//
//  PSPDiscProbe.c
//  EmulateurGBA
//
//  See PSPDiscProbe.h. Each test below is PPSSPP's own (`Identify_File`,
//  Core/Loaders.cpp, v1.20.4), cited where it is applied, so the app and the
//  core agree on what a PSP game is.
//

#include "PSPDiscProbe.h"
#include "../RetroAchievements/RADiscFileReader.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <pthread.h>
#include <sys/stat.h>

/// The ISO 9660 primary volume descriptor: sector 16 of 2048 bytes.
static const long kVolumeDescriptorOffset = 16 * 2048;

/// Where an ISO's bytes come from: a plain file (`.iso`) or a DVD `.chd`,
/// decompressed by the disc reader the achievements already use, which
/// presents it as the ISO it holds.
typedef struct ISOSource {
    FILE *file;
    void *disc;
} ISOSource;

static bool ReadAt(FILE *f, long offset, void *buffer, size_t length) {
    if (fseek(f, offset, SEEK_SET) != 0) return false;
    return fread(buffer, 1, length, f) == length;
}

static bool ReadISO(ISOSource *src, long offset, void *buffer, size_t length) {
    if (src->file) return ReadAt(src->file, offset, buffer, length);
    RADiscSeek(src->disc, offset, SEEK_SET);
    return RADiscRead(src->disc, buffer, length) == length;
}

static uint32_t LE32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint16_t LE16(const uint8_t *p) {
    return (uint16_t)(p[0] | p[1] << 8);
}

static const char *Extension(const char *path) {
    const char *slash = strrchr(path, '/');
    const char *dot = strrchr(path, '.');
    if (!dot || (slash && dot < slash)) return "";
    return dot + 1;
}

/// Whether the ISO's root directory holds a PSP_GAME folder: PPSSPP's answer
/// for a volume whose system name is neither "PSP GAME" nor a known other
/// console's (`umd.GetFileInfo("/PSP_GAME").exists`). One read of the root
/// directory's first sector, which on a UMD lists PSP_GAME among its first
/// entries.
static bool RootHoldsPSPGame(ISOSource *src, const uint8_t *pvd) {
    // The root directory record sits at byte 156 of the volume descriptor;
    // its extent (little-endian) at 2, its length at 10.
    const uint8_t *root = pvd + 156;
    uint32_t extent = LE32(root + 2);
    uint32_t length = LE32(root + 10);
    if (extent == 0 || length == 0) return false;
    uint8_t dir[2048];
    if (!ReadISO(src, (long)extent * 2048, dir, sizeof(dir))) return false;
    size_t limit = length < sizeof(dir) ? length : sizeof(dir);
    size_t at = 0;
    while (at + 33 < limit) {
        uint8_t recordLength = dir[at];
        if (recordLength == 0) break;               // the rest of the sector is padding
        if (at + recordLength > limit) break;
        uint8_t nameLength = dir[at + 32];
        if (33 + (size_t)nameLength <= recordLength
            && nameLength == 8 && memcmp(dir + at + 33, "PSP_GAME", 8) == 0) {
            return true;
        }
        at += recordLength;
    }
    return false;
}

/// An ISO 9660 image: "PSP GAME" in the volume's system name, PPSSPP's first
/// test; a UMD Video with game data, or any other volume carrying PSP_GAME,
/// is a PSP game too. "PLAYSTATION" (the PlayStation and the PS2) is not, and
/// neither is a raw 2352-byte CD image, which has no ISO volume at 0x8000: a
/// UMD is never dumped that way.
///
/// UNDECIDED for a 2048-byte volume that names some other system and holds no
/// PSP_GAME, and for one that cannot be read: a PlayStation disc names itself
/// "PLAYSTATION", a PSP game carries PSP_GAME, and this is neither, so the
/// bytes do not say which console it is and the player is asked
/// (2026-10-12; before, the answer was "PlayStation" without a word).
static PSPDiscProbeAnswer ReadPSPISO(ISOSource *src) {
    uint8_t pvd[2048];
    if (!ReadISO(src, kVolumeDescriptorOffset, pvd, sizeof(pvd))) return PSPDiscProbeUndecided;
    if (memcmp(pvd + 1, "CD001", 5) != 0) return PSPDiscProbeNotPSP;
    const uint8_t *systemId = pvd + 8;              // 32 bytes, space padded
    if (memcmp(systemId, "PSP GAME", 8) == 0 || memcmp(systemId, "\"PSP GAME\"", 10) == 0) {
        return PSPDiscProbePSP;
    }
    if (memcmp(systemId, "PLAYSTATION", 11) == 0 || memcmp(systemId, "PS3", 3) == 0) {
        return PSPDiscProbeNotPSP;
    }
    return RootHoldsPSPGame(src, pvd) ? PSPDiscProbePSP : PSPDiscProbeUndecided;
}

/// A `.chd`. A raw CD track (every PlayStation `.chd`, made by `chdman
/// createcd` from a `.cue`) is never a PSP game: a UMD is an image of 2048-byte
/// sectors. One that holds 2048-byte sectors (a DVD image, `chdman createdvd`,
/// which is how a UMD becomes a `.chd`; or a CD made from a plain `.iso`) is
/// read as the ISO it holds, as PPSSPP reads it (`CHDFileBlockDevice`). One
/// that will not open (a child CHD whose parent is elsewhere, a damaged file)
/// is undecided.
static PSPDiscProbeAnswer ReadPSPCHDUncached(const char *path) {
    void *disc = RADiscOpen(path);
    if (!disc) return PSPDiscProbeUndecided;
    PSPDiscProbeAnswer answer = PSPDiscProbeNotPSP;
    if (RADiscIsFlatImage(disc)) {
        ISOSource src = { NULL, disc };
        answer = ReadPSPISO(&src);
    }
    RADiscClose(disc);
    return answer;
}

/// The last answers for `.chd` files, keyed by path, size and modification
/// time. Opening a CHD decompresses its whole hunk map (about 13 ms for a
/// 1.5 GB image, measured on the Linux bench), and the library asks the
/// console of every game on every refresh, on the main thread. A cartridge
/// or an `.iso` costs a few reads and is not cached.
#define PSP_CHD_CACHE_SLOTS 64
typedef struct {
    char path[1024];
    off_t size;
    struct timespec modified;
    PSPDiscProbeAnswer answer;
} CHDAnswer;
static CHDAnswer gCHDAnswers[PSP_CHD_CACHE_SLOTS];
static unsigned gCHDNext;
static pthread_mutex_t gCHDLock = PTHREAD_MUTEX_INITIALIZER;

static PSPDiscProbeAnswer ReadPSPCHD(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return PSPDiscProbeUndecided;
    size_t length = strlen(path);
    bool cacheable = length < sizeof(gCHDAnswers[0].path);
    if (cacheable) {
        pthread_mutex_lock(&gCHDLock);
        for (unsigned i = 0; i < PSP_CHD_CACHE_SLOTS; i++) {
            CHDAnswer *e = &gCHDAnswers[i];
            if (e->size == st.st_size
                && e->modified.tv_sec == st.st_mtimespec.tv_sec
                && e->modified.tv_nsec == st.st_mtimespec.tv_nsec
                && strcmp(e->path, path) == 0) {
                PSPDiscProbeAnswer answer = e->answer;
                pthread_mutex_unlock(&gCHDLock);
                return answer;
            }
        }
        pthread_mutex_unlock(&gCHDLock);
    }
    PSPDiscProbeAnswer answer = ReadPSPCHDUncached(path);
    // An unreadable file is not remembered: it may be readable next time (a
    // copy still landing, an iCloud download).
    if (cacheable && answer != PSPDiscProbeUndecided) {
        pthread_mutex_lock(&gCHDLock);
        CHDAnswer *e = &gCHDAnswers[gCHDNext++ % PSP_CHD_CACHE_SLOTS];
        memcpy(e->path, path, length + 1);
        e->size = st.st_size;
        e->modified = st.st_mtimespec;
        e->answer = answer;
        pthread_mutex_unlock(&gCHDLock);
    }
    return answer;
}

/// The PARAM.SFO's CATEGORY, read from `sfo` (`size` bytes), into `out`
/// (NUL-terminated, at most `outSize - 1` characters). False when absent.
static bool SFOCategory(const uint8_t *sfo, size_t size, char *out, size_t outSize) {
    if (size < 20 || LE32(sfo) != 0x46535000) return false;   // "\0PSF"
    uint32_t keyTable = LE32(sfo + 8);
    uint32_t dataTable = LE32(sfo + 12);
    uint32_t entries = LE32(sfo + 16);
    if (keyTable > size || dataTable > size) return false;
    for (uint32_t i = 0; i < entries; i++) {
        size_t index = 20 + (size_t)i * 16;
        if (index + 16 > size) return false;
        size_t key = keyTable + LE16(sfo + index);
        size_t data = dataTable + LE32(sfo + index + 12);
        uint32_t length = LE32(sfo + index + 4);
        if (key + 9 > size || data >= size) return false;
        if (memcmp(sfo + key, "CATEGORY", 9) != 0) continue;   // with its NUL
        size_t n = 0;
        while (n + 1 < outSize && n < length && data + n < size && sfo[data + n]) {
            out[n] = (char)sfo[data + n];
            n++;
        }
        out[n] = 0;
        return true;
    }
    return false;
}

/// A PBP (an EBOOT): a PSP game, unless it is a PlayStation game repacked for
/// the PSP's store, which PPSSPP recognises two ways and so does this: its
/// PARAM.SFO's CATEGORY is "ME", or its data section begins "PSISOIMG" (one
/// disc) or "PSTITLEIMG" (several), which PPSSPP reads as the 32-bit word
/// 'SISP' at the section's start. A PBP whose data section begins "NPUMDIMG"
/// is a PSP game sold on the store, and every other PBP is a PSP program.
static bool IsPSPPBP(FILE *f) {
    uint8_t header[40];                             // magic, version, 8 offsets
    if (!ReadAt(f, 0, header, sizeof(header))) return false;
    // An ELF misnamed `.pbp` is a PSP program (PPSSPP: "a few elfs misnamed
    // as pbp (like Trig Wars), accept that").
    if (memcmp(header, "\x7f" "ELF", 4) == 0) return true;
    if (memcmp(header, "\0PBP", 4) != 0) return false;

    uint32_t sfoStart = LE32(header + 8);           // offsets[0], PARAM.SFO
    uint32_t sfoEnd = LE32(header + 12);            // offsets[1]
    uint32_t psar = LE32(header + 36);              // offsets[7], the data section

    if (sfoEnd > sfoStart && sfoEnd - sfoStart <= 64 * 1024) {
        uint8_t sfo[64 * 1024];
        size_t size = sfoEnd - sfoStart;
        char category[8];
        if (ReadAt(f, sfoStart, sfo, size)
            && SFOCategory(sfo, size, category, sizeof(category))
            && strcmp(category, "ME") == 0) {
            return false;
        }
    }
    uint8_t psarHead[4];
    if (psar && ReadAt(f, psar, psarHead, sizeof(psarHead))
        && (memcmp(psarHead, "PSIS", 4) == 0        // PSISOIMG, one disc
            || memcmp(psarHead, "PSTI", 4) == 0)) { // PSTITLEIMG, several
        return false;
    }
    return true;
}

PSPDiscProbeAnswer PSPDiscProbeRead(const char *path) {
    if (!path) return PSPDiscProbeNotPSP;
    const char *ext = Extension(path);
    bool iso = strcasecmp(ext, "iso") == 0;
    bool cso = strcasecmp(ext, "cso") == 0;
    bool pbp = strcasecmp(ext, "pbp") == 0;
    bool chd = strcasecmp(ext, "chd") == 0;
    if (!iso && !cso && !pbp && !chd) return PSPDiscProbeNotPSP;
    if (chd) return ReadPSPCHD(path);

    FILE *f = fopen(path, "rb");
    if (!f) return iso ? PSPDiscProbeUndecided : PSPDiscProbeNotPSP;
    PSPDiscProbeAnswer answer;
    if (cso) {
        // A compressed ISO. The format is the PSP scene's own and no other
        // console here uses it; the magic is checked so a file that is not
        // one is refused at import instead of failing at boot.
        uint8_t magic[4];
        answer = ReadAt(f, 0, magic, sizeof(magic)) && memcmp(magic, "CISO", 4) == 0
            ? PSPDiscProbePSP : PSPDiscProbeNotPSP;
    } else if (iso) {
        ISOSource src = { f, NULL };
        answer = ReadPSPISO(&src);
    } else {
        answer = IsPSPPBP(f) ? PSPDiscProbePSP : PSPDiscProbeNotPSP;
    }
    fclose(f);
    return answer;
}

bool PSPDiscProbeIsPSPGame(const char *path) {
    switch (PSPDiscProbeRead(path)) {
        case PSPDiscProbePSP: return true;
        case PSPDiscProbeNotPSP: return false;
        case PSPDiscProbeUndecided: break;
    }
    // The bytes do not say: the player's answer, recorded in the game's folder
    // when it was imported, decides. No answer is the extension's, the
    // PlayStation's, as it always was.
    const char *slash = strrchr(path, '/');
    if (!slash) return false;
    size_t folderLength = (size_t)(slash - path) + 1;
    char choicePath[4096];
    if (folderLength + sizeof(PSP_DISC_PROBE_CHOICE_FILE) > sizeof(choicePath)) return false;
    memcpy(choicePath, path, folderLength);
    memcpy(choicePath + folderLength, PSP_DISC_PROBE_CHOICE_FILE, sizeof(PSP_DISC_PROBE_CHOICE_FILE));
    FILE *f = fopen(choicePath, "rb");
    if (!f) return false;
    char choice[3] = {0};
    bool psp = fread(choice, 1, sizeof(choice), f) == sizeof(choice) && memcmp(choice, "psp", 3) == 0;
    fclose(f);
    return psp;
}
