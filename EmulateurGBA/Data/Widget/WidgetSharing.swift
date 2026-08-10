//
//  WidgetSharing.swift
//  EmulateurGBA
//
//  The whole contract between the app and the widget extension. BOTH targets
//  compile this file (Target Membership: EmulateurGBA + RetroPalWidgetExtension),
//  so the group identifier, the file layout and the deep-link format exist
//  once and cannot drift apart.
//
//  Deliberately: the widget never touches Core Data, iCloud or the app's own
//  containers. It reads one small JSON plus a folder of downscaled covers
//  that the app writes into the App Group. Widget timelines run in a very
//  small memory budget, and a Core Data stack with an iCloud container in
//  that budget is a crash generator.
//

import Foundation

enum WidgetSharing {
    /// Must match the App Groups capability on BOTH targets.
    static let appGroupID = "group.com.retropal"
    static let urlScheme = "retropal"
    static let playHost = "play"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("widget-snapshot.json")
    }

    static var coversDirURL: URL? {
        containerURL?.appendingPathComponent("Covers", isDirectory: true)
    }

    /// One game as the widget sees it. The snapshot carries the WHOLE library
    /// (not just recents) because the configurable widgets let the user pick
    /// any game; the recents widget filters on `lastPlayedAt` itself.
    struct Game: Codable, Identifiable, Hashable {
        /// The stored ROM filename — the library's own identity for a game,
        /// and the key the deep link carries back.
        let romFilePath: String
        let title: String
        let systemType: String
        /// nil = never played. The recents widget shows only games that have
        /// one, most recent first (the writer publishes them in that order).
        let lastPlayedAt: Date?
        /// Whether a slot-0 auto-save exists, i.e. whether "Reprendre" has
        /// anything to resume.
        let hasAutoSave: Bool
        /// Manual slots that actually hold a state, so a slot picker can only
        /// offer real ones.
        let manualSlots: [Int]
        /// File name inside `coversDirURL`; nil when the game has neither box
        /// art nor a screenshot yet.
        let coverFileName: String?
        /// True when the cover is a save-state screenshot rather than box art,
        /// so the widget renders it with nearest-neighbour scaling like the
        /// library does and keeps pixel art crisp.
        let coverIsScreenshot: Bool

        var id: String { romFilePath }

        /// What a plain tap resumes into: the auto-save when there is one,
        /// otherwise a fresh boot. Exactly what the "Continue" button loads.
        var resumeSlot: Int? { hasAutoSave ? 0 : nil }

        /// Console name for subtitles. Proper nouns, deliberately not
        /// localized, matching the strings the app already uses elsewhere.
        var consoleName: String {
            switch systemType {
            case "nds": return "Nintendo DS"
            case "gb": return "Game Boy"
            case "gbc": return "Game Boy Color"
            default: return "Game Boy Advance"
            }
        }

        init(romFilePath: String, title: String, systemType: String, lastPlayedAt: Date?,
             hasAutoSave: Bool, manualSlots: [Int], coverFileName: String?,
             coverIsScreenshot: Bool) {
            self.romFilePath = romFilePath
            self.title = title
            self.systemType = systemType
            self.lastPlayedAt = lastPlayedAt
            self.hasAutoSave = hasAutoSave
            self.manualSlots = manualSlots
            self.coverFileName = coverFileName
            self.coverIsScreenshot = coverIsScreenshot
        }

        /// Tolerant decoding so a snapshot written by an older build still
        /// loads (same pattern as ControlPreset): the widget shows slightly
        /// less until the app next republishes, rather than nothing at all.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            romFilePath = try c.decode(String.self, forKey: .romFilePath)
            title = try c.decode(String.self, forKey: .title)
            systemType = try c.decode(String.self, forKey: .systemType)
            lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
            hasAutoSave = try c.decodeIfPresent(Bool.self, forKey: .hasAutoSave) ?? false
            manualSlots = try c.decodeIfPresent([Int].self, forKey: .manualSlots) ?? []
            coverFileName = try c.decodeIfPresent(String.self, forKey: .coverFileName)
            coverIsScreenshot = try c.decodeIfPresent(Bool.self, forKey: .coverIsScreenshot) ?? false
        }
    }

    struct Snapshot: Codable {
        var games: [Game]
        var generatedAt: Date
    }

    static func loadSnapshot() -> Snapshot? {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Every game in the library, recent-first then alphabetical (the order
    /// the writer publishes).
    static func allGames() -> [Game] { loadSnapshot()?.games ?? [] }

    /// Only what has actually been played, for the zero-configuration widget.
    static func recentGames() -> [Game] { allGames().filter { $0.lastPlayedAt != nil } }

    static func game(withID id: String) -> Game? {
        allGames().first { $0.romFilePath == id }
    }

    static func coverURL(for game: Game) -> URL? {
        guard let name = game.coverFileName else { return nil }
        return coversDirURL?.appendingPathComponent(name)
    }

    // MARK: - Deep link

    /// A play request the widget hands back to the app:
    /// `retropal://play?rom=<filename>&slot=<n>` (slot omitted = fresh start).
    struct PlayRequest: Equatable, Hashable {
        let romFilePath: String
        let slot: Int?
    }

    static func playURL(romFilePath: String, slot: Int?) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = playHost
        var items = [URLQueryItem(name: "rom", value: romFilePath)]
        if let slot {
            items.append(URLQueryItem(name: "slot", value: String(slot)))
        }
        components.queryItems = items
        // The components are always well formed; the fallback only exists so
        // the widget's `Link` / `widgetURL` can take a non-optional URL.
        return components.url ?? openAppURL
    }

    /// Plain tap on a game: resume it.
    static func playURL(for game: Game) -> URL {
        playURL(romFilePath: game.romFilePath, slot: game.resumeSlot)
    }

    /// Opens the app without launching anything (the widget's empty and
    /// unconfigured states).
    static var openAppURL: URL { URL(string: "\(urlScheme)://")! }

    /// True for any URL that belongs to us, whether or not it names a game.
    /// The app checks this BEFORE its ROM-import handling, which would
    /// otherwise swallow a widget tap as an unreadable file.
    static func isOurURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == urlScheme
    }

    /// Parses a widget tap into a play request. Returns nil for our own
    /// "just open the app" link and for anything that is not ours.
    static func parsePlayURL(_ url: URL) -> PlayRequest? {
        guard isOurURL(url),
              url.host?.lowercased() == playHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let rom = items.first(where: { $0.name == "rom" })?.value,
              !rom.isEmpty else { return nil }
        let slot = items.first(where: { $0.name == "slot" })?.value.flatMap(Int.init)
        return PlayRequest(romFilePath: rom, slot: slot)
    }
}
