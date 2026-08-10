//
//  WidgetSnapshotWriter.swift
//  EmulateurGBA
//
//  Publishes the library's recent games into the App Group so the widget can
//  render them without a Core Data stack of its own (see WidgetSharing for
//  why the widget stays that thin).
//
//  App target only. Runs off the main thread, is idempotent, and only
//  re-copies a cover when the source file is newer than the copy — so the
//  common case (nothing changed since the last run) is a few stats and a
//  small JSON write.
//

import CoreData
import UIKit
import WidgetKit
import os

enum WidgetSnapshotWriter {
    /// The whole library is published, because the configurable widgets let
    /// the user pick any game, not just a recent one. The cap is a sanity
    /// bound on an unusually large library, not a product decision.
    private static let maxGames = 200
    /// Covers are decorative at widget size. Capping them keeps the
    /// extension well inside its memory budget.
    private static let coverMaxDimension: CGFloat = 320

    private static let log = Logger(subsystem: "com.retropal", category: "widget")

    /// True while a game is loaded. Set by LibraryView around the emulator
    /// cover.
    ///
    /// This exists for save safety, not tidiness. `EmulatorViewController`
    /// .appDidEnterBackground BLOCKS the main thread for up to 3 seconds
    /// writing the auto-save, capped to stay under the system's background
    /// watchdog, because an async save there once cost a tester's NDS
    /// session. Publishing the widget fires on the same transition and would
    /// spend CPU and disk I/O inside that window: a library-wide fetch, a
    /// SaveStateManager per game, PNG re-encoding. It cannot corrupt anything
    /// (it only reads those files) but it must not compete for that budget.
    /// So while a game is loaded we simply do not publish; the refresh
    /// happens when the game is dismissed, which is also the moment its
    /// lastPlayedAt, auto-save and cover have just changed.
    static var isGameLoaded = false

    /// Rebuilds the snapshot, then asks WidgetKit to reload. Safe to call
    /// often; safe to call when the App Group is unavailable (it logs and
    /// returns rather than trapping).
    /// `force` bypasses the in-game hold. Only one caller may use it: the
    /// emulator's background handler, AFTER its blocking auto-save has landed.
    /// At that point the save is durable and there is nothing left to contend
    /// with — and it is the last moment we are alive to update the widget at
    /// all, since a game killed straight from play never reaches
    /// coverDidDismiss.
    static func refresh(force: Bool = false) {
        guard force || !isGameLoaded else { return }
        let container = PersistenceController.shared.container
        container.performBackgroundTask { context in
            guard let coversDir = WidgetSharing.coversDirURL,
                  let snapshotURL = WidgetSharing.snapshotURL else {
                // Not a user-facing failure: the widget simply keeps showing
                // whatever it last had. Worth a log because it means the App
                // Group capability is missing or misspelled.
                log.error("App Group container unavailable, widget snapshot skipped")
                return
            }

            // Recent-first so the recents widget can just take the head of
            // the list, then alphabetical so the configurable widgets' picker
            // reads sensibly for everything never played.
            let request = NSFetchRequest<GameEntity>(entityName: "GameEntity")
            request.sortDescriptors = [
                NSSortDescriptor(key: "lastPlayedAt", ascending: false),
                NSSortDescriptor(key: "title", ascending: true,
                                 selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
            ]
            request.fetchLimit = maxGames
            guard let entities = try? context.fetch(request) else { return }

            try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)

            var games: [WidgetSharing.Game] = []
            var liveCovers: Set<String> = []

            for entity in entities {
                guard let romFilePath = entity.romFilePath else { continue }
                let romName = URL(fileURLWithPath: romFilePath).deletingPathExtension().lastPathComponent
                let manager = romName.isEmpty ? nil : SaveStateManager(romName: romName)

                let source = coverSourceURL(for: entity, manager: manager)
                var coverFileName: String?
                if let source, let hash = entity.romHash {
                    let name = "\(hash).png"
                    if publishCover(from: source.url, to: coversDir.appendingPathComponent(name)) {
                        coverFileName = name
                        liveCovers.insert(name)
                    }
                }

                games.append(WidgetSharing.Game(
                    romFilePath: romFilePath,
                    title: entity.title ?? romName,
                    systemType: entity.systemType ?? "gba",
                    lastPlayedAt: entity.lastPlayedAt,
                    hasAutoSave: manager?.autoSaveSlot().exists ?? false,
                    manualSlots: manager?.allManualSlots()
                        .filter { $0.exists }
                        .map(\.slotIndex) ?? [],
                    coverFileName: coverFileName,
                    coverIsScreenshot: source?.isScreenshot ?? false))
            }

            pruneCovers(in: coversDir, keeping: liveCovers)

            let snapshot = WidgetSharing.Snapshot(games: games, generatedAt: Date())
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: snapshotURL, options: .atomic)
            }

            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Cover resolution

    /// Mirrors `GameCoverView`'s chain exactly, so the widget shows the same
    /// image the library row shows: box art, else the auto-save screenshot,
    /// else the newest manual slot's screenshot, else nothing.
    private static func coverSourceURL(for entity: GameEntity,
                                       manager: SaveStateManager?) -> (url: URL, isScreenshot: Bool)? {
        if let art = BoxArtManager.shared.coverFileURL(forROMHash: entity.romHash,
                                                       coverType: entity.coverType),
           FileManager.default.fileExists(atPath: art.path) {
            return (art, false)
        }
        guard let manager else { return nil }

        let auto = manager.previewImageURL(slot: SaveStateManager.autoSaveSlotIndex)
        if FileManager.default.fileExists(atPath: auto.path) { return (auto, true) }

        let newest = manager.allManualSlots()
            .filter { $0.exists }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .first
        guard let newest else { return nil }
        let url = manager.previewImageURL(slot: newest.slotIndex)
        return FileManager.default.fileExists(atPath: url.path) ? (url, true) : nil
    }

    /// Copies a cover into the App Group, downscaled. Skips the work when the
    /// destination is already at least as new as the source. Returns whether
    /// a usable file is in place afterwards.
    private static func publishCover(from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        let sourceDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let destDate = (try? destination.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let sourceDate, let destDate, destDate >= sourceDate { return true }

        guard let image = UIImage(contentsOfFile: source.path) else { return false }
        let scaled = downscaled(image)
        guard let data = scaled.pngData() else { return false }
        do {
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            log.error("widget cover write failed: \(error.localizedDescription, privacy: .public)")
            return fm.fileExists(atPath: destination.path)
        }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > coverMaxDimension, longest > 0 else { return image }
        let factor = coverMaxDimension / longest
        let target = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Deleted or de-listed games must not leave their art behind in the
    /// shared container.
    private static func pruneCovers(in directory: URL, keeping live: Set<String>) {
        let fm = FileManager.default
        guard let existing = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in existing where !live.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
