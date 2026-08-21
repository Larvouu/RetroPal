#!/bin/bash
# Build the MesenCE core as a static library for iOS (arm64).
#
# Usage:
#   ./build.sh              build lib/libmesen-core.a for iOS arm64 (needs Xcode)
#   ./build.sh clean        remove the build dir and the lib
#   HOST=1 ./build.sh       build lib/libmesen-core-host.a for THIS machine
#
# WHY A SCRIPT AND NOT CMAKE. melonDS ships a CMakeLists we drive through
# ios-arm64.cmake; MesenCE has no CMake at all, only a makefile that builds the
# .NET UI and the SDL frontend alongside the core. Both of those are exactly what
# we must not build, so we compile the core's own translation units ourselves.
# The file list below is the makefile's (CORESRC + UTILSRC + SEVENZIPSRC +
# LUASRC), minus every frontend folder: no Sdl, no Linux, no MacOS, no
# InteropDLL, no UI. The 2026-08-11 spike verified that Core/ and Utilities/
# reference SDL in Visual Studio project files only, never in a source file.
#
# WHY HOST=1 EXISTS. It compiles the same file list with the host compiler so the
# list, the include paths and the defines can be verified on any machine before
# anyone spends Mac time on it. It produces a host library that is useless to the
# app and is never linked; only the iOS path ships. Keeping one source of truth
# for the file list is the point.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MESEN_SRC="$SCRIPT_DIR/../mesence"
BUILD_DIR="$SCRIPT_DIR/build"
LIB_DIR="$SCRIPT_DIR/lib"

HOST="${HOST:-0}"
if [ "$HOST" = "1" ]; then
    OBJ_DIR="$BUILD_DIR/obj-host"
    OUTPUT_LIB="$LIB_DIR/libmesen-core-host.a"
else
    OBJ_DIR="$BUILD_DIR/obj-ios-arm64"
    OUTPUT_LIB="$LIB_DIR/libmesen-core.a"
fi

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning..."
    rm -rf "$BUILD_DIR" "$LIB_DIR"
    echo "Done."
    exit 0
fi

if [ ! -f "$MESEN_SRC/Core/pch.h" ]; then
    echo "ERROR: MesenCE sources not found at $MESEN_SRC"
    echo "Run: git submodule update --init Vendor/mesence"
    exit 1
fi

# --- patch the core -----------------------------------------------------------
#
# One patch, and it exists because the core cannot be driven a frame at a time
# without it: Emulator::ProcessEndOfFrame() dereferences a frame limiter that only
# Run() ever builds, and the consoles call that method themselves every frame.
# See the patch's own header for the full reasoning.
#
# Patching here rather than forking keeps the submodule pinned to upstream, so
# the public repo carries the exact upstream SHA plus this file, which is the
# whole of our modification.
#
# THIS RUNS BEFORE THE "already built" CHECK ON PURPOSE. It used to run after,
# which meant a machine with a library from a previous build skipped the patch
# entirely and kept running the unpatched core: the script said nothing was to be
# done, and the app kept dying exactly as before. A newly applied patch now
# invalidates the library instead.

PATCH_DIR="$SCRIPT_DIR/patches"
PATCH_APPLIED_NOW=0
if [ -d "$PATCH_DIR" ]; then
    for patch in "$PATCH_DIR"/*.patch; do
        [ -e "$patch" ] || continue
        name="$(basename "$patch")"
        # Already applied? Then the reverse patch is what fits.
        if git -C "$MESEN_SRC" apply --reverse --check "$patch" 2>/dev/null; then
            echo "Patch already applied: $name"
        elif git -C "$MESEN_SRC" apply "$patch" 2>/dev/null; then
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
    echo "The core was patched after this library was built — rebuilding it."
    rm -f "$OUTPUT_LIB"
fi

# Skip if already built (use 'clean' to force a rebuild), matching melonds-ios.
if [ -f "$OUTPUT_LIB" ]; then
    echo "$(basename "$OUTPUT_LIB") already built. Run '$0 clean' to rebuild."
    exit 0
fi

# --- toolchain ----------------------------------------------------------------

if [ "$HOST" = "1" ]; then
    CXX="${CXX:-g++}"
    CC="${CC:-gcc}"
    TARGET_FLAGS=""
    AR_CMD="ar"
    echo "=== Building MesenCE core for THIS HOST (verification only) ==="
else
    command -v xcrun >/dev/null 2>&1 || { echo "ERROR: xcrun not found. This path needs Xcode."; exit 1; }
    SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
    CXX="$(xcrun --sdk iphoneos --find clang++)"
    CC="$(xcrun --sdk iphoneos --find clang)"
    TARGET_FLAGS="-isysroot $SDK_PATH -arch arm64 -miphoneos-version-min=16.0"
    AR_CMD="libtool"
    echo "=== Building MesenCE core for iOS arm64 ==="
    echo "SDK: $SDK_PATH"
fi

# -O3 and C++17 are the makefile's own settings. LTO is deliberately NOT enabled:
# melonDS is built -DENABLE_LTO_RELEASE=OFF for the same reason, a thin-LTO
# static library has to agree with the app target's own LTO setting to link.
COMMON_FLAGS="-O3 -fno-strict-aliasing -w $TARGET_FLAGS"
CXXFLAGS="-std=c++17 $COMMON_FLAGS -I$MESEN_SRC -I$MESEN_SRC/Core -I$MESEN_SRC/Utilities"
CFLAGS="$COMMON_FLAGS -I$MESEN_SRC -I$MESEN_SRC/Core -I$MESEN_SRC/Utilities"

# Lua's os.execute() calls system(), which the iOS SDK marks unavailable, so
# Lua/loslib.c is the one file in the whole core that cannot compile as-is.
#
# Upstream Lua already solves this behind LUA_USE_IOS, and defining that symbol
# is the obvious fix, but it is the wrong one here: LUA_USE_IOS also turns on
# LUA_USE_POSIX, which switches liolib.c onto popen — a file that compiles
# today. Trading a known error for a possible one is not a fix.
#
# So the surgical version: define l_system to upstream's own iOS expression.
# loslib.c guards it with `#if !defined(l_system)`, so a command-line definition
# wins and nothing else about Lua's configuration moves. Quoted at the use site
# because it carries parentheses and a `?`.
#
# Nothing is lost: Lua reaches the binary only because Core/Debugger links
# against it, and the debugger is never initialised. This makes os.execute report
# "no shell", which on iOS is simply true.
LUA_NO_SYSTEM='-Dl_system(cmd)=((cmd)==NULL?0:-1)'

# --- source list (the makefile's, minus every frontend) -----------------------
#
# Core/       the emulators themselves + the shared host-facing services
# Utilities/  serialization, compression, string and platform helpers
# SevenZip/   Utilities/SZReader.cpp links against it (archive ROM loading)
# Lua/        Core/Debugger/LuaApi.cpp links against it. Kept because Emulator.h
#             includes Debugger.h and Emulator.cpp calls into the debugger, so
#             Core/Debugger cannot be dropped without patching the core.

cd "$MESEN_SRC"
CPP_SOURCES="$(find Core Utilities -name '*.cpp' | sort)"
C_SOURCES="$(find Utilities SevenZip Lua -name '*.c' | sort)"

CPP_COUNT="$(echo "$CPP_SOURCES" | grep -c . || true)"
C_COUNT="$(echo "$C_SOURCES" | grep -c . || true)"
echo "Translation units: $CPP_COUNT C++ / $C_COUNT C"

mkdir -p "$OBJ_DIR" "$LIB_DIR"

# One object per source, named after its full path with separators mangled:
# basenames collide across consoles (Core/NES and Core/SNES both carry a
# Console.cpp, a CpuTypes.h and more), so a flat basename layout would silently
# drop objects and produce a library that links but misbehaves.
compile_one() {
    local src="$1" kind="$2"
    local obj="$OBJ_DIR/$(echo "$src" | tr '/' '_').o"
    if [ -f "$obj" ] && [ "$obj" -nt "$src" ]; then
        return 0
    fi
    if [ "$kind" = "cpp" ]; then
        $CXX $CXXFLAGS -c "$src" -o "$obj" 2> "$obj.err" || {
            echo "FAILED: $src"
            cat "$obj.err"
            return 1
        }
    else
        $CC $CFLAGS "$LUA_NO_SYSTEM" -c "$src" -o "$obj" 2> "$obj.err" || {
            echo "FAILED: $src"
            cat "$obj.err"
            return 1
        }
    fi
    rm -f "$obj.err"
}
export -f compile_one
export CXX CC CXXFLAGS CFLAGS OBJ_DIR LUA_NO_SYSTEM

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
echo "Compiling with $JOBS parallel jobs..."

echo "$CPP_SOURCES" | xargs -P "$JOBS" -I{} bash -c 'compile_one "$@"' _ {} cpp
echo "$C_SOURCES"   | xargs -P "$JOBS" -I{} bash -c 'compile_one "$@"' _ {} c

# --- archive ------------------------------------------------------------------

OBJ_COUNT="$(find "$OBJ_DIR" -name '*.o' | wc -l | tr -d ' ')"
EXPECTED=$((CPP_COUNT + C_COUNT))
if [ "$OBJ_COUNT" -ne "$EXPECTED" ]; then
    echo "ERROR: $OBJ_COUNT objects for $EXPECTED sources — a translation unit failed."
    exit 1
fi

echo "Archiving $OBJ_COUNT objects..."
rm -f "$OUTPUT_LIB"
# A glob, deliberately not xargs: xargs may split 432 paths across several
# invocations, and each one would OVERWRITE the archive rather than add to it,
# leaving a library that links until it suddenly cannot find a symbol.
if [ "$AR_CMD" = "libtool" ]; then
    # libtool, not ar: the Apple-supported way to build a static library, and it
    # does not warn about the no-symbol translation units Mesen has.
    libtool -static -o "$OUTPUT_LIB" "$OBJ_DIR"/*.o
else
    ar rcs "$OUTPUT_LIB" "$OBJ_DIR"/*.o
fi

echo
echo "=== Done ==="
ls -lh "$OUTPUT_LIB"
if [ "$HOST" != "1" ]; then
    echo
    echo "Xcode is already wired for this library (project.pbxproj, commit 38e1967):"
    echo "  the archive is in the app target's Frameworks phase, and both the"
    echo "  Debug and Release configurations carry the include roots and the"
    echo "  library search path. Nothing to do by hand — just build."
fi
