#!/usr/bin/env python3
"""
build_boxart_index.py - Retro Pal library box art.

Compiles the libretro dump databases for every console the app runs into the
compact identification index it bundles:

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
(MIT-licensed metadata). Cartridges come from metadat/no-intro/; the
PlayStation comes from metadat/redump/, because No-Intro catalogues cartridges
and DISCS ARE REDUMP'S DOMAIN. There is no No-Intro PlayStation DAT at all, and
looking for one returns a 404, which is the sort of thing that reads as "box art
is broken" rather than "wrong database".
"""

import argparse
import json
import os
import re
import sys
import urllib.request

RAW = "https://raw.githubusercontent.com/libretro/libretro-database/master/metadat/"

# Our ROMSystemType rawValue -> which database, which directory, which tiers.
#
# `dir` is BOTH the DAT filename and the thumbnails.libretro.com directory, so
# a console that matches here can be fetched there.
#
# `crc` and `serial` say which lookup tables to emit, and the PlayStation says
# no to both for reasons worth writing down rather than rediscovering:
#
#   crc     A Redump CRC is per TRACK, and a disc has up to fifty-eight of them.
#           The app would have to CRC32 a three-hundred-megabyte track at import
#           to use one, which is minutes of work for a tier the fuzzy title
#           already answers. It also costs 159 KB of index for entries that
#           could never match.
#   serial  A PlayStation disc DOES carry one (SLPS-02110), and it would be the
#           exact tier this console deserves. It is off because reading it means
#           parsing SYSTEM.CNF out of an ISO 9660 filesystem, which the app does
#           not do yet. Turning it on is one word HERE plus that reader; paying
#           228 KB now for a tier nothing queries is the wrong order.
SYSTEMS = {
    "gb":   {"db": "no-intro", "dir": "Nintendo - Game Boy"},
    "gbc":  {"db": "no-intro", "dir": "Nintendo - Game Boy Color"},
    "gba":  {"db": "no-intro", "dir": "Nintendo - Game Boy Advance"},
    "nds":  {"db": "no-intro", "dir": "Nintendo - Nintendo DS"},
    "snes": {"db": "no-intro", "dir": "Nintendo - Super Nintendo Entertainment System"},
    "nes":  {"db": "no-intro", "dir": "Nintendo - Nintendo Entertainment System"},
    "ps1":  {"db": "redump", "dir": "Sony - PlayStation", "crc": False, "serial": False},
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


def load_dat(db: str, system_dir: str, dat_dir: str | None) -> str:
    if dat_dir:
        with open(os.path.join(dat_dir, system_dir + ".dat"), encoding="utf-8") as f:
            return f.read()
    url = RAW + db + "/" + urllib.request.quote(system_dir + ".dat")
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


def build_system(text: str, want_crc: bool = True, want_serial: bool = True) -> tuple[str, dict]:
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
        if want_crc:
            for crc in game["crcs"]:
                crc_map.setdefault(crc, idx)
        serial = game["serial"] if want_serial else None
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

    out = {"source": "libretro-database metadat (no-intro + redump)",
           "versions": {}, "systems": {}}
    for key, cfg in SYSTEMS.items():
        print(f"{key}: {cfg['dir']} ({cfg['db']})")
        version, table = build_system(load_dat(cfg["db"], cfg["dir"], args.dat_dir),
                                      want_crc=cfg.get("crc", True),
                                      want_serial=cfg.get("serial", True))
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
