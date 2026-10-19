//
//  ROMImporterTests.swift
//  EmulateurGBATests
//
//  Regression coverage for the duplicate-import data-loss bug (fixed 2026-05-31):
//  importing a ROM already in the library used to copy it to ROMs/<name> and
//  then delete that very path on the duplicate check — but on a repeat import
//  the path IS the existing game's file, so the live ROM was deleted, leaving a
//  library entry that failed to launch as "file damaged".
//
//  The dedup is by SHA-256 and the deletion targeted the on-disk path, so the
//  bug was system-agnostic (GB/GBC/GBA/NDS/ZIP all import through this path). A
//  minimal valid GBA fixture exercises it; the fix is shared across systems.
//
//  Fixtures are synthesized in-test (no bundled ROMs); the GBA 0x96 marker at
//  0xB2 is public knowledge — see GBAROMParser.isValidGBAFile.
//

import Testing
import Foundation
import CoreData
@testable import EmulateurGBA

struct ROMImporterTests {

    /// A minimal but valid GBA ROM: 0xC0 bytes with the 0x96 marker at 0xB2 and
    /// a short title at 0x0A0, so isValidROMFile + parse accept it.
    private func makeValidGBA(title: String = "REGTEST") -> Data {
        var bytes = [UInt8](repeating: 0, count: 0xC0)
        bytes[0xB2] = 0x96
        for (i, b) in Array(title.utf8).prefix(12).enumerated() { bytes[0x0A0 + i] = b }
        return Data(bytes)
    }

    private func gameCount(_ context: NSManagedObjectContext) throws -> Int {
        try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "GameEntity"))
    }

    /// Re-importing the same file must NOT delete the existing ROM (the bug),
    /// and must not create a second library entry.
    @Test func duplicateImportKeepsTheExistingROMFile() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("regtest-\(UUID().uuidString).gba")
        try makeValidGBA().write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        // First import: lands in ROMs/, one entity.
        _ = try importer.importROM(from: src, method: "picker")
        let dest = importer.romURL(for: src.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: dest) }
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try gameCount(context) == 1)

        // Second import of the same bytes: a no-op that throws alreadyImported
        // WITHOUT deleting the existing ROM file.
        do {
            _ = try importer.importROM(from: src, method: "picker")
            Issue.record("Second import should have thrown .alreadyImported")
        } catch ROMImportError.alreadyImported {
            // expected
        }
        #expect(FileManager.default.fileExists(atPath: dest.path),
                "the duplicate import must not delete the existing ROM file")
        #expect(try gameCount(context) == 1)
    }

    /// Same bytes under a different filename is also a no-op: the hash-first
    /// guard must not copy a redundant file or touch the original.
    @Test func duplicateImportUnderDifferentNameDoesNotTouchTheOriginal() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        let bytes = makeValidGBA()

        let srcA = FileManager.default.temporaryDirectory
            .appendingPathComponent("regtest-A-\(UUID().uuidString).gba")
        let srcB = FileManager.default.temporaryDirectory
            .appendingPathComponent("regtest-B-\(UUID().uuidString).gba")
        try bytes.write(to: srcA)
        try bytes.write(to: srcB)
        defer { try? FileManager.default.removeItem(at: srcA) }
        defer { try? FileManager.default.removeItem(at: srcB) }

        _ = try importer.importROM(from: srcA, method: "picker")
        let destA = importer.romURL(for: srcA.lastPathComponent)
        let destB = importer.romURL(for: srcB.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: destA) }
        defer { try? FileManager.default.removeItem(at: destB) }

        do {
            _ = try importer.importROM(from: srcB, method: "picker")
            Issue.record("Importing the same bytes under a new name should throw .alreadyImported")
        } catch ROMImportError.alreadyImported {
            // expected
        }
        #expect(FileManager.default.fileExists(atPath: destA.path),
                "the original ROM must be untouched")
        #expect(!FileManager.default.fileExists(atPath: destB.path),
                "no redundant copy should be left in ROMs/")
        #expect(try gameCount(context) == 1)
    }

    // MARK: - Two different games, one name (fixed 2026-10-07)
    //
    // A game's file in ROMs/ is ALSO the key its battery save, save states,
    // auto-save and settings are filed under (its name without the
    // extension). A second, different game under a name already taken used
    // to delete the first game's file and take its place; and a different
    // game whose name differed only by its extension shared the first one's
    // saves. Each test uses names of its own and removes what it imported:
    // ROMs/ is the app's real folder.

    private func entries(_ context: NSManagedObjectContext) throws -> [NSManagedObject] {
        try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "GameEntity"))
    }

    /// Every ROM file the given library entries point at, for cleanup.
    private func removeImportedFiles(_ context: NSManagedObjectContext, _ importer: ROMImporter) {
        for entry in (try? entries(context)) ?? [] {
            if let path = entry.value(forKey: "romFilePath") as? String {
                try? FileManager.default.removeItem(at: importer.romURL(for: path))
            }
        }
    }

    /// A source file named `name` in a directory of its own, so two
    /// different games can carry the same name side by side.
    private func source(named name: String, bytes: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("same-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    @Test func aDifferentGameUnderATakenNameGetsAFreeNameAndTheFirstIsUntouched() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImportedFiles(context, importer) }
        let name = "regtest-same-\(UUID().uuidString)"
        let first = makeValidGBA(title: "FIRSTGAME")
        let second = makeValidGBA(title: "SECONDGAME")
        let srcA = try source(named: "\(name).gba", bytes: first)
        let srcB = try source(named: "\(name).gba", bytes: second)
        defer { try? FileManager.default.removeItem(at: srcA.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: srcB.deletingLastPathComponent()) }

        _ = try importer.importROM(from: srcA, method: "picker")
        _ = try importer.importROM(from: srcB, method: "picker")

        // The first game's file still holds the FIRST game.
        #expect(try Data(contentsOf: importer.romURL(for: "\(name).gba")) == first,
                "Importing a different game under the same name replaced the first game's file.")
        // The second has a file of its own.
        #expect(try Data(contentsOf: importer.romURL(for: "\(name) 2.gba")) == second)
        // Two entries, two files, two keys, each file the game its entry says.
        let library = try entries(context)
        let paths = library.compactMap { $0.value(forKey: "romFilePath") as? String }
        #expect(Set(paths) == ["\(name).gba", "\(name) 2.gba"])
        for entry in library {
            let path = entry.value(forKey: "romFilePath") as? String ?? ""
            let onDisk = GBAROMParser.parse(fileURL: importer.romURL(for: path))?.sha256
            #expect(onDisk == entry.value(forKey: "romHash") as? String,
                    "\(path) does not hold the game its library entry was imported as.")
        }
        #expect(Set(paths.map { BatterySaveImporter.romBasename(forStoredFilename: $0) }).count == 2,
                "The two games share a save key.")
    }

    @Test func aDifferentGameWhoseNameDiffersOnlyByItsExtensionGetsItsOwnKey() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImportedFiles(context, importer) }
        let name = "regtest-key-\(UUID().uuidString)"
        let srcA = try source(named: "\(name).gba", bytes: makeValidGBA(title: "KEYGBA"))
        let srcB = try source(named: "\(name).nes", bytes: ImportFixtures.nesROM(seed: 7))
        defer { try? FileManager.default.removeItem(at: srcA.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: srcB.deletingLastPathComponent()) }

        _ = try importer.importROM(from: srcA, method: "picker")
        _ = try importer.importROM(from: srcB, method: "picker")

        let paths = Set(try entries(context).compactMap { $0.value(forKey: "romFilePath") as? String })
        #expect(paths == ["\(name).gba", "\(name) 2.nes"],
                "A NES game named like a GBA game would have shared its battery save and save states.")
    }

    @Test func aZippedDifferentGameUnderATakenNameGetsAFreeName() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImportedFiles(context, importer) }
        let name = "regtest-zip-\(UUID().uuidString)"
        let first = ImportFixtures.nesROM(seed: 31)
        let second = ImportFixtures.nesROM(seed: 32)
        let src = try source(named: "\(name).nes", bytes: first)
        let zip = try source(named: "\(name).zip",
                             bytes: ArchiveBuilder.build([.init(name: "\(name).nes", content: second)]))
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

        _ = try importer.importROM(from: src, method: "picker")
        _ = try importer.importROM(from: zip, method: "picker")

        #expect(try Data(contentsOf: importer.romURL(for: "\(name).nes")) == first,
                "A single-game zip replaced the file of a different game with the same name.")
        #expect(try Data(contentsOf: importer.romURL(for: "\(name) 2.nes")) == second)
    }

    /// The rule itself, on a folder of its own: a key is taken by a cartridge
    /// of any extension or by a disc game's folder, whatever the case.
    @Test func aKeyIsTakenByACartridgeOfAnyExtensionOrADiscFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Tomb Raider (USA)"),
                                                withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("Tetris.gb"))
        try Data([1]).write(to: dir.appendingPathComponent("Tetris 2.gbc"))
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ROMImporter.isKeyTaken("Tetris", in: dir))
        #expect(ROMImporter.isKeyTaken("tetris", in: dir))
        #expect(ROMImporter.isKeyTaken("Tomb Raider (USA)", in: dir))
        #expect(!ROMImporter.isKeyTaken("Tetris 3", in: dir))
        // A free name is kept as it is.
        #expect(ROMImporter.uniqueDestination(for: dir.appendingPathComponent("Zelda.gb")).lastPathComponent == "Zelda.gb")
        // "Tetris" and "Tetris 2" are both taken, by two different extensions.
        #expect(ROMImporter.uniqueDestination(for: dir.appendingPathComponent("Tetris.nes")).lastPathComponent == "Tetris 3.nes")
        // A cartridge named like a disc game's folder.
        #expect(ROMImporter.uniqueDestination(for: dir.appendingPathComponent("Tomb Raider (USA).gba")).lastPathComponent
                == "Tomb Raider (USA) 2.gba")
    }
}
