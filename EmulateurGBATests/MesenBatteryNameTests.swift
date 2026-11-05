//
//  MesenBatteryNameTests.swift
//  EmulateurGBATests
//
//  A Super Nintendo game's battery save under an accented or Japanese name,
//  through the real MesenCE core (audit, 2026-10-29). Until then the bridge
//  named Mesen's file with `%s`, which reads a C string as MacRoman on iOS:
//  for "Pokémon" it looked for "Pok√©mon.srm" while Mesen wrote "Pokémon.srm",
//  so the player's save never reached the game and the game's never left it.
//  Broken since 1.2.5 for the SNES, the NES, the Master System and the Game
//  Gear, which all go through the same name.
//
//  The game is synthetic, made here: a LoROM header saying 2 KB of battery
//  RAM (type 0x02, SRAM size 1, which is how Mesen sizes it,
//  `BaseCartridge.cpp`), a reset vector on a loop that does nothing. No game
//  content, so it runs on the phone.
//

import Testing
import Foundation
@testable import EmulateurGBA

// NESTED in the save-state suite, which is `.serialized` (a trait nested
// suites inherit): every test that starts a real core runs one at a time, in
// that suite's order, as the PPSSPP case there explains. A first version ran
// on its own, in parallel with the other cores (⌘U 2026-10-29 stalled).
extension SaveStateCompatibilityTests {
@Suite("MesenCE battery saves under any name")
struct MesenBatteryNameTests {

    /// 128 KB, LoROM, "ROM + RAM + battery", 2 KB of SRAM.
    private static func batteryCartridge() -> Data {
        var rom = [UInt8](repeating: 0xEA, count: 0x20000)   // NOP
        let header = 0x7FC0
        for (i, b) in Array("RETRO PAL SRAM TEST  ".utf8).enumerated() { rom[header + i] = b }
        rom[header + 0x15] = 0x20    // LoROM, slow
        rom[header + 0x16] = 0x02    // ROM + RAM + battery
        rom[header + 0x17] = 0x07    // 128 KB
        rom[header + 0x18] = 0x01    // 2 KB of SRAM
        rom[header + 0x19] = 0x01    // North America
        // The checksum pair only has to agree with itself for the score.
        rom[header + 0x1C] = 0xFF; rom[header + 0x1D] = 0xFF
        rom[header + 0x1E] = 0x00; rom[header + 0x1F] = 0x00
        // Reset vector (emulation mode, 0xFFFC in bank 0 = 0x7FFC here) to a
        // `BRA -2` at 0x8000: the CPU loops and touches nothing.
        rom[0x7FFC] = 0x00; rom[0x7FFD] = 0x80
        rom[0x0000] = 0x80; rom[0x0001] = 0xFE
        return Data(rom)
    }

    private static let saveBytes = 2048

    /// Mesen's own folder for this game's battery file (`MesenBridge
    /// configureFolders`), the name as Mesen builds it (UTF-8).
    private static func mesenFile(_ basename: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mesen/Battery", isDirectory: true)
            .appendingPathComponent(basename + ".srm")
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mesen-battery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The session's order (`EmulatorSession.loadROMCore`): load, the save
    /// path, a reset that makes the save the cartridge's, a frame, then the
    /// flush every quit and background does.
    @Test("An imported save reaches the game and comes back out, under an accented or Japanese name",
          arguments: ["Pokémon Émeraude", "ポケモン スタジアム", "Plain Name"])
    func saveRoundTrip(_ name: String) throws {
        let dir = try scratch()
        let basename = "\(name) \(UUID().uuidString.prefix(6))"
        let rom = dir.appendingPathComponent(basename + ".sfc")
        let save = dir.appendingPathComponent(basename + ".sav")
        let shadow = Self.mesenFile(basename)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: shadow)
        }
        try Self.batteryCartridge().write(to: rom)
        let pattern = Data((0..<Self.saveBytes).map { UInt8(($0 &* 31 &+ 7) & 0xFF) })
        try pattern.write(to: save)

        let bridge = MesenBridge()
        defer { bridge.shutdown() }
        #expect(bridge.loadROM(atPath: rom.path), "the synthetic cartridge did not load")
        bridge.setSavePath(save.path)
        // Seeded under the name Mesen reads (was MacRoman: "Pok√©mon...").
        #expect(FileManager.default.fileExists(atPath: shadow.path),
                "the save was not given to the core under its own name")
        bridge.reset()
        bridge.runFrame()
        // Out of the CORE, not left over: the canonical file goes, and the
        // flush must make it again from the cartridge's RAM, which holds the
        // save only if the core read it. Before the fix nothing was read and
        // nothing copied back: the file stayed gone.
        try FileManager.default.removeItem(at: save)
        bridge.flushSaveData()
        let back = try #require(try? Data(contentsOf: save), "the flush did not write the save back")
        #expect(back == pattern, "the save did not come back out of the core unchanged")
        print("[mesen] \(name): seeded and flushed back, \(back.count) bytes")
    }

    /// The name the bridge used to give Mesen's file, made by the SAME calls
    /// the bridge makes (`MesenBridge loadROMAtPath:`: the path's last
    /// component, its extension dropped, `UTF8String`), then those bytes read
    /// in the system's C-string encoding as `%s` read them (MacRoman on iOS).
    /// Not from the test's own string: iOS hands a path's name back
    /// DECOMPOSED ("e" + accent, 65 CC 81, not C3 A9), and the first version,
    /// built from the composed string, made an old name no phone ever had
    /// (⌘U 2026-10-30: the test saw its file, the bridge looked for another).
    private static func legacyFile(romPath: String) -> URL? {
        let base = ((romPath as NSString).lastPathComponent as NSString).deletingPathExtension as NSString
        guard let cBytes = base.utf8String else { return nil }
        let bytes = Data(bytes: cBytes, count: strlen(cBytes))
        guard let legacy = String(data: bytes, encoding: String.Encoding(rawValue: NSString.defaultCStringEncoding)),
              legacy != (base as String) else { return nil }
        return mesenFile(legacy)
    }

    /// A game the old name broke (its saves only in Mesen's file, the bridge's
    /// mis-named file beside it): the core's save is copied out, the canonical
    /// one kept in Backups first, the old file removed so it runs once. With
    /// the dates in either order: a phone ended by iOS in the background left
    /// the canonical file the NEWER of the two (re-audit, 2026-10-29).
    @Test("A save only the core kept, under the old broken name, is copied out, the old one backed up",
          arguments: [true, false])
    func coreSaveRescuedOnce(canonicalIsNewer: Bool) throws {
        let dir = try scratch()
        let basename = "Pokémon Or \(UUID().uuidString.prefix(6))"
        let rom = dir.appendingPathComponent(basename + ".sfc")
        guard let legacy = Self.legacyFile(romPath: rom.path) else {
            // A system whose C strings are UTF-8 never had the old bug.
            print("[mesen] no legacy name on this system: nothing to rescue")
            return
        }
        let save = dir.appendingPathComponent(basename + ".sav")
        let shadow = Self.mesenFile(basename)
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: shadow)
            try? FileManager.default.removeItem(at: legacy)
        }
        try Self.batteryCartridge().write(to: rom)
        let oldImport = Data(repeating: 0x11, count: Self.saveBytes)
        let weeksOfPlay = Data(repeating: 0x77, count: Self.saveBytes)
        try FileManager.default.createDirectory(at: shadow.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try weeksOfPlay.write(to: shadow)
        try oldImport.write(to: legacy)
        try oldImport.write(to: save)
        let old = Date().addingTimeInterval(-86_400)
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: (canonicalIsNewer ? shadow : save).path)

        print("[mesen] rescue: old file \(legacy.lastPathComponent), there: \(FileManager.default.fileExists(atPath: legacy.path))")
        let bridge = MesenBridge()
        defer { bridge.shutdown() }
        #expect(bridge.loadROM(atPath: rom.path))
        bridge.setSavePath(save.path)
        #expect(try Data(contentsOf: save) == weeksOfPlay, "the core's save was not copied out")
        #expect(!FileManager.default.fileExists(atPath: legacy.path), "the old mis-named file is still there")
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        #expect(kept.contains { $0.hasPrefix(basename + "-before-name-fix-") }, "the canonical save was not backed up")
    }

    /// Without that proof the canonical file wins, whatever the dates: every
    /// quit leaves Mesen's file a few milliseconds newer (`Emulator::Release`
    /// saves it again), and a backup restored in Files keeps its old date, so
    /// a newer-date rule put a stale core file over a restored save
    /// (re-audit, 2026-10-29).
    @Test("With no old mis-named file, the canonical save wins even when the core's file is newer")
    func canonicalWinsWithoutProof() throws {
        let dir = try scratch()
        let basename = "Pokémon Argent \(UUID().uuidString.prefix(6))"
        let rom = dir.appendingPathComponent(basename + ".sfc")
        let save = dir.appendingPathComponent(basename + ".sav")
        let shadow = Self.mesenFile(basename)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: shadow)
        }
        try Self.batteryCartridge().write(to: rom)
        let restored = Data(repeating: 0x22, count: Self.saveBytes)
        let stale = Data(repeating: 0x55, count: Self.saveBytes)
        try restored.write(to: save)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400 * 30)],
                                              ofItemAtPath: save.path)
        try FileManager.default.createDirectory(at: shadow.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try stale.write(to: shadow)

        let bridge = MesenBridge()
        defer { bridge.shutdown() }
        #expect(bridge.loadROM(atPath: rom.path))
        bridge.setSavePath(save.path)
        #expect(try Data(contentsOf: shadow) == restored, "a stale core file was kept over the restored save")
        #expect(try Data(contentsOf: save) == restored, "the restored save was overwritten")
        // And the core's own file, which held bytes the canonical one did not,
        // is kept in Backups rather than deleted (audit, 2026-10-30).
        let kept = (try? FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("Backups").path)) ?? []
        let copy = try #require(kept.first { $0.hasPrefix(basename + "-core-before-seed-") },
                                "the core's own file was deleted with no copy")
        #expect(try Data(contentsOf: dir.appendingPathComponent("Backups").appendingPathComponent(copy)) == stale)
    }

    /// The old mis-named file no longer matches the canonical save: a save was
    /// imported (or pulled, or restored) after the old build last ran, so the
    /// player's choice wins, the core's file is kept in Backups, and the old
    /// file goes. Any old file used to trigger the rescue, over the import
    /// (audit, 2026-10-30).
    @Test("A save imported after the old build wins over the core's file, which is kept")
    func aSaveImportedSinceWinsOverTheRescue() throws {
        let dir = try scratch()
        let basename = "Pokémon Cristal \(UUID().uuidString.prefix(6))"
        let rom = dir.appendingPathComponent(basename + ".sfc")
        guard let legacy = Self.legacyFile(romPath: rom.path) else {
            print("[mesen] no legacy name on this system: nothing to rescue")
            return
        }
        let save = dir.appendingPathComponent(basename + ".sav")
        let shadow = Self.mesenFile(basename)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: shadow)
            try? FileManager.default.removeItem(at: legacy)
        }
        try Self.batteryCartridge().write(to: rom)
        let lastOldBuildSave = Data(repeating: 0x11, count: Self.saveBytes)
        let coreFile = Data(repeating: 0x77, count: Self.saveBytes)
        let importedSince = Data(repeating: 0x33, count: Self.saveBytes)
        try FileManager.default.createDirectory(at: shadow.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try coreFile.write(to: shadow)
        try lastOldBuildSave.write(to: legacy)
        try importedSince.write(to: save)

        let bridge = MesenBridge()
        defer { bridge.shutdown() }
        #expect(bridge.loadROM(atPath: rom.path))
        bridge.setSavePath(save.path)
        #expect(try Data(contentsOf: save) == importedSince, "the save imported since was replaced")
        #expect(try Data(contentsOf: shadow) == importedSince, "the game was not given the imported save")
        #expect(!FileManager.default.fileExists(atPath: legacy.path), "the old mis-named file is still there")
        let kept = (try? FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("Backups").path)) ?? []
        let copy = try #require(kept.first { $0.hasPrefix(basename + "-core-before-seed-") },
                                "the core's own file was deleted with no copy")
        #expect(try Data(contentsOf: dir.appendingPathComponent("Backups").appendingPathComponent(copy)) == coreFile)
    }
}
}
