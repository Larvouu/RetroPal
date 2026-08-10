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
        return out.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Every libretro cheat file that covers this title, most often one, but
    /// several when a game has regional dumps or codes from more than one tool.
    /// The player chooses; we never pick for them.
    func candidates(forTitle title: String, system: String) -> [String] {
        guard let system = payload?.systems[system] else { return [] }
        return system.titles[Self.bareTitle(title)] ?? []
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
