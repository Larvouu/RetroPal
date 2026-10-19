//
//  ImportFourConsolesTests.swift
//  EmulateurGBATests
//
//  The import audit of the four consoles added for 1.3.4 and after (Mega
//  Drive, Master System, Game Gear, PSP), 2026-10-10: the cases each fix
//  below was made for, on files built byte by byte here. No game is bundled.
//
//  - A disc that boots ALONE (no `.cue`, `.toc`, `.ccd` or `.m3u` naming it)
//    must carry what its format carries (`GBAROMParser.isBootableDiscImage`):
//    a `.bin` that is neither a Mega Drive cartridge nor a disc used to become
//    a PlayStation entry that failed at boot.
//  - Two PSP UMDs named "(Disc 1)" and "(Disc 2)" import as two games: the
//    grouper merged them behind a written `.m3u`, which PPSSPP does not read
//    and which launched on the PlayStation's core.
//  - The import gate and the console answer do not depend on the case of the
//    extension, and a Markdown file named `.md` is not a game.
//

import Testing
import Foundation
import CoreData
@testable import EmulateurGBA

struct ImportFourConsolesTests {

    // MARK: - Fixtures

    /// An ISO 9660 volume in `sectorSize`-byte sectors, the volume descriptor
    /// at sector 16, `userData` bytes into the sector, naming `systemID`.
    private func makeVolume(systemID: String, sectorSize: Int = 2048, userData: Int = 0,
                            sectors: Int = 20) -> Data {
        var bytes = [UInt8](repeating: 0, count: sectors * sectorSize)
        let pvd = 16 * sectorSize + userData
        bytes[pvd] = 1
        for (i, b) in Array("CD001".utf8).enumerated() { bytes[pvd + 1 + i] = b }
        var system = Array(systemID.utf8).prefix(32).map { $0 }
        system += [UInt8](repeating: 0x20, count: 32 - system.count)
        for (i, b) in system.enumerated() { bytes[pvd + 8 + i] = b }
        return Data(bytes)
    }

    /// A Mega Drive cartridge: "SEGA MEGA DRIVE" at 0x100.
    private func makeMD() -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x8000)
        for (i, b) in Array("SEGA MEGA DRIVE ".utf8).enumerated() { bytes[0x100 + i] = b }
        for i in 0x200..<bytes.count { bytes[i] = UInt8((i &* 13) & 0xFF) }
        return Data(bytes)
    }

    private func temp(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("four-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func entries(_ context: NSManagedObjectContext) throws -> [NSManagedObject] {
        try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "GameEntity"))
    }

    /// Removes what the given library entries put in ROMs/: a disc game's
    /// folder, a cartridge's file.
    private func removeImported(_ context: NSManagedObjectContext, _ importer: ROMImporter) {
        for entry in (try? entries(context)) ?? [] {
            guard let path = entry.value(forKey: "romFilePath") as? String else { continue }
            let url = importer.romURL(for: path)
            try? FileManager.default.removeItem(at: DiscStorage.gameFolder(forROMAt: url) ?? url)
        }
    }

    // MARK: - A disc that boots alone

    @Test func eachDiscLayoutTheCoresReadPasses() {
        #expect(GBAROMParser.isBootableDiscImage(head: makeVolume(systemID: "PSP GAME"), fileExtension: "iso"))
        #expect(GBAROMParser.isBootableDiscImage(head: makeVolume(systemID: "PSP GAME"), fileExtension: "ISO"))
        // Raw CD sectors: mode 1 (16 bytes of header) and mode 2 (24).
        #expect(GBAROMParser.isBootableDiscImage(
            head: makeVolume(systemID: "PLAYSTATION", sectorSize: 2352, userData: 16), fileExtension: "bin"))
        #expect(GBAROMParser.isBootableDiscImage(
            head: makeVolume(systemID: "PLAYSTATION", sectorSize: 2352, userData: 24), fileExtension: "img"))
        // An Alcohol `.mdf` keeps 96 bytes of subchannel per sector.
        #expect(GBAROMParser.isBootableDiscImage(
            head: makeVolume(systemID: "PLAYSTATION", sectorSize: 2448, userData: 24), fileExtension: "mdf"))
        #expect(GBAROMParser.isBootableDiscImage(head: Data("MComprHD".utf8) + Data(count: 64), fileExtension: "chd"))
        #expect(GBAROMParser.isBootableDiscImage(head: Data("CISO".utf8) + Data(count: 20), fileExtension: "cso"))
        #expect(GBAROMParser.isBootableDiscImage(head: Data([0x00, 0x50, 0x42, 0x50]) + Data(count: 36), fileExtension: "pbp"))
        // PPSSPP takes an ELF misnamed `.pbp`, so the import does too.
        #expect(GBAROMParser.isBootableDiscImage(head: Data([0x7F, 0x45, 0x4C, 0x46]) + Data(count: 36), fileExtension: "pbp"))
    }

    @Test func aFileThatIsNoDiscIsRefused() {
        let junk = Data(repeating: 0x42, count: 70_000)
        for ext in ["bin", "iso", "img", "mdf", "cso", "pbp", "chd"] {
            #expect(!GBAROMParser.isBootableDiscImage(head: junk, fileExtension: ext), "\(ext) of junk passed")
        }
        // A download cut off before the volume descriptor.
        let cut = makeVolume(systemID: "PSP GAME").prefix(16 * 2048)
        #expect(!GBAROMParser.isBootableDiscImage(head: cut, fileExtension: "iso"))
        // A Mega Drive cartridge is a cartridge, not a disc.
        #expect(!GBAROMParser.isBootableDiscImage(head: makeMD(), fileExtension: "bin"))
        // A Mega-CD disc is ISO 9660 too, with Sega's boot header in sector 0,
        // as a 2048-byte image and as raw sectors: no core here runs it.
        var megaCD = [UInt8](makeVolume(systemID: "SEGA"))
        for (i, b) in Array("SEGADISCSYSTEM  ".utf8).enumerated() { megaCD[i] = b }
        #expect(!GBAROMParser.isBootableDiscImage(head: Data(megaCD), fileExtension: "iso"))
        var megaCDRaw = [UInt8](makeVolume(systemID: "SEGA", sectorSize: 2352, userData: 16))
        for (i, b) in Array("SEGADISCSYSTEM  ".utf8).enumerated() { megaCDRaw[16 + i] = b }
        #expect(!GBAROMParser.isBootableDiscImage(head: Data(megaCDRaw), fileExtension: "bin"))
    }

    /// The path a `.bin` that is neither console takes from the picker: refused
    /// with the invalid-game message, nothing left in the library or on disk.
    @Test func aLoneBinThatIsNeitherConsoleIsRefusedAtImport() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImported(context, importer) }
        let url = try temp("Firmware \(UUID().uuidString.prefix(6)).bin", Data(repeating: 0x42, count: 70_000))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(throws: ROMImportError.self) { _ = try importer.importROM(from: url, method: "picker") }
        #expect(try entries(context).isEmpty, "a file that is no game became a library entry")
    }

    /// The same for a `.cso` that is not one: it was filed under the PSP by its
    /// extension alone, whatever it held.
    @Test func aCSOWithoutItsMagicIsRefusedAtImport() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImported(context, importer) }
        let url = try temp("Broken \(UUID().uuidString.prefix(6)).cso", Data(repeating: 0x07, count: 4096))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(throws: ROMImportError.self) { _ = try importer.importROM(from: url, method: "picker") }
        #expect(try entries(context).isEmpty)
    }

    /// A Mega Drive `.bin` picked loose still takes the cartridge path, stored
    /// as `.md`, filed under the Mega Drive: the new disc check is never asked.
    @Test func aMegaDriveBinStillImportsAsACartridge() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImported(context, importer) }
        let name = "Sonic \(UUID().uuidString.prefix(6))"
        let url = try temp("\(name).BIN", makeMD())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try importer.importROM(from: url, method: "picker")
        let game = try #require(try entries(context).first)
        #expect(game.value(forKey: "systemType") as? String == "md")
        #expect(game.value(forKey: "romFilePath") as? String == "\(name).md")
    }

    // MARK: - A PSP game on two UMDs

    @Test func twoPSPDiscsImportAsTwoPSPGamesWithoutAPlaylist() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImported(context, importer) }
        let base = "Test UMD \(UUID().uuidString.prefix(6)) (USA)"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("four-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two different discs: the first sector differs, so they hash apart.
        var one = makeVolume(systemID: "PSP GAME"); one[0] = 1
        var two = makeVolume(systemID: "PSP GAME"); two[0] = 2
        let d1 = dir.appendingPathComponent("\(base) (Disc 1).iso")
        let d2 = dir.appendingPathComponent("\(base) (Disc 2).iso")
        try one.write(to: d1)
        try two.write(to: d2)

        // The grouper, working on names, merges them, as it does a PlayStation game.
        let (_, discs, _) = DiscImportGrouper.group([d1, d2])
        let group = try #require(discs.first)
        #expect(discs.count == 1 && group.playlistDiscs?.count == 2)

        _ = try importer.importDiscGroup(group, method: "picker")
        let games = try entries(context)
        #expect(games.count == 2, "two UMDs must be two library entries, got \(games.count)")
        for game in games {
            let path = game.value(forKey: "romFilePath") as? String ?? ""
            #expect(game.value(forKey: "systemType") as? String == "psp", "\(path) was not filed under the PSP")
            #expect(path.hasSuffix(".iso"), "\(path) does not boot from its image")
        }
        // Two rows a player can tell apart: each keeps its disc number.
        let titles = Set(games.compactMap { $0.value(forKey: "title") as? String })
        #expect(titles.count == 2, "both discs show the same name: \(titles)")
        #expect(titles.contains { $0.hasSuffix("(Disc 1)") } && titles.contains { $0.hasSuffix("(Disc 2)") },
                "\(titles)")
    }

    /// A PlayStation game on two discs keeps its written playlist: the split
    /// above is the PSP's alone.
    @Test func twoPlayStationDiscsStillShareOnePlaylist() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImported(context, importer) }
        let base = "Test PS1 \(UUID().uuidString.prefix(6)) (USA)"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("four-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var one = makeVolume(systemID: "PLAYSTATION"); one[0] = 1
        var two = makeVolume(systemID: "PLAYSTATION"); two[0] = 2
        let d1 = dir.appendingPathComponent("\(base) (Disc 1).iso")
        let d2 = dir.appendingPathComponent("\(base) (Disc 2).iso")
        try one.write(to: d1)
        try two.write(to: d2)

        let group = try #require(DiscImportGrouper.group([d1, d2]).discs.first)
        _ = try importer.importDiscGroup(group, method: "picker")
        let games = try entries(context)
        #expect(games.count == 1)
        #expect(games.first?.value(forKey: "systemType") as? String == "ps1")
        #expect((games.first?.value(forKey: "romFilePath") as? String)?.hasSuffix(".m3u") == true)
    }

    // MARK: - Names and cases

    @Test func uppercaseExtensionsNameTheirConsole() throws {
        #expect(ROMSystemType.from(fileExtension: "MD") == .md)
        #expect(ROMSystemType.from(fileExtension: "GEN") == .md)
        #expect(ROMSystemType.from(fileExtension: "SMS") == .sms)
        #expect(ROMSystemType.from(fileExtension: "GG") == .gg)
        #expect(ROMSystemType.from(fileExtension: "CSO") == .psp)
        let sms = try temp("WATER.SMS", Data(count: 0x8000))
        let gg = try temp("WATER.GG", Data(count: 0x8000))
        defer {
            try? FileManager.default.removeItem(at: sms.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: gg.deletingLastPathComponent())
        }
        #expect(GBAROMParser.isValidROMFile(url: sms) && GBAROMParser.isValidROMFile(url: gg))
        #expect(GBAROMParser.detectSystemType(url: sms) == .sms)
        #expect(GBAROMParser.detectSystemType(url: gg) == .gg)
    }

    /// `.md` is also Markdown's extension. A text file of that name reaching
    /// the importer is refused, never filed as a Mega Drive game.
    @Test func aMarkdownFileIsNotAMegaDriveGame() throws {
        let text = String(repeating: "# A heading\nSome notes.\n", count: 64)
        let url = try temp("README.md", Data(text.utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!GBAROMParser.isValidROMFile(url: url))
    }

    /// The same with CJK text that happens to carry the GBA's one marker byte
    /// (0x96 at 0xB2), which UTF-8 Japanese does often: still refused.
    @Test func aJapaneseMarkdownNoteIsNotAGame() throws {
        var bytes = [UInt8](String(repeating: "# メモ\n文章を書く。\n", count: 64).utf8)
        if bytes.count > 0xB2 { bytes[0xB2] = 0x96 }
        let url = try temp("メモ.md", Data(bytes))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!GBAROMParser.isValidROMFile(url: url))
    }

    /// Every console the app runs is in the library's console order, the
    /// welcome strip and the file pickers.
    @Test func everyConsoleIsListedEverywhereTheLibraryListsThem() {
        let all = ["gba", "gb", "gbc", "nds", "snes", "nes", "ps1", "n64", "md", "sms", "gg", "psp"]
        #expect(ConsoleIconRow.all.count == all.count)
        #expect(ConsoleIconRow.lines.joined().count == all.count)
        for ext in ["md", "gen", "smd", "sms", "gg", "iso", "cso", "pbp"] {
            #expect(ROMSystemType.allFileExtensions.contains(ext), "the pickers do not offer .\(ext)")
        }
        for system in all {
            #expect(SystemColor.name(system).isEmpty == false, "\(system) has no name")
        }
    }

    // MARK: - The onboarding names every format

    /// The empty library's first step listed formats up to the PlayStation's
    /// `.chd` in every language until 2026-10-10; the four consoles after it
    /// were missing. Read from the checkout, so the source strings are checked.
    @Test func theFirstStepNamesEveryConsolesFormats() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EmulateurGBA", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            print("SKIPPED: the checkout is not readable from this test run")
            return
        }
        for locale in shippedLocales {
            let url = root.appendingPathComponent("\(locale).lproj/Localizable.strings")
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in ["library.empty.step1", "library.empty.step1.ipad"] {
                let line = text.split(separator: "\n").first { $0.hasPrefix("\"\(key)\" = ") }
                let value = try #require(line.map(String.init), "\(locale) lacks \(key)")
                for ext in [".md", ".gen", ".smd", ".sms", ".gg", ".chd", ".iso", ".cso", ".pbp"] {
                    #expect(value.contains(ext), "\(locale) \(key) does not name \(ext)")
                }
            }
        }
    }
}
