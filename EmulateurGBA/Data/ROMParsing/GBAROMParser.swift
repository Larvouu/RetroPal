//
//  GBAROMParser.swift
//  EmulateurGBA
//
//  Parses GBA, GB, GBC and NDS ROM headers to extract title + game code,
//  and decides which system a ROM belongs to. Also computes SHA256 for
//  deduplication.
//
//  System detection is EXTENSION-FIRST. A ROM file's extension (.gba /
//  .gb / .gbc / .nds) is the authoritative declaration of its system:
//  emulator ROMs are virtually always named correctly, and the extension
//  is the only reliable signal for two cases content-sniffing gets wrong:
//    - DS homebrew, which routinely omits the Nintendo logo at 0xC0 that
//      a logo-based NDS check depends on.
//    - the GB-vs-GBC split, which the CGB header flag reports ambiguously
//      for dual-mode games (flag 0x80 = "runs on both").
//  Content-sniffing is kept as a fallback for files with no usable
//  extension (e.g. odd names inside ZIP archives).
//
//  GBA  header: title 0xA0-0xAB, marker byte 0x96 at 0xB2.
//  GB   header: title 0x134-0x142, Nintendo logo 0x104-0x133.
//  NDS  header: title 0x000-0x00B, ARM9/ARM7 descriptors at 0x20/0x30.
//  N64  header: title 0x20-0x33, game code 0x3B-0x3E, in any of three byte
//       orders (see `n64ByteOrder`).
//

import Foundation
import CommonCrypto

enum ROMSystemType: String {
    case gba = "gba"
    case gb = "gb"
    case gbc = "gbc"
    case nds = "nds"
    case snes = "snes"
    case nes = "nes"
    case ps1 = "ps1"
    case n64 = "n64"
    case md = "md"
    case sms = "sms"
    case gg = "gg"
    case psp = "psp"

    /// The PlayStation's formats, and the first ones here that are DISCS.
    ///
    /// A cartridge is one file with a header at a known offset, which is what
    /// every check in this parser assumes. A disc is a filesystem, sometimes
    /// split across a descriptor and its data (`.cue` + `.bin`), sometimes a
    /// playlist naming several of those (`.m3u`), and its identity lives in a
    /// `SYSTEM.CNF` inside the image rather than at any fixed offset. So the
    /// extension is authoritative for these and the real validation belongs to
    /// the disc importer, which can read the structure.
    ///
    /// `.chd` leads the guidance everywhere the app talks about formats: it is
    /// one file, it compresses, and RetroAchievements can hash it. `.pbp` is
    /// accepted and captioned rather than refused, because a player who has one
    /// should not be told their game is invalid. `.exe` is deliberately absent:
    /// the core takes it, but it is a homebrew loader, not a game.
    static let discFileExtensions: Set<String> = [
        "chd", "cue", "bin", "m3u", "pbp", "iso", "img", "mdf", "toc", "cbn"
    ]

    /// The PSP's formats (2026-10-09): `.iso` (a UMD image), `.cso` (one
    /// compressed), `.pbp` (an EBOOT), and `.chd` (2026-10-12). Three of the
    /// four are ALSO the PlayStation's (a PlayStation disc dumped as `.iso` or
    /// made into a `.chd`, a PlayStation game repacked as an EBOOT), so for
    /// those the extension cannot name the console and `resolve(url:)` reads
    /// the file. `.cso` is the PSP's alone.
    /// A PSP game is one disc image, of up to 1.8 GB, and takes the disc import
    /// path (a folder per game, a bounded identity hash, extraction to disk out
    /// of a zip), which is built for exactly that: see `importsAsDisc`. `.cso`
    /// is NOT in `discFileExtensions`, which stays the PlayStation's list (the
    /// core and RetroAchievements answer "PlayStation" for every name in it).
    ///
    /// `.chd` was the PlayStation's alone until 2026-10-12, on the theory that
    /// PSP sets circulate as `.iso` / `.cso`; a fan-translated Kingdom Hearts
    /// Birth by Sleep `.chd` then imported as a PlayStation game and could not
    /// start. PPSSPP reads a `.chd` (`CHDFileBlockDevice`), so the file is read
    /// like an `.iso`: a UMD made into a `.chd` holds 2048-byte sectors, a
    /// PlayStation one raw CD sectors (`PSPDiscProbe`).
    static let pspFileExtensions: Set<String> = ["iso", "cso", "pbp", "chd"]

    /// Every extension the importer takes down the DISC path: the PlayStation's
    /// and the PSP's. The two gates that route a file (the importer and the
    /// grouper) ask this; what a disc extension MEANS (which console, which
    /// achievements) is `discFileExtensions` and `resolve(url:)`.
    static let importsAsDisc: Set<String> = discFileExtensions.union(pspFileExtensions)

    /// Maps a file extension to the system it declares. Returns nil for
    /// anything that isn't a recognized ROM extension.
    ///
    /// Not a rawValue lookup any more: the SNES ships under two extensions
    /// (`.sfc` and `.smc`, the same ROM with or without a copier header) while
    /// the stored `systemType` must stay one value per console.
    static func from(fileExtension ext: String) -> ROMSystemType? {
        switch ext.lowercased() {
        case "gba":          return .gba
        case "gb":           return .gb
        case "gbc":          return .gbc
        case "nds":          return .nds
        case "sfc", "smc":   return .snes
        case "nes":          return .nes
        // One console, three extensions for the three byte orders its
        // cartridges were dumped in. The core normalises all of them, and the
        // header check below reads each.
        case "z64", "n64", "v64": return .n64
        // One console, three names for the same cartridge dump: `.md` (the
        // No-Intro name), `.gen` (the Genesis), and `.smd`, the copier format
        // that interleaves each 16 KB block and adds a 512-byte header, which
        // the core recognises and undoes itself. `.bin`, the fourth name in
        // circulation, is a PlayStation disc here; see `discFileExtensions`.
        case "md", "gen", "smd":  return .md
        // Two consoles, one core and one cartridge format, told apart by the
        // extension alone: MesenCE chooses the Game Gear model from `.gg`
        // (`SmsConsole::LoadRom`), and so does everything here. `.sg` (the
        // SG-1000) and `.col` (the ColecoVision), which the same core reads,
        // are not offered: they are not among the consoles the app carries.
        case "sms":          return .sms
        case "gg":           return .gg
        // The PSP's own compressed image. Its `.iso` and `.pbp` are shared with
        // the PlayStation and fall to the default below: only the file's bytes
        // can tell them apart (`resolve(url:)`).
        case "cso":          return .psp
        default:
            return discFileExtensions.contains(ext.lowercased()) ? .ps1 : nil
        }
    }

    /// Every extension the importer accepts for this system, used by the file
    /// pickers and the ZIP extractor so the three can never drift.
    /// Files that belong to a disc game without ever being one.
    ///
    /// `.sbi` carries the subchannel data a PAL LibCrypt disc needs in order to
    /// get past its copy protection, and it has to travel with the disc. It is
    /// pickable for that reason and is NOT in `discFileExtensions`, so it never
    /// resolves to a system and can never become a library entry by itself.
    /// **This matters more to us than to most: LibCrypt is a PAL practice, and
    /// we are FR-first, so our players hold disproportionately many of exactly
    /// these discs.**
    /// `.ccd` joined the sidecars 2026-09-03: a CloneCD set is a `.ccd`
    /// descriptor beside a `.img` image (and often a `.sub`), and the core
    /// boots from the IMAGE, finding the descriptor by name next to it, so the
    /// image is the game and the descriptor travels with it, the way a `.sbi`
    /// does. The grouper still names a missing `.img` rather than dropping a
    /// lone `.ccd` silently.
    static let discSidecarExtensions: Set<String> = ["sbi", "sub", "ccd"]

    /// Everything the file pickers offer. Sidecars are included so they can be
    /// selected ALONGSIDE their disc; the grouper drops any that arrive alone.
    static let allFileExtensions: [String] =
        ["gba", "gb", "gbc", "nds", "sfc", "smc", "nes", "z64", "n64", "v64", "md", "gen", "smd",
         "sms", "gg"]
        + importsAsDisc.sorted() + discSidecarExtensions.sorted()

    /// The extension a cartridge of this console is stored under when it
    /// arrived misnamed (`GBAROMParser.storedCartridgeName`). Nil for the two
    /// disc consoles, which are never renamed.
    var canonicalExtension: String? {
        switch self {
        case .gba: return "gba"
        case .gb:  return "gb"
        case .gbc: return "gbc"
        case .nds: return "nds"
        case .snes: return "sfc"
        case .nes: return "nes"
        case .n64: return "z64"
        case .md:  return "md"
        case .sms: return "sms"
        case .gg:  return "gg"
        case .ps1, .psp: return nil
        }
    }

    /// Whether this system's games arrive as discs rather than cartridges.
    /// Import, hashing, saves and the library entry all branch on it. The PSP
    /// is one: a UMD is a disc, its image is up to 1.8 GB, and the disc path
    /// is what copies, hashes and stages a file that size safely.
    var isDiscBased: Bool { self == .ps1 || self == .psp }

    /// The console a file on disk belongs to, reading it when its extension
    /// is shared: a PSP `.iso` or `.pbp` is a PSP game, the same extensions
    /// holding a PlayStation disc are the PlayStation's (`PSPDiscProbe`, the
    /// PSP emulator's own tests). Every other file answers as its extension
    /// does, without being opened.
    ///
    /// ⚠ THIS, not `from(fileExtension:)`, is what any code holding a URL must
    /// ask. The extension alone files every PSP `.iso` under the PlayStation:
    /// the wrong core, the wrong pad, the wrong achievements.
    static func resolve(url: URL) -> ROMSystemType? {
        let ext = url.pathExtension.lowercased()
        if (ext == "iso" || ext == "pbp" || ext == "chd"),
           PSPDiscProbeIsPSPGame(url.path) {
            return .psp
        }
        return from(fileExtension: ext)
    }

    /// The disc images whose bytes do not say which of the two disc consoles
    /// they belong to: an `.iso` or a `.chd` whose volume names some other
    /// system and carries no PSP_GAME folder, or one that cannot be read
    /// (`PSPDiscProbeUndecided`). The importer asks the player for these
    /// rather than filing them under the PlayStation unasked, which is what
    /// the extension alone would do. Reads the bytes only, never the choice
    /// already recorded for an imported game.
    static func consoleIsUndecided(url: URL) -> Bool {
        PSPDiscProbeRead(url.path) == PSPDiscProbeUndecided
    }

    /// The file, in a disc game's folder, that records the console the player
    /// chose for an undecided image ("psp" or "ps1"), read back by
    /// `PSPDiscProbeIsPSPGame`. One name, the C header's.
    static let consoleChoiceFileName = PSP_DISC_PROBE_CHOICE_FILE
}

struct ROMInfo {
    let title: String
    let gameCode: String
    let sha256: String
    let fileSize: Int64
    let systemType: ROMSystemType
}

enum GBAROMParser {
    /// First 8 bytes of the Nintendo logo. The full 156-byte sequence is
    /// embedded at 0x04 in GBA carts and at 0xC0 in NDS carts; the boot
    /// ROM of each console verifies it byte-for-byte and refuses to launch
    /// otherwise. Checking just the prefix is sufficient to discriminate
    /// from any other binary format.
    private static let nintendoLogoPrefix: [UInt8] = [
        0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21
    ]

    // MARK: - Parsing

    /// `systemHint` overrides the extension's answer, for the one file whose
    /// extension does not decide its console: a Mega Drive `.bin`
    /// (`isMegaDriveBin`), read before it is stored as `.md`.
    static func parse(fileURL: URL, systemHint: ROMSystemType? = nil) -> ROMInfo? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        return parse(data: data,
                     fileSize: Int64(data.count),
                     systemHint: systemHint ?? ROMSystemType.resolve(url: fileURL))
    }

    // MARK: - The Mega Drive `.bin`

    /// The largest file a Mega Drive `.bin` can be. The biggest cartridges
    /// are 5 MB (Super Street Fighter II) and homebrew reaches 8; 16 leaves
    /// room and keeps the test from ever reading a PlayStation data track,
    /// which runs to hundreds of megabytes.
    static let megaDriveBinMaxBytes = 16 * 1024 * 1024

    /// Whether a `.bin` is a Mega Drive cartridge rather than a PlayStation
    /// disc's track. `.bin` is both consoles' extension in circulation (the
    /// GoodGen sets name every cartridge `.bin`), so for this one extension
    /// the bytes decide: the cartridge header (`isValidMDFile`, which also
    /// refuses a Mega-CD image) in a file no larger than a cartridge. Every
    /// other `.bin` stays a disc, exactly as before. Reads 16.5 KB at most.
    ///
    /// Opens the file's security scope itself (2026-10-10). The batch picker
    /// asks this of every picked file while GROUPING, before any import has
    /// opened a scope (`DiscImportGrouper.group`), and a picked file read
    /// outside its scope has no size and no bytes: every Mega Drive `.bin`
    /// picked from the `+` button was answered "not a cartridge" and filed as
    /// a PlayStation disc. Opening a scope already open is harmless (they nest).
    static func isMegaDriveBin(url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "bin" else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= megaDriveBinMaxBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x4200) else { return false }
        return isValidMDFile(data: head)
    }

    // MARK: - A disc image that boots alone

    /// Whether a disc file that a game boots from DIRECTLY (no `.cue`, `.toc`,
    /// `.ccd` or `.m3u` pointing at it) carries what its format must carry.
    ///
    /// `isValidROMFile` passes every disc extension unread, which is right for
    /// a descriptor's tracks (an audio track has no filesystem), but a lone
    /// image is the whole game: before 2026-10-10 any `.bin`, `.iso`, `.img`,
    /// `.cso` or `.pbp` became a library entry, a PlayStation one unless it
    /// read as a PSP game, whatever it held (firmware, a truncated download,
    /// another console's disc), and failed only at boot. Each test below is
    /// the first thing the core that would run the file reads:
    ///
    /// - `.chd`: "MComprHD" (libchdr, both cores).
    /// - `.cso`: "CISO" (PPSSPP `ConstructBlockDevice`).
    /// - `.pbp`: "\0PBP", or an ELF misnamed `.pbp` (PPSSPP `Identify_File`).
    /// - `.bin`, `.iso`, `.img`, `.mdf`: the ISO 9660 volume descriptor,
    ///   "CD001" at sector 16, in whichever sector layout the dump uses
    ///   (2048 for an `.iso`, 2352 raw in mode 1 or mode 2, 2336, and 2448 for
    ///   an Alcohol `.mdf` with subchannel). Every PlayStation and PSP disc
    ///   boots from that filesystem (`PSPDiscProbe`, PCSX `cdriso.c`).
    ///
    /// Anything else (`.cbn`) passes, as before. Reads 40 KB at most.
    static func isBootableDiscImage(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16 * 2448 + 32) else { return false }
        return isBootableDiscImage(head: head, fileExtension: url.pathExtension)
    }

    /// The same test on the first bytes of the file (`isBootableDiscImage(url:)`).
    static func isBootableDiscImage(head: Data, fileExtension ext: String) -> Bool {
        let bytes = [UInt8](head)
        func has(_ magic: [UInt8], at offset: Int) -> Bool {
            offset + magic.count <= bytes.count
                && Array(bytes[offset..<(offset + magic.count)]) == magic
        }
        switch ext.lowercased() {
        case "chd": return has(Array("MComprHD".utf8), at: 0)
        // PPSSPP reads CISO versions 0 and 1 only ("CSO version too high!",
        // BlockDevices.cpp), as our own achievements reader does: a version 2
        // file would import and then fail at boot.
        case "cso": return has(Array("CISO".utf8), at: 0) && bytes.count > 20 && bytes[20] <= 1
        case "pbp": return has([0x00] + Array("PBP".utf8), at: 0) || has([0x7F] + Array("ELF".utf8), at: 0)
        case "bin", "iso", "img", "mdf":
            let volume: [UInt8] = [0x01] + Array("CD001".utf8)
            let layouts: [(sector: Int, userData: Int)] = [
                (2048, 0), (2352, 16), (2352, 24), (2336, 8), (2448, 16), (2448, 24)
            ]
            // A Sega disc (Mega-CD "SEGADISCSYSTEM", Saturn "SEGA SEGASATURN")
            // is ISO 9660 too, and opens its first sector with its boot header:
            // not a disc either core here runs (BlastEm's own test,
            // `detect_system_type`). Sector 0 of a PlayStation or PSP disc is
            // the system area and never holds it.
            let sega = Array("SEGA".utf8)
            if [0, 16].contains(where: { has(sega, at: $0) }) { return false }
            return layouts.contains { has(volume, at: 16 * $0.sector + $0.userData) }
        default:
            return true
        }
    }

    /// The name a cartridge is stored under in ROMs/: its own, except a Mega
    /// Drive `.bin`, which is stored as `.md`. Once it is `.md` every part of
    /// the app that reads a console from an extension (the core, the save
    /// paths, RetroAchievements, the share cards) sees a Mega Drive game, and
    /// none of them has to learn the exception.
    ///
    /// And a cartridge whose bytes are plainly ANOTHER console's than its
    /// extension says (2026-10-12 audit): a Nintendo 64 or DS game named
    /// `.gba`, a NES game named `.sfc`. The import reads the bytes and files
    /// the right console (`resolveSystem`), but everything after it, the core
    /// at launch included, read the console from the extension: the library
    /// said one console and the wrong core ran. Stored under the console's own
    /// extension, the two can no longer disagree. Game Boy and Game Boy Color
    /// keep theirs (one core, one pad: `.gb` with colour bytes is not misnamed
    /// in any way that matters), as do consoles told apart by the extension
    /// alone (the Master System and the Game Gear).
    static func storedCartridgeName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if isMegaDriveBin(url: url) { return base + ".md" }
        guard let named = ROMSystemType.from(fileExtension: url.pathExtension),
              !named.isDiscBased,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let actual = resolveSystem(data: data, hint: named),
              actual != named,
              !([named, actual].allSatisfy { $0 == .gb || $0 == .gbc }),
              let ext = actual.canonicalExtension else {
            return url.lastPathComponent
        }
        return base + "." + ext
    }

    /// Parses ROM metadata. `systemHint` carries the system declared by the
    /// file extension (see the file header); pass it whenever a URL is
    /// available. With no hint the system is sniffed from the bytes.
    static func parse(data: Data, fileSize: Int64,
                      systemHint: ROMSystemType? = nil) -> ROMInfo? {
        guard let system = resolveSystem(data: data, hint: systemHint) else {
            return nil
        }

        let title: String
        let gameCode: String
        switch system {
        case .nds:
            // The banner names the game properly, in the phone's language when
            // the cartridge has it; the 12-byte code name at 0x000 is the
            // fallback it used to be the whole answer.
            title = ndsBannerTitle(data) ?? readASCII(data, 0x000, 0x00C)
            gameCode = readASCII(data, 0x00C, 0x010)
        case .snes:
            // The 21-byte title sits inside the cartridge header, whose position
            // depends on the mapping (LoROM vs HiROM) and on whether a copier
            // header shifts everything by 512 bytes. `snesHeaderOffset` finds it.
            title = snesHeaderOffset(data).map { readJISX0201(data, $0, $0 + 21) } ?? ""
            gameCode = ""
        case .nes:
            // An iNES header carries no title. The filename is the only name a
            // NES ROM has, which is also true of GB and GBC.
            title = ""
            gameCode = ""
        case .sms, .gg:
            // The Sega header ("TMR SEGA" near the end of the first 32 KB)
            // holds a checksum, a product number and a region, and no title.
            // The filename is the name, as on the NES.
            title = ""
            gameCode = ""
        case .gb, .gbc:
            // 0x134-0x142 is the title field; 0x143 is the CGB flag and
            // must NOT be read as part of the title (it is >0x7F on
            // CGB-aware carts, which would break the ASCII decode).
            title = readASCII(data, 0x134, 0x143)
            gameCode = ""
        case .gba:
            title = readASCII(data, 0x0A0, 0x0AC)
            gameCode = readASCII(data, 0x0AC, 0x0B0)
        case .n64:
            // Name at 0x20 (20 bytes) and the four-character game code at 0x3B
            // (media, two-letter ID, region: "NSME" is Super Mario 64, USA),
            // read in the console's own byte order whatever order the dump
            // is in. The name is JIS X 0201 like the SNES's, which is what a
            // Japanese cartridge's katakana title needs.
            let header = n64BigEndianHeader(data) ?? Data()
            title = readJISX0201(header, 0x20, 0x34)
            gameCode = readASCII(header, 0x3B, 0x3F)
        case .md:
            // The cartridge header names the game twice; the overseas name is
            // the one in Latin letters. The serial at 0x180 is not a code the
            // box-art index knows, so it is not carried.
            title = mdHeader(data).map(mdTitle) ?? ""
            gameCode = ""
        // A PSP image carries its name in PARAM.SFO, inside the image's own
        // filesystem, as a PlayStation disc carries its SYSTEM.CNF: the
        // importer's filename fallback names it, as it names the PlayStation's.
        case .ps1, .psp:
            // A disc carries both, and neither is at an offset. The name and
            // the serial (SCUS-94900 and the like) live in a SYSTEM.CNF inside
            // an ISO 9660 filesystem, which for a `.cue` is not even in this
            // file, and for a `.chd` is behind decompression. Reading it needs
            // a track layout, so it belongs to the disc importer.
            //
            // Empty is not a stopgap: it is what the NES answers too, and the
            // importer's filename fallback is what both then use. A player's
            // own filename is a better name than a wrong one.
            title = ""
            gameCode = ""
        }

        return ROMInfo(title: title.isEmpty ? "Unknown Game" : title,
                       gameCode: gameCode,
                       sha256: identityHash(data: data, fileSize: fileSize, system: system),
                       fileSize: fileSize,
                       systemType: system)
    }

    /// Reads the 4-character cartridge game code from a ROM header (GBA at
    /// 0xAC, NDS at 0xC; GB/GBC have no unique code). Reads only the header
    /// bytes — the code survives renaming AND NDS trimming, which is what
    /// box-art matching uses it for.
    static func gameCode(url: URL, system: ROMSystemType) -> String? {
        guard system == .gba || system == .nds || system == .n64,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x200) else { return nil }
        let code: String
        switch system {
        case .gba: code = readASCII(header, 0x0AC, 0x0B0)
        // The N64's code is read in the console's order whatever the dump's,
        // exactly as `parse(data:)` reads it.
        case .n64: code = n64BigEndianHeader(header).map { readASCII($0, 0x3B, 0x3F) } ?? ""
        default:   code = readASCII(header, 0x00C, 0x010)
        }
        return code.count >= 3 ? code : nil
    }

    /// Reads just the internal header title (offsets as in parse(data:)).
    /// Box-art matching uses it to detect a library title that merely echoes
    /// the header — for a ROM hack that echo names the BASE game, not the
    /// hack, and must not drive identification.
    static func headerTitle(url: URL, system: ROMSystemType) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x200) else { return nil }
        let title: String
        switch system {
        case .nds:
            // Same answer as `parse(data:)`, so a library title taken from the
            // banner reads as the echo it is. The banner sits past the 0x200
            // bytes read above, so the file is mapped, as for the SNES.
            guard let full = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            title = ndsBannerTitle(full) ?? readASCII(full, 0x000, 0x00C)
        case .gb, .gbc: title = readASCII(header, 0x134, 0x143)
        case .gba:      title = readASCII(header, 0x0A0, 0x0AC)
        case .snes:
            // The SNES header is at least 32 KB into the file and can be 4 MB
            // in, so the 0x200 bytes read above cannot reach it. Map instead.
            guard let full = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let offset = snesHeaderOffset(full) else { return nil }
            title = readJISX0201(full, offset, offset + 21)
        case .nes:      title = ""   // an iNES header carries no title
        case .sms, .gg: title = ""   // nor does a Sega 8-bit header
        case .n64:      title = n64BigEndianHeader(header).map { readJISX0201($0, 0x20, 0x34) } ?? ""
        case .md:
            // An `.smd` holds the header 512 bytes in and interleaved across
            // its first 16 KB block, past the 0x200 bytes read above.
            try? handle.seek(toOffset: 0)
            guard let first = try? handle.read(upToCount: 0x4200),
                  let cartridgeHeader = mdHeader(first) else { return nil }
            title = mdTitle(cartridgeHeader)
        // Nor does a disc, at any offset this function could read. Its caller
        // is box-art matching, which asks "does the library title merely echo
        // the header?" — and with no header title there is no echo to find,
        // which is a correct answer rather than a missing one.
        case .ps1, .psp: title = ""
        }
        return title.isEmpty ? nil : title
    }

    /// Cheap system-type probe. With a known file extension this answers
    /// without touching the file at all; otherwise it reads a header-sized
    /// prefix. No SHA256, no full mmap. Used on hot paths such as launch-time
    /// re-validation where the full ROMInfo is not needed.
    ///
    /// The prefix is a MAPPING rather than a read because a SNES header can sit
    /// 4 MB into the file. Mapping is constant-time and faults only the pages a
    /// validator actually touches, which for every console but SNES is the first
    /// one. This path runs only when a file has no usable extension; a correctly
    /// named ROM still costs nothing at all.
    static func detectSystemType(url: URL) -> ROMSystemType? {
        if let hint = ROMSystemType.resolve(url: url) {
            return hint
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return detectSystemType(data: data)
    }

    /// Content-only system sniff. Used as the fallback when no file
    /// extension is available.
    static func detectSystemType(data: Data) -> ROMSystemType? {
        resolveSystem(data: data, hint: nil)
    }

    // MARK: - System resolution

    /// Decides the system for a ROM. The extension hint wins whenever the
    /// bytes confirm the file really is a ROM of that family; otherwise
    /// the system is sniffed from the content, most-specific format first.
    private static func resolveSystem(data: Data, hint: ROMSystemType?) -> ROMSystemType? {
        // Discs never reach the cartridge sniffers below. Every one of those
        // reads a header at a fixed offset, and a disc has no such header: what
        // identifies it is a filesystem, and reading that needs the whole image
        // and a track layout, which is the disc importer's job and not this
        // parser's. Trusting the extension here is therefore not laziness, it
        // is declining to give a confident wrong answer.
        if let hint = hint, hint.isDiscBased { return hint }

        if let hint = hint, isValidFile(data: data, system: hint) {
            return hint
        }

        // No usable extension, or the extension disagreed with the bytes.
        // Sniff most-specific first: NES and N64 (4-byte magics) and NDS (strict
        // structural check), then GB/GBC (logo), then SNES (a checksum pair,
        // which is weaker than a magic number but still a real test), then GBA
        // (a single marker byte — the weakest test, so it runs last to avoid
        // swallowing anything else).
        if isValidNESFile(data: data) { return .nes }
        if isValidN64File(data: data) { return .n64 }
        if isValidNDSFile(data: data) { return .nds }
        if isValidGBFile(data: data) {
            // 0x143 = CGB flag: 0x80 = CGB-aware, 0xC0 = CGB-only.
            let cgbFlag = data.count > 0x143 ? data[0x143] : 0
            return (cgbFlag == 0x80 || cgbFlag == 0xC0) ? .gbc : .gb
        }
        // "SEGA" at a fixed offset is a magic of its own, so it runs before
        // the SNES's checksum search and the GBA's single byte.
        if isValidMDFile(data: data) { return .md }
        if isValidSNESFile(data: data) { return .snes }
        if isValidGBAFile(data: data) { return .gba }

        // Nothing matched the bytes. If the file still carried a known ROM
        // extension, honor it so an unusual but correctly-named ROM reaches
        // the right core rather than being rejected outright.
        return hint
    }

    /// "Do these bytes look like this system's cartridge?" — a question that
    /// only has an answer for cartridges.
    private static func isValidFile(data: Data, system: ROMSystemType) -> Bool {
        switch system {
        case .nds:      return isValidNDSFile(data: data)
        case .gb, .gbc: return isValidGBFile(data: data)
        case .gba:      return isValidGBAFile(data: data)
        case .snes:     return isValidSNESFile(data: data)
        case .nes:      return isValidNESFile(data: data)
        case .n64:      return isValidN64File(data: data)
        case .md:       return isValidMDFile(data: data)
        case .sms, .gg: return isValidSMSFile(data: data)
        // Unreachable in practice: `resolveSystem` returns a disc hint before
        // it gets here. Answering NO rather than YES anyway, because this
        // function's contract is a byte test and we have none — and it is the
        // safe direction: `resolveSystem` falls through to its sniffers and
        // then returns the hint regardless, so a disc still resolves to .ps1.
        case .ps1, .psp: return false
        }
    }

    // MARK: - Format validators

    static func isValidGBAFile(data: Data) -> Bool {
        guard data.count >= 0xC0 else { return false }
        return data[0xB2] == 0x96
    }

    static func isValidGBAFile(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        guard let data = try? handle.read(upToCount: 0xC0) else { return false }
        return isValidGBAFile(data: data)
    }

    static func isValidGBFile(data: Data) -> Bool {
        // GB ROMs have a Nintendo logo at 0x104-0x133 (48 bytes).
        // Check first 4 bytes of the logo: CE ED 66 66.
        guard data.count >= 0x150 else { return false }
        return data[0x104] == 0xCE && data[0x105] == 0xED &&
               data[0x106] == 0x66 && data[0x107] == 0x66
    }

    /// Validates a NES ROM. Every `.nes` file in circulation is iNES or its
    /// NES 2.0 successor, and both open with the same four bytes, so this is a
    /// real magic number rather than a heuristic.
    static func isValidNESFile(data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        return data[0] == 0x4E && data[1] == 0x45 && data[2] == 0x53 && data[3] == 0x1A
    }

    /// A Master System or Game Gear cartridge, as far as bytes can say.
    ///
    /// There is no magic every cartridge carries. Most have the Sega header,
    /// "TMR SEGA" at 0x7FF0 (or 0x3FF0, 0x1FF0 on the small ones), but the
    /// export Master System's BIOS is the only thing that ever checked it:
    /// Japanese cartridges, many Game Gear games and plenty of homebrew leave
    /// it out, and the core runs them all. So the extension decides, as it does
    /// for the PlayStation's discs, and this asks only what the core itself
    /// requires before it will load a file (`SmsConsole::LoadRom`: at least 256
    /// bytes). No sniffer is added to `resolveSystem` for the same reason: a
    /// file with no extension cannot be told to be one of these from its bytes.
    static func isValidSMSFile(data: Data) -> Bool {
        data.count >= 0x100
    }

    /// The first word of every N64 cartridge, as the console reads it
    /// (big-endian, the `.z64` order), and as it lands in the other two dumps:
    /// `.v64` swaps each 16-bit half, `.n64` reverses each 32-bit word. These
    /// are the core's own signatures (mupen64plus-core `rom.c`), and the rule
    /// is its `is_valid_rom`, size parity included, so the importer accepts
    /// exactly what the core will load.
    enum N64ByteOrder {
        case bigEndian, halfwordSwapped, wordSwapped
    }

    static func n64ByteOrder(_ data: Data) -> N64ByteOrder? {
        guard data.count >= 0x40 else { return nil }
        let b = data.startIndex
        let magic = (data[b], data[b + 1], data[b + 2], data[b + 3])
        switch magic {
        case (0x80, 0x37, 0x12, 0x40): return .bigEndian
        case (0x37, 0x80, 0x40, 0x12): return data.count % 2 == 0 ? .halfwordSwapped : nil
        case (0x40, 0x12, 0x37, 0x80): return data.count % 4 == 0 ? .wordSwapped : nil
        default:                       return nil
        }
    }

    static func isValidN64File(data: Data) -> Bool {
        n64ByteOrder(data) != nil
    }

    /// The first 0x40 bytes of an N64 cartridge (the header) in the console's
    /// own order, or nil when the data is not an N64 cartridge. Only the header
    /// is reordered: it is all the parser reads, and a cartridge is up to 64 MB.
    private static func n64BigEndianHeader(_ data: Data) -> Data? {
        guard let order = n64ByteOrder(data) else { return nil }
        var header = [UInt8](data.prefix(0x40))
        n64ToConsoleOrder(&header, from: order)
        return Data(header)
    }

    /// Whether this N64 cartridge boots through libdragon's open-source IPL3
    /// (the boot code every libdragon game has been built with since 2023),
    /// which the bundled core cannot run yet: the console's two processors
    /// lose step in its command queue and the game stops on its own "RSP
    /// CRASH" screen. Answered from the boot code's own banner,
    /// " Libdragon IPL3  Coded by Rasky ", which libdragon places inside the
    /// boot code (`boot/ipl3.c`, section `.banner`), so it is a fact about
    /// the file rather than a guess from its title or size.
    static func isLibdragonIPL3(_ data: Data) -> Bool {
        guard let order = n64ByteOrder(data), data.count >= 0x1000 else { return false }
        var boot = [UInt8](data.prefix(0x1000))
        n64ToConsoleOrder(&boot, from: order)
        return Data(boot).range(of: Data(" Libdragon IPL3 ".utf8)) != nil
    }

    /// Puts bytes of an N64 dump back in the console's own order, in place.
    /// `bytes` must start on a word boundary of the file and hold whole words,
    /// which every read of it does: the header, and the box-art hash's chunks.
    /// One copy of the reordering, so the header the importer reads and the
    /// bytes the box-art CRC hashes cannot come out of two different rules.
    static func n64ToConsoleOrder(_ bytes: inout [UInt8], from order: N64ByteOrder) {
        switch order {
        case .bigEndian:
            break
        case .halfwordSwapped:
            for i in stride(from: 0, to: bytes.count - 1, by: 2) {
                bytes.swapAt(i, i + 1)
            }
        case .wordSwapped:
            for i in stride(from: 0, to: bytes.count - 3, by: 4) {
                bytes.swapAt(i, i + 3)
                bytes.swapAt(i + 1, i + 2)
            }
        }
    }

    /// A Mega Drive cartridge: its header's system name begins "SEGA" at 0x100
    /// ("SEGA MEGA DRIVE", "SEGA GENESIS"), the bytes the later consoles' boot
    /// ROM checks before it will run a game (one space before it is also
    /// accepted, by the console and here). Read through `mdHeader`, so an
    /// `.smd` copier dump is checked on its de-interleaved bytes. A Mega-CD
    /// disc image carries the same header after "SEGADISCSYSTEM" and is not a
    /// cartridge, so it is refused.
    static func isValidMDFile(data: Data) -> Bool {
        guard let header = mdHeader(data) else { return false }
        let b = header.startIndex
        if header.count >= 14,
           header[b..<(b + 14)].elementsEqual("SEGADISCSYSTEM".utf8) { return false }
        // A 32X cartridge or a Sega Pico one carries "SEGA" at 0x100 too, and
        // BlastEm would start it as that machine (`detect_system_type`,
        // `load_media`), which the app does not offer: the 32X needs BIOS files
        // it never gets, and nothing says so. Refused at import with BlastEm's
        // own names (audit 2026-10-12).
        if isOtherSegaMachine(header: header) { return false }
        let sega = Array("SEGA".utf8)
        return header[(b + 0x100)..<(b + 0x104)].elementsEqual(sega)
            || header[(b + 0x101)..<(b + 0x105)].elementsEqual(sega)
    }

    /// BlastEm's own names for the 32X and the Pico in the system field at
    /// 0x100 (`detect_system_type`, `load_media`).
    private static let otherSegaMachines = ["SEGA 32X", "SEGA PICO", "SEGATOYS PICO", "SEGA TOYS PICO",
                                            "SAMSUNG PICO", "SEGA IAC", "IMA IKUNOUJYUKU", "IMA IKUNOJYUKU"]

    private static func isOtherSegaMachine(header: Data) -> Bool {
        let b = header.startIndex
        guard header.count >= 0x110 else { return false }
        let systemName = header[(b + 0x100)..<(b + 0x110)]
        return otherSegaMachines.contains { systemName.starts(with: $0.utf8) }
    }

    /// Whether a refused file is a 32X or Pico cartridge (telemetry only:
    /// `ImportFailureReason.otherConsoleCartridge`). Reads 16.5 KB at most.
    static func isOtherSegaMachineCartridge(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x4200), let header = mdHeader(head) else { return false }
        return isOtherSegaMachine(header: header)
    }

    /// The first 0x200 bytes of a Mega Drive cartridge as the console sees
    /// them (the vectors and the header), or nil if the data is too short.
    ///
    /// A plain dump is those bytes already. An `.smd` copier dump is not: a
    /// 512-byte header (byte 1 = 0x03, bytes 8 and 9 = 0xAA 0xBB, bytes 3 to 7
    /// zero, which is BlastEm's own `is_smd_format` test) is followed by 16 KB
    /// blocks that each hold the cartridge's odd bytes in their first half and
    /// its even bytes in the second. Recognised by its bytes, not its name, as
    /// the core does.
    ///
    /// A SPLIT `.smd` (byte 2 not zero: one cartridge cut across several
    /// files) answers nil, so it is refused at import: the core does not load
    /// one, and it says so through a fatal error that would end the app.
    static func mdHeader(_ data: Data) -> Data? {
        let b = data.startIndex
        guard data.count >= 0x200 else { return nil }
        let isSMD = data[b + 1] == 0x03 && data[b + 8] == 0xAA && data[b + 9] == 0xBB
            && (3...7).allSatisfy { data[b + $0] == 0 }
        guard isSMD else { return Data(data.prefix(0x200)) }
        guard data[b + 2] == 0, data.count >= 512 + 0x4000 else { return nil }
        let block = b + 512
        var header = [UInt8](repeating: 0, count: 0x200)
        for i in 0..<0x100 {
            header[i * 2]     = data[block + 0x2000 + i]
            header[i * 2 + 1] = data[block + i]
        }
        return Data(header)
    }

    /// The overseas name at 0x150, else the domestic one at 0x120 (both 48
    /// bytes). Headers pad words apart with runs of spaces ("SONIC THE
    /// HEDGEHOG" is stored with fifteen between two of its words), so every
    /// run becomes one space.
    private static func mdTitle(_ header: Data) -> String {
        let overseas = readASCII(header, 0x150, 0x180)
        let name = overseas.isEmpty ? readJISX0201(header, 0x120, 0x150) : overseas
        return name.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    /// Every position a SNES cartridge header's TITLE field can occupy, in the
    /// order MesenCE's own loader scores them (`BaseCartridge::LoadRom`, which
    /// reads its struct 0x10 bytes earlier, at the extended header).
    ///
    /// Four shapes multiply out: LoROM or HiROM, headerless or with a 512-byte
    /// copier header, and each of those again 4 MB in for the ExLoROM/ExHiROM
    /// carts (Tales of Phantasia, Star Ocean). Dropping the last four would
    /// reject exactly those games at import as "not a ROM", which is the kind of
    /// silent gap that only shows up in a support email.
    static let snesHeaderCandidates = [
        0x7FC0, 0x81C0, 0xFFC0, 0x101C0,
        0x407FC0, 0x4081C0, 0x40FFC0, 0x4101C0
    ]

    /// Locates the SNES cartridge header's TITLE field, or nil if the file does
    /// not look like a SNES ROM.
    ///
    /// The SNES has no magic number, which is why this is a search rather than a
    /// lookup. Two things vary:
    ///
    ///  - the header sits at 0x7FC0 on a LoROM cart and 0xFFC0 on a HiROM one,
    ///    and nothing outside the header itself says which;
    ///  - a `.smc` dump may carry a 512-byte copier header that shifts the whole
    ///    file, which is exactly why the same ROM ships as both `.sfc` and
    ///    `.smc`.
    ///
    /// The test at each candidate is the header's own checksum pair: bytes at
    /// +0x1C and +0x1E are a 16-bit checksum and its complement, so they must XOR
    /// to 0xFFFF. That is a genuine 16-bit test rather than a guess, and it is
    /// the same one every SNES emulator uses to choose a mapping.
    ///
    /// Every candidate is tried rather than deducing the copier header from the
    /// file size. The size rule (512 bytes over a multiple of 1 KB) is real, but
    /// it needs the WHOLE file, and a caller working from a prefix would measure
    /// its own read length instead. Trying both shifts costs a few more checksum
    /// tests and cannot be fooled by how much of the file the caller has.
    static func snesHeaderOffset(_ data: Data) -> Int? {
        var fallback: Int?
        for offset in snesHeaderCandidates {
            guard offset + 0x20 <= data.count else { continue }
            // Relative to the title: complement at +0x1C, checksum at +0x1E.
            let complement = readUInt16LE(data, offset + 0x1C)
            let checksum = readUInt16LE(data, offset + 0x1E)
            guard checksum != 0, complement != 0,
                  (checksum ^ complement) == 0xFFFF else { continue }
            // Two candidates can pass on the same file (a LoROM header can be
            // mirrored where HiROM's would sit). The title breaks the tie: a
            // real one is printable ASCII, padded with spaces.
            if looksLikeSNESTitle(data, at: offset) { return offset }
            if fallback == nil { fallback = offset }
        }
        return fallback
    }

    /// Whether the 21 bytes at `offset` read as a cartridge title rather than as
    /// code that happens to sit where a header would be.
    private static func looksLikeSNESTitle(_ data: Data, at offset: Int) -> Bool {
        guard offset + 21 <= data.count else { return false }
        // Printable means JIS X 0201: ASCII, or half-width katakana in
        // 0xA1-0xDF. Counting ASCII alone scored a Japanese cartridge's real
        // header at zero and let a mirrored candidate win the tie.
        var printable = 0
        for i in offset..<(offset + 21)
        where (data[i] >= 0x20 && data[i] < 0x7F) || (0xA1...0xDF).contains(data[i]) {
            printable += 1
        }
        return printable >= 18
    }

    static func isValidSNESFile(data: Data) -> Bool {
        snesHeaderOffset(data) != nil
    }

    /// Validates a Nintendo DS ROM header.
    ///
    /// A DS ROM is NOT reliably identified by the Nintendo logo at 0xC0:
    /// the DS boot ROM only verifies that logo on the real cartridge boot
    /// path, so homebrew built for flashcarts or the PassMe exploit
    /// frequently ships with that region blank or filled with code. A
    /// logo-only check therefore rejects a large share of homebrew.
    ///
    /// Instead we validate the ARM9/ARM7 cartridge header structurally.
    /// The header packs two code-binary descriptors (ROM offset, entry
    /// point, RAM load address, size) at 0x20 and 0x30. Their entry points
    /// and load addresses must land in known DS memory regions — a set of
    /// constraints a GB/GBC/GBA ROM cannot satisfy across all six address
    /// fields at once. The logo is kept only as a fast-accept path.
    /// The game's title from the DS cartridge banner, in the phone's language.
    ///
    /// Every DS cartridge carries a banner (its offset is at 0x68 of the
    /// header): an icon, and the title in Japanese, English, French, German,
    /// Italian and Spanish, 128 UTF-16 characters each, with Chinese added by
    /// banner version 2 and Korean by version 3. Each title is written on two
    /// or three lines: the name, an optional subtitle, and the publisher last
    /// ("Pokémon\nVersion Platine\nNintendo"). The publisher is dropped and
    /// the rest joined, which keeps "Version Platine" where a first-line-only
    /// read would have filed every Pokémon under "Pokémon".
    ///
    /// The language is the phone's first preferred one when the banner has it,
    /// then English, then Japanese (every banner has both). Nil when the banner
    /// is absent, points outside the file, or holds no printable title, in
    /// which case the caller keeps the 12-byte code name.
    static func ndsBannerTitle(_ data: Data,
                               preferredLanguages: [String] = LegacyTextEncoding.preferredLanguages) -> String? {
        guard data.count >= 0x200 else { return nil }
        let bannerOffset = Int(readUInt32LE(data, 0x68))
        // Version 1 holds six titles; the banner header itself is 0x20 bytes.
        guard bannerOffset >= 0x200, bannerOffset + 0x840 <= data.count else { return nil }
        let version = Int(readUInt16LE(data, bannerOffset)) & 0xFF
        var slots: [String: Int] = ["ja": 0x240, "en": 0x340, "fr": 0x440,
                                    "de": 0x540, "it": 0x640, "es": 0x740]
        if version >= 2, bannerOffset + 0x940 <= data.count { slots["zh"] = 0x840 }
        if version >= 3, bannerOffset + 0xA40 <= data.count { slots["ko"] = 0x940 }

        let wanted = preferredLanguages.first.map { tag -> String in
            String(tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        }
        for language in [wanted ?? "", "en", "ja"] {
            guard let slot = slots[language],
                  let title = bannerTitleField(data, at: bannerOffset + slot) else { continue }
            return title
        }
        return nil
    }

    /// One 0x100-byte UTF-16LE title field, reduced to the game's name.
    private static func bannerTitleField(_ data: Data, at offset: Int) -> String? {
        guard offset + 0x100 <= data.count else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(128)
        var i = offset
        while i + 1 < offset + 0x100 {
            let unit = UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
            if unit == 0 { break }
            units.append(unit)
            i += 2
        }
        guard !units.isEmpty else { return nil }
        let text = String(decoding: units, as: UTF16.self)
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        // Two lines: name and publisher. Three or more: name, subtitle(s), publisher.
        let name = lines.count >= 3 ? lines.dropLast().joined(separator: " ") : first
        return name.isEmpty ? nil : name
    }

    static func isValidNDSFile(data: Data) -> Bool {
        guard data.count >= 0x200 else { return false }

        // Fast path: a commercial DS cart carries the Nintendo logo at 0xC0.
        if matchesNintendoLogo(data, at: 0xC0) { return true }

        // Structural path: validate the ARM9/ARM7 header descriptors.
        let arm9RomOffset = readUInt32LE(data, 0x20)
        let arm9Entry     = readUInt32LE(data, 0x24)
        let arm9RamAddr   = readUInt32LE(data, 0x28)
        let arm9Size      = readUInt32LE(data, 0x2C)
        let arm7RomOffset = readUInt32LE(data, 0x30)
        let arm7Entry     = readUInt32LE(data, 0x34)
        let arm7RamAddr   = readUInt32LE(data, 0x38)
        let arm7Size      = readUInt32LE(data, 0x3C)

        // Code binaries are stored after the 0x200-byte header.
        guard arm9RomOffset >= 0x200, arm7RomOffset >= 0x200 else { return false }
        // ARM9 runs from main RAM (0x02000000-0x023FFFFF).
        guard isInMainRAM(arm9Entry), isInMainRAM(arm9RamAddr) else { return false }
        // ARM7 runs from main RAM or ARM7-WRAM (0x03000000-0x0380FFFF).
        guard isInARM7Space(arm7Entry), isInARM7Space(arm7RamAddr) else { return false }
        // Binary sizes must be non-zero and within a sane bound (4 MB RAM).
        guard (1...0x400000).contains(arm9Size),
              (1...0x400000).contains(arm7Size) else { return false }
        return true
    }

    /// The importer's gate: does this file look like a ROM for any console we
    /// run? Mapped rather than read, because a SNES header can sit 4 MB in and
    /// the old 0x200-byte read would have rejected every SNES ROM as "not a ROM".
    static func isValidROMFile(url: URL) -> Bool {
        // Checked BEFORE the file is mapped, on purpose: a PlayStation data
        // track is routinely several hundred megabytes (a PSP image up to 1.8
        // GB), and there is nothing in it this function could usefully read
        // anyway. A PSP `.iso`/`.pbp` passes here as a disc extension; which
        // console it is, the importer asks `ROMSystemType.resolve(url:)`.
        if ROMSystemType.from(fileExtension: url.pathExtension)?.isDiscBased == true {
            return true
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        // The Master System and the Game Gear have no magic to sniff
        // (`isValidSMSFile`), so for their two extensions the extension
        // decides, as it does for a disc, and the bytes only have to be the
        // core's minimum. Without this every `.sms` and `.gg` was refused here,
        // before anything else read it (found on device, 2026-10-09).
        if let system = ROMSystemType.from(fileExtension: url.pathExtension),
           system == .sms || system == .gg {
            return isValidSMSFile(data: data)
        }
        // `.md` is also Markdown's extension, so a `.md` file must BE a Mega
        // Drive cartridge: the other consoles' sniffs below are for a renamed
        // ROM, and the GBA's is one byte (0x96 at 0xB2), which UTF-8 Japanese,
        // Chinese or Korean text carries often (文 = E6 96 87). A note opened
        // from Files joined the library as a GBA game (audit 2026-10-11).
        // `.gen` and `.smd` keep the general rule: no other format uses them.
        if url.pathExtension.lowercased() == "md" {
            return isValidMDFile(data: data)
        }
        return isValidNESFile(data: data) || isValidN64File(data: data)
            || isValidNDSFile(data: data)
            || isValidGBFile(data: data) || isValidMDFile(data: data)
            || isValidSNESFile(data: data)
            || isValidGBAFile(data: data)
    }

    // MARK: - Helpers

    private static func matchesNintendoLogo(_ data: Data, at offset: Int) -> Bool {
        guard data.count >= offset + nintendoLogoPrefix.count else { return false }
        for (i, expected) in nintendoLogoPrefix.enumerated() {
            if data[offset + i] != expected { return false }
        }
        return true
    }

    /// Reads a little-endian UInt16 at `offset`. Returns 0 if out of range.
    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
    }

    /// Reads a little-endian UInt32 at `offset`. Returns 0 if out of range.
    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
             | UInt32(data[offset + 1]) << 8
             | UInt32(data[offset + 2]) << 16
             | UInt32(data[offset + 3]) << 24
    }

    /// DS main RAM: 0x02000000-0x023FFFFF.
    private static func isInMainRAM(_ address: UInt32) -> Bool {
        address >= 0x0200_0000 && address < 0x0240_0000
    }

    /// Memory the ARM7 may run from: DS main RAM or ARM7-WRAM
    /// (0x03000000-0x0380FFFF).
    private static func isInARM7Space(_ address: UInt32) -> Bool {
        isInMainRAM(address) || (address >= 0x0300_0000 && address < 0x0381_0000)
    }

    /// Reads an ASCII string from `data[start..<end]`, cut at the first NUL
    /// and trimmed of control and whitespace padding. Returns "" on any
    /// out-of-range or decode failure. The cut matters on the Game Boy, whose
    /// field holds a NUL-padded title followed by a manufacturer code: trimming
    /// only the ends kept the code glued to the title.
    private static func readASCII(_ data: Data, _ start: Int, _ end: Int) -> String {
        guard start >= 0, start < end, end <= data.count else { return "" }
        let field = data[start..<end].prefix { $0 != 0 }
        guard let raw = String(bytes: field, encoding: .ascii) else { return "" }
        return raw.trimmingCharacters(in: .controlCharacters)
                  .trimmingCharacters(in: .whitespaces)
    }

    /// The SNES internal name is JIS X 0201: ASCII plus half-width katakana in
    /// 0xA1-0xDF. Read as strict ASCII, every Japanese cartridge's title came
    /// back empty and the game was named after its file instead. Shift-JIS
    /// (CP932) contains JIS X 0201 as its single-byte half, so it decodes
    /// exactly those bytes; anything outside that range is not a title and
    /// returns "" as before.
    private static func readJISX0201(_ data: Data, _ start: Int, _ end: Int) -> String {
        guard start >= 0, start < end, end <= data.count else { return "" }
        let field = data[start..<end].prefix { $0 != 0 }
        guard field.allSatisfy({ $0 < 0x80 || (0xA1...0xDF).contains($0) }),
              let raw = String(bytes: field, encoding: .shiftJIS) else { return "" }
        return raw.trimmingCharacters(in: .controlCharacters)
                  .trimmingCharacters(in: .whitespaces)
    }

    /// The library's identity key for a file: what `romHash` stores, what the
    /// duplicate guard compares, and what `replaceROMFile` checks before it
    /// will swap a game's file.
    ///
    /// Cartridges hash whole, as they always have. **Discs hash a bounded
    /// prefix plus their size**, and that is a correctness fix rather than an
    /// optimisation: a PlayStation data track runs to several hundred
    /// megabytes, and this runs on the import path, on the duplicate probe, on
    /// the post-copy verification and once per entry of a multi-ROM zip.
    /// Hashing all of it several times would read gigabytes to answer "have I
    /// seen this file before".
    ///
    /// The prefix is genuinely identifying rather than arbitrary: the first
    /// megabytes of a disc image hold the volume descriptor, the root
    /// directory and SYSTEM.CNF, so two different games differ inside it. The
    /// size is mixed in so two dumps that share a prefix but not a length
    /// cannot collide.
    ///
    /// This is NOT the RetroAchievements hash and does not try to be. RA hashes
    /// a disc by the executable named in SYSTEM.CNF, through rcheevos, so that
    /// the same game in `.cue` and `.chd` form resolves to one set. This key
    /// deliberately does the opposite: it identifies a FILE, because its job is
    /// to stop the same file being imported twice.
    private static func identityHash(data: Data, fileSize: Int64, system: ROMSystemType) -> String {
        guard system.isDiscBased else { return sha256(data: data) }
        let prefix = data.prefix(discHashPrefixBytes)
        // "ps1-disc" for the PSP's images too, deliberately: renaming the seed
        // would re-key every PlayStation game already in a library and let the
        // same disc in twice. A PSP image and a PlayStation disc never share
        // four megabytes and a size, so one seed cannot make them collide.
        var seed = Data("ps1-disc:\(fileSize):".utf8)
        seed.append(prefix)
        return sha256(data: seed)
    }

    /// Four megabytes. Comfortably past the 32 KB where the ISO 9660 primary
    /// volume descriptor begins and past the root directory and SYSTEM.CNF that
    /// follow it, while staying a bounded read on the oldest device we support.
    private static let discHashPrefixBytes = 4 * 1024 * 1024

    private static func sha256(data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
