# Retro Pal

A local, offline emulator for iPhone supporting Game Boy, Game Boy Color,
Game Boy Advance, Nintendo DS, Super Nintendo and NES. Built with SwiftUI,
UIKit and Metal, on top of the [mGBA](https://mgba.io),
[melonDS](https://melonds.kuribo64.net) and
[MesenCE](https://github.com/nesdev-org/MesenCE) emulation cores.

Website: [retropal.fr](https://retropal.fr)

## License

Retro Pal is released under the **GNU General Public License v3.0**. See
[`LICENSE`](LICENSE) for the full text. The software is provided without any
warranty.

It uses three emulation cores, included as git submodules and pinned to their
upstream commits:

- **mGBA** (Game Boy, Game Boy Color, Game Boy Advance) — Mozilla Public License 2.0
- **melonDS** (Nintendo DS) — GNU General Public License v3.0
- **MesenCE** (Super Nintendo, NES) — GNU General Public License v3.0

mGBA and melonDS are built from unmodified upstream sources. MesenCE carries one
change of ours, which is not applied to the submodule but kept beside it as a
patch file in [`Vendor/mesen-ios/patches/`](Vendor/mesen-ios/patches) and applied
by its build script before compiling. The upstream commit plus that patch is
exactly what the shipped binary is built from.

The Retro Pal name, logo and visual identity are not covered by the GPL and
remain reserved.

## Building

Requires Xcode (iOS 16+) and CMake.

```bash
git submodule update --init --recursive         # fetch the three cores
cd Vendor/melonds-ios && ./build.sh && cd ../..  # build the melonDS static lib
cd Vendor/mesen-ios && ./build.sh && cd ../..    # build the MesenCE static lib
open EmulateurGBA.xcodeproj                      # then build on a device
```

## No games included

This project contains no game files. Import only ROM files you legally own.
