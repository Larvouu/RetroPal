//
//  RADiscFileReader.c
//  EmulateurGBA
//
//  The file reader RetroAchievements hashes through, taught to read a `.chd`.
//
//  WHY THIS EXISTS. rcheevos knows perfectly well what a `.chd` is: its own
//  extension table maps one to the PlayStation, the PS2, the Dreamcast and six
//  others. What it does NOT ship is anything that can open one. Its bundled CD
//  reader handles `.cue`, `.gdi` and a raw `.bin`, and the word "chd" does not
//  appear anywhere in it. Every frontend that earns achievements from a `.chd`
//  supplies its own reader; this is ours.
//
//  It matters more here than it would elsewhere. `.chd` is the format the app
//  leads its PlayStation guidance with, because it is one file instead of a
//  folder and it is compressed. Leading players to a format that silently earns
//  no achievements would be the worst of both.
//
//  WHERE THE BINDING LIVES. Not here. This file fills no rcheevos struct and
//  includes no rcheevos header; RAClient hands its five functions over. See the
//  header for why, and note that the reason is not only a build one: reading a
//  disc image has nothing to do with achievements, and the module is smaller
//  and testable on its own for having been made to admit that.
//
//  WHY A FILE READER RATHER THAN A CD READER, which is the hook the plan named.
//  rcheevos has two seams here. The CD reader is the higher one: replacing it
//  means owning track tables, the four special track selectors, absolute sector
//  arithmetic and the sector-geometry sniffing that decides whether a disc is
//  MODE1/2048, MODE1/2352 or MODE2, which the bundled reader already does by
//  reading sector 16 and looking for the sync pattern and "CD001". Replacing
//  the FILE reader instead means answering one much smaller question, "what
//  bytes are at offset N of this disc image", and letting all of that proven
//  logic run unchanged on top. A CHD is a compressed container of fixed-size
//  frames, so that question has an exact answer.
//
//  The narrowing that buys it: `rc_hash_psx` opens track 1, by number. Track 1
//  is where a PlayStation disc keeps its data and its SYSTEM.CNF, so the flat
//  view below only ever has to be track 1's sectors from its first one, which
//  is precisely what a CHD stores from the frame the track begins at. A format
//  whose hash wanted "the largest track" or "the first track of the second
//  session" would need the other seam.
//
//  RUN IT: `Tools/disc-reader-test/run.sh` builds this file against the core's
//  own libchdr and reads synthetic discs with it, on whatever machine you are
//  sitting at. Nothing here is reachable from the app's unit tests -- it is C,
//  it needs a real libchdr and a real `.chd` -- so without that tool this code
//  would first execute on a device, where the only symptom of getting the
//  sector arithmetic wrong is a game that quietly earns no achievements.
//

#include "RADiscFileReader.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libchdr/chd.h>
#include <zlib.h>

/// A CD frame inside a CHD: the 2352-byte sector followed by 96 bytes of
/// subcode. The core makes the same assumption when it plays these discs
/// (`cdriso.c` divides `hunkbytes` by exactly this), so the two agree about
/// what a frame is.
#define RA_CHD_SECTOR_BYTES   2352
#define RA_CHD_SUBCODE_BYTES    96
#define RA_CHD_FRAME_BYTES    (RA_CHD_SECTOR_BYTES + RA_CHD_SUBCODE_BYTES)

typedef struct RAFileHandle {
    /// NULL for an ordinary file, which is every console but this one.
    chd_file *chd;
    FILE *file;

    /* CSO only (the PSP's compressed ISO, see RACsoOpen). `file` is the .cso. */
    uint32_t *csoIndex;         /* frames + 1 entries, the high bit = stored plain */
    uint32_t csoFrames;
    uint32_t csoFrameBytes;     /* uncompressed bytes per frame, a power of two */
    uint32_t csoAlign;          /* index entries are shifted left by this */
    uint64_t csoTotalBytes;     /* the ISO's own size */
    uint8_t *csoFrame;          /* one decompressed frame */
    uint8_t *csoPacked;         /* one compressed frame as read */
    uint32_t csoFrameIndex;     /* which frame csoFrame holds, or RA_NO_HUNK */

    /* A CHD read as the flat ISO it holds (see RAFlatLayout): 2048 bytes at
     * the start of each unit, from `trackFirstFrame`, for `frameCount` units. */
    int flat;
    uint32_t unitBytes;         /* the stride between two 2048-byte sectors */
    uint32_t unitsPerHunk;

    /* CHD only, all of it in FRAMES unless the name says bytes. */
    uint32_t framesPerHunk;
    uint32_t hunkBytes;
    uint32_t trackFirstFrame;   /* where track 1's first sector lives in the CHD */
    uint32_t frameCount;        /* frames in track 1 */
    uint8_t *hunk;              /* one decompressed hunk */
    uint32_t hunkIndex;         /* which one, or RA_NO_HUNK */
    int64_t position;           /* the flat read pointer, in bytes */
} RAFileHandle;

#define RA_NO_HUNK ((uint32_t)-1)

static int RAPathHasExtension(const char *path, const char *ext) {
    const char *dot = path ? strrchr(path, '.') : NULL;
    size_t i;
    if (!dot || strlen(dot + 1) != strlen(ext)) return 0;
    for (i = 0; ext[i]; i++) {
        char c = dot[1 + i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        if (c != ext[i]) return 0;
    }
    return 1;
}

static int RAPathIsCHD(const char *path) {
    const char *dot = path ? strrchr(path, '.') : NULL;
    if (!dot || strlen(dot) != 4) return 0;
    return (dot[1] == 'c' || dot[1] == 'C')
        && (dot[2] == 'h' || dot[2] == 'H')
        && (dot[3] == 'd' || dot[3] == 'D');
}

/// Track 1's geometry, read from the CHD's own metadata rather than assumed.
///
/// A CHD stores each track's frames back to back, and a track may carry a
/// pregap ahead of its data. Track 1's pregap is usually zero on a PlayStation
/// disc, but "usually" is how a hash comes back wrong for one disc in fifty and
/// nobody can tell why: with a 150-frame pregap in front, sector 16 of the flat
/// view would be somebody else's bytes, the geometry sniff would find no sync
/// pattern, and the disc would simply earn nothing.
///
/// Follows the same reading the core does in `cdriso.c`: prefer the CHT2 tag,
/// fall back to CHTR (which has no pregap field, so it is zero), and treat the
/// pregap frames as stored ahead of the track.
static void RAReadTrackOneGeometry(RAFileHandle *h) {
    char meta[256];
    uint32_t metaSize = 0;
    char type[64] = {0}, subtype[32] = {0}, pgtype[32] = {0}, pgsub[32] = {0};
    uint32_t track = 0, frames = 0, pregap = 0, postgap = 0;

    h->trackFirstFrame = 0;
    h->frameCount = 0;

    if (chd_get_metadata(h->chd, CDROM_TRACK_METADATA2_TAG, 0, meta, sizeof(meta),
                         &metaSize, NULL, NULL) == CHDERR_NONE) {
        if (sscanf(meta, CDROM_TRACK_METADATA2_FORMAT, &track, type, subtype,
                   &frames, &pregap, pgtype, pgsub, &postgap) >= 5) {
            h->trackFirstFrame = pregap;
            h->frameCount = frames > pregap ? frames - pregap : frames;
        }
    } else if (chd_get_metadata(h->chd, CDROM_TRACK_METADATA_TAG, 0, meta, sizeof(meta),
                                &metaSize, NULL, NULL) == CHDERR_NONE) {
        if (sscanf(meta, CDROM_TRACK_METADATA_FORMAT, &track, type, subtype, &frames) >= 4) {
            h->frameCount = frames;
        }
    }

    // No metadata at all is not fatal: a CHD with no track table still has its
    // frames, and track 1 starting at frame 0 with no pregap is what almost
    // every PlayStation disc looks like. Read it and let the sniff decide.
    if (h->frameCount == 0) {
        const chd_header *header = chd_get_header(h->chd);
        if (header && h->framesPerHunk) h->frameCount = header->totalhunks * h->framesPerHunk;
    }
}

/// The PSP's compressed ISO (CISO v1, `.cso`), presented as the ISO it holds.
///
/// rcheevos hashes a PSP disc by finding PSP_GAME/PARAM.SFO and the boot
/// executable through its own CD reader, which opens any unknown extension as
/// a raw track and works out the sector size from the bytes (it finds "CD001"
/// at 2048-byte sectors). So the flat view this reader owes it is simply the
/// decompressed ISO, byte for byte, and everything above stays rcheevos' own.
///
/// The format is PPSSPP's reading of it (Core/FileSystems/BlockDevices.cpp,
/// CISOFileBlockDevice), which is what plays these files in the app: a
/// 24-byte header (magic, header size, the ISO's size, the frame size, the
/// version, the index alignment), then frames + 1 little-endian offsets, each
/// shifted left by the alignment, the high bit marking a frame stored plain;
/// a compressed frame is raw deflate. Version 1 only, as in PPSSPP (it calls
/// version 2 "never in active use").
static int RACsoOpen(RAFileHandle *h) {
    uint8_t header[24];
    uint32_t i, indexCount;

    if (fread(header, 1, sizeof header, h->file) != sizeof header) return 0;
    if (memcmp(header, "CISO", 4) != 0 || header[20] > 1) return 0;
    h->csoTotalBytes = 0;
    for (i = 0; i < 8; i++) h->csoTotalBytes |= (uint64_t)header[8 + i] << (8 * i);
    h->csoFrameBytes = (uint32_t)header[16] | (uint32_t)header[17] << 8
        | (uint32_t)header[18] << 16 | (uint32_t)header[19] << 24;
    h->csoAlign = header[21];
    if (h->csoFrameBytes < 0x800 || (h->csoFrameBytes & (h->csoFrameBytes - 1)) != 0
        || h->csoFrameBytes > (1u << 24) || h->csoAlign > 31 || h->csoTotalBytes == 0) {
        return 0;
    }
    h->csoFrames = (uint32_t)((h->csoTotalBytes + h->csoFrameBytes - 1) / h->csoFrameBytes);
    indexCount = h->csoFrames + 1;
    h->csoIndex = (uint32_t *)malloc((size_t)indexCount * sizeof(uint32_t));
    h->csoFrame = (uint8_t *)malloc(h->csoFrameBytes);
    /* A compressed frame can be at most one alignment unit past a frame's size. */
    h->csoPacked = (uint8_t *)malloc((size_t)h->csoFrameBytes + ((size_t)1 << h->csoAlign));
    if (!h->csoIndex || !h->csoFrame || !h->csoPacked) return 0;
    for (i = 0; i < indexCount; i++) {
        uint8_t le[4];
        if (fread(le, 1, 4, h->file) != 4) return 0;
        h->csoIndex[i] = (uint32_t)le[0] | (uint32_t)le[1] << 8 | (uint32_t)le[2] << 16 | (uint32_t)le[3] << 24;
    }
    h->csoFrameIndex = RA_NO_HUNK;
    return 1;
}

/// One frame of the ISO, decompressed. NULL on any failure, which the reader
/// turns into a short read: rcheevos then reports the disc as one it cannot
/// hash rather than hashing whatever was in the buffer.
static const uint8_t *RACsoFrame(RAFileHandle *h, uint32_t frame) {
    uint32_t entry, start, end;
    uint64_t at, length;

    if (frame >= h->csoFrames) return NULL;
    if (frame == h->csoFrameIndex) return h->csoFrame;
    entry = h->csoIndex[frame];
    start = entry & 0x7FFFFFFFu;
    end = h->csoIndex[frame + 1] & 0x7FFFFFFFu;
    if (end < start) return NULL;
    at = (uint64_t)start << h->csoAlign;
    length = ((uint64_t)end - start) << h->csoAlign;
    if (fseeko(h->file, (off_t)at, SEEK_SET) != 0) return NULL;

    h->csoFrameIndex = RA_NO_HUNK;
    if (entry & 0x80000000u) {
        /* Stored plain: the frame's bytes as they are. */
        size_t got = fread(h->csoFrame, 1, h->csoFrameBytes, h->file);
        if (got < h->csoFrameBytes) memset(h->csoFrame + got, 0, h->csoFrameBytes - got);
    } else {
        z_stream z;
        size_t got;
        int status;
        if (length > (uint64_t)h->csoFrameBytes + ((uint64_t)1 << h->csoAlign)) return NULL;
        got = fread(h->csoPacked, 1, (size_t)length, h->file);
        memset(&z, 0, sizeof z);
        if (inflateInit2(&z, -15) != Z_OK) return NULL;
        z.next_in = h->csoPacked;
        z.avail_in = (uInt)got;
        z.next_out = h->csoFrame;
        z.avail_out = h->csoFrameBytes;
        status = inflate(&z, Z_FINISH);
        inflateEnd(&z);
        if (status != Z_STREAM_END || z.total_out != h->csoFrameBytes) return NULL;
    }
    h->csoFrameIndex = frame;
    return h->csoFrame;
}

static size_t RACsoRead(RAFileHandle *h, uint8_t *out, size_t requested) {
    size_t total = 0;
    while (requested > 0 && (uint64_t)h->position < h->csoTotalBytes) {
        const uint32_t frame = (uint32_t)((uint64_t)h->position / h->csoFrameBytes);
        const size_t within = (size_t)((uint64_t)h->position % h->csoFrameBytes);
        size_t chunk = h->csoFrameBytes - within;
        const uint8_t *data = RACsoFrame(h, frame);
        if (!data) break;
        if (chunk > requested) chunk = requested;
        if ((uint64_t)h->position + chunk > h->csoTotalBytes) chunk = (size_t)(h->csoTotalBytes - (uint64_t)h->position);
        memcpy(out, data + within, chunk);
        out += chunk;
        total += chunk;
        requested -= chunk;
        h->position += (int64_t)chunk;
    }
    return total;
}

static void RACsoFree(RAFileHandle *h) {
    free(h->csoIndex);
    free(h->csoFrame);
    free(h->csoPacked);
    h->csoIndex = NULL;
    h->csoFrame = h->csoPacked = NULL;
}

/// Whether a CHD is read as the flat ISO it holds, 2048 bytes a sector,
/// rather than as raw 2352-byte CD sectors. Two kinds are (2026-10-12, when a
/// fan-translated Kingdom Hearts Birth by Sleep `.chd` was filed under the
/// PlayStation):
///
/// - a DVD image, what `chdman createdvd` writes and how a PSP UMD becomes a
///   `.chd`: the image itself in 2048-byte units, with no track table;
/// - a CD image whose track 1 is "cooked" (MODE1 or MODE2_FORM1), what
///   `chdman createcd` writes from a plain `.iso`: each frame holds the
///   sector's 2048 bytes first.
///
/// Both are read as PPSSPP reads them (`CHDFileBlockDevice`, BlockDevices.cpp,
/// v1.20.4: 2048 bytes from the start of each unit). A PlayStation `.chd` is a
/// raw track (MODE2_RAW, MODE1_RAW) and takes the 2352-byte path as before.
/// Answers the stride between two sectors, or 0 for a raw CD.
static uint32_t RAFlatLayout(chd_file *chd) {
    char meta[256];
    char type[64] = {0}, subtype[32] = {0};
    uint32_t track = 0, frames = 0;
    const chd_header *header = chd_get_header(chd);
    if (!header || header->unitbytes < 2048) return 0;
    if (chd_get_metadata(chd, CDROM_TRACK_METADATA2_TAG, 0, meta, sizeof meta, NULL, NULL, NULL) == CHDERR_NONE
        || chd_get_metadata(chd, CDROM_TRACK_METADATA_TAG, 0, meta, sizeof meta, NULL, NULL, NULL) == CHDERR_NONE) {
        if (sscanf(meta, "TRACK:%u TYPE:%63s SUBTYPE:%31s FRAMES:%u", &track, type, subtype, &frames) < 2) return 0;
        return (strcmp(type, "MODE1") == 0 || strcmp(type, "MODE2_FORM1") == 0) ? header->unitbytes : 0;
    }
    if (chd_get_metadata(chd, CDROM_OLD_METADATA_TAG, 0, meta, sizeof meta, NULL, NULL, NULL) == CHDERR_NONE) {
        return 0;
    }
    if (chd_get_metadata(chd, DVD_METADATA_TAG, 0, meta, sizeof meta, NULL, NULL, NULL) == CHDERR_NONE
        || header->unitbytes == 2048) {
        return header->unitbytes;
    }
    return 0;
}

/// The flat ISO's bytes, sector by sector. A short read at the end or on a
/// hunk that will not decompress, as for a raw CD.
static size_t RAFlatRead(RAFileHandle *h, uint8_t *out, size_t requested) {
    size_t total = 0;
    const uint64_t size = (uint64_t)h->frameCount * 2048;
    while (requested > 0 && (uint64_t)h->position < size) {
        const uint32_t unit = h->trackFirstFrame + (uint32_t)((uint64_t)h->position / 2048);
        const size_t within = (size_t)((uint64_t)h->position % 2048);
        const uint32_t hunk = unit / h->unitsPerHunk;
        size_t chunk = 2048 - within;
        if (hunk != h->hunkIndex) {
            if (chd_read(h->chd, hunk, h->hunk) != CHDERR_NONE) {
                h->hunkIndex = RA_NO_HUNK;
                break;
            }
            h->hunkIndex = hunk;
        }
        if (chunk > requested) chunk = requested;
        memcpy(out, h->hunk + (size_t)(unit % h->unitsPerHunk) * h->unitBytes + within, chunk);
        out += chunk;
        total += chunk;
        requested -= chunk;
        h->position += (int64_t)chunk;
    }
    return total;
}

int RADiscIsFlatImage(void *handle) {
    RAFileHandle *h = (RAFileHandle *)handle;
    return h && h->flat;
}

void *RADiscOpen(const char *path) {
    RAFileHandle *h;

    if (!path) return NULL;

    h = (RAFileHandle *)calloc(1, sizeof(*h));
    if (!h) return NULL;
    h->hunkIndex = RA_NO_HUNK;

    if (RAPathHasExtension(path, "cso")) {
        h->file = fopen(path, "rb");
        if (!h->file) { free(h); return NULL; }
        if (!RACsoOpen(h)) {
            RACsoFree(h);
            fclose(h->file);
            free(h);
            return NULL;
        }
        return h;
    }

    if (!RAPathIsCHD(path)) {
        h->file = fopen(path, "rb");
        if (!h->file) { free(h); return NULL; }
        return h;
    }

    if (chd_open(path, CHD_OPEN_READ, NULL, &h->chd) != CHDERR_NONE) {
        free(h);
        return NULL;
    }

    h->unitBytes = RAFlatLayout(h->chd);
    if (h->unitBytes) {
        const chd_header *header = chd_get_header(h->chd);
        h->unitsPerHunk = header->hunkbytes / h->unitBytes;
        if (h->unitsPerHunk == 0) {
            chd_close(h->chd);
            free(h);
            return NULL;
        }
        h->flat = 1;
        h->hunkBytes = header->hunkbytes;
        h->framesPerHunk = h->unitsPerHunk;
        h->hunk = (uint8_t *)malloc(h->hunkBytes);
        if (!h->hunk) {
            chd_close(h->chd);
            free(h);
            return NULL;
        }
        // A cooked CD keeps its track table, pregap included, and is read
        // from it exactly as a raw one is; a DVD has none, and every unit of
        // its logical size is the image.
        RAReadTrackOneGeometry(h);
        if (chd_get_metadata(h->chd, DVD_METADATA_TAG, 0, NULL, 0, NULL, NULL, NULL) == CHDERR_NONE
            || h->unitBytes == 2048) {
            h->trackFirstFrame = 0;
            h->frameCount = (uint32_t)(header->logicalbytes / h->unitBytes);
        }
        return h;
    }

    {
        const chd_header *header = chd_get_header(h->chd);
        if (!header || header->hunkbytes < RA_CHD_FRAME_BYTES) {
            chd_close(h->chd);
            free(h);
            return NULL;
        }
        h->hunkBytes = header->hunkbytes;
        h->framesPerHunk = header->hunkbytes / RA_CHD_FRAME_BYTES;
    }

    h->hunk = (uint8_t *)malloc(h->hunkBytes);
    if (!h->hunk) {
        chd_close(h->chd);
        free(h);
        return NULL;
    }

    RAReadTrackOneGeometry(h);
    return h;
}

/// One sector of track 1, decompressed, without its subcode.
///
/// Returns 0 on any failure, which the callers turn into a short read. A short
/// read is the right answer here: rcheevos treats it as "this is not a disc I
/// can hash" and moves on, rather than hashing whatever happened to be in the
/// buffer.
static const uint8_t *RASector(RAFileHandle *h, uint32_t sector) {
    uint32_t frame, hunk, indexInHunk;

    if (sector >= h->frameCount) return NULL;
    frame = h->trackFirstFrame + sector;
    hunk = frame / h->framesPerHunk;
    indexInHunk = frame % h->framesPerHunk;

    if (hunk != h->hunkIndex) {
        if (chd_read(h->chd, hunk, h->hunk) != CHDERR_NONE) {
            h->hunkIndex = RA_NO_HUNK;
            return NULL;
        }
        h->hunkIndex = hunk;
    }
    return h->hunk + (size_t)indexInHunk * RA_CHD_FRAME_BYTES;
}

size_t RADiscRead(void *handle, void *buffer, size_t requested) {
    RAFileHandle *h = (RAFileHandle *)handle;
    uint8_t *out = (uint8_t *)buffer;
    size_t total = 0;

    if (!h || !buffer) return 0;
    if (h->csoIndex) return RACsoRead(h, out, requested);
    if (!h->chd) return fread(buffer, 1, requested, h->file);
    if (h->flat) return RAFlatRead(h, out, requested);

    while (requested > 0) {
        const uint32_t sector = (uint32_t)(h->position / RA_CHD_SECTOR_BYTES);
        const size_t within = (size_t)(h->position % RA_CHD_SECTOR_BYTES);
        size_t chunk = RA_CHD_SECTOR_BYTES - within;
        const uint8_t *data = RASector(h, sector);

        if (!data) break;
        if (chunk > requested) chunk = requested;

        memcpy(out, data + within, chunk);
        out += chunk;
        total += chunk;
        requested -= chunk;
        h->position += (int64_t)chunk;
    }
    return total;
}

void RADiscSeek(void *handle, int64_t offset, int origin) {
    RAFileHandle *h = (RAFileHandle *)handle;
    if (!h) return;
    if (!h->chd && !h->csoIndex) { fseeko(h->file, (off_t)offset, origin); return; }

    switch (origin) {
        case SEEK_SET: h->position = offset; break;
        case SEEK_CUR: h->position += offset; break;
        case SEEK_END:
            h->position = h->csoIndex ? (int64_t)h->csoTotalBytes + offset
                        : h->flat     ? (int64_t)h->frameCount * 2048 + offset
                                      : (int64_t)h->frameCount * RA_CHD_SECTOR_BYTES + offset;
            break;
        default: return;
    }
    if (h->position < 0) h->position = 0;
}

int64_t RADiscTell(void *handle) {
    RAFileHandle *h = (RAFileHandle *)handle;
    if (!h) return 0;
    return (h->chd || h->csoIndex) ? h->position : (int64_t)ftello(h->file);
}

void RADiscClose(void *handle) {
    RAFileHandle *h = (RAFileHandle *)handle;
    if (!h) return;
    if (h->chd) {
        chd_close(h->chd);
        free(h->hunk);
    } else if (h->file) {
        RACsoFree(h);
        fclose(h->file);
    }
    free(h);
}
