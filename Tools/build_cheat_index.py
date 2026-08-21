#!/usr/bin/env python3
"""
build_cheat_index.py - Retro Pal cheat database index.

Compiles libretro-database's `cht/` folder into the ONE small file the app
bundles:

    EmulateurGBA/Resources/CheatIndex.json      (~420 KB, four systems)

The index holds no cheat codes at all. It maps a normalised game title to the
libretro filenames that carry codes for it, so the app can build a URL and
fetch that single game's file (median 0.6 KB) from jsDelivr on demand.

WHY AN INDEX AND NOT THE CODES. Bundling the codes themselves costs ~11 MB,
almost all of it Nintendo DS, and it would grow with every console we add.
The index costs 20-80 KB per console, so breadth stays free. Measured, not
estimated.

WHY TITLES AND NOT CRC32. libretro's cheat filenames follow an OLDER No-Intro
naming generation than the DATs behind BoxArtIndex: exact-name matching
measures at 35-68% by system, and the files carry no CRC. Stripping every
parenthetical tag and comparing bare titles measures at 94-98%. A title can
therefore hold SEVERAL entries (regions, and the tool the codes came from) and
the player picks: codes from one regional dump hit different addresses on
another, and this app's promise is save safety.

LICENCE. libretro-database is CC BY-SA 4.0, commercial use granted. The codes
themselves are never redistributed by us — they travel from libretro's CDN
straight to the device — but this index is derived from their file listing, so
it carries their attribution and licence and the app credits them.

Usage (stdlib only):

    python3 Tools/build_cheat_index.py --src <path to libretro-database/cht>
"""

import argparse
import json
import os
import re

SYSTEMS = {
    "gb": "Nintendo - Game Boy",
    "gbc": "Nintendo - Game Boy Color",
    "gba": "Nintendo - Game Boy Advance",
    "nds": "Nintendo - Nintendo DS",
    "snes": "Nintendo - Super Nintendo Entertainment System",
    "nes": "Nintendo - Nintendo Entertainment System",
}

FORMAT_VERSION = 1
# The app builds: <BASE>/<folder>/<filename>.cht (each path segment escaped).
BASE_URL = "https://cdn.jsdelivr.net/gh/libretro/libretro-database@master/cht"

# A .cht smaller than this is a stub with no codes (the DS set has ~124 of
# them, "cheats = 0"). Cheaper to drop here than to fetch and discover it.
MIN_USEFUL_BYTES = 40

TAG = re.compile(r"\s*\([^)]*\)|\s*\[[^\]]*\]")


def bare_title(name: str) -> str:
    """Normalised join key. MUST stay byte-identical to CheatIndex.bareTitle
    in Swift: drop every parenthetical and bracketed tag, read libretro's '_'
    substitution as 'and', lowercase, keep only letters and digits."""
    n = TAG.sub("", name)
    n = n.replace("_", "and").lower()
    return re.sub(r"[^a-z0-9]+", "", n)


def build(src: str) -> dict:
    index = {
        "v": FORMAT_VERSION,
        "source": "libretro-database",
        "license": "CC-BY-SA-4.0",
        "baseURL": BASE_URL,
        "systems": {},
    }
    for key, folder in SYSTEMS.items():
        path = os.path.join(src, folder)
        if not os.path.isdir(path):
            print(f"  ! missing {folder}, skipped")
            continue
        titles = {}
        kept = skipped = 0
        for filename in sorted(os.listdir(path)):
            if not filename.endswith(".cht"):
                continue
            if os.path.getsize(os.path.join(path, filename)) < MIN_USEFUL_BYTES:
                skipped += 1
                continue
            stem = filename[:-4]
            titles.setdefault(bare_title(stem), []).append(stem)
            kept += 1
        index["systems"][key] = {"folder": folder, "titles": titles}
        print(f"  {key}: {kept} games, {len(titles)} titles "
              f"({skipped} empty files dropped)")
    return index


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="libretro-database/cht")
    ap.add_argument("--out",
                    default=os.path.join(here, "EmulateurGBA", "Resources",
                                         "CheatIndex.json"))
    args = ap.parse_args()

    index = build(args.src)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  wrote {args.out} "
          f"({os.path.getsize(args.out) / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
