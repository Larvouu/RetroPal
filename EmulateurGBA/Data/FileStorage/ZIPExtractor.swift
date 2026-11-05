//
//  ZIPExtractor.swift
//  EmulateurGBA
//
//  Minimal ZIP extraction using Foundation's built-in support.
//  Lists the game files (.gba, .gb, .gbc, .nds) inside a ZIP archive and
//  extracts them one entry at a time.
//

import Foundation
import Compression

enum ZIPExtractorError: Error {
    case cannotReadZIP
    case noROMFound
    case extractionFailed
    /// The archive is valid and we cannot read it: it uses a compression
    /// method beyond store and deflate (LZMA, BZIP2, Deflate64, Zstandard).
    /// Distinct from `extractionFailed` because the honest sentence is
    /// different: nothing is broken, and re-zipping fixes it.
    case unsupportedCompression
    /// Password-protected entry (general-purpose bit 0). We cannot ask for a
    /// password and would not want to, so this is its own answer.
    case encryptedArchive
}

enum ZIPExtractor {
    /// Full entry names (including any folder prefix) of the ROM files
    /// (every extension in `ROMSystemType.allFileExtensions`) inside the
    /// archive, in archive order: the cartridges when there are any, else the
    /// disc parts. The rules (cartridges win, a README is not a game, a `.bin`
    /// may be a Mega Drive cartridge) are `ArchiveGameRules`, shared with the
    /// other archive formats since 2026-10-27.
    static func romEntryNames(in zipURL: URL) throws -> [String] {
        let data = try loadData(zipURL)
        let entries = romEntries(in: data)
        try requireReadableMethods(entries)
        return ArchiveGameRules.entryNames(entries.map(\.ruleEntry), bytes: bytesReader(entries, in: data))
    }

    /// The GAMES an archive holds, rather than the files it holds.
    ///
    /// This is the difference between offering someone a choice of fifty-eight
    /// files and telling them they have Tomb Raider. The archive is opened and
    /// parsed ONCE, and only the descriptors are decompressed: a `.cue` is a few
    /// hundred bytes, so grouping a four-hundred-megabyte archive costs nothing
    /// until something is actually imported.
    static func gameEntries(in zipURL: URL) throws
    -> (discs: [DiscNameGroup], cartridges: [String], gaps: [DiscNameGap]) {
        let data = try loadData(zipURL)
        let entries = romEntries(in: data)
        try requireReadableMethods(entries)
        return ArchiveGameRules.games(entries.map(\.ruleEntry), bytes: bytesReader(entries, in: data))
    }

    /// The rules read some entries' BYTES (a `.cue`, a `.md` or `.bin` that may
    /// be a cartridge), through `bytesReader`, which answers nil on a method
    /// this reader does not implement. So an LZMA zip's `.md` was taken for a
    /// README ("no game in this ZIP") and its `.cue` read as empty, the `.bin`
    /// then offered as a second game; the libarchive fallback (`GameArchive`)
    /// only runs on a THROWN `unsupportedCompression` (audit, 2026-10-29). Any
    /// game file in another method sends the whole zip there, which reads them all.
    private static func requireReadableMethods(_ entries: [ZIPEntry]) throws {
        if entries.contains(where: { $0.method != 0 && $0.method != 8 }) {
            throw ZIPExtractorError.unsupportedCompression
        }
    }

    /// An entry's bytes for the rules, decompressed on demand from the mapped
    /// archive (the rules ask only for small entries: descriptors, and `.md` /
    /// `.bin` no larger than a cartridge).
    private static func bytesReader(_ entries: [ZIPEntry], in data: Data) -> (String) -> Data? {
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return { name in byName[name].flatMap { try? extractEntry($0, from: data) } }
    }

    /// Extract several named entries into ONE fresh temp directory, parsing the
    /// archive a single time.
    ///
    /// The per-entry `extractROM` re-opens and re-parses the archive on every
    /// call, which is fine for one cartridge and absurd for a disc: Tomb Raider
    /// would have parsed the same central directory fifty-eight times.
    static func extractEntries(named names: [String], from zipURL: URL) throws -> [URL] {
        let data = try loadData(zipURL)
        let byName = Dictionary(romEntries(in: data).map { ($0.name, $0) },
                                uniquingKeysWith: { a, _ in a })
        let tempDir = try GameArchive.makeScratchFolder()

        var written: [URL] = []
        // A failure leaves nothing in tmp: the caller removes the folder only
        // once this returns, and a disc stopped by a full phone otherwise kept
        // its written tracks there (audit, 2026-10-29).
        do {
            for name in names {
                guard let entry = byName[name] else { throw ZIPExtractorError.noROMFound }
                // Flattened: an archive's folder structure is its own, and a game's
                // descriptor names its tracks WITHOUT a path, so they have to end up
                // side by side or the core cannot find them.
                let dest = tempDir.appendingPathComponent(
                    URL(fileURLWithPath: entry.name).lastPathComponent)
                try writeEntry(entry, from: data, to: dest)
                written.append(dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
        return written
    }

    /// Extracts one ROM entry (by its full entry name, as returned by
    /// `romEntryNames`) into a fresh temp directory and returns the file URL.
    static func extractROM(named name: String, from zipURL: URL) throws -> URL {
        let data = try loadData(zipURL)
        guard let entry = romEntries(in: data).first(where: { $0.name == name }) else {
            throw ZIPExtractorError.noROMFound
        }

        let tempDir = try GameArchive.makeScratchFolder()

        let filename = URL(fileURLWithPath: entry.name).lastPathComponent
        let destURL = tempDir.appendingPathComponent(filename)
        // Written through `writeEntry`, the disc path's: a stored entry is a
        // slice of the mapped archive, a deflated one past the streaming
        // threshold is inflated to the file a megabyte at a time. A Nintendo
        // 3DS game is a single cartridge entry of 1 to 4 GB (2026-10-19), and
        // inflating it whole in memory, as this did, ends the app. Under the
        // threshold it is the same in-memory inflate as before. Streamed to the
        // file, a failure (a full phone) left the part written in tmp, gigabytes
        // for a 3DS game: removed (audit, 2026-10-29).
        do {
            try writeEntry(entry, from: data, to: destURL)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }

        return destURL
    }

    /// Every file entry of the archive, written under `directory` at its own
    /// relative path (folders created as needed), and every folder entry
    /// (`name/`) created, empty ones included. For an archive that IS a
    /// folder, a Nintendo 3DS game's save data (`CTRSaveData`), where the
    /// structure is the content: an extdata the core opens only if its `boss/`
    /// folder exists, usually empty (audit, 2026-10-20). Returns the relative
    /// paths of the files written.
    ///
    /// A name that would land outside `directory` (absolute, or with a `..`
    /// component) refuses the whole archive: a save import must never write
    /// anywhere but where it was told.
    static func extractAll(from zipURL: URL, to directory: URL) throws -> [String] {
        let data = try loadData(zipURL)
        var entries = (try? findEntriesFromCentralDirectory(in: data, keepingFolders: true)) ?? []
        if entries.isEmpty { entries = findEntriesFromLocalHeaders(in: data, keepingFolders: true) }
        var written: [String] = []
        for entry in entries {
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: true)
            guard !entry.name.hasPrefix("/"), !parts.isEmpty,
                  !parts.contains(where: { $0 == ".." || $0 == "." }) else {
                throw ZIPExtractorError.cannotReadZIP
            }
            let relative = parts.joined(separator: "/")
            let dest = directory.appendingPathComponent(relative)
            if entry.name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try writeEntry(entry, from: data, to: dest)
            written.append(relative)
        }
        return written
    }

    /// Mapped, not loaded: collection zips can run to hundreds of MB, and
    /// per-entry extraction re-opens the archive once per game.
    private static func loadData(_ zipURL: URL) throws -> Data {
        do {
            return try Data(contentsOf: zipURL, options: .mappedIfSafe)
        } catch {
            throw ZIPExtractorError.cannotReadZIP
        }
    }

    /// ROM entries of the archive, in archive order. Tries the Central
    /// Directory first (handles data descriptors), falls back to local headers.
    private static func romEntries(in data: Data) -> [ZIPEntry] {
        var entries = (try? findEntriesFromCentralDirectory(in: data)) ?? []
        if entries.isEmpty {
            entries = findEntriesFromLocalHeaders(in: data)
        }
        return entries.filter { ArchiveGameRules.isGameFile($0.name) }
    }

    // MARK: - ZIP Parsing (minimal, handles store + deflate)

    private struct ZIPEntry {
        let name: String
        let compressedSize: Int
        let uncompressedSize: Int
        let method: UInt16       // 0=store, 8=deflate
        let dataOffset: Int      // offset to compressed data in ZIP
        /// General-purpose bit flag. Bit 0 = encrypted, bit 11 = UTF-8 name.
        let flags: UInt16

        var isEncrypted: Bool { flags & 0x0001 != 0 }

        var ruleEntry: ArchiveGameRules.Entry { .init(name: name, size: uncompressedSize) }
    }

    // MARK: - Entry names

    /// Decode a ZIP entry name. The format offers three answers and one
    /// legacy, and they are tried in that order:
    ///
    /// 1. **General-purpose bit 11 (0x0800)**: the name is UTF-8. macOS
    ///    Archive Utility and most current archivers set it.
    /// 2. **The Info-ZIP Unicode Path extra field (0x7075)**: a UTF-8 copy of
    ///    the name beside a CRC-32 of the raw header name, trusted only when
    ///    that CRC matches (APPNOTE 4.6.9). WinRAR, WinZip and Info-ZIP write
    ///    it, and it is authoritative when present.
    /// 3. **Strict UTF-8 with no flag**, because plenty of tools write UTF-8
    ///    without flagging it (`/usr/bin/zip` among them), and valid UTF-8 is
    ///    unambiguous enough to trust.
    /// 4. **The legacy codepage.** Windows Explorer's "Compress to ZIP" and
    ///    7-Zip both write names in the machine's OEM codepage with no flag:
    ///    CP932 on Japanese Windows, CP949 Korean, CP950 Taiwan, CP936 China,
    ///    CP850 Western Europe, CP437 US. Nothing in the archive says which.
    ///    So we do what Windows itself does when reading: the codepage of
    ///    the user's own language first. That chain lives in
    ///    `LegacyTextEncoding`, shared with the `.cue` and `.m3u` readers,
    ///    and the reason it is ordered that way is written there: a Shift-JIS
    ///    guess for everyone turned a French `Pokémon.gba` into `PokＮon.gba`.
    static func decodeEntryName(_ nameData: Data, flags: UInt16, extra: Data?,
                                preferredLanguages: [String] = LegacyTextEncoding.preferredLanguages) -> String {
        if flags & 0x0800 != 0, let utf8 = String(data: nameData, encoding: .utf8) {
            return utf8
        }
        if let unicodePath = unicodePathExtraField(in: extra, rawName: nameData) {
            return unicodePath
        }
        return LegacyTextEncoding.decode(nameData, preferredLanguages: preferredLanguages)
    }

    /// The UTF-8 name from an Info-ZIP Unicode Path extra field (0x7075), or
    /// nil when the block is absent, is a version we do not know, or its CRC
    /// does not match the raw header name (the spec says ignore it then: the
    /// header name was edited after the block was written).
    ///
    /// Layout (APPNOTE 4.6.9): tag u16 · size u16 · version u8 (= 1) ·
    /// CRC-32 u32 of the header name bytes · UTF-8 name. Extra fields are a
    /// sequence of such tag/size blocks, walked here on a plain byte array so
    /// no offset arithmetic depends on `Data`'s index base.
    static func unicodePathExtraField(in extra: Data?, rawName: Data) -> String? {
        guard let extra = extra, !extra.isEmpty else { return nil }
        let bytes = [UInt8](extra)
        var offset = 0
        while offset + 4 <= bytes.count {
            let tag = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let size = Int(UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8))
            let body = offset + 4
            guard body + size <= bytes.count else { return nil }
            if tag == 0x7075, size >= 5 {
                let version = bytes[body]
                let crc = UInt32(bytes[body + 1])
                    | (UInt32(bytes[body + 2]) << 8)
                    | (UInt32(bytes[body + 3]) << 16)
                    | (UInt32(bytes[body + 4]) << 24)
                if version == 1, crc == crc32(rawName) {
                    let nameBytes = Data(bytes[(body + 5)..<(body + size)])
                    return String(data: nameBytes, encoding: .utf8)
                }
                return nil
            }
            offset = body + size
        }
        return nil
    }

    /// Standard CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320), the
    /// checksum ZIP uses everywhere. Written out rather than imported: a
    /// twelve-line table beats a dependency for one field.
    private static let crc32Table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = crc32Table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }

    /// Read a little-endian UInt32, or nil if the range is not inside `data`.
    ///
    /// **Bounds-checked, and composed byte by byte on purpose.** Every offset
    /// here comes from the file being parsed, so it is untrusted: `Data.subdata`
    /// TRAPS on an out-of-range range rather than throwing, which turned a
    /// malformed archive into a crash instead of a message. The bytes are
    /// assembled explicitly rather than with `load(as:)`, which requires an
    /// alignment this buffer cannot be given, and the shifts state ZIP's
    /// little-endian layout rather than inheriting the host's.
    private static func readU32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let b = [UInt8](data.subdata(in: offset..<offset+4))
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    /// Read a little-endian UInt64, or nil if the range is not inside `data`.
    private static func readU64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(data[data.startIndex + offset + i]) }
        return v
    }

    /// The data of the ZIP64 extended-information block (header ID 0x0001) in
    /// an entry's extra field, or nil.
    private static func zip64ExtraBlock(_ extra: Data) -> Data? {
        var at = 0
        while at + 4 <= extra.count {
            guard let id = readU16(extra, at: at), let size = readU16(extra, at: at + 2) else { return nil }
            if id == 0x0001 { return slice(extra, at: at + 4, count: Int(size)) }
            at += 4 + Int(size)
        }
        return nil
    }

    /// A 64-bit value from the file as an offset, a size or a count that can
    /// be real: never more than the file itself. nil otherwise, so the caller
    /// treats it as the malformed field it is instead of trapping on it.
    private static func withinFile(_ value: UInt64?, _ data: Data) -> Int? {
        guard let value, value <= UInt64(data.count) else { return nil }
        return Int(value)
    }

    /// Read a little-endian UInt16, or nil if the range is not inside `data`.
    private static func readU16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        let b = [UInt8](data.subdata(in: offset..<offset+2))
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    /// A bounds-checked slice. Same reason as the readers above.
    private static func slice(_ data: Data, at offset: Int, count: Int) -> Data? {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else { return nil }
        return data.subdata(in: offset..<offset+count)
    }

    /// Parse entries from the Central Directory (reliable, handles data descriptors).
    /// `keepingFolders`: folder entries (`name/`) too, for `extractAll` only;
    /// every ROM path reads the files alone, as it always has.
    private static func findEntriesFromCentralDirectory(in data: Data,
                                                        keepingFolders: Bool = false) throws -> [ZIPEntry] {
        guard let eocdOffset = findEOCD(in: data),
              let cdOffsetRaw = readU32(data, at: eocdOffset + 16),
              let cdEntriesRaw = readU16(data, at: eocdOffset + 10) else {
            throw ZIPExtractorError.cannotReadZIP
        }

        var cdOffset = Int(cdOffsetRaw)   // offset of central directory
        var cdEntries = Int(cdEntriesRaw) // total entries
        // ZIP64 (APPNOTE 4.3.14-15): an archive over 4 GB, or with more than
        // 65,535 entries, saturates these fields and keeps the real ones in
        // the ZIP64 end record, found through the locator just before the end
        // record. A collection of PSP games is one (audit 2026-10-27).
        if cdOffsetRaw == 0xFFFF_FFFF || cdEntriesRaw == 0xFFFF,
           readU32(data, at: eocdOffset - 20) == 0x07064b50,
           let zip64EndOffset = withinFile(readU64(data, at: eocdOffset - 20 + 8), data),
           readU32(data, at: zip64EndOffset) == 0x06064b50,
           let entries64 = withinFile(readU64(data, at: zip64EndOffset + 32), data),
           let offset64 = withinFile(readU64(data, at: zip64EndOffset + 48), data) {
            cdEntries = entries64
            cdOffset = offset64
        }

        var entries: [ZIPEntry] = []
        var offset = cdOffset

        for _ in 0..<cdEntries {
            guard offset + 46 <= data.count else { break }

            // Central directory file header signature: 0x02014b50
            guard readU32(data, at: offset) == 0x02014b50,
                  let flags = readU16(data, at: offset + 8),
                  let method = readU16(data, at: offset + 10),
                  let compressedSizeRaw = readU32(data, at: offset + 20),
                  let uncompressedSizeRaw = readU32(data, at: offset + 24),
                  let nameLengthRaw = readU16(data, at: offset + 28),
                  let extraLengthRaw = readU16(data, at: offset + 30),
                  let commentLengthRaw = readU16(data, at: offset + 32),
                  let localHeaderOffsetRaw = readU32(data, at: offset + 42) else { break }

            var compressedSize = Int(compressedSizeRaw)
            var uncompressedSize = Int(uncompressedSizeRaw)
            let nameLength = Int(nameLengthRaw)
            let extraLength = Int(extraLengthRaw)
            let commentLength = Int(commentLengthRaw)
            var localHeaderOffset = Int(localHeaderOffsetRaw)

            guard let nameData = slice(data, at: offset + 46, count: nameLength) else { break }
            let extraData = slice(data, at: offset + 46 + nameLength, count: extraLength)
            // ZIP64 (APPNOTE 4.5.3): each saturated field is in the 0x0001
            // extra block, in this order, and only the saturated ones are.
            if let extra = extraData,
               uncompressedSizeRaw == 0xFFFF_FFFF || compressedSizeRaw == 0xFFFF_FFFF
                || localHeaderOffsetRaw == 0xFFFF_FFFF,
               let block = zip64ExtraBlock(extra) {
                var at = 0
                func next() -> UInt64? {
                    guard let v = readU64(block, at: at) else { return nil }
                    at += 8
                    return v
                }
                // Each one taken only when it can be real: a compressed size or
                // an offset inside the file, a size a game can have. A crafted
                // value trapped `Int(_:)` (2^63 and up) or the additions after
                // it (audit, 2026-10-29); such an entry is now skipped below,
                // as an unreadable local header is.
                if uncompressedSizeRaw == 0xFFFF_FFFF, let v = next() {
                    uncompressedSize = v <= UInt64(Int32.max) * 64 ? Int(v) : -1
                }
                if compressedSizeRaw == 0xFFFF_FFFF, let v = next() { compressedSize = withinFile(v, data) ?? -1 }
                if localHeaderOffsetRaw == 0xFFFF_FFFF, let v = next() { localHeaderOffset = withinFile(v, data) ?? -1 }
            }
            let name = decodeEntryName(nameData, flags: flags, extra: extraData)

            // Compute data offset from local file header. A header we cannot
            // read costs us THIS entry and not the archive: `break` here would
            // throw away every later game in a collection zip because one of
            // them was malformed.
            let localNameLen = readU16(data, at: localHeaderOffset + 26)
            let localExtraLen = readU16(data, at: localHeaderOffset + 28)
            let dataOffset = localHeaderOffset + 30
                + Int(localNameLen ?? 0) + Int(localExtraLen ?? 0)

            if localNameLen != nil, localExtraLen != nil, compressedSize >= 0, uncompressedSize >= 0,
               keepingFolders || !name.hasSuffix("/") {
                entries.append(ZIPEntry(
                    name: name,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    method: method,
                    dataOffset: dataOffset,
                    flags: flags
                ))
            }

            offset += 46 + nameLength + extraLength + commentLength
        }

        return entries
    }

    /// Scan backwards from end of data to find the End of Central Directory record.
    private static func findEOCD(in data: Data) -> Int? {
        // EOCD is at least 22 bytes, scan backwards up to 65KB (max comment size)
        let maxScan = min(data.count, 65557)
        for i in stride(from: 22, through: maxScan, by: 1) {
            let offset = data.count - i
            if readU32(data, at: offset) == 0x06054b50 { return offset }
        }
        return nil
    }

    /// Fallback: parse entries from local file headers (doesn't handle data descriptors).
    private static func findEntriesFromLocalHeaders(in data: Data, keepingFolders: Bool = false) -> [ZIPEntry] {
        var entries: [ZIPEntry] = []
        var offset = 0

        while offset + 30 <= data.count {
            guard readU32(data, at: offset) == 0x04034b50,
                  let flags = readU16(data, at: offset + 6),
                  let method = readU16(data, at: offset + 8),
                  let compressedSizeRaw = readU32(data, at: offset + 18),
                  let uncompressedSizeRaw = readU32(data, at: offset + 22),
                  let nameLengthRaw = readU16(data, at: offset + 26),
                  let extraLengthRaw = readU16(data, at: offset + 28) else { break }

            let compressedSize = Int(compressedSizeRaw)
            let uncompressedSize = Int(uncompressedSizeRaw)
            let nameLength = Int(nameLengthRaw)
            let extraLength = Int(extraLengthRaw)

            guard let nameData = slice(data, at: offset + 30, count: nameLength) else { break }
            let extraData = slice(data, at: offset + 30 + nameLength, count: extraLength)
            let name = decodeEntryName(nameData, flags: flags, extra: extraData)

            let dataOffset = offset + 30 + nameLength + extraLength

            if name.hasSuffix("/") ? keepingFolders : compressedSize > 0 {
                entries.append(ZIPEntry(
                    name: name,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    method: method,
                    dataOffset: dataOffset,
                    flags: flags
                ))
            }

            offset = dataOffset + compressedSize
        }

        return entries
    }

    private static func extractEntry(_ entry: ZIPEntry, from data: Data) throws -> Data {
        try check(entry)
        guard let compressed = slice(data, at: entry.dataOffset, count: entry.compressedSize) else {
            throw ZIPExtractorError.cannotReadZIP
        }

        switch entry.method {
        case 0: // Store (no compression)
            return compressed
        case 8: // Deflate
            return try inflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw ZIPExtractorError.unsupportedCompression
        }
    }

    /// What an entry we cannot read is, said precisely.
    ///
    /// Store and deflate are the two methods this reader implements, and that
    /// is a deliberate limit rather than a defect. **But "this ZIP couldn't be
    /// opened" was the wrong sentence for it**: the archive is perfectly valid,
    /// nothing is corrupt, and the person only needs to know that the
    /// compression method is not one we read. 7-Zip and WinRAR both write
    /// LZMA, BZIP2 and Deflate64 into `.zip` containers, so this is a normal
    /// file to meet, not an edge case.
    private static func check(_ entry: ZIPEntry) throws {
        if entry.isEncrypted { throw ZIPExtractorError.encryptedArchive }
        guard entry.method == 0 || entry.method == 8 else {
            throw ZIPExtractorError.unsupportedCompression
        }
    }

    /// Above this, an entry is inflated STRAIGHT TO DISK in chunks instead of
    /// being built whole in memory.
    ///
    /// The number is chosen to leave every console that shipped before the
    /// PlayStation on the path it has always used: the largest cartridge this
    /// app loads is a 32 MB DS card, so nothing below the disc era can reach
    /// the streaming branch and nothing below the disc era changes.
    ///
    /// It matters because a disc is a different order of size. The data track
    /// of a real Tomb Raider archive is 293 MB, and holding that as one
    /// allocation on the oldest device we support, an A11, is how an import
    /// gets the app killed rather than merely being slow.
    private static let streamingInflateThreshold = 32 * 1024 * 1024

    /// Write one entry to `dest`, choosing how by size.
    private static func writeEntry(_ entry: ZIPEntry, from data: Data, to dest: URL) throws {
        try check(entry)
        let offset = entry.dataOffset, count = entry.compressedSize
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw ZIPExtractorError.cannotReadZIP
        }
        // A small entry is built in memory, as before: bounded by the threshold.
        if entry.method == 8, entry.uncompressedSize <= streamingInflateThreshold {
            guard let compressed = slice(data, at: offset, count: count) else {
                throw ZIPExtractorError.cannotReadZIP
            }
            try inflate(compressed, expectedSize: entry.uncompressedSize).write(to: dest)
            return
        }
        // A large one is read straight from the MAPPED archive through a
        // pointer, never through `slice`: `subdata` COPIES, so a 1.8 GB PSP game
        // stored in a zip was copied whole into memory before being written,
        // and a large compressed one had its whole compressed range copied
        // before the streaming inflate even began (audit 2026-10-27). Mapped
        // pages are the file's, which the system can drop again under pressure.
        try data.withUnsafeBytes { (archive: UnsafeRawBufferPointer) in
            guard let base = archive.baseAddress else { throw ZIPExtractorError.cannotReadZIP }
            let source = UnsafeRawBufferPointer(start: base + offset, count: count)
            switch entry.method {
            case 0:
                try writeStored(source, to: dest)
            case 8:
                try inflateToFile(source, expectedSize: entry.uncompressedSize, dest: dest)
            default:
                throw ZIPExtractorError.unsupportedCompression
            }
        }
    }

    /// A stored entry, a megabyte at a time, so peak memory is the piece and
    /// not the entry.
    private static func writeStored(_ source: UnsafeRawBufferPointer, to dest: URL) throws {
        guard FileManager.default.createFile(atPath: dest.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: dest) else {
            throw ZIPExtractorError.extractionFailed
        }
        defer { try? handle.close() }
        let piece = 1 << 20
        var at = 0
        while at < source.count {
            let n = min(piece, source.count - at)
            try autoreleasepool {
                try handle.write(contentsOf: Data(bytes: source.baseAddress! + at, count: n))
            }
            at += n
        }
    }

    /// Inflate to a file a megabyte at a time, so peak memory is the chunk and
    /// not the track.
    private static func inflateToFile(_ compressed: UnsafeRawBufferPointer, expectedSize: Int, dest: URL) throws {
        guard FileManager.default.createFile(atPath: dest.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: dest) else {
            throw ZIPExtractorError.extractionFailed
        }
        defer { try? handle.close() }

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZIPExtractorError.extractionFailed
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 1 << 20
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }
        var written = 0

        do {
            guard let source = compressed.baseAddress else { throw ZIPExtractorError.extractionFailed }
            stream.src_ptr = source.assumingMemoryBound(to: UInt8.self)
            stream.src_size = compressed.count

            while true {
                stream.dst_ptr = chunk
                stream.dst_size = chunkSize
                let status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    try handle.write(contentsOf: Data(bytes: chunk, count: produced))
                    written += produced
                }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR {
                    throw ZIPExtractorError.extractionFailed
                }
                // No output and not finished means the stream is stuck; without
                // this a corrupt entry spins forever instead of failing.
                if produced == 0 && status == COMPRESSION_STATUS_OK {
                    throw ZIPExtractorError.extractionFailed
                }
            }
        }

        // Same guarantee the one-shot path gives: the entry is all there, or it
        // is a failure rather than a truncated file that imports and then does
        // not boot.
        guard written == expectedSize else {
            try? FileManager.default.removeItem(at: dest)
            throw ZIPExtractorError.extractionFailed
        }
    }

    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        // Use Apple's Compression framework with ZLIB (raw deflate)
        var output = Data(count: expectedSize)
        let result = output.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                compression_decode_buffer(
                    outPtr.bindMemory(to: UInt8.self).baseAddress!,
                    expectedSize,
                    inPtr.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard result == expectedSize else {
            throw ZIPExtractorError.extractionFailed
        }
        return output
    }
}
