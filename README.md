# Retro Pal

A local, offline emulator for iPhone and iPad supporting Game Boy, Game Boy Color,
Game Boy Advance, Nintendo DS, Super Nintendo, NES, PlayStation and Nintendo 64.
Built with SwiftUI, UIKit and Metal, on top of the [mGBA](https://mgba.io),
[melonDS](https://melonds.kuribo64.net),
[MesenCE](https://github.com/nesdev-org/MesenCE),
[PCSX-ReARMed](https://github.com/notaz/pcsx_rearmed) and
[Mupen64Plus-Next](https://github.com/libretro/mupen64plus-libretro-nx) emulation cores.

Website: [retropal.fr](https://retropal.fr)

## License

Retro Pal is released under the **GNU General Public License v3.0**. See
[`LICENSE`](LICENSE) for the full text. The software is provided without any
warranty.

It uses five emulation cores, included as git submodules and pinned to their
upstream commits:

- **mGBA** (Game Boy, Game Boy Color, Game Boy Advance): Mozilla Public License 2.0
- **melonDS** (Nintendo DS): GNU General Public License v3.0
- **MesenCE** (Super Nintendo, NES): GNU General Public License v3.0
- **PCSX-ReARMed** (PlayStation): GNU General Public License v2.0 or later
- **Mupen64Plus-Next** (Nintendo 64): GNU General Public License v2.0 or later,
  built with the cxd4 signal processor (CC0) and the ParaLLEl-RDP renderer (MIT),
  which draws through **MoltenVK** (Apache License 2.0), also a pinned submodule

mGBA and PCSX-ReARMed are built from unmodified upstream sources. melonDS,
MesenCE and Mupen64Plus-Next carry changes of ours, which are not applied to the
submodules but kept beside them as patch files, in
[`Vendor/melonds-ios/patches/`](Vendor/melonds-ios/patches),
[`Vendor/mesen-ios/patches/`](Vendor/mesen-ios/patches) and
[`Vendor/n64-ios/patches/`](Vendor/n64-ios/patches), and applied by their build
scripts before compiling. Mupen64Plus-Next's build leaves out the renderers and
processors whose licences cannot ship in this app (GLideN64, angrylion) and its
recompiler. The upstream commits plus those patches are exactly what the shipped
binary is built from.

The Retro Pal name, logo and visual identity are not covered by the GPL and
remain reserved.

## Building

Requires Xcode (iOS 16+) and CMake.

```bash
git submodule update --init                      # fetch the five cores (not --recursive:
                                                 # PCSX-ReARMed's only submodule is an SDL
                                                 # frontend this build never compiles)
cd Vendor/melonds-ios && ./build.sh && cd ../..  # build the melonDS static lib
cd Vendor/mesen-ios && ./build.sh && cd ../..    # build the MesenCE static lib
cd Vendor/pcsx-ios   && ./build.sh && cd ../..   # build the PCSX-ReARMed static lib
cd Vendor/moltenvk-ios && ./build.sh && cd ../.. # fetch MoltenVK (release of the pinned tag)
cd Vendor/n64-ios    && ./build.sh && cd ../..   # build the Mupen64Plus-Next static lib
open EmulateurGBA.xcodeproj                      # then build on a device
```

## No games included

This project contains no game files. Import only ROM files you legally own.
