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
}

enum ZIPExtractor {
    /// Read from the parser's own list so a new console cannot be importable
    /// loose but invisible inside a zip.
    private static let romExtensions: Set<String> = Set(ROMSystemType.allFileExtensions)

    /// Full entry names (including any folder prefix) of the ROM files
    /// (every extension in `ROMSystemType.allFileExtensions`) inside the
    /// archive, in archive order.
    /// Duplicate names are dropped: extraction is by name, so a malformed
    /// archive with two identical entry names could only ever yield the
    /// first one anyway.
    ///
    /// **Cartridges win over disc parts when an archive holds both**, and that
    /// rule exists to protect archives that already work. The PlayStation
    /// brought generic extensions into the ROM list, `.bin` and `.iso` among
    /// them, and a cartridge zip that happens to carry a stray `.bin` beside
    /// its game would otherwise go from importing silently to asking the user
    /// which of two "games" they meant. An archive containing a cartridge is a
    /// cartridge archive; only one containing no cartridge at all is read as a
    /// disc.
    static func romEntryNames(in zipURL: URL) throws -> [String] {
        var seen = Set<String>()
        let names = romEntries(in: try loadData(zipURL))
            .map(\.name)
            .filter { seen.insert($0).inserted }
        let cartridges = names.filter { !isDiscPart($0) }
        return cartridges.isEmpty ? names : cartridges
    }

    private static func isDiscPart(_ entryName: String) -> Bool {
        DiscImportGrouper.isDiscFile(entryName)
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
        var seen = Set<String>()
        let names = entries.map(\.name).filter { seen.insert($0).inserted }

        // Cartridges still win, for the reason above: an archive with a real
        // cartridge in it is a cartridge archive, whatever else it carries.
        let cartridgeNames = names.filter { !isDiscPart($0) }
        if !cartridgeNames.isEmpty { return ([], cartridgeNames, []) }

        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let grouping = DiscImportGrouper.groupNames(names) { name in
            guard let entry = byName[name],
                  let bytes = try? extractEntry(entry, from: data) else { return nil }
            return DiscImportGrouper.decode(bytes)
        }
        return (grouping.discs, grouping.others, grouping.gaps)
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
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var written: [URL] = []
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
        return written
    }

    /// Extracts one ROM entry (by its full entry name, as returned by
    /// `romEntryNames`) into a fresh temp directory and returns the file URL.
    static func extractROM(named name: String, from zipURL: URL) throws -> URL {
        let data = try loadData(zipURL)
        guard let entry = romEntries(in: data).first(where: { $0.name == name }) else {
            throw ZIPExtractorError.noROMFound
        }

        // Extract the file data
        let fileData = try extractEntry(entry, from: data)

        // Write to temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let filename = URL(fileURLWithPath: entry.name).lastPathComponent
        let destURL = tempDir.appendingPathComponent(filename)
        try fileData.write(to: destURL)

        return destURL
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
        return entries.filter { entry in
            // Check extension from both URL parsing and raw string suffix
            let name = entry.name.lowercased()
            return romExtensions.contains(where: { name.hasSuffix(".\($0)") })
        }
    }

    // MARK: - ZIP Parsing (minimal, handles store + deflate)

    private struct ZIPEntry {
        let name: String
        let compressedSize: Int
        let uncompressedSize: Int
        let method: UInt16       // 0=store, 8=deflate
        let dataOffset: Int      // offset to compressed data in ZIP
    }

    /// Read a little-endian UInt32 from data at the given offset.
    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    /// Read a little-endian UInt16 from data at the given offset.
    private static func readU16(_ data: Data, at offset: Int) -> UInt16 {
        data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
    }

    /// Parse entries from the Central Directory (reliable, handles data descriptors).
    private static func findEntriesFromCentralDirectory(in data: Data) throws -> [ZIPEntry] {
        guard let eocdOffset = findEOCD(in: data) else {
            throw ZIPExtractorError.cannotReadZIP
        }

        let cdOffset = Int(readU32(data, at: eocdOffset + 16))  // offset of central directory
        let cdEntries = Int(readU16(data, at: eocdOffset + 10))  // total entries

        var entries: [ZIPEntry] = []
        var offset = cdOffset

        for _ in 0..<cdEntries {
            guard offset + 46 <= data.count else { break }

            // Central directory file header signature: 0x02014b50
            let sig = readU32(data, at: offset)
            guard sig == 0x02014b50 else { break }

            let method = readU16(data, at: offset + 10)
            let compressedSize = Int(readU32(data, at: offset + 20))
            let uncompressedSize = Int(readU32(data, at: offset + 24))
            let nameLength = Int(readU16(data, at: offset + 28))
            let extraLength = Int(readU16(data, at: offset + 30))
            let commentLength = Int(readU16(data, at: offset + 32))
            let localHeaderOffset = Int(readU32(data, at: offset + 42))

            let nameData = data.subdata(in: offset+46..<offset+46+nameLength)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) ?? ""

            // Compute data offset from local file header
            let localNameLen = Int(readU16(data, at: localHeaderOffset + 26))
            let localExtraLen = Int(readU16(data, at: localHeaderOffset + 28))
            let dataOffset = localHeaderOffset + 30 + localNameLen + localExtraLen

            if !name.hasSuffix("/") {
                entries.append(ZIPEntry(
                    name: name,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    method: method,
                    dataOffset: dataOffset
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
            if readU32(data, at: offset) == 0x06054b50 {
                return offset
            }
        }
        return nil
    }

    /// Fallback: parse entries from local file headers (doesn't handle data descriptors).
    private static func findEntriesFromLocalHeaders(in data: Data) -> [ZIPEntry] {
        var entries: [ZIPEntry] = []
        var offset = 0

        while offset + 30 <= data.count {
            let sig = readU32(data, at: offset)
            guard sig == 0x04034b50 else { break }

            let method = readU16(data, at: offset + 8)
            let compressedSize = Int(readU32(data, at: offset + 18))
            let uncompressedSize = Int(readU32(data, at: offset + 22))
            let nameLength = Int(readU16(data, at: offset + 26))
            let extraLength = Int(readU16(data, at: offset + 28))

            let nameEnd = offset + 30 + nameLength
            guard nameEnd <= data.count else { break }
            let nameData = data.subdata(in: offset+30..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) ?? ""

            let dataOffset = offset + 30 + nameLength + extraLength

            if !name.hasSuffix("/") && compressedSize > 0 {
                entries.append(ZIPEntry(
                    name: name,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    method: method,
                    dataOffset: dataOffset
                ))
            }

            offset = dataOffset + compressedSize
        }

        return entries
    }

    private static func extractEntry(_ entry: ZIPEntry, from data: Data) throws -> Data {
        let compressed = data.subdata(in: entry.dataOffset..<entry.dataOffset + entry.compressedSize)

        switch entry.method {
        case 0: // Store (no compression)
            return compressed
        case 8: // Deflate
            return try inflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw ZIPExtractorError.extractionFailed
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
        let compressed = data.subdata(in: entry.dataOffset..<entry.dataOffset + entry.compressedSize)
        switch entry.method {
        case 0:
            // Stored. `compressed` is a slice of the MAPPED archive, so this
            // never resident-loads the whole thing either.
            try compressed.write(to: dest)
        case 8 where entry.uncompressedSize <= streamingInflateThreshold:
            try inflate(compressed, expectedSize: entry.uncompressedSize).write(to: dest)
        case 8:
            try inflateToFile(compressed, expectedSize: entry.uncompressedSize, dest: dest)
        default:
            throw ZIPExtractorError.extractionFailed
        }
    }

    /// Inflate to a file a megabyte at a time, so peak memory is the chunk and
    /// not the track.
    private static func inflateToFile(_ compressed: Data, expectedSize: Int, dest: URL) throws {
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

        try compressed.withUnsafeBytes { raw in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
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
