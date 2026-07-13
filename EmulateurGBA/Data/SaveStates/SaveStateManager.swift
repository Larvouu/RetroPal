//
//  SaveStateManager.swift
//  EmulateurGBA
//
//  Manages save state files, preview images, and metadata for a game.
//  5 manual slots (1-5) + 1 hidden auto-save slot (0).
//
//  File IO for save-state binaries and their PNG previews flows through
//  `CoordinatedFileIO` (defined at the bottom of this file) so that every
//  read or write goes through `NSFileCoordinator`. This is the prerequisite
//  for the Week-4 iCloud Documents sync: an `NSFilePresenter` registered
//  by the sync layer will be serialised against these accessors, so a save
//  written while iCloud is uploading the previous one never produces a
//  torn file, and a read taken while iCloud is pulling a newer copy waits
//  until the pull is committed. `nil` is passed for the presenter today;
//  the sync layer in Week 4 will pass its singleton presenter.
//

import UIKit
import os

struct SaveSlotInfo {
    let slotIndex: Int
    let isAutoSave: Bool
    let stateFileURL: URL
    let previewImageURL: URL
    let date: Date?
    let exists: Bool
    var isLocked: Bool = false
}

final class SaveStateManager {
    static let manualSlotCount = 5
    static let freeSlotCount = 2
    static let autoSaveSlotIndex = 0

    private let romName: String
    private let baseDir: URL        // manual slots 1-5 (iCloud-backed when synced)
    private let autoSaveDir: URL    // slot 0 — ALWAYS local (see init)

    static let autoSaveLog = Logger(subsystem: "com.retropal", category: "autosave")

    /// `baseDir` is injectable for tests. In the app, manual slots route to the
    /// per-session iCloud-or-local decision (see `iCloudSaveSync`), while the
    /// slot-0 auto-save ALWAYS lives in a dedicated LOCAL directory. The
    /// auto-save is written under time pressure on app-kill; keeping it out of
    /// the iCloud container removes the uncoordinated-write-vs-iCloud-reconcile
    /// race that could rarely resurface an older state ("Reprendre" loading a
    /// stale save). Manual saves still sync.
    init(romName: String, baseDir: URL? = nil) {
        self.romName = romName
        if let baseDir {
            // Explicit/test injection keeps everything in one directory.
            self.baseDir = baseDir
            self.autoSaveDir = baseDir
        } else {
            self.baseDir = iCloudSaveSync.shared.saveStatesURL(forROM: romName)
            self.autoSaveDir = SaveStateManager.localAutoSaveDir(romName: romName)
            SaveStateManager.migrateAutoSaveIfNeeded(romName: romName,
                                                     legacyDir: self.baseDir,
                                                     autoSaveDir: self.autoSaveDir)
        }
    }

    /// Dedicated LOCAL directory for the slot-0 auto-save, outside the
    /// SaveStates tree so the iCloud sync toggle never relocates it.
    static func localAutoSaveDir(romName: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("AutoSaves", isDirectory: true)
            .appendingPathComponent(romName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where a slot's files live: slot 0 -> local auto-save dir, manual -> baseDir.
    private func dir(forSlot slot: Int) -> URL {
        slot == SaveStateManager.autoSaveSlotIndex ? autoSaveDir : baseDir
    }

    private static let migrationLock = NSLock()
    private static var autoSaveMigrated = Set<String>()

    /// One-time copy of a pre-existing slot-0 auto-save from its legacy location
    /// (the SaveStates tree, possibly iCloud) into the local auto-save dir, so
    /// existing users keep their "Reprendre la session" after the switch to a
    /// local auto-save. Copy (not move) on a background queue with a coordinated
    /// read, so it never blocks the caller; the legacy file is left as a
    /// harmless orphan.
    static func migrateAutoSaveIfNeeded(romName: String, legacyDir: URL, autoSaveDir: URL) {
        let dst = autoSaveDir.appendingPathComponent("slot0.state")
        if FileManager.default.fileExists(atPath: dst.path) { return }   // already local
        let legacy = legacyDir.appendingPathComponent("slot0.state")
        guard legacy.path != dst.path else { return }                    // injected / local==local

        migrationLock.lock()
        let already = autoSaveMigrated.contains(romName)
        if !already { autoSaveMigrated.insert(romName) }
        migrationLock.unlock()
        if already { return }

        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.fileExists(atPath: legacy.path) else { return }
            var stateData: Data?
            CoordinatedFileIO.read(at: legacy) { stateData = try? Data(contentsOf: $0) }
            guard let stateData, !stateData.isEmpty else { return }
            try? stateData.write(to: dst, options: .atomic)
            let legacyPNG = legacyDir.appendingPathComponent("slot0.png")
            if FileManager.default.fileExists(atPath: legacyPNG.path) {
                var pngData: Data?
                CoordinatedFileIO.read(at: legacyPNG) { pngData = try? Data(contentsOf: $0) }
                if let pngData, !pngData.isEmpty {
                    try? pngData.write(to: autoSaveDir.appendingPathComponent("slot0.png"), options: .atomic)
                }
            }
            autoSaveLog.notice("Migrated slot-0 auto-save to local for \(romName, privacy: .public)")
            DispatchQueue.main.async { NotificationCenter.default.post(name: .saveStatesDidChange, object: nil) }
        }
    }

    // MARK: - File Paths

    func stateFileURL(slot: Int) -> URL {
        dir(forSlot: slot).appendingPathComponent("slot\(slot).state")
    }

    func previewImageURL(slot: Int) -> URL {
        dir(forSlot: slot).appendingPathComponent("slot\(slot).png")
    }

    // MARK: - Slot Info

    func slotInfo(slot: Int) -> SaveSlotInfo {
        let stateURL = stateFileURL(slot: slot)
        let previewURL = previewImageURL(slot: slot)
        let exists = FileManager.default.fileExists(atPath: stateURL.path)
        var date: Date?
        if exists {
            date = try? FileManager.default.attributesOfItem(atPath: stateURL.path)[.modificationDate] as? Date
        }
        return SaveSlotInfo(
            slotIndex: slot,
            isAutoSave: slot == SaveStateManager.autoSaveSlotIndex,
            stateFileURL: stateURL,
            previewImageURL: previewURL,
            date: date,
            exists: exists
        )
    }

    func allManualSlots() -> [SaveSlotInfo] {
        (1...SaveStateManager.manualSlotCount).map { slotInfo(slot: $0) }
    }

    /// Returns all 5 manual slots with lock state based on Pro status.
    func allManualSlotsWithLockState() -> [(info: SaveSlotInfo, isLocked: Bool)] {
        // Read cached Pro flag directly from UserDefaults to avoid @MainActor isolation
        let isPro = UserDefaults.standard.bool(forKey: "isPro")
        return (1...SaveStateManager.manualSlotCount).map { slot in
            var info = slotInfo(slot: slot)
            let locked = slot > SaveStateManager.freeSlotCount && !isPro
            info.isLocked = locked
            return (info: info, isLocked: locked)
        }
    }

    func autoSaveSlot() -> SaveSlotInfo {
        slotInfo(slot: SaveStateManager.autoSaveSlotIndex)
    }

    /// Dedicated pre-cheat backup path. Never overwritten by auto-save.
    var preCheatBackupURL: URL {
        baseDir.appendingPathComponent("pre_cheat_backup.state")
    }

    var hasPreCheatBackup: Bool {
        FileManager.default.fileExists(atPath: preCheatBackupURL.path)
    }

    // MARK: - Save Preview

    /// Writes the slot's PNG preview, then announces `.saveStatesDidChange` so
    /// the library cover + game-details preview re-read from disk. The async
    /// write paths (quit, manual save) complete AFTER those views refreshed on
    /// dismiss, so without this signal the new thumbnail wouldn't appear until
    /// the view was recreated. `coordinated: false` does a direct atomic write,
    /// used by the background-durability auto-save which must not stall on the
    /// iCloud daemon (same approach as `flushBatterySave`).
    func savePreviewImage(_ image: CGImage, slot: Int, coordinated: Bool = true) {
        let uiImage = UIImage(cgImage: image)
        guard let data = uiImage.pngData() else { return }
        let url = previewImageURL(slot: slot)
        if coordinated {
            CoordinatedFileIO.write(at: url) { coordURL in
                try? data.write(to: coordURL, options: .atomic)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .saveStatesDidChange, object: nil)
        }
    }

    func loadPreviewImage(slot: Int) -> UIImage? {
        let url = previewImageURL(slot: slot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var image: UIImage?
        CoordinatedFileIO.read(at: url) { coordURL in
            image = UIImage(contentsOfFile: coordURL.path)
        }
        return image
    }
}

// MARK: - Coordinated file IO

/// Thin wrappers around `NSFileCoordinator` for the iCloud-synced
/// save-state container (state binaries + their PNG previews + the
/// pre-cheat backup). Every read or write that touches one of those files
/// MUST go through these helpers so it serialises against the iCloud
/// sync presenter (registered in Week 4) and never produces a torn file
/// or a stale read.
///
/// The closure receives the *coordinated* URL handed back by the
/// coordinator and should perform the actual IO using that URL. It must
/// stay tight: the coordinator holds an exclusive accessor against any
/// registered `NSFilePresenter` for the duration of the block.
///
/// `.forReplacing` on writes tells the coordinator the file's content is
/// being overwritten so the presenter can drop its cache. Conflict
/// resolution between devices is mtime-wins (decided in the 2026-05-15
/// eng review); `NSFileVersion` is intentionally not used for save-state
/// binaries (industry norm, Delta does the same).
enum CoordinatedFileIO {

    /// Coordinated read. Returns `true` if `NSFileCoordinator` granted
    /// access (it almost always does; failure means the system is in a
    /// state where coordination cannot be acquired). The body's own
    /// success is whatever the caller captures via an `inout`-style
    /// outer variable; that captured value is the result the caller
    /// cares about.
    @discardableResult
    static func read(at url: URL, body: (URL) -> Void) -> Bool {
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: url, options: [], error: &coordError) { coordURL in
                body(coordURL)
            }
        return coordError == nil
    }

    /// Coordinated write. Same contract as `read(at:body:)`.
    @discardableResult
    static func write(at url: URL, body: (URL) -> Void) -> Bool {
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { coordURL in
                body(coordURL)
            }
        return coordError == nil
    }
}
