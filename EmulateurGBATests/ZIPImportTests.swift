//
//  ZIPImportTests.swift
//  EmulateurGBATests
//
//  The import path, from the bytes of a `.zip` to a library entry, with no
//  device, no bundled archive and no language setting on the simulator.
//
//  Why archives are BUILT here rather than bundled: the cases that matter are
//  about what the archiver wrote in the header (a codepage name with no flag,
//  bit 11, an Info-ZIP Unicode Path field, a data descriptor, an LZMA method
//  number, an encrypted bit), and a hand-built archive states each of those
//  exactly. `ArchiveBuilder` writes the format the way Windows, 7-Zip and
//  WinRAR do, entry by entry, so every test reads as "this is the archive a
//  real person dropped on the app".
//
//  Why the phone's language is bound per call: the importer reads the user's
//  language with no parameter to pass, and a test on an English simulator
//  still has to import a Japanese archive "as a Japanese phone". The binding
//  is `LegacyTextEncoding.preferredLanguagesOverride`, a task-local, so tests
//  running in parallel cannot see each other's language.
//
//  Trigger: a Japanese 1-star review on 2026-09-02, "ZIP error appears".
//

import Testing
import Foundation
import Compression
import CoreData
@testable import EmulateurGBA

// MARK: - A ZIP archive, written the way real archivers write it

struct ArchiveBuilder {

    struct Entry {
        /// The header name, as BYTES: this is the whole point. Windows writes
        /// the machine's OEM codepage here and sets no flag.
        var nameBytes: [UInt8]
        var content: Data
        /// 0 = stored, 8 = deflate, anything else = a method this app does not read.
        var method: UInt16 = 8
        /// General-purpose bits. 0x0001 encrypted, 0x0800 UTF-8 name.
        var flags: UInt16 = 0
        var extra: [UInt8] = []
        /// Bit 3: sizes and CRC are zero in the local header and trail the
        /// data instead. Streaming archivers write this.
        var useDataDescriptor = false
        /// Written verbatim as the compressed payload, for methods this reader
        /// does not implement (nothing here can produce real LZMA).
        var rawPayload: Data? = nil

        init(name: String, content: Data, method: UInt16 = 8, flags: UInt16 = 0) {
            self.nameBytes = Array(name.utf8)
            self.content = content
            self.method = method
            self.flags = flags
        }

        init(nameBytes: [UInt8], content: Data, method: UInt16 = 8, flags: UInt16 = 0) {
            self.nameBytes = nameBytes
            self.content = content
            self.method = method
            self.flags = flags
        }
    }

    /// Raw deflate, which is what a ZIP method-8 payload is and what the
    /// extractor's `COMPRESSION_ZLIB` decodes.
    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count + data.count / 2 + 4096
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        precondition(written > 0, "deflate failed")
        return Data(out.prefix(written))
    }

    /// An Info-ZIP Unicode Path extra field (0x7075) naming `utf8Name` for a
    /// header whose raw bytes are `rawName`. WinRAR, WinZip and Info-ZIP write it.
    static func unicodePathField(rawName: [UInt8], utf8Name: String) -> [UInt8] {
        let name = Array(utf8Name.utf8)
        let crc = ZIPExtractor.crc32(Data(rawName))
        let size = 1 + 4 + name.count
        var bytes: [UInt8] = [0x75, 0x70, UInt8(size & 0xFF), UInt8(size >> 8), 0x01]
        bytes += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
        bytes += name
        return bytes
    }

    static func build(_ entries: [Entry], comment: [UInt8] = []) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []

        func u16(_ v: UInt16, into a: inout [UInt8]) {
            a.append(UInt8(v & 0xFF)); a.append(UInt8(v >> 8))
        }
        func u32(_ v: UInt32, into a: inout [UInt8]) {
            a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
            a.append(UInt8((v >> 16) & 0xFF)); a.append(UInt8(v >> 24))
        }

        for e in entries {
            let payload: Data
            if let raw = e.rawPayload { payload = raw }
            else if e.method == 8 { payload = deflate(e.content) }
            else { payload = e.content }
            let crc = ZIPExtractor.crc32(e.content)
            let flags = e.flags | (e.useDataDescriptor ? 0x0008 : 0)
            let localOffset = UInt32(out.count)

            // Local file header
            u32(0x04034b50, into: &out)
            u16(20, into: &out)                 // version needed
            u16(flags, into: &out)
            u16(e.method, into: &out)
            u16(0, into: &out)                  // mod time
            u16(0x0021, into: &out)             // mod date
            if e.useDataDescriptor {
                u32(0, into: &out); u32(0, into: &out); u32(0, into: &out)
            } else {
                u32(crc, into: &out)
                u32(UInt32(payload.count), into: &out)
                u32(UInt32(e.content.count), into: &out)
            }
            u16(UInt16(e.nameBytes.count), into: &out)
            u16(UInt16(e.extra.count), into: &out)
            out += e.nameBytes
            out += e.extra
            out += [UInt8](payload)
            if e.useDataDescriptor {
                u32(0x08074b50, into: &out)
                u32(crc, into: &out)
                u32(UInt32(payload.count), into: &out)
                u32(UInt32(e.content.count), into: &out)
            }

            // Central directory header
            u32(0x02014b50, into: &central)
            u16(20, into: &central)             // version made by
            u16(20, into: &central)             // version needed
            u16(flags, into: &central)
            u16(e.method, into: &central)
            u16(0, into: &central)
            u16(0x0021, into: &central)
            u32(crc, into: &central)
            u32(UInt32(payload.count), into: &central)
            u32(UInt32(e.content.count), into: &central)
            u16(UInt16(e.nameBytes.count), into: &central)
            u16(UInt16(e.extra.count), into: &central)
            u16(0, into: &central)              // comment length
            u16(0, into: &central)              // disk number
            u16(0, into: &central)              // internal attributes
            u32(0, into: &central)              // external attributes
            u32(localOffset, into: &central)
            central += e.nameBytes
            central += e.extra
        }

        let cdOffset = UInt32(out.count)
        let cdSize = UInt32(central.count)
        out += central
        u32(0x06054b50, into: &out)
        u16(0, into: &out); u16(0, into: &out)
        u16(UInt16(entries.count), into: &out)
        u16(UInt16(entries.count), into: &out)
        u32(cdSize, into: &out)
        u32(cdOffset, into: &out)
        u16(UInt16(comment.count), into: &out)
        out += comment
        return Data(out)
    }
}

// MARK: - Shared fixtures

enum ImportFixtures {

    /// The bytes real archivers write, produced with Python's codecs
    /// (`"ポケモン.gba".encode("cp932")` and so on).
    static let cp932Pokemon: [UInt8] = [0x83, 0x7C, 0x83, 0x50, 0x83, 0x82, 0x83, 0x93]          // ポケモン
    static let cp850Pokemon: [UInt8] = [0x50, 0x6F, 0x6B, 0x82, 0x6D, 0x6F, 0x6E]                // Pokémon
    static let cp949Pokemon: [UInt8] = [0xC6, 0xF7, 0xC4, 0xCF, 0xB8, 0xF3]                      // 포켓몬
    static let cp950Pokemon: [UInt8] = [0xC4, 0x5F, 0xA5, 0x69, 0xB9, 0xDA]                      // 寶可夢
    /// ソニック in CP932. The trail byte of ソ is 0x5C, an ASCII backslash,
    /// which is the classic Shift-JIS trap for anything that splits on it.
    static let cp932Sonic: [UInt8] = [0x83, 0x5C, 0x83, 0x6A, 0x83, 0x62, 0x83, 0x4E]
    /// A cue sheet as a Japanese Windows tool writes it: CP932 text, CRLF.
    static let cp932CueSheet: [UInt8] = [
        0x46, 0x49, 0x4C, 0x45, 0x20, 0x22, 0x83, 0x5C, 0x83, 0x6A, 0x83, 0x62, 0x83, 0x4E,
        0x2E, 0x62, 0x69, 0x6E, 0x22, 0x20, 0x42, 0x49, 0x4E, 0x41, 0x52, 0x59, 0x0D, 0x0A,
        0x20, 0x20, 0x54, 0x52, 0x41, 0x43, 0x4B, 0x20, 0x30, 0x31, 0x20, 0x4D, 0x4F, 0x44,
        0x45, 0x32, 0x2F, 0x32, 0x33, 0x35, 0x32, 0x0D, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x49,
        0x4E, 0x44, 0x45, 0x58, 0x20, 0x30, 0x31, 0x20, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A,
        0x30, 0x30, 0x0D, 0x0A
    ]

    static func suffixed(_ name: [UInt8], _ ext: String) -> [UInt8] { name + Array(ext.utf8) }

    /// Patterned rather than zero so a wrong offset or a truncated inflate
    /// shows up as a byte mismatch instead of matching by accident.
    static func patterned(_ count: Int, seed: UInt8 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = UInt8((i &* 31 &+ Int(seed)) & 0xFF) }
        return Data(bytes)
    }

    /// A valid iNES ROM. Its header carries no title, so the library names
    /// the game after the FILE, which makes it the console that shows what
    /// the entry-name decoder did.
    static func nesROM(seed: UInt8 = 1) -> Data {
        var bytes = [UInt8](patterned(0x8000, seed: seed))
        bytes[0] = 0x4E; bytes[1] = 0x45; bytes[2] = 0x53; bytes[3] = 0x1A
        bytes[4] = 2; bytes[5] = 1; bytes[6] = 0; bytes[7] = 0
        return Data(bytes)
    }

    /// A minimal valid GBA ROM (marker 0x96 at 0xB2), as in ROMImporterTests.
    static func gbaROM(title: String = "ZIPTEST") -> Data {
        var bytes = [UInt8](repeating: 0, count: 0xC0)
        bytes[0xB2] = 0x96
        for (i, b) in Array(title.utf8).prefix(12).enumerated() { bytes[0x0A0 + i] = b }
        return Data(bytes)
    }

    /// A fresh temp directory that the caller removes.
    static func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run `body` as if the phone's language list were `languages`.
    static func asPhone<T>(_ languages: [String], _ body: () throws -> T) rethrows -> T {
        try LegacyTextEncoding.$preferredLanguagesOverride.withValue(languages, operation: body)
    }
}

// MARK: - The extractor

@Suite("ZIP extractor")
struct ZIPExtractorTests {

    private func write(_ archive: Data, in dir: URL, name: String = "test.zip") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try archive.write(to: url)
        return url
    }

    @Test("Stored and deflated entries both come back byte for byte")
    func storedAndDeflatedRoundTrip() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gba = ImportFixtures.patterned(0x20000, seed: 3)
        let gb = ImportFixtures.patterned(0x8000, seed: 5)
        let zip = try write(ArchiveBuilder.build([
            .init(name: "Game A.gba", content: gba, method: 0),
            .init(name: "Game B.gb", content: gb, method: 8),
        ]), in: dir)

        #expect(try ZIPExtractor.romEntryNames(in: zip) == ["Game A.gba", "Game B.gb"])
        let a = try ZIPExtractor.extractROM(named: "Game A.gba", from: zip)
        let b = try ZIPExtractor.extractROM(named: "Game B.gb", from: zip)
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        #expect(try Data(contentsOf: a) == gba)
        #expect(try Data(contentsOf: b) == gb)
        print("[zip] stored + deflated round trip: \(gba.count) + \(gb.count) bytes intact")
    }

    @Test("A Japanese Windows zip on a Japanese phone lists its game under its real name")
    func japaneseWindowsZipOnAJapanesePhone() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try write(ArchiveBuilder.build([
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp932Pokemon, ".gba"),
                  content: ImportFixtures.gbaROM())
        ]), in: dir)

        let names = try ImportFixtures.asPhone(["ja-JP"]) { try ZIPExtractor.romEntryNames(in: zip) }
        #expect(names == ["ポケモン.gba"])

        let extracted = try ImportFixtures.asPhone(["ja-JP"]) { try ZIPExtractor.extractROM(named: "ポケモン.gba", from: zip) }
        defer { try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent()) }
        #expect(extracted.lastPathComponent == "ポケモン.gba")
        #expect(FileManager.default.fileExists(atPath: extracted.path))
        print("[zip] ja-JP phone, CP932 name → \(names)")
    }

    @Test("The same Japanese zip on a French phone still imports, under a name that keeps its extension")
    func japaneseWindowsZipOnAFrenchPhoneStillImports() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try write(ArchiveBuilder.build([
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp932Pokemon, ".gba"),
                  content: ImportFixtures.gbaROM())
        ]), in: dir)

        let names = try ImportFixtures.asPhone(["fr-FR"]) { try ZIPExtractor.romEntryNames(in: zip) }
        #expect(names.count == 1)
        #expect(names.first?.hasSuffix(".gba") == true)
        let extracted = try ImportFixtures.asPhone(["fr-FR"]) { try ZIPExtractor.extractROM(named: names[0], from: zip) }
        defer { try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent()) }
        #expect(FileManager.default.fileExists(atPath: extracted.path))
        print("[zip] fr-FR phone, CP932 name → \(names) (garbled by design, still a .gba)")
    }

    @Test("A French Windows zip reads right on a French phone and never turns into PokＮon")
    func frenchWindowsZipOnAFrenchPhone() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try write(ArchiveBuilder.build([
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp850Pokemon, ".gba"),
                  content: ImportFixtures.gbaROM())
        ]), in: dir)
        let fr = try ImportFixtures.asPhone(["fr-FR"]) { try ZIPExtractor.romEntryNames(in: zip) }
        let de = try ImportFixtures.asPhone(["de-DE"]) { try ZIPExtractor.romEntryNames(in: zip) }
        let en = try ImportFixtures.asPhone(["en-US"]) { try ZIPExtractor.romEntryNames(in: zip) }
        #expect(fr == ["Pokémon.gba"])
        #expect(de == ["Pokémon.gba"])
        #expect(en == ["Pokémon.gba"])   // é is 0x82 in CP437 as well
        print("[zip] fr/de/en phones, CP850 name → \(fr) / \(de) / \(en)")
    }

    @Test("Korean and Taiwanese Windows zips read right on their own phones")
    func koreanAndTaiwaneseZips() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try write(ArchiveBuilder.build([
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp949Pokemon, ".nds"), content: ImportFixtures.patterned(64)),
        ]), in: dir, name: "ko.zip")
        let zipTW = try write(ArchiveBuilder.build([
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp950Pokemon, ".nds"), content: ImportFixtures.patterned(64)),
        ]), in: dir, name: "tw.zip")
        let ko = try ImportFixtures.asPhone(["ko-KR"]) { try ZIPExtractor.romEntryNames(in: zip) }
        let tw = try ImportFixtures.asPhone(["zh-Hant-TW"]) { try ZIPExtractor.romEntryNames(in: zipTW) }
        #expect(ko == ["포켓몬.nds"])
        #expect(tw == ["寶可夢.nds"])
        print("[zip] ko-KR → \(ko), zh-Hant-TW → \(tw)")
    }

    @Test("Bit 11 means UTF-8 and wins on every phone")
    func utf8FlaggedNameOnAnyPhone() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try write(ArchiveBuilder.build([
            .init(name: "Pokémon Émeraude.gba", content: ImportFixtures.gbaROM(), flags: 0x0800)
        ]), in: dir)
        for language in ["ja-JP", "fr-FR", "ko-KR", "en-US"] {
            let names = try ImportFixtures.asPhone([language]) { try ZIPExtractor.romEntryNames(in: zip) }
            #expect(names == ["Pokémon Émeraude.gba"], "on a \(language) phone")
        }
        print("[zip] bit 11 UTF-8 name identical on ja/fr/ko/en phones")
    }

    @Test("A WinRAR-style Unicode Path field is trusted over the codepage guess, even on a Japanese phone")
    func unicodePathFieldInTheCentralDirectory() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = ImportFixtures.suffixed(ImportFixtures.cp850Pokemon, ".gba")
        var entry = ArchiveBuilder.Entry(nameBytes: raw, content: ImportFixtures.gbaROM())
        entry.extra = ArchiveBuilder.unicodePathField(rawName: raw, utf8Name: "Pokémon.gba")
        let zip = try write(ArchiveBuilder.build([entry]), in: dir)
        // A Japanese phone would otherwise read these bytes as PokＮon.gba.
        let names = try ImportFixtures.asPhone(["ja-JP"]) { try ZIPExtractor.romEntryNames(in: zip) }
        #expect(names == ["Pokémon.gba"])
        print("[zip] Unicode Path field on a ja-JP phone → \(names)")
    }

    @Test("An LZMA entry is reported as unsupported, not as a broken archive, and is still listed")
    func lzmaEntryIsUnsupportedNotBroken() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var entry = ArchiveBuilder.Entry(name: "Game.gba", content: ImportFixtures.gbaROM(), method: 14)
        entry.rawPayload = ImportFixtures.patterned(300, seed: 9)
        let zip = try write(ArchiveBuilder.build([entry]), in: dir)
        #expect(try ZIPExtractor.romEntryNames(in: zip) == ["Game.gba"])
        #expect(throws: ZIPExtractorError.unsupportedCompression) {
            _ = try ZIPExtractor.extractROM(named: "Game.gba", from: zip)
        }
        print("[zip] method 14 (LZMA) → unsupportedCompression")
    }

    @Test("A password-protected entry says so")
    func encryptedEntry() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try write(ArchiveBuilder.build([
            .init(name: "Game.gba", content: ImportFixtures.gbaROM(), method: 8, flags: 0x0001)
        ]), in: dir)
        #expect(throws: ZIPExtractorError.encryptedArchive) {
            _ = try ZIPExtractor.extractROM(named: "Game.gba", from: zip)
        }
        print("[zip] bit 0 (encrypted) → encryptedArchive")
    }

    @Test("Entries written with a data descriptor are read through the central directory")
    func dataDescriptorEntries() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rom = ImportFixtures.patterned(0x4000, seed: 7)
        var entry = ArchiveBuilder.Entry(name: "Streamed.gbc", content: rom)
        entry.useDataDescriptor = true
        let zip = try write(ArchiveBuilder.build([entry]), in: dir)
        let extracted = try ZIPExtractor.extractROM(named: "Streamed.gbc", from: zip)
        defer { try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: extracted) == rom)
        print("[zip] data-descriptor entry extracted intact")
    }

    @Test("Folders are skipped, nested names keep their extension, extraction flattens, duplicates collapse")
    func foldersNestingAndDuplicates() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rom = ImportFixtures.patterned(0x400, seed: 2)
        let zip = try write(ArchiveBuilder.build([
            .init(name: "roms/", content: Data(), method: 0),
            .init(name: "roms/sub/Game.nds", content: rom),
            .init(name: "roms/sub/Game.nds", content: rom),
            .init(name: "readme.txt", content: Data("hello".utf8)),
        ]), in: dir)
        #expect(try ZIPExtractor.romEntryNames(in: zip) == ["roms/sub/Game.nds"])
        let urls = try ZIPExtractor.extractEntries(named: ["roms/sub/Game.nds"], from: zip)
        defer { if let first = urls.first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) } }
        #expect(urls.map(\.lastPathComponent) == ["Game.nds"])
        #expect(try Data(contentsOf: urls[0]) == rom)
    }

    @Test("A cartridge beside a stray .bin is a cartridge archive")
    func cartridgeWinsOverDiscParts() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try write(ArchiveBuilder.build([
            .init(name: "Game.gba", content: ImportFixtures.gbaROM()),
            .init(name: "stray.bin", content: ImportFixtures.patterned(64)),
        ]), in: dir)
        #expect(try ZIPExtractor.romEntryNames(in: zip) == ["Game.gba"])
        let games = try ZIPExtractor.gameEntries(in: zip)
        #expect(games.cartridges == ["Game.gba"])
        #expect(games.discs.isEmpty)
    }

    @Test("An archive with a trailing comment is still found")
    func archiveWithAComment() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try write(ArchiveBuilder.build(
            [.init(name: "Game.gba", content: ImportFixtures.gbaROM())],
            comment: [UInt8](repeating: 0x41, count: 1000)), in: dir)
        #expect(try ZIPExtractor.romEntryNames(in: zip) == ["Game.gba"])
    }

    @Test("One corrupt entry costs only itself, never the games after it")
    func oneCorruptEntryDoesNotCostTheOthers() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = [UInt8](ArchiveBuilder.build([
            .init(name: "First.gba", content: ImportFixtures.gbaROM(title: "FIRST")),
            .init(name: "Second.gba", content: ImportFixtures.gbaROM(title: "SECOND")),
            .init(name: "Third.gba", content: ImportFixtures.gbaROM(title: "THIRD")),
        ]))
        // Point the second entry's local-header offset past the end of the file.
        let eocd = bytes.count - 22
        let cdOffset = Int(UInt32(bytes[eocd + 16]) | UInt32(bytes[eocd + 17]) << 8
                           | UInt32(bytes[eocd + 18]) << 16 | UInt32(bytes[eocd + 19]) << 24)
        let firstLen = 46 + "First.gba".utf8.count
        let second = cdOffset + firstLen
        #expect(bytes[second] == 0x50 && bytes[second + 1] == 0x4B, "test arithmetic found the second header")
        bytes[second + 42] = 0xF0; bytes[second + 43] = 0xFF; bytes[second + 44] = 0xFF; bytes[second + 45] = 0x7F
        let zip = try write(Data(bytes), in: dir)

        let names = try ZIPExtractor.romEntryNames(in: zip)
        #expect(names == ["First.gba", "Third.gba"])
        print("[zip] corrupt middle entry → \(names)")
    }

    @Test("Malformed archives fail with an error or an empty list, never a crash")
    func malformedArchivesDoNotTrap() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = ArchiveBuilder.build([
            .init(name: "Game.gba", content: ImportFixtures.gbaROM()),
            .init(name: "Other.gb", content: ImportFixtures.patterned(0x800)),
        ])
        var cdBeyondEOF = [UInt8](good)
        do {
            let eocd = cdBeyondEOF.count - 22
            cdBeyondEOF[eocd + 16] = 0xF0; cdBeyondEOF[eocd + 17] = 0xFF
            cdBeyondEOF[eocd + 18] = 0xFF; cdBeyondEOF[eocd + 19] = 0x7F
        }
        var nameLengthBeyondEOF = [UInt8](good)
        do {
            let eocd = nameLengthBeyondEOF.count - 22
            let cd = Int(UInt32(nameLengthBeyondEOF[eocd + 16]) | UInt32(nameLengthBeyondEOF[eocd + 17]) << 8
                         | UInt32(nameLengthBeyondEOF[eocd + 18]) << 16 | UInt32(nameLengthBeyondEOF[eocd + 19]) << 24)
            nameLengthBeyondEOF[cd + 28] = 0xFF; nameLengthBeyondEOF[cd + 29] = 0xFF
        }
        var sizeBeyondEOF = [UInt8](good)
        do {
            // Local header of the first entry: compressed size at +18.
            sizeBeyondEOF[18] = 0xFF; sizeBeyondEOF[19] = 0xFF; sizeBeyondEOF[20] = 0xFF; sizeBeyondEOF[21] = 0x7F
        }
        let cases: [(String, Data)] = [
            ("empty file", Data()),
            ("four bytes", Data([0x50, 0x4B, 0x03, 0x04])),
            ("random bytes", ImportFixtures.patterned(4096, seed: 77)),
            ("truncated in half", Data(good.prefix(good.count / 2))),
            ("central directory beyond EOF", Data(cdBeyondEOF)),
            ("name length beyond EOF", Data(nameLengthBeyondEOF)),
            ("compressed size beyond EOF", Data(sizeBeyondEOF)),
        ]
        for (label, data) in cases {
            let url = try write(data, in: dir, name: "\(UUID().uuidString).zip")
            let names = (try? ZIPExtractor.romEntryNames(in: url)) ?? []
            // Listing may still succeed on a damaged size; extraction then must
            // fail cleanly rather than read past the buffer.
            for name in names {
                if let result = try? ZIPExtractor.extractROM(named: name, from: url) {
                    try? FileManager.default.removeItem(at: result.deletingLastPathComponent())
                }
            }
            print("[zip] malformed '\(label)': listed \(names.count), no trap")
        }
    }

    @Test("A disc track above the streaming threshold is inflated to disk intact")
    func largeEntryStreamsToDisk() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Just past the one-shot limit, and compressible, so the archive stays small.
        let block = ImportFixtures.patterned(4096, seed: 11)
        var track = Data(capacity: 32 * 1024 * 1024 + 4096)
        for _ in 0..<(8 * 1024 + 1) { track.append(block) }
        #expect(track.count > 32 * 1024 * 1024)
        let zip = try write(ArchiveBuilder.build([
            .init(name: "Track 01.bin", content: track),
            .init(name: "Game.cue", content: Data("FILE \"Track 01.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".utf8)),
        ]), in: dir)
        let urls = try ZIPExtractor.extractEntries(named: ["Game.cue", "Track 01.bin"], from: zip)
        defer { if let first = urls.first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) } }
        let out = urls.first { $0.lastPathComponent == "Track 01.bin" }
        let bytes = try out.map { try Data(contentsOf: $0) }
        #expect(bytes?.count == track.count)
        #expect(bytes == track)
        print("[zip] \(track.count)-byte track streamed to disk, byte-identical")
    }

    @Test("A Shift-JIS cue sheet groups with its CP932-named disc inside an archive")
    func shiftJISCueSheetGroupsWithItsDisc() throws {
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try write(ArchiveBuilder.build([
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp932Sonic, ".cue"), content: Data(ImportFixtures.cp932CueSheet)),
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp932Sonic, ".bin"), content: ImportFixtures.patterned(0x1000, seed: 4)),
        ]), in: dir)

        let ja = try ImportFixtures.asPhone(["ja-JP"]) { try ZIPExtractor.gameEntries(in: zip) }
        #expect(ja.discs.count == 1)
        #expect(ja.gaps.isEmpty)
        #expect(ja.discs.first?.boot == "ソニック.cue")
        #expect(ja.discs.first?.members.contains("ソニック.bin") == true)
        print("[zip] ja-JP phone: cue \(ja.discs.first?.boot ?? "-") → members \(ja.discs.first?.members ?? [])")

        // On a French phone both names and the cue text go through the SAME
        // chain, so the game still groups, under a name that is not its own.
        let fr = try ImportFixtures.asPhone(["fr-FR"]) { try ZIPExtractor.gameEntries(in: zip) }
        #expect(fr.discs.count == 1)
        #expect(fr.gaps.isEmpty)
        #expect(fr.discs.first?.boot.hasSuffix(".cue") == true)
    }
}

// MARK: - Through the importer, to the library

/// Serialized: every test writes into the app's real ROMs/ folder on the
/// simulator and cleans up after itself, and two of them use the same names.
@Suite("ZIP import through ROMImporter", .serialized)
struct ZIPImportThroughImporterTests {

    private func makeImporter() -> (ROMImporter, NSManagedObjectContext) {
        let context = PersistenceController(inMemory: true).container.viewContext
        return (ROMImporter(context: context), context)
    }

    private func games(_ context: NSManagedObjectContext) throws -> [NSManagedObject] {
        try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "GameEntity"))
    }

    private func writeZip(_ archive: Data, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("import-\(UUID().uuidString).zip")
        try archive.write(to: url)
        return url
    }

    @Test("A Japanese Windows zip lands in the library under its Japanese title on a Japanese phone")
    func japaneseZipBecomesAJapaneseLibraryEntry() throws {
        let (importer, context) = makeImporter()
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try writeZip(ArchiveBuilder.build([
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp932Pokemon, ".nes"), content: ImportFixtures.nesROM(seed: 21))
        ]), in: dir)

        _ = try ImportFixtures.asPhone(["ja-JP"]) { try importer.importROM(from: zip, method: "picker") }
        let entries = try games(context)
        let path = entries.first?.value(forKey: "romFilePath") as? String
        defer { if let path { try? FileManager.default.removeItem(at: importer.romURL(for: path)) } }

        #expect(entries.count == 1)
        #expect(entries.first?.value(forKey: "title") as? String == "ポケモン")
        #expect(path == "ポケモン.nes")
        #expect(path.map { FileManager.default.fileExists(atPath: importer.romURL(for: $0).path) } == true)
        print("[import] ja-JP phone: title '\(entries.first?.value(forKey: "title") as? String ?? "-")', file '\(path ?? "-")'")
    }

    @Test("The same Japanese zip on a French phone still becomes a playable entry")
    func japaneseZipOnAFrenchPhoneStillImports() throws {
        let (importer, context) = makeImporter()
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try writeZip(ArchiveBuilder.build([
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp932Pokemon, ".nes"), content: ImportFixtures.nesROM(seed: 22))
        ]), in: dir)

        _ = try ImportFixtures.asPhone(["fr-FR"]) { try importer.importROM(from: zip, method: "picker") }
        let entries = try games(context)
        let path = entries.first?.value(forKey: "romFilePath") as? String
        defer { if let path { try? FileManager.default.removeItem(at: importer.romURL(for: path)) } }

        #expect(entries.count == 1)
        #expect(path?.hasSuffix(".nes") == true)
        #expect((entries.first?.value(forKey: "title") as? String)?.isEmpty == false)
        #expect(path.map { FileManager.default.fileExists(atPath: importer.romURL(for: $0).path) } == true)
        print("[import] fr-FR phone: title '\(entries.first?.value(forKey: "title") as? String ?? "-")' (garbled by design), file present")
    }

    @Test("A Shift-JIS cue and its disc import as one game, and the cue on disk is rewritten in UTF-8")
    func shiftJISDiscImportsWithARewrittenCue() throws {
        let (importer, context) = makeImporter()
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = try writeZip(ArchiveBuilder.build([
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp932Sonic, ".cue"), content: Data(ImportFixtures.cp932CueSheet)),
            .init(nameBytes: ImportFixtures.suffixed(ImportFixtures.cp932Sonic, ".bin"), content: ImportFixtures.patterned(0x2000, seed: 5)),
        ]), in: dir)

        _ = try ImportFixtures.asPhone(["ja-JP"]) { try importer.importROM(from: zip, method: "picker") }
        let entries = try games(context)
        let path = entries.first?.value(forKey: "romFilePath") as? String
        let folder = path.map { importer.romURL(for: $0).deletingLastPathComponent() }
        defer { if let folder { try? FileManager.default.removeItem(at: folder) } }

        #expect(entries.count == 1)
        #expect(path == "ソニック/ソニック.cue")
        let cueURL = try #require(path.map { importer.romURL(for: $0) })
        let cueBytes = try Data(contentsOf: cueURL)
        let cueText = String(data: cueBytes, encoding: .utf8)
        #expect(cueText != nil, "the cue must have been rewritten as UTF-8")
        #expect(cueText?.contains("FILE \"ソニック.bin\"") == true)
        #expect(FileManager.default.fileExists(atPath: cueURL.deletingLastPathComponent().appendingPathComponent("ソニック.bin").path),
                "the disc must sit beside the cue under the name the cue now uses")
        print("[import] ja-JP phone: \(path ?? "-"), cue rewritten → \(cueText?.split(separator: "\r\n").first.map(String.init) ?? "-")")
    }

    @Test("The importer names the reason: unsupported method, password, broken file, no game")
    func importerReportsTheRightError() throws {
        let (importer, _) = makeImporter()
        let dir = try ImportFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var lzma = ArchiveBuilder.Entry(name: "Game.gba", content: ImportFixtures.gbaROM(), method: 14)
        lzma.rawPayload = ImportFixtures.patterned(200, seed: 8)
        let lzmaZip = try writeZip(ArchiveBuilder.build([lzma]), in: dir)
        do {
            _ = try importer.importROM(from: lzmaZip, method: "picker")
            Issue.record("an LZMA archive must not import")
        } catch ROMImportError.zipUnsupportedCompression {
            print("[import] LZMA → zipUnsupportedCompression")
        }

        let encryptedZip = try writeZip(ArchiveBuilder.build([
            .init(name: "Game.gba", content: ImportFixtures.gbaROM(), flags: 0x0001)
        ]), in: dir)
        do {
            _ = try importer.importROM(from: encryptedZip, method: "picker")
            Issue.record("an encrypted archive must not import")
        } catch ROMImportError.zipEncrypted {
            print("[import] encrypted → zipEncrypted")
        }

        let garbage = try writeZip(ImportFixtures.patterned(2048, seed: 3), in: dir)
        do {
            _ = try importer.importROM(from: garbage, method: "picker")
            Issue.record("garbage must not import")
        } catch ROMImportError.zipNoGBA {
            // Not a ZIP at all lists no entries, which the importer reads as
            // "no game inside". Acceptable: the sentence tells the user what
            // to do and nothing crashed.
            print("[import] garbage → zipNoGBA")
        } catch ROMImportError.zipExtractionFailed {
            print("[import] garbage → zipExtractionFailed")
        }

        let noGame = try writeZip(ArchiveBuilder.build([
            .init(name: "readme.txt", content: Data("nothing to play".utf8))
        ]), in: dir)
        do {
            _ = try importer.importROM(from: noGame, method: "picker")
            Issue.record("an archive with no game must not import")
        } catch ROMImportError.zipNoGBA {
            print("[import] no game inside → zipNoGBA")
        }
    }
}
