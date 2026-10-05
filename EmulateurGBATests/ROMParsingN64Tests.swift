//
//  ROMParsingN64Tests.swift
//  EmulateurGBATests
//
//  Coverage for the Nintendo 64, added in 1.3.3, whose cartridges come in three
//  byte orders: `.z64` is the console's own (big-endian), `.v64` swaps every
//  16-bit half, `.n64` reverses every 32-bit word. The parser reads the header
//  in all three and accepts exactly what the core's own `is_valid_rom` accepts,
//  size parity included, so the importer and the core never disagree about
//  what an N64 cartridge is.
//
//  Fixtures are synthesized here, as in ROMImporterTests: no ROMs are bundled.
//

import Testing
import Foundation
@testable import EmulateurGBA

struct ROMParsingN64Tests {

    /// A cartridge in the console's own order: the PI magic, a space-padded
    /// title at 0x20 and the four-character game code at 0x3B.
    private func makeZ64(title: String, code: String, size: Int = 0x100000) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0x40..<bytes.count { bytes[i] = UInt8((i &* 13) & 0xFF) }
        bytes[0] = 0x80; bytes[1] = 0x37; bytes[2] = 0x12; bytes[3] = 0x40
        for (i, b) in Array(title.padding(toLength: 20, withPad: " ", startingAt: 0).utf8).enumerated() {
            bytes[0x20 + i] = b
        }
        for (i, b) in Array(code.utf8).enumerated() {
            bytes[0x3B + i] = b
        }
        return bytes
    }

    /// The same cartridge as a `.v64` dump: each 16-bit half swapped.
    private func toV64(_ z64: [UInt8]) -> [UInt8] {
        var out = z64
        for i in stride(from: 0, to: z64.count - 1, by: 2) {
            out[i] = z64[i + 1]; out[i + 1] = z64[i]
        }
        return out
    }

    /// The same cartridge as a `.n64` dump: each 32-bit word reversed.
    private func toN64(_ z64: [UInt8]) -> [UInt8] {
        var out = z64
        for i in stride(from: 0, to: z64.count - 3, by: 4) {
            out[i] = z64[i + 3]; out[i + 1] = z64[i + 2]
            out[i + 2] = z64[i + 1]; out[i + 3] = z64[i]
        }
        return out
    }

    // MARK: - All three byte orders read the same header

    @Test func readsTitleAndGameCodeInTheConsolesOwnOrder() {
        let rom = Data(makeZ64(title: "SUPER MARIO 64", code: "NSME"))
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .n64)
        #expect(info?.systemType == .n64)
        #expect(info?.title == "SUPER MARIO 64")
        #expect(info?.gameCode == "NSME")
    }

    @Test func readsTheSameHeaderFromAHalfwordSwappedDump() {
        let rom = Data(toV64(makeZ64(title: "SUPER MARIO 64", code: "NSME")))
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .n64)
        #expect(info?.title == "SUPER MARIO 64")
        #expect(info?.gameCode == "NSME")
    }

    @Test func readsTheSameHeaderFromAWordSwappedDump() {
        let rom = Data(toN64(makeZ64(title: "SUPER MARIO 64", code: "NSME")))
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .n64)
        #expect(info?.title == "SUPER MARIO 64")
        #expect(info?.gameCode == "NSME")
    }

    // MARK: - What counts as an N64 cartridge

    @Test func acceptsTheThreeSignaturesAndNothingElse() {
        let z64 = makeZ64(title: "ZELDA", code: "CZLE")
        #expect(GBAROMParser.isValidN64File(data: Data(z64)))
        #expect(GBAROMParser.isValidN64File(data: Data(toV64(z64))))
        #expect(GBAROMParser.isValidN64File(data: Data(toN64(z64))))
        var nes = [UInt8](repeating: 0, count: 0x8000)
        nes[0] = 0x4E; nes[1] = 0x45; nes[2] = 0x53; nes[3] = 0x1A
        #expect(!GBAROMParser.isValidN64File(data: Data(nes)))
        #expect(!GBAROMParser.isValidN64File(data: Data(z64.prefix(0x20))))
    }

    /// The core refuses a `.v64` of odd length and a `.n64` whose length is not
    /// a multiple of four, since neither can be reordered; so does the importer.
    @Test func refusesASwappedDumpTheCoreCouldNotReorder() {
        let z64 = makeZ64(title: "ZELDA", code: "CZLE")
        #expect(!GBAROMParser.isValidN64File(data: Data(toV64(z64) + [0x00])))
        #expect(!GBAROMParser.isValidN64File(data: Data(toN64(z64) + [0x00, 0x00])))
        #expect(GBAROMParser.isValidN64File(data: Data(z64 + [0x00])))
    }

    // MARK: - The extension declares the system, the bytes confirm it

    @Test func allThreeExtensionsResolveToOneStoredSystem() {
        #expect(ROMSystemType.from(fileExtension: "z64") == .n64)
        #expect(ROMSystemType.from(fileExtension: "N64") == .n64)
        #expect(ROMSystemType.from(fileExtension: "v64") == .n64)
        #expect(ROMSystemType.n64.rawValue == "n64")
        #expect(ROMSystemType.allFileExtensions.contains("z64"))
        #expect(ROMSystemType.allFileExtensions.contains("v64"))
    }

    @Test func sniffsAnN64CartridgeWithNoUsableExtension() {
        let rom = Data(toV64(makeZ64(title: "MARIOKART64", code: "NKTE")))
        #expect(GBAROMParser.detectSystemType(data: rom) == .n64)
    }

    // MARK: - Box art identifies every byte order

    /// No-Intro's CRCs are of the console's own order, so the box-art hash of a
    /// `.v64` or `.n64` dump has to come out equal to the `.z64` one, and the
    /// header code (the serial tier) has to read the same from all three.
    @Test func allThreeOrdersHashAndReadAsTheSameCartridge() throws {
        let z64 = makeZ64(title: "SUPER MARIO 64", code: "NSME", size: 0x300000)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("n64-boxart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for (ext, bytes) in [("z64", z64), ("v64", toV64(z64)), ("n64", toN64(z64))] {
            let url = dir.appendingPathComponent("Super Mario 64.\(ext)")
            try Data(bytes).write(to: url)
            urls.append(url)
        }
        let native = BoxArtManager.crc32(of: urls[0])
        #expect(native != nil)
        for url in urls {
            #expect(BoxArtManager.crc32(of: url, system: .n64) == native,
                    "\(url.pathExtension): hashed in the file's order, not the console's")
            #expect(GBAROMParser.gameCode(url: url, system: .n64) == "NSME")
        }
        // Without the console, a swapped dump hashes as the bytes it holds.
        #expect(BoxArtManager.crc32(of: urls[1]) != native)
    }

    // MARK: - RetroAchievements knows it

    /// All three byte orders answer the Nintendo 64 (rcheevos id 2). The answer
    /// is what caches the memory regions BEFORE the load, and a console that
    /// answers 0 has every achievement marked unsupported during it (see the
    /// playlist note in RAClient.mm), so a missing extension here is not a
    /// cosmetic gap.
    @Test func retroAchievementsAnswersTheN64ForAllThreeOrders() {
        #expect(RAClient.consoleId(forROMPath: "/games/Super Mario 64.z64") == 2)
        #expect(RAClient.consoleId(forROMPath: "/games/Mario Kart 64.n64") == 2)
        #expect(RAClient.consoleId(forROMPath: "/games/GoldenEye.V64") == 2)
    }

    // MARK: - Its battery save lands where the core writes it

    @Test func theCoresSaveBlockImportsAsAnSRM() {
        #expect(BatterySaveSystem.srmFamily.compatibleSystemTypes.contains("n64"))
        #expect(BatterySaveSystem.srmFamily.knownSaveSizes.contains(296_960))
        #expect(!BatterySaveSystem.savFamily.compatibleSystemTypes.contains("n64"))
    }

    // MARK: - libdragon's IPL3 (games the core cannot run yet)

    /// A cartridge whose boot code carries libdragon's banner, at the offset
    /// libdragon's own builds put it (0x2FB in DamN64 1.0.0, the 2026 game
    /// that showed the problem).
    private func makeLibdragonZ64() -> [UInt8] {
        var bytes = makeZ64(title: "DamN64", code: "N\0\0\0")
        for (i, b) in Array(" Libdragon IPL3  Coded by Rasky ".utf8).enumerated() {
            bytes[0x2FB + i] = b
        }
        return bytes
    }

    @Test func recognisesLibdragonsBootCodeInAllThreeByteOrders() {
        let z64 = makeLibdragonZ64()
        #expect(GBAROMParser.isLibdragonIPL3(Data(z64)))
        #expect(GBAROMParser.isLibdragonIPL3(Data(toV64(z64))))
        #expect(GBAROMParser.isLibdragonIPL3(Data(toN64(z64))))
    }

    /// Every other cartridge boots as before: the check must never stop a game
    /// the core can run.
    @Test func otherCartridgesAreNotMistakenForLibdragon() {
        #expect(!GBAROMParser.isLibdragonIPL3(Data(makeZ64(title: "SUPER MARIO 64", code: "NSME"))))
        // The banner further than the boot code (a game's own data) is not the boot code.
        var late = makeZ64(title: "SOME GAME", code: "NXXE")
        for (i, b) in Array(" Libdragon IPL3 ".utf8).enumerated() { late[0x2000 + i] = b }
        #expect(!GBAROMParser.isLibdragonIPL3(Data(late)))
        // Too short to hold a boot code, and not a cartridge at all.
        #expect(!GBAROMParser.isLibdragonIPL3(Data(makeLibdragonZ64().prefix(0x800))))
        #expect(!GBAROMParser.isLibdragonIPL3(Data(repeating: 0, count: 0x2000)))
    }
}
