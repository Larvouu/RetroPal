#!/bin/bash
# Build the Nintendo 64 core (Mupen64Plus-Next, libretro) as a static library
# for iOS (arm64).
#
# Usage:
#   ./build.sh              build lib/libn64-core.a for iOS arm64 (needs Xcode)
#   ./build.sh clean        remove the build artefacts and the lib
#   HOST=1 ./build.sh       build lib/libn64-core-host.a for THIS machine, then
#                           link and run host-check.c against it
#
# WHAT IS BUILT, AND WHAT IS LEFT OUT. Mupen64Plus-Next bundles four renderers
# and three RSPs. We build exactly one of each, and each choice is a licence or
# App Store decision before it is a technical one:
#
#   renderer  parallel-RDP (MIT), drawn on the GPU through Vulkan, which the
#             bridge provides on top of MoltenVK (Vendor/moltenvk-ios).
#             GLideN64 is compiled OUT by our patch (HAVE_GLIDEN64=0): it is
#             GPL-2.0-only, and melonDS and MesenCE are GPL-3.0, so the two
#             cannot share one binary. angrylion is compiled out too
#             (HAVE_THR_AL=0): its only licence is MAME's, which forbids
#             commercial use.
#   RSP       cxd4 (CC0), the low-level interpreter parallel-RDP needs (LLE=1).
#             parallel-RSP is a JIT (HAVE_PARALLEL_RSP=0). The high-level RSP
#             is always compiled in, and handles the audio tasks.
#   CPU       the cached interpreter. WITH_DYNAREC is empty and NO_ASM is set:
#             the App Store forbids JIT, so a recompiler would be code we ship
#             and are never allowed to run.
#
# The upstream ios-arm64 block turns parallel-RSP and angrylion ON; the values
# above are passed on the make command line, which overrides the makefile's own
# assignments.
#
# WHY PLATCFLAGS IS RESTATED HERE. Upstream's ios-arm64 block hard-codes
# -miphoneos-version-min=8.0 inside PLATCFLAGS and has no variable for it (the
# PCSX makefile has MINVERSION; this one does not). Our floor is 16.0 and the
# deployment target has to match the app's, so the block's PLATCFLAGS is given
# in full below with 16.0 in place of 8.0 and nothing else changed. If upstream
# edits that block, compare it with IOS_PLATCFLAGS.
#
# SYMBOL ISOLATION, the part that is new with this core. PCSX-ReARMed is also a
# libretro core linked statically into the app, so both define retro_run,
# retro_init and the rest, and both carry their own zlib and libretro-common.
# Two steps keep them apart:
#   1. n64_symbols.h is force-included into every translation unit, renaming
#      this core's libretro API to n64_retro_*.
#   2. every object is pre-linked into ONE relocatable object that exports only
#      those names (ld -r with an export list). Every other global becomes
#      private to the object, so nothing else can meet PCSX's copies.
# The export check at the end FAILS the build if anything else is global.
#
# PATCHES, applied here rather than forked, so the submodule stays pinned to
# upstream; the seven files are the whole of our modification to the core:
#   0001-build-without-gliden64.patch   compiles GLideN64 and OpenGL out
#   0002-free-the-emulation-coroutine-at-deinit.patch
#                                       lets a statically linked core be
#                                       started again for the next game
#   0003-size-the-cheat-parser-buffer-for-its-terminator.patch
#                                       fixes a one-byte stack overflow per
#                                       cheat code group
#   0004-stop-zlib-taking-apple-sdks-for-classic-mac-os.patch
#                                       lets the bundled zlib compile against
#                                       Apple's SDKs, which define TARGET_OS_MAC
#                                       on iOS too
#   0005-compile-shader-variants-off-the-emulation-thread-on-moltenvk.patch
#                                       stops shader compiles stalling the
#                                       emulation thread (MoltenVK compiles
#                                       specialisations it was told not to)
#   0006-fix-rdram-initialization.patch upstream's RDRAM fix (mupen64plus-core
#                                       b4d028a): boot code that sets up the
#                                       memory chips by the book, libdragon's
#                                       IPL3 among it, found no RAM and the app
#                                       hung on the game's first frame
#   0007-keep-the-audio-dma-inside-rdram.patch
#                                       a game that wrote a CPU pointer to the
#                                       audio address register sent the sample
#                                       push past RDRAM and crashed the app
# The `legal.compliance` string x15 names the cores we modify, and has to stay
# accurate while these patches exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
N64_SRC="$SCRIPT_DIR/../mupen64plus-libretro-nx"
LIB_DIR="$SCRIPT_DIR/lib"
BUILD_DIR="$SCRIPT_DIR/build"
SYMBOLS_H="$SCRIPT_DIR/n64_symbols.h"

HOST="${HOST:-0}"
if [ "$HOST" = "1" ]; then
    OUTPUT_LIB="$LIB_DIR/libn64-core-host.a"
    SUFFIX="host"
else
    OUTPUT_LIB="$LIB_DIR/libn64-core.a"
    SUFFIX="ios"
fi
UPSTREAM_LIB="$BUILD_DIR/upstream-$SUFFIX.a"
PRELINKED_OBJ="$BUILD_DIR/n64-core-$SUFFIX.o"

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning..."
    # The makefile builds in-tree; its own clean target deletes every .o and .d.
    if [ -d "$N64_SRC" ]; then
        make -C "$N64_SRC" clean >/dev/null 2>&1 || true
    fi
    rm -rf "$LIB_DIR" "$BUILD_DIR"
    echo "Done."
    exit 0
fi

if [ ! -f "$N64_SRC/Makefile.common" ]; then
    echo "ERROR: Mupen64Plus-Next sources not found at $N64_SRC"
    echo "Run: git submodule update --init Vendor/mupen64plus-libretro-nx"
    exit 1
fi

# --- patches ------------------------------------------------------------------
#
# Applied in name order. Same shape as mesen-ios/build.sh and pcsx-ios/build.sh:
# a patch that applies neither way aborts the build rather than silently
# producing a core that differs from the one we tested. It runs BEFORE the "already built" check, so a
# machine holding a library from an unpatched build rebuilds it.

PATCH_DIR="$SCRIPT_DIR/patches"
PATCH_APPLIED_NOW=0
for patch in "$PATCH_DIR"/*.patch; do
    [ -e "$patch" ] || continue
    name="$(basename "$patch")"
    if git -C "$N64_SRC" apply --reverse --check "$patch" 2>/dev/null; then
        echo "Patch already applied: $name"
    elif git -C "$N64_SRC" apply "$patch" 2>/dev/null; then
        echo "Patch applied: $name"
        PATCH_APPLIED_NOW=1
    else
        echo "ERROR: $name applies neither way."
        echo "Either the pinned core has moved under the patch (re-make the patch"
        echo "against the new source rather than build something that silently"
        echo "differs), or this checkout still carries an OLDER version of our own"
        echo "patch. For the second, reset the core's sources and build again:"
        echo "  git -C Vendor/mupen64plus-libretro-nx checkout . && $0 clean && $0"
        exit 1
    fi
done

if [ "$PATCH_APPLIED_NOW" = "1" ] && [ -f "$OUTPUT_LIB" ]; then
    echo "The core was patched after this library was built - rebuilding it."
    rm -f "$OUTPUT_LIB"
fi

if [ -f "$OUTPUT_LIB" ]; then
    echo "$(basename "$OUTPUT_LIB") already built. Run '$0 clean' to rebuild."
    exit 0
fi

mkdir -p "$LIB_DIR" "$BUILD_DIR"
rm -f "$UPSTREAM_LIB" "$PRELINKED_OBJ"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# The makefile builds objects in the source tree and does not track compiler
# flags, so objects left by a build for the OTHER platform (or by upstream's
# default flags) would be archived as they are. Start from a clean tree.
make -C "$N64_SRC" clean >/dev/null 2>&1 || true

# The renderer, RSP and CPU choices described at the top, shared by both builds.
#
# -fno-common is ours, and undoes upstream's -fcommon. With -fcommon every
# uninitialised global is a "common" symbol, and a common symbol cannot be made
# private by the prelink below: it stays global unless the linker is told to
# define it (-d), and Apple's current linker no longer accepts -d. Among the
# commons are volk's Vulkan function pointers, named exactly like MoltenVK's
# real vk* functions, so they must not leak. Checked on the host build: each of
# the core's common symbols is defined once and only tentatively, so defining
# them outright changes nothing but their linkage; the export check below
# refuses any common symbol that survives (nm lists it as a global).
CORE_CHOICES=(
    STATIC_LINKING=1
    HAVE_GLIDEN64=0
    HAVE_PARALLEL_RDP=1
    LLE=1
    HAVE_PARALLEL_RSP=0
    HAVE_THR_AL=0
    WITH_DYNAREC=
)

# --- build --------------------------------------------------------------------

if [ "$HOST" = "1" ]; then
    # Verification only: the same sources, patch, choices and renaming, built
    # with the host compiler, so all of it can be checked on any machine before
    # anyone spends Mac time. NO_ASM is what the iOS block sets; the host block
    # does not, and without it the core references the dynarec it did not build.
    echo "=== Building Mupen64Plus-Next for THIS HOST (verification only) ==="
    make -C "$N64_SRC" \
        platform=unix \
        "${CORE_CHOICES[@]}" \
        CPPFLAGS="-DNO_ASM -include $SYMBOLS_H" \
        CPUFLAGS="-fno-common" \
        TARGET="$UPSTREAM_LIB" \
        -j "$JOBS"
else
    command -v xcrun >/dev/null 2>&1 || { echo "ERROR: xcrun not found. This path needs Xcode."; exit 1; }
    IOSSDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    echo "=== Building Mupen64Plus-Next core for iOS arm64 ==="
    echo "SDK: $IOSSDK"

    # Upstream's ios-arm64 PLATCFLAGS with 16.0 in place of 8.0 (see the top).
    IOS_PLATCFLAGS="-DHAVE_POSIX_MEMALIGN -DIOS -DOS_IOS -Ofast -ffast-math -funsafe-math-optimizations -DNO_ASM -miphoneos-version-min=16.0 -Wno-error=implicit-function-declaration -fno-common"

    make -C "$N64_SRC" \
        platform=ios-arm64 \
        IOSSDK="$IOSSDK" \
        "${CORE_CHOICES[@]}" \
        PLATCFLAGS="$IOS_PLATCFLAGS" \
        CPPFLAGS="-include $SYMBOLS_H" \
        AR="$(xcrun --sdk iphoneos --find ar)" \
        TARGET="$UPSTREAM_LIB" \
        -j "$JOBS"
fi

if [ ! -f "$UPSTREAM_LIB" ]; then
    echo "ERROR: the makefile reported success but produced no library."
    exit 1
fi

# --- what went into the archive -------------------------------------------------
#
# Checked by archive MEMBER, as pcsx-ios/build.sh does: `ar t` speaks one format
# everywhere. Each check is a way the flags above can resolve differently
# without the build failing.

MEMBERS="$(ar t "$UPSTREAM_LIB" 2>/dev/null || true)"
if [ -z "$MEMBERS" ]; then
    echo "ERROR: 'ar t' listed nothing. The archive exists but is not readable"
    echo "       as an archive, which means it is not what the makefile thinks."
    exit 1
fi

require_member() {
    if ! printf '%s\n' "$MEMBERS" | grep -qx "$1"; then
        echo "ERROR: $1 absent - $2"
        exit 1
    fi
}
forbid_members() {
    local found
    found="$(printf '%s\n' "$MEMBERS" | grep -xE "$1" || true)"
    if [ -n "$found" ]; then
        echo "ERROR: $2"
        printf '%s\n' "$found" | sort -u | sed 's/^/         /'
        exit 1
    fi
}

require_member libretro.o      "the core was built without its libretro frontend."
require_member rdp.o           "parallel-RDP is not in the build; there is no renderer."
require_member rsp.o           "the cxd4 RSP is not in the build (LLE did not resolve to 1)."
require_member cached_interp.o "there is no cached interpreter to run the CPU."

# GLideN64 and OpenGL. The first names are GLideN64's core files; glsm, glsym and
# rglgen are libretro-common's OpenGL layer, which only GLideN64 uses.
forbid_members '(GLideN64|gSP|gDP|Combiner|FrameBuffer|opengl_ContextImpl|Config_mupenplus|glsm|glsym_(gl|es2|es3)|rglgen)\.o' \
    "GLideN64 or OpenGL objects are present. GLideN64 is GPL-2.0-only and cannot ship with our GPL-3.0 cores; the patch or HAVE_GLIDEN64=0 did not take."
# angrylion: its MAME licence forbids commercial use.
forbid_members '(n64video|parallel_al)\.o' \
    "angrylion objects are present (HAVE_THR_AL did not resolve to 0). Its licence forbids commercial use."
# Any JIT: the r4300 recompiler, and parallel-RSP with GNU lightning.
forbid_members '(new_dynarec|linkage_arm|linkage_arm64|rsp_jit|jit_allocator|lightning|jit_[a-z]+)\.o' \
    "recompiler objects are present. The App Store forbids JIT; this library cannot ship."

# --- prelink into one object that exports only n64_retro_* ------------------------

# The export list comes from n64_symbols.h, the single source of truth.
EXPORT_NAMES="$(sed -nE 's/^#define[[:space:]]+retro_[a-z_]+[[:space:]]+(n64_retro_[a-z_]+)[[:space:]]*$/\1/p' "$SYMBOLS_H")"
EXPORT_COUNT="$(printf '%s\n' "$EXPORT_NAMES" | grep -c . || true)"
if [ "$EXPORT_COUNT" -lt 20 ]; then
    echo "ERROR: read only $EXPORT_COUNT names from n64_symbols.h; the list or its parsing is broken."
    exit 1
fi

if [ "$HOST" = "1" ]; then
    # ELF: ld -r merges the archive, then objcopy localizes every global not
    # listed.
    printf '%s\n' $EXPORT_NAMES > "$BUILD_DIR/exports-elf.txt"
    ld -r --whole-archive "$UPSTREAM_LIB" --no-whole-archive -o "$PRELINKED_OBJ"
    objcopy --keep-global-symbols="$BUILD_DIR/exports-elf.txt" "$PRELINKED_OBJ"
    AR_BIN="ar"
    NM_BIN="nm"
else
    # Mach-O: ld -r with an export list makes every unlisted global a private
    # extern, and ld -r then turns private externs into local symbols (the
    # default, since -keep_private_externs is not given).
    printf '_%s\n' $EXPORT_NAMES > "$BUILD_DIR/exports-macho.txt"
    CLANG_BIN="$(xcrun --sdk iphoneos --find clang)"
    "$CLANG_BIN" -arch arm64 -isysroot "$IOSSDK" -miphoneos-version-min=16.0 \
        -r -nostdlib \
        -Wl,-force_load,"$UPSTREAM_LIB" \
        -Wl,-exported_symbols_list,"$BUILD_DIR/exports-macho.txt" \
        -o "$PRELINKED_OBJ"
    AR_BIN="$(xcrun --sdk iphoneos --find ar)"
    NM_BIN="$(xcrun --sdk iphoneos --find nm)"
fi

rm -f "$OUTPUT_LIB"
"$AR_BIN" rcs "$OUTPUT_LIB" "$PRELINKED_OBJ"

# --- verify the exports -------------------------------------------------------------
#
# FATAL, unlike pcsx-ios's advisory symbol check, because here the symbol table IS
# the property being built: a stray global is a duplicate-symbol failure at the
# app's link, or worse, one core silently calling the other's copy of a helper.
# It still refuses to guess: if nm cannot be read, it says so and stops, rather
# than reporting a good library as broken or a broken one as good.

if ! DEFINED="$("$NM_BIN" -g "$PRELINKED_OBJ" 2>&1)"; then
    echo "ERROR: could not read symbols with '$NM_BIN', so the export check could"
    echo "       not run. nm said:"
    printf '%s\n' "$DEFINED" | head -5 | sed 's/^/         /'
    exit 1
fi
# Defined globals only: drop undefined references (U) and keep the name column.
DEFINED="$(printf '%s\n' "$DEFINED" | awk 'NF >= 3 && $2 != "U" { print $3 }' | sed 's/^_//' | sort -u)"
EXPECTED="$(printf '%s\n' $EXPORT_NAMES | sort -u)"

EXTRA="$(comm -23 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$EXPECTED"))"
MISSING="$(comm -13 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$EXPECTED"))"
if [ -n "$EXTRA" ]; then
    echo "ERROR: the core exports globals besides its n64_retro_* entry points."
    echo "       These could collide with PCSX-ReARMed or the app at link time:"
    printf '%s\n' "$EXTRA" | head -20 | sed 's/^/         /'
    exit 1
fi
if [ -n "$MISSING" ]; then
    echo "ERROR: these entry points are listed in n64_symbols.h but not defined:"
    printf '%s\n' "$MISSING" | sed 's/^/         /'
    exit 1
fi
echo "Exports: exactly the $EXPORT_COUNT n64_retro_* entry points."

# No OpenGL reference may survive either, even as an undefined symbol: the app
# would have to link OpenGL ES for code that can never run.
UNDEFINED="$("$NM_BIN" -u "$PRELINKED_OBJ" 2>/dev/null | awk '{ print $NF }' | sed 's/^_//')"
GL_REFS="$(printf '%s\n' "$UNDEFINED" | grep -E '^(gl[A-Z]|egl[A-Z])' || true)"
if [ -n "$GL_REFS" ]; then
    echo "ERROR: the core still calls OpenGL:"
    printf '%s\n' "$GL_REFS" | head -10 | sed 's/^/         /'
    exit 1
fi

if [ "$HOST" != "1" ]; then
    if ! lipo -info "$OUTPUT_LIB" 2>/dev/null | grep -q 'arm64'; then
        echo "ERROR: the library is not arm64."
        lipo -info "$OUTPUT_LIB" || true
        exit 1
    fi
fi

# --- host only: link a program against it and run it -----------------------------
#
# Linking proves the object is complete (every internal reference resolved inside
# it) and callable through the renamed API. Running it proves the core starts and
# that a load without Vulkan fails cleanly instead of reaching GLideN64's code.

if [ "$HOST" = "1" ]; then
    echo "=== Linking and running host-check ==="
    cc -std=gnu11 -O1 \
        -include "$SYMBOLS_H" \
        -I"$N64_SRC/libretro-common/include" \
        "$SCRIPT_DIR/host-check.c" "$OUTPUT_LIB" \
        -lstdc++ -lm -lpthread -ldl \
        -o "$BUILD_DIR/host-check"
    "$BUILD_DIR/host-check"
fi

echo
echo "=== Done ==="
ls -lh "$OUTPUT_LIB"
if [ "$HOST" != "1" ]; then
    echo
    echo "Xcode wiring for this library:"
    echo "  - add $OUTPUT_LIB to the app target's Frameworks phase"
    echo "  - library search path: Vendor/n64-ios/lib"
    echo "  - the bridge includes Vendor/n64-ios/n64_symbols.h BEFORE libretro.h"
fi
