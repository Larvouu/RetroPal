#!/bin/bash
# Build the PCSX-ReARMed core as a static library for iOS (arm64).
#
# Usage:
#   ./build.sh              build lib/libpcsx-core.a for iOS arm64 (needs Xcode)
#   ./build.sh clean        remove the build artefacts and the lib
#   HOST=1 ./build.sh       build lib/libpcsx-core-host.a for THIS machine
#
# WHY THIS SCRIPT IS SO MUCH SHORTER THAN mesen-ios/build.sh. MesenCE ships no
# CMake and no library target, only a makefile that builds the .NET UI and the
# SDL frontend beside the core, so we had to compile its translation units
# ourselves and maintain the file list. PCSX-ReARMed is the opposite case: it
# already carries a first-class `platform=ios-arm64` target in Makefile.libretro
# that sets precisely the configuration we need, and it is the same target
# RetroArch's own iOS build uses. Re-deriving a file list here would create a
# second source of truth for no gain, so this script drives upstream's makefile
# and asserts the settings that matter instead of restating them.
#
# THE FOUR SETTINGS THAT MATTER, and why:
#
#   DYNAREC=0      The App Store forbids JIT, so the recompilers (ari64,
#                  lightrec) are unavailable to us and the core runs its
#                  interpreter. The ios-arm64 target already sets this; we
#                  assert it below rather than trust it, because a silent
#                  change upstream would produce a library that cannot ship.
#   BUILTIN_GPU=neon
#                  The ARM-assembly software renderer (Exophase). It is the
#                  reason this core was chosen: it fills a framebuffer, which
#                  is what EmulatorMetalView already consumes. Also the setting
#                  that raises the maximum picture to 1024x512.
#   STATIC_LINKING=1
#                  We link the core into the app. Upstream's default target is
#                  a .dylib, which iOS will not let us load.
#   MINVERSION     Upstream targets iOS 8. Our floor is 16, and the deployment
#                  target has to match the app's or the link fails.
#
# WHY THE SUBMODULE IS NOT RECURSIVE. pcsx_rearmed carries one submodule,
# frontend/libpicofe, which belongs to the standalone SDL/handheld frontend.
# Verified in the upstream Makefile: the `PLATFORM = libretro` block (the one
# Makefile.libretro selects) never references it. Cloning it would add weight
# to every checkout, and to the public GPL snapshot, for code we do not build.
#
# PATCHES. There are none, and that is worth stating: MesenCE needed one to be
# driven a frame at a time, while libretro's retro_run() IS one frame by
# contract, so nothing here has to be changed to fit our loop. If a patch ever
# becomes necessary it goes in patches/ beside the pin, exactly as MesenCE's
# does, AND the `legal.compliance` string x15 has to change with it: it names
# which cores we modify, and GPL asks that it be accurate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PCSX_SRC="$SCRIPT_DIR/../pcsx_rearmed"
LIB_DIR="$SCRIPT_DIR/lib"

HOST="${HOST:-0}"
if [ "$HOST" = "1" ]; then
    OUTPUT_LIB="$LIB_DIR/libpcsx-core-host.a"
else
    OUTPUT_LIB="$LIB_DIR/libpcsx-core.a"
fi

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning..."
    # The makefile builds in-tree (upstream's .gitignore covers *.o / *.d / *.a,
    # so this leaves no dirty submodule either way).
    if [ -d "$PCSX_SRC" ]; then
        make -C "$PCSX_SRC" -f Makefile.libretro clean >/dev/null 2>&1 || true
        find "$PCSX_SRC" \( -name '*.o' -o -name '*.d' \) -delete 2>/dev/null || true
    fi
    rm -rf "$LIB_DIR"
    echo "Done."
    exit 0
fi

if [ ! -f "$PCSX_SRC/Makefile.libretro" ]; then
    echo "ERROR: PCSX-ReARMed sources not found at $PCSX_SRC"
    echo "Run: git submodule update --init Vendor/pcsx_rearmed"
    exit 1
fi

# --- patches ------------------------------------------------------------------
#
# Same shape as mesen-ios/build.sh, and deliberately kept even though the
# directory is empty: a patch that applies neither way must abort the build
# rather than silently produce a core that differs from the one we tested.
# Runs BEFORE the "already built" check, because a machine holding a library
# from a previous build would otherwise skip the patch and keep running the
# unpatched core.

PATCH_DIR="$SCRIPT_DIR/patches"
PATCH_APPLIED_NOW=0
if [ -d "$PATCH_DIR" ]; then
    for patch in "$PATCH_DIR"/*.patch; do
        [ -e "$patch" ] || continue
        name="$(basename "$patch")"
        if git -C "$PCSX_SRC" apply --reverse --check "$patch" 2>/dev/null; then
            echo "Patch already applied: $name"
        elif git -C "$PCSX_SRC" apply "$patch" 2>/dev/null; then
            echo "Patch applied: $name"
            PATCH_APPLIED_NOW=1
        else
            echo "ERROR: $name applies neither way."
            echo "The pinned core has moved under the patch. Re-make it against the"
            echo "new source rather than building something that silently differs."
            exit 1
        fi
    done
fi

if [ "$PATCH_APPLIED_NOW" = "1" ] && [ -f "$OUTPUT_LIB" ]; then
    echo "The core was patched after this library was built - rebuilding it."
    rm -f "$OUTPUT_LIB"
fi

# Skip if already built (use 'clean' to force a rebuild), matching the other two.
if [ -f "$OUTPUT_LIB" ]; then
    echo "$(basename "$OUTPUT_LIB") already built. Run '$0 clean' to rebuild."
    exit 0
fi

mkdir -p "$LIB_DIR"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# --- build --------------------------------------------------------------------

if [ "$HOST" = "1" ]; then
    # Verification only: compiles the same sources with the host compiler so the
    # tree, the makefile invocation and the submodule pin can be checked on any
    # machine before anyone spends Mac time. The library it produces is useless
    # to the app and is never linked. HAVE_PHYSICAL_CDROM and USE_LIBRETRO_VFS
    # are forced off to match the iOS target, so the two builds cover the same
    # translation units.
    echo "=== Building PCSX-ReARMed for THIS HOST (verification only) ==="
    make -C "$PCSX_SRC" -f Makefile.libretro \
        platform=unix \
        STATIC_LINKING=1 \
        HAVE_CHD=1 \
        HAVE_PHYSICAL_CDROM=0 \
        USE_LIBRETRO_VFS=0 \
        DYNAREC=0 \
        TARGET="$OUTPUT_LIB" \
        -j "$JOBS"
else
    command -v xcrun >/dev/null 2>&1 || { echo "ERROR: xcrun not found. This path needs Xcode."; exit 1; }
    IOSSDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    echo "=== Building PCSX-ReARMed core for iOS arm64 ==="
    echo "SDK: $IOSSDK"

    # platform=ios-arm64 brings ARCH=arm64, BUILTIN_GPU=neon, DYNAREC=0 and
    # HAVE_PHYSICAL_CDROM=0 with it. AR is pointed at the SDK's own tool rather
    # than whatever `ar` is first on PATH.
    make -C "$PCSX_SRC" -f Makefile.libretro \
        platform=ios-arm64 \
        IOSSDK="$IOSSDK" \
        MINVERSION=-miphoneos-version-min=16.0 \
        STATIC_LINKING=1 \
        HAVE_CHD=1 \
        AR="$(xcrun --sdk iphoneos --find ar)" \
        TARGET="$OUTPUT_LIB" \
        -j "$JOBS"
fi

# --- verify -------------------------------------------------------------------
#
# A static library that links but misbehaves is the failure mode this catches.
# Five checks, each for a way the build can go quietly wrong.
#
# Both listings are taken ONCE, into variables, rather than piped per check.
# `nm ... | grep -q` looks correct and is not: grep exits at the first match and
# closes the pipe, nm dies of SIGPIPE, and with `set -o pipefail` the whole
# pipeline reports failure. Every check would then report a healthy library as
# broken, which is exactly what the first run of this script did.
#
# THE SECOND LESSON, and it cost a Mac build: a check that cannot tell "the
# thing is broken" from "I could not look" is worse than no check. The symbol
# check below used to swallow nm's stderr and its exit code, so a machine where
# `nm` simply did not run reported a PERFECT library as missing every one of its
# entry points, and said nothing about why. The structural checks are therefore
# the ones that fail the build, because `ar t` is portable and its output format
# is fixed; the symbol check reports what it found and warns when it could not
# look, rather than guessing.

if [ ! -f "$OUTPUT_LIB" ]; then
    echo "ERROR: the makefile reported success but produced no library."
    exit 1
fi

MEMBERS="$(ar t "$OUTPUT_LIB" 2>/dev/null || true)"
if [ -z "$MEMBERS" ]; then
    echo "ERROR: 'ar t' listed nothing. The archive exists but is not readable"
    echo "       as an archive, which means it is not what the makefile thinks."
    exit 1
fi

# 1. The libretro frontend must be IN the archive. Without it the app links
#    against a core with no entry points, and fails much later with a message
#    that points at our bridge rather than at this.
#
#    Checked as an archive MEMBER rather than by symbol, for the same reason as
#    the dynarec check below: `ar t` speaks one format everywhere, while nm's
#    output differs between ELF and Mach-O and between toolchain versions.
if ! printf '%s\n' "$MEMBERS" | grep -q '^libretro\.o$'; then
    echo "ERROR: libretro.o absent - the core was built without its frontend."
    exit 1
fi

# 2. The NEON software renderer has to be in the archive. It is the whole reason
#    this core was chosen, and if the platform block ever stops setting
#    BUILTIN_GPU the makefile falls back to `peops` without a word: the build
#    still succeeds, and the app just runs a much slower renderer.
#    `psx_gpu_if.o` is the invariant (the makefile adds it for neon on every
#    architecture); `gpulib_if.o` is what peops and unai add instead.
if ! printf '%s\n' "$MEMBERS" | grep -q '^psx_gpu_if\.o$'; then
    echo "ERROR: psx_gpu_if.o absent - BUILTIN_GPU did not resolve to neon."
    exit 1
fi
if printf '%s\n' "$MEMBERS" | grep -q '^gpulib_if\.o$'; then
    echo "ERROR: gpulib_if.o present - a fallback renderer (peops/unai) was built."
    exit 1
fi

# 3. No recompiler, on either build. The App Store forbids JIT, so a dynarec in
#    the archive is code we would ship and never be allowed to run.
#    Checked by archive MEMBER and not by symbol, deliberately: `emu_if.o` is
#    compiled either way and exports new_dynarec_* stubs even under
#    -DDRC_DISABLE, so a symbol check fails a perfectly correct build. The real
#    recompiler is a separate object, and the makefile names it exactly.
if printf '%s\n' "$MEMBERS" | grep -qE '^(new_dynarec|pcsxmem|linkage_arm|linkage_arm64|lightrec|interpreter|emitter|lightning)\.o$'; then
    echo "ERROR: recompiler objects present - DYNAREC did not resolve to 0."
    echo "The App Store forbids JIT; this library cannot ship."
    printf '%s\n' "$MEMBERS" | grep -E '^(new_dynarec|pcsxmem|linkage_arm|linkage_arm64|lightrec|emitter|lightning)\.o$'
    exit 1
fi
if ! printf '%s\n' "$MEMBERS" | grep -q '^psxinterpreter\.o$'; then
    echo "ERROR: psxinterpreter.o absent - there is no CPU to run the game."
    exit 1
fi

# 4. libchdr has to be in the archive, and it is not only the core that needs it.
#    HAVE_CHD=1 is what puts it there, and if that ever stops resolving the
#    makefile drops CHD support without a word: the core simply refuses to open
#    a `.chd`, and the app's RetroAchievements reader (RADiscFileReader.c, which
#    calls chd_open directly) fails to LINK. That second failure is loud, but it
#    points at our code rather than at this flag, so name it here.
if ! printf '%s\n' "$MEMBERS" | grep -q '^libchdr_chd\.o$'; then
    echo "ERROR: libchdr_chd.o absent - HAVE_CHD did not resolve to 1."
    echo "The core cannot open a .chd, and the achievement hasher will not link."
    exit 1
fi

# 5. iOS only: the architecture actually produced.
if [ "$HOST" != "1" ]; then
    if ! lipo -info "$OUTPUT_LIB" 2>/dev/null | grep -q 'arm64'; then
        echo "ERROR: the library is not arm64."
        lipo -info "$OUTPUT_LIB" || true
        exit 1
    fi
fi

# 6. The entry points, by name. ADVISORY, not fatal: check 1 has already proved
#    the object is present, so a disagreement here is far more likely to be nm
#    than the library. It is kept because when it does work it is the most
#    direct statement that the app will link.
#
#    `nm` is taken from the SDK on the iOS path so it matches the toolchain that
#    produced the archive, and its stderr is shown rather than swallowed.
if [ "$HOST" = "1" ]; then NM_BIN="nm"; else NM_BIN="$(xcrun --sdk iphoneos --find nm 2>/dev/null || echo nm)"; fi
NM_ERR="$("$NM_BIN" "$OUTPUT_LIB" 2>&1 >/dev/null || true)"
SYMS="$("$NM_BIN" "$OUTPUT_LIB" 2>/dev/null || true)"

if [ -z "$SYMS" ]; then
    echo "NOTE: could not read symbols with '$NM_BIN', so the entry-point check"
    echo "      was SKIPPED. The archive itself is fine: its members were listed"
    echo "      and libretro.o is present."
    [ -n "$NM_ERR" ] && echo "      nm said: $NM_ERR"
else
    # A leading underscore is Mach-O's convention and ELF has none, so both are
    # accepted, and the symbol is matched at the END of its line rather than
    # against an exact column layout.
    MISSING=""
    for sym in retro_init retro_run retro_load_game retro_serialize retro_serialize_size \
               retro_unserialize retro_get_memory_data retro_cheat_set retro_deinit; do
        if ! printf '%s\n' "$SYMS" | grep -qE "[[:space:]]_?${sym}\$"; then
            MISSING="$MISSING $sym"
        fi
    done
    if [ -n "$MISSING" ]; then
        echo "WARNING: these entry points were not found by name:$MISSING"
        echo "         libretro.o IS in the archive, so this is much more likely"
        echo "         to be nm's output format than a real problem. Here are the"
        echo "         retro_* symbols it did report, to compare against:"
        printf '%s\n' "$SYMS" | grep -E 'retro_(init|run|deinit)' | head -5 | sed 's/^/           /'
        echo "         The build is NOT failed on this. If the app then fails to"
        echo "         link, the failure was real and this is where it was seen."
    fi
fi

echo
echo "=== Done ==="
ls -lh "$OUTPUT_LIB"
if [ "$HOST" != "1" ]; then
    echo
    echo "Xcode wiring for this library:"
    echo "  - add $OUTPUT_LIB to the app target's Frameworks phase"
    echo "  - header search path: Vendor/pcsx_rearmed/deps/libretro-common/include"
    echo "    (that is where libretro.h lives; the bridge needs no other header)"
    echo "  - library search path: Vendor/pcsx-ios/lib"
fi
