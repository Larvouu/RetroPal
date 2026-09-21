//
//  NDSBannerTitleTests.swift
//  EmulateurGBATests
//
//  A DS cartridge carries a banner with the game's title in six to eight
//  languages, and until 2026-09-03 the app never read it: every DS game was
//  named after its 12-byte code name. These fixtures are synthesized here, as
//  the SNES and GBA ones are: a valid header (Nintendo logo prefix at 0xC0,
//  code name at 0x000, banner offset at 0x68) and a banner block with UTF-16LE
//  titles laid out exactly as the hardware expects them.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("NDS banner title")
struct NDSBannerTitleTests {

    private static let bannerOffset = 0x1000

    /// A DS image whose banner holds the given titles. `titles` maps the
    /// banner language slot to the raw multi-line text (lines separated by
    /// "\n"), exactly as a cartridge stores it.
    private func nds(codeName: String = "POKEMON PL", titles: [String: String],
                     version: UInt16 = 1, bannerOffset: Int? = Self.bannerOffset) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x3000)
        for (i, b) in Array(codeName.utf8).prefix(12).enumerated() { bytes[i] = b }
        for (i, b) in Array("CPUF".utf8).enumerated() { bytes[0x0C + i] = b }
        // Nintendo logo prefix, the fast path of isValidNDSFile.
        for (i, b) in [0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21].enumerated() { bytes[0xC0 + i] = UInt8(b) }
        if let offset = bannerOffset {
            bytes[0x68] = UInt8(offset & 0xFF); bytes[0x69] = UInt8((offset >> 8) & 0xFF)
            bytes[0x6A] = UInt8((offset >> 16) & 0xFF); bytes[0x6B] = UInt8(offset >> 24)
            if offset + 1 < bytes.count {
                bytes[offset] = UInt8(version & 0xFF); bytes[offset + 1] = UInt8(version >> 8)
            }
            let slots: [String: Int] = ["ja": 0x240, "en": 0x340, "fr": 0x440, "de": 0x540,
                                        "it": 0x640, "es": 0x740, "zh": 0x840, "ko": 0x940]
            for (language, text) in titles {
                guard let slot = slots[language] else { continue }
                var i = offset + slot
                for unit in Array(text.utf16).prefix(127) {
                    // One case points the banner past the file on purpose; the
                    // fixture must not write there either.
                    guard i + 1 < bytes.count else { break }
                    bytes[i] = UInt8(unit & 0xFF); bytes[i + 1] = UInt8(unit >> 8); i += 2
                }
            }
        }
        return Data(bytes)
    }

    private let platinum: [String: String] = [
        "ja": "ポケットモンスター\nプラチナ\nポケモン",
        "en": "Pokémon\nPlatinum Version\nNintendo",
        "fr": "Pokémon\nVersion Platine\nNintendo",
        "de": "Pokémon\nPlatin-Edition\nNintendo",
    ]

    @Test("A French phone reads the French title, publisher dropped, subtitle kept")
    func frenchTitle() {
        let rom = nds(titles: platinum)
        #expect(GBAROMParser.ndsBannerTitle(rom, preferredLanguages: ["fr-FR"]) == "Pokémon Version Platine")
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .nds)
        #expect(info?.title == "Pokémon Version Platine")
        #expect(info?.gameCode == "CPUF")
        print("[nds] fr → \(info?.title ?? "-")")
    }

    @Test("English and German phones read their own slots")
    func otherLanguages() {
        let rom = nds(titles: platinum)
        #expect(GBAROMParser.ndsBannerTitle(rom, preferredLanguages: ["en-US"]) == "Pokémon Platinum Version")
        #expect(GBAROMParser.ndsBannerTitle(rom, preferredLanguages: ["de-DE"]) == "Pokémon Platin-Edition")
        #expect(GBAROMParser.ndsBannerTitle(rom, preferredLanguages: ["ja-JP"]) == "ポケットモンスター プラチナ")
    }

    @Test("A language the banner lacks falls back to English, then Japanese")
    func fallbacks() {
        let rom = nds(titles: platinum)
        #expect(GBAROMParser.ndsBannerTitle(rom, preferredLanguages: ["sv-SE"]) == "Pokémon Platinum Version")
        let japaneseOnly = nds(titles: ["ja": "ポケットモンスター\nプラチナ\nポケモン"])
        #expect(GBAROMParser.ndsBannerTitle(japaneseOnly, preferredLanguages: ["fr-FR"]) == "ポケットモンスター プラチナ")
    }

    @Test("A two-line title is the name alone, the publisher being the second line")
    func twoLines() {
        let rom = nds(titles: ["en": "Tetris DS\nNintendo", "fr": "Tetris DS\nNintendo"])
        #expect(GBAROMParser.ndsBannerTitle(rom, preferredLanguages: ["fr-FR"]) == "Tetris DS")
    }

    @Test("Korean needs banner version 3; on an older banner the Korean phone gets English")
    func koreanSlotByVersion() {
        let v1 = nds(titles: ["en": "Game\nPub", "ko": "게임\n퍼블리셔"], version: 1)
        #expect(GBAROMParser.ndsBannerTitle(v1, preferredLanguages: ["ko-KR"]) == "Game")
        let v3 = nds(titles: ["en": "Game\nPub", "ko": "게임\n퍼블리셔"], version: 3)
        #expect(GBAROMParser.ndsBannerTitle(v3, preferredLanguages: ["ko-KR"]) == "게임")
    }

    @Test("Without a banner the 12-byte code name is the title, as before")
    func noBanner() {
        let rom = nds(titles: [:], bannerOffset: nil)
        #expect(GBAROMParser.ndsBannerTitle(rom, preferredLanguages: ["fr-FR"]) == nil)
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .nds)
        #expect(info?.title == "POKEMON PL")
    }

    @Test("A banner offset outside the file cannot trap and yields the code name")
    func bannerBeyondFile() {
        let rom = nds(titles: platinum, bannerOffset: 0x2F00)   // header says 0x2F00, file ends at 0x3000
        #expect(GBAROMParser.ndsBannerTitle(rom, preferredLanguages: ["fr-FR"]) == nil)
        let info = GBAROMParser.parse(data: rom, fileSize: Int64(rom.count), systemHint: .nds)
        #expect(info?.title == "POKEMON PL")
    }

    @Test("The header-title probe used by box-art matching agrees with the parser")
    func headerTitleAgrees() throws {
        let rom = nds(titles: platinum)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("banner-\(UUID().uuidString).nds")
        try rom.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = LegacyTextEncoding.$preferredLanguagesOverride.withValue(["fr-FR"]) {
            GBAROMParser.headerTitle(url: url, system: .nds)
        }
        #expect(probe == "Pokémon Version Platine")
    }
}
