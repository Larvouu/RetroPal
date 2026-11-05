//
//  CTRSaveData.swift
//  EmulateurGBA
//
//  A Nintendo 3DS game's save, which is a FOLDER and not a file: the game's
//  save data archive on the emulated SD card, where the core files it by the
//  game's title ID, exactly as a real 3DS does:
//
//      3DS/Azahar/sdmc/Nintendo 3DS/<id0>/<id1>/title/<high>/<low>/data/
//
//  (Azahar's GetSaveDataContainerPath and GetSaveDataPath,
//  core/file_sys/archive_source_sd_savedata.cpp: id0 and id1 are 32 zeros, the
//  title ID's halves are 8 lowercase hex digits each.) Inside, `00000001/` holds
//  the files the game wrote and `00000001.metadata` the archive's format.
//
//  Everything the other consoles do with their `.sav` file, the 3DS does with
//  this folder as one `.zip`: the copy kept before a state is loaded
//  (`BatterySaves/Backups/<rom>-before-state-<stamp>.zip`), the export, the
//  import. The zip holds the `data` folder's CONTENTS (`00000001/…` and the
//  metadata at its root), so a save taken from one copy of a game goes into any
//  other copy with the same title ID.
//
//  A `.3dsx` has no title ID (the core runs homebrew as title 0), and homebrew
//  keeps its own files on the SD card wherever it chooses: no folder here.
//
//  EXTDATA (2026-10-20, audit). Many games keep part of their progress or
//  content beside the save, in their "extra save data" on the SD card,
//  `…/extdata/<HIGH>/<LOW>/` (Azahar's GetExtSaveDataPath), named by the ID
//  the game's own header declares (Pokémon Sun: 0x1648). The zip carries it
//  under `extdata/`, beside the save's own files, so an export, a backup and
//  the iCloud copy are the whole of what the game keeps; an older zip, or
//  another emulator's, without it imports as before and leaves the extdata as
//  it is. The ID is read from the game's file (`CTRGameProbeReadExtdataID`)
//  and remembered by title ID, which is all the iCloud pass knows a save by.
//

import Foundation

enum CTRSaveData {

    /// The game's title ID, read from its file (`CTRGameProbeReadTitleID`):
    /// nil for a `.3dsx` and for anything that is not a 3DS game.
    /// Remembered by path AND by the file found there (its inode, size and
    /// date): Game Details asks on every redraw, and a path is not a game. A
    /// game deleted and another imported under the same free name had the
    /// first one's ID, so its save import, its backups and the iCloud guard
    /// went to the other game's folder (audit, 2026-10-20).
    static func titleID(ofROMAt url: URL) -> UInt64? {
        let path = url.path
        // Only a file that is there is remembered: a missing one may arrive.
        guard let file = FileIdentity(path: path) else {
            let id = UInt64(CTRGameProbeReadTitleID(path))
            return id == 0 ? nil : id
        }
        titleIDLock.lock()
        if let known = titleIDs[path], known.file == file {
            titleIDLock.unlock()
            return known.id == 0 ? nil : known.id
        }
        titleIDLock.unlock()
        let id = UInt64(CTRGameProbeReadTitleID(path))
        titleIDLock.lock(); titleIDs[path] = (file, id); titleIDLock.unlock()
        if id != 0 { rememberExtdataID(UInt64(CTRGameProbeReadExtdataID(path)), forTitleID: id) }
        return id == 0 ? nil : id
    }

    /// Which file a path held when its title ID was read.
    private struct FileIdentity: Equatable {
        let inode: UInt64, size: UInt64, modified: Date
        init?(path: String) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: path),
                  let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (a[.size] as? NSNumber)?.uint64Value,
                  let modified = a[.modificationDate] as? Date else { return nil }
            self.inode = inode; self.size = size; self.modified = modified
        }
    }

    // MARK: - Extdata

    private static let extdataKey = "ctrExtdataIDs"

    /// What a game's file declared, kept by title ID (the iCloud pass and the
    /// backups know a save by its title ID only). 0 is not stored.
    static func rememberExtdataID(_ extdataID: UInt64, forTitleID titleID: UInt64) {
        guard extdataID != 0 else { return }
        let key = String(titleID, radix: 16)
        var known = UserDefaults.standard.dictionary(forKey: extdataKey) as? [String: String] ?? [:]
        let value = String(extdataID, radix: 16)
        guard known[key] != value else { return }
        known[key] = value
        UserDefaults.standard.set(known, forKey: extdataKey)
    }

    /// The game's extdata ID, as its file declared it; nil when it has none
    /// or the game was never read on this device.
    static func extdataID(forTitleID titleID: UInt64) -> UInt64? {
        let known = UserDefaults.standard.dictionary(forKey: extdataKey) as? [String: String] ?? [:]
        return known[String(titleID, radix: 16)].flatMap { UInt64($0, radix: 16) }
    }

    /// The game's extdata folder (`…/extdata/<HIGH>/<LOW>`), whether or not
    /// the game has made it yet. UPPERCASE hex, unlike the save folder: the
    /// core opens and formats a game's extdata through GetExtSaveDataPath
    /// (`{:08X}`, archive_extsavedata.cpp); the lowercase GetExtDataPathFromId
    /// serves only the desktop app's game list. iOS's data volume tells the
    /// two apart, so an ID with a letter in it (0x00000B8D) was missed by the
    /// export, the backups and iCloud, and an import put it where the game
    /// never looks (audit, 2026-10-20).
    static func extdataFolder(extdataID: UInt64) -> URL {
        let high = String(format: "%08X", UInt32(truncatingIfNeeded: extdataID >> 32))
        let low = String(format: "%08X", UInt32(truncatingIfNeeded: extdataID))
        let zeros = String(repeating: "0", count: 32)
        return BatterySaveImporter.ctrSystemFolder
            .appendingPathComponent("Azahar/sdmc/Nintendo 3DS", isDirectory: true)
            .appendingPathComponent(zeros, isDirectory: true)
            .appendingPathComponent(zeros, isDirectory: true)
            .appendingPathComponent("extdata", isDirectory: true)
            .appendingPathComponent(high, isDirectory: true)
            .appendingPathComponent(low, isDirectory: true)
    }

    /// The game's extdata folder when it has one on disk.
    static func existingExtdataFolder(titleID: UInt64) -> URL? {
        guard let id = extdataID(forTitleID: titleID) else { return nil }
        let folder = extdataFolder(extdataID: id)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// The name prefix of the extdata's files in a save zip.
    static let extdataPrefix = "extdata/"
    /// Beside them, the extdata's ID, as hex text: the zip says whose extdata
    /// it carries. A device that never read the game's file (another iPhone
    /// pulling from iCloud, a new one) has no ID for it, and without this
    /// dropped the incoming extdata, then pushed its own copy without it over
    /// the complete one (audit, 2026-10-20).
    static let extdataIDEntry = "extdata.id"

    /// The game's whole save as one zip: the save's files at the root, the
    /// extdata's under `extdata/` with its ID in `extdata.id`.
    static func zipSave(titleID: UInt64, to zipURL: URL) throws {
        var extra: [(prefix: String, folder: URL)] = []
        var literal: [(name: String, contents: Data)] = []
        if let folder = existingExtdataFolder(titleID: titleID), let id = extdataID(forTitleID: titleID) {
            extra = [(extdataPrefix, folder)]
            literal = [(extdataIDEntry, Data(String(id, radix: 16).utf8))]
        }
        try ZIPWriter.zipFolder(saveFolder(titleID: titleID), to: zipURL, extra: extra, literal: literal)
    }
    private static let titleIDLock = NSLock()
    private static var titleIDs: [String: (file: FileIdentity, id: UInt64)] = [:]

    /// The game's save folder (`…/title/<high>/<low>/data`), whether or not
    /// the game has written it yet.
    static func saveFolder(titleID: UInt64) -> URL {
        let high = String(format: "%08x", UInt32(truncatingIfNeeded: titleID >> 32))
        let low = String(format: "%08x", UInt32(truncatingIfNeeded: titleID))
        let zeros = String(repeating: "0", count: 32)
        return BatterySaveImporter.ctrSystemFolder
            .appendingPathComponent("Azahar/sdmc/Nintendo 3DS", isDirectory: true)
            .appendingPathComponent(zeros, isDirectory: true)
            .appendingPathComponent(zeros, isDirectory: true)
            .appendingPathComponent("title", isDirectory: true)
            .appendingPathComponent(high, isDirectory: true)
            .appendingPathComponent(low, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
    }

    /// Whether the game has written a save: its archive's metadata, which the
    /// core writes when the game formats it (`ArchiveSource_SDSaveData::Format`).
    static func hasSave(titleID: UInt64) -> Bool {
        FileManager.default.fileExists(
            atPath: saveFolder(titleID: titleID).appendingPathComponent("00000001.metadata").path)
    }

    /// The save, zipped to `zipURL`. Throws when there is no save.
    static func exportSave(titleID: UInt64, to zipURL: URL) throws {
        guard hasSave(titleID: titleID) else { throw ExportError.noSave }
        try zipSave(titleID: titleID, to: zipURL)
    }

    enum ExportError: Error { case noSave }

    // MARK: - Backups

    /// A zip of the current save in `BatterySaveImporter.backupsDir`, named
    /// `<rom><infix><stamp>.zip`; the newest `keep` of that name are kept when
    /// `keep` is given. Best-effort, as every save backup is: a failed copy
    /// never blocks what the player asked for.
    @discardableResult
    static func backUp(titleID: UInt64, romBasename: String, infix: String, keep: Int?) -> URL? {
        guard hasSave(titleID: titleID) else { return nil }
        let dir = BatterySaveImporter.backupsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefix = "\(romBasename)\(infix)"
        let url = dir.appendingPathComponent("\(prefix)\(timestamp()).zip")
        guard (try? zipSave(titleID: titleID, to: url)) != nil else { return nil }
        if let keep {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".zip") }
                .sorted()
            for name in names.dropLast(keep) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        return url
    }

    /// Before a save STATE is loaded (`EmulatorSession.loadState`): a state
    /// holds the whole console, and the game may write its save again from the
    /// older moment it puts back. Same rule and same folder as the other
    /// consoles' `.sav` copy (`BatterySaveImporter.backUpBeforeStateLoad`).
    static func backUpBeforeStateLoad(titleID: UInt64, romBasename: String) {
        backUp(titleID: titleID, romBasename: romBasename, infix: "-before-state-",
               keep: BatterySaveImporter.stateLoadBackupsKept)
    }

    // MARK: - Import

    enum ImportError: Error {
        /// Not a zip we can read, or one whose names leave the folder.
        case unreadable
        /// A zip, but not a 3DS save: no `00000001.metadata` at its root, nor
        /// in a single folder (a `data` folder zipped whole, the shape another
        /// emulator's export can have).
        case notASave
        case writeFailed
    }

    /// The save folder's contents found in a zip: unpacked to a scratch folder
    /// and checked, so the game's own save is touched only once the import is
    /// known to be good. The caller applies it with `apply(_:titleID:...)`.
    struct Pending {
        /// The scratch folder holding `00000001.metadata` and `00000001/`.
        let contents: URL
        /// The zip's `extdata/` folder, moved out of `contents`; nil when the
        /// zip has none (older exports, other emulators').
        let extdata: URL?
        /// The extdata's ID the zip names (`extdataIDEntry`); nil in a zip
        /// without one.
        let extdataID: UInt64?
        /// The folder `prepare` unpacked into: `contents` itself, or its
        /// parent when the zip held the save one folder down. Removing only
        /// `contents` left that parent in tmp (audit, 2026-10-29).
        let scratch: URL

        /// An import the player called off: its scratch copy goes.
        func discard() {
            try? FileManager.default.removeItem(at: scratch)
            if let extdata { try? FileManager.default.removeItem(at: extdata) }
        }
    }

    /// The scratch folders of save imports left in tmp: one prepared and
    /// never applied nor discarded (its dialog dismissed by a tap outside it,
    /// which runs no button; the app ended meanwhile). Run at launch (audit,
    /// 2026-10-29). Only this type's own prefixes are touched, and only
    /// folders older than ten minutes: a save opened from Files as the app
    /// comes up can be importing while this runs.
    static func sweepImportScratch(now: Date = Date()) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
        where name.hasPrefix(scratchPrefix) || name.hasPrefix(extdataScratchPrefix) {
            let url = tmp.appendingPathComponent(name)
            guard let written = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(written) > 600 else { continue }
            try? fm.removeItem(at: url)
        }
    }

    private static let scratchPrefix = "CTRSaveImport-"
    private static let extdataScratchPrefix = "CTRExtdataImport-"

    static func prepare(zipURL: URL) -> Result<Pending, ImportError> {
        let scope = zipURL.startAccessingSecurityScopedResource()
        defer { if scope { zipURL.stopAccessingSecurityScopedResource() } }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(scratchPrefix)\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            _ = try ZIPExtractor.extractAll(from: zipURL, to: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            return .failure(.unreadable)
        }
        // A zip made by the Mac's Finder carries a `__MACOSX` folder of
        // resource forks beside what was zipped: it made the `data` folder
        // one child of two (refused as not a save), and at the root it would
        // have gone into the game's save (audit, 2026-10-30).
        try? FileManager.default.removeItem(at: scratch.appendingPathComponent("__MACOSX", isDirectory: true))
        // The metadata at the root, or one folder down when the export was
        // the `data` folder itself.
        var root = scratch
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("00000001.metadata").path) {
            let children = ((try? FileManager.default.contentsOfDirectory(
                at: scratch, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            if children.count == 1,
               FileManager.default.fileExists(atPath: children[0].appendingPathComponent("00000001.metadata").path) {
                root = children[0]
            } else {
                try? FileManager.default.removeItem(at: scratch)
                return .failure(.notASave)
            }
        }
        // The extdata goes into its own scratch folder, and its ID out of the
        // folder, so `contents` is the save folder's contents alone.
        let idFile = root.appendingPathComponent(extdataIDEntry)
        let namedID = (try? String(contentsOf: idFile, encoding: .utf8))
            .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) }
            .flatMap { $0 == 0 ? nil : $0 }
        try? FileManager.default.removeItem(at: idFile)
        var extdata: URL?
        let zipped = root.appendingPathComponent(String(extdataPrefix.dropLast()), isDirectory: true)
        if FileManager.default.fileExists(atPath: zipped.path) {
            let moved = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(extdataScratchPrefix)\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.moveItem(at: zipped, to: moved)
                extdata = moved
            } catch {
                try? FileManager.default.removeItem(at: scratch)
                return .failure(.unreadable)
            }
        }
        return .success(Pending(contents: root, extdata: extdata, extdataID: namedID, scratch: scratch))
    }

    /// Puts a prepared save in place of the game's. The current save, if any,
    /// is zipped to the backups first (`<rom>-<stamp>.zip`, as an overwritten
    /// `.sav` is), then replaced in one move.
    /// `keepBackups`: how many of this name's backups stay, nil for all (a
    /// player's own import). An iCloud pull passes a number: each pull zipped
    /// the save it replaced, and nothing ever removed those (audit, 2026-10-29).
    static func apply(_ pending: Pending, titleID: UInt64, romBasename: String,
                      keepBackups: Int? = nil) throws {
        let folder = saveFolder(titleID: titleID)
        // The backup is best-effort (`backUp`); when it could not be written
        // (a full disk, an unreadable file), the replaced folder itself is
        // kept in the backups below instead of deleted, so a confirmed import
        // or an iCloud pull never ends with the old save in no copy at all
        // (audit, 2026-10-20).
        let backupZip = hasSave(titleID: titleID)
            ? backUp(titleID: titleID, romBasename: romBasename, infix: "-", keep: keepBackups) : nil
        let backedUp = !hasSave(titleID: titleID) || backupZip != nil
        // The extdata is in that zip only when there was a save to zip: a
        // game with extdata and no save yet had its extdata replaced as if it
        // were backed up, and deleted with no copy (audit, 2026-10-30).
        // Nor when this device did not know the game's extdata ID yet (learnt
        // below, from the incoming zip): `zipSave` could not have found it.
        let extdataBackedUp = backupZip != nil && existingExtdataFolder(titleID: titleID) != nil
        let fm = FileManager.default
        // Whatever is left of the unpacked zip once this returns: nothing when
        // `contents` was the scratch folder and moved in, the empty parent when
        // it was one folder down, the whole copy when the move failed.
        defer { pending.discard() }
        // The old folder is moved aside, the new one moved in, and the old
        // one put back if that fails: never a moment with half a save. Moves,
        // not `replaceItemAt`, which is not documented to swap two non-empty
        // folders (and on Linux, where this is tested, it cannot).
        let aside = folder.deletingLastPathComponent()
            .appendingPathComponent("data-replaced-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            let hadSave = fm.fileExists(atPath: folder.path)
            if hadSave { try fm.moveItem(at: folder, to: aside) }
            do {
                try fm.moveItem(at: pending.contents, to: folder)
            } catch {
                if hadSave { try? fm.moveItem(at: aside, to: folder) }
                throw error
            }
            if hadSave {
                if backedUp {
                    try? fm.removeItem(at: aside)
                } else {
                    let kept = BatterySaveImporter.backupsDir
                        .appendingPathComponent("\(romBasename)-\(timestamp())", isDirectory: true)
                    try? fm.createDirectory(at: BatterySaveImporter.backupsDir, withIntermediateDirectories: true)
                    // Not even moved: it stays where it is, beside the save,
                    // rather than going.
                    try? fm.moveItem(at: aside, to: kept)
                }
            }
            // The extdata, when the zip has it and its ID is known: the game's
            // own file says it when this device has read it, the zip when it
            // has not (and this device then remembers it). The same move aside
            // and in. Its failure leaves the save applied and the old extdata
            // in place.
            if pending.extdata != nil, extdataID(forTitleID: titleID) == nil, let named = pending.extdataID {
                rememberExtdataID(named, forTitleID: titleID)
            }
            if let incoming = pending.extdata, let id = extdataID(forTitleID: titleID) {
                let target = extdataFolder(extdataID: id)
                let old = target.deletingLastPathComponent()
                    .appendingPathComponent("extdata-replaced-\(UUID().uuidString)", isDirectory: true)
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let hadExtdata = fm.fileExists(atPath: target.path)
                if hadExtdata { try? fm.moveItem(at: target, to: old) }
                if (try? fm.moveItem(at: incoming, to: target)) != nil {
                    // Kept, as the save folder above, when the backup zip (it
                    // carries the extdata too) could not be written: it was
                    // removed even then, the one copy of it gone (audit,
                    // 2026-10-29).
                    if hadExtdata {
                        if extdataBackedUp {
                            try? fm.removeItem(at: old)
                        } else {
                            let kept = BatterySaveImporter.backupsDir
                                .appendingPathComponent("\(romBasename)-extdata-\(timestamp())", isDirectory: true)
                            try? fm.createDirectory(at: BatterySaveImporter.backupsDir, withIntermediateDirectories: true)
                            try? fm.moveItem(at: old, to: kept)
                        }
                    }
                } else {
                    if hadExtdata { try? fm.moveItem(at: old, to: target) }
                    try? fm.removeItem(at: incoming)
                }
            } else if let incoming = pending.extdata {
                try? fm.removeItem(at: incoming)
            }
        } catch {
            Analytics.signal("save_failure", ["kind": "battery_write",
                                              "system": ROMSystemType.n3ds.rawValue,
                                              "reason": ErrorTelemetry.writeReason(for: error).rawValue])
            throw ImportError.writeFailed
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .batterySavesDidChange, object: nil)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
