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

Usage (stdlib only, run from anywhere, then commit the JSON; add
`--only <system>` to rebuild one console and leave the others byte-identical):

    python3 Tools/build_boxart_index.py              # downloads the DATs
    python3 Tools/build_boxart_index.py --dat-dir D  # reuses local DATs
    python3 Tools/build_boxart_index.py --only psp --refresh-listing
        # re-reads the server's PSP thumbnail listing into
        # Tools/boxart-listings/ before rebuilding the PSP's alias table

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
    # Its CRCs are of the console's own byte order (the DAT lists `.z64`
    # files); the app hashes a `.v64` or `.n64` in that order too. Its serial
    # is the four-character code at header offset 0x3B ("NZLP").
    "n64":  {"db": "no-intro", "dir": "Nintendo - Nintendo 64"},
    # One directory for both names of the console. No serial tier: the app
    # does not read the header's serial (`GBAROMParser.gameCode` answers GBA,
    # DS and N64 only), so the table would be bytes nothing queries. An `.smd`
    # copier dump is interleaved, so its CRC is not the cartridge's and it is
    # found by its name instead.
    "md":   {"db": "no-intro", "dir": "Sega - Mega Drive - Genesis", "serial": False},
    # The Master System and the Game Gear, each its own No-Intro set. No serial
    # tier for the Mega Drive's reason (the header's product code is not read).
    "sms":  {"db": "no-intro", "dir": "Sega - Master System - Mark III", "serial": False},
    "gg":   {"db": "no-intro", "dir": "Sega - Game Gear", "serial": False},
    # The PSP, a Redump set like the PlayStation and for the PlayStation's
    # reasons: no CRC tier (a UMD image is up to 1.8 GB to read at import) and
    # no serial tier (it is in PARAM.SFO inside the image, which the app does
    # not read). Found by name, the fuzzy tier bridging a PSN dump's filename
    # ("... (USA) (PSP) (PSN)") to Redump's ("... (USA) (En,Fr,De,Es,It)").
    #
    # `alias`: the PSP's thumbnails are NOT named after Redump. Measured on
    # 2026-10-10 against the server's own listing, 562 of the 3,366 indexed
    # names (16.7 %) exist there as they are; the rest differ by a dropped
    # language group ("(USA)" for Redump's "(USA) (En,Ja,Fr,De,Es,It,Ko)"), an
    # added version ("(v1.02)"), a narrower region ("(Japan)" for
    # "(Japan, Asia)"), a moved article ("La Pucelle" for "Pucelle, La") or a
    # romanisation ("Shogi" for "Shougi"). The table emits, for those names
    # only, the file the server really holds (see `build_aliases`).
    "psp":  {"db": "redump", "dir": "Sony - PlayStation Portable", "crc": False, "serial": False,
             "alias": True},
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
# One file per aliased console: the server's Named_Boxarts listing, one stem
# per line (the `.png` dropped), sorted. A snapshot rather than a live read so
# the build is reproducible and the tests can check every alias against it.
# `--refresh-listing` rewrites it from the server.
LISTING_DIR = os.path.join(REPO_ROOT, "Tools", "boxart-listings")
THUMBS = "https://thumbnails.libretro.com/"


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


# --- Aliases: index name -> the name thumbnails.libretro.com actually holds ---
#
# A name is aliased only to a listing entry that is the SAME GAME, which is
# decided by three things agreeing, never by similarity:
#
#   title    equal after folding case, punctuation and spacing, and a trailing
#            article moved to the front ("Pucelle, La - X" = "La Pucelle - X").
#            Only when that finds nothing, a second fold also equates the
#            Hepburn long vowels and Roman numerals ("Shougi" = "Shogi",
#            "Aladdin II" = "Aladdin 2"); measured on the full index and
#            listing, it merges no two titles whose digits differ other than
#            those two numeral spellings of one game.
#   region   the same set, or else overlapping ("(Japan, Asia)" ->
#            "(Japan)"); a disjoint region is never taken, so "(Korea)" never
#            borrows "(USA)".
#   status   a beta, demo, proto, kiosk, promo or trade-show entry is never a
#            target for a name that is not one itself.
#
# Language groups and version numbers are ignored for identity (they are what
# libretro most often drops or adds) and used only to break ties, with the
# other tags: exact region, then the same edition tags, then no extra tags,
# then the same languages, then the same version, then the shortest name.
_REGION_WORDS = ("USA|Europe|Japan|Asia|Korea|UK|Australia|Germany|France|Spain|Italy|"
                 "Netherlands|Sweden|Russia|World|Brazil|Canada|China|Hong Kong|Taiwan|"
                 "Scandinavia|Portugal|Greece|Poland|India|Latin America|Mexico|Denmark|"
                 "Finland|Norway|Austria|Switzerland|Belgium|New Zealand|Unknown")
_REGION_GROUP = re.compile(r"^(?:%s)(?:, (?:%s))*$" % (_REGION_WORDS, _REGION_WORDS))
_LANG_GROUP = re.compile(r"^[A-Z][a-z](?:-[A-Za-z]+)?(?:,[A-Z][a-z](?:-[A-Za-z]+)?)*$")
_VERSION_GROUP = re.compile(r"^(?:v\d[\d.]*|Rev \w+|\d\.\d+)$")
_NOT_RETAIL = re.compile(r"beta|demo|proto|sample|kiosk|debug|preview|promo|trade", re.IGNORECASE)
_TRAILING_ARTICLE = re.compile(r"^(.*?), (The|La|Le|Les|Der|Die|Das|El|Il|Los|Las|A|An)( - .*)?$")
_ROMAN = {"i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6",
          "vii": "7", "viii": "8", "ix": "9", "x": "10"}


def _fold_title(title: str, deep: bool) -> str:
    if m := _TRAILING_ARTICLE.match(title):
        title = m.group(2) + " " + m.group(1) + (m.group(3) or "")
    t = title.lower()
    if deep:
        t = " ".join(_ROMAN.get(w, w) for w in re.split(r"[^0-9a-z]+", t))
        t = t.replace("ou", "o").replace("uu", "u")
    return re.sub(r"[^0-9a-z]", "", t)


def _parse_stem(stem: str, deep: bool):
    m = re.match(r"^(.*?)((?: \([^)]*\))*)$", stem)
    regions, tags, langs, version = None, [], None, None
    for group in re.findall(r"\(([^)]*)\)", m.group(2)):
        if regions is None and _REGION_GROUP.match(group):
            regions = frozenset(group.split(", "))
        elif _LANG_GROUP.match(group):
            langs = group
        elif _VERSION_GROUP.match(group):
            version = group
        else:
            tags.append(group.lower())
    return _fold_title(m.group(1), deep), regions, tuple(tags), langs, version


def build_aliases(names: list[str], listing: list[str]) -> dict[str, str]:
    """Index name -> listing name, for the index names the listing lacks."""
    on_server = set(listing)
    by_title = {}
    for deep in (False, True):
        table: dict[str, list] = {}
        for stem in listing:
            parsed = _parse_stem(stem, deep)
            table.setdefault(parsed[0], []).append((stem, parsed))
        by_title[deep] = table

    def pick(name: str, deep: bool):
        title, regions, tags, langs, version = _parse_stem(name, deep)
        best = None
        for stem, (_, c_regions, c_tags, c_langs, c_version) in by_title[deep].get(title, []):
            if regions is None or c_regions is None:
                continue
            if _NOT_RETAIL.search(" ".join(c_tags)) and not _NOT_RETAIL.search(" ".join(tags)):
                continue
            if regions == c_regions:
                region_rank = 0
            elif regions & c_regions:
                region_rank = 1
            else:
                continue
            tag_rank = 0 if c_tags == tags else (1 if not c_tags else 2)
            score = (region_rank, tag_rank, c_langs != langs, c_version != version,
                     len(stem), stem)
            if best is None or score < best:
                best = score
        return best[-1] if best else None

    aliases = {}
    for name in names:
        if name in on_server:
            continue
        target = pick(name, False) or pick(name, True)
        if target:
            aliases[name] = target
    return aliases


def listing_path(system_dir: str) -> str:
    return os.path.join(LISTING_DIR, system_dir + ".txt")


def load_listing(system_dir: str) -> list[str]:
    with open(listing_path(system_dir), encoding="utf-8") as f:
        return [line for line in f.read().split("\n") if line]


def refresh_listing(system_dir: str) -> None:
    """Rewrites the snapshot from the server's Apache index page."""
    url = THUMBS + urllib.request.quote(system_dir) + "/Named_Boxarts/"
    print(f"  downloading {url}")
    with urllib.request.urlopen(url) as resp:
        page = resp.read().decode("utf-8")
    stems = sorted({urllib.request.unquote(href)[:-4]
                    for href in re.findall(r'<a href="([^"?/][^"]*\.png)"', page)})
    if not stems:
        raise SystemExit(f"no .png entries found at {url}")
    os.makedirs(LISTING_DIR, exist_ok=True)
    with open(listing_path(system_dir), "w", encoding="utf-8") as f:
        f.write("\n".join(stems) + "\n")
    print(f"  {len(stems)} thumbnails listed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dat-dir", help="directory with local '<System>.dat' files")
    parser.add_argument("--only", action="append",
                        help="rebuild only this system and keep every other system "
                             "of the existing index, and its DAT version, as it is "
                             "(repeatable). A full rebuild reads today's DATs for "
                             "every console, which changes consoles nobody asked to "
                             "change; adding one console should touch only it "
                             "(checklist row 17.1, done by hand until 2026-10-10).")
    parser.add_argument("--refresh-listing", action="store_true",
                        help="re-read the server's Named_Boxarts listing for every "
                             "aliased system being built, before building it")
    args = parser.parse_args()

    out = {"source": "libretro-database metadat (no-intro + redump)",
           "versions": {}, "systems": {}}
    if args.only:
        unknown = [k for k in args.only if k not in SYSTEMS]
        if unknown:
            raise SystemExit(f"unknown system(s): {unknown}")
        with open(OUT_PATH, encoding="utf-8") as f:
            out = json.load(f)
    for key, cfg in SYSTEMS.items():
        if args.only and key not in args.only:
            continue
        print(f"{key}: {cfg['dir']} ({cfg['db']})")
        version, table = build_system(load_dat(cfg["db"], cfg["dir"], args.dat_dir),
                                      want_crc=cfg.get("crc", True),
                                      want_serial=cfg.get("serial", True))
        if cfg.get("alias"):
            if args.refresh_listing:
                refresh_listing(cfg["dir"])
            # Keyed by the name's POSITION in `names`, as `crc` and `serial`
            # are: only the names that differ are stored, and a position
            # costs a few bytes where the name would cost fifty.
            aliases = build_aliases(table["names"], load_listing(cfg["dir"]))
            position = {name: i for i, name in enumerate(table["names"])}
            table["alias"] = {str(position[n]): target for n, target in aliases.items()}
            on_server = len(set(table["names"]) & set(load_listing(cfg["dir"])))
            print(f"  {on_server} names on the server as they are, {len(aliases)} aliased: "
                  f"{100 * on_server / len(table['names']):.1f} % -> "
                  f"{100 * (on_server + len(aliases)) / len(table['names']):.1f} %")
        out["versions"][key] = version
        # Keys in sorted order inside each map, as the full rebuild's
        # sort_keys writes them, so `--only` lays a table out the same way.
        out["systems"][key] = {k: (dict(sorted(v.items())) if isinstance(v, dict) else v)
                               for k, v in sorted(table.items())}
        print(f"  {len(table['names'])} names, {len(table['crc'])} CRCs, "
              f"{len(table['serial'])} serials")

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        if args.only:
            # The existing file's own layout (key order, no trailing newline,
            # as the hand merges of 2026-10 left it), so the diff is the
            # rebuilt console and nothing else. A new system is appended.
            json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
        else:
            json.dump(out, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
            f.write("\n")
    print(f"wrote {OUT_PATH} ({os.path.getsize(OUT_PATH) / 1024:.0f} KB)")


if __name__ == "__main__":
    sys.exit(main())
