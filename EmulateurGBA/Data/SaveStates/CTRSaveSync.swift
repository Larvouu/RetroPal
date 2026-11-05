//
//  CTRSaveSync.swift
//  EmulateurGBA
//
//  The Nintendo 3DS's saves in the iCloud mirror, like every other console's
//  `.sav`. A 3DS save is a FOLDER (`CTRSaveData.saveFolder`), and the mirror
//  moves single files, so each game's save travels as ONE file: a zip snapshot
//  of its folder, `BatterySaves/3DS/<title id>.zip` locally and in iCloud,
//  reconciled by the same engine with the same rules (`SaveSyncReconciler`:
//  local authoritative, the newer one wins, the loser archived locally in
//  `BatterySaves/3DS/_Conflicts/`).
//
//  Around that pass:
//   - before it, every 3DS save folder is snapshotted to its zip, rewritten
//     only when the bytes differ (`ZIPWriter` writes the same bytes for the
//     same folder), its date set to the newest file in the folder, so the
//     comparison is the save's age and not the snapshot's;
//   - after it, every zip the pass PULLED (another device's newer save) is
//     unpacked in place of the game's folder, the folder it replaces zipped to
//     the backups first (`CTRSaveData.apply`).
//  The game being played is skipped both ways (`activeTitleIDs`), and synced
//  at quit or on the next pass, as a live `.sav` is.
//
//  Keyed by title ID, not by file name: that is how the 3DS itself files a
//  save, so two copies of one game (a renamed file, another dump) share it.
//

import Foundation

enum CTRSaveSync {

    /// Local snapshots, beside the battery saves (the zip is not a battery
    /// file, and the `.sav` pass ignores this folder as it ignores `Backups`).
    static var localRoot: URL {
        BatterySaveImporter.batterySavesRoot.appendingPathComponent("3DS", isDirectory: true)
    }

    /// The title IDs of the 3DS games being played, set by `EmulatorSession`;
    /// their saves are left alone until the session ends.
    static var activeTitleIDs: Set<UInt64> {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set { lock.lock(); _active = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    private static var _active: Set<UInt64> = []

    /// Held while a pass touches one game's folders (its snapshot zipped, a
    /// pulled save put in place), and by `markActive`. The game's check and
    /// the work on its folders were two steps: a game launched between them
    /// booted with its save folder moved aside (a new game offered) or had a
    /// save zipped while it wrote it (audit, 2026-10-30). Now a boot waits
    /// for the folder work under way, a few seconds at most, and the pass
    /// sees it active before it starts the next.
    private static let folderLock = NSLock()

    /// Marks the games being played (`EmulatorSession`), after any pass still
    /// working on one of their folders.
    static func markActive(_ titleIDs: Set<UInt64>) {
        folderLock.lock(); defer { folderLock.unlock() }
        activeTitleIDs = titleIDs
    }

    /// `body` on one game's folders, unless that game is being played.
    private static func withIdleTitle(_ titleID: UInt64, _ body: () -> Void) {
        folderLock.lock(); defer { folderLock.unlock() }
        guard !activeTitleIDs.contains(titleID) else { return }
        body()
    }

    static func snapshotName(_ titleID: UInt64) -> String { String(format: "%016llx", titleID) }

    /// One reconcile of the 3DS saves against `cloudRoot`
    /// (`<iCloud>/BatterySaves/3DS`).
    @discardableResult
    static func reconcile(cloudRoot: URL,
                          materialize: @escaping (URL) -> Bool) -> SaveSyncReconciler.Result {
        let active = activeTitleIDs
        let skips = Set(active.map(snapshotName))
        snapshotLocalSaves(skipping: active)
        var engine = SaveSyncReconciler(localRoot: localRoot, cloudRoot: cloudRoot)
        engine.materialize = materialize
        let (result, pulled) = engine.reconcileFlatFiles(withExtension: "zip", skipping: skips)
        for name in pulled {
            guard let titleID = UInt64(name.dropLast(".zip".count), radix: 16) else { continue }
            unpackPulled(localRoot.appendingPathComponent(name), titleID: titleID)
        }
        return result
    }

    // MARK: - Snapshots

    /// Every game's save folder on the emulated SD card, by title ID.
    static func localSaveFolders() -> [UInt64: URL] {
        let title = CTRSaveData.saveFolder(titleID: 0)    // .../title/00000000/00000000/data
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        var found: [UInt64: URL] = [:]
        for high in (try? fm.contentsOfDirectory(atPath: title.path)) ?? [] {
            guard high.count == 8, let h = UInt64(high, radix: 16) else { continue }
            for low in (try? fm.contentsOfDirectory(atPath: title.appendingPathComponent(high).path)) ?? [] {
                guard low.count == 8, let l = UInt64(low, radix: 16) else { continue }
                let id = h << 32 | l
                if CTRSaveData.hasSave(titleID: id) { found[id] = CTRSaveData.saveFolder(titleID: id) }
            }
        }
        return found
    }

    private static func snapshotLocalSaves(skipping active: Set<UInt64>) {
        let fm = FileManager.default
        try? fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
        for (titleID, folder) in localSaveFolders() where !active.contains(titleID) {
            withIdleTitle(titleID) {
                let zip = localRoot.appendingPathComponent(snapshotName(titleID) + ".zip")
                let scratch = fm.temporaryDirectory.appendingPathComponent("ctr-snap-\(UUID().uuidString).zip")
                defer { try? fm.removeItem(at: scratch) }
                // The save and the game's extdata, the whole of what it keeps
                // (`CTRSaveData.zipSave`).
                guard (try? CTRSaveData.zipSave(titleID: titleID, to: scratch)) != nil,
                      let fresh = try? Data(contentsOf: scratch) else { return }
                if let current = try? Data(contentsOf: zip), current == fresh { return }
                guard (try? fresh.write(to: zip, options: .atomic)) != nil else { return }
                let extdata = CTRSaveData.existingExtdataFolder(titleID: titleID).flatMap { newestModification(in: $0) }
                if let date = [newestModification(in: folder), extdata].compactMap({ $0 }).max() {
                    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: zip.path)
                }
            }
        }
    }

    /// The newest modification date of any file in `folder`: when the game
    /// last wrote its save.
    static func newestModification(in folder: URL) -> Date? {
        var newest: Date?
        let walker = FileManager.default.enumerator(at: folder,
                                                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let date = values?.contentModificationDate else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    // MARK: - Pulls

    /// Another device's newer save, now the local snapshot: put it in place of
    /// the game's folder. Which file it was is the 3DS's own key, so no name to
    /// match and nothing to ask; the save it replaces is zipped to the backups.
    private static func unpackPulled(_ zip: URL, titleID: UInt64) {
        withIdleTitle(titleID) { unpack(zip, titleID: titleID) }
    }

    private static func unpack(_ zip: URL, titleID: UInt64) {
        guard case .success(let pending) = CTRSaveData.prepare(zipURL: zip) else { return }
        try? CTRSaveData.apply(pending, titleID: titleID,
                               romBasename: "3DS-" + snapshotName(titleID) + "-before-icloud",
                               keepBackups: BatterySaveImporter.stateLoadBackupsKept)
        // The folder now holds files dated today; the snapshot keeps the
        // pulled save's date, which is the one the next comparison must see.
        if let date = try? FileManager.default.attributesOfItem(atPath: zip.path)[.modificationDate] as? Date {
            let folders = [CTRSaveData.saveFolder(titleID: titleID)]
                + (CTRSaveData.existingExtdataFolder(titleID: titleID).map { [$0] } ?? [])
            for folder in folders {
                let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
                while let url = walker?.nextObject() as? URL {
                    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                }
            }
        }
    }
}
