#!/bin/bash
# Build the PSP core (PPSSPP's own libretro port, Vendor/ppsspp pinned v1.20.4)
# as a static library for iOS (arm64).
#
# Usage:
#   ./build.sh              build lib/libpsp-core.a for iOS arm64 (needs Xcode, CMake)
#   ./build.sh clean        remove the build artefacts and the lib
#   HOST=1 ./build.sh       build lib/libpsp-core-host.a for THIS machine: the same
#                           sources, choices, renaming and prelink, checked here
#                           before anyone spends Mac time
#
# WHY THE LIBRETRO PORT, and not PPSSPP embedded natively (the plan of
# 2026-09-03, made for two reasons that no longer hold):
# the app has had a Vulkan hardware-render frontend since the Nintendo 64
# (N64VulkanFrontend: MoltenVK, readback into the framebuffer every other
# console uses), and PPSSPP's libretro port lives in PPSSPP's own repository,
# runs Vulkan on the caller's thread, negotiates the device the way parallel-RDP
# does, serialises, and exposes RAM for RetroAchievements. Proven on the host
# with Tools/psp-bench (the app's own frontend, compiled unchanged).
#
# WHAT IS BUILT, AND WHAT IS LEFT OUT:
#   renderer  Vulkan only, through the frontend's MoltenVK. GLES is compiled in
#             by upstream's CMake on Apple (it is part of Common) but never
#             selected: the bridge sets ppsspp_backend to vulkan, and the app
#             links no OpenGL ES (the export check below refuses gl* references
#             only if the prelink leaves any; see the note there).
#   CPU       the IR interpreter. UNLIKE the N64's build, PPSSPP's ARM64 JIT is
#             compiled in: upstream's CMake adds Core/MIPS/ARM64 to every ARM64
#             build, the official App Store app ships it the same way, and it
#             cannot run: the bridge answers RETRO_ENVIRONMENT_GET_JIT_CAPABLE
#             with false, and the port then forces the IR interpreter
#             (libretro.cpp, "Just gonna force it to the IR interpreter"). No
#             page is ever mapped executable on iOS (PlatformIsWXExclusive).
#   Vulkan    the POINTER loader (no IOS_APP_STORE): the libretro port reaches
#             every Vulkan function through the frontend's vkGetInstanceProcAddr
#             and intercepts surface and swapchain calls; PPSSPP's App Store
#             mode calls MoltenVK directly and would bypass that interception.
#             The port never dlopens a Vulkan library (VulkanLoad is not called
#             by it).
#   ffmpeg    BUILT HERE from the source in Vendor/ppsspp/ffmpeg (a submodule of
#             PPSSPP), with PPSSPP's own option set (ffmpeg/shared_options.sh:
#             LGPL, no --enable-gpl, no --enable-nonfree, only the PSP's codecs),
#             for arm64 only, iOS 16.0, and -fno-common. The prebuilt libraries
#             beside it were compiled with -fcommon: 96 of their globals
#             (ff_cos_*, ff_sin_*, swscale's tables) are COMMON symbols, which a
#             relocatable link cannot make private (Apple's ld no longer accepts
#             -d), so they would leak out of the prelinked object and meet
#             anything else of that name in the app. Proved on the host: with
#             the commons defined, nothing but the psp_retro_* entry points
#             stays global. The host build keeps the prebuilt library and
#             defines its commons with GNU ld's -d (FFMPEG_FROM_SOURCE=1 builds
#             it from source there too).
#   off       Discord, UPnP, OpenXR, the headless and unit-test targets.
#
# SYMBOL ISOLATION, as the N64 and the Mega Drive do:
#   1. psp_symbols.h is force-included into every translation unit (through
#      CMAKE_C_FLAGS and CMAKE_CXX_FLAGS), renaming the libretro API to
#      psp_retro_*.
#   2. every archive is pre-linked into ONE relocatable object that exports
#      only those names. PPSSPP carries its own rcheevos (the app has one),
#      zstd, glslang, SPIRV-Cross (MoltenVK has one) and libretro-common (whose
#      retro_vfs_* PCSX and the N64 carry too): all become private.
#   The export check at the end FAILS the build if anything else is global.
#
# PATCHES: Vendor/ppsspp-ios/patches/*.patch, applied in name order to the
# submodule (reverted state checked first), as for the other cores. 0001 lets
# the PSP's memory sit outside the 4-6 GB band when the band is full.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PPSSPP_SRC="$SCRIPT_DIR/../ppsspp"
LIB_DIR="$SCRIPT_DIR/lib"
BUILD_DIR="$SCRIPT_DIR/build"
# The core's files, which it reads at run time from <system>/PPSSPP (see the
# assets step at the end). The app bundles this folder, under this name.
ASSETS_OUT="$SCRIPT_DIR/PPSSPP"
SYMBOLS_H="$SCRIPT_DIR/psp_symbols.h"

HOST="${HOST:-0}"
if [ "$HOST" = "1" ]; then
    OUTPUT_LIB="$LIB_DIR/libpsp-core-host.a"
    SUFFIX="host"
else
    OUTPUT_LIB="$LIB_DIR/libpsp-core.a"
    SUFFIX="ios"
fi
CMAKE_DIR="$BUILD_DIR/cmake-$SUFFIX"
PRELINKED_OBJ="$BUILD_DIR/psp-core-$SUFFIX.o"

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning..."
    rm -rf "$LIB_DIR" "$BUILD_DIR" "$ASSETS_OUT"
    echo "Done."
    exit 0
fi

# A `git pull` brings the submodule's POINTER, not its files: fetch them here
# (shallow, at the pinned commit) rather than stop on the first build after it.
if [ ! -f "$PPSSPP_SRC/CMakeLists.txt" ]; then
    echo "Fetching Vendor/ppsspp (the pinned PPSSPP, shallow)..."
    git -C "$SCRIPT_DIR/.." submodule update --init --depth 1 ppsspp
fi
if [ ! -f "$PPSSPP_SRC/CMakeLists.txt" ]; then
    echo "ERROR: PPSSPP sources not found at $PPSSPP_SRC, and fetching them failed."
    exit 1
fi

# --- PPSSPP's own submodules, only those the libretro build compiles ------------
#
# Shallow, at the commits PPSSPP pins. The rest (pspautotests, the Windows,
# macOS-SDL, debugger and OpenXR runtime trees, discord-rpc, miniupnp) are not
# compiled here. Two are needed for their HEADERS only, nothing of theirs is
# built or linked: ext/OpenXR-SDK (upstream's Common/VR files include it on
# every platform) and ext/miniupnp (Core/Util/PortManager.h includes it whether
# or not USE_MINIUPNPC is on; the library itself stays out). ext/armips needs
# its own ext/filesystem.
NEEDED_SUBMODULES=(
    libretro/libretro-common ffmpeg ext/glslang ext/SPIRV-Cross ext/zstd
    ext/cpu_features ext/rcheevos ext/rapidjson ext/libchdr ext/lua ext/armips
    ext/naett ext/freetype ext/nanosvg ext/aemu_postoffice ext/OpenXR-SDK
    ext/miniupnp
)
for sub in "${NEEDED_SUBMODULES[@]}"; do
    if [ -z "$(ls -A "$PPSSPP_SRC/$sub" 2>/dev/null)" ]; then
        echo "Fetching PPSSPP's $sub..."
        git -C "$PPSSPP_SRC" submodule update --init --depth 1 "$sub"
    fi
done
if [ -z "$(ls -A "$PPSSPP_SRC/ext/armips/ext/filesystem" 2>/dev/null)" ]; then
    git -C "$PPSSPP_SRC/ext/armips" submodule update --init --depth 1 ext/filesystem
fi

# --- patches ------------------------------------------------------------------

PATCH_DIR="$SCRIPT_DIR/patches"
PATCH_APPLIED_NOW=0
for patch in "$PATCH_DIR"/*.patch; do
    [ -e "$patch" ] || continue
    name="$(basename "$patch")"
    if git -C "$PPSSPP_SRC" apply --reverse --check "$patch" 2>/dev/null; then
        echo "Patch already applied: $name"
    elif git -C "$PPSSPP_SRC" apply "$patch" 2>/dev/null; then
        echo "Patch applied: $name"
        PATCH_APPLIED_NOW=1
    else
        echo "ERROR: $name applies neither way. Re-make it against the pinned source."
        exit 1
    fi
done
if [ "$PATCH_APPLIED_NOW" = "1" ] && [ -f "$OUTPUT_LIB" ]; then
    echo "The core was patched after this library was built - rebuilding it."
    rm -f "$OUTPUT_LIB"
fi

# --- the core's assets: <system>/PPSSPP -------------------------------------------
#
# The port registers <system>/PPSSPP as the root of everything it reads at run
# time (libretro.cpp: g_VFS.Register("", ...), flash0Directory, the warning when
# compat.ini is missing): the per-game fixes (compat.ini), the PSP's vector-math
# tables (vfpu/*.dat, without which some games compute wrong), the system
# dialogs' atlas (ppge_atlas), the language and region tables, the game database
# (redump.csv), the GPU's shaders, and the firmware fonts in flash0/font (all
# eighteen files, all shipped, as decided on 2026-10-09). The app answers the bundle's
# resources as the system directory (PSPBridge `makeSystemDirectory`), and Xcode
# bundles THIS folder as a folder reference, so it keeps its tree and its name.
#
# The whole of upstream's assets/, as RetroArch's distribution of this port
# ships it, minus assets/debugger (a submodule holding the standalone app's web
# debugger, never fetched here and never read by the port). Made on EVERY run,
# before the "already built" exit below: it is a copy, seconds long, and a
# library built before this step existed must not leave the app without it.
# Trimming the
# standalone app's own UI files from it (its fonts, sounds, themes) is possible
# and not done: each would need proving never read by the port first.
echo
echo "Assets for <system>/PPSSPP..."
[ -f "$PPSSPP_SRC/assets/compat.ini" ] || { echo "ERROR: $PPSSPP_SRC/assets/compat.ini is missing."; exit 1; }
rm -rf "$ASSETS_OUT"
mkdir -p "$ASSETS_OUT"
( cd "$PPSSPP_SRC/assets" && tar --exclude='./debugger' -cf - . ) | ( cd "$ASSETS_OUT" && tar -xf - )
for need in compat.ini ppge_atlas.meta ppge_atlas.zim langregion.ini redump.csv flash0/font/jpn0.pgf vfpu; do
    [ -e "$ASSETS_OUT/$need" ] || { echo "ERROR: $need is missing from $ASSETS_OUT."; exit 1; }
done
ASSET_BYTES="$(find "$ASSETS_OUT" -type f -exec cat {} + | wc -c | tr -d ' ')"
echo "Assets: $(find "$ASSETS_OUT" -type f | wc -l | tr -d ' ') files, $((ASSET_BYTES / 1048576)) MB, in $ASSETS_OUT"

if [ -f "$OUTPUT_LIB" ]; then
    echo "$(basename "$OUTPUT_LIB") already built. Run '$0 clean' to rebuild."
    exit 0
fi

command -v cmake >/dev/null 2>&1 || { echo "ERROR: cmake not found."; exit 1; }
mkdir -p "$LIB_DIR" "$BUILD_DIR"
rm -f "$PRELINKED_OBJ"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# --- ffmpeg, before PPSSPP: its headers must be the ones of the libraries linked
# ffmpeg from source (see the top): configured once per platform into its own
# folder, never in the submodule's tree.
build_ffmpeg() {
    local prefix="$BUILD_DIR/ffmpeg-$SUFFIX"
    if [ -f "$prefix/lib/libavutil.a" ]; then
        FFMPEG_DIR="$prefix"
        return
    fi
    echo "=== Building ffmpeg from source (log: $BUILD_DIR/ffmpeg-$SUFFIX.log) ==="
    local work="$BUILD_DIR/ffmpeg-work-$SUFFIX"
    mkdir -p "$work"
    # shellcheck disable=SC1091
    CONFIGURE_OPTS="$(cd "$PPSSPP_SRC/ffmpeg" && . ./shared_options.sh && echo "$CONFIGURE_OPTS")"
    local cross=()
    if [ "$HOST" != "1" ]; then
        local sdk
        sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
        cross=(--enable-cross-compile --arch=aarch64 --target-os=darwin --cpu=generic
               --cc="$(xcrun -f clang)" --sysroot="$sdk"
               --extra-cflags="-arch arm64 -miphoneos-version-min=16.0 -fno-common"
               --extra-ldflags="-arch arm64 -isysroot $sdk -miphoneos-version-min=16.0")
        PATH="$PPSSPP_SRC/ffmpeg/gas-preprocessor:$PATH"
    else
        # The host rehearsal only proves the -fno-common point; x86 assembly
        # needs nasm, which nothing else here needs.
        cross=(--extra-cflags="-fno-common" --disable-yasm)
    fi
    # shellcheck disable=SC2086
    (cd "$work" && "$PPSSPP_SRC/ffmpeg/configure" --prefix="$prefix" $CONFIGURE_OPTS "${cross[@]}" --enable-pic \
        && make -j "$JOBS" && make install) > "$BUILD_DIR/ffmpeg-$SUFFIX.log" 2>&1 \
        || { tail -30 "$BUILD_DIR/ffmpeg-$SUFFIX.log"; exit 1; }
    FFMPEG_DIR="$prefix"
}
if [ "$HOST" = "1" ] && [ "${FFMPEG_FROM_SOURCE:-0}" != "1" ]; then
    FFMPEG_DIR="$PPSSPP_SRC/ffmpeg/linux/$(uname -m)"
else
    build_ffmpeg
fi

# --- configure and build --------------------------------------------------------
#
# The CMake build folder is configured FROM SCRATCH every time (its cache is
# removed first). CMake reads a toolchain file only when a folder is first
# configured and silently ignores a new one afterwards ("Manually-specified
# variables were not used: CMAKE_TOOLCHAIN_FILE", proved on a two-line
# project): the second Mac run (2026-10-09) reused the folder of the first,
# configured without PPSSPP's iOS toolchain, and failed the same way. Only the
# configure step reruns; ffmpeg's build is kept in its own folder.
rm -rf "$CMAKE_DIR/CMakeCache.txt" "$CMAKE_DIR/CMakeFiles"

COMMON_OPTIONS=(
    -DLIBRETRO=ON
    -DCMAKE_BUILD_TYPE=Release
    -DUSE_DISCORD=OFF
    -DUSE_MINIUPNPC=OFF
    -DOPENXR=OFF
    -DHEADLESS=OFF
    -DUNITTEST=OFF
    -DATLAS_TOOL=OFF
    -DUSE_WAYLAND_WSI=OFF
    # FFMPEG_DIR: PPSSPP's CMake compiles against this ffmpeg's headers (the
    # ones of the libraries the prelink below takes), not its own prebuilt.
    "-DFFMPEG_DIR=$FFMPEG_DIR"
    # -Wno-nonportable-include-path: a shell whose working directory differs
    # in case from the disk (~/desktop vs ~/Desktop, same folder on macOS)
    # made every file warn about the forced include's spelling.
    "-DCMAKE_C_FLAGS=-include $SYMBOLS_H -fno-common -Wno-nonportable-include-path"
    "-DCMAKE_CXX_FLAGS=-include $SYMBOLS_H -fno-common -Wno-nonportable-include-path"
)

if [ "$HOST" = "1" ]; then
    echo "=== Configuring PPSSPP (libretro) for THIS HOST (verification only) ==="
    # X11 Vulkan ON only so the port's surface interception has a branch to
    # take on Linux (see Tools/psp-bench); it never opens a display.
    cmake -S "$PPSSPP_SRC" -B "$CMAKE_DIR" -G "Unix Makefiles" "${COMMON_OPTIONS[@]}" \
        -DUSING_X11_VULKAN=ON \
        -DCMAKE_C_COMPILER="${PSP_HOST_CC:-clang}" -DCMAKE_CXX_COMPILER="${PSP_HOST_CXX:-clang++}" \
        > "$BUILD_DIR/configure-$SUFFIX.log" 2>&1 || { tail -30 "$BUILD_DIR/configure-$SUFFIX.log"; exit 1; }
else
    command -v xcrun >/dev/null 2>&1 || { echo "ERROR: xcrun not found. This path needs Xcode."; exit 1; }
    IOSSDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    echo "=== Configuring PPSSPP (libretro) for iOS arm64 ==="
    echo "SDK: $IOSSDK"
    # IOS=ON with no IOS_APP_STORE: the pointer Vulkan loader the port needs
    # (see the top). Deployment target = the app's.
    # PPSSPP's OWN iOS toolchain file (cmake/Toolchains/ios.cmake, what its
    # b.sh --ios uses): it sets IOS, arm64, the iPhoneOS SDK, MOBILE_DEVICE,
    # USING_GLES2 and OPENGL_LIBRARIES (-framework OpenGLES). Configured by
    # hand instead (first Mac run, 2026-10-09), CMake looked for DESKTOP
    # OpenGL and stopped. The toolchain compiles for iOS 13.0 and up, which an
    # app whose floor is 16.0 links without complaint. The SAME generator as
    # the host rehearsal (Unix Makefiles), so the link rule and object paths
    # read below are the ones proved there.
    cmake -S "$PPSSPP_SRC" -B "$CMAKE_DIR" -G "Unix Makefiles" "${COMMON_OPTIONS[@]}" \
        -DCMAKE_TOOLCHAIN_FILE="$PPSSPP_SRC/cmake/Toolchains/ios.cmake" \
        -DIOS_PLATFORM=OS \
        > "$BUILD_DIR/configure-$SUFFIX.log" 2>&1 || { tail -30 "$BUILD_DIR/configure-$SUFFIX.log"; exit 1; }
fi

echo "=== Building (log: $BUILD_DIR/build-$SUFFIX.log) ==="
# What is built: the port's OBJECTS and the static libraries its link rule
# names, never the port's own .dylib (.so). We do not use that file (the
# prelink below makes the core from the same objects and archives), and on
# Apple its link carries PPSSPP's export list (libretro/libretro.osx.def:
# _retro_run and the rest), names psp_symbols.h has renamed: it failed with
# "symbol(s) not found" on the fifth Mac run; the Linux link has no export
# list, so the host never saw it. The library targets are read from CMake's
# own link rule for the port, which exists once the folder is configured.
LINK_TXT="$CMAKE_DIR/libretro/CMakeFiles/ppsspp_libretro.dir/link.txt"
[ -f "$LINK_TXT" ] || { echo "ERROR: CMake's link rule for the core is not at $LINK_TXT."; exit 1; }
BUILD_TARGETS=()
for item in $(cat "$LINK_TXT"); do
    case "$item" in
        */ffmpeg*) ;;
        *.a)
            name="$(basename "$item" .a)"; name="${name#lib}"
            BUILD_TARGETS+=("$name") ;;
    esac
done
[ "${#BUILD_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no library targets read from $LINK_TXT."; exit 1; }
# The port's own objects: their make rules, in the port's folder.
PORT_OBJ_TARGETS="$(make -C "$CMAKE_DIR/libretro" help 2>/dev/null | sed -n 's/^\.\.\. \(.*\.o\)$/\1/p')"
[ -n "$PORT_OBJ_TARGETS" ] || { echo "ERROR: no object rules for the port in $CMAKE_DIR/libretro."; exit 1; }

# On failure, show the compiler's and make's own error lines, not every line
# with "error" in it (zip_error.c and friends matched that, and hid the real
# one behind warnings on the third Mac run).
# shellcheck disable=SC2086
if ! { cmake --build "$CMAKE_DIR" --config Release -j "$JOBS" --target "${BUILD_TARGETS[@]}" \
       && make -C "$CMAKE_DIR/libretro" -j "$JOBS" $PORT_OBJ_TARGETS; } \
    > "$BUILD_DIR/build-$SUFFIX.log" 2>&1; then
    echo "ERROR: the build failed. The first errors:"
    # Linker WARNINGS (thousands of "built for newer iOS version" lines on the
    # fourth Mac run) are left out, so the line that failed is the one shown.
    grep -nE "(error|fatal error): |\*\*\* \[|Error [0-9]+|[Uu]ndefined symbol|ld: |clang.*: error" "$BUILD_DIR/build-$SUFFIX.log" \
        | grep -v "ld: warning" | head -20
    exit 1
fi

# --- collect the archives -----------------------------------------------------------
#
# The port's own objects (CMake builds the port as a SHARED library, so they are
# taken directly), then the static libraries IN THE ORDER CMake links them, then
# ffmpeg. The order matters and so does NOT force-loading: several archives
# hold an object of the same name (JitState.cpp.o in Common and Core, 7zip's
# LZMA files inside libchdr, xxhash inside zstd), so loading every member of
# every archive defines things twice. The prelink pulls only what the port
# references, as CMake's own link of the .so does.

PORT_OBJS="$(find "$CMAKE_DIR" -path '*ppsspp_libretro.dir*' -name '*.o' | sort)"
[ -n "$PORT_OBJS" ] || { echo "ERROR: the port's objects were not found under $CMAKE_DIR."; exit 1; }
# CMake's order, read from its link rule (the .a files only; ffmpeg is added below).
LINK_LINE="$(cat "$LINK_TXT")"
ARCHIVES=""
for item in $LINK_LINE; do
    case "$item" in
        *ffmpeg*) ;;
        *.a)
            path="$item"
            [ -f "$path" ] || path="$CMAKE_DIR/libretro/$item"
            [ -f "$path" ] || path="$CMAKE_DIR/$item"
            [ -f "$path" ] || { echo "ERROR: CMake links $item, which is not on disk."; exit 1; }
            ARCHIVES="$ARCHIVES $path" ;;
    esac
done
[ -n "$ARCHIVES" ] || { echo "ERROR: could not read CMake's library order from its link rule."; exit 1; }
FFMPEG_LIBS=""
for lib in avformat avcodec swresample swscale avutil; do
    [ -f "$FFMPEG_DIR/lib/lib$lib.a" ] || { echo "ERROR: $FFMPEG_DIR/lib/lib$lib.a is missing."; exit 1; }
    FFMPEG_LIBS="$FFMPEG_LIBS $FFMPEG_DIR/lib/lib$lib.a"
done

# --- what went into it --------------------------------------------------------------

ALL_MEMBERS="$(for a in $ARCHIVES; do ar t "$a" 2>/dev/null; done; for o in $PORT_OBJS; do basename "$o"; done)"
require_member() {
    printf '%s\n' "$ALL_MEMBERS" | grep -qE "^$1$" || { echo "ERROR: $1 absent - $2"; exit 1; }
}
require_member 'libretro\.cpp\.o'               "the libretro port is not in the build."
require_member 'LibretroVulkanContext\.cpp\.o'  "the port's Vulkan context is not in the build; there is no renderer."
require_member 'IRInterpreter\.cpp\.o'          "there is no IR interpreter to run the CPU."

# --- prelink into one object that exports only psp_retro_* ---------------------------

EXPORT_NAMES="$(sed -nE 's/^#define[[:space:]]+retro_[a-z_]+[[:space:]]+(psp_retro_[a-z_]+)[[:space:]]*$/\1/p' "$SYMBOLS_H")"
EXPORT_COUNT="$(printf '%s\n' "$EXPORT_NAMES" | grep -c . || true)"
[ "$EXPORT_COUNT" -ge 20 ] || { echo "ERROR: read only $EXPORT_COUNT names from psp_symbols.h."; exit 1; }

if [ "$HOST" = "1" ]; then
    printf '%s\n' $EXPORT_NAMES > "$BUILD_DIR/exports-elf.txt"
    # A group so the archives resolve each other whatever their order.
    # shellcheck disable=SC2086
    # -d defines common symbols (the prebuilt ffmpeg's) so they can be made
    # private below; built from source they are none.
    ld -r -d -o "$PRELINKED_OBJ" $PORT_OBJS --start-group $ARCHIVES $FFMPEG_LIBS --end-group
    objcopy --keep-global-symbols="$BUILD_DIR/exports-elf.txt" "$PRELINKED_OBJ"
    AR_BIN="ar"
    NM_BIN="nm"
else
    printf '_%s\n' $EXPORT_NAMES > "$BUILD_DIR/exports-macho.txt"
    CLANG_BIN="$(xcrun --sdk iphoneos --find clang)"
    # ld64 searches archives repeatedly by itself; no group needed.
    # shellcheck disable=SC2086
    "$CLANG_BIN" -arch arm64 -isysroot "$IOSSDK" -miphoneos-version-min=16.0 \
        -r -nostdlib $PORT_OBJS $ARCHIVES $FFMPEG_LIBS \
        -Wl,-exported_symbols_list,"$BUILD_DIR/exports-macho.txt" \
        -o "$PRELINKED_OBJ"
    AR_BIN="$(xcrun --sdk iphoneos --find ar)"
    NM_BIN="$(xcrun --sdk iphoneos --find nm)"
fi

rm -f "$OUTPUT_LIB"
"$AR_BIN" rcs "$OUTPUT_LIB" "$PRELINKED_OBJ"

# --- verify the exports (FATAL: the symbol table IS the property being built) ----------

if ! DEFINED="$("$NM_BIN" -g "$PRELINKED_OBJ" 2>&1)"; then
    echo "ERROR: could not read symbols with '$NM_BIN':"
    printf '%s\n' "$DEFINED" | head -5 | sed 's/^/         /'
    exit 1
fi
DEFINED="$(printf '%s\n' "$DEFINED" | awk 'NF >= 3 && $2 != "U" && $2 != "w" && $2 != "v" { print $3 }' | sed 's/^_//' | sort -u)"
EXPECTED="$(printf '%s\n' $EXPORT_NAMES | sort -u)"
EXTRA="$(comm -23 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$EXPECTED"))"
MISSING="$(comm -13 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$EXPECTED"))"
if [ -n "$EXTRA" ]; then
    echo "ERROR: the core exports globals besides its psp_retro_* entry points:"
    printf '%s\n' "$EXTRA" | head -20 | sed 's/^/         /'
    echo "       ($(printf '%s\n' "$EXTRA" | grep -c .) in all)"
    exit 1
fi
if [ -n "$MISSING" ]; then
    echo "ERROR: listed in psp_symbols.h but not defined:"
    printf '%s\n' "$MISSING" | sed 's/^/         /'
    exit 1
fi
echo "Exports: exactly the $EXPORT_COUNT psp_retro_* entry points."

# OpenGL ES: PPSSPP compiles its GLES renderer on iOS (USING_GLES2, part of
# Common and of the port's context choice). It is never SELECTED (the bridge
# asks for Vulkan), but its calls are in the object, so the app must link
# OpenGLES.framework (a system framework, deprecated, still in the SDK and
# accepted by the App Store; RetroArch and PPSSPP's own app link it).
GLES_REFS="$("$NM_BIN" -u "$PRELINKED_OBJ" 2>/dev/null | awk '{ print $NF }' | sed 's/^_//' | grep -cE '^(gl[A-Z]|EAGL)' || true)"
echo "OpenGL ES references left for OpenGLES.framework: $GLES_REFS"

if [ "$HOST" != "1" ]; then
    lipo -info "$OUTPUT_LIB" 2>/dev/null | grep -q 'arm64' || { echo "ERROR: the library is not arm64."; exit 1; }
fi

echo
echo "=== Done ==="
ls -lh "$OUTPUT_LIB"
if [ "$HOST" != "1" ]; then
    echo
    echo "Xcode wiring for this library:"
    echo "  - add $OUTPUT_LIB to the app target's Frameworks phase"
    echo "  - link OpenGLES.framework (the GLES renderer is compiled, never selected)"
    echo "  - library search path: Vendor/ppsspp-ios/lib"
    echo "  - the bridge includes Vendor/ppsspp-ios/psp_symbols.h BEFORE libretro.h"
    echo "  - Vendor/ppsspp-ios/PPSSPP is bundled as a folder reference (the project carries it)"
fi
