//
//  GameArchiveReader.c
//  EmulateurGBA
//
//  See GameArchiveReader.h. Every call opens the archive, walks it once front
//  to back, and closes it.
//

#include "GameArchiveReader.h"

#include <archive.h>
#include <archive_entry.h>

#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#if defined(__APPLE__)
#include <xlocale.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

/// What a disc descriptor weighs at most. A `.cue` is a few hundred bytes; a
/// megabyte is a game with thousands of tracks, and nothing real.
#define GA_DESCRIPTOR_MAX (1u << 20)
/// The largest Mega Drive cartridge (`GBAROMParser.megaDriveBinMaxBytes`). A
/// `.bin` or `.md` above it is not one and is never read: a PlayStation data
/// track runs to hundreds of megabytes.
#define GA_CARTRIDGE_MAX (16u << 20)
/// What is read of a `.bin` / `.md` that could be a cartridge: its START only.
/// The tests that decide (`GBAROMParser.isValidMDFile`, a 32X or Pico check)
/// read 16.5 KB at most, and a disc archive can hold dozens of small tracks, so
/// a whole 16 MB each would hold hundreds of megabytes at once.
#define GA_CARTRIDGE_PREFIX (64u << 10)

static const char *last_component(const char *name) {
    const char *slash = strrchr(name, '/');
    return slash ? slash + 1 : name;
}

static const char *extension(const char *name) {
    const char *base = last_component(name);
    const char *dot = strrchr(base, '.');
    return dot ? dot + 1 : "";
}

/// Which entries' bytes come with the listing, by extension: the descriptors
/// the disc grouper reads (whole, up to `GA_DESCRIPTOR_MAX`), and the two
/// cartridge extensions that need their bytes looked at, a `.md` that may be a
/// README and a `.bin` that may be a Mega Drive cartridge (their first
/// `GA_CARTRIDGE_PREFIX`, and only when no larger than a cartridge).
/// `*limit` is the largest entry read, `*keep` how much of it.
static int read_policy(const char *name, size_t *limit, size_t *keep) {
    const char *e = extension(name);
    if (!strcasecmp(e, "cue") || !strcasecmp(e, "toc") || !strcasecmp(e, "m3u")) {
        *limit = GA_DESCRIPTOR_MAX; *keep = GA_DESCRIPTOR_MAX; return 1;
    }
    if (!strcasecmp(e, "md") || !strcasecmp(e, "bin")) {
        *limit = GA_CARTRIDGE_MAX; *keep = GA_CARTRIDGE_PREFIX; return 1;
    }
    return 0;
}

/// A lone compressed file (`Game.gba.gz`, `Game.gba.xz`), as opposed to a
/// tarball: libarchive's "raw" format is enabled only for these, or any file
/// at all would open as an archive of itself.
static int is_lone_compressed(const char *path) {
    const char *e = extension(path);
    if (strcasecmp(e, "gz") && strcasecmp(e, "xz")) return 0;
    // A ".tar.gz" / ".tar.xz" is a tarball, read by the tar format.
    size_t n = strlen(path);
    return !(n >= 7 && (!strcasecmp(path + n - 7, ".tar.gz") || !strcasecmp(path + n - 7, ".tar.xz")));
}

/// A UTF-8 character set for the calling thread only, for the time of one
/// call. libarchive turns a 7z's names (UTF-16) and a zip's UTF-8 names into
/// the CURRENT locale's characters, and an app runs in the "C" locale, which
/// has no "é" and no "ポ": such a name did not convert, the entry came back
/// nameless and the whole archive was called damaged (audit, 2026-10-29,
/// measured on the host with this file). `uselocale` changes this thread
/// alone, never the process, so nothing else (the cores' number formatting)
/// sees it. Darwin names the locale "UTF-8" or "en_US.UTF-8", Linux "C.UTF-8";
/// when none exists the call runs as before.
typedef struct { locale_t utf8; locale_t previous; } GALocale;

static GALocale enter_utf8(void) {
    GALocale l = { (locale_t)0, (locale_t)0 };
    const char *names[] = { "UTF-8", "en_US.UTF-8", "C.UTF-8" };
    for (size_t i = 0; i < sizeof names / sizeof names[0] && !l.utf8; i++) {
        l.utf8 = newlocale(LC_CTYPE_MASK, names[i], (locale_t)0);
    }
    if (l.utf8) {
        l.previous = uselocale(l.utf8);
        // Not switched (uselocale returned 0): the locale is not in use and
        // goes now, and the call runs as before.
        if (!l.previous) { freelocale(l.utf8); l.utf8 = (locale_t)0; }
    }
    return l;
}

/// `previous` is the thread's own locale, or LC_GLOBAL_LOCALE when it had none,
/// which puts it back on the process's.
static void leave_utf8(GALocale l) {
    if (!l.utf8) return;
    uselocale(l.previous);
    freelocale(l.utf8);
}

static struct archive *open_archive(const char *path, GameArchiveStatus *status) {
    struct archive *a = archive_read_new();
    if (!a) { *status = GameArchiveCannotRead; return NULL; }
    archive_read_support_format_7zip(a);
    archive_read_support_format_rar(a);
    archive_read_support_format_rar5(a);
    archive_read_support_format_tar(a);
    // A .zip reaches this reader only when the app's own (ZIPExtractor) met a
    // compression method it does not implement: LZMA, BZIP2, XZ or Deflate64
    // inside a zip, which 7-Zip and WinRAR write (`GameArchive`).
    archive_read_support_format_zip(a);
    archive_read_support_filter_gzip(a);
    archive_read_support_filter_xz(a);
    archive_read_support_filter_bzip2(a);
    if (is_lone_compressed(path)) archive_read_support_format_raw(a);
    if (archive_read_open_filename(a, path, 1 << 16) != ARCHIVE_OK) {
        archive_read_free(a);
        *status = GameArchiveCannotRead;
        return NULL;
    }
    *status = GameArchiveOK;
    return a;
}

/// The status a failed read stands for. libarchive says "encrypted" in two
/// ways: on the entry (`archive_entry_is_encrypted`) and, for an archive whose
/// very NAMES are encrypted, only in its error, before any entry exists.
static GameArchiveStatus failure(struct archive *a, struct archive_entry *e) {
    if (e && archive_entry_is_encrypted(e)) return GameArchiveEncrypted;
    const char *message = archive_error_string(a);
    if (message && (strstr(message, "ncrypt") || strstr(message, "assword"))) return GameArchiveEncrypted;
    if (message && (strstr(message, "unsupported") || strstr(message, "not supported")
                    || strstr(message, "Unsupported"))) return GameArchiveUnsupported;
    return GameArchiveCannotRead;
}

/// The entry's name, UTF-8 when the archive says so, else as stored. A lone
/// compressed file's entry is libarchive's "data": it is named after the
/// archive minus its last extension instead.
static char *entry_name(struct archive *a, struct archive_entry *e, const char *path) {
    if (archive_format(a) == ARCHIVE_FORMAT_RAW) {
        const char *base = last_component(path);
        const char *dot = strrchr(base, '.');
        size_t n = dot ? (size_t)(dot - base) : strlen(base);
        char *name = malloc(n + 1);
        if (!name) return NULL;
        memcpy(name, base, n);
        name[n] = 0;
        return name;
    }
    const char *utf8 = archive_entry_pathname_utf8(e);
    const char *raw = utf8 ? utf8 : archive_entry_pathname(e);
    return raw ? strdup(raw) : NULL;
}

/// A raw entry's size, by reading it: at most `limit + 1` bytes, the first
/// `keep` of them kept in `entry->bytes`. Within the limit, `entry->size` is
/// the size read; past it, the size stays unknown (-1), larger than any
/// cartridge or descriptor, and nothing is kept. Returns 0 only when memory
/// ran out; a read error leaves the entry unread, as a short read does above.
static int read_unsized(struct archive *a, GameArchiveEntry *entry, size_t limit, size_t keep) {
    unsigned char *kept = malloc(keep ? keep : 1);
    if (!kept) return 0;
    unsigned char scratch[1 << 16];
    size_t total = 0;
    int failed = 0;
    while (total <= limit) {
        la_ssize_t n = archive_read_data(a, scratch, sizeof scratch);
        if (n == 0) break;
        if (n < 0) { failed = 1; break; }
        if (total < keep) {
            size_t room = keep - total;
            memcpy(kept + total, scratch, (size_t)n < room ? (size_t)n : room);
        }
        total += (size_t)n;
    }
    if (failed || total > limit) {
        free(kept);
        if (!failed) archive_read_data_skip(a);
        return 1;
    }
    entry->size = (int64_t)total;
    entry->bytes = kept;
    entry->byteCount = total < keep ? total : keep;
    return 1;
}

static int is_regular_file(struct archive *a, struct archive_entry *e) {
    if (archive_format(a) == ARCHIVE_FORMAT_RAW) return 1;
    return archive_entry_filetype(e) == AE_IFREG;
}

static GameArchiveListing *list_archive(const char *path, GameArchiveStatus *status) {
    struct archive *a = open_archive(path, status);
    if (!a) return NULL;

    GameArchiveListing *listing = calloc(1, sizeof *listing);
    size_t capacity = 0;
    struct archive_entry *e = NULL;
    int r;
    if (!listing) { archive_read_free(a); *status = GameArchiveCannotRead; return NULL; }

    while ((r = archive_read_next_header(a, &e)) == ARCHIVE_OK || r == ARCHIVE_WARN) {
        if (!is_regular_file(a, e)) { archive_read_data_skip(a); continue; }
        if (listing->count == capacity) {
            size_t grown = capacity ? capacity * 2 : 16;
            GameArchiveEntry *more = realloc(listing->entries, grown * sizeof *more);
            if (!more) { r = ARCHIVE_FATAL; break; }
            listing->entries = more;
            capacity = grown;
        }
        GameArchiveEntry *entry = &listing->entries[listing->count];
        memset(entry, 0, sizeof *entry);
        entry->name = entry_name(a, e, path);
        if (!entry->name) { r = ARCHIVE_FATAL; break; }
        entry->legacyRARName = archive_format(a) == ARCHIVE_FORMAT_RAR
            && archive_entry_pathname_utf8(e) == NULL;
        entry->size = archive_entry_size_is_set(e) ? archive_entry_size(e) : -1;
        entry->encrypted = archive_entry_is_encrypted(e) ? 1 : 0;
        listing->count++;

        size_t limit = 0, keep = 0;
        int wanted = read_policy(entry->name, &limit, &keep);
        // A lone .gz / .xz states no size (raw format, -1): the rules then took
        // its `.md` for a README and its `.bin` for a disc track, and the game
        // was not found (audit, 2026-10-29). Its size is learnt by reading it,
        // up to one byte past the limit: the first `keep` bytes are kept, the
        // rest only counted.
        if (wanted && entry->size < 0 && !entry->encrypted && archive_format(a) == ARCHIVE_FORMAT_RAW) {
            if (!read_unsized(a, entry, limit, keep)) { r = ARCHIVE_FATAL; break; }
            continue;
        }
        int small = wanted && entry->size >= 0 && (uint64_t)entry->size <= limit;
        if (!small || entry->encrypted) { archive_read_data_skip(a); continue; }
        size_t want = (size_t)entry->size < keep ? (size_t)entry->size : keep;
        entry->bytes = malloc(want ? want : 1);
        if (!entry->bytes) { r = ARCHIVE_FATAL; break; }
        size_t got = 0;
        while (got < want) {
            la_ssize_t n = archive_read_data(a, entry->bytes + got, want - got);
            if (n <= 0) break;
            got += (size_t)n;
        }
        if (got != want) {
            // Not fatal to the listing: the rules treat a descriptor they
            // cannot read as missing, which is what it is.
            free(entry->bytes);
            entry->bytes = NULL;
            continue;
        }
        entry->byteCount = got;
        // The rest of a cartridge's bytes are not wanted.
        archive_read_data_skip(a);
    }

    if (r != ARCHIVE_EOF) {
        *status = failure(a, e);
        archive_read_free(a);
        GameArchiveListingFree(listing);
        return NULL;
    }
    archive_read_free(a);
    *status = GameArchiveOK;
    return listing;
}

GameArchiveListing *GameArchiveList(const char *path, GameArchiveStatus *status) {
    GALocale l = enter_utf8();
    GameArchiveListing *listing = list_archive(path, status);
    leave_utf8(l);
    return listing;
}

void GameArchiveListingFree(GameArchiveListing *listing) {
    if (!listing) return;
    for (size_t i = 0; i < listing->count; i++) {
        free(listing->entries[i].name);
        free(listing->entries[i].bytes);
    }
    free(listing->entries);
    free(listing);
}

/// Stream the current entry's data into `dest`. Returns the status.
/// A failed write's status: the phone full, or anything else.
static GameArchiveStatus write_failure(int error) {
    return (error == ENOSPC || error == EDQUOT) ? GameArchiveNoSpace : GameArchiveWriteFailed;
}

static GameArchiveStatus write_entry(struct archive *a, struct archive_entry *e, const char *dest) {
    int fd = open(dest, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return write_failure(errno);
    char buffer[1 << 16];
    GameArchiveStatus status = GameArchiveOK;
    for (;;) {
        la_ssize_t n = archive_read_data(a, buffer, sizeof buffer);
        if (n == 0) break;
        if (n < 0) { status = failure(a, e); break; }
        const char *p = buffer;
        while (n > 0) {
            ssize_t w = write(fd, p, (size_t)n);
            if (w < 0) {
                if (errno == EINTR) continue;
                status = write_failure(errno);
                break;
            }
            p += w;
            n -= w;
        }
        if (status != GameArchiveOK) break;
    }
    if (close(fd) != 0 && status == GameArchiveOK) status = write_failure(errno);
    if (status != GameArchiveOK) unlink(dest);
    return status;
}

static GameArchiveStatus extract_archive(const char *path, const size_t *indices,
                                         const char *const *files, size_t count,
                                         const char *directory) {
    GameArchiveStatus status;
    struct archive *a = open_archive(path, &status);
    if (!a) return status;

    char *done = calloc(count ? count : 1, 1);
    if (!done) { archive_read_free(a); return GameArchiveCannotRead; }
    size_t remaining = count;
    size_t position = 0;   // among regular files, as GameArchiveList counts them
    struct archive_entry *e = NULL;
    int r = ARCHIVE_OK;

    while (remaining > 0 && ((r = archive_read_next_header(a, &e)) == ARCHIVE_OK || r == ARCHIVE_WARN)) {
        if (!is_regular_file(a, e)) { archive_read_data_skip(a); continue; }
        size_t here = position++;
        size_t index = count;
        for (size_t i = 0; i < count; i++) {
            if (!done[i] && indices[i] == here) { index = i; break; }
        }
        if (index == count) { archive_read_data_skip(a); continue; }
        if (archive_entry_is_encrypted(e)) { status = GameArchiveEncrypted; break; }

        // The file name only, never a path: nothing is written outside `directory`.
        const char *base = last_component(files[index]);
        if (!*base || !strcmp(base, ".") || !strcmp(base, "..")) { status = GameArchiveCannotRead; break; }
        size_t length = strlen(directory) + 1 + strlen(base) + 1;
        char *dest = malloc(length);
        if (!dest) { status = GameArchiveCannotRead; break; }
        snprintf(dest, length, "%s/%s", directory, base);
        status = write_entry(a, e, dest);
        free(dest);
        if (status != GameArchiveOK) break;
        done[index] = 1;
        remaining--;
    }

    if (status == GameArchiveOK && remaining > 0) {
        status = (r == ARCHIVE_EOF) ? GameArchiveNotFound : failure(a, e);
    }
    free(done);
    archive_read_free(a);
    return status;
}

GameArchiveStatus GameArchiveExtract(const char *path, const size_t *indices,
                                     const char *const *files, size_t count,
                                     const char *directory) {
    GALocale l = enter_utf8();
    GameArchiveStatus status = extract_archive(path, indices, files, count, directory);
    leave_utf8(l);
    return status;
}
