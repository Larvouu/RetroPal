//
//  RetroStoryModel.swift
//  EmulateurGBA
//
//  What the Retro story page reads (2026-10-28): every device's history
//  (`PlayHistory.loadAll`) summed with the library as it is now, into a
//  `PlayStats`, recomputed off the main thread whenever a history file changes
//  (a sitting banked here, a pull from iCloud) or the library does.
//

import Foundation
import CoreData
import Combine

@MainActor
final class RetroStoryModel: ObservableObject {
    static let shared = RetroStoryModel()

    @Published private(set) var stats: PlayStats?
    /// The year in review, from December 1 through January 6 (`reviewYear`),
    /// when that year has play recorded; nil otherwise.
    @Published private(set) var year: PlayStats.Year?

    private var library: [PlayStats.LibraryGame] = []
    private var observer: NSObjectProtocol?
    private var generation = 0

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: PlayHistory.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }

    /// The library's games, as the page needs them; called by the library
    /// whenever its games change (and once at launch).
    func update(library games: [GameEntity]) {
        library = games.compactMap { game in
            guard let hash = game.romHash, !hash.isEmpty else { return nil }
            return PlayStats.LibraryGame(romHash: hash, romFilePath: game.romFilePath,
                                         title: game.title ?? "", system: game.systemType ?? "gba",
                                         importedAt: game.importedAt)
        }
        recompute()
    }

    /// Settings ▸ Debug: shows this year's review before December, to see it
    /// on a device (debug builds only).
    static var reviewYearOverride: Int? {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "debugShowYearInReview") else { return nil }
        return Calendar.current.component(.year, from: Date())
        #else
        return nil
        #endif
    }

    func recompute() {
        generation &+= 1
        let mine = generation
        let library = self.library
        let reviewYear = Self.reviewYearOverride ?? PlayStats.reviewYear()
        Task.detached(priority: .utility) { [weak self] in
            let files = PlayHistory.loadAll()
            let stats = PlayStats.compute(files: files, library: library)
            let year = reviewYear.flatMap { PlayStats.year($0, files: files, library: library) }
            await MainActor.run {
                // A newer request wins; an older answer arriving late is dropped.
                guard let self, mine == self.generation else { return }
                self.stats = stats
                self.year = year
                // A badge newly earned is announced (seeded in silence the first time).
                StoryBadgeAnnouncer.shared.check(stats.milestones)
            }
        }
    }
}
