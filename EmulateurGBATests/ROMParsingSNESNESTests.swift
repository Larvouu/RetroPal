//
//  ROMParsingSNESNESTests.swift
//  EmulateurGBATests
//
//  Coverage for the two consoles added in 1.2.5, whose ROM formats are the first
//  the app has met that cannot be identified from the first 512 bytes.
//
//  NES is easy: iNES and NES 2.0 both open with "NES\x1A", a real magic number.
//
//  SNES has no magic number at all. Its cartridge header sits at 0x7FC0 on a
//  LoROM cart and 0xFFC0 on a HiROM one, with nothing outside the header saying
//  which; a `.smc` dump may shift everything by a 512-byte copier header; and the
//  ExLoROM/ExHiROM carts (Tales of Phantasia, Star Ocean) put theirs 4 MB in. The
//  test is the header's own checksum pair, which must XOR to 0xFFFF — the same
//  test MesenCE's own loader scores, so the app and the core agree about what a
//  SNES ROM is.
//
//  Fixtures are synthesized here, as in ROMImporterTests: no ROMs are bundled.
//

import Testing
import Foundation
@testable import EmulateurGBA

struct ROMParsingSNESNESTests {

    /// A SNES ROM with a valid header (title + checksum pair) at `headerAt`.
    /// Filled with varying bytes rather than zeros so the "does this look like a
    /// title" test has to do real work.
    private func makeSNES(title: String, headerAt: Int, size: Int = 0x80000,
                          checksum: UInt16 = 0x1234) -> Data {
        var bytes = [UInt8](repeating: 0, count: max(size, headerAt + 0x30))
        for i in 0..<bytes.count { bytes[i] = UInt8((i &* 7) & 0xFF) }
        for (i, b) in Array(title.padding(toLength: 21, withPad: " ", startingAt: 0).utf8).enumerated() {
            bytes[headerAt + i] = b
        }
        let complement = checksum ^ 0xFFFF
        bytes[headerAt + 0x1C] = UInt8(complement & 0xFF)
        bytes[headerAt + 0x1D] = UInt8(complement >> 8)
        bytes[headerAt + 0x1E] = UInt8(checksum & 0xFF)
        bytes[headerAt + 0x1F] = UInt8(checksum >> 8)
        return Data(bytes)
    }

    private func makeNES() -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x8000)
        bytes[0] = 0x4E; bytes[1] = 0x45; bytes[2] = 0x53; bytes[3] = 0x1A
        return Data(bytes)
    }

    // MARK: - The four ordinary SNES layouts

    @Test func findsTheLoROMHeader() {
        let rom = makeSNES(title: "SUPER MARIOWORLD", headerAt: 0x7FC0)
        #expect(GBAROMParser.snesHeaderOffset(rom) == 0x7FC0)
        #expect(GBAROMParser.isValidSNESFile(data: rom))
    }

    @Test func findsTheHiROMHeader() {
        let rom = makeSNES(title: "CHRONO TRIGGER", headerAt: 0xFFC0, size: 0x200000)
        #expect(GBAROMParser.snesHeaderOffset(rom) == 0xFFC0)
    }

    /// The same ROM shipped as `.smc`: a 512-byte copier header shifts everything.
    @Test func findsTheHeaderBehindACopierHeader() {
        let rom = Data(repeating: 0, count: 512) + makeSNES(title: "ZELDA", headerAt: 0x7FC0)
        #expect(GBAROMParser.snesHeaderOffset(rom) == 0x81C0)
    }

    /// The carts a shorter search would silently reject at import.
    @Test func findsTheExtendedCartHeaderFourMegabytesIn() {
        let rom = makeSNES(title: "Tales of Phantasia", headerAt: 0x40FFC0, size: 0x600000)
        #expect(GBAROMParser.snesHeaderOffset(rom) == 0x40FFC0)
        #expect(GBAROMParser.isValidSNESFile(data: rom))
    }

    /// Two candidates can carry a valid checksum pair, because a LoROM image can
    /// be mirrored where a HiROM header would sit. The readable title breaks it.
    @Test func prefersTheCandidateThatCarriesAReadableTitle() {
        var bytes = [UInt8](makeSNES(title: "REAL GAME TITLE", headerAt: 0xFFC0, size: 0x200000))
        for i in 0x7FC0..<(0x7FC0 + 21) { bytes[i] = 0x00 }
        bytes[0x7FC0 + 0x1C] = 0xCD; bytes[0x7FC0 + 0x1D] = 0xAB
        bytes[0x7FC0 + 0x1E] = 0x32; bytes[0x7FC0 + 0x1F] = 0x54
        #expect(GBAROMParser.snesHeaderOffset(Data(bytes)) == 0xFFC0)
    }

    // MARK: - The trap this design avoids

    /// The first version deduced the copier header from the buffer's length,
    /// which is only meaningful for a WHOLE file: every prefix read of 0x10200
    /// bytes measures as "512 over a multiple of 1 KB" and would have claimed a
    /// copier header that is not there.
    @Test func aPartialReadIsNotMistakenForACopierHeader() {
        let rom = makeSNES(title: "SUPER MARIOWORLD", headerAt: 0x7FC0)
        let prefix = rom.prefix(0x10200)
        #expect(prefix.count % 1024 == 512)
        #expect(GBAROMParser.snesHeaderOffset(Data(prefix)) == 0x7FC0)
    }

    // MARK: - Nothing else is mistaken for these two

    @Test func doesNotConfuseTheOtherConsoles() {
        var gba = [UInt8](repeating: 0, count: 0x100000)
        gba[0xB2] = 0x96
        #expect(!GBAROMParser.isValidSNESFile(data: Data(gba)))
        #expect(!GBAROMParser.isValidNESFile(data: Data(gba)))
        #expect(GBAROMParser.isValidGBAFile(data: Data(gba)))

        var gb = [UInt8](repeating: 0, count: 0x8000)
        gb[0x104] = 0xCE; gb[0x105] = 0xED; gb[0x106] = 0x66; gb[0x107] = 0x66
        #expect(!GBAROMParser.isValidSNESFile(data: Data(gb)))
        #expect(GBAROMParser.isValidGBFile(data: Data(gb)))

        let noise = Data((0..<0x200000).map { UInt8(($0 &* 31 &+ 7) & 0xFF) })
        #expect(!GBAROMParser.isValidSNESFile(data: noise))
    }

    @Test func acceptsTheINESMagicAndNothingElse() {
        #expect(GBAROMParser.isValidNESFile(data: makeNES()))
        #expect(!GBAROMParser.isValidNESFile(data: Data("NES".utf8)))
        #expect(!GBAROMParser.isValidNESFile(data: makeSNES(title: "X", headerAt: 0x7FC0)))
    }

    // MARK: - The extension is still what declares the system

    @Test func bothSNESExtensionsResolveToOneStoredSystem() {
        #expect(ROMSystemType.from(fileExtension: "sfc") == .snes)
        #expect(ROMSystemType.from(fileExtension: "SMC") == .snes)
        #expect(ROMSystemType.from(fileExtension: "nes") == .nes)
        // The stored value is one per console, never per extension: a game
        // imported as .smc and the same game as .sfc must land in one place.
        #expect(ROMSystemType.snes.rawValue == "snes")
        #expect(ROMSystemType.nes.rawValue == "nes")
    }

    @Test func parseReadsTheSNESTitleAndLeavesNESToItsFilename() {
        let snes = makeSNES(title: "SUPER METROID", headerAt: 0x7FC0)
        let info = GBAROMParser.parse(data: snes, fileSize: Int64(snes.count), systemHint: .snes)
        #expect(info?.systemType == .snes)
        #expect(info?.title == "SUPER METROID")
        #expect(info?.gameCode == "")

        let nes = makeNES()
        let nesInfo = GBAROMParser.parse(data: nes, fileSize: Int64(nes.count), systemHint: .nes)
        #expect(nesInfo?.systemType == .nes)
        // No title in an iNES header, so the parser falls back the same way it
        // does for a GB ROM with a blank title field.
        #expect(nesInfo?.title == "Unknown Game")
    }
}
