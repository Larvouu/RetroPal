# Retro Pal

A local, offline emulator for iPhone and iPad supporting Game Boy, Game Boy Color,
Game Boy Advance, Nintendo DS, Super Nintendo, NES, PlayStation, Nintendo 64,
Mega Drive / Genesis, Master System, Game Gear and PSP.
Built with SwiftUI, UIKit and Metal, on top of the [mGBA](https://mgba.io),
[melonDS](https://melonds.kuribo64.net),
[MesenCE](https://github.com/nesdev-org/MesenCE),
[PCSX-ReARMed](https://github.com/notaz/pcsx_rearmed),
[Mupen64Plus-Next](https://github.com/libretro/mupen64plus-libretro-nx),
[BlastEm](https://www.retrodev.com/repos/blastem) and
[PPSSPP](https://github.com/hrydgard/ppsspp) emulation cores.

Website: [retropal.fr](https://retropal.fr)

## License

Retro Pal is released under the **GNU General Public License v3.0**. See
[`LICENSE`](LICENSE) for the full text. The software is provided without any
warranty.

It uses seven emulation cores. Six are included as git submodules pinned to
their upstream commits; BlastEm, whose upstream is a Mercurial repository, is
included as plain source in [`Vendor/blastem/`](Vendor/blastem), exactly as
upstream's archive of the pinned revision ships it (its `.hg_archival.txt`
names the revision):

- **mGBA** (Game Boy, Game Boy Color, Game Boy Advance): Mozilla Public License 2.0
- **melonDS** (Nintendo DS): GNU General Public License v3.0
- **MesenCE** (Super Nintendo, NES, Master System, Game Gear): GNU General Public License v3.0
- **PCSX-ReARMed** (PlayStation): GNU General Public License v2.0 or later
- **Mupen64Plus-Next** (Nintendo 64): GNU General Public License v2.0 or later,
  built with the cxd4 signal processor (CC0) and the ParaLLEl-RDP renderer (MIT),
  which draws through **MoltenVK** (Apache License 2.0), also a pinned submodule
- **BlastEm** (Mega Drive / Genesis): GNU General Public License v3.0 or later
- **PPSSPP** (PSP): GNU General Public License v2.0 or later, its own libretro
  port, drawing through MoltenVK as Mupen64Plus-Next does

mGBA and PCSX-ReARMed are built from unmodified upstream sources. melonDS,
MesenCE, Mupen64Plus-Next, BlastEm and PPSSPP carry changes of ours, which are
not applied to their sources but kept beside them as patch files, in
[`Vendor/melonds-ios/patches/`](Vendor/melonds-ios/patches),
[`Vendor/mesen-ios/patches/`](Vendor/mesen-ios/patches),
[`Vendor/n64-ios/patches/`](Vendor/n64-ios/patches),
[`Vendor/blastem-ios/patches/`](Vendor/blastem-ios/patches) and
[`Vendor/ppsspp-ios/patches/`](Vendor/ppsspp-ios/patches), and applied by
their build scripts before compiling (BlastEm's to a copy of its source). Mupen64Plus-Next's build leaves out the renderers and
processors whose licences cannot ship in this app (GLideN64, angrylion) and its
recompiler. The upstream commits plus those patches are exactly what the shipped
binary is built from.

The Retro Pal name, logo and visual identity are not covered by the GPL and
remain reserved.

## Building

Requires Xcode (iOS 16+) and CMake.

```bash
git submodule update --init                      # fetch the cores (not --recursive:
                                                 # PCSX-ReARMed's only submodule is an SDL
                                                 # frontend this build never compiles)
cd Vendor/melonds-ios && ./build.sh && cd ../..  # build the melonDS static lib
cd Vendor/mesen-ios && ./build.sh && cd ../..    # build the MesenCE static lib
cd Vendor/pcsx-ios   && ./build.sh && cd ../..   # build the PCSX-ReARMed static lib
cd Vendor/moltenvk-ios && ./build.sh && cd ../.. # fetch MoltenVK (release of the pinned tag)
cd Vendor/n64-ios    && ./build.sh && cd ../..   # build the Mupen64Plus-Next static lib
cd Vendor/blastem-ios && ./build.sh && cd ../..  # build the BlastEm static lib (needs python3)
cd Vendor/ppsspp-ios && ./build.sh && cd ../..   # build the PPSSPP static lib and its assets
                                                 # (fetches PPSSPP's own submodules itself)
open EmulateurGBA.xcodeproj                      # then build on a device
```

## No games included

This project contains no game files. Import only ROM files you legally own.
