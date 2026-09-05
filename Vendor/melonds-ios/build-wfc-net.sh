#!/bin/bash
# Build the melonDS network stack (Net + Net_Slirp + libslirp) as static
# libraries for iOS (arm64) — the WFC spike's build half. Additive: does not
# touch build.sh or libmelonds-core.a. See the header of MelonDSPlatform.cpp for
# the Xcode wiring and the go/no-go device checklist.
#
# Usage: ./build-wfc-net.sh [clean]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MELONDS_SRC="$SCRIPT_DIR/../melonds"
BUILD_DIR="$SCRIPT_DIR/build-wfc-net"
OUTPUT_NET="$SCRIPT_DIR/lib/libmelonds-net.a"
OUTPUT_SLIRP="$SCRIPT_DIR/lib/libslirp.a"
INCLUDE_DIR="$SCRIPT_DIR/include"
TOOLCHAIN="$SCRIPT_DIR/ios-arm64.cmake"

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning WFC net build..."
    rm -rf "$BUILD_DIR" "$OUTPUT_NET" "$OUTPUT_SLIRP"
    echo "Done."
    exit 0
fi

if [ -f "$OUTPUT_NET" ] && [ -f "$OUTPUT_SLIRP" ]; then
    echo "WFC net libraries already built. Run '$0 clean' to rebuild."
    exit 0
fi

echo "=== Building melonDS net stack for iOS arm64 (WFC spike) ==="

mkdir -p "$BUILD_DIR"

cmake -S "$SCRIPT_DIR/wfc-net" -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DCMAKE_C_FLAGS="-Wno-unused-function -miphoneos-version-min=16.0" \
    -DCMAKE_CXX_FLAGS="-Wno-unused-function -miphoneos-version-min=16.0"

cmake --build "$BUILD_DIR" --target melonds-net --config Release -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

echo "=== Copying artifacts ==="

mkdir -p "$SCRIPT_DIR/lib"
cp "$BUILD_DIR/libmelonds-net.a" "$OUTPUT_NET"
cp "$BUILD_DIR/libslirp/libslirp.a" "$OUTPUT_SLIRP"

# Net headers land flat in include/melonds/ beside types.h/FIFO.h (already
# copied by build.sh) so their quote-includes resolve in-directory.
mkdir -p "$INCLUDE_DIR/melonds"
for h in Net.h NetDriver.h Net_Slirp.h PacketDispatcher.h; do
    cp "$MELONDS_SRC/src/net/$h" "$INCLUDE_DIR/melonds/"
done
# Net_Slirp.h does `#include <libslirp.h>` (angle include), so libslirp's
# public headers go to the include ROOT, which is the header search path.
cp "$MELONDS_SRC/src/net/libslirp/src/libslirp.h" "$INCLUDE_DIR/"
cp "$BUILD_DIR/libslirp/libslirp-version.h" "$INCLUDE_DIR/"

echo "=== Done ==="
echo "Static libraries: $OUTPUT_NET + $OUTPUT_SLIRP"
echo "Next: Xcode wiring (link both libs, set RETROPAL_WFC=1)"
