//
//  LegacyTextEncodingTests.swift
//  EmulateurGBATests
//
//  The bytes below are what real archivers write. Each was produced by
//  encoding the name with Python's codecs (cp932, cp949, cp950, cp936, cp850)
//  and is therefore what Windows Explorer or 7-Zip on that locale's Windows
//  puts in a zip, since both write the machine's OEM codepage with no flag.
//  Cross-decoding the same bytes shows why the user's own codepage has to
//  come first: the CP850 bytes of "Pokémon.gba" are VALID Shift-JIS and read
//  "PokＮon.gba" there, so no single fallback can be right for everyone.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("LegacyTextEncoding")
struct LegacyTextEncodingTests {

    private let cp932Pokemon: [UInt8]  = [0x83, 0x7C, 0x83, 0x50, 0x83, 0x82, 0x83, 0x93, 0x2E, 0x67, 0x62, 0x61] // ポケモン.gba
    private let cp949Pokemon: [UInt8]  = [0xC6, 0xF7, 0xC4, 0xCF, 0xB8, 0xF3, 0x2E, 0x67, 0x62, 0x61]             // 포켓몬.gba
    private let cp950Pokemon: [UInt8]  = [0xC4, 0x5F, 0xA5, 0x69, 0xB9, 0xDA, 0x2E, 0x67, 0x62, 0x61]             // 寶可夢.gba
    private let cp936Pokemon: [UInt8]  = [0xB1, 0xA6, 0xBF, 0xC9, 0xC3, 0xCE, 0x2E, 0x67, 0x62, 0x61]             // 宝可梦.gba
    private let cp850Pokemon: [UInt8]  = [0x50, 0x6F, 0x6B, 0x82, 0x6D, 0x6F, 0x6E, 0x2E, 0x67, 0x62, 0x61]       // Pokémon.gba
    private let cp850Uebung: [UInt8]   = [0x5A, 0x65, 0x6C, 0x64, 0x61, 0x20, 0x9A, 0x62, 0x75, 0x6E, 0x67, 0x2E, 0x67, 0x62, 0x61] // Zelda Übung.gba
    private let utf8Pokemon: [UInt8]   = [0x50, 0x6F, 0x6B, 0xC3, 0xA9, 0x6D, 0x6F, 0x6E, 0x2E, 0x67, 0x62, 0x61] // Pokémon.gba

    @Test("A Japanese Windows zip on a Japanese phone")
    func japaneseOnJapanese() {
        #expect(LegacyTextEncoding.decode(Data(cp932Pokemon), preferredLanguages: ["ja-JP"]) == "ポケモン.gba")
    }

    @Test("A Korean Windows zip on a Korean phone")
    func koreanOnKorean() {
        #expect(LegacyTextEncoding.decode(Data(cp949Pokemon), preferredLanguages: ["ko-KR"]) == "포켓몬.gba")
    }

    @Test("A Taiwanese Windows zip on a Traditional Chinese phone")
    func traditionalChinese() {
        #expect(LegacyTextEncoding.decode(Data(cp950Pokemon), preferredLanguages: ["zh-Hant-TW"]) == "寶可夢.gba")
    }

    @Test("A mainland Windows zip on a Simplified Chinese phone")
    func simplifiedChinese() {
        #expect(LegacyTextEncoding.decode(Data(cp936Pokemon), preferredLanguages: ["zh-Hans-CN"]) == "宝可梦.gba")
    }

    @Test("A French Windows zip on a French phone, the case the Shift-JIS guess broke")
    func frenchOnFrench() {
        #expect(LegacyTextEncoding.decode(Data(cp850Pokemon), preferredLanguages: ["fr-FR"]) == "Pokémon.gba")
    }

    @Test("A German Windows zip on a German phone")
    func germanOnGerman() {
        #expect(LegacyTextEncoding.decode(Data(cp850Uebung), preferredLanguages: ["de-DE"]) == "Zelda Übung.gba")
    }

    @Test("Unflagged UTF-8 is trusted before any codepage, even on a Japanese phone")
    func utf8First() {
        #expect(LegacyTextEncoding.decode(Data(utf8Pokemon), preferredLanguages: ["ja-JP"]) == "Pokémon.gba")
    }

    @Test("The extension survives whatever the codepage guess does, so the game still imports")
    func extensionSurvives() {
        let foreign = LegacyTextEncoding.decode(Data(cp932Pokemon), preferredLanguages: ["fr-FR"])
        #expect(foreign.hasSuffix(".gba"))
    }

    @Test("The user's own codepage comes first and Japanese is CP932 through .shiftJIS")
    func ownCodepageFirst() {
        #expect(LegacyTextEncoding.candidates(forPreferredLanguages: ["ja-JP", "en-US"]).first == String.Encoding.shiftJIS)
        #expect(LegacyTextEncoding.oemEncoding(forLanguageTag: "ja") == .shiftJIS)
        #expect(LegacyTextEncoding.oemEncoding(forLanguageTag: "zh-Hant-TW") == LegacyTextEncoding.oemEncoding(forLanguageTag: "zh_TW"))
        #expect(LegacyTextEncoding.oemEncoding(forLanguageTag: "zh-Hant-TW") != LegacyTextEncoding.oemEncoding(forLanguageTag: "zh-Hans-CN"))
    }

    @Test("A Shift-JIS cue sheet names its bin correctly, 0x5C trail byte included")
    func shiftJISCueSheet() {
        // FILE "ソニック.bin" BINARY, with ソ = 0x83 0x5C: the trail byte is a
        // backslash in ASCII, which is the classic Shift-JIS trap.
        var bytes: [UInt8] = Array("FILE \"".utf8)
        bytes += [0x83, 0x5C, 0x83, 0x6A, 0x83, 0x62, 0x83, 0x4E]
        bytes += Array(".bin\" BINARY".utf8)
        let text = LegacyTextEncoding.decode(Data(bytes), preferredLanguages: ["ja-JP"])
        #expect(text == "FILE \"ソニック.bin\" BINARY")
        #expect(!LegacyTextEncoding.isUTF8(Data(bytes)))
    }
}

@Suite("ZIP entry names")
struct ZIPEntryNameDecodingTests {

    private let cp850Pokemon: [UInt8] = [0x50, 0x6F, 0x6B, 0x82, 0x6D, 0x6F, 0x6E, 0x2E, 0x67, 0x62, 0x61]
    private let utf8Pokemon: [UInt8]  = [0x50, 0x6F, 0x6B, 0xC3, 0xA9, 0x6D, 0x6F, 0x6E, 0x2E, 0x67, 0x62, 0x61]

    /// An Info-ZIP Unicode Path extra field (0x7075) for `utf8Name`, carrying
    /// the given CRC of the raw header name.
    private func unicodePathField(crc: UInt32, utf8Name: [UInt8]) -> Data {
        let size = 1 + 4 + utf8Name.count
        var bytes: [UInt8] = [0x75, 0x70, UInt8(size & 0xFF), UInt8(size >> 8), 0x01]
        bytes += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
        bytes += utf8Name
        return Data(bytes)
    }

    @Test("CRC-32 matches the standard check value")
    func crc32Reference() {
        #expect(ZIPExtractor.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }

    @Test("Bit 11 means UTF-8, whatever the phone's language")
    func bit11() {
        let name = ZIPExtractor.decodeEntryName(Data(utf8Pokemon), flags: 0x0800, extra: nil, preferredLanguages: ["ja-JP"])
        #expect(name == "Pokémon.gba")
    }

    @Test("The Unicode Path extra field wins when its CRC matches the raw name")
    func unicodePathTrusted() {
        let raw = Data(cp850Pokemon)
        let extra = unicodePathField(crc: ZIPExtractor.crc32(raw), utf8Name: utf8Pokemon)
        let name = ZIPExtractor.decodeEntryName(raw, flags: 0, extra: extra, preferredLanguages: ["ja-JP"])
        #expect(name == "Pokémon.gba")
    }

    @Test("A Unicode Path field with a stale CRC is ignored, per the spec")
    func unicodePathStale() {
        let raw = Data(cp850Pokemon)
        let extra = unicodePathField(crc: 0xDEADBEEF, utf8Name: utf8Pokemon)
        let name = ZIPExtractor.decodeEntryName(raw, flags: 0, extra: extra, preferredLanguages: ["fr-FR"])
        #expect(name == "Pokémon.gba")   // from CP850, not from the field
    }

    @Test("Other extra fields are walked past without confusion")
    func otherExtraFields() {
        // A 0x5455 (extended timestamp) block, then nothing useful.
        let extra = Data([0x55, 0x54, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        let name = ZIPExtractor.decodeEntryName(Data(cp850Pokemon), flags: 0, extra: extra, preferredLanguages: ["fr-FR"])
        #expect(name == "Pokémon.gba")
        #expect(ZIPExtractor.unicodePathExtraField(in: extra, rawName: Data(cp850Pokemon)) == nil)
    }

    @Test("A truncated extra field cannot trap")
    func truncatedExtra() {
        let extra = Data([0x75, 0x70, 0xFF, 0x7F, 0x01])
        #expect(ZIPExtractor.unicodePathExtraField(in: extra, rawName: Data(cp850Pokemon)) == nil)
    }
}

// MARK: - Every language the app ships

/// One row per shipped locale: a game name in that language's own letters,
/// encoded in the OEM codepage a Windows machine set to that language writes
/// into a zip with no flag. Bytes from Python's codecs (`"…".encode("cp850")`
/// and so on), which is what Explorer and 7-Zip produce on that Windows.
struct LocaleCodepageRow: CustomTestStringConvertible {
    let locale: String
    let codepage: String
    let name: String
    let bytes: [UInt8]
    var testDescription: String { "\(locale) · \(codepage) · \(name)" }
}

let localeCodepageRows: [LocaleCodepageRow] = [
    .init(locale: "en",      codepage: "cp437", name: "Café Crème.gba",       bytes: [0x43, 0x61, 0x66, 0x82, 0x20, 0x43, 0x72, 0x8A, 0x6D, 0x65, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "fr",      codepage: "cp850", name: "Pokémon Émeraude.gba", bytes: [0x50, 0x6F, 0x6B, 0x82, 0x6D, 0x6F, 0x6E, 0x20, 0x90, 0x6D, 0x65, 0x72, 0x61, 0x75, 0x64, 0x65, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "de",      codepage: "cp850", name: "Zelda Übung.gba",      bytes: [0x5A, 0x65, 0x6C, 0x64, 0x61, 0x20, 0x9A, 0x62, 0x75, 0x6E, 0x67, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "es",      codepage: "cp850", name: "Añoranza.gba",         bytes: [0x41, 0xA4, 0x6F, 0x72, 0x61, 0x6E, 0x7A, 0x61, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "es-MX",   codepage: "cp850", name: "Añoranza.gba",         bytes: [0x41, 0xA4, 0x6F, 0x72, 0x61, 0x6E, 0x7A, 0x61, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "it",      codepage: "cp850", name: "Perché.gba",           bytes: [0x50, 0x65, 0x72, 0x63, 0x68, 0x82, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "pt-BR",   codepage: "cp850", name: "Coração.gba",          bytes: [0x43, 0x6F, 0x72, 0x61, 0x87, 0xC6, 0x6F, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "pt-PT",   codepage: "cp850", name: "Coração.gba",          bytes: [0x43, 0x6F, 0x72, 0x61, 0x87, 0xC6, 0x6F, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "nl",      codepage: "cp850", name: "Eén Spel.gba",         bytes: [0x45, 0x82, 0x6E, 0x20, 0x53, 0x70, 0x65, 0x6C, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "sv",      codepage: "cp850", name: "Räksmörgås.gba",       bytes: [0x52, 0x84, 0x6B, 0x73, 0x6D, 0x94, 0x72, 0x67, 0x86, 0x73, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "pl",      codepage: "cp852", name: "Żółw.gba",             bytes: [0xBD, 0xA2, 0x88, 0x77, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "ro",      codepage: "cp852", name: "Pădure.gba",           bytes: [0x50, 0xC7, 0x64, 0x75, 0x72, 0x65, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "ja",      codepage: "cp932", name: "ポケモン.gba",           bytes: [0x83, 0x7C, 0x83, 0x50, 0x83, 0x82, 0x83, 0x93, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "ko",      codepage: "cp949", name: "포켓몬.gba",            bytes: [0xC6, 0xF7, 0xC4, 0xCF, 0xB8, 0xF3, 0x2E, 0x67, 0x62, 0x61]),
    .init(locale: "zh-Hant", codepage: "cp950", name: "寶可夢.gba",            bytes: [0xC4, 0x5F, 0xA5, 0x69, 0xB9, 0xDA, 0x2E, 0x67, 0x62, 0x61]),
]

/// Language tags in every shape the system hands out, and the tag whose
/// codepage they must share.
let languageTagShapes: [(tag: String, sameAs: String)] = [
    ("fr-FR", "fr"), ("fr_FR", "fr"), ("fr-CA", "fr"), ("de-AT", "fr"), ("es-419", "fr"),
    ("pt-BR", "fr"), ("nl-BE", "fr"), ("sv-SE", "fr"), ("it-CH", "fr"), ("tr-TR", "fr"),
    ("en-GB", "en"), ("en-US", "en"), ("EN", "en"),
    ("ja-JP", "ja"), ("ko-KR", "ko"),
    ("zh-Hant-TW", "zh-Hant"), ("zh-TW", "zh-Hant"), ("zh-HK", "zh-Hant"), ("zh-Hant-HK", "zh-Hant"), ("zh_TW", "zh-Hant"),
    ("zh-Hans-CN", "zh-Hans"), ("zh-CN", "zh-Hans"), ("zh", "zh-Hans"),
    ("pl-PL", "pl"), ("ro-RO", "pl"), ("cs-CZ", "pl"), ("hu-HU", "pl"),
    ("ru-RU", "ru"), ("uk-UA", "ru"),
]

@Suite("LegacyTextEncoding across the 15 shipped languages")
struct LegacyTextEncodingLocaleMatrixTests {

    @Test("A zip made on this language's Windows reads right on this language's phone",
          arguments: localeCodepageRows)
    func ownCodepageOnOwnPhone(_ row: LocaleCodepageRow) {
        let decoded = LegacyTextEncoding.decode(Data(row.bytes), preferredLanguages: [row.locale])
        #expect(decoded == row.name)
        print("[lang] \(row.locale.padding(toLength: 8, withPad: " ", startingAt: 0)) \(row.codepage)  →  \(decoded)")
    }

    /// The runtime proof this file cannot give statically: the DOS codepages
    /// come from CoreFoundation constants, and a converter iOS did not ship
    /// would make `String(data:encoding:)` return nil for plain ASCII. That
    /// nil would fall through to the NEXT codepage in the chain and decode
    /// wrongly rather than fail, which is exactly the silent shape to catch.
    @Test("Every codepage in every locale's chain converts on this OS")
    func everyCodepageIsAvailableAtRuntime() {
        for row in localeCodepageRows {
            for encoding in LegacyTextEncoding.candidates(forPreferredLanguages: [row.locale]) {
                let ascii = String(data: Data("abc123.gba".utf8), encoding: encoding)
                #expect(ascii == "abc123.gba",
                        "encoding 0x\(String(encoding.rawValue, radix: 16)) in the \(row.locale) chain is not available on this OS")
            }
        }
        print("[lang] every codepage in every chain converts on \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    @Test("Bytes valid in two codepages resolve by the phone's language, and the losing case is the documented one")
    func ambiguityResolvesByPhoneLanguage() {
        let cp850 = Data([0x50, 0x6F, 0x6B, 0x82, 0x6D, 0x6F, 0x6E, 0x2E, 0x67, 0x62, 0x61])
        #expect(LegacyTextEncoding.decode(cp850, preferredLanguages: ["fr-FR"]) == "Pokémon.gba")
        #expect(LegacyTextEncoding.decode(cp850, preferredLanguages: ["de-DE"]) == "Pokémon.gba")
        #expect(LegacyTextEncoding.decode(cp850, preferredLanguages: ["en-US"]) == "Pokémon.gba")
        // A French Windows zip on a Japanese phone: 0x82 0x6D is a valid CP932
        // pair, so this is the one direction the chain gets wrong, by design.
        #expect(LegacyTextEncoding.decode(cp850, preferredLanguages: ["ja-JP"]) == "PokＮon.gba")
    }

    @Test("Language tags in every shape map to the right codepage", arguments: languageTagShapes)
    func tagShapes(_ shape: (tag: String, sameAs: String)) {
        #expect(LegacyTextEncoding.oemEncoding(forLanguageTag: shape.tag)
                == LegacyTextEncoding.oemEncoding(forLanguageTag: shape.sameAs),
                "\(shape.tag) should use the same codepage as \(shape.sameAs)")
    }

    @Test("The chain starts with the phone's own codepage, holds no duplicate, and an empty language list is English")
    func chainShape() {
        for row in localeCodepageRows {
            let chain = LegacyTextEncoding.candidates(forPreferredLanguages: [row.locale, "en-US"])
            #expect(chain.first == LegacyTextEncoding.oemEncoding(forLanguageTag: row.locale), "\(row.locale)")
            #expect(Set(chain.map(\.rawValue)).count == chain.count, "duplicate codepage in the \(row.locale) chain")
        }
        #expect(LegacyTextEncoding.candidates(forPreferredLanguages: []).first
                == LegacyTextEncoding.oemEncoding(forLanguageTag: "en"))
    }

    @Test("Strict UTF-8 always wins, whatever the phone's language", arguments: localeCodepageRows)
    func utf8AlwaysWins(_ row: LocaleCodepageRow) {
        let utf8 = Data("Pokémon Émeraude ポケモン 포켓몬.gba".utf8)
        #expect(LegacyTextEncoding.decode(utf8, preferredLanguages: [row.locale]) == "Pokémon Émeraude ポケモン 포켓몬.gba")
        #expect(LegacyTextEncoding.isUTF8(utf8))
        #expect(!LegacyTextEncoding.isUTF8(Data(row.bytes)) || row.bytes.allSatisfy { $0 < 0x80 })
    }
}
