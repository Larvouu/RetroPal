#!/bin/bash
# Provide MoltenVK (Vulkan on top of Metal) for the Nintendo 64 core.
#
# Usage:
#   ./build.sh          put lib/MoltenVK.xcframework and lib/include/ in place
#   ./build.sh clean    remove them
#
# WHY IT IS NEEDED. The N64 core draws through parallel-RDP, which is written
# against Vulkan. iOS has no Vulkan; MoltenVK implements it on Metal. The bridge
# (N64Bridge.mm) creates the Vulkan instance on MoltenVK and hands it to the
# core, then copies each finished frame back into the framebuffer our Metal view
# already draws. Licence: Apache-2.0, compatible with the GPL-3.0 app.
#
# WHY THIS SCRIPT FETCHES INSTEAD OF COMPILING. Khronos publishes a build of every
# release, and building MoltenVK from source means fetching and compiling the
# seven repositories pinned in Vendor/MoltenVK/ExternalRevisions (SPIRV-Cross,
# SPIRV-Tools, SPIRV-Headers, Vulkan-Headers, Vulkan-Tools, Volk, cereal) for a
# result that is the same library. So this script downloads the release
# build of the tag the submodule is pinned to, and refuses it unless its SHA-256
# matches the one written below.
#
# THE SUBMODULE (Vendor/MoltenVK) IS STILL REQUIRED, and this script checks it.
# The GPL obligation is the complete source of the binary we ship, and MoltenVK
# is linked into it; the public repository carries that source as the submodule,
# pinned to the same tag as the binary. If the two ever disagree, the build
# stops rather than ship a library whose source is not the one we publish.
#
# TO MOVE TO A NEW RELEASE: check out the new tag in Vendor/MoltenVK, then change
# MOLTENVK_TAG and MOLTENVK_IOS_SHA256 together. The SHA-256 is the "digest"
# GitHub lists for MoltenVK-ios.tar on the release page.

set -euo pipefail

MOLTENVK_TAG="v1.4.2"
MOLTENVK_IOS_SHA256="b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1"
MOLTENVK_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/${MOLTENVK_TAG}/MoltenVK-ios.tar"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/../MoltenVK"
LIB_DIR="$SCRIPT_DIR/lib"
XCFRAMEWORK="$LIB_DIR/MoltenVK.xcframework"

if [ "${1:-}" = "clean" ]; then
    echo "Cleaning..."
    rm -rf "$LIB_DIR"
    echo "Done."
    exit 0
fi

# --- the source we publish must be the source of this binary ---------------------

if [ ! -f "$SOURCE_DIR/LICENSE" ]; then
    echo "ERROR: MoltenVK sources not found at $SOURCE_DIR"
    echo "Run: git submodule update --init Vendor/MoltenVK"
    exit 1
fi
PINNED_TAG="$(git -C "$SOURCE_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [ "$PINNED_TAG" != "$MOLTENVK_TAG" ]; then
    echo "ERROR: Vendor/MoltenVK is at '${PINNED_TAG:-an untagged commit}', this script fetches $MOLTENVK_TAG."
    echo "The published source has to be the source of the shipped binary. Move both"
    echo "together (see the top of this file)."
    exit 1
fi

if [ -d "$XCFRAMEWORK" ] && [ -f "$LIB_DIR/include/vulkan/vulkan.h" ] && [ -f "$LIB_DIR/VERSION" ] \
    && [ "$(cat "$LIB_DIR/VERSION")" = "$MOLTENVK_TAG" ]; then
    echo "MoltenVK $MOLTENVK_TAG already in place. Run '$0 clean' to fetch it again."
    exit 0
fi

# --- fetch and verify ------------------------------------------------------------

rm -rf "$LIB_DIR"
mkdir -p "$LIB_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== Fetching MoltenVK $MOLTENVK_TAG (iOS) ==="
curl -fL --retry 3 -o "$WORK/MoltenVK-ios.tar" "$MOLTENVK_URL"

if command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "$WORK/MoltenVK-ios.tar" | awk '{ print $1 }')"
else
    ACTUAL="$(sha256sum "$WORK/MoltenVK-ios.tar" | awk '{ print $1 }')"
fi
if [ "$ACTUAL" != "$MOLTENVK_IOS_SHA256" ]; then
    echo "ERROR: MoltenVK-ios.tar does not match the expected SHA-256."
    echo "  expected $MOLTENVK_IOS_SHA256"
    echo "  got      $ACTUAL"
    echo "Nothing was installed."
    exit 1
fi

tar -xf "$WORK/MoltenVK-ios.tar" -C "$WORK"

# The static framework only: the app links MoltenVK into its own binary, like
# every core, rather than embedding a dynamic library.
cp -R "$WORK/MoltenVK/MoltenVK/static/MoltenVK.xcframework" "$XCFRAMEWORK"
mkdir -p "$LIB_DIR/include"
cp -R "$WORK/MoltenVK/MoltenVK/include/vulkan" "$LIB_DIR/include/vulkan"
cp -R "$WORK/MoltenVK/MoltenVK/include/vk_video" "$LIB_DIR/include/vk_video"
cp -R "$WORK/MoltenVK/MoltenVK/include/MoltenVK" "$LIB_DIR/include/MoltenVK"
cp "$WORK/MoltenVK/LICENSE" "$LIB_DIR/LICENSE"
printf '%s\n' "$MOLTENVK_TAG" > "$LIB_DIR/VERSION"

# --- verify ----------------------------------------------------------------------

STATIC_LIB="$XCFRAMEWORK/ios-arm64/libMoltenVK.a"
if [ ! -f "$STATIC_LIB" ]; then
    echo "ERROR: the release no longer has ios-arm64/libMoltenVK.a where this script expects it."
    exit 1
fi
if command -v lipo >/dev/null 2>&1; then
    if ! lipo -info "$STATIC_LIB" 2>/dev/null | grep -q 'arm64'; then
        echo "ERROR: libMoltenVK.a is not arm64."
        lipo -info "$STATIC_LIB" || true
        exit 1
    fi
fi

echo
echo "=== Done ==="
echo "MoltenVK $MOLTENVK_TAG"
ls -lh "$STATIC_LIB"
echo
echo "Xcode wiring:"
echo "  - add $XCFRAMEWORK to the app target's Frameworks phase"
echo "  - header search path: Vendor/moltenvk-ios/lib/include"
echo "  - MoltenVK needs Metal, IOSurface, QuartzCore, CoreGraphics, UIKit and Foundation,"
echo "    and libc++"
