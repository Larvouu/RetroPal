#!/usr/bin/env python3
"""
build_boxart_index.py - Retro Pal library box art.

Compiles the four libretro no-intro DATs (GB / GBC / GBA / NDS) into the
compact identification index the app bundles:

  EmulateurGBA/Resources/BoxArtIndex.json

For every known cartridge dump the index maps its CRC32 (and, on GBA/NDS,
its 4-character header serial) to the exact thumbnail filename stem on
https://thumbnails.libretro.com/<System>/Named_Boxarts/<stem>.png — the
No-Intro display name with libretro's filename character substitution
applied (verified live 2026-07-10: '&' really is served as '_'; apostrophes
and commas are kept).

The app matches a game by CRC32 first (exact, any language, any filename),
then by header serial (survives renaming AND NDS trimming), then fuzzily by
name against the "names" arrays. No LLM, no scraping, no third-party API
key: regional releases keep their native No-Intro titles ("Pokemon - Version
Emeraude (France)"), so native-named files match natively.

Usage (stdlib only, run from anywhere, then commit the JSON):

    python3 Tools/build_boxart_index.py              # downloads the DATs
    python3 Tools/build_boxart_index.py --dat-dir D  # reuses local DATs

Source DATs: https://github.com/libretro/libretro-database
(metadat/no-intro/, MIT-licensed metadata compiled from No-Intro).
"""

import argparse
import json
import os
import re
import sys
import urllib.request

RAW = "https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/no-intro/"

# Our ROMSystemType rawValue -> DAT / thumbnail directory name.
SYSTEMS = {
    "gb":  "Nintendo - Game Boy",
    "gbc": "Nintendo - Game Boy Color",
    "gba": "Nintendo - Game Boy Advance",
    "nds": "Nintendo - Nintendo DS",
    "snes": "Nintendo - Super Nintendo Entertainment System",
    "nes": "Nintendo - Nintendo Entertainment System",
}

# libretro thumbnail filename substitution (documented set, '&' verified live).
THUMB_SUBST = str.maketrans({c: "_" for c in '&*/:`<>?\\|"'})

# A serial should point at the plain retail release, not a pre-release dump
# that happens to share it. CRC entries keep everything (an exact hash match
# is always the right answer, whatever the dump is).
NON_RETAIL = re.compile(r"\((?:Beta|Proto|Demo|Sample|Kiosk|Debug)[^)]*\)", re.IGNORECASE)

GAME_NAME = re.compile(r'^\s*name\s+"(.*)"\s*$')
ROM_LINE = re.compile(r'^\s*rom\s+\(')
CRC_FIELD = re.compile(r'\bcrc\s+([0-9A-Fa-f]{8})\b')
SERIAL_FIELD = re.compile(r'\bserial\s+"([^"]+)"')
VERSION_FIELD = re.compile(r'^\s*version\s+"([^"]+)"\s*$')

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT_PATH = os.path.join(REPO_ROOT, "EmulateurGBA", "Resources", "BoxArtIndex.json")


def load_dat(system_dir: str, dat_dir: str | None) -> str:
    if dat_dir:
        with open(os.path.join(dat_dir, system_dir + ".dat"), encoding="utf-8") as f:
            return f.read()
    url = RAW + urllib.request.quote(system_dir + ".dat")
    print(f"  downloading {url}")
    with urllib.request.urlopen(url) as resp:
        return resp.read().decode("utf-8")


def parse_dat(text: str) -> tuple[str, list[dict]]:
    """Returns (dat_version, games). Each game: name, crcs[], serial, retail."""
    version = ""
    games = []
    current = None
    for line in text.splitlines():
        if m := VERSION_FIELD.match(line):
            if not version:
                version = m.group(1)
        stripped = line.strip()
        if stripped.startswith("game ("):
            current = {"name": None, "crcs": [], "serial": None}
            continue
        if current is None:
            continue
        if stripped == ")":
            if current["name"]:
                current["retail"] = not NON_RETAIL.search(current["name"])
                games.append(current)
            current = None
            continue
        if ROM_LINE.match(line):
            if m := CRC_FIELD.search(line):
                current["crcs"].append(m.group(1).upper())
            if (m := SERIAL_FIELD.search(line)) and not current["serial"]:
                current["serial"] = m.group(1).strip()
            continue
        if current["name"] is None and (m := GAME_NAME.match(line)):
            current["name"] = m.group(1)


    return version, games


def build_system(text: str) -> tuple[str, dict]:
    version, games = parse_dat(text)
    names: list[str] = []
    name_index: dict[str, int] = {}
    crc_map: dict[str, int] = {}
    serial_map: dict[str, int] = {}
    serial_is_retail: dict[str, bool] = {}

    for game in games:
        if "[BIOS]" in game["name"]:
            continue
        stem = game["name"].translate(THUMB_SUBST)
        if stem not in name_index:
            name_index[stem] = len(names)
            names.append(stem)
        idx = name_index[stem]
        for crc in game["crcs"]:
            crc_map.setdefault(crc, idx)
        serial = game["serial"]
        if serial and len(serial) >= 3:
            # First mapping wins unless a retail release displaces a
            # pre-release dump sharing the serial.
            if serial not in serial_map or (game["retail"] and not serial_is_retail[serial]):
                serial_map[serial] = idx
                serial_is_retail[serial] = game["retail"]

    return version, {"names": names, "crc": crc_map, "serial": serial_map}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dat-dir", help="directory with local '<System>.dat' files")
    args = parser.parse_args()

    out = {"source": "libretro-database metadat/no-intro", "versions": {}, "systems": {}}
    for key, system_dir in SYSTEMS.items():
        print(f"{key}: {system_dir}")
        version, table = build_system(load_dat(system_dir, args.dat_dir))
        out["versions"][key] = version
        out["systems"][key] = table
        print(f"  {len(table['names'])} names, {len(table['crc'])} CRCs, "
              f"{len(table['serial'])} serials")

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        f.write("\n")
    print(f"wrote {OUT_PATH} ({os.path.getsize(OUT_PATH) / 1024:.0f} KB)")


if __name__ == "__main__":
    sys.exit(main())
