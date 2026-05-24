# Retro Pal

A local, offline emulator for iPhone supporting Game Boy, Game Boy Color,
Game Boy Advance and Nintendo DS. Built with SwiftUI, UIKit and Metal, on top
of the [mGBA](https://mgba.io) and [melonDS](https://melonds.kuribo64.net)
emulation cores.

Website: [retropal.fr](https://retropal.fr)

## License

Retro Pal is released under the **GNU General Public License v3.0**. See
[`LICENSE`](LICENSE) for the full text. The software is provided without any
warranty.

It uses two emulation cores, included as git submodules and built from their
unmodified upstream sources:

- **mGBA** (Game Boy, Game Boy Color, Game Boy Advance) — Mozilla Public License 2.0
- **melonDS** (Nintendo DS) — GNU General Public License v3.0

The Retro Pal name, logo and visual identity are not covered by the GPL and
remain reserved.

## Building

Requires Xcode (iOS 16+) and CMake.

```bash
git submodule update --init --recursive           # fetch the mGBA + melonDS cores
cd Vendor/melonds-ios && ./build.sh && cd ../..    # build the melonDS static lib
open EmulateurGBA.xcodeproj                         # then build on a device
```

## No games included

This project contains no game files. Import only ROM files you legally own.
