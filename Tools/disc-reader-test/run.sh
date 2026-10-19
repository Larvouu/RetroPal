#!/usr/bin/env bash
#
# Runs the achievement disc reader (RADiscFileReader.c) on THIS machine.
#
# WHY THIS EXISTS. That file decompresses CHD hunks, walks a track's metadata
# and maps a flat byte stream onto 2352-byte sectors, and none of it can be
# reached from the app's unit tests: it is C, it needs a real libchdr, and it
# needs a real `.chd` to read. Without this it would first execute on a device,
# where the only symptom of getting the sector maths wrong is that a game
# quietly earns no achievements. It already caught one class of that: the
# pregap case below is the one that would break roughly one disc in fifty and
# be indistinguishable from "RetroAchievements has no set for this game".
#
# The discs are SYNTHESISED, not shipped: `make_chd.py` writes an uncompressed
# CHD v5 from libchdr's own header and map layout, so this tool carries no
# copyrighted bytes and no fixture to go stale.
#
# Needs the host build of the core, for its libchdr:
#     HOST=1 ./Vendor/pcsx-ios/build.sh
#
set -euo pipefail
cd "$(dirname "$0")/../.."

LIB="Vendor/pcsx-ios/lib/libpcsx-core-host.a"
if [ ! -f "$LIB" ]; then
    echo "ERROR: $LIB is missing. This tool links against the core's own libchdr"
    echo "       rather than a second copy of it. Build the host core first:"
    echo "           HOST=1 ./Vendor/pcsx-ios/build.sh"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 Tools/disc-reader-test/make_chd.py "$WORK/plain.chd" 0
python3 Tools/disc-reader-test/make_chd.py "$WORK/pregap.chd" 150
printf 'ABCDEFGHIJKLMNOP' > "$WORK/plain.bin"

CC="${CC:-cc}"
"$CC" -O1 -Wall \
    -I EmulateurGBA/Data/RetroAchievements \
    -I Vendor/pcsx_rearmed/deps/libchdr/include \
    Tools/disc-reader-test/host.c \
    EmulateurGBA/Data/RetroAchievements/RADiscFileReader.c \
    "$LIB" -lz -lm -lpthread -o "$WORK/host"

"$WORK/host" "$WORK/plain.chd" "$WORK/pregap.chd" "$WORK/plain.bin"

# THE PSP's `.cso` (2026-10-10). A PSP disc is hashed by rcheevos itself
# (PARAM.SFO and the boot executable) through this reader, so the one thing to
# prove is that a `.cso` reads as the ISO it was made from: hashed both ways,
# the two must agree, with 2 KB frames and with 8 KB frames shifted by an index
# alignment, compressed and plain frames both. It needs a real PSP ISO, which
# never enters the repository, so it runs only when one is named:
#     Tools/disc-reader-test/run.sh /path/to/game.iso
if [ $# -ge 1 ]; then
    R=Vendor/rcheevos
    "$CC" -O1 -Wall -Wno-unused-function \
        -I EmulateurGBA/Data/RetroAchievements -I "$R/include" -I "$R/src" \
        -I Vendor/pcsx_rearmed/deps/libchdr/include \
        Tools/disc-reader-test/psp_hash.c \
        EmulateurGBA/Data/RetroAchievements/RADiscFileReader.c \
        "$R"/src/rhash/*.c "$R/src/rc_compat.c" "$R/src/rc_util.c" \
        "$LIB" -lz -lm -lpthread -o "$WORK/psp_hash"
    python3 Tools/disc-reader-test/make_cso.py "$1" "$WORK/game.cso"
    python3 Tools/disc-reader-test/make_cso.py "$1" "$WORK/game-8k.cso" --frame 8192 --align 2
    OUT="$("$WORK/psp_hash" "$1" "$WORK/game.cso" "$WORK/game-8k.cso")"
    echo "$OUT"
    if [ "$(echo "$OUT" | awk '{print $1}' | sort -u | wc -l)" -eq 1 ] && ! echo "$OUT" | grep -q '(none)'; then
        echo "PSP .cso: the same hash as the ISO, both layouts"
    else
        echo "PSP .cso: HASHES DIFFER"; exit 1
    fi
else
    echo "PSP .cso: SKIPPED (name a PSP ISO to run it)"
fi
