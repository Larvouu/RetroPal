#!/usr/bin/env python3
"""
generate_name_tables.py - Retro Pal in-game translation feature.

Downloads the veekun/pokedex CC0 dataset and emits the two name tables the
translation feature bundles:

  EmulateurGBA/Resources/pokemon_names_gen3.json   (386 species)
  EmulateurGBA/Resources/move_names_gen3.json      (354 moves)

Species are keyed by the Gen 3 INTERNAL index, the value the game stores in RAM
(gBattleMons[].species): National Dex 1-251 -> internal 1-251; National Dex
252-386 -> internal 277-411; internal 252-276 are unused.

Usage (run once on the Mac before building, then commit the JSON):

    python3 Tools/generate_name_tables.py

Stdlib only, no pip dependencies. Re-run only to refresh the data.

Source: https://github.com/veekun/pokedex  (data is CC0-licensed)
"""

import csv
import io
import json
import os
import urllib.request

RAW = "https://raw.githubusercontent.com/veekun/pokedex/master/pokedex/data/csv/"

# veekun local_language_id -> our JSON language key.
LANGUAGES = {9: "en", 5: "fr", 6: "de", 7: "es", 8: "it"}

MAX_SPECIES = 386   # Gen 1-3 National Dex
MAX_MOVE = 354      # Gen 1-3 move IDs

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT_DIR = os.path.join(REPO_ROOT, "EmulateurGBA", "Resources")


def fetch_csv(name):
    """Download a veekun CSV and return it as a list of dict rows."""
    print(f"  fetching {name} ...")
    with urllib.request.urlopen(RAW + name) as resp:
        text = resp.read().decode("utf-8")
    return list(csv.DictReader(io.StringIO(text)))


def national_to_internal(dex):
    """Gen 3 internal species index for a National Dex number."""
    return dex if dex <= 251 else dex + 25


def build_species():
    table = {}
    for row in fetch_csv("pokemon_species_names.csv"):
        dex = int(row["pokemon_species_id"])
        lang = int(row["local_language_id"])
        if dex < 1 or dex > MAX_SPECIES or lang not in LANGUAGES:
            continue
        key = str(national_to_internal(dex))
        table.setdefault(key, {})[LANGUAGES[lang]] = row["name"]
    return table


def build_moves():
    table = {}
    for row in fetch_csv("move_names.csv"):
        mid = int(row["move_id"])
        lang = int(row["local_language_id"])
        if mid < 1 or mid > MAX_MOVE or lang not in LANGUAGES:
            continue
        table.setdefault(str(mid), {})[LANGUAGES[lang]] = row["name"]
    return table


def write_json(table, filename):
    """Write the table sorted numerically by key, for a stable diff."""
    path = os.path.join(OUT_DIR, filename)
    ordered = {k: table[k] for k in sorted(table, key=int)}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(ordered, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"  wrote {filename}  ({len(table)} entries)")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("Generating Gen 3 name tables from veekun/pokedex (CC0)...")
    write_json(build_species(), "pokemon_names_gen3.json")
    write_json(build_moves(), "move_names_gen3.json")
    print("Done. Commit the two generated JSON files.")


if __name__ == "__main__":
    main()
