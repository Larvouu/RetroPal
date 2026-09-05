//
//  LibraryStats.swift
//  EmulateurGBA
//

import Foundation

/// Aggregated, display-ready library statistics for the in-app stats block at
/// the bottom of the library (and, later, the shareable "retro story" card).
///
/// A pure value type computed from the current games + PromptTracker, so it is
/// unit-testable and never surfaces deleted games: the rankings come from the
/// live Core Data list, not the orphan-prone per-game UserDefaults keys.
struct LibraryStats {

    /// Minimal per-game input, decoupled from Core Data so `compute` stays
    /// testable with plain values.
    struct GameInput {
        let title: String
        let romFilePath: String?
        let systemType: String?
    }

    struct TopGame: Identifiable {
        let id: String
        let title: String
        let seconds: TimeInterval
    }

    struct ConsolePlay: Identifiable {
        let id: String      // systemType raw ("gba"/"gb"/"gbc"/"nds")
        let seconds: TimeInterval
    }

    let totalSeconds: TimeInterval
    let sessionCount: Int
    let libraryCount: Int        // total games imported
    let playedCount: Int         // games with any recorded play time
    let topGames: [TopGame]      // up to 3, descending by play time
    let topConsoles: [ConsolePlay] // up to 3 played consoles, descending by play time

    /// Needs at least two played games — with only one, both rankings (top games
    /// and consoles) are trivial, so there's nothing to compare.
    var hasData: Bool { playedCount >= 2 }

    /// Derive the PromptTracker per-game key basename from a stored ROM path —
    /// the SAME derivation LibraryRow + GameCoverView use, so look-ups match.
    static func romName(for path: String?) -> String? {
        guard let path = path else { return nil }
        let name = BatterySaveImporter.romBasename(forStoredFilename: path)
        return name.isEmpty ? nil : name
    }

    static func compute(games: [GameInput], tracker: PromptTracker = .shared) -> LibraryStats {
        var played: [(game: GameInput, seconds: TimeInterval)] = []
        var perSystem: [String: TimeInterval] = [:]

        for game in games {
            guard let name = romName(for: game.romFilePath) else { continue }
            let seconds = tracker.gamePlayTime(romName: name)
            guard seconds > 0 else { continue }
            played.append((game, seconds))
            perSystem[game.systemType ?? "gba", default: 0] += seconds
        }

        let topGames = played
            .sorted { $0.seconds > $1.seconds }
            .prefix(3)
            .map { TopGame(id: $0.game.romFilePath ?? $0.game.title, title: $0.game.title, seconds: $0.seconds) }

        let topConsoles = perSystem
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { ConsolePlay(id: $0.key, seconds: $0.value) }

        return LibraryStats(
            totalSeconds: tracker.totalPlaySeconds,
            sessionCount: tracker.sessionCount,
            libraryCount: games.count,
            playedCount: played.count,
            topGames: Array(topGames),
            topConsoles: Array(topConsoles)
        )
    }
}
