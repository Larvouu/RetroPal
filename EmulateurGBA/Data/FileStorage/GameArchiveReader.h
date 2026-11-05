//
//  GameArchiveReader.h
//  EmulateurGBA
//
//  The archives other than .zip that a game can arrive in: .7z, .rar (RAR4
//  and RAR5), .tar, .tar.gz / .tgz, .tar.xz / .txz, and a lone .gz or .xz
//  (1.3.5, decided 2026-10-27: every main archive format, not .zip alone).
//  Read through libarchive (Vendor/archive-ios/build.sh, which says why that
//  library and what is left out). The .zip keeps its own reader
//  (ZIPExtractor), unchanged; `GameArchive` in Swift chooses, and sends a
//  .zip here only when that reader meets a compression method it does not
//  implement (LZMA, BZIP2, XZ, Deflate64 inside a zip).
//
//  C, with plain C types only, so Swift never sees libarchive's.
//
//  ONE PASS PER CALL, ALWAYS. These formats are read front to back: a 7z or
//  a RAR made "solid" has no way to reach its tenth file without decoding the
//  nine before it. So there is no "read entry N" here, as there is for a zip.
//  Listing reads, in the same pass, the few entries whose bytes the importer's
//  rules need (a disc's .cue / .toc / .m3u, a .md that may be a README, a .bin
//  small enough to be a Mega Drive cartridge), and extracting writes every
//  wanted entry in one pass too.
//

#ifndef GameArchiveReader_h
#define GameArchiveReader_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    GameArchiveOK = 0,
    /// The file cannot be opened as any format read here, or is damaged.
    GameArchiveCannotRead = 1,
    /// The archive (its names, or an entry wanted) is protected by a password.
    GameArchiveEncrypted = 2,
    /// A valid archive, an entry compressed by a method not built in.
    GameArchiveUnsupported = 3,
    /// A wanted entry is not in the archive.
    GameArchiveNotFound = 4,
    /// Writing to the destination failed, for a reason other than space.
    GameArchiveWriteFailed = 5,
    /// Writing to the destination failed: the phone is full (ENOSPC, EDQUOT),
    /// which the player can fix, and is told so (audit, 2026-10-29).
    GameArchiveNoSpace = 6,
} GameArchiveStatus;

typedef struct {
    /// The entry's path inside the archive, UTF-8, '/' separated.
    char *name;
    /// Its size when the archive states it, -1 when it does not (a lone .gz).
    int64_t size;
    /// 1 when this entry's data is protected by a password.
    int encrypted;
    /// The bytes the rules read, else NULL: a disc descriptor whole, the
    /// first 64 KB of a `.bin` / `.md` no larger than a cartridge (see the top
    /// of this file).
    uint8_t *bytes;
    size_t byteCount;
    /// 1 when `name` is an old RAR's raw codepage bytes (no Unicode name
    /// stored), in which libarchive turned EVERY 0x5C byte into '/': a path
    /// separator there, but also the second byte of many Shift-JIS characters
    /// (ソ is 83 5C), which split the name. The Swift side puts those back on
    /// a Japanese phone (`GameArchive.Listing`).
    int legacyRARName;
} GameArchiveEntry;

typedef struct {
    GameArchiveEntry *entries;
    size_t count;
} GameArchiveListing;

/// Every regular file in the archive, in archive order, with the bytes of the
/// small entries the rules read. A lone .gz / .xz holds one file, which is
/// named after the archive without its last extension (`Game.gba.xz` gives
/// `Game.gba`) when the format stores no name of its own. On failure returns
/// NULL and sets `*status`. Free with `GameArchiveListingFree`.
GameArchiveListing *GameArchiveList(const char *path, GameArchiveStatus *status);

void GameArchiveListingFree(GameArchiveListing *listing);

/// Write entries into `directory`: `indices[i]` is an entry's position in
/// `GameArchiveList`'s order, `files[i]` the file name it is written under
/// (the caller passes the last component of the name it decoded, so a disc's
/// tracks end up side by side as its descriptor expects, and the file is where
/// the caller looks, whatever encoding the archive stored the name in). By
/// position and not by name for that reason: a legacy name is decoded in
/// Swift, never compared here. One pass, streamed: memory is a buffer, not an
/// entry. Every index must be found.
GameArchiveStatus GameArchiveExtract(const char *path, const size_t *indices,
                                     const char *const *files, size_t count,
                                     const char *directory);

#ifdef __cplusplus
}
#endif

#endif /* GameArchiveReader_h */
