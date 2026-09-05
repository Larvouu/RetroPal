// Host harness: runs RADiscFileReader against a real libchdr, on this machine,
// so the reader is not first executed on a device.
#include <stdio.h>
#include <string.h>
#include "RADiscFileReader.h"

static int fails = 0;
static void check(int ok, const char *what) {
    printf("  %-52s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) fails++;
}

static void run(const char *path, const char *label) {
    printf("%s (%s)\n", label, path);
    void *h = RADiscOpen(path);
    if (!h) { printf("  open FAILED\n"); fails++; return; }

    // Sector 16 of TRACK 1, which is where rcheevos sniffs the geometry.
    unsigned char buf[2352];
    RADiscSeek(h, 16 * 2352, SEEK_SET);
    size_t n = RADiscRead(h, buf, sizeof buf);
    check(n == sizeof buf, "read a whole sector at LBA 16");

    static const unsigned char sync[12] =
        {0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00};
    check(memcmp(buf, sync, 12) == 0, "sector 16 starts with the sync pattern");
    check(memcmp(buf + 16 + 1, "CD001", 5) == 0, "CD001 at the volume descriptor");

    int lba = (buf[16+16] << 24) | (buf[16+17] << 16) | (buf[16+18] << 8) | buf[16+19];
    check(lba == 16, "the sector reports LBA 16, so the pregap was honoured");

    // The subcode must never appear: a 2448 stride read as 2352 would put the
    // next sector's sync 96 bytes early and every later sector would drift.
    RADiscSeek(h, 17 * 2352, SEEK_SET);
    check(RADiscRead(h, buf, sizeof buf) == sizeof buf, "read the next sector");
    check(memcmp(buf, sync, 12) == 0, "sector 17 also starts on a sync pattern");
    lba = (buf[16+16] << 24) | (buf[16+17] << 16) | (buf[16+18] << 8) | buf[16+19];
    check(lba == 17, "sector 17 reports LBA 17, so the stride is right");

    // A read spanning a hunk boundary. 8 frames per hunk, so sector 7->8 crosses.
    RADiscSeek(h, 7 * 2352 + 2340, SEEK_SET);
    unsigned char span[24];
    check(RADiscRead(h, span, sizeof span) == sizeof span, "read across a hunk boundary");
    check(memcmp(span + 12, sync, 12) == 0, "the far side of the boundary is sector 8");

    check(RADiscTell(h) == 7 * 2352 + 2364, "tell tracks the flat position");

    // Past the end is a short read, not a crash and not invented bytes.
    RADiscSeek(h, 10000 * 2352, SEEK_SET);
    check(RADiscRead(h, buf, sizeof buf) == 0, "past the end reads nothing");

    RADiscClose(h);
}

int main(int argc, char **argv) {
    run(argv[1], "CHD, no pregap");
    run(argv[2], "CHD, 150-frame pregap on track 1");

    // The non-CHD path is the one every OTHER console hashes through.
    printf("ordinary file\n");
    void *h = RADiscOpen(argv[3]);
    check(h != NULL, "opens a plain file");
    if (h) {
        char b[5] = {0};
        RADiscSeek(h, 4, SEEK_SET);
        check(RADiscRead(h, b, 4) == 4, "reads from an offset");
        check(strcmp(b, "EFGH") == 0, "and gets the right bytes");
        check(RADiscTell(h) == 8, "tell agrees");
        RADiscClose(h);
    }
    check(RADiscOpen("/nope/missing.chd") == NULL, "a missing file opens as NULL");

    printf("\n%s\n", fails ? "FAILURES" : "all checks passed");
    return fails != 0;
}
