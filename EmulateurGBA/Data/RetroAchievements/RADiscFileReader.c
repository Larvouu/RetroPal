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

void *RADiscOpen(const char *path) {
    RAFileHandle *h;

    if (!path) return NULL;

    h = (RAFileHandle *)calloc(1, sizeof(*h));
    if (!h) return NULL;
    h->hunkIndex = RA_NO_HUNK;

    if (!RAPathIsCHD(path)) {
        h->file = fopen(path, "rb");
        if (!h->file) { free(h); return NULL; }
        return h;
    }

    if (chd_open(path, CHD_OPEN_READ, NULL, &h->chd) != CHDERR_NONE) {
        free(h);
        return NULL;
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
    if (!h->chd) return fread(buffer, 1, requested, h->file);

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
    if (!h->chd) { fseeko(h->file, (off_t)offset, origin); return; }

    switch (origin) {
        case SEEK_SET: h->position = offset; break;
        case SEEK_CUR: h->position += offset; break;
        case SEEK_END:
            h->position = (int64_t)h->frameCount * RA_CHD_SECTOR_BYTES + offset;
            break;
        default: return;
    }
    if (h->position < 0) h->position = 0;
}

int64_t RADiscTell(void *handle) {
    RAFileHandle *h = (RAFileHandle *)handle;
    if (!h) return 0;
    return h->chd ? h->position : (int64_t)ftello(h->file);
}

void RADiscClose(void *handle) {
    RAFileHandle *h = (RAFileHandle *)handle;
    if (!h) return;
    if (h->chd) {
        chd_close(h->chd);
        free(h->hunk);
    } else if (h->file) {
        fclose(h->file);
    }
    free(h);
}
