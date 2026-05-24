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

    /// Maps a file extension to the system it declares. Returns nil for
    /// anything that isn't a recognized ROM extension.
    static func from(fileExtension ext: String) -> ROMSystemType? {
        ROMSystemType(rawValue: ext.lowercased())
    }
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

    /// Cheap system-type probe. With a known file extension this answers
    /// without touching the file at all; otherwise it reads only the
    /// 0x200-byte header. No SHA256, no full mmap. Used on hot paths such
    /// as launch-time re-validation where the full ROMInfo is not needed.
    static func detectSystemType(url: URL) -> ROMSystemType? {
        if let hint = ROMSystemType.from(fileExtension: url.pathExtension) {
            return hint
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x200) else { return nil }
        return detectSystemType(data: header)
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
        // Sniff: NDS first (strict structural check), then GB/GBC (logo),
        // then GBA (single marker byte — the weakest test, so it runs last
        // to avoid swallowing GB/NDS ROMs).
        if isValidNDSFile(data: data) { return .nds }
        if isValidGBFile(data: data) {
            // 0x143 = CGB flag: 0x80 = CGB-aware, 0xC0 = CGB-only.
            let cgbFlag = data.count > 0x143 ? data[0x143] : 0
            return (cgbFlag == 0x80 || cgbFlag == 0xC0) ? .gbc : .gb
        }
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

    static func isValidROMFile(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        guard let data = try? handle.read(upToCount: 0x200) else { return false }
        return isValidNDSFile(data: data) || isValidGBFile(data: data) || isValidGBAFile(data: data)
    }

    // MARK: - Helpers

    private static func matchesNintendoLogo(_ data: Data, at offset: Int) -> Bool {
        guard data.count >= offset + nintendoLogoPrefix.count else { return false }
        for (i, expected) in nintendoLogoPrefix.enumerated() {
            if data[offset + i] != expected { return false }
        }
        return true
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
