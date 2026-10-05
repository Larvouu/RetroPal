#!/bin/bash
# Build the nds-bench host harness against a melonDS source tree.
#
# Usage: Tools/nds-bench/build.sh <melonds-source-dir> <build-dir> [cmake args...]
#
# <melonds-source-dir> is a COPY of the core (e.g. `git -C Vendor/melonds archive
# HEAD | tar -x -C somewhere`, then the patches applied to it), never the
# submodule itself, so that several variants can be built side by side and
# compared: pinned vs patched, LTO vs not.
#
# Needs cmake (pip install cmake works) and a C++17 compiler. The Platform layer
# is the app's own MelonDSPlatform.cpp, compiled unchanged, so the harness runs
# the same threads and semaphores the phone does.

set -euo pipefail

SRC="$(cd "$1" && pwd)"
OUT="$2"
shift 2
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_BRIDGE="$HERE/../../EmulateurGBA/EmulatorCore/Bridge"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

cmake -S "$SRC" -B "$OUT/core" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_QT_SDL=OFF \
    -DENABLE_OGLRENDERER=OFF \
    -DENABLE_JIT=OFF \
    -DENABLE_GDBSTUB=OFF \
    -DENABLE_LTO_RELEASE=OFF \
    "$@" >/dev/null
cmake --build "$OUT/core" --target core >/dev/null

# The app includes the core as <melonds/...>, so the harness does too.
mkdir -p "$OUT/include"
ln -sfn "$SRC/src" "$OUT/include/melonds"

LTO_FLAGS=()
for a in "$@"; do
    [ "$a" = "-DENABLE_LTO_RELEASE=ON" ] && LTO_FLAGS=(-flto=auto)
done

c++ -std=c++17 -O3 -DNDEBUG -fwrapv "${LTO_FLAGS[@]}" \
    -I"$OUT/include" -I"$SRC/src" -I"$OUT/core/src" -I"$APP_BRIDGE" \
    "$HERE/nds-bench.cpp" "$APP_BRIDGE/MelonDSPlatform.cpp" \
    "$OUT/core/src/libcore.a" "$OUT/core/src/teakra/src/libteakra.a" \
    -lpthread -o "$OUT/nds-bench"

echo "$OUT/nds-bench"
