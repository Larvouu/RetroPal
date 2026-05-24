//
//  BatterySaveImporterTests.swift
//  EmulateurGBATests
//
//  Covers the six paths called out by the /plan-eng-review 2026-05-15 test
//  plan for Manic / Delta / OpenEmu / RetroArch save-import:
//    1. .sav 128 KB classifies as a GBA save (Gen 3 signature path).
//    2. .srm 512 KB classifies as an NDS save.
//    3. A .sav that actually carries the GBA Nintendo-logo bytes is
//       rejected as `invalidFormat` so a misshared ROM doesn't silently
//       corrupt the BatterySaves directory.
//    4. A file whose size matches no known battery-save layout throws
//       `invalidFormat`.
//    5. The Gen 3 section-signature gate accepts a real save and rejects
//       a same-size garbage file.
//    6. `writeImport` refuses to clobber an existing save without an
//       explicit `overwriting: true`, and respects the override when set.
//
//  Fixtures are synthesized in-test rather than bundled to keep the test
//  target dependency-free. The Gen 3 magic, the GBA Nintendo-logo prefix
//  and the file-size table are public knowledge — see BatterySaveImporter
//  for citations.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("BatterySaveImporter", .serialized)
struct BatterySaveImporterTests {

    // MARK: - Helpers

    /// 8-byte prefix of the Nintendo logo embedded at GBA offset 0x04.
    /// Identical to the constant in `BatterySaveImporter` and chosen here
    /// so the test doesn't depend on the importer's private field.
    static let nintendoLogoPrefix: [UInt8] = [
        0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21
    ]

    /// Builds a 128 KB byte buffer that passes the Gen 3 signature gate.
    /// Stamps `0x08012025` little-endian at section-relative offset 0xFF8
    /// (the signature field; 0xFFC is the save index) across sections
    /// 14–27 — the backup slot. This mirrors the byte layout verified in
    /// the real FireRed Manic export (`Vendor/test-fixtures/`), which had
    /// exactly 14 stamps, all in the backup slot. Pinning the test to the
    /// real offset prevents a future off-by-4 from passing unnoticed.
    static func makeValidGen3Save() -> Data {
        var data = Data(repeating: 0, count: 131072)
        for sectionIndex in 14..<28 {
            let offset = sectionIndex * 0x1000 + 0xFF8
            data[offset]     = 0x25
            data[offset + 1] = 0x20
            data[offset + 2] = 0x01
            data[offset + 3] = 0x08
        }
        return data
    }

    /// 128 KB of zeros — passes the size gate but fails the Gen 3 signature
    /// check. Stands in for "random 128 KB file that happens to be the
    /// right size."
    static func makeBlank128KBSave() -> Data {
        Data(repeating: 0, count: 131072)
    }

    /// 512 KB of zeros. Matches the NDS HG/SS / Black/White save layout.
    static func makeBlankDSSave() -> Data {
        Data(repeating: 0, count: 524288)
    }

    /// 128 KB buffer whose first 0x10 bytes mimic a GBA ROM header with
    /// the Nintendo logo at offset 0x04. The size also happens to match a
    /// real Gen 3 save, which is the worst-case false positive we have to
    /// reject — without the logo gate, this would slip through.
    static func makeRomSizedFile() -> Data {
        var data = Data(repeating: 0, count: 131072)
        for (i, byte) in nintendoLogoPrefix.enumerated() {
            data[0x04 + i] = byte
        }
        return data
    }

    /// Writes `data` to a unique URL in the temp directory and returns the
    /// path. Caller is responsible for cleanup via `removeItem`.
    static func writeTempFile(data: Data, extension ext: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-import-\(UUID().uuidString).\(ext)")
        try data.write(to: tmp)
        return tmp
    }

    // MARK: - Classification

    @Test
    func test_classify_gbaSave128KB_routesToGBA() {
        let data = Self.makeValidGen3Save()
        let result = BatterySaveImporter.classify(data: data, system: .gbaFamily)
        #expect(result == .savable(system: .gbaFamily, byteCount: 131072))
    }

    @Test
    func test_classify_dsSave512KB_routesToNDS() {
        let data = Self.makeBlankDSSave()
        let result = BatterySaveImporter.classify(data: data, system: .nds)
        #expect(result == .savable(system: .nds, byteCount: 524288))
    }

    @Test
    func test_reject_gbaRom_byNintendoLogo() {
        let data = Self.makeRomSizedFile()
        let result = BatterySaveImporter.classify(data: data, system: .gbaFamily)
        #expect(result == .unsupported(reason: .invalidFormat))
    }

    @Test
    func test_reject_unknownSize_throwsInvalidFormat() {
        // 100,000 bytes matches no known GBA / GB / GBC battery save size,
        // so the file is rejected even though its declared extension is .sav.
        let data = Data(repeating: 0xAB, count: 100_000)
        let result = BatterySaveImporter.classify(data: data, system: .gbaFamily)
        #expect(result == .unsupported(reason: .invalidFormat))
    }

    @Test
    func test_gen3SectionSignatures_validatesRealSave() {
        // Identical sizes (131072 B) — the gate has to discriminate by the
        // section-footer magic alone.
        let validSave = Self.makeValidGen3Save()
        let blankSave = Self.makeBlank128KBSave()

        let validResult = BatterySaveImporter.classify(data: validSave, system: .gbaFamily)
        let blankResult = BatterySaveImporter.classify(data: blankSave, system: .gbaFamily)

        #expect(validResult == .savable(system: .gbaFamily, byteCount: 131072))
        #expect(blankResult == .unsupported(reason: .invalidFormat))
    }

    // MARK: - Save-path compatibility contract

    /// COMPATIBILITY CONTRACT. A ROM stored as `<basename>.<ext>` must always
    /// map to `BatterySaves/<basename>.sav`, and the save-state folder to
    /// `<basename>`. If this test fails, someone changed how the save path is
    /// derived, which silently orphans every existing user's in-game save
    /// (the file is still on disk, just at the old path the game no longer
    /// looks at). Do not "fix" the test to match new behaviour without a
    /// migration that moves existing saves.
    @Test
    func test_batterySavePath_derivationIsFrozen() {
        let gba = BatterySaveImporter.romBasename(
            forStoredFilename: "Pokemon - FireRed Version (USA, Europe) (Rev 1).gba")
        #expect(gba == "Pokemon - FireRed Version (USA, Europe) (Rev 1)")

        let nds = BatterySaveImporter.romBasename(
            forStoredFilename: "Pokemon - Version Argent SoulSilver (France).nds")
        #expect(nds == "Pokemon - Version Argent SoulSilver (France)")

        // Spaces, parentheses and commas in the title must survive verbatim.
        let path = BatterySaveImporter.savePath(forRomBasename: gba).path
        #expect(path.hasSuffix("/BatterySaves/Pokemon - FireRed Version (USA, Europe) (Rev 1).sav"))
    }

    // MARK: - Write import

    @Test
    func test_writeImport_duplicateGame_doesNotOverwrite() throws {
        // Unique basename per test run so concurrent / repeat runs don't
        // collide on the shared Documents/BatterySaves directory.
        let basename = "BatterySaveImporterTest-\(UUID().uuidString)"
        let dest = BatterySaveImporter.savePath(forRomBasename: basename)
        defer { try? FileManager.default.removeItem(at: dest) }

        let firstPayload = Self.makeBlankDSSave()
        let firstSrc = try Self.writeTempFile(data: firstPayload, extension: "srm")
        defer { try? FileManager.default.removeItem(at: firstSrc) }

        // First import lands cleanly — no pre-existing save at this basename.
        try BatterySaveImporter.writeImport(from: firstSrc, romBasename: basename)
        let writtenAfterFirst = try Data(contentsOf: dest)
        #expect(writtenAfterFirst == firstPayload)

        // Second import without `overwriting: true` must throw and leave
        // the original bytes intact.
        let secondPayload = Data(repeating: 0xFF, count: 524288)
        let secondSrc = try Self.writeTempFile(data: secondPayload, extension: "srm")
        defer { try? FileManager.default.removeItem(at: secondSrc) }

        #expect(throws: BatterySaveImportError.duplicateExists) {
            try BatterySaveImporter.writeImport(from: secondSrc, romBasename: basename)
        }
        let writtenAfterReject = try Data(contentsOf: dest)
        #expect(writtenAfterReject == firstPayload,
                "the rejected import must not have touched the existing save")

        // With `overwriting: true`, the second import wins.
        try BatterySaveImporter.writeImport(from: secondSrc,
                                            romBasename: basename,
                                            overwriting: true)
        let writtenAfterOverwrite = try Data(contentsOf: dest)
        #expect(writtenAfterOverwrite == secondPayload)
    }
}
