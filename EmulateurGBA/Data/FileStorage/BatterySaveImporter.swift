//
//  BatterySaveImporter.swift
//  EmulateurGBA
//
//  Imports raw battery save RAM (.sav / .srm) exported from any other iOS
//  emulator into Retro Pal. Manic, Delta, OpenEmu and RetroArch all export
//  the same artefact: bare save RAM, no header, no container. There is
//  nothing to "parse." Classification is size + extension + (for the
//  marquee Gen 3 GBA case) section-signature based.
//
//  System routing
//  --------------
//  The file's extension declares the system family the export came from:
//    .sav → GBA / GB / GBC  (Manic exports GBA games as .sav)
//    .srm → NDS              (Manic exports DS games as .srm; RetroArch uses
//                             .srm for everything but we only register the
//                             extension as an NDS hint)
//
//  Once classified, the file is written to Documents/BatterySaves under the
//  target game's ROM basename + ".sav" — the SAME on-disk convention used
//  by EmulatorSession.loadROM for both bridges. melonDS reads from a path
//  ending in .sav just as mGBA does, so a single canonical filename per
//  ROM avoids a system-by-system fork in the loader.
//
//  Rejection cases
//  ---------------
//  - A file matching a known ROM header (Nintendo logo at 0x04 / 0xC0 /
//    0x104) is rejected. Covers the "user mistakenly shared a .gba ROM
//    under a .sav extension" edge case.
//  - A file whose size is not a known raw save-RAM size for the declared
//    system is rejected. Covers most "this is actually a save state, not
//    a battery save" cases — save states are typically tens of KB to a
//    few MB and rarely land on a known battery-save size.
//  - A 128 KB GBA file that does NOT carry a Gen 3 section signature at
//    any of the 28 expected footer offsets is rejected. Catches "random
//    128 KB file that happens to be the right size."
//

import Foundation

/// Battery-save source system, declared by the file extension. Determines
/// which library games are valid import targets and which save sizes are
/// accepted.
enum BatterySaveSystem {
    /// .sav file — accepts GBA, GB, GBC and NES targets.
    case savFamily
    /// .srm file — accepts NDS, SNES and PlayStation targets.
    case srmFamily
    /// .mcd file — a PlayStation memory card, and nothing else uses the name.
    case mcdFamily

    static func from(fileExtension ext: String) -> BatterySaveSystem? {
        switch ext.lowercased() {
        case "sav": return .savFamily
        case "srm": return .srmFamily
        case "mcd": return .mcdFamily
        default:    return nil
        }
    }

    /// `GameEntity.systemType` raw values that accept a save from this family.
    /// Matches the strings written by `ROMImporter.createGameEntry` via
    /// `ROMSystemType.rawValue`.
    ///
    /// The two new consoles join the families their own emulators use: MesenCE
    /// writes `.srm` for a SNES cart and `.sav` for a NES one, which is also
    /// what every other emulator exports, so a save arriving from elsewhere
    /// carries the extension this expects.
    var compatibleSystemTypes: Set<String> {
        switch self {
        case .savFamily: return ["gba", "gb", "gbc", "nes"]
        // The PlayStation joins the .srm family as well as owning .mcd, and
        // that is not a guess: in the frontend-managed card mode we ask for,
        // libretro frontends write the card out as `.srm`. So the two names a
        // player is likely to already have both land on the right game, which
        // matters more than tidiness on a console whose save model is new here.
        case .srmFamily: return ["nds", "snes", "ps1"]
        case .mcdFamily: return ["ps1"]
        }
    }

    /// All raw save-RAM sizes a file of this family can legitimately have.
    /// Unknown sizes are rejected as `invalidFormat` to filter out save
    /// states (which are typically tens of KB to a few MB and rarely land
    /// exactly on a known battery-save size).
    var knownSaveSizes: Set<Int> {
        switch self {
        case .savFamily:
            // GBA: 512 B EEPROM4K, 8 KB EEPROM64K, 32 KB SRAM, 64 KB Flash512,
            //      128 KB Flash1M (Gen 3 Pokémon).
            // GB / GBC: 2 KB, 8 KB, 32 KB, 128 KB (some MBC5 carts).
            // NES: 8 KB is the whole story for battery carts (Zelda, Final
            //      Fantasy, Dragon Warrior); a few boards wire 2 KB or 32 KB.
            return [512, 2048, 8192, 32768, 65536, 131072]
        case .srmFamily:
            // NDS: 512 B EEPROM, 8 KB, 64 KB, 256 KB, 512 KB (HG/SS, B/W),
            //      1 MB (Dragon Quest IX), 8 MB (the largest commercial saves).
            // SNES: 2 KB, 8 KB, 32 KB (the common one: Chrono Trigger, A Link
            //      to the Past), 64 KB, 128 KB (SA-1 and the big RPGs). Without
            //      these three additions every ordinary SNES save would have been
            //      rejected as "not a battery save" on import, which is why the
            //      size set is a property of the FAMILY and not of one console.
            return [512, 2048, 8192, 32768, 65536, 131072, 262144, 524288, 1048576, 8388608]
        case .mcdFamily:
            // A PlayStation memory card is exactly one size, 128 KB: fifteen
            // blocks of 8 KB plus the directory. Anything else under this name
            // is one of the wrapped formats (.gme, .vgs, .vmp) that carry a
            // header, and those are a different file even when renamed.
            return [131072]
        }
    }
}

enum BatterySaveImportError: LocalizedError, Equatable {
    /// File is not a recognizable raw battery save — wrong size, looks
    /// like a ROM, or missing the Gen 3 signature where one is required.
    case invalidFormat
    /// A save already exists for the target game; the caller must ask
    /// the user before passing `overwriting: true`.
    case duplicateExists
    /// Source URL couldn't be read (security scoping, missing file, etc.).
    case fileAccessDenied
    /// Destination write into Documents/BatterySaves failed.
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return NSLocalizedString("saveImport.error.invalidFormat", comment: "")
        case .duplicateExists:
            return NSLocalizedString("saveImport.error.duplicateExists", comment: "")
        case .fileAccessDenied:
            return NSLocalizedString("saveImport.error.fileAccessDenied", comment: "")
        case .writeFailed:
            return NSLocalizedString("saveImport.error.writeFailed", comment: "")
        }
    }
}

enum BatterySaveImporter {

    /// Outcome of classification. `.savable` means the file passed all
    /// rejection gates. `prepare(url:)` returns the savable bytes; the
    /// data-level `classify` is exposed for unit tests.
    enum Classification: Equatable {
        case savable(system: BatterySaveSystem, byteCount: Int)
        case unsupported(reason: BatterySaveImportError)
    }

    // MARK: - Classification

    static func classify(data: Data, system: BatterySaveSystem) -> Classification {
        if looksLikeROM(data: data) {
            return .unsupported(reason: .invalidFormat)
        }
        guard system.knownSaveSizes.contains(data.count) else {
            return .unsupported(reason: .invalidFormat)
        }
        // 128 KB in this family is a Gen 3 Pokémon save and nothing else: no GB,
        // GBC or NES cart wires that much battery RAM.
        if system == .savFamily, data.count == 131072,
           !hasGen3SectionSignature(data: data) {
            return .unsupported(reason: .invalidFormat)
        }
        return .savable(system: system, byteCount: data.count)
    }

    // MARK: - ROM-header sniff

    /// First 8 bytes of the Nintendo logo, shared by GBA carts at 0x04 and
    /// NDS carts at 0xC0. The boot ROM of each console refuses to launch
    /// without a byte-for-byte match, so any battery save that happens to
    /// contain these bytes at the right offset would be statistically
    /// astronomical to encounter — safe rejection signal.
    private static let nintendoLogoPrefix: [UInt8] = [
        0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21
    ]

    private static func looksLikeROM(data: Data) -> Bool {
        if matchesLogo(data, at: 0x04) { return true }    // GBA
        if matchesLogo(data, at: 0xC0) { return true }    // NDS
        // GB / GBC: logo starts at 0x104 with `CE ED 66 66`.
        if data.count >= 0x108,
           data[0x104] == 0xCE, data[0x105] == 0xED,
           data[0x106] == 0x66, data[0x107] == 0x66 {
            return true
        }
        return false
    }

    private static func matchesLogo(_ data: Data, at offset: Int) -> Bool {
        guard data.count >= offset + nintendoLogoPrefix.count else { return false }
        for (i, expected) in nintendoLogoPrefix.enumerated() {
            if data[offset + i] != expected { return false }
        }
        return true
    }

    // MARK: - Gen 3 section signature

    /// Pokémon Gen 3 saves (Ruby, Sapphire, FireRed, LeafGreen, Emerald) are
    /// 128 KB Flash divided into 32 × 4 KB sections — 14 active + 14 backup
    /// + 4 reserved (Hall of Fame / Trainer Hill). Each section's footer
    /// occupies the last 16 bytes:
    ///   0xFF4 section ID (2) · 0xFF6 checksum (2) · 0xFF8 signature (4) ·
    ///   0xFFC save index (4)
    /// The signature is the constant `0x08012025` at section-relative
    /// offset 0xFF8 (NOT 0xFFC — that holds the save index). A fully-
    /// written save stamps all 28 sections; a freshly-saved game stamps the
    /// 14 sections of whichever slot it last wrote. Requiring AT LEAST ONE
    /// of the 28 expected offsets to match rules out random 128 KB files
    /// while staying tolerant of partial / single-slot saves.
    private static func hasGen3SectionSignature(data: Data) -> Bool {
        let magic: UInt32 = 0x08012025
        for sectionIndex in 0..<28 {
            let offset = sectionIndex * 0x1000 + 0xFF8
            guard offset + 4 <= data.count else { continue }
            let value = UInt32(data[offset])
                      | UInt32(data[offset + 1]) << 8
                      | UInt32(data[offset + 2]) << 16
                      | UInt32(data[offset + 3]) << 24
            if value == magic { return true }
        }
        return false
    }

    // MARK: - Importing

    /// The flat directory holding every game's battery save (`<rom>.sav`).
    /// Single source of truth for the loader, the importer/exporter and the
    /// iCloud battery mirror. Idempotent.
    static var batterySavesRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let savesDir = docs.appendingPathComponent("BatterySaves", isDirectory: true)
        try? FileManager.default.createDirectory(at: savesDir, withIntermediateDirectories: true)
        return savesDir
    }

    /// Where the bridge expects to load this game's battery save. Mirrors
    /// `EmulatorSession.loadROM` exactly — both system families read from
    /// a `.sav` path on disk regardless of the source file's extension.
    static func savePath(forRomBasename romName: String) -> URL {
        batterySavesRoot.appendingPathComponent("\(romName).sav")
    }

    // MARK: - Live-session guard (for the iCloud battery mirror)

    /// Basenames of the ROMs whose battery saves are currently held OPEN by a
    /// live emulation session (mGBA retains the file's VFile for the whole
    /// session; melonDS rewrites the file as the game saves). Usually one
    /// entry; two when an NDS session has a GBA game mounted in slot 2 (the
    /// GBA cart's save RAM is live in the core, and Pal Park writes to it).
    /// Set by `EmulatorSession` on load, cleared on shutdown; read by the
    /// iCloud mirror so it never replaces or half-reads a live save file.
    static var activeSessionBasenames: Set<String> {
        get { activeLock.lock(); defer { activeLock.unlock() }; return _activeSessionBasenames }
        set { activeLock.lock(); _activeSessionBasenames = newValue; activeLock.unlock() }
    }
    private static let activeLock = NSLock()
    private static var _activeSessionBasenames: Set<String> = []

    /// The on-disk basename a ROM's battery save (and save-state folder) is
    /// keyed under, derived from the stored ROM filename by dropping the
    /// extension. **This derivation is a compatibility contract:** the loader
    /// (`EmulatorSession.loadROM`) and the per-game importer both depend on it,
    /// and changing it would point every existing user's game at a new, empty
    /// path — i.e. silently orphan their saves. Centralised here as the single
    /// source of truth and frozen by `BatterySaveImporterTests`.
    static func romBasename(forStoredFilename romFilePath: String) -> String {
        // A disc game is stored as `<folder>/<boot file>`, and the FOLDER is
        // the game: its boot file can be called anything, two different games
        // can both boot from a file called `disc1.cue`, and the folder is the
        // part the importer guarantees unique. Cartridges carry no separator
        // and are unchanged.
        let components = romFilePath.split(separator: "/")
        if components.count > 1, let folder = components.first {
            return String(folder)
        }
        return URL(fileURLWithPath: romFilePath).deletingPathExtension().lastPathComponent
    }

    /// The same key, from the ROM's location on disk rather than from the
    /// stored path. `EmulatorSession` has the URL and not the entity, and this
    /// keeps the two derivations from drifting: whatever names the game here
    /// names its save, its save states, its per-game filter and its palette.
    static func romBasename(forROMURL url: URL) -> String {
        if let folder = DiscStorage.gameFolder(forROMAt: url) {
            return folder.lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Copy the imported save into Documents/BatterySaves under the target
    /// ROM's basename. When a save already exists and `overwriting` is
    /// false, throws `.duplicateExists` so the caller can ask the user
    /// before clobbering. When `overwriting` is true, replaces the file
    /// atomically.
    static func writeImport(from sourceURL: URL,
                            romBasename: String,
                            overwriting: Bool = false) throws {
        let didStartScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { sourceURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: sourceURL, options: .mappedIfSafe) else {
            throw BatterySaveImportError.fileAccessDenied
        }
        try writeImport(data: data, romBasename: romBasename, overwriting: overwriting)
    }

    /// Same contract as the URL-based variant, but takes already-loaded
    /// bytes so the UI can read the file while the document picker's
    /// security scope is still valid, then write after it has dismissed
    /// (iOS revokes the scope once the picker fully dismisses).
    ///
    /// When overwriting an existing save, the current one is first copied
    /// to a timestamped backup (see `backUpExistingSave`) so "Replace" is
    /// never destructive — the user can recover their previous in-game
    /// progress from Files if they imported by mistake.
    static func writeImport(data: Data,
                            romBasename: String,
                            overwriting: Bool = false) throws {
        let dest = savePath(forRomBasename: romBasename)
        let existed = FileManager.default.fileExists(atPath: dest.path)
        if existed, !overwriting {
            throw BatterySaveImportError.duplicateExists
        }
        if existed, overwriting {
            backUpExistingSave(at: dest, romBasename: romBasename)
        }
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            Analytics.signal("save_failure", ["kind": "battery_write"])
            throw BatterySaveImportError.writeFailed
        }
        // Mirror the imported save up to iCloud promptly (no session holds it:
        // the per-game import UI is only reachable outside gameplay).
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .batterySavesDidChange, object: nil)
        }
    }

    /// Directory holding pre-overwrite backups of battery saves, kept in a
    /// `Backups` subfolder so the emulator (which loads an exact `<rom>.sav`
    /// path) never picks them up. Visible to the user in Files under
    /// On My iPhone → Retro Pal → BatterySaves → Backups.
    static var backupsDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("BatterySaves", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    /// Copies the current on-disk save to a timestamped file in `backupsDir`
    /// before it gets overwritten. Best-effort: a backup failure must not
    /// block the import the user explicitly confirmed, so failures are
    /// swallowed rather than thrown.
    private static func backUpExistingSave(at currentSave: URL, romBasename: String) {
        let dir = backupsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = backupTimestampFormatter.string(from: Date())
        let backupURL = dir.appendingPathComponent("\(romBasename)-\(stamp).sav")
        try? FileManager.default.copyItem(at: currentSave, to: backupURL)
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// One-shot classification: reads the file (while its security scope is
    /// still alive), runs the rejection gates, and returns either a `Pending`
    /// the UI can apply to a game or a localized error.
    static func prepare(url: URL) -> Result<Pending, BatterySaveImportError> {
        guard let system = BatterySaveSystem.from(fileExtension: url.pathExtension) else {
            return .failure(.invalidFormat)
        }
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .failure(.fileAccessDenied)
        }
        switch classify(data: data, system: system) {
        case .savable:
            return .success(Pending(data: data, system: system))
        case .unsupported(let reason):
            return .failure(reason)
        }
    }

    /// Fully-classified, in-memory import waiting to be applied to a game.
    /// Detaches from the Files-app security-scoped URL so the picker can
    /// safely dismiss before the write happens.
    struct Pending {
        let data: Data
        let system: BatterySaveSystem
    }
}
