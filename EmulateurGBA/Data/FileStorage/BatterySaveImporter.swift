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
//  The SIZE says which consoles a save can belong to (see
//  `BatterySaveImporter.saveSizes`); the extension does not, since every
//  emulator writes `.sav` or `.srm` for every console (2026-10-07). Only `.mcd`
//  narrows it, to the PlayStation.
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
//  - A file whose size is not a known raw save-RAM size for any console
//    is rejected. Covers most "this is actually a save state, not
//    a battery save" cases — save states are typically tens of KB to a
//    few MB and rarely land on a known battery-save size.
//  - A 128 KB file is a GBA save only when it carries a Gen 3 section
//    signature at one of the 28 expected footer offsets (the other consoles
//    of that size stay candidates). Catches "random 128 KB file that happens
//    to be the right size" for the GBA.
//

import Foundation

/// What a battery save's file extension says about it, which since
/// 2026-10-07 is very little. Every emulator names its saves `.sav` or `.srm`
/// for whatever console it runs (RetroArch writes `.srm` for all of them, Delta
/// and melonDS `.sav` for the DS), and Retro Pal itself stores every console's
/// save as `<rom>.sav`. The old rule, `.sav` for GBA / GB / GBC / NES and `.srm`
/// for DS / SNES / PS1 / N64, turned real saves away: a DS save from Delta, or
/// any save a player opened from Retro Pal's own BatterySaves folder in Files.
/// So the consoles a save can belong to come from its SIZE
/// (`BatterySaveImporter.consoles(acceptingSaveOf:)`), and only `.mcd`, a name
/// nothing but a PlayStation memory card uses, narrows them.
enum BatterySaveSystem: Equatable {
    /// `.sav` or `.srm`: any console's save RAM.
    case cartridge
    /// `.mcd`: a PlayStation memory card, and nothing else uses the name.
    case memoryCard

    static func from(fileExtension ext: String) -> BatterySaveSystem? {
        switch ext.lowercased() {
        case "sav", "srm": return .cartridge
        case "mcd":        return .memoryCard
        default:           return nil
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
    /// rejection gates, and names the consoles (`GameEntity.systemType` raw
    /// values) whose games it can be imported into. `prepare(url:)` returns
    /// the savable bytes; the data-level `classify` is exposed for unit tests.
    enum Classification: Equatable {
        case savable(consoles: Set<String>, byteCount: Int)
        case unsupported(reason: BatterySaveImportError)
    }

    /// Every raw battery-save size each console's saves come in, as other
    /// emulators and our own cores write them.
    static let saveSizes: [String: Set<Int>] = [
        // EEPROM 4K / 64K, SRAM 32 KB, Flash 64 KB and 128 KB (Gen 3 Pokémon).
        "gba": [512, 8192, 32768, 65536, 131072],
        // MBC2's 512 bytes, then 2, 8, 32 KB and the 128 KB of some MBC5 carts.
        "gb":  [512, 2048, 8192, 32768, 131072],
        "gbc": [512, 2048, 8192, 32768, 131072],
        // 8 KB is nearly every battery cart (Zelda, Final Fantasy, Dragon
        // Warrior); a few boards wire 2 KB or 32 KB.
        "nes": [2048, 8192, 32768],
        // 2 to 32 KB (Chrono Trigger, A Link to the Past), 64 and 128 KB for
        // SA-1 and the big RPGs.
        "snes": [2048, 8192, 32768, 65536, 131072],
        // EEPROM 512 B / 8 KB / 64 KB, Flash 256 KB, 512 KB (HG/SS, B/W) and
        // 1 MB (Dragon Quest IX), 8 MB for the largest.
        "nds": [512, 8192, 65536, 262144, 524288, 1048576, 8388608],
        // One size for every cartridge: the core's block holds all of the
        // console's save memories side by side (2 KB EEPROM, four 32 KB
        // Controller Paks, 32 KB SRAM, 128 KB FlashRAM) whichever the game
        // uses. The loader refuses any other size, so a standalone
        // .eep/.sra/.fla is not taken.
        "n64": [296960],
        // A memory card: fifteen blocks of 8 KB plus the directory. The
        // wrapped formats (.gme, .vgs, .vmp) carry a header and are other sizes.
        "ps1": [131072],
        // Sized per cartridge by BlastEm's database and header (`romdb.c`):
        // the save chip's mask plus one, halved when the chip sits on one byte
        // lane, so every power of two from a 128-byte EEPROM to 64 KB of SRAM.
        "md": [128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536],
        // The cartridge's RAM, which MesenCE reads up to 32 KB of and writes at
        // 8, 16 or 32 KB, the size its game has used (`SmsMemoryManager`);
        // other emulators write the full 32 KB or the 8 KB nearly every game
        // uses. A smaller file loads into the start of the RAM, which is where
        // the game keeps it, and the core never writes it back smaller.
        "sms": [8192, 16384, 32768],
        "gg": [8192, 16384, 32768],
    ]

    /// Bytes a clock cartridge's save carries AFTER its save RAM: the clock's
    /// state, appended by mGBA (ours) and the emulators that share its format.
    /// A GBA clock cart (Pokémon Ruby, Sapphire, Emerald) adds 16 bytes
    /// (`GBASavedataRTCBuffer`); a Game Boy MBC3 clock cart (Pokémon Gold,
    /// Silver, Crystal) 48, or 44 in the older VBA layout. Before 2026-10-07
    /// these sizes were refused, so a save mGBA itself had written did not
    /// import back.
    static let clockSuffixes: [String: Set<Int>] = [
        "gba": [16],
        "gb":  [44, 48],
        "gbc": [44, 48],
    ]

    /// The consoles a save of `data`'s size can belong to (its size, or its
    /// size less a clock suffix, is one of theirs), before any extension
    /// narrows them.
    static func consoles(acceptingSaveOf data: Data) -> Set<String> {
        var consoles: Set<String> = []
        for (console, sizes) in saveSizes {
            let suffixes = [0] + (clockSuffixes[console] ?? [])
            guard let ramSize = suffixes.lazy.map({ data.count - $0 }).first(where: { sizes.contains($0) })
            else { continue }
            // 128 KB in a GBA save is a Gen 3 Pokémon save and nothing else.
            if console == "gba", ramSize == 131072, !hasGen3SectionSignature(data: data) { continue }
            consoles.insert(console)
        }
        return consoles
    }

    // MARK: - Classification

    static func classify(data: Data, system: BatterySaveSystem) -> Classification {
        if looksLikeROM(data: data) {
            return .unsupported(reason: .invalidFormat)
        }
        var consoles = Self.consoles(acceptingSaveOf: data)
        if system == .memoryCard { consoles.formIntersection(["ps1"]) }
        guard !consoles.isEmpty else {
            return .unsupported(reason: .invalidFormat)
        }
        return .savable(consoles: consoles, byteCount: data.count)
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

    /// Where a PSP game keeps its saves: a memory stick, a FOLDER the game
    /// writes itself (`PSP/SAVEDATA/<game id>/…`), one per game under the same
    /// key as every other save of that game (`romBasename`).
    ///
    /// NOT under `batterySavesRoot`, on purpose: that directory holds one flat
    /// `<rom>.sav` per game, and the iCloud battery mirror and the save importer
    /// read it as exactly that. A folder there would be one more thing every
    /// reader of it has to know to skip. So a PSP save is LOCAL to the device
    /// for now: syncing a folder is not the `.sav` mirror's job. The bridge
    /// creates the folder.
    ///
    /// ONE stick for every UMD of a game: "X (Disc 1)" and "X (Disc 2)" are two
    /// library entries (the PSP core cannot swap a UMD in a running game), yet a
    /// game on its second disc reads the save its first disc wrote, as from the
    /// one stick in a real PSP (audit 2026-10-12; before, disc 2 started on an
    /// empty stick). Sharing harms nothing: inside a stick each save is filed by
    /// the game's own ID.
    static func pspMemoryStickFolder(forRomBasename romName: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let stick = DiscImportGrouper.discToken(inStem: romName)?.base ?? romName
        return docs.appendingPathComponent("MemoryStick", isDirectory: true)
            .appendingPathComponent(stick, isDirectory: true)
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
            Analytics.signal("save_failure", ["kind": "battery_write",
                                              "reason": ErrorTelemetry.writeReason(for: error).rawValue])
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

    /// Copy a game's in-game save to `backupsDir` before a SAVE STATE is
    /// loaded, keeping the newest `stateLoadBackupsKept` per game.
    ///
    /// Why (decided 2026-10-12): a state carries the cartridge's save memory on
    /// several cores (melonDS rewrites the `.sav` from it; MesenCE, so the NES,
    /// Super Nintendo, Master System and Game Gear, puts it back and flushes it
    /// later), so loading an OLDER state, an old slot or an old auto-save,
    /// silently replaces a newer in-game save. The state is the player's
    /// choice; losing the save with it is not, and this copy is the way back
    /// (Files ▸ Retro Pal ▸ BatterySaves ▸ Backups). Best-effort: a failed
    /// copy never blocks the load.
    static func backUpBeforeStateLoad(romBasename: String) {
        let save = savePath(forRomBasename: romBasename)
        guard FileManager.default.fileExists(atPath: save.path) else { return }
        let dir = backupsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefix = "\(romBasename)-before-state-"
        let stamp = backupTimestampFormatter.string(from: Date())
        try? FileManager.default.copyItem(at: save, to: dir.appendingPathComponent("\(prefix)\(stamp).sav"))
        // The newest few only: a player who loads states often must not fill
        // the folder. The stamp sorts by date as text.
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".sav") }
            .sorted()
        for name in names.dropLast(stateLoadBackupsKept) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static let stateLoadBackupsKept = 5

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
        case .savable(let consoles, _):
            return .success(Pending(data: data, consoles: consoles))
        case .unsupported(let reason):
            return .failure(reason)
        }
    }

    /// Fully-classified, in-memory import waiting to be applied to a game.
    /// Detaches from the Files-app security-scoped URL so the picker can
    /// safely dismiss before the write happens.
    struct Pending {
        let data: Data
        /// The `GameEntity.systemType` values whose games this save fits.
        let consoles: Set<String>
    }
}
