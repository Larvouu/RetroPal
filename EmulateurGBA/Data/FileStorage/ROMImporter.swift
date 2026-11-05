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
import os

/// Outcome of `findOrImport(at:method:)`. Lets the caller distinguish a freshly
/// copied ROM from one that was already in the library — used by the
/// Files → "Open in Retro Pal" URL handler so duplicate opens navigate
/// to the existing game instead of erroring out.
enum ROMImportResult {
    case imported(NSManagedObjectID)
    case existed(NSManagedObjectID)
}

/// Carry the archive reader's REASON out to the person instead of flattening
/// every failure into "couldn't be opened". A valid archive we cannot read is a
/// different sentence from a broken one, and the 2026-09-02 Japanese 1-star
/// review is what made that distinction worth the code.
///
/// A zip keeps its own sentences; every other archive (7z, rar, tar, gz, xz,
/// since 1.3.5) has its own, because the zip's advice is to extract it in the
/// Files app, which opens a zip and nothing else.
/// Internal, not private, so a test can call it (`ErrorTelemetryTests`).
func importError(for error: Error, archive: URL) -> ROMImportError {
    let zip = archive.pathExtension.lowercased() == "zip"
    switch error {
    case ZIPExtractorError.unsupportedCompression:
        return zip ? .zipUnsupportedCompression : .archiveUnsupportedCompression
    case ZIPExtractorError.encryptedArchive: return zip ? .zipEncrypted : .archiveEncrypted
    // A full phone while the game was being written out (since 1.3.5 a 3DS
    // game streams gigabytes to the file): "free up storage", the copy's own
    // sentence, and not "this ZIP couldn't be opened, extract it in Files",
    // which needs the same space again (audit, 2026-10-29).
    case _ where ErrorTelemetry.copyCause(of: error) == .diskFull: return .copyFailed
    default: return zip ? .zipExtractionFailed : .archiveExtractionFailed
    }
}

/// No game in the archive, in the zip's words or the other archives'.
private func noGameError(archive: URL) -> ROMImportError {
    archive.pathExtension.lowercased() == "zip" ? .zipNoGBA : .archiveNoGame
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
    /// The same four for every archive that is not a zip (.7z, .rar, .tar,
    /// .gz, .xz; 1.3.5). Their own sentences: the zip's tell the player to
    /// extract it in the Files app, which cannot open these.
    case archiveNoGame
    case archiveExtractionFailed
    case archiveUnsupportedCompression
    case archiveEncrypted
    /// One volume of an archive split in several (`.part1.rar`, `.r00`,
    /// `.7z.001`, 2026-10-30): a game inside runs on into the next volume,
    /// which the reader is never given, so it read as damaged.
    case archiveSplit
    /// The player was asked which console a disc image belongs to (its bytes
    /// could not say) and chose Cancel. Not a failure: nothing is imported and
    /// nothing is said, as when a zip's picker is cancelled.
    case consoleChoiceCancelled
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
    /// A Nintendo 3DS game that is ENCRYPTED (its own header says so,
    /// `CTRGameProbe`). Separate from `invalidROM` because the file IS a game
    /// and the fix is specific: Azahar reads decrypted games only, and Retro
    /// Pal ships no console keys (decided 2026-10-16), so the player needs a
    /// decrypted copy. Telemetry: `reason = ctr_encrypted` (since 2026-10-27).
    case ctrEncrypted

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
        case .archiveNoGame: return NSLocalizedString("import.error.archiveNoGame", comment: "")
        case .archiveExtractionFailed: return NSLocalizedString("import.error.archiveExtractionFailed", comment: "")
        case .archiveUnsupportedCompression:
            return NSLocalizedString("import.error.archiveUnsupportedCompression", comment: "")
        case .archiveEncrypted: return NSLocalizedString("import.error.archiveEncrypted", comment: "")
        case .archiveSplit: return NSLocalizedString("import.error.archiveSplit", comment: "")
        case .consoleChoiceCancelled: return nil   // never shown; the player cancelled
        case .alreadyImported: return NSLocalizedString("import.error.alreadyImported", comment: "")
        case .saveFailed: return NSLocalizedString("import.error.saveFailed", comment: "")
        case .differentGame: return NSLocalizedString("import.error.differentGame", comment: "")
        case .discMissingFiles(let names):
            return String(format: NSLocalizedString("import.error.discMissingFiles", comment: ""),
                          names.joined(separator: ", "))
        case .ctrEncrypted: return NSLocalizedString("import.error.ctrEncrypted", comment: "")
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
        case .archiveNoGame: return "archiveNoGame"
        case .archiveExtractionFailed: return "archiveExtractionFailed"
        case .archiveUnsupportedCompression: return "archiveUnsupportedCompression"
        case .archiveEncrypted: return "archiveEncrypted"
        case .archiveSplit: return "archiveSplit"
        case .consoleChoiceCancelled: return "consoleChoiceCancelled"   // never signaled
        case .alreadyImported: return "alreadyImported"
        case .saveFailed: return "saveFailed"
        case .differentGame: return "differentGame"
        case .discMissingFiles: return "discMissingFiles"
        case .ctrEncrypted: return "ctrEncrypted"
        }
    }
}

/// One failed entry of a multi-ROM zip selection import, for the summary
/// alert (displayName + reason) and the error signals (analyticsID).
struct ZipEntryFailure {
    let displayName: String
    let reason: String
    let analyticsID: String
    /// The closed-set category for the `rom_import` error signal.
    var telemetryReason: ImportFailureReason = .unknownError
}

final class ROMImporter {
    private let context: NSManagedObjectContext
    private let romsDir: URL

    /// Why the last failure happened, finer than the `ROMImportError` it threw
    /// (telemetry only, `ErrorTelemetry.importReason`). Set where the cause is
    /// known, taken by the caller that signals the failure. An importer runs
    /// one import at a time on one queue, so a plain property is enough.
    private var failureCause: ImportFailureReason?

    /// Take (and clear) the cause the last failure recorded.
    func takeFailureCause() -> ImportFailureReason? {
        defer { failureCause = nil }
        return failureCause
    }

    /// Asks the player which console a disc image belongs to, when its bytes
    /// cannot say (`ROMSystemType.consoleIsUndecided`): an `.iso` or a `.chd`
    /// whose volume names neither the PlayStation nor the PSP. Called on the
    /// import's own queue, and blocks it until the player answers: `.ps1`,
    /// `.psp`, or nil for Cancel. Unset (the tests, a path with no screen), an
    /// undecided image imports as the PlayStation's, as every one did before
    /// 2026-10-12.
    ///
    /// WHY ASK AT ALL, when the bytes decide every ordinary case: a PlayStation
    /// disc names itself "PLAYSTATION" and a PSP game carries PSP_GAME, so a
    /// file that does neither is one the app would otherwise file by guess,
    /// and a wrong guess is a game that cannot start on the core it was given
    /// (2026-10-12: ask, "so we know for sure").
    var askConsole: ((_ fileName: String) -> ROMSystemType?)?

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
        do {
            return try findOrImportBody(at: sourceURL, method: method)
        } catch {
            // A refused file is not ours to keep: the copy iOS dropped in our
            // Inbox to deliver it (AirDrop, the share sheet) was left there on
            // every refusal (audit 2026-10-11). A zip awaiting a choice works
            // from its own temporary copy, so it is safe to drop too; a file
            // opened in place is never touched (`discardInboxCopy`).
            Self.discardInboxCopy(sourceURL)
            throw error
        }
    }

    private func findOrImportBody(at sourceURL: URL, method: String) throws -> ROMImportResult {
        // Conditional security-scoped access: required for URLs from the
        // document picker (cross-sandbox), no-op-returning-false for URLs
        // delivered via .onOpenURL / share sheet / AirDrop (iOS has already
        // copied the file into our Documents/Inbox before delivery, so it's
        // directly readable). Calling start unconditionally and only
        // balancing stop when start succeeded handles both paths correctly.
        let didStartScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { sourceURL.stopAccessingSecurityScopedResource() } }

        // For an archive (zip, 7z, rar, tar, gz, xz: `GameArchive`) we have to
        // extract before we can hash the inner ROM, so fall straight through to
        // the normal import path (it surfaces .alreadyImported as a regular
        // throw; the caller can re-fetch by hash if it wants the existing
        // entity, but in practice the URL handler ignores .zip via the
        // no-zip-claim decision).
        let ext = sourceURL.pathExtension.lowercased()
        if GameArchive.isArchive(sourceURL) {
            let id = try importROM(from: sourceURL, method: method)
            return .imported(id)
        }

        // An encrypted 3DS game is said to be, by name, as `importROM` says
        // it: the check below refuses it first, and from Files or AirDrop the
        // player was told only that the file is not a game (audit, 2026-10-20).
        if ROMSystemType.from(fileExtension: ext)?.isCTR == true,
           CTRGameProbeRead(sourceURL.path) == CTRGameProbeEncrypted {
            throw ROMImportError.ctrEncrypted
        }

        // Cheap probe: read the file once, hash it, look the hash up in
        // Core Data. Avoids the redundant copy + parse for duplicates.
        guard GBAROMParser.isValidROMFile(url: sourceURL) else {
            failureCause = ErrorTelemetry.invalidFileCause(sourceURL)
            throw ROMImportError.invalidROM
        }
        // A Mega Drive `.bin` hashes as the cartridge it is (whole), not as a
        // disc (a prefix), so the same game named `.md` is found.
        let hint: ROMSystemType? = GBAROMParser.isMegaDriveBin(url: sourceURL)
            ? .md : ROMSystemType.resolve(url: sourceURL)
        guard let probeData = try? Data(contentsOf: sourceURL, options: .mappedIfSafe),
              let info = GBAROMParser.parse(
                data: probeData,
                fileSize: Int64(probeData.count),
                systemHint: hint) else {
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

        // Every archive format takes the zip's path (`GameArchive` chooses the reader).
        if GameArchive.isArchive(sourceURL) {
            return try importZIP(from: sourceURL)
        }

        // A disc never takes the flat cartridge path below, even when it is a
        // single file: it needs its own folder, because that folder is what
        // names its saves and what a second disc of the same game would
        // otherwise collide with. Routed through the grouper rather than
        // constructed here, so one `.cue` opened from Files gets exactly the
        // same answer as one `.cue` picked in a batch — including the message
        // naming the tracks it cannot reach.
        //
        // Except a Mega Drive `.bin`, which is a cartridge (`isMegaDriveBin`)
        // and takes the cartridge path below, stored under its name as `.md`.
        let megaDriveBin = ext == "bin" && GBAROMParser.isMegaDriveBin(url: sourceURL)
        if ROMSystemType.importsAsDisc.contains(ext) && !megaDriveBin {
            let (_, discs, gaps) = DiscImportGrouper.group([sourceURL])
            if let gap = gaps.first { throw ROMImportError.discMissingFiles(names: gap.missing) }
            guard let group = discs.first else { throw ROMImportError.invalidROM }
            return try importDiscGroup(group, method: method)
        }

        // A 3DS game that is encrypted is said to be, by name: it is a game,
        // but not one the core can read (see `ctrEncrypted`).
        if ROMSystemType.from(fileExtension: ext)?.isCTR == true,
           CTRGameProbeRead(sourceURL.path) == CTRGameProbeEncrypted {
            throw ROMImportError.ctrEncrypted
        }

        // Validate ROM header (GBA, GB, or GBC)
        guard GBAROMParser.isValidROMFile(url: sourceURL) else {
            failureCause = ErrorTelemetry.invalidFileCause(sourceURL)
            throw ROMImportError.invalidROM
        }

        // Hash-first duplicate guard: if this ROM is already in the library, do
        // NOT copy — and never touch the existing on-disk file. Copying to the
        // (identical) destination and then deleting it on the duplicate check
        // below was the cause of a game losing its ROM file after a repeat
        // import, which then failed to launch as "file damaged".
        if let info = GBAROMParser.parse(fileURL: sourceURL, systemHint: megaDriveBin ? .md : nil) {
            let dupCheck = NSFetchRequest<NSManagedObject>(entityName: "GameEntity")
            dupCheck.predicate = NSPredicate(format: "romHash == %@", info.sha256)
            dupCheck.fetchLimit = 1
            if !(((try? context.fetch(dupCheck)) ?? []).isEmpty) {
                cleanupInboxFile(sourceURL)
                throw ROMImportError.alreadyImported
            }
        }

        // Copy to sandbox, under a name no file in ROMs/ has. The content
        // check above has already turned away this same game, so a file of
        // that name here is ANOTHER game's live ROM (a second dump or revision
        // named alike, "Tetris.gb"), and it used to be deleted and replaced:
        // both library entries then shared one file, the first launched the
        // second, and deleting either took the file from both (found
        // 2026-10-07). The new game gets "Tetris 2.gb", and its saves, save
        // states and cover follow that name; nothing already there moves.
        let filename = GBAROMParser.storedCartridgeName(for: sourceURL)
        let destURL = Self.uniqueDestination(for: romsDir.appendingPathComponent(filename))
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            failureCause = ErrorTelemetry.copyCause(of: error)
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
        //
        // Which console: the BOOT file's, read from its bytes when its
        // extension is shared (`ROMSystemType.resolve`). A PSP game is one
        // image, so it is its own boot; a PlayStation `.cue` or `.m3u` is never
        // a PSP game, and a lone PlayStation `.iso` reads as one. Asked of the
        // boot rather than the identity file because a playlist's identity
        // file is its largest track, which is a `.bin`.
        //
        // When the bytes cannot say (`consoleIsUndecided`), the player is
        // asked, and the answer is recorded in the game's folder below, where
        // every later reader of the file finds it (`PSPDiscProbeIsPSPGame`):
        // the core, the pad and the achievements then agree with the library.
        // Asked before the duplicate check and the copy, so a cancel costs
        // nothing.
        //
        // First, a disc that is POSITIVELY another console's is refused: a
        // PlayStation 2, Sega CD or Saturn disc (`isOtherConsolesDisc`), in
        // any container, a `.cue` or a `.chd` included. Those used to import
        // as PlayStation games and fail only when played (audit 2026-10-12),
        // and none of them should be asked about either. A PSP UMD answers
        // yes there too, so a PSP image's bytes are read first and the PSP
        // keeps it.
        if ROMSystemType.resolve(url: group.boot) != .psp,
           RAClient.isOtherConsolesDisc(atPath: group.boot.path) {
            // What it is, for the report: a PS3 disc and a UMD film are not
            // demand for a console the way a PS2 or Saturn disc is.
            switch PSPDiscProbeReadVolume(group.boot.path) {
            case PSPDiscProbeVolumePS3: failureCause = .ps3Disc
            case PSPDiscProbeVolumeUMDMedia: failureCause = .umdMedia
            default: failureCause = .otherConsoleDisc
            }
            throw ROMImportError.invalidROM
        }
        let system: ROMSystemType
        var askedSystem: ROMSystemType?
        if ROMSystemType.consoleIsUndecided(url: group.boot), let askConsole {
            // How often the bytes leave the console undecided, and what the
            // player answers (2026-10-13): `result` psp | ps1 | cancelled, and
            // the import's `method`. Nothing else, no file name.
            let chosen = askConsole(group.boot.lastPathComponent)
            Analytics.signal("disc_console_asked", ["result": chosen?.rawValue ?? "cancelled", "method": method])
            guard let chosen else {
                group.members.forEach { cleanupInboxFile($0) }
                throw ROMImportError.consoleChoiceCancelled
            }
            system = chosen == .psp ? .psp : .ps1
            askedSystem = system
        } else {
            system = ROMSystemType.resolve(url: group.boot) == .psp ? .psp : .ps1
        }

        // A game made of images alone (no descriptor names its files) boots
        // from those images, so each must be one (`isBootableDiscImage`): a
        // `.bin` that is neither a Mega Drive cartridge nor a disc, a truncated
        // `.iso`, a `.cso` that is not one, used to become a library entry that
        // failed at boot. A descriptor's tracks are not checked: an audio track
        // has no filesystem, and the core reads them through the descriptor.
        if !group.members.contains(where: { Self.isDescriptor($0) || $0.pathExtension.lowercased() == "ccd" }) {
            for member in group.members
            where !ROMSystemType.discSidecarExtensions.contains(member.pathExtension.lowercased()) {
                guard GBAROMParser.isBootableDiscImage(url: member) else {
                    failureCause = .discNotBootable
                    throw ROMImportError.invalidROM
                }
                // A `.mdf` with subchannel data boots only through its `.mds`.
                if GBAROMParser.mdfNeedsItsDescriptor(url: member),
                   !group.members.contains(where: {
                       $0.pathExtension.lowercased() == "mds"
                           && $0.deletingPathExtension().lastPathComponent.lowercased()
                              == member.deletingPathExtension().lastPathComponent.lowercased()
                   }) {
                    failureCause = .discMissingFiles
                    throw ROMImportError.discMissingFiles(names: ["\(member.deletingPathExtension().lastPathComponent).mds"])
                }
            }
        }

        // The discs of a PSP game that has more than one UMD stay separate
        // games. The grouper merges discs named "(Disc 1)", "(Disc 2)" into one
        // game booted through a written `.m3u` (`playlistDiscs`), which is the
        // PlayStation's way and not the PSP's: PPSSPP reads no playlist, and an
        // entry pointing at one launched on the PlayStation's core (a `.m3u` is
        // a PlayStation extension). The grouper works on NAMES and cannot know
        // a `.iso` is a PSP game, so the decision is made here, where the boot
        // file has been read. Each disc imports as the game it is, as every
        // disc did before the grouper merged them.
        if system == .psp, let discs = group.playlistDiscs, discs.count > 1 {
            // Every disc is attempted. A disc that fails is reported (its error
            // is thrown once the others are in), a disc already in the library
            // is not a failure, and only when every disc was already there is
            // the answer "already imported".
            var imported: NSManagedObjectID?
            var failure: Error?
            // The answer the player gave for this game holds for each of its
            // discs: asked once, not once per disc.
            let asked = askConsole
            if askedSystem != nil { askConsole = { _ in askedSystem } }
            defer { askConsole = asked }
            for member in group.members
            where !ROMSystemType.discSidecarExtensions.contains(member.pathExtension.lowercased()) {
                do {
                    let id = try importDiscGroup(DiscImportGroup(boot: member, members: [member]),
                                                 method: method, movingMembers: movingMembers)
                    if imported == nil { imported = id }
                } catch ROMImportError.alreadyImported {
                    continue
                } catch {
                    if failure == nil { failure = error }
                }
            }
            if let failure { throw failure }
            if let imported { return imported }
            throw ROMImportError.alreadyImported
        }

        guard let info = GBAROMParser.parse(fileURL: group.identityFile, systemHint: system) else {
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
            // Marks the folder as an import in progress until its library entry
            // is saved (`sweepAbandonedImports`). Not a disc file, so no size
            // ever counts it (`DiscStorage.installedSize`).
            try Data().write(to: folder.appendingPathComponent(Self.importInProgressFileName))
        } catch {
            failureCause = ErrorTelemetry.copyCause(of: error)
            try? FileManager.default.removeItem(at: folder)
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
                // A short copy has already said `copy_truncated` itself.
                if let cause = ErrorTelemetry.copyCause(of: error) { failureCause = cause }
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
                    // The reading the grouper chose, under which its files are
                    // found (`decodeDescriptor`), not the zip names' chain alone.
                    let text = DiscImportGrouper.decodeDescriptor(
                        bytes, ext: dest.pathExtension,
                        among: group.members.map(\.lastPathComponent)) ?? LegacyTextEncoding.decodeLegacy(bytes)
                    try text.write(to: dest, atomically: true, encoding: .utf8)
                } catch {
                    failureCause = ErrorTelemetry.copyCause(of: error)
                    abandon()
                    throw ROMImportError.copyFailed
                }
            }
            if member.path == group.boot.path { bootDestination = dest }
        }

        // Every descriptor names its files exactly as they now are on disk, in
        // UTF-8 without a byte-order mark. The core opens each reference by its
        // bytes on a case-sensitive volume and skips one it cannot open without
        // a word, so a `.cue` saying `GAME.BIN` beside `Game.bin`, a Windows
        // path, or a UTF-8 file starting with a BOM (which hides its first
        // `FILE` keyword from the core) imported fine and booted to nothing
        // (audit 2026-10-27). Written only when something has to change.
        var storedNames = group.members.map(\.lastPathComponent)
        // A track named a `.cue` cannot hold for the core (`coreCueNameMaxBytes`,
        // about 80 Japanese characters) is renamed shorter, and its descriptor
        // pointed at the new name below: it was cut on the cue's line and the
        // game booted to nothing (audit, 2026-10-29). Only a file a `.cue`
        // names; the boot file keeps its name, which is the game's.
        var renamed: [String: String] = [:]
        if group.members.contains(where: { $0.pathExtension.lowercased() == "cue" }) {
            var taken = Set(storedNames.map { $0.lowercased() })
            for (i, name) in storedNames.enumerated() where name != group.boot.lastPathComponent {
                guard !Self.isDescriptor(URL(fileURLWithPath: name)),
                      let short = DiscImportGrouper.coreFittingName(name, taken: taken) else { continue }
                do {
                    try FileManager.default.moveItem(at: folder.appendingPathComponent(name),
                                                     to: folder.appendingPathComponent(short))
                } catch {
                    failureCause = ErrorTelemetry.copyCause(of: error)
                    abandon()
                    throw ROMImportError.copyFailed
                }
                renamed[name] = short
                storedNames[i] = short
                taken.insert(short.lowercased())
            }
        }
        for member in group.members {
            let dest = folder.appendingPathComponent(member.lastPathComponent)
            guard Self.isDescriptor(dest), let bytes = try? Data(contentsOf: dest) else { continue }
            let hasBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
            var text = LegacyTextEncoding.decode(bytes)
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            let pointed = DiscImportGrouper.descriptorPointingAt(storedNames: storedNames, text: text,
                                                                 ext: dest.pathExtension, renamed: renamed)
            guard pointed != nil || hasBOM else { continue }
            do {
                try Data((pointed ?? text).utf8).write(to: dest, options: .atomic)
            } catch {
                failureCause = ErrorTelemetry.copyCause(of: error)
                abandon()
                throw ROMImportError.copyFailed
            }
        }
        guard var boot = bootDestination else {
            abandon()
            throw ROMImportError.copyFailed
        }

        // The player's answer, beside the image it is about. A dot file, so
        // the Files app does not list it; inside the game's folder, so it goes
        // when the game is deleted. Counted in the folder's size, which the
        // launch preflight compares, because it is measured after this.
        if let askedSystem {
            do {
                try Data(askedSystem.rawValue.utf8).write(
                    to: folder.appendingPathComponent(ROMSystemType.consoleChoiceFileName),
                    options: .atomic)
            } catch {
                failureCause = ErrorTelemetry.copyCause(of: error)
                abandon()
                throw ROMImportError.copyFailed
            }
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
                failureCause = ErrorTelemetry.copyCause(of: error)
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
            let installed = DiscStorage.installedSize(ofROMAt: boot, system: system) ?? info.fileSize
            let id = try createDiscEntry(boot: boot,
                                         relativePath: "\(folderName)/\(boot.lastPathComponent)",
                                         system: system,
                                         info: info,
                                         installedSize: installed,
                                         method: method)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(Self.importInProgressFileName))
            group.members.forEach { cleanupInboxFile($0) }
            return id
        } catch {
            abandon()
            throw error
        }
    }

    private static let log = Logger(subsystem: "com.retropal", category: "import")

    /// The file that marks a disc game's folder while its import is running.
    static let importInProgressFileName = ".retropal-importing"

    /// How old a marker must be before its folder counts as abandoned.
    static let abandonedAfter: TimeInterval = 10 * 60

    /// Removes the folders of disc imports that never finished: the app was
    /// killed or suspended in the middle of a copy (a PSP game is 1 to 2 GB),
    /// and the half-copied folder stayed in `ROMs/`, out of sight in the app,
    /// with no library entry, and its name then made the re-import "Game 2"
    /// (audit 2026-10-27). A folder is removed only when it still carries the
    /// marker this importer writes (`importInProgressFileName`) AND no game in
    /// the library points into it: `ROMs/` is visible in the Files app, so a
    /// folder a player put there themselves, which has no marker, is never
    /// touched. Folders abandoned before the marker existed are left alone for
    /// the same reason. Run once at launch, off the main thread. An import
    /// that started in this launch (a game opened from Files as the app came
    /// up) has a marker written moments ago and an entry not saved yet: only a
    /// marker older than `abandonedAfter` counts, so it is never mistaken for
    /// an abandoned one.
    static func sweepAbandonedImports(context: NSManagedObjectContext, now: Date = Date()) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let roms = docs.appendingPathComponent(DiscStorage.romsFolderName, isDirectory: true)
        guard !markedFolders(in: roms, now: now).isEmpty else { return }
        context.performAndWait {
            let request = NSFetchRequest<NSDictionary>(entityName: "GameEntity")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["romFilePath"]
            // A library that cannot be read says nothing about which folders are
            // games: nothing is removed then, rather than everything marked.
            guard let rows = try? context.fetch(request) else {
                ROMImporter.log.error("unfinished imports not swept: the library could not be read")
                return
            }
            let paths = rows.compactMap { $0["romFilePath"] as? String }
            for folder in abandonedFolders(in: roms, romFilePaths: paths, now: now) {
                do {
                    try fm.removeItem(at: folder)
                    ROMImporter.log.info("removed an import that never finished: \(folder.lastPathComponent, privacy: .public)")
                } catch {
                    ROMImporter.log.error("could not remove an unfinished import: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// The folders of `roms` whose import marker is older than `abandonedAfter`.
    static func markedFolders(in roms: URL, now: Date) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: roms, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false,
                  let written = (try? fm.attributesOfItem(
                      atPath: folder.appendingPathComponent(importInProgressFileName).path))?[.modificationDate] as? Date
            else { return false }
            return now.timeIntervalSince(written) > abandonedAfter
        }
    }

    /// The marked folders no library entry points into (`romFilePath` is
    /// `<folder>/<boot>` for a disc game, a bare name for a cartridge).
    static func abandonedFolders(in roms: URL, romFilePaths: [String], now: Date) -> [URL] {
        let used = Set(romFilePaths.compactMap { path -> String? in
            let parts = path.split(separator: "/", maxSplits: 1)
            return parts.count == 2 ? String(parts[0]) : nil
        })
        return markedFolders(in: roms, now: now).filter { !used.contains($0.lastPathComponent) }
    }

    /// The text descriptors a disc game can carry.
    private static func isDescriptor(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "cue" || ext == "m3u" || ext == "toc"
    }

    /// A directory name no existing game is using as its key. Sanitised because it becomes
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
        // Taken by another disc's folder OR by a cartridge of that name: both
        // would file their saves under the same key (`isKeyTaken`).
        while Self.isKeyTaken(candidate, in: romsDir) {
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
        if GameArchive.isArchive(sourceURL) {
            // Its own folder under the import scratch (`GameArchive.stagedCopyURL`).
            let tempZip: URL
            do { tempZip = try GameArchive.stagedCopyURL(for: sourceURL) } catch {
                failureCause = ErrorTelemetry.copyCause(of: error)
                throw ROMImportError.copyFailed
            }
            cleanup.append(tempZip.deletingLastPathComponent())
            // The app's words on a full phone, not the system's (audit 2026-10-27).
            do { try FileManager.default.copyItem(at: sourceURL, to: tempZip) } catch {
                failureCause = ErrorTelemetry.copyCause(of: error)
                throw ROMImportError.copyFailed
            }

            let entryNames: [String]
            do {
                entryNames = try GameArchive.romEntryNames(in: tempZip)
            } catch {
                throw archiveError(error, archive: tempZip)
            }
            guard !entryNames.isEmpty else { throw noGameError(archive: tempZip) }

            // The target game is known here, so a multi-ROM zip needs no
            // picker: auto-select the entry whose hash matches the game
            // being repaired. No match at all = every entry is some other
            // game, the same situation .differentGame already describes.
            // Each entry that is not the game is removed before the next is
            // written, and a full phone is said as such: before, every entry
            // tried stayed in tmp until the end (the space needed was their
            // sum) and an extraction that failed for want of space was skipped,
            // so the repair ended on "a different game" (audit, 2026-10-30).
            var matched: URL?
            for name in entryNames {
                let extracted: URL
                do {
                    extracted = try GameArchive.extractROM(named: name, from: tempZip)
                } catch where ErrorTelemetry.copyCause(of: error) == .diskFull {
                    failureCause = .diskFull
                    throw ROMImportError.copyFailed
                } catch {
                    continue
                }
                let folder = extracted.deletingLastPathComponent()
                // A Mega Drive `.bin` hashes as the cartridge it is, as at
                // import; without the hint it hashed as a PlayStation disc and
                // never matched, so the repair said "a different game".
                let hint: ROMSystemType? = GBAROMParser.isMegaDriveBin(url: extracted) ? .md : nil
                if GBAROMParser.parse(fileURL: extracted, systemHint: hint)?.sha256 == storedHash {
                    cleanup.append(folder)
                    matched = extracted
                    break
                }
                try? FileManager.default.removeItem(at: folder)
            }
            guard let matched else { throw ROMImportError.differentGame }
            romFileURL = matched
        } else {
            romFileURL = sourceURL
        }

        guard GBAROMParser.isValidROMFile(url: romFileURL),
              let info = GBAROMParser.parse(fileURL: romFileURL,
                                            systemHint: GBAROMParser.isMegaDriveBin(url: romFileURL) ? .md : nil) else {
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
        do { try FileManager.default.copyItem(at: romFileURL, to: tmp) } catch {
            failureCause = ErrorTelemetry.copyCause(of: error)
            try? FileManager.default.removeItem(at: tmp)
            throw ROMImportError.copyFailed
        }
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
        Self.discardInboxCopy(url)
    }

    /// Removes a file iOS copied into our Documents/Inbox to deliver it (share
    /// sheet, AirDrop), once its contents are ours. Anything outside Inbox,
    /// a file opened in place in Files above all, is never touched.
    static func discardInboxCopy(_ url: URL) {
        let inboxPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Inbox").path
        if url.path.hasPrefix(inboxPath) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - ZIP Import

    /// `importError`, with a full phone also recorded as the telemetry cause:
    /// without it the alert said "free up storage" and TelemetryDeck counted
    /// `copy_failed` (audit, 2026-10-30).
    private func archiveError(_ error: Error, archive: URL) -> ROMImportError {
        if ErrorTelemetry.copyCause(of: error) == .diskFull { failureCause = .diskFull }
        return importError(for: error, archive: archive)
    }

    private func importZIP(from sourceURL: URL) throws -> NSManagedObjectID {
        // WHERE THE ARCHIVE IS READ FROM. A copy in its own scratch folder
        // (`GameArchive.stagedCopyURL`: never shared with another archive of
        // the same name, and swept at launch if the app is killed meanwhile),
        // except where that copy is needless weight (audit, 2026-10-30: an
        // archive needed twice its size free before a byte was extracted, three
        // times from AirDrop):
        //   - a file iOS delivered into our Inbox (AirDrop, Share, Open in) is
        //     ours already: MOVED into the scratch folder, a rename;
        //   - a .7z, .rar or tar on this device's own storage, picked in Files,
        //     is read where it is: libarchive streams it, and the security
        //     scope `importROM` holds lasts the whole import;
        //   - a .zip keeps its copy: its reader maps the file, and a mapped
        //     file someone else can change or delete meanwhile can crash the
        //     app; so does anything on an external drive or a server.
        // The selection sheet needs the archive after this returns, when the
        // scope is gone: one read in place is copied then, for that case only.
        // One volume of a split archive: said as such, before any copy.
        if GameArchive.isSplitVolume(sourceURL) { throw ROMImportError.archiveSplit }
        let fm = FileManager.default
        let inInbox = Self.isInboxCopy(sourceURL)
        let readsInPlace = !inInbox && !GameArchive.isMappedWhenRead(sourceURL)
            && Self.isOnLocalStorage(sourceURL)
        var tempZip = sourceURL
        var staged = false
        /// Removes the archive's scratch copy; never the player's own file.
        func releaseArchive() { if staged { GameArchive.discardStagedCopy(tempZip) } }
        func stage() throws {
            let copy: URL
            do { copy = try GameArchive.stagedCopyURL(for: sourceURL) } catch {
                failureCause = ErrorTelemetry.copyCause(of: error)
                throw ROMImportError.copyFailed
            }
            do {
                if inInbox { try fm.moveItem(at: sourceURL, to: copy) } else { try fm.copyItem(at: sourceURL, to: copy) }
            } catch {
                // A full phone, the commonest reason with a 1-2 GB archive: said in
                // the app's words ("free up storage"), not the system's raw error in
                // English (audit 2026-10-27), as every other copy here already is.
                failureCause = ErrorTelemetry.copyCause(of: error)
                GameArchive.discardStagedCopy(copy)
                throw ROMImportError.copyFailed
            }
            tempZip = copy
            staged = true
        }
        if !readsInPlace { try stage() }

        // GAMES, not files. An archive holding one PlayStation disc holds it in
        // as many pieces as the disc had tracks: Tomb Raider is a `.cue` and
        // fifty-seven `.bin`, and listing those as fifty-eight choices is what
        // this used to do. Only the descriptors are decompressed to work it out,
        // so this costs a few hundred bytes whatever the archive weighs.
        let games: (discs: [DiscNameGroup], cartridges: [String], gaps: [DiscNameGap])
        do {
            games = try GameArchive.gameEntries(in: tempZip)
        } catch {
            releaseArchive()
            throw archiveError(error, archive: tempZip)
        }

        if let gap = games.gaps.first, games.discs.isEmpty, games.cartridges.isEmpty {
            releaseArchive()
            throw ROMImportError.discMissingFiles(names: gap.missing)
        }

        let total = games.discs.count + games.cartridges.count
        guard total > 0 else {
            releaseArchive()
            throw noGameError(archive: tempZip)
        }

        // Several GAMES: hand the temp copy to the caller so the user can pick
        // which to add. The temp copy deliberately survives this throw;
        // importZIPSelection / discardZIPSelection deletes it. What the picker
        // is given is one name per game, the boot file for a disc, so choosing
        // "Tomb Raider" quietly brings its fifty-eight files with it.
        guard total == 1 else {
            if !staged { try stage() }
            cleanupInboxFile(sourceURL)
            let names = games.discs.map(\.boot) + games.cartridges
            throw ROMImportError.zipNeedsSelection(tempZipURL: tempZip, entryNames: names)
        }

        defer { releaseArchive() }
        let id: NSManagedObjectID
        if let disc = games.discs.first {
            id = try importDiscGroup(disc, fromZip: tempZip, method: "picker")
        } else {
            id = try importEntry(named: games.cartridges[0], fromZip: tempZip)
        }
        cleanupInboxFile(sourceURL)
        return id
    }

    /// Whether iOS delivered this file into our own Inbox (AirDrop, Share, Open in).
    static func isInboxCopy(_ url: URL) -> Bool {
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Inbox").standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(inbox + "/")
    }

    /// Whether the file is on the same volume as the app's own temporary
    /// folder: this device's storage, not an external drive or a server, whose
    /// reads can stall or fail mid-way.
    static func isOnLocalStorage(_ url: URL) -> Bool {
        let key: URLResourceKey = .volumeIdentifierKey
        guard let here = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [key]).volumeIdentifier,
              let there = try? url.resourceValues(forKeys: [key]).volumeIdentifier else { return false }
        return here.isEqual(there)
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
            extracted = try GameArchive.extractEntries(named: group.members, from: tempZip)
        } catch {
            throw archiveError(error, archive: tempZip)
        }
        let staging = extracted.first?.deletingLastPathComponent()
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }

        let bootName = URL(fileURLWithPath: group.boot).lastPathComponent
        guard let boot = extracted.first(where: { $0.lastPathComponent == bootName }) else {
            throw importError(for: ZIPExtractorError.extractionFailed, archive: tempZip)
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
        defer { GameArchive.discardStagedCopy(tempZip) }
        // Re-grouped rather than remembered: the sheet hands back the names it
        // was given, and a disc's boot file has to be expanded into its parts
        // again. Re-reading a few hundred bytes of descriptor is cheaper than
        // carrying a parallel structure through the picker and keeping the two
        // in step.
        let games = (try? GameArchive.gameEntries(in: tempZip))
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
                    _ = try importEntry(named: name, fromZip: tempZip)
                }
            } catch ROMImportError.consoleChoiceCancelled {
                // The player said Cancel to the console question.
                continue
            } catch let error as ROMImportError {
                let cause = takeFailureCause()
                if case .alreadyImported = error { duplicates.append(displayName); continue }
                failures.append(ZipEntryFailure(displayName: displayName,
                                                reason: error.errorDescription ?? "",
                                                analyticsID: error.analyticsID,
                                                telemetryReason: ErrorTelemetry.importReason(for: error, noted: cause)))
            } catch {
                failures.append(ZipEntryFailure(displayName: displayName,
                                                reason: error.localizedDescription,
                                                analyticsID: "unknown",
                                                telemetryReason: ErrorTelemetry.importReason(for: error, noted: takeFailureCause())))
            }
        }
        return (failures, duplicates)
    }

    /// Cancel path of the zip picker: drop the temp copy importZIP staged.
    static func discardZIPSelection(tempZipURL: URL) {
        GameArchive.discardStagedCopy(tempZipURL)
    }

    /// Extract one entry of the archive, validate it, copy it into ROMs/ and
    /// create its library entry. Shared by the single-ROM zip path and the
    /// multi-ROM selection import.
    ///
    /// Always under a free name in ROMs/ (`uniqueDestination`): a multi-ROM
    /// zip can hold same-named entries in different folders, and a single-ROM
    /// zip can hold a game named like one already in the library; overwriting
    /// would leave the earlier entry's library row pointing at another game's
    /// bytes. The single path overwrote until 2026-10-07.
    private func importEntry(named name: String, fromZip tempZip: URL) throws -> NSManagedObjectID {
        let extractedURL: URL
        do {
            extractedURL = try GameArchive.extractROM(named: name, from: tempZip)
        } catch {
            throw archiveError(error, archive: tempZip)
        }
        defer { try? FileManager.default.removeItem(at: extractedURL.deletingLastPathComponent()) }

        // An encrypted 3DS game out of an archive is said to be, as a loose one is.
        if ROMSystemType.from(fileExtension: extractedURL.pathExtension)?.isCTR == true,
           CTRGameProbeRead(extractedURL.path) == CTRGameProbeEncrypted {
            throw ROMImportError.ctrEncrypted
        }

        // Validate (GBA, GB, GBC, NDS)
        guard GBAROMParser.isValidROMFile(url: extractedURL) else {
            failureCause = ErrorTelemetry.invalidFileCause(extractedURL)
            throw ROMImportError.invalidROM
        }

        // Moved to ROMs/ (a Mega Drive `.bin` as `.md`, as when picked loose):
        // the extracted file is this import's own, in tmp, on the same volume,
        // so a move is a rename and no second copy of the game is written.
        // Copied, a 4 GB 3DS game needed its size three times over (the
        // archive, the extraction, the library copy; audit, 2026-10-29), as
        // the disc path already avoids (`movingMembers`). A rename moves no
        // bytes, so there is no size to verify.
        let filename = GBAROMParser.storedCartridgeName(for: extractedURL)
        let destURL = Self.uniqueDestination(for: romsDir.appendingPathComponent(filename))
        do { try FileManager.default.moveItem(at: extractedURL, to: destURL) } catch {
            failureCause = ErrorTelemetry.copyCause(of: error)
            try? FileManager.default.removeItem(at: destURL)
            throw ROMImportError.copyFailed
        }

        // The title from the game's own name, as for a loose file: " 2" is
        // only how it is STORED beside a game of the same name, and a console
        // whose header has no title (NES, Master System, Game Gear) showed it.
        return try createGameEntry(romURL: destURL, originalFilename: filename, method: "zip")
    }

    /// First free "name.ext", "name 2.ext", ... inside ROMs/. Never touches
    /// an existing file: it may be another game's live ROM.
    ///
    /// Free means free as a KEY, not only as a file name: a game's battery
    /// save, save states, auto-save, per-game settings and palette are all
    /// filed under its name WITHOUT the extension
    /// (`BatterySaveImporter.romBasename`), so "Tetris.gbc" beside a
    /// different game's "Tetris.gb", or beside a disc game's "Tetris" folder,
    /// would have shared that game's save. Since 2026-10-07 both are taken.
    static func uniqueDestination(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        guard isKeyTaken(base, in: dir) else { return url }
        for n in 2...999 {
            let candidate = "\(base) \(n)"
            if !isKeyTaken(candidate, in: dir) {
                return dir.appendingPathComponent(candidate).appendingPathExtension(ext)
            }
        }
        return dir.appendingPathComponent("\(base) \(UUID().uuidString)").appendingPathExtension(ext)
    }

    /// Whether `key` already names a game in `dir` (ROMs/): a cartridge file
    /// `key.<any extension>` or a disc game's folder `key`, the two shapes
    /// `BatterySaveImporter.romBasename` reads a key from. Compared without
    /// regard to case, so the answer does not depend on how the volume treats
    /// case; the price of that is at most a needless " 2".
    static func isKeyTaken(_ key: String, in dir: URL) -> Bool {
        let wanted = key.lowercased()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.contains { entry in
            let isFolder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let entryKey = isFolder ? entry.lastPathComponent
                                    : entry.deletingPathExtension().lastPathComponent
            return entryKey.lowercased() == wanted
        }
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
            failureCause = .copyTruncated
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
    /// The TITLE a PBP's PARAM.SFO carries, trimmed, or nil (see
    /// `PSPDiscProbeReadPBPTitle`). The field is 128 bytes on the PSP.
    static func pbpTitle(_ url: URL) -> String? {
        let capacity = 512
        var buffer = [CChar](repeating: 0, count: capacity)
        let found = url.withUnsafeFileSystemRepresentation { path in
            path.map { PSPDiscProbeReadPBPTitle($0, &buffer, capacity) } ?? false
        }
        guard found else { return nil }
        let title = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func createDiscEntry(boot: URL,
                                 relativePath: String,
                                 system: ROMSystemType,
                                 info: ROMInfo,
                                 installedSize: Int64,
                                 method: String) throws -> NSManagedObjectID {
        // A disc's header title is empty by design (see GBAROMParser), so the
        // name is the boot file's, cleaned exactly as a cartridge filename is.
        let rawTitle = boot.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
        var title = Self.cleanGameTitle(rawTitle)
        // Every PSP EBOOT is named `EBOOT.PBP`: two of them were two games called
        // "Eboot" (audit 2026-10-27). Its real name is the TITLE in its PARAM.SFO;
        // the file name stays the fallback for a PBP that carries none.
        if system == .psp, boot.pathExtension.lowercased() == "pbp",
           let sfoTitle = Self.pbpTitle(boot) {
            title = sfoTitle
        }
        // A disc that is a game of its own (each UMD of a PSP game, which
        // stays separate) keeps its number: the cleaning drops every
        // parenthesis, and two discs showed as two identical rows (audit
        // 2026-10-11). Written as the file names it, not localised: the title
        // is stored, and the rest of it is the file's own text too. The PSP
        // only: a PlayStation set is one game booted through its playlist.
        if system == .psp,
           let token = DiscImportGrouper.discToken(inStem: boot.deletingPathExtension().lastPathComponent) {
            title += " (Disc \(token.number))"
        }

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
        game.setValue(system.rawValue, forKey: "systemType")
        game.setValue("placeholder", forKey: "coverType")

        do {
            try context.save()
        } catch {
            throw ROMImportError.saveFailed
        }

        Analytics.signal("rom_import", ["result": "success", "system": system.rawValue, "method": method])
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
