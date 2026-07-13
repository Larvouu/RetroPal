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
}
