#!/bin/bash
# Build the Mega Drive core (BlastEm, libretro build) as a static library for
# iOS (arm64).
#
# Usage:
#   ./build.sh              build lib/libmd-core.a for iOS arm64 (needs Xcode)
#   ./build.sh clean        remove the build artefacts and the lib
#   HOST=1 ./build.sh       build lib/libmd-core-host.a for THIS machine (the
#                           same sources, choices and renaming), for
#                           verification and Tools/md-bench
#
# THE SOURCE. BlastEm's upstream is Mercurial (https://www.retrodev.com/repos/blastem)
# with no official git mirror, so it cannot be a submodule like the other cores.
# Vendor/blastem holds the pinned source as plain files, exactly as upstream's
# archive of that revision ships it; its .hg_archival.txt names the revision
# (node 9b71c8bd2065, 14 changesets after v1.0.0, taken 2026-10-07). Nothing in
# that folder is edited: the build runs on a COPY (build/src-<platform>), since
# the makefile generates sources and objects inside its own tree, and our
# patches (below) are applied to the copy. To move the pin, replace the folder
# with a newer archive (.../archive/<node>.tar.gz) and re-run Tools/md-bench
# before anything reaches a phone.
#
# WHAT IS BUILT. The makefile's libretro library objects (LIBOBJS), nothing of
# the standalone emulator (SDL, OpenGL, the Nuklear UI). Its CPU cores:
#   68000, Z80   NEW_CORE: interpreters GENERATED IN C at build time by
#                cpu_dsl.py from m68k.cpu and z80.cpu. Off x86 this is the only
#                path the makefile has (the x86 recompilers are never built), so
#                there is no JIT and no assembly: the App Store's rule and
#                BlastEm's own design agree. CPU=arm64 below selects it.
#   SH-2 (32X), uPD78K2 (LaserActive), SVP   the same DSL, the same C.
# Generating m68k.c takes Python 3 (Xcode's /usr/bin/python3) and produces a
# ~1.9 million-line file, which is most of the build time.
#
# Link-time optimisation is off (NOLTO=1) for the reason n64-ios/build.sh gives:
# the prelink below is an `ld -r`, which on all-bitcode input writes merged
# bitcode without hiding a single symbol.
#
# THREE STUBS (blastem-stubs.c): the libretro objects call the standalone
# emulator's oscilloscope and VDP debug window, which are not part of them.
# RetroArch loads cores lazily, so upstream never meets the missing names; a
# static link does. Each call site is unreachable from a libretro frontend (see
# the stubs file), and the export check below proves no other name is missing.
#
# SYMBOL ISOLATION, as for the N64: md_symbols.h renames the libretro API to
# md_retro_* (PCSX-ReARMed and Mupen64Plus-Next define the same names), and the
# whole core is pre-linked into one object exporting only those names.
#
# OUTPUT. The compile is long and loud (the generated 68000 interpreter alone
# raises hundreds of harmless warnings), so it goes to build/build-<platform>.log
# and the terminal gets the steps, the first errors and a closing summary.
#
# PATCHES: patches/*.patch, applied in name order to the copy, each one
# explaining itself in its header. GPL-3.0 asks that changes be stated, and the
# patch files are that statement. The stubs and the renaming are build glue
# around the core, not changes to it.
#   0001  reset the per-game statics at each load (the app keeps the core
#         linked and loads game after game into it; RetroArch reloads the
#         library, so upstream never meets it)
#   0002  a loaded state cancels a pending soft reset (the app resets each
#         core after loading a game and then loads the Resume or slot state;
#         BlastEm's reset waits for a random cycle the state does not carry,
#         and fired after the load, rebooting the game)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MD_SRC="$SCRIPT_DIR/../blastem"
LIB_DIR="$SCRIPT_DIR/lib"
BUILD_DIR="$SCRIPT_DIR/build"
SYMBOLS_H="$SCRIPT_DIR/md_symbols.h"
STUBS_C="$SCRIPT_DIR/blastem-stubs.c"

HOST="${HOST:-0}"
if [ "$HOST" = "1" ]; then
    OUTPUT_LIB="$LIB_DIR/libmd-core-host.a"
    SUFFIX="host"
else
    OUTPUT_LIB="$LIB_DIR/libmd-core.a"
    SUFFIX="ios"
fi
WORK_SRC="$BUILD_DIR/src-$SUFFIX"
UPSTREAM_LIB="$BUILD_DIR/upstream-$SUFFIX.a"
PRELINKED_OBJ="$BUILD_DIR/md-core-$SUFFIX.o"

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning..."
    rm -rf "$LIB_DIR" "$BUILD_DIR"
    echo "Done."
    exit 0
fi

if [ ! -f "$MD_SRC/libblastem.c" ] || [ ! -f "$MD_SRC/.hg_archival.txt" ]; then
    echo "ERROR: BlastEm sources not found at $MD_SRC"
    exit 1
fi

PATCH_DIR="$SCRIPT_DIR/patches"
# What the library was built from, beside the library: a pull that brings a
# new or changed patch must rebuild it, not keep the old one as "already
# built".
PATCHES_STAMP="$LIB_DIR/.patches-$SUFFIX"
PATCHES_NOW="$(cat "$PATCH_DIR"/*.patch 2>/dev/null | cksum | awk '{ print $1 "-" $2 }')"
if [ -f "$OUTPUT_LIB" ]; then
    if [ "$(cat "$PATCHES_STAMP" 2>/dev/null)" = "$PATCHES_NOW" ]; then
        echo "$(basename "$OUTPUT_LIB") already built. Run '$0 clean' to rebuild."
        exit 0
    fi
    echo "The patches changed since $(basename "$OUTPUT_LIB") was built - rebuilding it."
    rm -f "$OUTPUT_LIB"
fi

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found; cpu_dsl.py generates the CPU cores."; exit 1; }

mkdir -p "$LIB_DIR" "$BUILD_DIR"
rm -rf "$WORK_SRC" "$UPSTREAM_LIB" "$PRELINKED_OBJ"
cp -R "$MD_SRC" "$WORK_SRC"

# A patch that does not apply EXACTLY (-F0: no fuzz) aborts the build rather
# than producing a core that differs from the one tested: the pin moved under
# it, and the patch must be re-made against the new source. `patch` and not
# `git apply`, which inside this repository would resolve the paths against
# the repository's root rather than the copy. -t: never ask a question.
for patch in "$PATCH_DIR"/*.patch; do
    [ -e "$patch" ] || continue
    if ! patch -d "$WORK_SRC" -p1 -s -t -F0 < "$patch"; then
        echo "ERROR: $(basename "$patch") does not apply to the pinned BlastEm."
        exit 1
    fi
    echo "Patch applied: $(basename "$patch")"
done
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# --- the ROM database, generated here rather than by the makefile ------------
#
# rom.db (per-game mappers, EEPROM, controllers) is compiled in as one C string.
# The makefile's rule writes it with GNU sed argument order (`sed FILE -e ...`),
# which macOS's BSD sed refuses. This is the same transformation: every line
# quoted with its double quotes escaped, the whole a `const char rom_db_data[]`.
# Being newer than rom.db, the file is taken as up to date by make.
python3 - "$WORK_SRC/rom.db" "$WORK_SRC/rom.db.c" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
if lines and lines[-1] == "":
    lines.pop()
out = ['"' + l.replace('"', '\\"') + '\\n"' for l in lines]
out[0] = "const char rom_db_data[] = " + out[0]
out[-1] += ";"
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out) + "\n")
PY

# --- the library's object list, read from the makefile itself -----------------
#
# The makefile's own goal links a SHARED library, which neither an iOS app nor
# the prelink below wants (and which fails on the stubbed names). Its object
# list is printed through a second makefile instead, and those objects become
# the goals: every compile flag still comes from upstream's makefile.
cat > "$BUILD_DIR/print-libobjs.mk" <<'MK'
print-libobjs:
	@echo $(LIBOBJS:%.o=$(LIBOBJDIR)/%.o)
MK

# The choices shared by both builds. CPU=arm64 selects NEW_CORE on either
# machine (it is any non-x86 value). The extra compiler flags travel in CC:
# CFLAGS given on the command line would REPLACE the makefile's own
# (-std=gnu99, the warnings it makes errors, NEW_CORE), not add to them.
#
# -fno-common: BlastEm declares globals without an initialiser (config,
# current_system, MCLKS_PER_68K...). Compiled as COMMON symbols, which the
# first Mac build did, the Mach-O prelink below keeps them global whatever the
# export list says: eleven of them reached the export check on 2026-10-08.
# As ordinary definitions they are hidden like every other name. GCC and
# clang on Linux already default to this, which is why the host build passed.
MAKE_CHOICES=(CPU=arm64 NOLTO=1)
LOG="$BUILD_DIR/build-$SUFFIX.log"

if [ "$HOST" = "1" ]; then
    echo "=== Building BlastEm for THIS HOST (verification only) ==="
    CC_LINE="${MD_HOST_CC:-cc} -fno-common -include $SYMBOLS_H"
else
    command -v xcrun >/dev/null 2>&1 || { echo "ERROR: xcrun not found. This path needs Xcode."; exit 1; }
    IOSSDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    echo "=== Building BlastEm core for iOS arm64 ==="
    echo "SDK: $IOSSDK"
    CC_LINE="$(xcrun --sdk iphoneos --find clang) -arch arm64 -isysroot $IOSSDK -miphoneos-version-min=16.0 -fno-common -include $SYMBOLS_H"
fi

# Deduplicated, in order: upstream lists tern.o twice (CONFIGOBJS and TRANSOBJS).
# Make drops the repeat when it links ($^); ar would archive it twice.
OBJS="$(make -s -C "$WORK_SRC" -f Makefile -f "$BUILD_DIR/print-libobjs.mk" "${MAKE_CHOICES[@]}" print-libobjs 2>/dev/null | tail -1 | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
OBJ_COUNT="$(printf '%s\n' $OBJS | grep -c '\.o$' || true)"
if [ "$OBJ_COUNT" -lt 60 ]; then
    echo "ERROR: read only $OBJ_COUNT library objects from the makefile; the list or its parsing is broken."
    exit 1
fi
for required in libblastem.o m68k.o z80.o genesis.o vdp.o ym2612.o; do
    if ! printf '%s\n' $OBJS | grep -q "/$required\$"; then
        echo "ERROR: $required is not among the library objects."
        exit 1
    fi
done
# The x86 recompilers must not be there: their presence would mean CPU did not
# select NEW_CORE.
if printf '%s\n' $OBJS | grep -qE '/(m68k_core_x86|z80_to_x86|gen_x86|backend_x86)\.o$'; then
    echo "ERROR: x86 recompiler objects are in the list; NEW_CORE was not selected."
    exit 1
fi

echo "Compiling $OBJ_COUNT objects on $JOBS jobs (several minutes; full log: $LOG)..."
START_SECONDS=$SECONDS
# shellcheck disable=SC2086
if ! make -C "$WORK_SRC" "${MAKE_CHOICES[@]}" CC="$CC_LINE" -j "$JOBS" $OBJS > "$LOG" 2>&1; then
    echo "ERROR: the compile failed. The first errors, from $LOG:"
    grep -nE '(error|Error)[: ]' "$LOG" | head -15 | sed 's/^/         /'
    echo "       The log's last lines:"
    tail -10 "$LOG" | sed 's/^/         /'
    exit 1
fi
echo "Compiled in $(( (SECONDS - START_SECONDS) / 60 )) min $(( (SECONDS - START_SECONDS) % 60 )) s, $(grep -c 'warning:' "$LOG" || true) compiler warnings (in the log, upstream's)."

# The same compiler line without the rename header (the stubs define no
# libretro name). Unquoted on purpose: it is a command and its arguments.
# shellcheck disable=SC2086
${CC_LINE%% -include*} -fpic -O2 -c "$STUBS_C" -o "$BUILD_DIR/blastem-stubs-$SUFFIX.o"

if [ "$HOST" = "1" ]; then AR_BIN="ar"; NM_BIN="nm"; else AR_BIN="$(xcrun --sdk iphoneos --find ar)"; NM_BIN="$(xcrun --sdk iphoneos --find nm)"; fi
# shellcheck disable=SC2086
(cd "$WORK_SRC" && "$AR_BIN" rcs "$UPSTREAM_LIB" $OBJS "$BUILD_DIR/blastem-stubs-$SUFFIX.o")

# --- prelink into one object that exports only md_retro_* -------------------------

EXPORT_NAMES="$(sed -nE 's/^#define[[:space:]]+retro_[a-z_]+[[:space:]]+(md_retro_[a-z_]+)[[:space:]]*$/\1/p' "$SYMBOLS_H")"
EXPORT_COUNT="$(printf '%s\n' "$EXPORT_NAMES" | grep -c . || true)"
if [ "$EXPORT_COUNT" -ne 25 ]; then
    echo "ERROR: read $EXPORT_COUNT names from md_symbols.h, expected 25; the list or its parsing is broken."
    exit 1
fi

if [ "$HOST" = "1" ]; then
    printf '%s\n' $EXPORT_NAMES > "$BUILD_DIR/exports-elf.txt"
    ld -r --whole-archive "$UPSTREAM_LIB" --no-whole-archive -o "$PRELINKED_OBJ"
    objcopy --keep-global-symbols="$BUILD_DIR/exports-elf.txt" "$PRELINKED_OBJ"
else
    printf '_%s\n' $EXPORT_NAMES > "$BUILD_DIR/exports-macho.txt"
    "$(xcrun --sdk iphoneos --find clang)" -arch arm64 -isysroot "$IOSSDK" -miphoneos-version-min=16.0 \
        -r -nostdlib \
        -Wl,-force_load,"$UPSTREAM_LIB" \
        -Wl,-exported_symbols_list,"$BUILD_DIR/exports-macho.txt" \
        -o "$PRELINKED_OBJ"
fi

# --- verify the exports -------------------------------------------------------------
#
# FATAL, as for the N64: the symbol table IS the property being built. A stray
# global is a duplicate-symbol failure at the app's link (BlastEm defines
# `config`, `current_system` and a zlib), or one core calling another's helper.

# The library itself is written only once every check has passed: a failed run
# leaves nothing behind that the next run would take as already built.

if ! DEFINED="$("$NM_BIN" -g "$PRELINKED_OBJ" 2>&1)"; then
    echo "ERROR: could not read symbols with '$NM_BIN', so the export check could"
    echo "       not run. nm said:"
    printf '%s\n' "$DEFINED" | head -5 | sed 's/^/         /'
    exit 1
fi
DEFINED="$(printf '%s\n' "$DEFINED" | awk 'NF >= 3 && $2 != "U" { print $3 }' | sed 's/^_//' | sort -u)"
EXPECTED="$(printf '%s\n' $EXPORT_NAMES | sort -u)"
EXTRA="$(comm -23 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$EXPECTED"))"
MISSING="$(comm -13 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$EXPECTED"))"
if [ -n "$EXTRA" ]; then
    echo "ERROR: the core exports globals besides its md_retro_* entry points"
    echo "       (nm's type letter first: C = common, D/S = data, T = code):"
    "$NM_BIN" -g "$PRELINKED_OBJ" | awk 'NF >= 3 && $2 != "U" { n = $3; sub(/^_/, "", n); print $2, n }' \
        | grep -vE ' md_retro_[a-z_]+$' | head -20 | sed 's/^/         /'
    exit 1
fi
if [ -n "$MISSING" ]; then
    echo "ERROR: these entry points are listed in md_symbols.h but not defined:"
    printf '%s\n' "$MISSING" | sed 's/^/         /'
    exit 1
fi
echo "Exports: exactly the $EXPORT_COUNT md_retro_* entry points."

# What the core still needs from outside must be the C library and nothing of
# the standalone emulator: an SDL, OpenGL or GUI name here would be code the app
# cannot link, and any other unknown name means the stubs are incomplete.
UNDEFINED="$("$NM_BIN" -u "$PRELINKED_OBJ" 2>/dev/null | awk '{ print $NF }' | sed 's/^_//' | sort -u)"
BAD_REFS="$(printf '%s\n' "$UNDEFINED" | grep -E '^(SDL_|gl[A-Z]|egl[A-Z]|render_|nk_|scope_|debug_)' || true)"
if [ -n "$BAD_REFS" ]; then
    echo "ERROR: the core still references the standalone emulator's code:"
    printf '%s\n' "$BAD_REFS" | head -20 | sed 's/^/         /'
    exit 1
fi
echo "External references: $(printf '%s\n' "$UNDEFINED" | grep -c . || true), none from SDL, OpenGL or the UI."

if [ "$HOST" != "1" ]; then
    if ! lipo -info "$PRELINKED_OBJ" 2>/dev/null | grep -q 'arm64'; then
        echo "ERROR: the core is not arm64."
        lipo -info "$PRELINKED_OBJ" || true
        exit 1
    fi
fi

rm -f "$OUTPUT_LIB"
"$AR_BIN" rcs "$OUTPUT_LIB" "$PRELINKED_OBJ"
printf '%s\n' "$PATCHES_NOW" > "$PATCHES_STAMP"

echo "Built $OUTPUT_LIB ($(( $(wc -c < "$OUTPUT_LIB") / 1048576 )) MB) from $(sed -n 's/^node: \(.\{12\}\).*/\1/p' "$MD_SRC/.hg_archival.txt")."
