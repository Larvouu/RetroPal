//
//  CTRGameProbe.c
//  EmulateurGBA
//
//  See CTRGameProbe.h. The offsets are Azahar's (core/file_sys/ncch_container.h,
//  NCCH_Header; core/loader/ncch.cpp and ncsd.cpp), so the app and the core
//  agree on what a decrypted 3DS game is.
//

#include "CTRGameProbe.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

/// Both headers' magic sits 0x100 into the header (after the signature).
static const long kMagicOffset = 0x100;
/// NCSD: the partition table, eight (offset, size) pairs in 0x200-byte media
/// units, the first being the game.
static const long kPartitionTableOffset = 0x120;
static const long kMediaUnit = 0x200;
/// NCCH: flags[8] at 0x188; flags[7] holds no_crypto (bit 2).
static const long kNCCHFlags7Offset = 0x188 + 7;
static const uint8_t kNoCryptoBit = 0x04;
/// NCCH: program_id, a little-endian u64 at 0x118.
static const long kNCCHProgramIDOffset = 0x118;

static int ReadAt(FILE *f, long offset, void *buffer, size_t length) {
    if (fseek(f, offset, SEEK_SET) != 0) return 0;
    return fread(buffer, 1, length, f) == length;
}

/// The NCCH at `base`: decrypted, encrypted, or not an NCCH.
static CTRGameProbeAnswer ReadNCCH(FILE *f, long base) {
    char magic[4];
    uint8_t flags7;
    if (!ReadAt(f, base + kMagicOffset, magic, sizeof magic) || memcmp(magic, "NCCH", 4) != 0) {
        return CTRGameProbeNotCTR;
    }
    if (!ReadAt(f, base + kNCCHFlags7Offset, &flags7, 1)) return CTRGameProbeNotCTR;
    return (flags7 & kNoCryptoBit) ? CTRGameProbeDecrypted : CTRGameProbeEncrypted;
}

CTRGameProbeAnswer CTRGameProbeRead(const char *path) {
    if (!path) return CTRGameProbeNotCTR;
    FILE *f = fopen(path, "rb");
    if (!f) return CTRGameProbeNotCTR;

    CTRGameProbeAnswer answer = CTRGameProbeNotCTR;
    char magic[4];
    if (ReadAt(f, 0, magic, sizeof magic) && memcmp(magic, "3DSX", 4) == 0) {
        // A homebrew executable: never encrypted.
        answer = CTRGameProbeDecrypted;
    } else if (ReadAt(f, kMagicOffset, magic, sizeof magic) && memcmp(magic, "NCSD", 4) == 0) {
        uint8_t entry[4];
        if (ReadAt(f, kPartitionTableOffset, entry, sizeof entry)) {
            const uint32_t units = (uint32_t)entry[0] | (uint32_t)entry[1] << 8
                                 | (uint32_t)entry[2] << 16 | (uint32_t)entry[3] << 24;
            answer = ReadNCCH(f, (long)units * kMediaUnit);
        }
    } else {
        // A bare NCCH (.cxi, .app).
        answer = ReadNCCH(f, 0);
    }
    fclose(f);
    return answer;
}

/// Where the game's NCCH starts: 0 for a bare NCCH, the first partition for an
/// NCSD; -1 for a `.3dsx` or a file that is neither.
static long NCCHBase(FILE *f) {
    char magic[4];
    if (ReadAt(f, 0, magic, sizeof magic) && memcmp(magic, "3DSX", 4) == 0) return -1;
    if (ReadAt(f, kMagicOffset, magic, sizeof magic) && memcmp(magic, "NCSD", 4) == 0) {
        uint8_t entry[4];
        if (!ReadAt(f, kPartitionTableOffset, entry, sizeof entry)) return -1;
        const uint32_t units = (uint32_t)entry[0] | (uint32_t)entry[1] << 8
                             | (uint32_t)entry[2] << 16 | (uint32_t)entry[3] << 24;
        return (long)units * kMediaUnit;
    }
    return 0;
}

unsigned long long CTRGameProbeReadTitleID(const char *path) {
    if (!path) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    unsigned long long titleID = 0;
    const long base = NCCHBase(f);
    char magic[4];
    uint8_t id[8];
    if (base >= 0
        && ReadAt(f, base + kMagicOffset, magic, sizeof magic) && memcmp(magic, "NCCH", 4) == 0
        && ReadAt(f, base + kNCCHProgramIDOffset, id, sizeof id)) {
        for (int i = 7; i >= 0; i--) titleID = titleID << 8 | id[i];
    }
    fclose(f);
    return titleID;
}

/// NCCH + 0x200 is the extended header; its ARM11 local capabilities start
/// 0x200 into it and their storage info 0x30 into those (Azahar's
/// ExHeader_Header, ExHeader_ARM11_SystemLocalCaps, ExHeader_StorageInfo:
/// offsets measured from the structs, 2026-10-20). ext_save_data_id is the
/// storage info's first u64; other_attributes its last byte (0x1F).
static const long kExtSaveDataIDOffset = 0x200 + 0x200 + 0x30;
static const long kStorageOtherAttributesOffset = kExtSaveDataIDOffset + 0x1F;

unsigned long long CTRGameProbeReadExtdataID(const char *path) {
    if (!path) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    unsigned long long extdataID = 0;
    const long base = NCCHBase(f);
    char magic[4];
    uint8_t flags7 = 0, attributes = 0;
    uint8_t id[8];
    if (base >= 0
        && ReadAt(f, base + kMagicOffset, magic, sizeof magic) && memcmp(magic, "NCCH", 4) == 0
        && ReadAt(f, base + kNCCHFlags7Offset, &flags7, 1) && (flags7 & kNoCryptoBit)
        && ReadAt(f, base + kStorageOtherAttributesOffset, &attributes, 1)
        // Extended save data access: several IDs, which Azahar itself only
        // guesses among (ReadExtdataId). Not guessed here.
        && (attributes >> 1) == 0
        && ReadAt(f, base + kExtSaveDataIDOffset, id, sizeof id)) {
        for (int i = 7; i >= 0; i--) extdataID = extdataID << 8 | id[i];
    }
    fclose(f);
    return extdataID;
}
