#!/bin/bash
# Build the archive readers (libarchive over xz's liblzma) as ONE static
# library for iOS (arm64): what lets a game be imported from a .7z, a .rar
# (RAR4 and RAR5), a .tar, a .tar.gz / .tgz, a .tar.xz, or a lone .gz / .xz,
# beside the .zip the app has always read itself (ZIPExtractor).
#
# Usage:
#   ./build.sh              build lib/libarchive-ios.a for iOS arm64 (needs Xcode, CMake)
#   ./build.sh clean        remove the build artefacts and the lib
#   HOST=1 ./build.sh       build lib/libarchive-host.a + .so for THIS machine: the
#                           same sources and choices, checked here before any Mac
#                           time (Tools/archive-probe extracts real archives with it)
#
# WHY THESE TWO (2026-10-27, decided the same day: every main archive format, in 1.3.5):
#   libarchive (Vendor/libarchive, BSD-2-Clause, pinned at v3.8.9): the one
#     reader of RAR whose licence fits the GPL. RARLAB's UnRAR forbids
#     re-creating the RAR compressor and is not GPL-compatible; libarchive's
#     RAR and RAR5 readers are its own code. It also reads 7z, tar, gzip, xz.
#     v3.8.9 and not older: every release since 3.8.1 hardens the 7z and RAR5
#     readers (header counts, varints, unpacked-size limits).
#   xz's liblzma (Vendor/xz, 0BSD, pinned at v5.8.4): libarchive decodes a 7z's
#     LZMA and LZMA2, nearly every 7z there is, ONLY through liblzma, and iOS
#     ships no liblzma (its Compression framework is not a stream library
#     libarchive can call). Measured on the host 2026-10-27: without it a 7z
#     lists and does not extract. 5.8.x is after the 2024 backdoor (5.6.0 and
#     5.6.1, in release tarballs' build scripts); this builds from git.
#   zlib and bzip2: the iPhone's own (libz.tbd, libbz2.tbd, linked by the app),
#     for .gz, the zip-in-7z Deflate and a 7z's BZip2.
#
# WHAT IS BUILT, AND WHAT IS LEFT OUT: the READ side only. No writers, no
#   bsdtar/bsdcpio/bsdcat/unzip tools, no tests, no crypto (OpenSSL, mbedTLS,
#   Nettle off: an encrypted archive is refused, by name, as an encrypted zip
#   already is), no xattr/ACL, no iconv (names are taken as UTF-8, which 7z
#   and RAR5 store; RAR4 and tar names are decoded by libarchive's own
#   fallbacks), no LZ4/LZO/zstd/xml.
#
# SYMBOL ISOLATION, as every core is built: the two libraries are pre-linked
# into ONE relocatable object that exports only the libarchive functions the
# bridge (EmulateurGBA/Data/FileStorage/GameArchiveReader.c) calls. Both carry generic names (libarchive's Ppmd8_*,
# blake2sp_*, pack_find; liblzma's lzma_*), and the LZMA SDK is already in this
# binary through MesenCE (LzmaDec_*, Ppmd7_*) and PCSX-ReARMed (lzma_codec_*):
# none clash today (checked 2026-10-27), and after this none can. The export
# check at the end FAILS the build if anything else is global.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBARCHIVE_SRC="$SCRIPT_DIR/../libarchive"
XZ_SRC="$SCRIPT_DIR/../xz"
LIB_DIR="$SCRIPT_DIR/lib"
BUILD_DIR="$SCRIPT_DIR/build"
HOST="${HOST:-0}"

LIBARCHIVE_PIN="27cbc7827172698143e440801fc0ba39ccb4f1f5"   # v3.8.9
XZ_PIN="d3e650e63c110e830fd5391e7f8b45df0b91d3da"           # v5.8.4

if [ "$HOST" = "1" ]; then
    SUFFIX="host"
    OUTPUT_LIB="$LIB_DIR/libarchive-host.a"
else
    SUFFIX="ios"
    OUTPUT_LIB="$LIB_DIR/libarchive-ios.a"
fi

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning..."
    rm -rf "$BUILD_DIR" "$LIB_DIR"
    echo "Done."
    exit 0
fi

# A `git pull` brings the submodules' POINTERS, not their files.
for pair in "libarchive:$LIBARCHIVE_SRC/CMakeLists.txt" "xz:$XZ_SRC/CMakeLists.txt"; do
    name="${pair%%:*}"; probe="${pair#*:}"
    if [ ! -f "$probe" ]; then
        echo "Fetching Vendor/$name (submodule)..."
        git -C "$SCRIPT_DIR/.." submodule update --init --depth 1 "$name"
    fi
done

# The pins, checked: a moved submodule builds something nobody reviewed.
for pair in "$LIBARCHIVE_SRC:$LIBARCHIVE_PIN" "$XZ_SRC:$XZ_PIN"; do
    src="${pair%%:*}"; pin="${pair#*:}"
    head="$(git -C "$src" rev-parse HEAD)"
    if [ "$head" != "$pin" ]; then
        echo "ERROR: $(basename "$src") is at $head, the pin is $pin."
        echo "       Moving a pin is a decision: update it here, with the reason, in the same commit."
        exit 1
    fi
done

mkdir -p "$LIB_DIR" "$BUILD_DIR"

# Rebuilt only when an input changed: the pins, this script.
STAMP="$LIB_DIR/.inputs-$SUFFIX"
BUILD_INPUTS="$LIBARCHIVE_PIN $XZ_PIN $(cksum < "$0")"
if [ -f "$OUTPUT_LIB" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$BUILD_INPUTS" ]; then
    echo "Up to date: $OUTPUT_LIB"
    exit 0
fi

XZ_BUILD="$BUILD_DIR/xz-$SUFFIX"
XZ_INSTALL="$BUILD_DIR/xz-install-$SUFFIX"
LA_BUILD="$BUILD_DIR/libarchive-$SUFFIX"
rm -rf "$XZ_BUILD" "$XZ_INSTALL" "$LA_BUILD"

PLATFORM_OPTIONS=()
if [ "$HOST" = "1" ]; then
    PLATFORM_OPTIONS+=(-DCMAKE_C_COMPILER="${ARCHIVE_HOST_CC:-cc}" -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
    # This machine has no bzlib.h; the iPhone has libbz2. The host checks
    # everything else; a 7z's BZip2 is checked on the phone.
    BZIP2_OPTION=-DENABLE_BZip2=OFF
else
    command -v xcrun >/dev/null 2>&1 || { echo "ERROR: xcrun not found. This path needs Xcode."; exit 1; }
    IOSSDK="$(xcrun --sdk iphoneos --show-sdk-path)"
    echo "SDK: $IOSSDK"
    PLATFORM_OPTIONS+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64
                       -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_OSX_SYSROOT="$IOSSDK")
    BZIP2_OPTION=-DENABLE_BZip2=ON
fi

echo "=== liblzma (xz $(git -C "$XZ_SRC" describe --tags)) for $SUFFIX ==="
cmake -S "$XZ_SRC" -B "$XZ_BUILD" "${PLATFORM_OPTIONS[@]}" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF \
    -DXZ_TOOL_SCRIPTS=OFF -DXZ_TOOL_SYMLINKS=OFF -DXZ_TOOL_SYMLINKS_LZMA=OFF \
    -DXZ_DOC=OFF -DXZ_NLS=OFF -DXZ_DOXYGEN=OFF \
    -DCMAKE_INSTALL_PREFIX="$XZ_INSTALL" \
    > "$BUILD_DIR/xz-configure-$SUFFIX.log" 2>&1 || { tail -30 "$BUILD_DIR/xz-configure-$SUFFIX.log"; exit 1; }
cmake --build "$XZ_BUILD" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" --target liblzma \
    > "$BUILD_DIR/xz-build-$SUFFIX.log" 2>&1 || { tail -30 "$BUILD_DIR/xz-build-$SUFFIX.log"; exit 1; }
cmake --install "$XZ_BUILD" > "$BUILD_DIR/xz-install-$SUFFIX.log" 2>&1 \
    || { tail -30 "$BUILD_DIR/xz-install-$SUFFIX.log"; exit 1; }
LZMA_LIB="$XZ_INSTALL/lib/liblzma.a"
[ -f "$LZMA_LIB" ] || { echo "ERROR: liblzma.a was not produced."; exit 1; }

echo "=== libarchive ($(git -C "$LIBARCHIVE_SRC" describe --tags)) for $SUFFIX ==="
cmake -S "$LIBARCHIVE_SRC" -B "$LA_BUILD" "${PLATFORM_OPTIONS[@]}" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_TEST=OFF \
    -DENABLE_INSTALL=OFF \
    -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_CNG=OFF \
    -DENABLE_LIBB2=OFF -DENABLE_LZ4=OFF -DENABLE_LZO=OFF -DENABLE_ZSTD=OFF \
    -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_WIN32_XMLLITE=OFF \
    -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF -DENABLE_ICONV=OFF \
    -DENABLE_ACL=OFF -DENABLE_XATTR=OFF \
    -DENABLE_ZLIB=ON "$BZIP2_OPTION" \
    -DENABLE_LZMA=ON -DLIBLZMA_INCLUDE_DIR="$XZ_INSTALL/include" -DLIBLZMA_LIBRARY="$LZMA_LIB" \
    > "$BUILD_DIR/libarchive-configure-$SUFFIX.log" 2>&1 \
    || { tail -30 "$BUILD_DIR/libarchive-configure-$SUFFIX.log"; exit 1; }

# The decoders the app relies on, read from the configured header: a missing
# one would build a library that lists a 7z and cannot extract it.
CONFIG_H="$LA_BUILD/config.h"
grep -q '^#define HAVE_LZMA_H 1' "$CONFIG_H" || { echo "ERROR: libarchive configured without liblzma (no 7z LZMA/LZMA2)."; exit 1; }
grep -q '^#define HAVE_ZLIB_H 1' "$CONFIG_H" || { echo "ERROR: libarchive configured without zlib (no .gz)."; exit 1; }
if [ "$HOST" != "1" ]; then
    grep -q '^#define HAVE_BZLIB_H 1' "$CONFIG_H" || { echo "ERROR: libarchive configured without bzip2 (no 7z BZip2)."; exit 1; }
fi

cmake --build "$LA_BUILD" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" --target archive_static \
    > "$BUILD_DIR/libarchive-build-$SUFFIX.log" 2>&1 \
    || { tail -30 "$BUILD_DIR/libarchive-build-$SUFFIX.log"; exit 1; }
LA_LIB="$(find "$LA_BUILD" -name 'libarchive.a' -o -name 'libarchive_static.a' | head -1)"
[ -n "$LA_LIB" ] && [ -f "$LA_LIB" ] || { echo "ERROR: libarchive's static library was not produced."; exit 1; }

# --- prelink into one object that exports only what the app calls -------------
#
# The names are the libarchive functions the app's bridge calls, read from that
# bridge (EmulateurGBA/Data/FileStorage/GameArchiveReader.c), so the two cannot
# disagree. They are the link's ROOTS as well as its exports: only the objects
# they reach are pulled in, never the whole archive. That matters beyond size:
# libarchive's tree holds files under other licences (BLAKE2, the compress
# filter's UC Regents BSD-3, a public-domain date parser), and a whole-archive
# link compiled them all into the app (found 2026-10-27 reading the first
# build's symbols). What is in the binary is what the credits must name.
PRELINKED_OBJ="$BUILD_DIR/archive-prelinked-$SUFFIX.o"
BRIDGE_C="$SCRIPT_DIR/../../EmulateurGBA/Data/FileStorage/GameArchiveReader.c"
[ -f "$BRIDGE_C" ] || { echo "ERROR: the bridge $BRIDGE_C is missing."; exit 1; }
EXPORT_NAMES="$(grep -oE '\barchive_[a-z0-9_]+[[:space:]]*\(' "$BRIDGE_C" | sed -E 's/[[:space:]]*\($//' | sort -u)"
EXPORT_COUNT="$(printf '%s\n' "$EXPORT_NAMES" | grep -c . || true)"
[ "$EXPORT_COUNT" -ge 20 ] || { echo "ERROR: read only $EXPORT_COUNT libarchive calls from the bridge."; exit 1; }
LIBS="$LA_LIB $LZMA_LIB"

if [ "$HOST" = "1" ]; then
    # ELF cannot localise a relocatable object's symbols the way ld64 does, so
    # the same property is shown by linking ONE shared object with a version
    # script, and --no-undefined proving the pair is complete against zlib.
    UNDEF_ARGS=()
    for name in $EXPORT_NAMES; do UNDEF_ARGS+=(-u "$name"); done
    ld -r -o "$PRELINKED_OBJ" "${UNDEF_ARGS[@]}" --start-group $LIBS --end-group
    {
        echo "{ global:"
        printf '  %s;\n' $EXPORT_NAMES
        echo "local: *; };"
    } > "$BUILD_DIR/exports-elf.map"
    HOST_SO="$LIB_DIR/libarchive-host.so"
    "${ARCHIVE_HOST_CC:-cc}" -shared -o "$HOST_SO" "$PRELINKED_OBJ" \
        -Wl,--version-script="$BUILD_DIR/exports-elf.map" -Wl,--no-undefined -lz -lpthread
    AR_BIN="ar"
    NM_BIN="nm"
    CHECKED="$HOST_SO"; NM_ARGS=(-D --defined-only)
else
    printf '_%s\n' $EXPORT_NAMES > "$BUILD_DIR/exports-macho.txt"
    CLANG_BIN="$(xcrun --sdk iphoneos --find clang)"
    UNDEF_ARGS=()
    for name in $EXPORT_NAMES; do UNDEF_ARGS+=(-Wl,-u,"_$name"); done
    # zlib and bzip2 stay UNDEFINED here: the app links the system's.
    # shellcheck disable=SC2086
    "$CLANG_BIN" -arch arm64 -isysroot "$IOSSDK" -miphoneos-version-min=16.0 \
        -r -nostdlib "${UNDEF_ARGS[@]}" $LIBS \
        -Wl,-exported_symbols_list,"$BUILD_DIR/exports-macho.txt" \
        -o "$PRELINKED_OBJ"
    AR_BIN="$(xcrun --sdk iphoneos --find ar)"
    NM_BIN="$(xcrun --sdk iphoneos --find nm)"
    CHECKED="$PRELINKED_OBJ"; NM_ARGS=(-g)
fi

rm -f "$OUTPUT_LIB"
"$AR_BIN" rcs "$OUTPUT_LIB" "$PRELINKED_OBJ"

# --- verify the exports (FATAL) -------------------------------------------------
if ! DEFINED="$("$NM_BIN" "${NM_ARGS[@]}" "$CHECKED" 2>&1)"; then
    echo "ERROR: could not read symbols with '$NM_BIN':"
    printf '%s\n' "$DEFINED" | head -5 | sed 's/^/         /'
    exit 1
fi
DEFINED="$(printf '%s\n' "$DEFINED" | awk 'NF >= 3 && $2 != "U" && $2 != "w" && $2 != "v" { print $3 }' \
    | sed 's/^_//' | sed 's/@.*//' | sort -u)"
EXTRA="$(comm -23 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$EXPORT_NAMES") | grep -v '^$' || true)"
MISSING="$(comm -13 <(printf '%s\n' "$DEFINED") <(printf '%s\n' "$EXPORT_NAMES") | grep -v '^$' || true)"
if [ -n "$EXTRA" ]; then
    echo "ERROR: the library exports globals besides the functions the bridge calls:"
    printf '%s\n' "$EXTRA" | head -20 | sed 's/^/         /'
    exit 1
fi
if [ -n "$MISSING" ]; then
    echo "ERROR: the bridge calls these, and the library does not define them:"
    printf '%s\n' "$MISSING" | sed 's/^/         /'
    exit 1
fi
echo "Exports: exactly the $EXPORT_COUNT libarchive functions the bridge calls."

# What else came in, by licence. The RAR5 reader brings libarchive's BLAKE2
# (CC0 / OpenSSL / Apache-2.0, its own files' choice; credited under CC0 in
# ThirdPartyLicensesView). Nothing else under another licence may.
LOCALS="$("$NM_BIN" "$PRELINKED_OBJ" 2>/dev/null || true)"
for unwanted in archive_parse_date compress_bidder; do
    if grep -q "$unwanted" <<< "$LOCALS"; then
        echo "ERROR: '$unwanted' was linked in: a part of libarchive under another licence, not credited."
        exit 1
    fi
done

if [ "$HOST" != "1" ]; then
    lipo -info "$OUTPUT_LIB" 2>/dev/null | grep -q 'arm64' || { echo "ERROR: the library is not arm64."; exit 1; }
fi

printf '%s\n' "$BUILD_INPUTS" > "$STAMP"
echo
echo "=== Done ==="
ls -lh "$OUTPUT_LIB"
