#!/bin/bash
# Build the 3DS core (Azahar's own libretro core, Vendor/azahar pinned at
# 2127.0-alpha2) as a static library for iOS (arm64).
#
# Usage:
#   ./build.sh              build lib/libctr-core.a for iOS arm64 (needs Xcode, CMake)
#   ./build.sh clean        remove the build artefacts and the lib
#   HOST=1 ./build.sh       build lib/libctr-core-host.a for THIS machine: the same
#                           sources, choices, renaming and prelink, checked here
#                           before anyone spends Mac time (Tools/3ds-bench)
#
# WHY AZAHAR, AND WHY 2127 (2026-10-16, the 3DS core study): its 2127.0 line
# brings FastInterp, a cached, threaded interpreter for the 3DS's ARM11 written
# for the platforms that cannot JIT (iOS among them), and relicenses the project
# GPL-3.0-or-later. Every other App Store 3DS emulator studied that day ran the
# older DynCom interpreter at 15 to 25 % of the 3DS's clock; Panda3DS has no
# interpreter at all. Measured on the host with Tools/3ds-bench (the app's own
# Vulkan frontend): FastInterp ~3.7x faster than DynCom on the same frames. The
# pin is 2127.0-alpha2 (68202bc), which also carries 2126.2's security fix
# (#2648, a crafted CIA could run code on the host).
#
# WHAT IS BUILT, AND WHAT IS LEFT OUT:
#   renderer  Vulkan only, through the app's MoltenVK (N64VulkanFrontend, as the
#             N64 and the PSP). Upstream already turns OpenGL off on Apple.
#             With ENABLE_LIBRETRO the core does not fetch or link MoltenVK
#             itself: the frontend provides the device.
#   CPU       FastInterp. IOS is defined (upstream's own iOS libretro recipe,
#             .github/workflows/libretro.yml, libretro-ios), which makes the core
#             force the CPU JIT and the shader JIT off and hide both settings
#             (core_settings.cpp). dynarmic is still COMPILED (upstream's CMake
#             adds it to every arm64 build) and never runs: no page is ever
#             mapped executable.
#   keys      NONE. ENABLE_BUILTIN_KEYBLOB=OFF: upstream's default compiles in a
#             blob of the 3DS's AES keys (src/core/hw/default_keys.h, 97
#             entries). Retro Pal ships no console keys (decided 2026-10-16):
#             games must be decrypted, as Azahar itself requires. The export
#             check below FAILS the build if the blob is in it.
#   -fno-common  on every file: a C global defined without an initializer
#             is otherwise a COMMON symbol, which a relocatable link cannot
#             make private, so it leaks out of the prelinked object (first Mac
#             run, 2026-10-19: framelog_t, an accidental global in zstd's
#             seekable format, and LibreSSL's sig_app / sigx_app, whose own
#             -fno-common is added only when CMAKE_SYSTEM_NAME is Darwin, not
#             iOS). The same reason ppsspp-ios/build.sh gives for ffmpeg.
#   off       Qt, SDL, the web service, scripting, GDB stub, OpenAL, cubeb,
#             libusb, ffmpeg and the room server (forced off by upstream's
#             libretro build); tests; LTO (the prelink below is an `ld -r`,
#             which on bitcode writes merged bitcode without hiding a symbol,
#             the reason n64-ios/build.sh gives).
#
# THE VERSION. Azahar stamps its version (common/scm_rev.cpp) into every save
# state and into its shader cache's key, and refuses a state whose version is
# not its own. It reads it from .git/objects, which a submodule does not have
# (its .git is a file): the build then says "UNKNOWN", the state header is the
# hex decoding of that word, and the core refuses its own states (seen on the
# host, 2026-10-16). Upstream's own answer for a tree without git, GIT-COMMIT and
# GIT-TAG at the top of the source (both in its .gitignore), is written below
# from the pinned commit.
#
# SYMBOL ISOLATION, as the N64, the Mega Drive and the PSP do:
#   1. ctr_symbols.h is force-included into every translation unit (through
#      CMAKE_C_FLAGS and CMAKE_CXX_FLAGS), renaming the libretro API to
#      ctr_retro_*.
#   2. the core's objects and every archive it links are pre-linked into ONE
#      relocatable object that exports only those names.
#   The export check at the end FAILS the build if anything else is global.
#
# PATCHES: patches/*.patch, applied in name order to the submodule (reverted
# state checked first), as for the other cores. GPL-3.0 asks that changes be
# stated, and the patch files are that statement.
#   0001  copy upstream's git hook only when .git is a directory (in a
#         submodule it is a file, and the configure stopped)
#   0002  make the shader disk cache after a state load when the title ID is
#         unchanged (a state load of a program with title ID 0 crashed at the
#         next draw: Tools/3ds-bench roundtrip)
#   0003  expose async shader compilation as a core option (the libretro core
#         never set it: every new shader stopped the game for up to seconds)
#   0004  save and load a state without extra copies of the uncompressed state
#         (296 MB for a New 3DS game: resuming was killed for memory on an
#         iPhone 14 Pro)
#   0005  enable on the libretro device the features the renderer assumes
#         (pipeline creation cache control above all: without it every new
#         pipeline compiled on the emulation thread, and the game stopped)
#   0006  core option to let async shader compilation skip small draws too
#         (they still waited for their pipeline: a Metal compile each)
#   0007  write the archives' host paths in a save state as placeholders, and
#         move an older state's paths to the current data container (iOS gives
#         the app a new container on reinstall: after resuming such a state,
#         every in-game save failed)
#   0008  core option so async shader compilation never builds a pipeline on
#         the emulation thread (the driver's "quick" probe still compiled a
#         Metal pipeline state on MoltenVK; software-vertex draws always waited)
#   0009  faster state loads: queued pipeline builds dropped instead of waited
#         for, no empty driver cache saved over title 0, a 64 MiB upload ring
#         instead of 512 MiB
#   0010  read the frontend's microphone for the whole frame (one 128-sample
#         read per frame gave the game a sixth of its signal)
#   0011  cheats through retro_cheat_set / retro_cheat_reset (they were empty),
#         and one cheat event after a state load (each load doubled the runs)
#   0012  the 3DS's cameras from the frontend's, through libretro's camera
#         interface (they were always blank in the libretro core)
#   0013  a build without OpenSSL / LibreSSL (CITRA_NO_OPENSSL, on here): the
#         OpenSSL licence's advertising clause does not sit with the GPL,
#         and no TLS library is linked; the 3DS's HTTP service keeps plain
#         http, an https request fails as a network error
#   0014  raw states for a rewind: retro_ctr_rewind_capture / _restore, the
#         state without its zstd compression, into a buffer kept between calls
#   0015  rewind states without the emulated memories: the frontend keeps its
#         own copy of the four memory arrays and writes it back after a load
#   0016  keep the video side across a state load of the running title (GPU,
#         renderer, pipelines, memory system): restore 290 -> 100 ms on the host
#   0017  free the texture cache's surfaces when a state save or load clears
#         it (they leaked at every rewind snapshot: 75 -> 1546 in 17)
#   0018  keep the queued shader compiles when the pipeline cache goes (0009
#         dropped them, and a pipeline build waiting for one hung a quit)
#   0019  the module linker invalidates the code cache once per call, not once
#         per relocation (each one walked FastInterp's whole block cache on
#         every core: 0.55 s frozen when Pokemon Sun loads its field module)
#   0020  a rewind state no longer sets the size the next save reserves (a
#         12 MB rewind state made every later save grow its 296 MB buffer by
#         doubling: the peak 0004 removed, back in the background auto-save)
#   0021  retro_run stops and tells the frontend (RETRO_ENVIRONMENT_SHUTDOWN)
#         when the game has ended: a game that closed itself, or an in-game
#         reboot that left the console off, looped for good under the lock

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AZAHAR_SRC="$SCRIPT_DIR/../azahar"
LIB_DIR="$SCRIPT_DIR/lib"
BUILD_DIR="$SCRIPT_DIR/build"
SYMBOLS_H="$SCRIPT_DIR/ctr_symbols.h"

HOST="${HOST:-0}"
if [ "$HOST" = "1" ]; then
    OUTPUT_LIB="$LIB_DIR/libctr-core-host.a"
    SUFFIX="host"
else
    OUTPUT_LIB="$LIB_DIR/libctr-core.a"
    SUFFIX="ios"
fi
CMAKE_DIR="$BUILD_DIR/cmake-$SUFFIX"
PRELINKED_OBJ="$BUILD_DIR/ctr-core-$SUFFIX.o"

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning..."
    rm -rf "$LIB_DIR" "$BUILD_DIR"
    echo "Done."
    exit 0
fi

# A `git pull` brings the submodule's POINTER, not its files: fetch them here
# (shallow, at the pinned commit, with Azahar's own submodules) rather than stop
# on the first build after it.
if [ ! -f "$AZAHAR_SRC/CMakeLists.txt" ]; then
    echo "Fetching Vendor/azahar (the pinned Azahar, shallow)..."
    git -C "$SCRIPT_DIR/.." submodule update --init --depth 1 azahar
fi
if [ ! -f "$AZAHAR_SRC/CMakeLists.txt" ]; then
    echo "ERROR: Azahar sources not found at $AZAHAR_SRC, and fetching them failed."
    exit 1
fi
# Every one of Azahar's submodules, recursively (dynarmic's own mcl, zydis and
# robin-map are needed to CONFIGURE, though dynarmic never runs on iOS).
if [ -z "$(ls -A "$AZAHAR_SRC/externals/dynarmic/externals/mcl" 2>/dev/null)" ] \
   || [ -z "$(ls -A "$AZAHAR_SRC/externals/boost" 2>/dev/null)" ]; then
    echo "Fetching Azahar's own submodules (recursive, shallow)..."
    git -C "$AZAHAR_SRC" submodule update --init --recursive --depth 1 --jobs 8
fi

# --- the version (see THE VERSION above) -----------------------------------------

AZAHAR_COMMIT="$(git -C "$AZAHAR_SRC" rev-parse HEAD)"
# The tag of the pin, named here: the shallow submodule fetch brings the
# commit without its tag (first Mac run: "Azahar unknown"), so asking git gives
# a different answer depending on how the tree was fetched. The commit is
# checked against it, so a moved pin without this line moving stops here.
PINNED_TAG="2127.0-alpha2"
PINNED_COMMIT="68202bc4ff7edf9d7280ec0dcd6572b7cd1ae26e"
if [ "$AZAHAR_COMMIT" != "$PINNED_COMMIT" ]; then
    echo "ERROR: Vendor/azahar is at $AZAHAR_COMMIT, but this script names $PINNED_TAG ($PINNED_COMMIT)."
    echo "       Moving the pin: update PINNED_TAG and PINNED_COMMIT here, and re-check the patches."
    exit 1
fi
AZAHAR_TAG="$PINNED_TAG"
printf '%s\n' "$AZAHAR_COMMIT" > "$AZAHAR_SRC/GIT-COMMIT"
printf '%s\n' "$AZAHAR_TAG" > "$AZAHAR_SRC/GIT-TAG"
echo "Azahar $AZAHAR_TAG ($AZAHAR_COMMIT)"

# --- patches ------------------------------------------------------------------

# Checked as a SERIES, not one patch at a time: two of them change the same
# lines (0006 adds to what 0003 added in core_settings.cpp), and once both are
# in, 0003 alone no longer reverses cleanly, which a per-patch check reads as
# "applies neither way". So: the series is applied when its patches reverse one
# by one, newest first, in a scratch copy of the files they touch. Otherwise
# those files are put back to the pinned commit and the whole series applied
# in name order; a patch that then fails stops the build.
PATCH_DIR="$SCRIPT_DIR/patches"
PATCH_APPLIED_NOW=0
PATCHES=()
for patch in "$PATCH_DIR"/*.patch; do
    [ -e "$patch" ] && PATCHES+=("$patch")
done
if [ "${#PATCHES[@]}" -gt 0 ]; then
    TOUCHED="$(for patch in "${PATCHES[@]}"; do git -C "$AZAHAR_SRC" apply --numstat "$patch" | cut -f3; done | sort -u)"
    SCRATCH="$(mktemp -d)"
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        mkdir -p "$SCRATCH/$(dirname "$file")"
        if [ -e "$AZAHAR_SRC/$file" ]; then cp "$AZAHAR_SRC/$file" "$SCRATCH/$file"; fi
    done <<< "$TOUCHED"
    SERIES_APPLIED=1
    for (( i=${#PATCHES[@]}-1; i>=0; i-- )); do
        if ! git -C "$SCRATCH" apply --reverse "${PATCHES[$i]}" 2>/dev/null; then
            SERIES_APPLIED=0
            break
        fi
    done
    rm -rf "$SCRATCH"

    if [ "$SERIES_APPLIED" = "1" ]; then
        for patch in "${PATCHES[@]}"; do echo "Patch already applied: $(basename "$patch")"; done
    else
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            # A file a patch CREATES is not at the pin (0012's camera): it is
            # removed, so the patch can make it again.
            if git -C "$AZAHAR_SRC" cat-file -e "$PINNED_COMMIT:$file" 2>/dev/null; then
                git -C "$AZAHAR_SRC" checkout "$PINNED_COMMIT" -- "$file"
            else
                rm -f "$AZAHAR_SRC/$file"
            fi
        done <<< "$TOUCHED"
        for patch in "${PATCHES[@]}"; do
            if git -C "$AZAHAR_SRC" apply "$patch" 2>/dev/null; then
                echo "Patch applied: $(basename "$patch")"
            else
                echo "ERROR: $(basename "$patch") does not apply to the pinned source after the"
                echo "       patches before it. Re-make it against the pinned source."
                exit 1
            fi
        done
        PATCH_APPLIED_NOW=1
    fi
fi
if [ "$PATCH_APPLIED_NOW" = "1" ] && [ -f "$OUTPUT_LIB" ]; then
    echo "The core was patched after this library was built - rebuilding it."
    rm -f "$OUTPUT_LIB"
fi

# What the library was built from: the patches, the export list and this
# script, by content, in a stamp beside it. "Applied in this run" alone missed
# a library built before a patch was added in a tree where the series already
# reversed cleanly (a host build, then an iOS one, share the tree): it was
# reported "already built" and the old core shipped without a word (audit,
# 2026-10-20, when 0020 and 0021 were added).
if command -v shasum >/dev/null 2>&1; then HASH=(shasum -a 256); else HASH=(sha256sum); fi
BUILD_INPUTS="$(cat "${PATCHES[@]}" "$SYMBOLS_H" "$0" | "${HASH[@]}" | awk '{ print $1 }')"
STAMP="$OUTPUT_LIB.inputs"
if [ -f "$OUTPUT_LIB" ] && [ "$(cat "$STAMP" 2>/dev/null)" != "$BUILD_INPUTS" ]; then
    echo "This library was built from other patches or another export list - rebuilding it."
    rm -f "$OUTPUT_LIB"
fi

if [ -f "$OUTPUT_LIB" ]; then
    echo "$(basename "$OUTPUT_LIB") already built. Run '$0 clean' to rebuild."
    exit 0
fi

command -v cmake >/dev/null 2>&1 || { echo "ERROR: cmake not found."; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "ERROR: ninja not found (brew install ninja)."; exit 1; }
mkdir -p "$LIB_DIR" "$BUILD_DIR"
rm -f "$PRELINKED_OBJ"

# --- configure and build --------------------------------------------------------
#
# Configured FROM SCRATCH every time (its cache removed first): CMake reads the
# platform choice only when a folder is first configured and silently keeps the
# old one afterwards, the trap ppsspp-ios/build.sh met on its second Mac run.
rm -rf "$CMAKE_DIR/CMakeCache.txt" "$CMAKE_DIR/CMakeFiles"

COMMON_OPTIONS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DENABLE_LIBRETRO=ON
    -DCITRA_NO_OPENSSL=ON
    -DENABLE_BUILTIN_KEYBLOB=OFF
    -DENABLE_OPENGL=OFF
    -DENABLE_VULKAN=ON
    -DENABLE_TESTS=OFF
    -DENABLE_LTO=OFF
    -DCITRA_USE_PRECOMPILED_HEADERS=OFF
    -DCITRA_WARNINGS_AS_ERRORS=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -Wno-dev
)

if [ "$HOST" = "1" ]; then
    echo "=== Configuring Azahar (libretro) for THIS HOST (verification only) ==="
    # No IOS define here: the host keeps the JIT and its option so that
    # Tools/3ds-bench can measure FastInterp, DynCom and the JIT side by side.
    cmake -S "$AZAHAR_SRC" -B "$CMAKE_DIR" "${COMMON_OPTIONS[@]}" \
        -DCMAKE_C_COMPILER="${CTR_HOST_CC:-clang}" -DCMAKE_CXX_COMPILER="${CTR_HOST_CXX:-clang++}" \
        "-DCMAKE_C_FLAGS=-include $SYMBOLS_H -fno-common" "-DCMAKE_CXX_FLAGS=-include $SYMBOLS_H -fno-common" \
        > "$BUILD_DIR/configure-$SUFFIX.log" 2>&1 || { tail -30 "$BUILD_DIR/configure-$SUFFIX.log"; exit 1; }
else
    command -v xcrun >/dev/null 2>&1 || { echo "ERROR: xcrun not found. This path needs Xcode."; exit 1; }
    IOSSDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    echo "=== Configuring Azahar (libretro) for iOS arm64 ==="
    echo "SDK: $IOSSDK"
    # Upstream's own iOS recipe (libretro.yml, libretro-ios): CMake's iOS
    # platform, IOS=ON, -DIOS in the compile flags (the define the core reads to
    # turn the JITs off), arm64, no precompiled headers. Deployment target = the
    # app's (upstream builds for 14.0).
    # -Wno-nonportable-include-path: a shell whose working directory differs in
    # case from the disk made every file warn about the forced include's
    # spelling (ppsspp-ios/build.sh, third Mac run).
    cmake -S "$AZAHAR_SRC" -B "$CMAKE_DIR" "${COMMON_OPTIONS[@]}" \
        -DCMAKE_SYSTEM_NAME=iOS -DIOS=ON \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DENABLE_OPT=OFF \
        "-DCMAKE_C_FLAGS=-DIOS -include $SYMBOLS_H -fno-common -Wno-nonportable-include-path" \
        "-DCMAKE_CXX_FLAGS=-DIOS -include $SYMBOLS_H -fno-common -Wno-nonportable-include-path" \
        > "$BUILD_DIR/configure-$SUFFIX.log" 2>&1 || { tail -30 "$BUILD_DIR/configure-$SUFFIX.log"; exit 1; }
fi

echo "=== Building (log: $BUILD_DIR/build-$SUFFIX.log) ==="
# What is built: the core's OBJECTS and the static libraries its link rule
# names, never the core's own shared library: on Apple that link carries
# upstream's export list (libretro.osx.def: _retro_run and the rest), names
# ctr_symbols.h has renamed, and fails, the failure ppsspp-ios/build.sh met on
# its fifth Mac run. Ninja is asked for the link rule's INPUTS.
# The output's path is read from Ninja's own target list rather than assumed:
# bin/Release/azahar_libretro.so on Linux, .dylib on Apple.
CORE_OUTPUT="$(ninja -C "$CMAKE_DIR" -t targets all 2>/dev/null \
               | sed -n 's#^\(bin/[^:]*/azahar_libretro\.[a-z]*\): .*#\1#p' | head -1)"
[ -n "$CORE_OUTPUT" ] || { echo "ERROR: no azahar_libretro output among $CMAKE_DIR's targets."; exit 1; }
LINK_INPUTS="$(ninja -C "$CMAKE_DIR" -t query "$CORE_OUTPUT" 2>/dev/null || true)"
[ -n "$LINK_INPUTS" ] || { echo "ERROR: cannot read the link rule of $CORE_OUTPUT."; exit 1; }
# `ninja -t query` prints "<output>:", "  input: <rule>", then one input per
# line indented four spaces: the core's objects as they are, the archives
# behind "| " (implicit dependencies), order-only ones behind "|| ", until
# "  outputs:". Only objects and archives are kept.
INPUTS="$(printf '%s\n' "$LINK_INPUTS" | awk '/^  input:/{on=1; next} /^  outputs:/{on=0} on {print $NF}' \
          | grep -E '\.(o|a)$' | sort -u)"
PORT_OBJS="$(printf '%s\n' "$INPUTS" | grep '\.o$' | sed "s#^#$CMAKE_DIR/#")"
[ -n "$PORT_OBJS" ] || { echo "ERROR: no object inputs read from the core's link rule."; exit 1; }

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
# shellcheck disable=SC2086
if ! ninja -C "$CMAKE_DIR" -j "$JOBS" $(printf '%s\n' "$INPUTS") > "$BUILD_DIR/build-$SUFFIX.log" 2>&1; then
    echo "ERROR: the build failed. The first errors:"
    grep -nE "(error|fatal error): |FAILED: |[Uu]ndefined symbol|ld: |clang.*: error" "$BUILD_DIR/build-$SUFFIX.log" \
        | grep -v "ld: warning" | head -20
    exit 1
fi

# --- collect the archives -----------------------------------------------------------
#
# The core's own objects (taken directly: CMake builds the core as a SHARED
# library), then the static libraries, read from the link command IN ITS
# ORDER (the query above lists inputs, not their order). Not force-loaded:
# only what the core references is pulled, as CMake's own link does.

LINK_CMD="$(ninja -C "$CMAKE_DIR" -t commands "$CORE_OUTPUT" | tail -1)"
ARCHIVES=""
for item in $LINK_CMD; do
    case "$item" in
        *.a)
            path="$item"
            [ -f "$path" ] || path="$CMAKE_DIR/$item"
            [ -f "$path" ] || { echo "ERROR: CMake links $item, which is not on disk."; exit 1; }
            ARCHIVES="$ARCHIVES $path" ;;
    esac
done
[ -n "$ARCHIVES" ] || { echo "ERROR: could not read CMake's library order from its link command."; exit 1; }

# --- what went into it --------------------------------------------------------------

# Archive members are listed with their build path; matched on the file name.
ALL_MEMBERS="$(for a in $ARCHIVES; do ar t "$a" 2>/dev/null; done | sed 's#.*/##'; for o in $PORT_OBJS; do basename "$o"; done)"
require_member() {
    # A here-string, not `printf | grep -q`: grep -q exits at its first match,
    # printf's next write then dies of SIGPIPE, and pipefail reported a member
    # that IS there as absent (seen 2026-10-19 on an incremental host build,
    # twice in a row, then not: it depends on timing).
    grep -qE "^$1$" <<< "$ALL_MEMBERS" || { echo "ERROR: $1 absent - $2"; exit 1; }
}
require_member 'citra_libretro\.cpp\.o'  "the libretro core is not in the build."
require_member 'libretro_vk\.cpp\.o'     "the core's Vulkan path is not in the build; there is no renderer."
require_member 'fastinterp\.cpp\.o'      "there is no FastInterp to run the CPU."
# No console keys. The blob is a header compiled into hw/aes/key.cpp, so it is
# looked for as what it leaves there: the local symbol default_keys_enc (proved
# 2026-10-16 by compiling key.cpp both ways: present with the blob, absent
# without). Any NM reads the archives here, symbols local or not.
CHECK_NM="nm"
[ "$HOST" = "1" ] || CHECK_NM="$(xcrun --sdk iphoneos --find nm)"
# The symbol table is read whole before it is searched, for require_member's
# reason, and here it matters more: under pipefail an nm killed by SIGPIPE after
# grep -q matched would turn "the blob is in" into "it is not".
# shellcheck disable=SC2086
KEY_SYMBOLS="$("$CHECK_NM" -a $ARCHIVES $PORT_OBJS 2>/dev/null)" \
    || { echo "ERROR: could not read the symbols with '$CHECK_NM', so the build cannot be shown to carry no console keys."; exit 1; }
if grep -q 'default_keys_enc' <<< "$KEY_SYMBOLS"; then
    echo "ERROR: the built-in AES key blob (default_keys_enc) is in the build. Retro Pal ships no console keys."
    exit 1
fi

# --- prelink into one object that exports only ctr_retro_* ---------------------------

EXPORT_NAMES="$(sed -nE 's/^#define[[:space:]]+retro_[a-z_]+[[:space:]]+(ctr_retro_[a-z_]+)[[:space:]]*$/\1/p' "$SYMBOLS_H")"
EXPORT_COUNT="$(printf '%s\n' "$EXPORT_NAMES" | grep -c . || true)"
[ "$EXPORT_COUNT" -eq 27 ] || { echo "ERROR: read $EXPORT_COUNT names from ctr_symbols.h, expected 27."; exit 1; }

if [ "$HOST" = "1" ]; then
    # The host CANNOT hide symbols in a relocatable object the way the phone
    # does. On ELF, `objcopy --keep-global-symbols` turns the C++ COMDAT
    # (inline and template) definitions local, and the next link discards
    # their sections ("defined in discarded section", first run 2026-10-16);
    # BlastEm is C and never met it. ld64's -exported_symbols_list keeps weak
    # definitions coherent, which is why the iOS branch below is an `-r`. Here
    # the same property is built the way ELF does it: ONE shared object linked
    # with a version script that exports only ctr_retro_*, from the same
    # objects and archives, with --no-undefined proving the core is complete.
    # The archive below still holds the plain `-r` object (not localized) so
    # the export check reads the shared object's dynamic table instead.
    {
        echo "{ global:"
        printf '  %s;\n' $EXPORT_NAMES
        echo "local: *; };"
    } > "$BUILD_DIR/exports-elf.map"
    # shellcheck disable=SC2086
    ld -r -o "$PRELINKED_OBJ" $PORT_OBJS --start-group $ARCHIVES --end-group
    HOST_SO="$LIB_DIR/libctr-core-host.so"
    "${CTR_HOST_CXX:-clang++}" -shared -o "$HOST_SO" "$PRELINKED_OBJ" \
        -Wl,--version-script="$BUILD_DIR/exports-elf.map" -Wl,--no-undefined \
        -lstdc++ -lm -lpthread -ldl
    AR_BIN="ar"
    NM_BIN="nm"
else
    printf '_%s\n' $EXPORT_NAMES > "$BUILD_DIR/exports-macho.txt"
    CLANG_BIN="$(xcrun --sdk iphoneos --find clang)"
    # shellcheck disable=SC2086
    "$CLANG_BIN" -arch arm64 -isysroot "$IOSSDK" -miphoneos-version-min=16.0 \
        -r -nostdlib $PORT_OBJS $ARCHIVES \
        -Wl,-exported_symbols_list,"$BUILD_DIR/exports-macho.txt" \
        -o "$PRELINKED_OBJ"
    AR_BIN="$(xcrun --sdk iphoneos --find ar)"
    NM_BIN="$(xcrun --sdk iphoneos --find nm)"
fi

rm -f "$OUTPUT_LIB"
"$AR_BIN" rcs "$OUTPUT_LIB" "$PRELINKED_OBJ"

# --- verify the exports (FATAL: the symbol table IS the property being built) ----------

CHECKED="$PRELINKED_OBJ"
NM_ARGS=(-g)
if [ "$HOST" = "1" ]; then CHECKED="$HOST_SO"; NM_ARGS=(-D --defined-only); fi
if ! DEFINED="$("$NM_BIN" "${NM_ARGS[@]}" "$CHECKED" 2>&1)"; then
    echo "ERROR: could not read symbols with '$NM_BIN':"
    printf '%s\n' "$DEFINED" | head -5 | sed 's/^/         /'
    exit 1
fi
DEFINED="$(printf '%s\n' "$DEFINED" | awk 'NF >= 3 && $2 != "U" && $2 != "w" && $2 != "v" { print $3 }' | sed 's/^_//' | sort -u)"
EXPECTED="$(printf '%s\n' $EXPORT_NAMES | sort -u)"
EXTRA="$(comm -23 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$EXPECTED"))"
MISSING="$(comm -13 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$EXPECTED"))"
if [ -n "$EXTRA" ]; then
    echo "ERROR: the core exports globals besides its ctr_retro_* entry points:"
    printf '%s\n' "$EXTRA" | head -20 | sed 's/^/         /'
    echo "       ($(printf '%s\n' "$EXTRA" | grep -c .) in all)"
    exit 1
fi
if [ -n "$MISSING" ]; then
    echo "ERROR: listed in ctr_symbols.h but not defined:"
    printf '%s\n' "$MISSING" | sed 's/^/         /'
    exit 1
fi
echo "Exports: exactly the $EXPORT_COUNT ctr_retro_* entry points."

if [ "$HOST" != "1" ]; then
    lipo -info "$OUTPUT_LIB" 2>/dev/null | grep -q 'arm64' || { echo "ERROR: the library is not arm64."; exit 1; }
fi

printf '%s\n' "$BUILD_INPUTS" > "$STAMP"

echo
echo "=== Done ==="
ls -lh "$OUTPUT_LIB"
