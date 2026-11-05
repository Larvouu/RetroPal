//
//  GameArchive.swift
//  EmulateurGBA
//
//  Every archive a game can arrive in, behind the four calls the importer
//  makes (1.3.5, decided 2026-10-27: "cover all main ways to zip a file", a
//  .zip-only importer being a friction where 7-Zip and WinRAR are the usual
//  tools).
//
//  .zip         the app's own reader (`ZIPExtractor`), exactly as before. When
//               it meets a compression method it does not implement (LZMA,
//               BZIP2, XZ or Deflate64 inside a zip, which 7-Zip and WinRAR
//               write), the same call is made again through libarchive, which
//               reads them: what used to end on "this ZIP uses a compression
//               method Retro Pal can't read" now imports.
//  everything   .7z, .rar (RAR4 and RAR5), .tar, .tar.gz / .tgz, .tar.xz / .txz,
//  else         and a lone .gz / .xz: libarchive (`GameArchiveReader`, C).
//
//  Both readers apply the same rules (`ArchiveGameRules`), throw the same
//  errors (`ZIPExtractorError`, so every message, telemetry value and summary
//  line the importer has works unchanged), and extract the same way (into one
//  fresh temp directory, flattened, as a disc's descriptor expects).
//

import Foundation

enum GameArchive {

    /// The archive extensions offered and read, `.zip` included. A double
    /// extension (`.tar.gz`) is matched on its last part, `gz`.
    static let extensions: [String] = ["zip", "7z", "rar", "tar", "gz", "tgz", "xz", "txz"]

    /// Whether this file is one of them.
    static func isArchive(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Scratch

    /// Every file an archive import writes before the game reaches ROMs/: the
    /// archive's own copy and each extraction, one folder apiece. Gathered
    /// under one root so the launch sweep (`sweepScratch`) can find what an
    /// import killed midway left (gigabytes for a disc in a .7z), and one
    /// folder each so two archives of the same name never share a copy
    /// (audit, 2026-10-30: both lived loose in tmp, the copy named after the
    /// archive, and nothing ever removed them after a kill).
    static var scratchRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveImport", isDirectory: true)
    }

    /// A new, empty folder under `scratchRoot`.
    static func makeScratchFolder() throws -> URL {
        let folder = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Where an archive is copied before it is read, in its own folder.
    static func stagedCopyURL(for source: URL) throws -> URL {
        try makeScratchFolder().appendingPathComponent(source.lastPathComponent)
    }

    /// Removes a copy made by `stagedCopyURL`, its folder with it.
    static func discardStagedCopy(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Run at launch: removes the scratch folders older than ten minutes. An
    /// import started in this launch (a game opened from Files as the app came
    /// up) has a folder made moments ago and is left alone, as
    /// `CTRSaveData.sweepImportScratch` does for its own.
    static func sweepScratch(now: Date = Date()) {
        let fm = FileManager.default
        let root = scratchRoot
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let url = root.appendingPathComponent(name)
            guard let made = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(made) > 600 else { continue }
            try? fm.removeItem(at: url)
        }
    }

    private static func isZip(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    /// Whether reading this archive maps the file into memory (the app's own
    /// zip reader, `ZIPExtractor.loadData`) rather than streaming it
    /// (libarchive). A mapped file must be one nobody else changes meanwhile:
    /// the importer copies those first (`ROMImporter.importZIP`).
    static func isMappedWhenRead(_ url: URL) -> Bool { isZip(url) }

    /// Whether the file is one volume of an archive split in several, as
    /// WinRAR and 7-Zip write them (2026-10-30): a game in it runs on into the
    /// next volume, which the reader is never given, and the import said the
    /// archive was damaged. Known by its name (`name.part2.rar`, `name.7z.001`,
    /// `name.zip.001`) or, for a RAR named plainly (the older `name.rar` +
    /// `name.r00` sets, or a renamed part), by the volume flag of its main
    /// header, read from its first bytes as libarchive reads it
    /// (`archive_read_support_format_rar.c` MAIN_HEAD, `MHD_VOLUME`;
    /// `..._rar5.c` `process_head_main`, `VOLUME`).
    static func isSplitVolume(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.range(of: #"\.part\d+\.rar$"#, options: .regularExpression) != nil { return true }
        if name.range(of: #"\.(7z|zip|rar)\.\d{3}$"#, options: .regularExpression) != nil { return true }
        guard url.pathExtension.lowercased() == "rar",
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 64)) ?? Data())
        return rarHeaderSaysVolume(head)
    }

    /// The volume flag in a RAR's first bytes (`isSplitVolume`). RAR 1.5-4:
    /// the 7-byte marker, then the main block, its type 0x73 at byte 9 and its
    /// flags (little-endian) at 10-11, `MHD_VOLUME` 0x0001. RAR 5: the 8-byte
    /// marker, then the main header: CRC32 (4 bytes), its size, its type
    /// (1, main), its flags, its extra-area size when flag 0x0001 is set, then
    /// the archive flags, `VOLUME` 0x0001; every number after the CRC a
    /// variable-length integer (7 bits a byte, the high bit for "more").
    static func rarHeaderSaysVolume(_ b: [UInt8]) -> Bool {
        let rar4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        let rar5: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        if b.count >= 12, Array(b[0..<7]) == rar4 {
            return b[9] == 0x73 && (UInt16(b[10]) | UInt16(b[11]) << 8) & 0x0001 != 0
        }
        guard b.count > 12, Array(b[0..<8]) == rar5 else { return false }
        var i = 12
        func vint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]; i += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        guard vint() != nil, let type = vint(), type == 1, let flags = vint() else { return false }
        if flags & 0x0001 != 0 { guard vint() != nil else { return false } }
        guard let archiveFlags = vint() else { return false }
        return archiveFlags & 0x0001 != 0
    }

    /// The game files to offer: the cartridges, else the disc parts
    /// (`ZIPExtractor.romEntryNames`).
    static func romEntryNames(in url: URL) throws -> [String] {
        if isZip(url) {
            do { return try ZIPExtractor.romEntryNames(in: url) } catch ZIPExtractorError.unsupportedCompression {}
        }
        let listing = try Listing.of(url)
        return ArchiveGameRules.entryNames(listing.gameEntries, bytes: listing.bytes)
    }

    /// The GAMES the archive holds (`ZIPExtractor.gameEntries`).
    static func gameEntries(in url: URL) throws
    -> (discs: [DiscNameGroup], cartridges: [String], gaps: [DiscNameGap]) {
        if isZip(url) {
            do { return try ZIPExtractor.gameEntries(in: url) } catch ZIPExtractorError.unsupportedCompression {}
        }
        let listing = try Listing.of(url)
        return ArchiveGameRules.games(listing.gameEntries, bytes: listing.bytes)
    }

    /// The named entries in ONE fresh temp directory, flattened
    /// (`ZIPExtractor.extractEntries`).
    static func extractEntries(named names: [String], from url: URL) throws -> [URL] {
        if isZip(url) {
            do { return try ZIPExtractor.extractEntries(named: names, from: url) }
            catch ZIPExtractorError.unsupportedCompression {}
        }
        return try extract(names, from: url)
    }

    /// One entry in a fresh temp directory (`ZIPExtractor.extractROM`).
    static func extractROM(named name: String, from url: URL) throws -> URL {
        if isZip(url) {
            do { return try ZIPExtractor.extractROM(named: name, from: url) }
            catch ZIPExtractorError.unsupportedCompression {}
        }
        guard let first = try extract([name], from: url).first else { throw ZIPExtractorError.noROMFound }
        return first
    }

    // MARK: - libarchive

    /// The status the C reader returns, as the error the importer already reads.
    private static func error(for status: GameArchiveStatus) -> Error {
        switch status {
        case GameArchiveEncrypted: return ZIPExtractorError.encryptedArchive
        case GameArchiveUnsupported: return ZIPExtractorError.unsupportedCompression
        case GameArchiveNotFound: return ZIPExtractorError.noROMFound
        // The phone full: the system's own error, which the importer reads as
        // "free up storage" (`importError`, `ErrorTelemetry.copyCause`), as
        // for a zip written by the app's own reader (audit, 2026-10-29).
        case GameArchiveNoSpace: return NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        case GameArchiveWriteFailed: return ZIPExtractorError.extractionFailed
        default: return ZIPExtractorError.cannotReadZIP
        }
    }

    /// One pass over the archive: its game files, and the bytes the rules read.
    private struct Listing {
        let gameEntries: [ArchiveGameRules.Entry]
        let byName: [String: Data]
        /// Each game file's position among the archive's files, which is how
        /// `GameArchiveExtract` finds it (never by name: see `extract`).
        let positions: [String: Int]

        init(_ url: URL) throws {
            var status = GameArchiveOK
            guard let listing = GameArchiveList(url.path, &status) else {
                throw GameArchive.error(for: status)
            }
            defer { GameArchiveListingFree(listing) }
            var entries: [ArchiveGameRules.Entry] = []
            var byName: [String: Data] = [:]
            var positions: [String: Int] = [:]
            for i in 0..<Int(listing.pointee.count) {
                let raw = listing.pointee.entries[i]
                guard let cName = raw.name else { continue }
                // UTF-8 when the archive stores it so (7z, RAR5, most tar); a
                // legacy name that is not valid UTF-8 is read in the user's own
                // codepage first, as a zip's is (`LegacyTextEncoding`).
                var bytes = Data(bytes: cName, count: strlen(cName))
                if raw.legacyRARName != 0 { bytes = Self.restoringShiftJISBackslashes(bytes) }
                let name = String(data: bytes, encoding: .utf8) ?? LegacyTextEncoding.decode(bytes)
                guard ArchiveGameRules.isGameFile(name), positions[name] == nil else { continue }
                // An encrypted game file cannot be imported; said as an
                // encrypted zip entry is, rather than as "no game in it".
                if raw.encrypted != 0 { throw ZIPExtractorError.encryptedArchive }
                entries.append(.init(name: name, size: raw.size >= 0 ? Int(raw.size) : nil))
                positions[name] = i
                if let p = raw.bytes { byName[name] = Data(bytes: p, count: raw.byteCount) }
            }
            self.gameEntries = entries
            self.byName = byName
            self.positions = positions
        }

        func bytes(_ name: String) -> Data? { byName[name] }

        /// The listing of this archive, made once while the file is unchanged.
        /// An import lists the archive to find its games, then extracts by the
        /// listing's positions, and the selection sheet extracts each pick the
        /// same way: each used to list it again, and listing a solid .7z or
        /// .rar decompresses it as far as the small files it reads, so a disc
        /// in a solid archive was decompressed two or three times (audit,
        /// 2026-10-30). Keyed by path, size and date, so a changed file is
        /// listed again; the last few kept, names and descriptor bytes only.
        static func of(_ url: URL) throws -> Listing {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let key = CacheKey(path: url.standardizedFileURL.path,
                               size: (attributes?[.size] as? NSNumber)?.int64Value ?? -1,
                               date: (attributes?[.modificationDate] as? Date) ?? .distantPast)
            cacheLock.lock()
            if let hit = cache.first(where: { $0.key == key }) { cacheLock.unlock(); return hit.listing }
            cacheLock.unlock()
            let listing = try Listing(url)
            cacheLock.lock()
            cache.removeAll { $0.key.path == key.path }
            cache.append((key, listing))
            if cache.count > 4 { cache.removeFirst(cache.count - 4) }
            cacheLock.unlock()
            return listing
        }

        private struct CacheKey: Equatable { let path: String; let size: Int64; let date: Date }
        private static let cacheLock = NSLock()
        private static var cache: [(key: CacheKey, listing: Listing)] = []

        /// An old RAR's name (`legacyRARName`), on a phone whose codepage is
        /// Shift-JIS: the '/' libarchive wrote over a character's second byte
        /// is 0x5C again. The bytes are walked as Shift-JIS from the start, so
        /// only a '/' that is the second byte of a character is restored; a
        /// '/' after a single-byte character is the separator it stood for.
        /// Elsewhere the bytes are left alone: in a Western codepage the same
        /// bytes are accented letters, and a folder named like that would be
        /// joined to its file (audit, 2026-10-29).
        static func restoringShiftJISBackslashes(_ data: Data) -> Data {
            guard LegacyTextEncoding.candidates(forPreferredLanguages: LegacyTextEncoding.preferredLanguages)
                .first == .shiftJIS else { return data }
            var bytes = [UInt8](data)
            var i = 0
            while i < bytes.count {
                let b = bytes[i]
                let lead = (0x81...0x9F).contains(b) || (0xE0...0xFC).contains(b)
                if lead, i + 1 < bytes.count {
                    if bytes[i + 1] == 0x2F { bytes[i + 1] = 0x5C }
                    i += 2
                } else {
                    i += 1
                }
            }
            return Data(bytes)
        }
    }

    /// Extract the named entries (names as `Listing` gave them) into one fresh
    /// temp directory, in one pass, flattened.
    ///
    /// The C reader is handed POSITIONS and the file names to write, never the
    /// names to look for: a legacy name was decoded here in Swift, and comparing
    /// it there against the raw bytes would miss it.
    private static func extract(_ names: [String], from url: URL) throws -> [URL] {
        let listing = try Listing.of(url)
        var indices: [Int] = []
        for name in names {
            guard let position = listing.positions[name] else { throw ZIPExtractorError.noROMFound }
            indices.append(position)
        }
        let files = names.map { URL(fileURLWithPath: $0).lastPathComponent }
        let tempDir = try makeScratchFolder()

        // `size_t` is `Int` in Swift, so the positions pass as they are.
        let cFiles = files.map { strdup($0) }
        defer { cFiles.forEach { free($0) } }
        let status: GameArchiveStatus = indices.withUnsafeBufferPointer { indexBuffer in
            cFiles.map { UnsafePointer<CChar>($0) }.withUnsafeBufferPointer { fileBuffer in
                GameArchiveExtract(url.path, indexBuffer.baseAddress, fileBuffer.baseAddress,
                                   files.count, tempDir.path)
            }
        }
        guard status == GameArchiveOK else {
            try? FileManager.default.removeItem(at: tempDir)
            throw error(for: status)
        }
        return files.map { tempDir.appendingPathComponent($0) }
    }
}
