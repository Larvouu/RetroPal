//
//  CheatIndex.swift
//  EmulateurGBA
//
//  The bundled half of the cheat database: which libretro cheat files exist
//  for a given game title. ~420 KB for all four consoles, and 20-80 KB per
//  console after that, so adding consoles never costs megabytes.
//
//  It holds NO codes. Those are fetched one game at a time (see CheatLibrary),
//  which is what keeps this small: bundling the codes themselves measured at
//  ~11 MB, almost all of it Nintendo DS.
//
//  Built by Tools/build_cheat_index.py from libretro-database (CC BY-SA 4.0).
//

import Foundation

struct CheatIndex {
    static let shared = CheatIndex()

    private struct Payload: Decodable {
        struct System: Decodable {
            let folder: String
            let titles: [String: [String]]
        }
        let baseURL: String
        let systems: [String: System]
    }

    private let payload: Payload?

    private init() {
        guard let url = Bundle.main.url(forResource: "CheatIndex", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
            payload = nil
            return
        }
        payload = decoded
    }

    /// Normalised join key. MUST stay byte-identical to `bare_title` in
    /// Tools/build_cheat_index.py: drop every parenthetical and bracketed tag,
    /// read libretro's '_' substitution as "and", lowercase, keep only letters
    /// and digits.
    ///
    /// The tags are dropped because libretro's cheat filenames follow an older
    /// No-Intro naming generation than our box-art DATs. Measured: matching the
    /// full names lands at 35-68%, matching bare titles lands at 94-98%.
    static func bareTitle(_ name: String) -> String {
        var out = ""
        var depth = 0
        for ch in name {
            switch ch {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            default:
                guard depth == 0 else { continue }
                if ch == "_" { out += "and" } else { out.append(ch) }
            }
        }
        // ASCII-only on purpose: the Python side keeps [a-z0-9], so anything
        // that keeps accented or CJK letters here would key "Pokémon"
        // differently on each side and every lookup would silently miss.
        // Walked by UNICODE SCALAR, not by Character, for the same reason:
        // Python filters code points, so a decomposed "é" (e + combining
        // accent, the form a Mac or iCloud writes) keeps its "e" there. A
        // Character-level filter dropped the whole grapheme and keyed
        // "pokmon" for a name the builder keyed "pokemon".
        var key = ""
        for scalar in out.lowercased().unicodeScalars
        where ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
            key.unicodeScalars.append(scalar)
        }
        return key
    }

    /// Every libretro cheat file that covers this title, most often one, but
    /// several when a game has regional dumps or codes from more than one tool.
    /// The player chooses; we never pick for them. Retail dumps come first
    /// (see `retailFirst`), so the first section on screen is the game the
    /// player holds and not a hack of it.
    func candidates(forTitle title: String, system: String) -> [String] {
        guard let system = payload?.systems[system] else { return [] }
        return Self.retailFirst(system.titles[Self.bareTitle(title)] ?? [])
    }

    /// The stems of one title, the retail dumps before the ROM hacks, each
    /// group in the order it arrived (2026-09-10).
    ///
    /// libretro names a hack's file after its base dump with the hack's own
    /// name NESTED in a parenthesis of its own, "Pokemon - SoulSilver Version
    /// (Europe) (Rev 10) (Pokemon - SoothingSilver Version (v1.3.1))", while a
    /// retail dump's tags never nest: region, revision, version, language,
    /// one level deep. So "nests" is the whole test, and it needs no list of
    /// hack names. The builder sorts the same way at build time; this is kept
    /// here too so a bundle built before the rule still reads right: the
    /// bundled index listed the SoothingSilver hack ABOVE the retail Europe
    /// file (a space sorts before a dot), and a German player with a retail
    /// cartridge was served a hack's anti-piracy patches as the first section.
    static func retailFirst(_ stems: [String]) -> [String] {
        let retail = stems.filter { !isHackStem($0) }
        let hacks = stems.filter { isHackStem($0) }
        return retail + hacks
    }

    /// Whether a libretro cheat-file stem names a ROM hack: any parenthesis
    /// nested inside another one.
    static func isHackStem(_ stem: String) -> Bool {
        var depth = 0
        for ch in stem {
            switch ch {
            case "(", "[": depth += 1; if depth >= 2 { return true }
            case ")", "]": depth = max(0, depth - 1)
            default: break
            }
        }
        return false
    }

    /// The title to try when the filename's own lookup missed: the game's OWN
    /// release name, read from the cartridge code, when it keys differently
    /// from the filename (2026-09-10). nil when it keys the same, since that
    /// lookup has just failed and would fail again.
    ///
    /// The case that names it: `4828 - Pokemon - Silberne Edition SoulSilver
    /// (G).nds`, a numbered set's filename. `bareTitle` strips tags only, so
    /// the catalogue number survived and the key became
    /// "4828pokemonsilberneeditionsoulsilver", a miss, while libretro's
    /// German file sat in the index under the serial's own name. The browser
    /// then went to the REGIONAL SIBLINGS, which skip the game's own code on
    /// the assumption that its own name already failed, true only when the
    /// file is named like the DAT. The cartridge code is the identity that
    /// survives any filename, so it is asked before the siblings.
    static func ownReleaseTitle(forROMName romName: String, serialName: String) -> String? {
        bareTitle(serialName) == bareTitle(romName) ? nil : serialName
    }

    /// Where a given cheat file lives. Every path segment is escaped: these
    /// names carry spaces, commas, apostrophes and parentheses.
    func url(forCheatFile stem: String, system: String) -> URL? {
        guard let payload, let system = payload.systems[system] else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        guard let folder = system.folder.addingPercentEncoding(withAllowedCharacters: allowed),
              let file = (stem + ".cht").addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "\(payload.baseURL)/\(folder)/\(file)")
    }

    /// Free-text search over a console's cheat files, so someone whose ROM is
    /// named "Pokemon Emerald.gba" can still find "Pokemon - Emerald Version".
    /// Automatic matching handles well-named dumps; this handles the rest.
    func search(_ query: String, system: String, limit: Int = 60) -> [String] {
        let needle = Self.bareTitle(query)
        guard needle.count >= 2, let system = payload?.systems[system] else { return [] }
        var exact: [String] = []
        var partial: [String] = []
        for (key, stems) in system.titles {
            if key == needle { exact.append(contentsOf: stems) }
            else if key.contains(needle) { partial.append(contentsOf: stems) }
            if exact.count + partial.count > limit * 3 { break }
        }
        return Array((exact.sorted() + partial.sorted()).prefix(limit))
    }

    /// False when the bundle is missing or unreadable — the UI then says so
    /// instead of pretending the game simply has no cheats.
    var isAvailable: Bool { payload != nil }
}
