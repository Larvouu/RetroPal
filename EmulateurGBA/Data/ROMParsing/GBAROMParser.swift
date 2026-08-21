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
        default:             return nil
        }
    }

    /// Every extension the importer accepts for this system, used by the file
    /// pickers and the ZIP extractor so the three can never drift.
    static let allFileExtensions: [String] = ["gba", "gb", "gbc", "nds", "sfc", "smc", "nes"]
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

    static func parse(fileURL: URL) -> ROMInfo? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        return parse(data: data,
                     fileSize: Int64(data.count),
                     systemHint: ROMSystemType.from(fileExtension: fileURL.pathExtension))
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
            title = readASCII(data, 0x000, 0x00C)
            gameCode = readASCII(data, 0x00C, 0x010)
        case .snes:
            // The 21-byte title sits inside the cartridge header, whose position
            // depends on the mapping (LoROM vs HiROM) and on whether a copier
            // header shifts everything by 512 bytes. `snesHeaderOffset` finds it.
            title = snesHeaderOffset(data).map { readASCII(data, $0, $0 + 21) } ?? ""
            gameCode = ""
        case .nes:
            // An iNES header carries no title. The filename is the only name a
            // NES ROM has, which is also true of GB and GBC.
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
        }

        return ROMInfo(title: title.isEmpty ? "Unknown Game" : title,
                       gameCode: gameCode,
                       sha256: sha256(data: data),
                       fileSize: fileSize,
                       systemType: system)
    }

    /// Reads the 4-character cartridge game code from a ROM header (GBA at
    /// 0xAC, NDS at 0xC; GB/GBC have no unique code). Reads only the header
    /// bytes — the code survives renaming AND NDS trimming, which is what
    /// box-art matching uses it for.
    static func gameCode(url: URL, system: ROMSystemType) -> String? {
        guard system == .gba || system == .nds,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x200) else { return nil }
        let code = system == .gba ? readASCII(header, 0x0AC, 0x0B0)
                                  : readASCII(header, 0x00C, 0x010)
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
        case .nds:      title = readASCII(header, 0x000, 0x00C)
        case .gb, .gbc: title = readASCII(header, 0x134, 0x143)
        case .gba:      title = readASCII(header, 0x0A0, 0x0AC)
        case .snes:
            // The SNES header is at least 32 KB into the file and can be 4 MB
            // in, so the 0x200 bytes read above cannot reach it. Map instead.
            guard let full = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let offset = snesHeaderOffset(full) else { return nil }
            title = readASCII(full, offset, offset + 21)
        case .nes:      title = ""   // an iNES header carries no title
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
        if let hint = ROMSystemType.from(fileExtension: url.pathExtension) {
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
        if let hint = hint, isValidFile(data: data, system: hint) {
            return hint
        }

        // No usable extension, or the extension disagreed with the bytes.
        // Sniff most-specific first: NES (4-byte magic) and NDS (strict
        // structural check), then GB/GBC (logo), then SNES (a checksum pair,
        // which is weaker than a magic number but still a real test), then GBA
        // (a single marker byte — the weakest test, so it runs last to avoid
        // swallowing anything else).
        if isValidNESFile(data: data) { return .nes }
        if isValidNDSFile(data: data) { return .nds }
        if isValidGBFile(data: data) {
            // 0x143 = CGB flag: 0x80 = CGB-aware, 0xC0 = CGB-only.
            let cgbFlag = data.count > 0x143 ? data[0x143] : 0
            return (cgbFlag == 0x80 || cgbFlag == 0xC0) ? .gbc : .gb
        }
        if isValidSNESFile(data: data) { return .snes }
        if isValidGBAFile(data: data) { return .gba }

        // Nothing matched the bytes. If the file still carried a known ROM
        // extension, honor it so an unusual but correctly-named ROM reaches
        // the right core rather than being rejected outright.
        return hint
    }

    private static func isValidFile(data: Data, system: ROMSystemType) -> Bool {
        switch system {
        case .nds:      return isValidNDSFile(data: data)
        case .gb, .gbc: return isValidGBFile(data: data)
        case .gba:      return isValidGBAFile(data: data)
        case .snes:     return isValidSNESFile(data: data)
        case .nes:      return isValidNESFile(data: data)
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
        var printable = 0
        for i in offset..<(offset + 21) where data[i] >= 0x20 && data[i] < 0x7F {
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
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return isValidNESFile(data: data) || isValidNDSFile(data: data)
            || isValidGBFile(data: data) || isValidSNESFile(data: data)
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

    /// Reads an ASCII string from `data[start..<end]`, trimming control and
    /// whitespace padding. Returns "" on any out-of-range or decode failure.
    private static func readASCII(_ data: Data, _ start: Int, _ end: Int) -> String {
        guard start >= 0, start < end, end <= data.count else { return "" }
        guard let raw = String(bytes: data[start..<end], encoding: .ascii) else { return "" }
        return raw.trimmingCharacters(in: .controlCharacters)
                  .trimmingCharacters(in: .whitespaces)
    }

    private static func sha256(data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
