#!/bin/bash
# Build melonDS core as a static library for iOS (arm64)
#
# Usage: ./build.sh [clean]
# Run from the melonds-ios/ directory or from the repo root.
#
# The core is pinned to upstream (Vendor/melonds) and PATCHED at build time since
# 1.3.3, the same way as MesenCE and Mupen64Plus-Next: the patch files in
# patches/ are the whole of our modification, applied in name order.
#   0001  free the SPU's output buffer (upstream 0638e5bc; a leak per game launch)
#   0002  save a DS state's 4 MB of main RAM, not the DSi's 16 MB (state format
#         13.1; 13.0 states still load, and older builds refuse 13.1 ones)
# While any patch exists, the in-app legal text (`legal.compliance`, 15
# languages) and README.public.md must say melonDS is used with changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MELONDS_SRC="$SCRIPT_DIR/../melonds"
BUILD_DIR="$SCRIPT_DIR/build"
OUTPUT_LIB="$SCRIPT_DIR/lib/libmelonds-core.a"
OUTPUT_TEAKRA="$SCRIPT_DIR/lib/libteakra.a"
INCLUDE_DIR="$SCRIPT_DIR/include"
TOOLCHAIN="$SCRIPT_DIR/ios-arm64.cmake"

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning build..."
    rm -rf "$BUILD_DIR" "$SCRIPT_DIR/lib" "$INCLUDE_DIR/melonds"
    echo "Done."
    exit 0
fi

# --- patch the core -----------------------------------------------------------
#
# Before the "already built" check on purpose (the MesenCE lesson): a library
# built before a patch existed must not be reused, or the app keeps running the
# unpatched core while this script says there is nothing to do.
PATCH_DIR="$SCRIPT_DIR/patches"
PATCH_APPLIED_NOW=0
for patch in "$PATCH_DIR"/*.patch; do
    [ -e "$patch" ] || continue
    name="$(basename "$patch")"
    # Already applied? Then the reverse patch is what fits.
    if git -C "$MELONDS_SRC" apply --reverse --check "$patch" 2>/dev/null; then
        echo "Patch already applied: $name"
    elif git -C "$MELONDS_SRC" apply "$patch" 2>/dev/null; then
        echo "Patch applied: $name"
        PATCH_APPLIED_NOW=1
    else
        echo "ERROR: $name applies neither way."
        echo "Either the pinned core moved under the patch (re-make it against the"
        echo "new source), or an older version of one of our patches is still applied:"
        echo "  git -C Vendor/melonds checkout . && $0 clean && $0"
        exit 1
    fi
done
if [ "$PATCH_APPLIED_NOW" = "1" ] && [ -f "$OUTPUT_LIB" ]; then
    echo "The core was patched after these libraries were built, rebuilding them."
    rm -rf "$BUILD_DIR" "$OUTPUT_LIB" "$OUTPUT_TEAKRA"
fi

# What this script builds with. Recorded beside the libraries, so a library
# built under an older configuration is rebuilt instead of silently reused: a
# stale library would keep the old speed and every measurement would be wrong.
BUILD_CONFIG="lto-release=on"
CONFIG_STAMP="$SCRIPT_DIR/lib/BUILD_CONFIG"

# Skip if already built with this configuration (use 'clean' to force rebuild)
if [ -f "$OUTPUT_LIB" ] && [ -f "$OUTPUT_TEAKRA" ]; then
    if [ "$(cat "$CONFIG_STAMP" 2>/dev/null)" = "$BUILD_CONFIG" ]; then
        echo "melonDS libraries already built. Run '$0 clean' to rebuild."
        exit 0
    fi
    echo "melonDS libraries were built with another configuration, rebuilding."
    rm -rf "$BUILD_DIR" "$OUTPUT_LIB" "$OUTPUT_TEAKRA"
fi

echo "=== Building melonDS core for iOS arm64 ==="

mkdir -p "$BUILD_DIR"

cmake -S "$MELONDS_SRC" -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DBUILD_QT_SDL=OFF \
    -DENABLE_OGLRENDERER=OFF \
    -DENABLE_JIT=OFF \
    -DENABLE_GDBSTUB=OFF \
    -DENABLE_LTO_RELEASE=ON \
    -DCMAKE_C_FLAGS="-Wno-unused-function -miphoneos-version-min=16.0" \
    -DCMAKE_CXX_FLAGS="-Wno-unused-function -miphoneos-version-min=16.0"

cmake --build "$BUILD_DIR" --target core --config Release -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# Link-time optimisation, melonDS's own default for release builds. It was off
# here from the first iOS build with no reason written down. The core's CPU
# interpreter calls into memory and hardware handlers in other files on every
# instruction, and LTO is what lets the compiler inline across them: measured
# with Tools/nds-bench, the same pictures and sound frame for frame and 4 to 11 %
# less time per frame. The objects in the archive are then LLVM bitcode, which
# Xcode's linker optimises when it links the app, whatever the app target's own
# LTO setting; the Mac link is the check.
#
# melonDS only honours the flag when CMake's IPO check passes, and turns it off
# quietly otherwise. So the archive is read back: a library without bitcode
# means LTO did not happen, and this fails instead of shipping the slower core
# under the faster core's name. To build without LTO on purpose, change
# -DENABLE_LTO_RELEASE and BUILD_CONFIG above together.
# (`|| true`: head closes the pipe early, which pipefail would turn into an exit.)
FIRST_OBJECT="$(ar -t "$BUILD_DIR/src/libcore.a" | grep '\.o$' | head -n 1 || true)"
MAGIC="$(ar -p "$BUILD_DIR/src/libcore.a" "$FIRST_OBJECT" | head -c 4 | od -An -tx1 | tr -d ' \n' || true)"
if [ "$MAGIC" != "4243c0de" ] && [ "$MAGIC" != "dec0170b" ]; then
    echo "ERROR: libcore.a holds native objects ($FIRST_OBJECT starts with $MAGIC), so LTO was not applied."
    echo "       CMake's IPO check probably failed; see $BUILD_DIR/CMakeCache.txt (IPO_SUPPORTED)."
    exit 1
fi

echo "=== Copying artifacts ==="

mkdir -p "$SCRIPT_DIR/lib"
cp "$BUILD_DIR/src/libcore.a" "$OUTPUT_LIB"
cp "$BUILD_DIR/src/teakra/src/libteakra.a" "$OUTPUT_TEAKRA" 2>/dev/null || true
echo "$BUILD_CONFIG" > "$CONFIG_STAMP"

# Copy all headers from src/ (the include chain is deep, easier to copy all)
mkdir -p "$INCLUDE_DIR/melonds"
find "$MELONDS_SRC/src" -maxdepth 1 -name "*.h" -exec cp {} "$INCLUDE_DIR/melonds/" \;

# Copy subdirectory headers
for subdir in NDSCart dolphin ARMJIT_A64 ARMJIT_x64 fatfs sha1 tiny-AES-c xxhash blip-buf DSP_HLE; do
    if [ -d "$MELONDS_SRC/src/$subdir" ]; then
        mkdir -p "$INCLUDE_DIR/melonds/$subdir"
        find "$MELONDS_SRC/src/$subdir" -name "*.h" -exec cp {} "$INCLUDE_DIR/melonds/$subdir/" \; 2>/dev/null || true
    fi
done

# Copy generated version.h
cp "$BUILD_DIR/src/version.h" "$INCLUDE_DIR/melonds/"

echo "=== Done ==="
echo "Static library: $OUTPUT_LIB"
echo "Headers: $INCLUDE_DIR/melonds/"
