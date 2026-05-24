#!/bin/bash
# Build melonDS core as a static library for iOS (arm64)
#
# Usage: ./build.sh [clean]
# Run from the melonds-ios/ directory or from the repo root.

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

# Skip if already built (use 'clean' to force rebuild)
if [ -f "$OUTPUT_LIB" ] && [ -f "$OUTPUT_TEAKRA" ]; then
    echo "melonDS libraries already built. Run '$0 clean' to rebuild."
    exit 0
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
    -DENABLE_LTO_RELEASE=OFF \
    -DCMAKE_C_FLAGS="-Wno-unused-function -miphoneos-version-min=16.0" \
    -DCMAKE_CXX_FLAGS="-Wno-unused-function -miphoneos-version-min=16.0"

cmake --build "$BUILD_DIR" --target core --config Release -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

echo "=== Copying artifacts ==="

mkdir -p "$SCRIPT_DIR/lib"
cp "$BUILD_DIR/src/libcore.a" "$OUTPUT_LIB"
cp "$BUILD_DIR/src/teakra/src/libteakra.a" "$OUTPUT_TEAKRA" 2>/dev/null || true

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
