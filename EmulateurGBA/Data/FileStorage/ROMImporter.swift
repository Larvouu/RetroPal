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

enum ROMImportError: LocalizedError {
    case fileAccessDenied
    case copyFailed
    case invalidROM
    case zipNoGBA
    case zipMultipleGBA
    case zipExtractionFailed
    case alreadyImported
    case saveFailed
    /// The file picked to replace a game's ROM is a different game (its hash
    /// doesn't match the one recorded at import), so the existing save states
    /// wouldn't be valid for it.
    case differentGame

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied: return NSLocalizedString("import.error.fileAccessDenied", comment: "")
        case .copyFailed: return NSLocalizedString("import.error.copyFailed", comment: "")
        case .invalidROM: return NSLocalizedString("import.error.invalidROM", comment: "")
        case .zipNoGBA: return NSLocalizedString("import.error.zipNoROM", comment: "")
        case .zipMultipleGBA: return NSLocalizedString("import.error.zipMultipleROMs", comment: "")
        case .zipExtractionFailed: return NSLocalizedString("import.error.zipExtractionFailed", comment: "")
        case .alreadyImported: return NSLocalizedString("import.error.alreadyImported", comment: "")
        case .saveFailed: return NSLocalizedString("import.error.saveFailed", comment: "")
        case .differentGame: return NSLocalizedString("import.error.differentGame", comment: "")
        }
    }

    /// Stable, anonymous identifier for analytics (no user content).
    var analyticsID: String {
        switch self {
        case .fileAccessDenied: return "fileAccessDenied"
        case .copyFailed: return "copyFailed"
        case .invalidROM: return "invalidROM"
        case .zipNoGBA: return "zipNoGBA"
        case .zipMultipleGBA: return "zipMultipleGBA"
        case .zipExtractionFailed: return "zipExtractionFailed"
        case .alreadyImported: return "alreadyImported"
        case .saveFailed: return "saveFailed"
        case .differentGame: return "differentGame"
        }
    }
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
            do {
                let extracted = try ZIPExtractor.extractROM(from: tempZip)
                cleanup.append(extracted.deletingLastPathComponent())
                romFileURL = extracted
            } catch {
                throw ROMImportError.zipExtractionFailed
            }
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
        defer { try? FileManager.default.removeItem(at: tempZip) }

        // Extract the single ROM file (.gba, .gb, or .gbc)
        let extractedURL: URL
        do {
            extractedURL = try ZIPExtractor.extractROM(from: tempZip)
        } catch let error as ZIPExtractorError {
            switch error {
            case .noROMFound: throw ROMImportError.zipNoGBA
            case .multipleROMsFound: throw ROMImportError.zipMultipleGBA
            default: throw ROMImportError.zipExtractionFailed
            }
        }
        defer { try? FileManager.default.removeItem(at: extractedURL.deletingLastPathComponent()) }

        // Validate (supports GBA, GB, GBC)
        guard GBAROMParser.isValidROMFile(url: extractedURL) else {
            throw ROMImportError.invalidROM
        }

        // Copy to ROMs directory
        let filename = extractedURL.lastPathComponent
        let destURL = romsDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.copyItem(at: extractedURL, to: destURL)
        try verifyCopyComplete(source: extractedURL, dest: destURL)

        return try createGameEntry(romURL: destURL, originalFilename: filename, method: "zip")
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
