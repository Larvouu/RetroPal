//
//  LegacyTextEncoding.swift
//  EmulateurGBA
//
//  How bytes with no declared encoding become text. Three things arrive that
//  way: ZIP entry names, `.cue` sheets and `.m3u` playlists. All three are
//  written by desktop tools, and the ones that matter to a non-English user
//  are written by Windows, which stores such text in the machine's OEM
//  codepage and says nowhere which one it used.
//
//  The rule here is the one every desktop unzipper applies when reading:
//  strict UTF-8 first, because valid UTF-8 is unambiguous, then the codepage
//  of the USER'S OWN language, then the other multibyte codepages (which can
//  fail on foreign bytes), and only then Latin-1, which decodes every byte and
//  therefore belongs last. A Japanese user's archives come from Japanese
//  machines; a French user's from French ones. Guessing one codepage for
//  everyone is what broke: Shift-JIS as the universal fallback turned the
//  CP850 bytes of `Pokémon.gba` into `PokＮon.gba`, silently, for the two
//  largest markets, while fixing Japan.
//

import Foundation

enum LegacyTextEncoding {

    /// The language list the chain is built from: the phone's, unless a test
    /// has bound an override for the duration of a call.
    ///
    /// A task-local rather than a settable global on purpose. The import path
    /// reads the language with no parameter to pass, so the only way for a
    /// test running on an English simulator to import a Japanese archive "as a
    /// Japanese phone" is to bind the language around the call; a task-local
    /// is scoped to that call, so tests running in parallel cannot see each
    /// other's binding. Never set by the app.
    @TaskLocal static var preferredLanguagesOverride: [String]?

    static var preferredLanguages: [String] {
        preferredLanguagesOverride ?? Locale.preferredLanguages
    }

    /// Strict UTF-8, then the legacy chain. Never fails: Latin-1 closes it.
    static func decode(_ data: Data,
                       preferredLanguages: [String] = LegacyTextEncoding.preferredLanguages) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return decodeLegacy(data, preferredLanguages: preferredLanguages)
    }

    /// The legacy chain alone, for bytes already known not to be UTF-8.
    static func decodeLegacy(_ data: Data,
                             preferredLanguages: [String] = LegacyTextEncoding.preferredLanguages) -> String {
        for encoding in candidates(forPreferredLanguages: preferredLanguages) {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func isUTF8(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8) != nil
    }

    /// Legacy codepages to try, in order: the OEM codepage of the user's first
    /// language, then the remaining multibyte codepages. A single-byte
    /// codepage (CP437, CP850, CP852, CP866) decodes every byte and never
    /// fails, so whatever follows it is unreachable by construction. That is
    /// intended, and it is why the user's own codepage has to come first
    /// rather than a guessed one.
    static func candidates(forPreferredLanguages languages: [String]) -> [String.Encoding] {
        let own = oemEncoding(forLanguageTag: languages.first ?? "en")
        let multibyte: [String.Encoding] = [
            .shiftJIS,                          // CP932, Japan
            cfEncoding(.dosKorean),             // CP949, Korea
            cfEncoding(.dosChineseTrad),        // CP950, Taiwan / Hong Kong
            cfEncoding(.dosChineseSimplif),     // CP936, China
        ]
        return [own] + multibyte.filter { $0 != own }
    }

    /// The OEM codepage a Windows machine set to this language writes its
    /// legacy text in. Tags arrive as BCP 47 from `Locale.preferredLanguages`
    /// (`fr-FR`, `zh-Hant-TW`, `pt-BR`): the language is the first subtag, and
    /// for Chinese the script or region decides Traditional against Simplified.
    ///
    /// Foundation's `.shiftJIS` is CP932 already (it maps to
    /// `kCFStringEncodingDOSJapanese`, NEC/IBM extensions included), which is
    /// why Japanese needs no CoreFoundation constant.
    static func oemEncoding(forLanguageTag tag: String) -> String.Encoding {
        let subtags = tag.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map(String.init)
        let language = subtags.first ?? ""
        let rest = subtags.dropFirst()
        switch language {
        case "ja":
            return .shiftJIS                                    // CP932
        case "ko":
            return cfEncoding(.dosKorean)                       // CP949
        case "zh":
            let traditional = rest.contains { ["hant", "tw", "hk", "mo"].contains($0) }
            return cfEncoding(traditional ? .dosChineseTrad : .dosChineseSimplif) // CP950 / CP936
        case "pl", "cs", "sk", "hu", "hr", "sl", "ro", "bs", "sq":
            return cfEncoding(.dosLatin2)                       // CP852, Central Europe
        case "ru", "uk", "be":
            return cfEncoding(.dosRussian)                      // CP866
        case "en":
            return cfEncoding(.dosLatinUS)                      // CP437, the ZIP spec's own default
        default:
            return cfEncoding(.dosLatin1)                       // CP850, Western Europe
        }
    }

    /// A `String.Encoding` for a CoreFoundation codepage constant. The DOS
    /// codepages have no Foundation-level case of their own; this is the
    /// documented bridge for them.
    private static func cfEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(encoding.rawValue)))
    }
}
