//
//  NameTable.swift
//  EmulateurGBA
//
//  Resolves Generation 3 Pokémon species and move IDs to localized names,
//  from bundled JSON tables. Part of the in-game translation feature.
//
//  Species are keyed by the Gen 3 **internal index** — the value the game
//  stores in RAM (`gBattleMons[].species`). Internal indices 1...251 equal the
//  National Dex; 277...411 map to National Dex 252...386 (Gen 3); 252...276 are
//  unused. The generation script bakes that remap into the keys, so lookup is
//  a direct hit with no runtime conversion.
//
//  Data sources, in priority order:
//    1. pokemon_names_gen3.json / move_names_gen3.json — the full Gen 3 set,
//       produced by Tools/generate_name_tables.py from the veekun/pokedex
//       CC0 dataset. Primary source.
//    2. pokemon_names_gen1.json / move_names_gen1.json — the hand-authored
//       Gen 1 baseline (151 species), used only when the Gen 3 files have not
//       been generated yet, so the feature still resolves Gen 1 names.
//
//  An ID absent from the loaded table returns nil; the caller renders "#<id>".
//

import Foundation

#if DEBUG

/// Display language for resolved names.
enum NameLanguage {
    case fr
    case en

    var key: String { self == .fr ? "fr" : "en" }

    /// Best language for the current device: French locales get FR, all
    /// others fall back to EN.
    static var current: NameLanguage {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return code == "fr" ? .fr : .en
    }
}

struct NameTable {

    /// id -> { langKey: name }
    private let species: [Int: [String: String]]
    private let moves: [Int: [String: String]]

    /// Loads the bundled name tables (Gen 3 primary, Gen 1 fallback). If both
    /// are missing or malformed, a table is left empty: callers then render
    /// "#id", so a bad bundle degrades gracefully and never crashes.
    init() {
        species = NameTable.loadWithFallback(primary: "pokemon_names_gen3",
                                             fallback: "pokemon_names_gen1")
        moves = NameTable.loadWithFallback(primary: "move_names_gen3",
                                           fallback: "move_names_gen1")
    }

    /// Load `primary`; if it is missing or empty, load `fallback` instead.
    private static func loadWithFallback(primary: String,
                                         fallback: String) -> [Int: [String: String]] {
        let p = load(primary)
        return p.isEmpty ? load(fallback) : p
    }

    private static func load(_ resource: String) -> [Int: [String: String]] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else {
            return [:]
        }
        var table: [Int: [String: String]] = [:]
        for (key, value) in raw {
            if let id = Int(key) { table[id] = value }
        }
        return table
    }

    /// Localized species name for a Gen 3 internal index, or nil if absent.
    /// Falls back to English when the requested language has no entry.
    func speciesName(id: Int, language: NameLanguage = .current) -> String? {
        Self.resolve(species[id], language: language)
    }

    /// Localized move name, or nil if the id is absent from the table.
    /// Falls back to English when the requested language has no entry.
    func moveName(id: Int, language: NameLanguage = .current) -> String? {
        Self.resolve(moves[id], language: language)
    }

    private static func resolve(_ entry: [String: String]?,
                                language: NameLanguage) -> String? {
        guard let entry else { return nil }
        return entry[language.key] ?? entry["en"]
    }
}

#endif
