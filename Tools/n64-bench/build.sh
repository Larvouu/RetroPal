#!/bin/bash
# Build the n64-bench host harness against a COPY of the Nintendo 64 core.
#
# Usage: Tools/n64-bench/build.sh <out-dir> [patch-dir...]
#
#   <out-dir>     where the copy of the core, its objects and the harness go.
#                 Several out-dirs side by side are how two variants are
#                 compared (patched vs not, a flag vs not). The patches are
#                 applied when the copy is made, so a different patch set
#                 needs a fresh out-dir; flags only need a rerun.
#   [patch-dir]   extra directories of *.patch applied AFTER the shipped ones
#                 (Vendor/n64-ios/patches), each in name order: a candidate
#                 change is tried here before it is proposed for the phone.
#
# Environment:
#   N64_EXTRA_CFLAGS   added to the core's C and C++ flags (e.g. -flto=auto)
#   N64_EXTRA_LDFLAGS  added to the harness link (e.g. -flto=auto)
#   N64_SKIP           shipped patches to leave out, as basename globs
#                      ("0009-*"): how the build BEFORE a patch is rebuilt
#                      to measure it
#   N64_CC, N64_CXX    the core's compilers (default gcc/g++); clang/clang++
#                      is the phone's compiler family, with
#                      N64_EXTRA_CFLAGS="-Ofast" for the phone's flags
#
# The core is the submodule's pinned commit (`git archive`, never the working
# tree, which build.sh patches in place), with the same make choices as
# Vendor/n64-ios/build.sh: parallel-RDP, cxd4, the cached interpreter, no JIT,
# no GLideN64, no angrylion. It is linked into one shared object that exports
# only the n64_retro_* entry points (see below).
#
# The Vulkan half is the app's own N64VulkanFrontend.mm, compiled unchanged
# but for one line: its log handle is created through a block, which only
# clang compiles, so the build gives it a plain assignment instead. Runs on
# lavapipe (Mesa's CPU Vulkan): VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
#
# Needs gcc/g++ (or clang), make and the Vulkan loader (libvulkan.so.1).

set -euo pipefail

OUT="$1"
shift
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CORE_SUBMODULE="$ROOT/Vendor/mupen64plus-libretro-nx"
N64_IOS="$ROOT/Vendor/n64-ios"
APP_BRIDGE="$ROOT/EmulateurGBA/EmulatorCore/Bridge"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SRC="$OUT/core-src"

if [ ! -f "$SRC/Makefile.common" ]; then
    mkdir -p "$SRC"
    git -C "$CORE_SUBMODULE" archive HEAD | tar -x -C "$SRC"
    for dir in "$N64_IOS/patches" "$@"; do
        for patch in "$dir"/*.patch; do
            [ -e "$patch" ] || continue
            skip=0
            for glob in ${N64_SKIP:-}; do
                # shellcheck disable=SC2053
                [[ "$(basename "$patch")" == $glob ]] && skip=1
            done
            [ "$skip" = 1 ] && { echo "skipped $(basename "$patch")"; continue; }
            git -C "$SRC" apply "$patch" 2>/dev/null || patch -d "$SRC" -p1 -s < "$patch"
            echo "applied $(basename "$patch")"
        done
    done
fi

# The makefile tracks no flags, so objects from an earlier build of this copy
# would be reused as they are: always from clean.
make -C "$SRC" clean >/dev/null 2>&1 || true
make -C "$SRC" \
    platform=unix \
    CC="${N64_CC:-cc}" CXX="${N64_CXX:-c++}" \
    STATIC_LINKING=1 HAVE_GLIDEN64=0 HAVE_PARALLEL_RDP=1 LLE=1 \
    HAVE_PARALLEL_RSP=0 HAVE_THR_AL=0 WITH_DYNAREC= PIC=1 \
    CPPFLAGS="-DNO_ASM -include $N64_IOS/n64_symbols.h" \
    CPUFLAGS="-fno-common -g ${N64_EXTRA_CFLAGS:-}" \
    TARGET="$OUT/upstream.a" \
    -j "$(nproc)" >"$OUT/core-build.log" 2>&1 || { tail -30 "$OUT/core-build.log"; exit 1; }

# Host LTO only: GCC loses the symbols libco's x86-64 file (amd64.c) defines
# in top-level assembly, so that one object is rebuilt without -flto and put
# back. The phone builds aarch64.c with clang, which keeps module assembly.
if [[ "${N64_EXTRA_CFLAGS:-}" == *-flto* ]]; then
    LIBCO_CMD="$(grep -m1 ' -c libretro-common/libco/libco.c\| libretro-common/libco/libco.c ' "$OUT/core-build.log" || true)"
    [ -n "$LIBCO_CMD" ] || { echo "cannot find libco's compile line in core-build.log"; exit 1; }
    (cd "$SRC" && eval "${LIBCO_CMD//-flto=auto/}")
    ar rcs "$OUT/upstream.a" "$SRC/libretro-common/libco/libco.o"
fi

# One shared object exporting only the entry points, the host's equivalent of
# the phone's pre-linked object (Vendor/n64-ios/build.sh): nothing else of the
# core, volk's vk* pointers among it, can meet the system's libvulkan. A shared
# object rather than `ld -r` + objcopy because the latter strands the C++
# template copies the core shares with the frontend.
{
    echo "{ global:"
    sed -nE 's/^#define[[:space:]]+retro_[a-z_]+[[:space:]]+(n64_retro_[a-z_]+)[[:space:]]*$/  \1;/p' "$N64_IOS/n64_symbols.h"
    echo "local: *; };"
} > "$OUT/exports.map"
g++ -shared ${N64_EXTRA_LDFLAGS:-} -o "$OUT/libn64core.so" \
    -Wl,--whole-archive "$OUT/upstream.a" -Wl,--no-whole-archive \
    -Wl,--version-script="$OUT/exports.map" -Wl,--no-undefined \
    -lstdc++ -lm -lpthread -ldl -lz

# The app's frontend, its one block replaced (see the top).
sed 's/dispatch_once(&once, ^{ log = os_log_create("com.retropal.emulateurgba", "n64-vulkan"); });/log = os_log_create("com.retropal.emulateurgba", "n64-vulkan"); (void)once;/' \
    "$APP_BRIDGE/N64VulkanFrontend.mm" > "$OUT/N64VulkanFrontend.cpp"
grep -q 'dispatch_once(&once, \^' "$OUT/N64VulkanFrontend.cpp" && { echo "the frontend's log line changed; update this script"; exit 1; }

INCLUDES=(
    -I"$HERE/shim"
    -I"$APP_BRIDGE"
    -I"$SRC/libretro-common/include"
    -I"$SRC/mupen64plus-video-paraLLEl/parallel-rdp/vulkan-headers/include"
)

g++ -std=c++17 -O2 -g -include "$N64_IOS/n64_symbols.h" "${INCLUDES[@]}" \
    "$OUT/N64VulkanFrontend.cpp" "$HERE/n64-bench.cpp" \
    -L"$OUT" -ln64core -Wl,-rpath,"$OUT" \
    -l:libvulkan.so.1 -lstdc++ -lm -lpthread -ldl -lz \
    -o "$OUT/n64-bench"

echo "$OUT/n64-bench"
