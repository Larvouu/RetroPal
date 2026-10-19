//
//  ROMParsingMDTests.swift
//  EmulateurGBATests
//
//  Coverage for the Mega Drive, added in 1.3.4. Its cartridges come under
//  three names the extension decides (`.md`, `.gen`, the interleaved copier
//  `.smd`) and one it does not: `.bin`, which is also a PlayStation disc's
//  extension, so for that one the bytes decide (`GBAROMParser.isMegaDriveBin`)
//  and a cartridge is stored as `.md`.
//
//  Fixtures are synthesized here, as in ROMParsingN64Tests: no ROMs are
//  bundled. The `.smd` rule (each 16 KB block holds the odd bytes first, the
//  even ones second) was checked on the host against the real core: a
//  cartridge converted with it played identically to the `.md` it came from
//  over 3600 frames (Tools/md-bench, 2026-10-08).
//

import Testing
import Foundation
@testable import EmulateurGBA

struct ROMParsingMDTests {

    /// A cartridge: vectors, "SEGA MEGA DRIVE" at 0x100, the domestic and
    /// overseas names at 0x120 and 0x150 (48 bytes each, space-padded).
    private func makeMD(overseas: String, domestic: String = "",
                        system: String = "SEGA MEGA DRIVE ", size: Int = 0x8000) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0x200..<bytes.count { bytes[i] = UInt8((i &* 7) & 0xFF) }
        func put(_ text: String, at offset: Int, length: Int) {
            for (i, b) in Array(text.padding(toLength: length, withPad: " ", startingAt: 0).utf8).enumerated() {
                bytes[offset + i] = b
            }
        }
        put(system, at: 0x100, length: 16)
        put(domestic, at: 0x120, length: 48)
        put(overseas, at: 0x150, length: 48)
        return bytes
    }

    /// The same cartridge as an `.smd` copier dump: a 512-byte header, then
    /// every 16 KB block with its odd bytes first and its even bytes second.
    private func toSMD(_ md: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 512)
        out[0] = UInt8((md.count / 0x4000) & 0xFF); out[1] = 0x03; out[8] = 0xAA; out[9] = 0xBB
        var pos = 0
        while pos < md.count {
            var block = [UInt8](repeating: 0, count: 0x4000)
            for i in 0..<0x2000 {
                block[0x2000 + i] = md[pos + 2 * i]
                block[i] = md[pos + 2 * i + 1]
            }
            out += block
            pos += 0x4000
        }
        return out
    }

    private func tempFile(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Extensions

    @Test func theThreeCartridgeExtensionsAreTheMegaDrive() {
        for ext in ["md", "gen", "smd", "MD", "Gen"] {
            #expect(ROMSystemType.from(fileExtension: ext) == .md, "\(ext)")
        }
        // `.bin` stays a disc by its extension; only its bytes can make it a cartridge.
        #expect(ROMSystemType.from(fileExtension: "bin") == .ps1)
        for ext in ["md", "gen", "smd"] {
            #expect(ROMSystemType.allFileExtensions.contains(ext), "\(ext) is not offered by the pickers")
        }
    }

    // MARK: - The header

    @Test func readsTheOverseasNameWithItsPaddingFolded() {
        let rom = Data(makeMD(overseas: "SONIC THE               HEDGEHOG"))
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .md)
        #expect(info?.systemType == .md)
        #expect(info?.title == "SONIC THE HEDGEHOG")
    }

    @Test func fallsBackToTheDomesticName() {
        let rom = Data(makeMD(overseas: "", domestic: "PUYO PUYO"))
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .md)
        #expect(info?.title == "PUYO PUYO")
    }

    @Test func acceptsSegaOneSpaceIn() {
        let rom = Data(makeMD(overseas: "GAME", system: " SEGA GENESIS   "))
        #expect(GBAROMParser.isValidMDFile(data: rom))
    }

    @Test func isSniffedWithoutAnExtension() {
        let rom = Data(makeMD(overseas: "GAME"))
        #expect(GBAROMParser.detectSystemType(data: rom) == .md)
    }

    @Test func refusesAMegaCDImageAndNonCartridges() {
        var disc = makeMD(overseas: "GAME")
        for (i, b) in Array("SEGADISCSYSTEM".utf8).enumerated() { disc[i] = b }
        #expect(!GBAROMParser.isValidMDFile(data: Data(disc)))
        #expect(!GBAROMParser.isValidMDFile(data: Data(repeating: 0, count: 0x8000)))
        #expect(!GBAROMParser.isValidMDFile(data: Data(makeMD(overseas: "GAME").prefix(0x100))))
    }

    // MARK: - The copier dump

    @Test func anSMDDumpReadsTheSameHeader() {
        let md = makeMD(overseas: "STREETS OF RAGE")
        let smd = toSMD(md)
        #expect(GBAROMParser.isValidMDFile(data: Data(smd)))
        #expect(GBAROMParser.mdHeader(Data(smd)) == GBAROMParser.mdHeader(Data(md)))
        let info = GBAROMParser.parse(data: Data(smd), fileSize: Int64(smd.count), systemHint: .md)
        #expect(info?.title == "STREETS OF RAGE")
    }

    /// One cartridge cut across several files. The core refuses one with a
    /// fatal error, which would end the app, so the importer refuses it first.
    @Test func aSplitSMDIsRefused() {
        var smd = toSMD(makeMD(overseas: "GAME"))
        smd[2] = 0x40
        #expect(!GBAROMParser.isValidMDFile(data: Data(smd)))
    }

    // MARK: - `.bin`

    @Test func aBinWithTheHeaderIsAMegaDriveCartridgeStoredAsMD() throws {
        let url = try tempFile("Sonic The Hedgehog (USA, Europe).bin", makeMD(overseas: "SONIC"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(GBAROMParser.isMegaDriveBin(url: url))
        #expect(GBAROMParser.storedCartridgeName(for: url) == "Sonic The Hedgehog (USA, Europe).md")
        #expect(GBAROMParser.parse(fileURL: url, systemHint: .md)?.systemType == .md)
    }

    @Test func aBinWithoutTheHeaderStaysADisc() throws {
        // The first bytes of a raw CD sector: the sync pattern, no cartridge header.
        var track = [UInt8](repeating: 0, count: 0x8000)
        track[0] = 0x00
        for i in 1...10 { track[i] = 0xFF }
        let url = try tempFile("Game (Track 1).bin", track)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!GBAROMParser.isMegaDriveBin(url: url))
        #expect(GBAROMParser.storedCartridgeName(for: url) == "Game (Track 1).bin")
    }

    @Test func onlyABinCanBeSniffed() throws {
        let url = try tempFile("Sonic.md", makeMD(overseas: "SONIC"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!GBAROMParser.isMegaDriveBin(url: url))
        #expect(GBAROMParser.storedCartridgeName(for: url) == "Sonic.md")
    }

    /// A batch with a Mega Drive `.bin` and a PlayStation `.cue` + `.bin`: the
    /// cartridge comes back as a cartridge, the disc as one disc.
    @Test func theGrouperSetsAMegaDriveBinAside() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cart = dir.appendingPathComponent("Sonic.bin")
        try Data(makeMD(overseas: "SONIC")).write(to: cart)
        let track = dir.appendingPathComponent("Disc Game.bin")
        try Data(repeating: 0, count: 0x8000).write(to: track)
        let cue = dir.appendingPathComponent("Disc Game.cue")
        try Data("FILE \"Disc Game.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".utf8).write(to: cue)

        let (cartridges, discs, gaps) = DiscImportGrouper.group([cart, cue, track])
        #expect(cartridges.map(\.lastPathComponent) == ["Sonic.bin"])
        #expect(discs.count == 1)
        #expect(discs.first?.boot.lastPathComponent == "Disc Game.cue")
        #expect(gaps.isEmpty)
    }
}
