//
//  ROMImporter.swift
//  EmulateurGBA
//
//  Handles the full ROM import flow:
//  1. Accept .gba from Files picker
//  2. Validate GBA ROM header (0xB2 == 0x96)
//  3. Copy to Documents/ROMs/
//  4. Parse header for title + compute SHA256 hash
//  5. Create GameEntity in Core Data
//

import Foundation
import CoreData

/// Outcome of `findOrImport(at:method:)`. Lets the caller distinguish a freshly
/// copied ROM from one that was already in the library — used by the
/// Files → "Open in Retro Pal" URL handler so duplicate opens navigate
/// to the existing game instead of erroring out.
enum ROMImportResult {
    case imported(NSManagedObjectID)
    case existed(NSManagedObjectID)
}

/// Carry the ZIP reader's REASON out to the person instead of flattening every
/// failure into "couldn't be opened". A valid archive we cannot read is a
/// different sentence from a broken one, and the 2026-09-02 Japanese 1-star
/// review is what made that distinction worth the code.
private func importError(for error: Error) -> ROMImportError {
    switch error {
    case ZIPExtractorError.unsupportedCompression: return .zipUnsupportedCompression
    case ZIPExtractorError.encryptedArchive: return .zipEncrypted
    default: return .zipExtractionFailed
    }
}

enum ROMImportError: LocalizedError {
    case fileAccessDenied
    case copyFailed
    case invalidROM
    case zipNoGBA
    /// Control flow, not a failure: the zip holds several ROMs, so the user
    /// picks which games to import (ZipROMPickerSheet). Carries the temp
    /// copy of the archive that importZIP staged — kept alive on purpose;
    /// `importZIPSelection` (or `discardZIPSelection` on cancel) deletes it.
    case zipNeedsSelection(tempZipURL: URL, entryNames: [String])
    case zipExtractionFailed
    /// The archive is valid and uses a compression method we do not read
    /// (LZMA, BZIP2, Deflate64, Zstandard). Separate from `zipExtractionFailed`
    /// because nothing is broken and the fix is different.
    case zipUnsupportedCompression
    /// Password-protected archive.
    case zipEncrypted
    case alreadyImported
    case saveFailed
    /// The file picked to replace a game's ROM is a different game (its hash
    /// doesn't match the one recorded at import), so the existing save states
    /// wouldn't be valid for it.
    case differentGame
    /// A disc was picked without the files it is made of. Carries their names,
    /// because "some files are missing" is not actionable and "Game (Track
    /// 01).bin is missing" is. iOS grants access per picked file, so there is
    /// no way to reach a sibling the person did not select.
    case discMissingFiles(names: [String])

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied: return NSLocalizedString("import.error.fileAccessDenied", comment: "")
        case .copyFailed: return NSLocalizedString("import.error.copyFailed", comment: "")
        case .invalidROM: return NSLocalizedString("import.error.invalidROM", comment: "")
        case .zipNoGBA: return NSLocalizedString("import.error.zipNoROM", comment: "")
        case .zipNeedsSelection: return nil   // never shown; handled by the picker flow
        case .zipExtractionFailed: return NSLocalizedString("import.error.zipExtractionFailed", comment: "")
        case .zipUnsupportedCompression: return NSLocalizedString("import.error.zipUnsupportedCompression", comment: "")
        case .zipEncrypted: return NSLocalizedString("import.error.zipEncrypted", comment: "")
        case .alreadyImported: return NSLocalizedString("import.error.alreadyImported", comment: "")
        case .saveFailed: return NSLocalizedString("import.error.saveFailed", comment: "")
        case .differentGame: return NSLocalizedString("import.error.differentGame", comment: "")
        case .discMissingFiles(let names):
            return String(format: NSLocalizedString("import.error.discMissingFiles", comment: ""),
                          names.joined(separator: ", "))
        }
    }

    /// Stable, anonymous identifier for analytics (no user content).
    var analyticsID: String {
        switch self {
        case .fileAccessDenied: return "fileAccessDenied"
        case .copyFailed: return "copyFailed"
        case .invalidROM: return "invalidROM"
        case .zipNoGBA: return "zipNoGBA"
        case .zipNeedsSelection: return "zipNeedsSelection"   // never signaled; picker flow
        case .zipExtractionFailed: return "zipExtractionFailed"
        case .zipUnsupportedCompression: return "zipUnsupportedCompression"
        case .zipEncrypted: return "zipEncrypted"
        case .alreadyImported: return "alreadyImported"
        case .saveFailed: return "saveFailed"
        case .differentGame: return "differentGame"
        case .discMissingFiles: return "discMissingFiles"
        }
    }
}

/// One failed entry of a multi-ROM zip selection import, for the summary
/// alert (displayName + reason) and the error signals (analyticsID).
struct ZipEntryFailure {
    let displayName: String
    let reason: String
    let analyticsID: String
}

final class ROMImporter {
    private let context: NSManagedObjectContext
    private let romsDir: URL

    init(context: NSManagedObjectContext) {
        self.context = context
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.romsDir = docs.appendingPathComponent("ROMs", isDirectory: true)
        try? FileManager.default.createDirectory(at: romsDir, withIntermediateDirectories: true)
    }

    /// Full ROM URL inside the app sandbox
    func romURL(for filename: String) -> URL {
        romsDir.appendingPathComponent(filename)
    }

    /// Hash-first import: if the ROM at `sourceURL` is already in the
    /// library (matched by SHA256 of the file contents, including ZIP
    /// payloads), return its existing object ID without re-copying. Else
    /// run the full import flow and return the freshly created ID.
    ///
    /// Used by the Files → "Open in Retro Pal" URL handler so tapping a
    /// ROM that's already imported navigates to its Game Details view
    /// instead of surfacing a confusing "already imported" error.
    func findOrImport(at sourceURL: URL, method: String) throws -> ROMImportResult {
        // Conditional security-scoped access: required for URLs from the
        // document picker (cross-sandbox), no-op-returning-false for URLs
        // delivered via .onOpenURL / share sheet / AirDrop (iOS has already
        // copied the file into our Documents/Inbox before delivery, so it's
        // directly readable). Calling start unconditionally and only
        // balancing stop when start succeeded handles both paths correctly.
        let didStartScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { sourceURL.stopAccessingSecurityScopedResource() } }

        // For ZIP we have to extract before we can hash the inner ROM, so
        // fall straight through to the normal import path (it surfaces
        // .alreadyImported as a regular throw; the caller can re-fetch by
        // hash if it wants the existing entity, but in practice the URL
        // handler ignores .zip via the no-zip-claim decision).
        let ext = sourceURL.pathExtension.lowercased()
        if ext == "zip" {
            let id = try importROM(from: sourceURL, method: method)
            return .imported(id)
        }

        // Cheap probe: read the file once, hash it, look the hash up in
        // Core Data. Avoids the redundant copy + parse for duplicates.
        guard GBAROMParser.isValidROMFile(url: sourceURL) else {
            throw ROMImportError.invalidROM
        }
        guard let probeData = try? Data(contentsOf: sourceURL, options: .mappedIfSafe),
              let info = GBAROMParser.parse(
                data: probeData,
                fileSize: Int64(probeData.count),
                systemHint: ROMSystemType.from(fileExtension: sourceURL.pathExtension)) else {
            throw ROMImportError.invalidROM
        }

        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "GameEntity")
        fetchRequest.predicate = NSPredicate(format: "romHash == %@", info.sha256)
        fetchRequest.fetchLimit = 1
        if let existing = try context.fetch(fetchRequest).first {
            // Duplicate import — discard the Inbox file iOS dropped on us so
            // it doesn't sit around taking disk space.
            cleanupInboxFile(sourceURL)
            return .existed(existing.objectID)
        }

        // Not in library — full import path produces a new entity.
        let id = try importROM(from: sourceURL, method: method)
        return .imported(id)
    }

    /// Import a ROM from a URL. Handles both security-scoped sources (the
    /// in-app document picker) and directly-readable sources (share sheet /
    /// AirDrop / "Open in Retro Pal" — iOS pre-copies these into our Inbox).
    func importROM(from sourceURL: URL, method: String) throws -> NSManagedObjectID {
        // See findOrImport(at:) for the rationale on conditional scoping.
        let didStartScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.lowercased()

        if ext == "zip" {
            return try importZIP(from: sourceURL)
        }

        // A disc never takes the flat cartridge path below, even when it is a
        // single file: it needs its own folder, because that folder is what
        // names its saves and what a second disc of the same game would
        // otherwise collide with. Routed through the grouper rather than
        // constructed here, so one `.cue` opened from Files gets exactly the
        // same answer as one `.cue` picked in a batch — including the message
        // naming the tracks it cannot reach.
        if ROMSystemType.discFileExtensions.contains(ext) {
            let (_, discs, gaps) = DiscImportGrouper.group([sourceURL])
            if let gap = gaps.first { throw ROMImportError.discMissingFiles(names: gap.missing) }
            guard let group = discs.first else { throw ROMImportError.invalidROM }
            return try importDiscGroup(group, method: method)
        }

        // Validate ROM header (GBA, GB, or GBC)
        guard GBAROMParser.isValidROMFile(url: sourceURL) else {
            throw ROMImportError.invalidROM
        }

        // Hash-first duplicate guard: if this ROM is already in the library, do
        // NOT copy — and never touch the existing on-disk file. Copying to the
        // (identical) destination and then deleting it on the duplicate check
        // below was the cause of a game losing its ROM file after a repeat
        // import, which then failed to launch as "file damaged".
        if let info = GBAROMParser.parse(fileURL: sourceURL) {
            let dupCheck = NSFetchRequest<NSManagedObject>(entityName: "GameEntity")
            dupCheck.predicate = NSPredicate(format: "romHash == %@", info.sha256)
            dupCheck.fetchLimit = 1
            if !(((try? context.fetch(dupCheck)) ?? []).isEmpty) {
                cleanupInboxFile(sourceURL)
                throw ROMImportError.alreadyImported
            }
        }

        // Copy to sandbox
        let filename = sourceURL.lastPathComponent
        let destURL = romsDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destURL)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw ROMImportError.copyFailed
        }
        try verifyCopyComplete(source: sourceURL, dest: destURL)

        let id = try createGameEntry(romURL: destURL, originalFilename: filename, method: method)
        cleanupInboxFile(sourceURL)
        return id
    }

    /// Import one disc game: every file it is made of, into a folder of its
    /// own, and one library entry pointing at the file the emulator boots.
    ///
    /// A folder rather than the flat layout the cartridges use, because a disc
    /// game is several files whose names it does not control. `Game (Track
    /// 01).bin` is a name two different games can both have, and a `.cue`
    /// naming its tracks only works if they sit beside it. Giving each game a
    /// directory makes both true without renaming anything the descriptors
    /// point at.
    /// - Parameter movingMembers: take the files rather than copy them. True
    ///   only when they are OUR OWN staging copies, freshly decompressed out of
    ///   an archive, and it is not an optimisation: a PlayStation disc runs to
    ///   most of a gigabyte, so copying a staged one means holding the archive,
    ///   the staging and the final copy at once, on a device where that is the
    ///   difference between an import working and the disk being full.
    func importDiscGroup(_ group: DiscImportGroup, method: String,
                         movingMembers: Bool = false) throws -> NSManagedObjectID {
        // One scope per member: they were picked separately and are granted
        // separately, so opening them as a batch is not an option.
        var scoped: [URL] = []
        for url in group.members {
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
        }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        // Identify BEFORE copying, so a duplicate costs nothing: a disc runs to
        // hundreds of megabytes and copying one to discover we already have it
        // is the most expensive mistake available on this console.
        guard let info = GBAROMParser.parse(fileURL: group.identityFile) else {
            throw ROMImportError.invalidROM
        }
        let dupCheck = NSFetchRequest<NSManagedObject>(entityName: "GameEntity")
        dupCheck.predicate = NSPredicate(format: "romHash == %@", info.sha256)
        dupCheck.fetchLimit = 1
        if !(((try? context.fetch(dupCheck)) ?? []).isEmpty) {
            group.members.forEach { cleanupInboxFile($0) }
            throw ROMImportError.alreadyImported
        }

        let folderName = uniqueFolderName(for: group.displayName)
        let folder = romsDir.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ROMImportError.copyFailed
        }

        // Any failure past this point takes the whole folder with it. A disc
        // game that is half copied is worse than one that is absent: it appears
        // in the library and fails at boot, which is the shape of the 1.1
        // "file damaged" bug this project already paid for once.
        func abandon() { try? FileManager.default.removeItem(at: folder) }

        var bootDestination: URL?
        for member in group.members {
            let dest = folder.appendingPathComponent(member.lastPathComponent)
            do {
                try? FileManager.default.removeItem(at: dest)
                if movingMembers {
                    // A move inside the same volume is a rename, so there is no
                    // size to verify: the bytes never travelled.
                    try FileManager.default.moveItem(at: member, to: dest)
                } else {
                    try FileManager.default.copyItem(at: member, to: dest)
                    try verifyCopyComplete(source: member, dest: dest)
                }
            } catch {
                abandon()
                throw ROMImportError.copyFailed
            }
            // A `.cue` or `.m3u` that was not UTF-8 is rewritten as UTF-8, in
            // place, with the text the grouper decoded. The core opens the
            // files a descriptor names by the BYTES in the descriptor, and the
            // discs beside it were just written under their decoded, UTF-8
            // names: a Shift-JIS cue copied verbatim names a `.bin` that no
            // longer exists on this disk, and the game boots to nothing with
            // a library entry that looks fine. A descriptor that already is
            // UTF-8 is copied byte for byte and never touched.
            if Self.isDescriptor(dest),
               let bytes = try? Data(contentsOf: dest),
               !LegacyTextEncoding.isUTF8(bytes) {
                do {
                    try LegacyTextEncoding.decodeLegacy(bytes)
                        .write(to: dest, atomically: true, encoding: .utf8)
                } catch {
                    abandon()
                    throw ROMImportError.copyFailed
                }
            }
            if member.path == group.boot.path { bootDestination = dest }
        }
        guard var boot = bootDestination else {
            abandon()
            throw ROMImportError.copyFailed
        }

        // A multi-disc game that arrived without a playlist gets one written for
        // it, here, from the names the grouper put in disc order.
        //
        // ⚠ WHY IT IS WRITTEN RATHER THAN INFERRED AT LAUNCH. The core reads a
        // playlist and nothing else: without a file naming the discs it sees one
        // image, reports a single disc, and the pause menu's disc picker never
        // appears. And the cost of that is not only the picker. A disc game's
        // memory card and its save states are filed under its FOLDER, so three
        // separate entries meant three memory cards, and the save from disc one
        // was not there when disc two started.
        //
        // Named after the folder, which is already sanitised and already unique,
        // so this can never collide with a disc file beside it. Lines are bare
        // filenames: the core resolves them against the playlist's own
        // directory, which is this folder.
        if let discs = group.playlistDiscs, discs.count > 1 {
            let playlist = folder.appendingPathComponent("\(folderName).m3u")
            do {
                try (discs.joined(separator: "\n") + "\n")
                    .write(to: playlist, atomically: true, encoding: .utf8)
            } catch {
                abandon()
                throw ROMImportError.copyFailed
            }
            boot = playlist
        }

        do {
            // Measured AFTER the copy, from the folder, because that is what the
            // launch preflight will measure too. Recording the identity file's
            // size here (the data track) while pointing `romFilePath` at the
            // `.cue` is what made a good game report itself damaged.
            let installed = DiscStorage.installedSize(ofROMAt: boot) ?? info.fileSize
            let id = try createDiscEntry(boot: boot,
                                         relativePath: "\(folderName)/\(boot.lastPathComponent)",
                                         info: info,
                                         installedSize: installed,
                                         method: method)
            group.members.forEach { cleanupInboxFile($0) }
            return id
        } catch {
            abandon()
            throw error
        }
    }

    /// The text descriptors a disc game can carry.
    private static func isDescriptor(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "cue" || ext == "m3u" || ext == "toc"
    }

    /// A directory name no existing game is using. Sanitised because it becomes
    /// a real path AND the key every save, save state and per-game setting is
    /// filed under.
    private func uniqueFolderName(for displayName: String) -> String {
        var base = displayName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Disc" }
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: romsDir.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    /// Replace a game's on-disk ROM file in place, KEEPING its library entry and
    /// save states. Save-preserving recovery for a corrupted/missing ROM file —
    /// unlike delete + re-import, which drops local save states. The picked file
    /// must be the SAME game (its SHA256 must match the hash recorded at import)
    /// so the existing save states stay valid; otherwise throws `.differentGame`.
    func replaceROMFile(for game: GameEntity, from sourceURL: URL) throws {
        let didStartScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { sourceURL.stopAccessingSecurityScopedResource() } }

        // KVC for the hash (it's only ever accessed via KVC elsewhere, so don't
        // assume a generated typed accessor exists); romFilePath is a known property.
        guard let storedFilename = game.romFilePath,
              let storedHash = game.value(forKey: "romHash") as? String else {
            throw ROMImportError.copyFailed
        }

        // Resolve the ROM bytes (extract first if a .zip was picked, mirroring import).
        var cleanup: [URL] = []
        defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
        let romFileURL: URL
        if sourceURL.pathExtension.lowercased() == "zip" {
            let tempZip = FileManager.default.temporaryDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            try? FileManager.default.removeItem(at: tempZip)
            try FileManager.default.copyItem(at: sourceURL, to: tempZip)
            cleanup.append(tempZip)

            let entryNames: [String]
            do {
                entryNames = try ZIPExtractor.romEntryNames(in: tempZip)
            } catch {
                throw importError(for: error)
            }
            guard !entryNames.isEmpty else { throw ROMImportError.zipNoGBA }

            // The target game is known here, so a multi-ROM zip needs no
            // picker: auto-select the entry whose hash matches the game
            // being repaired. No match at all = every entry is some other
            // game, the same situation .differentGame already describes.
            var matched: URL?
            for name in entryNames {
                guard let extracted = try? ZIPExtractor.extractROM(named: name, from: tempZip) else { continue }
                cleanup.append(extracted.deletingLastPathComponent())
                if GBAROMParser.parse(fileURL: extracted)?.sha256 == storedHash {
                    matched = extracted
                    break
                }
            }
            guard let matched else { throw ROMImportError.differentGame }
            romFileURL = matched
        } else {
            romFileURL = sourceURL
        }

        guard GBAROMParser.isValidROMFile(url: romFileURL),
              let info = GBAROMParser.parse(fileURL: romFileURL) else {
            throw ROMImportError.invalidROM
        }

        // Same-game guard: the hash must match so the existing saves stay valid.
        guard info.sha256 == storedHash else {
            throw ROMImportError.differentGame
        }

        // Replace via a verified temp file, then move into place. Handles both a
        // corrupt existing file and a missing one. The entity (path/hash/size)
        // and the save-state folder are left untouched.
        let destURL = romsDir.appendingPathComponent(storedFilename)
        let tmp = destURL.appendingPathExtension("replacing")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: romFileURL, to: tmp)
        try verifyCopyComplete(source: romFileURL, dest: tmp)
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: tmp, to: destURL)
    }

    /// If the source URL lives in our Documents/Inbox (where iOS drops files
    /// from share sheet, AirDrop, "Open in Retro Pal", etc.), remove it now
    /// that we've copied the contents to Documents/ROMs. Inbox files
    /// otherwise accumulate indefinitely — iOS doesn't garbage-collect them.
    /// No-op for URLs outside Inbox (e.g. cross-sandbox URLs from the
    /// document picker, which we don't own).
    private func cleanupInboxFile(_ url: URL) {
        let inboxPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Inbox").path
        if url.path.hasPrefix(inboxPath) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - ZIP Import

    private func importZIP(from sourceURL: URL) throws -> NSManagedObjectID {
        // Copy ZIP to temp for extraction
        let tempZip = FileManager.default.temporaryDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try? FileManager.default.removeItem(at: tempZip)
        try FileManager.default.copyItem(at: sourceURL, to: tempZip)

        // GAMES, not files. An archive holding one PlayStation disc holds it in
        // as many pieces as the disc had tracks: Tomb Raider is a `.cue` and
        // fifty-seven `.bin`, and listing those as fifty-eight choices is what
        // this used to do. Only the descriptors are decompressed to work it out,
        // so this costs a few hundred bytes whatever the archive weighs.
        let games: (discs: [DiscNameGroup], cartridges: [String], gaps: [DiscNameGap])
        do {
            games = try ZIPExtractor.gameEntries(in: tempZip)
        } catch {
            try? FileManager.default.removeItem(at: tempZip)
            throw importError(for: error)
        }

        if let gap = games.gaps.first, games.discs.isEmpty, games.cartridges.isEmpty {
            try? FileManager.default.removeItem(at: tempZip)
            throw ROMImportError.discMissingFiles(names: gap.missing)
        }

        let total = games.discs.count + games.cartridges.count
        guard total > 0 else {
            try? FileManager.default.removeItem(at: tempZip)
            throw ROMImportError.zipNoGBA
        }

        // Several GAMES: hand the temp copy to the caller so the user can pick
        // which to add. The temp copy deliberately survives this throw;
        // importZIPSelection / discardZIPSelection deletes it. What the picker
        // is given is one name per game, the boot file for a disc, so choosing
        // "Tomb Raider" quietly brings its fifty-eight files with it.
        guard total == 1 else {
            cleanupInboxFile(sourceURL)
            let names = games.discs.map(\.boot) + games.cartridges
            throw ROMImportError.zipNeedsSelection(tempZipURL: tempZip, entryNames: names)
        }

        defer { try? FileManager.default.removeItem(at: tempZip) }
        let id: NSManagedObjectID
        if let disc = games.discs.first {
            id = try importDiscGroup(disc, fromZip: tempZip, method: "picker")
        } else {
            id = try importEntry(named: games.cartridges[0], fromZip: tempZip)
        }
        cleanupInboxFile(sourceURL)
        return id
    }

    /// Import one disc game out of an archive: extract the files it is made of
    /// into a temp directory, then hand them to the same folder-per-game
    /// importer the picked-files path uses.
    ///
    /// Deliberately routed through `importDiscGroup` rather than given its own
    /// copy of that logic. The duplicate check, the folder naming, the identity
    /// hash and the delete-the-whole-folder-on-failure rule are all decisions
    /// that must not differ by where the disc happened to come from.
    private func importDiscGroup(_ group: DiscNameGroup, fromZip tempZip: URL,
                                 method: String) throws -> NSManagedObjectID {
        let extracted: [URL]
        do {
            extracted = try ZIPExtractor.extractEntries(named: group.members, from: tempZip)
        } catch {
            throw importError(for: error)
        }
        let staging = extracted.first?.deletingLastPathComponent()
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }

        let bootName = URL(fileURLWithPath: group.boot).lastPathComponent
        guard let boot = extracted.first(where: { $0.lastPathComponent == bootName }) else {
            throw ROMImportError.zipExtractionFailed
        }
        // The playlist decision travels with the group: an archive holding three
        // `.chd` files of one game is the same case as three picked files, and
        // it would be a poor joke to fix one and not the other.
        return try importDiscGroup(DiscImportGroup(boot: boot, members: extracted,
                                                   playlistDiscs: group.playlistDiscs,
                                                   name: group.name),
                                   method: method, movingMembers: true)
    }

    /// Import the user's picks from a multi-ROM zip (the ZipROMPickerSheet
    /// outcome). `tempZip` is the temp copy importZIP staged before throwing
    /// `zipNeedsSelection`; it's deleted here when done.
    ///
    /// Returns the failures for the caller's summary alert AND the picks that
    /// were already in the library. Those two are separate on purpose: a
    /// duplicate is not a failure, it is an outcome, and it used to be dropped
    /// here without a word. From the player's side that was an import that ran
    /// its loader and then simply did not happen.
    /// Success signals fire per entry inside createGameEntry.
    func importZIPSelection(entryNames: [String], fromTempZip tempZip: URL)
        -> (failures: [ZipEntryFailure], duplicates: [String]) {
        defer { try? FileManager.default.removeItem(at: tempZip) }
        // Re-grouped rather than remembered: the sheet hands back the names it
        // was given, and a disc's boot file has to be expanded into its parts
        // again. Re-reading a few hundred bytes of descriptor is cheaper than
        // carrying a parallel structure through the picker and keeping the two
        // in step.
        let games = (try? ZIPExtractor.gameEntries(in: tempZip))
        let discsByBoot = Dictionary((games?.discs ?? []).map { ($0.boot, $0) },
                                     uniquingKeysWith: { a, _ in a })

        var failures: [ZipEntryFailure] = []
        var duplicates: [String] = []
        for name in entryNames {
            let displayName = URL(fileURLWithPath: name).lastPathComponent
            do {
                if let disc = discsByBoot[name] {
                    _ = try importDiscGroup(disc, fromZip: tempZip, method: "picker")
                } else {
                    _ = try importEntry(named: name, fromZip: tempZip, uniquifyFilename: true)
                }
            } catch let error as ROMImportError {
                if case .alreadyImported = error { duplicates.append(displayName); continue }
                failures.append(ZipEntryFailure(displayName: displayName,
                                                reason: error.errorDescription ?? "",
                                                analyticsID: error.analyticsID))
            } catch {
                failures.append(ZipEntryFailure(displayName: displayName,
                                                reason: error.localizedDescription,
                                                analyticsID: "unknown"))
            }
        }
        return (failures, duplicates)
    }

    /// Cancel path of the zip picker: drop the temp copy importZIP staged.
    static func discardZIPSelection(tempZipURL: URL) {
        try? FileManager.default.removeItem(at: tempZipURL)
    }

    /// Extract one entry of the archive, validate it, copy it into ROMs/ and
    /// create its library entry. Shared by the single-ROM zip path and the
    /// multi-ROM selection import.
    ///
    /// `uniquifyFilename` is on for the selection path only: a multi-ROM zip
    /// can hold same-named entries in different folders, and overwriting
    /// would leave an earlier entry's library row pointing at another game's
    /// bytes. The single path keeps its historical overwrite behavior.
    private func importEntry(named name: String, fromZip tempZip: URL, uniquifyFilename: Bool = false) throws -> NSManagedObjectID {
        let extractedURL: URL
        do {
            extractedURL = try ZIPExtractor.extractROM(named: name, from: tempZip)
        } catch {
            throw importError(for: error)
        }
        defer { try? FileManager.default.removeItem(at: extractedURL.deletingLastPathComponent()) }

        // Validate (GBA, GB, GBC, NDS)
        guard GBAROMParser.isValidROMFile(url: extractedURL) else {
            throw ROMImportError.invalidROM
        }

        // Copy to ROMs directory
        var destURL = romsDir.appendingPathComponent(extractedURL.lastPathComponent)
        if uniquifyFilename {
            destURL = Self.uniqueDestination(for: destURL)
        } else {
            try? FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: extractedURL, to: destURL)
        try verifyCopyComplete(source: extractedURL, dest: destURL)

        return try createGameEntry(romURL: destURL, originalFilename: destURL.lastPathComponent, method: "zip")
    }

    /// First free "name.ext", "name 2.ext", ... inside ROMs/. Never touches
    /// an existing file: it may be another game's live ROM.
    private static func uniqueDestination(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...999 {
            let candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(base) \(UUID().uuidString)").appendingPathExtension(ext)
    }

    /// Throws (and removes the partial dest) if the copied file's size doesn't
    /// match the source. A truncated copy otherwise yields a library entry that
    /// loads fine in the list but fails when the emulator tries to read the ROM
    /// (only a re-import fixes it). Belt-and-suspenders alongside the header
    /// re-parse in createGameEntry, which only validates the first bytes.
    private func verifyCopyComplete(source: URL, dest: URL) throws {
        let fm = FileManager.default
        let srcSize = ((try? fm.attributesOfItem(atPath: source.path))?[.size] as? NSNumber)?.int64Value
        let dstSize = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value
        if let srcSize, let dstSize, srcSize != dstSize {
            try? fm.removeItem(at: dest)
            throw ROMImportError.copyFailed
        }
    }

    // MARK: - Core Data

    /// The library entry for a disc game.
    ///
    /// Separate from `createGameEntry` for two reasons, both about the fact
    /// that a disc has already been identified by the time we get here.
    /// `createGameEntry` re-parses the file it copied, which for a disc would
    /// mean re-reading the data track after having read it once already; and
    /// `romFilePath` stores a RELATIVE PATH (`<folder>/<boot>`) rather than a
    /// bare filename, which is what every reader resolves against `ROMs/`
    /// anyway and what makes the folder the game's identity.
    private func createDiscEntry(boot: URL,
                                 relativePath: String,
                                 info: ROMInfo,
                                 installedSize: Int64,
                                 method: String) throws -> NSManagedObjectID {
        // A disc's header title is empty by design (see GBAROMParser), so the
        // name is the boot file's, cleaned exactly as a cartridge filename is.
        let rawTitle = boot.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
        let title = Self.cleanGameTitle(rawTitle)

        let game = NSEntityDescription.insertNewObject(forEntityName: "GameEntity", into: context)
        game.setValue(UUID(), forKey: "id")
        game.setValue(title, forKey: "title")
        game.setValue(relativePath, forKey: "romFilePath")
        game.setValue(info.sha256, forKey: "romHash")
        // Every file the game is made of, not just the one the core is pointed
        // at. It is what Game Details shows and what the preflight checks.
        game.setValue(installedSize, forKey: "romSize")
        game.setValue(Date(), forKey: "importedAt")
        game.setValue(Date(), forKey: "lastPlayedAt")
        game.setValue(ROMSystemType.ps1.rawValue, forKey: "systemType")
        game.setValue("placeholder", forKey: "coverType")

        do {
            try context.save()
        } catch {
            throw ROMImportError.saveFailed
        }

        Analytics.signal("rom_import", ["result": "success", "system": ROMSystemType.ps1.rawValue, "method": method])
        if !UserDefaults.standard.bool(forKey: "didImportROM") {
            UserDefaults.standard.set(true, forKey: "didImportROM")
            Analytics.signal("import_first")
        }
        return game.objectID
    }

    private func createGameEntry(romURL destURL: URL, originalFilename filename: String, method: String) throws -> NSManagedObjectID {
        guard let info = GBAROMParser.parse(fileURL: destURL) else {
            try? FileManager.default.removeItem(at: destURL)
            throw ROMImportError.invalidROM
        }

        // Check for duplicates by hash
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "GameEntity")
        fetchRequest.predicate = NSPredicate(format: "romHash == %@", info.sha256)
        let existing = try context.fetch(fetchRequest)
        if let dup = existing.first {
            // Same ROM already in the library. Only remove the copy we just made
            // if it's a SEPARATE file from the existing game's ROM — NEVER delete
            // the live file (deleting it here was the "file damaged" bug after a
            // repeat import). The importROM path already guards this before
            // copying; this covers the ZIP path and is defense-in-depth.
            let dupPath = dup.value(forKey: "romFilePath") as? String
            if dupPath != destURL.lastPathComponent {
                try? FileManager.default.removeItem(at: destURL)
            }
            throw ROMImportError.alreadyImported
        }

        // Use ROM header title, fall back to cleaned filename
        let rawTitle = info.title != "Unknown Game"
            ? info.title
            : URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
        let title = Self.cleanGameTitle(rawTitle)

        // Create Core Data entry
        let game = NSEntityDescription.insertNewObject(forEntityName: "GameEntity", into: context)
        game.setValue(UUID(), forKey: "id")
        game.setValue(title, forKey: "title")
        game.setValue(destURL.lastPathComponent, forKey: "romFilePath")
        game.setValue(info.sha256, forKey: "romHash")
        game.setValue(info.fileSize, forKey: "romSize")
        game.setValue(Date(), forKey: "importedAt")
        // Surface a freshly imported game at the top of the library: the
        // default sort is by last-played, so treat the import as a play.
        game.setValue(Date(), forKey: "lastPlayedAt")
        game.setValue(info.systemType.rawValue, forKey: "systemType")
        game.setValue("placeholder", forKey: "coverType")

        do {
            try context.save()
        } catch {
            throw ROMImportError.saveFailed
        }

        Analytics.signal("rom_import", ["result": "success", "system": info.systemType.rawValue, "method": method])
        // One-time "ever activated" signal: unique users on import_first / all
        // users = % who have ever added a game (the rest never have). Fires once
        // per device, immune to the time-window caveat of per-import counts.
        if !UserDefaults.standard.bool(forKey: "didImportROM") {
            UserDefaults.standard.set(true, forKey: "didImportROM")
            Analytics.signal("import_first")
        }
        return game.objectID
    }

    /// Clean up ROM header titles and filenames into readable game names.
    /// "POKEMON FIRE" → "Pokemon Fire"
    /// "Pokemon - FireRed Version (USA, Europe) (Rev 1)" → "Pokemon - FireRed Version"
    static func cleanGameTitle(_ raw: String) -> String {
        var name = raw

        // Strip parenthetical region/version info: (USA), (Rev 1), (GBC,SGB Enhanced), etc.
        name = name.replacingOccurrences(
            of: "\\s*\\([^)]*\\)",
            with: "",
            options: .regularExpression
        )

        // Strip bracket info: [!], [S], etc.
        name = name.replacingOccurrences(
            of: "\\s*\\[[^]]*\\]",
            with: "",
            options: .regularExpression
        )

        name = name.trimmingCharacters(in: .whitespaces)

        // Title-case if all uppercase (ROM header names like "POKEMON FIRE")
        if name == name.uppercased() && name.count > 1 {
            name = name.capitalized
        }

        return name.isEmpty ? "Unknown Game" : name
    }
}
