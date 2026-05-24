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
    private let baseDir: URL

    init(romName: String) {
        self.romName = romName
        // The per-session routing decision: iCloud-backed when the
        // container has been resolved by now, local otherwise. See
        // `iCloudSaveSync` for the resolution + fallback logic. The
        // directory is created inside saveStatesURL(forROM:) so we
        // don't repeat the work here.
        self.baseDir = iCloudSaveSync.shared.saveStatesURL(forROM: romName)
    }

    // MARK: - File Paths

    func stateFileURL(slot: Int) -> URL {
        baseDir.appendingPathComponent("slot\(slot).state")
    }

    func previewImageURL(slot: Int) -> URL {
        baseDir.appendingPathComponent("slot\(slot).png")
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

    func savePreviewImage(_ image: CGImage, slot: Int) {
        let uiImage = UIImage(cgImage: image)
        guard let data = uiImage.pngData() else { return }
        CoordinatedFileIO.write(at: previewImageURL(slot: slot)) { coordURL in
            try? data.write(to: coordURL, options: .atomic)
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
