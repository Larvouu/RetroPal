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
    static func romEntryNames(in zipURL: URL) throws -> [String] {
        var seen = Set<String>()
        return romEntries(in: try loadData(zipURL)).map(\.name).filter { seen.insert($0).inserted }
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
