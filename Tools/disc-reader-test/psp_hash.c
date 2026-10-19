// Hashes a PSP game the way the app's RetroAchievements client does: rcheevos'
// own PSP hash (PARAM.SFO + the boot executable, found through its CD reader)
// over the app's file reader (RADiscFileReader.c), told the console is the PSP
// as RAClient tells it for a `.cso`. Usage: psp_hash <file>...
#include <stdio.h>
#include <string.h>
#include "rc_hash.h"
#include "rc_consoles.h"
#include "RADiscFileReader.h"

int main(int argc, char **argv) {
    int bad = 0;
    for (int i = 1; i < argc; i++) {
        rc_hash_iterator_t it;
        char hash[33] = {0};
        rc_hash_initialize_iterator(&it, argv[i], NULL, 0);
        it.callbacks.filereader.open = RADiscOpen;
        it.callbacks.filereader.seek = RADiscSeek;
        it.callbacks.filereader.tell = RADiscTell;
        it.callbacks.filereader.read = RADiscRead;
        it.callbacks.filereader.close = RADiscClose;
        int ok = rc_hash_generate(hash, RC_CONSOLE_PSP, &it);
        rc_hash_destroy_iterator(&it);
        printf("%s %s\n", ok ? hash : "(none)", argv[i]);
        if (!ok) bad++;
    }
    return bad;
}
