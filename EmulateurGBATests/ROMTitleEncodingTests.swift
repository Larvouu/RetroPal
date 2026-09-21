//
//  ROMTitleEncodingTests.swift
//  EmulateurGBATests
//
//  Two title fixes from the 2026-09-02 language audit, each with a fixture
//  synthesized in-test as ROMParsingSNESNESTests and ROMImporterTests do.
//
//  SNES: the internal name is JIS X 0201, ASCII plus half-width katakana in
//  0xA1-0xDF. Read as strict ASCII, every Japanese cartridge came back
//  untitled and was named after its file instead.
//
//  Game Boy: the 0x134 field holds a NUL-padded title followed by a
//  manufacturer code, and trimming only the ends kept the code glued to
//  the title.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("ROM titles across scripts")
struct ROMTitleEncodingTests {

    /// A LoROM image whose 21-byte title field holds `titleBytes`, space
    /// padded, with a valid checksum pair. Filled with varying bytes so the
    /// header search has to find the real header rather than a run of zeros.
    private func snesROM(titleBytes: [UInt8], headerAt: Int = 0x7FC0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x80000)
        for i in 0..<bytes.count { bytes[i] = UInt8((i &* 7) & 0xFF) }
        var field = titleBytes
        while field.count < 21 { field.append(0x20) }
        for (i, b) in field.prefix(21).enumerated() { bytes[headerAt + i] = b }
        let checksum: UInt16 = 0x1234
        let complement = checksum ^ 0xFFFF
        bytes[headerAt + 0x1C] = UInt8(complement & 0xFF)
        bytes[headerAt + 0x1D] = UInt8(complement >> 8)
        bytes[headerAt + 0x1E] = UInt8(checksum & 0xFF)
        bytes[headerAt + 0x1F] = UInt8(checksum >> 8)
        return Data(bytes)
    }

    /// A Game Boy image with the logo bytes the validator checks, a title at
    /// 0x134 and a manufacturer code in the NUL-padded tail of the field.
    private func gameBoyROM(title: String, manufacturerCode: String) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x150)
        bytes[0x104] = 0xCE; bytes[0x105] = 0xED; bytes[0x106] = 0x66; bytes[0x107] = 0x66
        for (i, b) in Array(title.utf8).prefix(11).enumerated() { bytes[0x134 + i] = b }
        for (i, b) in Array(manufacturerCode.utf8).prefix(4).enumerated() { bytes[0x13F + i] = b }
        return Data(bytes)
    }

    @Test("A Japanese SNES cartridge's half-width katakana title is read")
    func japaneseSNESTitle() {
        // ﾎﾟｹﾓﾝ in JIS X 0201: 0xCE 0xDF 0xB9 0xD3 0xDD
        let rom = snesROM(titleBytes: [0xCE, 0xDF, 0xB9, 0xD3, 0xDD])
        #expect(GBAROMParser.snesHeaderOffset(rom) == 0x7FC0, "the katakana header must still be recognised as a title")
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .snes)
        #expect(info?.systemType == .snes)
        #expect(info?.title == "ﾎﾟｹﾓﾝ")
        print("[title] SNES JIS X 0201 → \(info?.title ?? "-")")
    }

    @Test("An ASCII SNES title reads as before")
    func asciiSNESTitle() {
        let rom = snesROM(titleBytes: Array("SUPER MARIOWORLD".utf8))
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .snes)
        #expect(info?.title == "SUPER MARIOWORLD")
    }

    @Test("A mixed ASCII and katakana SNES title reads whole")
    func mixedSNESTitle() {
        // "DQ ﾄﾞﾗｺﾞﾝ" : ASCII then katakana with voiced marks
        let rom = snesROM(titleBytes: Array("DQ ".utf8) + [0xC4, 0xDE, 0xD7, 0xBA, 0xDE, 0xDD])
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .snes)
        #expect(info?.title == "DQ ﾄﾞﾗｺﾞﾝ")
        print("[title] SNES mixed → \(info?.title ?? "-")")
    }

    @Test("Bytes outside JIS X 0201 in the title field still give no title rather than garbage")
    func bytesOutsideJISX0201() {
        // 0x81 0x40 is a full-width Shift-JIS space, which a SNES header never holds.
        let rom = snesROM(titleBytes: [0x81, 0x40] + Array("GAME".utf8))
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .snes)
        #expect(info?.title == "Unknown Game")
    }

    @Test("A Game Boy title stops at the first NUL and leaves the manufacturer code out")
    func gameBoyTitleStopsAtNUL() {
        // "ZELDA" then six NULs then the code: the old read glued "BAAE" on.
        let rom = gameBoyROM(title: "ZELDA", manufacturerCode: "BAAE")
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .gb)
        #expect(info?.title == "ZELDA")
        print("[title] GB NUL-cut → \(info?.title ?? "-")")
    }

    @Test("A Game Boy title that fills its field is still read whole")
    func gameBoyFullTitle() {
        let rom = gameBoyROM(title: "ZELDA DX", manufacturerCode: "")
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .gb)
        #expect(info?.title == "ZELDA DX")
    }
}
