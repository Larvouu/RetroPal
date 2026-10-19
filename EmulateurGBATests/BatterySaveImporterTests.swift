//
//  BatterySaveImporterTests.swift
//  EmulateurGBATests
//
//  Covers the six paths called out by the /plan-eng-review 2026-05-15 test
//  plan for Manic / Delta / OpenEmu / RetroArch save-import:
//    1. .sav 128 KB classifies as a GBA save (Gen 3 signature path).
//    2. 512 KB classifies as an NDS save, as .sav or .srm (since 2026-10-07
//       the size, not the extension, names the console).
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
    /// a real Gen 3 export from another emulator, verified locally, which had
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
        guard case .savable(let consoles, 131072) = BatterySaveImporter.classify(data: data, system: .cartridge) else {
            Issue.record("A Gen 3 save was refused."); return
        }
        #expect(consoles.contains("gba"))
    }

    @Test
    func test_classify_dsSave512KB_routesToNDS() {
        // A DS save under BOTH names: RetroArch writes `.srm`, Delta and melonDS
        // `.sav`, and Retro Pal stores it as `<rom>.sav`. A 512 KB `.sav`
        // (SoulSilver, opened from Retro Pal's own BatterySaves folder) was
        // refused until 2026-10-07.
        #expect(BatterySaveImporter.classify(data: Self.makeBlankDSSave(), system: .cartridge)
                == .savable(consoles: ["nds"], byteCount: 524288))
        #expect(BatterySaveSystem.from(fileExtension: "sav") == .cartridge)
        #expect(BatterySaveSystem.from(fileExtension: "SRM") == .cartridge)
    }

    @Test
    func test_reject_gbaRom_byNintendoLogo() {
        let data = Self.makeRomSizedFile()
        let result = BatterySaveImporter.classify(data: data, system: .cartridge)
        #expect(result == .unsupported(reason: .invalidFormat))
    }

    @Test
    func test_reject_unknownSize_throwsInvalidFormat() {
        // 100,000 bytes matches no console's battery save size.
        let data = Data(repeating: 0xAB, count: 100_000)
        let result = BatterySaveImporter.classify(data: data, system: .cartridge)
        #expect(result == .unsupported(reason: .invalidFormat))
    }

    @Test
    func test_gen3SectionSignatures_validatesRealSave() {
        // Identical sizes (131072 B): only the section-footer magic makes a
        // 128 KB file a GBA save. Without it the file is still a size the
        // Game Boy, the Super Nintendo and a PlayStation memory card use, so
        // it stays importable for THOSE, never for a GBA game.
        guard case .savable(let valid, _) = BatterySaveImporter.classify(data: Self.makeValidGen3Save(), system: .cartridge),
              case .savable(let blank, _) = BatterySaveImporter.classify(data: Self.makeBlank128KBSave(), system: .cartridge) else {
            Issue.record("A 128 KB save was refused outright."); return
        }
        #expect(valid.contains("gba"))
        #expect(!blank.contains("gba"))
        #expect(blank == ["gb", "gbc", "snes", "ps1"])
    }

    /// The clock carts. mGBA, our GBA and Game Boy core, appends the clock's
    /// state after the save RAM: 16 bytes on a GBA (Pokémon Ruby, Sapphire,
    /// Emerald), 48 on a Game Boy MBC3 (Pokémon Gold, Silver, Crystal), 44 in
    /// the older VBA layout. A save mGBA itself wrote was refused on import
    /// until 2026-10-07.
    @Test
    func test_classify_clockCartSaves_areAccepted() {
        var emerald = Self.makeValidGen3Save()
        emerald.append(Data(repeating: 0x11, count: 16))
        guard case .savable(let gba, _) = BatterySaveImporter.classify(data: emerald, system: .cartridge) else {
            Issue.record("A GBA clock-cart save (128 KB + 16) was refused."); return
        }
        #expect(gba == ["gba"])

        for suffix in [44, 48] {
            let crystal = Data(repeating: 0x22, count: 32768 + suffix)
            #expect(BatterySaveImporter.classify(data: crystal, system: .cartridge)
                    == .savable(consoles: ["gb", "gbc"], byteCount: 32768 + suffix),
                    "A Game Boy clock-cart save (32 KB + \(suffix)) was refused.")
        }
        // A blank 128 KB + 16 is not a Gen 3 save, so it is nothing at all.
        var blank = Self.makeBlank128KBSave()
        blank.append(Data(count: 16))
        #expect(BatterySaveImporter.classify(data: blank, system: .cartridge) == .unsupported(reason: .invalidFormat))
    }

    /// Every console's own save, as Retro Pal stores it (`<rom>.sav`), imports
    /// back into a game of that console: what a player gets by opening a file
    /// from Retro Pal's BatterySaves folder in Files, or moving a save between
    /// two devices.
    @Test
    func test_classify_everyConsolesOwnSave_isAccepted() {
        let sizes: [(String, Int)] = [("gba", 32768), ("gb", 8192), ("gbc", 32768), ("nes", 8192),
                                      ("snes", 32768), ("nds", 524288), ("n64", 296_960), ("ps1", 131072)]
        for (console, size) in sizes {
            guard case .savable(let consoles, _) = BatterySaveImporter.classify(
                data: Data(repeating: 0x5A, count: size), system: .cartridge) else {
                Issue.record("A \(console) save of \(size) bytes was refused."); continue
            }
            #expect(consoles.contains(console), "A \(size)-byte save is not offered to \(console) games.")
        }
    }

    /// `.mcd` is a PlayStation memory card and nothing else.
    @Test
    func test_classify_memoryCard_isPlayStationOnly() {
        let card = Data(repeating: 0, count: 131072)
        #expect(BatterySaveSystem.from(fileExtension: "mcd") == .memoryCard)
        #expect(BatterySaveImporter.classify(data: card, system: .memoryCard)
                == .savable(consoles: ["ps1"], byteCount: 131072))
        #expect(BatterySaveImporter.classify(data: Data(count: 8192), system: .memoryCard)
                == .unsupported(reason: .invalidFormat))
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

        // A DISC game is stored as `<folder>/<boot file>`, and the FOLDER is the
        // game. This is the derivation that decides where its saves, its save
        // states, its box art and its achievement record all live, and it has
        // already been got wrong once: taking the boot file's name gave a game
        // whose cover and save-state preview simply never appeared, because
        // twenty-five call sites were each asking a slightly different
        // question. A boot file can be called anything, and two different games
        // can both boot from a file called `disc1.cue`; only the folder is
        // unique, and only the folder is stable when the boot file changes on a
        // re-import.
        let disc = BatterySaveImporter.romBasename(
            forStoredFilename: "Tomb Raider (USA)/Tomb Raider (USA) (Track 1).cue")
        #expect(disc == "Tomb Raider (USA)")

        // The same answer from the URL form, because both forms are asked at
        // different call sites and a disagreement between them is invisible
        // until a save lands under a name nothing else looks for.
        let discURL = BatterySaveImporter.romBasename(
            forROMURL: URL(fileURLWithPath: "/x/ROMs/Tomb Raider (USA)/Tomb Raider (USA) (Track 1).cue"))
        #expect(discURL == disc)

        // A cartridge has no folder of its own, so the URL form must NOT read
        // the ROMs directory as one.
        let cartURL = BatterySaveImporter.romBasename(
            forROMURL: URL(fileURLWithPath: "/x/ROMs/Pokemon - FireRed Version (USA, Europe) (Rev 1).gba"))
        #expect(cartURL == gba)

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

    // MARK: - The consoles every size reaches

    /// An 8 KB save is the commonest cart save there is (Zelda, Final
    /// Fantasy, Dragon Warrior on the NES, Phantasy Star on the Mega Drive) and
    /// must classify for every console that writes one, whatever its
    /// extension, while the Gen 3 signature rule stays confined to the GBA at
    /// 128 KB.
    @Test
    func test_classify_8KBSave_reachesEveryConsoleOfThatSize() {
        let save = Data(repeating: 0x42, count: 8192)
        #expect(BatterySaveImporter.classify(data: save, system: .cartridge)
                == .savable(consoles: ["gba", "gb", "gbc", "nes", "snes", "nds", "md", "sms", "gg"],
                            byteCount: 8192))
        #expect(BatterySaveSystem.from(fileExtension: "state") == nil)
    }
}
