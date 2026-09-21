//
//  LocalizationIntegrityTests.swift
//  EmulateurGBATests
//
//  "Does everything work in every language" has a part no device can answer
//  faster than a test: are all fifteen string tables actually IN the built
//  app, do they hold the same keys, do their format specifiers agree with
//  English, does every key the code asks for exist, and do the two plural
//  tables resolve. Any one of these fails silently in the app: a missing key
//  shows its raw identifier, one unescaped quote makes a whole language fall
//  back to English, a wrong specifier crashes on the sentence that uses it,
//  and a `.stringsdict` the build did not pick up shows `%#@minutes@`.
//
//  The tables are read from the COMPILED bundle, not from the source files,
//  so what is checked is what ships. The one source-side check, the scan for
//  requested keys, finds the tree through `#filePath` the way
//  SaveStateCompatibilityTests does.
//

import Testing
import Foundation
@testable import EmulateurGBA

let shippedLocales = ["en", "fr", "de", "es", "es-MX", "it", "pt-BR", "pt-PT",
                      "nl", "sv", "pl", "ro", "ja", "ko", "zh-Hant"]

/// (locale, count, expected sentence) for the two plural-aware prompts.
let pluralExpectations: [(locale: String, count: Int, expected: String)] = [
    ("pl", 1, "Grałeś 1 minutę na 1,5x"),
    ("pl", 2, "Grałeś 2 minuty na 1,5x"),
    ("pl", 5, "Grałeś 5 minut na 1,5x"),
    ("pl", 22, "Grałeś 22 minuty na 1,5x"),
    ("ro", 1, "Ai jucat 1 minut la 1,5x"),
    ("ro", 5, "Ai jucat 5 minute la 1,5x"),
    ("ro", 25, "Ai jucat 25 de minute la 1,5x"),
]

@Suite("Localization integrity, all 15 languages")
struct LocalizationIntegrityTests {

    private var appBundle: Bundle { Bundle(for: ROMImporter.self) }

    /// A compiled `.strings` table for one localization, or nil if the build
    /// did not include one.
    private func table(_ name: String, _ locale: String) -> [String: String]? {
        guard let path = appBundle.path(forResource: name, ofType: "strings",
                                        inDirectory: nil, forLocalization: locale) else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    /// The printf specifiers a string carries, in order. `%%` is a literal
    /// percent sign and is not one.
    private func specifiers(_ text: String) -> [String] {
        let cleaned = text.replacingOccurrences(of: "%%", with: "")
        guard let regex = try? NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:l{1,2}[du]|[@dfsu]|\\.\\d+f)") else { return [] }
        let whole = NSRange(cleaned.startIndex..., in: cleaned)
        return regex.matches(in: cleaned, range: whole)
            .compactMap { Range($0.range, in: cleaned).map { String(cleaned[$0]) } }
            .sorted()
    }

    @Test("Every shipped language is in the built app")
    func bundleShipsAllLocalizations() {
        let built = Set(appBundle.localizations)
        for locale in shippedLocales {
            #expect(built.contains(locale), "\(locale) is not among the bundle's localizations: \(built.sorted())")
        }
        print("[l10n] bundle localizations: \(built.sorted())")
    }

    @Test("Localizable.strings holds the same keys as English, no empty value, same format specifiers",
          arguments: shippedLocales)
    func localizableTableMatchesEnglish(_ locale: String) throws {
        let en = try #require(table("Localizable", "en"), "no compiled English Localizable.strings")
        let t = try #require(table("Localizable", locale), "no compiled Localizable.strings for \(locale)")

        let missing = Set(en.keys).subtracting(t.keys).sorted()
        let extra = Set(t.keys).subtracting(en.keys).sorted()
        #expect(missing.isEmpty, "\(locale) is missing \(missing.count) keys, first: \(missing.prefix(8))")
        #expect(extra.isEmpty, "\(locale) has \(extra.count) keys English lacks, first: \(extra.prefix(8))")

        let empty = t.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.key).sorted()
        #expect(empty.isEmpty, "\(locale) has empty values for \(empty.prefix(8))")

        var mismatched: [String] = []
        for (key, value) in t {
            if let english = en[key], specifiers(value) != specifiers(english) { mismatched.append(key) }
        }
        #expect(mismatched.isEmpty, "\(locale) format specifiers differ from English in \(mismatched.sorted().prefix(8))")
        print("[l10n] \(locale.padding(toLength: 8, withPad: " ", startingAt: 0)) \(t.count) keys · parity with en · specifiers match")
    }

    @Test("InfoPlist.strings exists in every language with the same keys as English",
          arguments: shippedLocales)
    func infoPlistTableExists(_ locale: String) throws {
        let en = try #require(table("InfoPlist", "en"), "no compiled English InfoPlist.strings")
        let t = try #require(table("InfoPlist", locale), "no compiled InfoPlist.strings for \(locale): the Photos permission and the file-type names would show in English")
        #expect(Set(t.keys) == Set(en.keys), "\(locale) InfoPlist keys differ from English")
        #expect(t["NSPhotoLibraryAddUsageDescription"]?.isEmpty == false)
    }

    /// The two new import sentences and the other keys the language audit
    /// added, by name, so a rename in the code cannot silently orphan them.
    @Test("The keys the language audit added exist in every language", arguments: shippedLocales)
    func auditKeysExist(_ locale: String) throws {
        let t = try #require(table("Localizable", locale))
        for key in ["import.error.zipUnsupportedCompression", "import.error.zipEncrypted",
                    "cheats.browse.noResults", "cheats.placeholderPrefix",
                    "library.untitled", "guide.controller.keyboard"] {
            #expect(t[key]?.isEmpty == false, "\(locale) lacks \(key)")
        }
    }

    /// The fifteen sentences that name the device have an `.ipad` twin per
    /// language (2026-09-05, the iPad build), chosen at run time by
    /// `DeviceWording.string`, which builds the key, so the literal scan
    /// below cannot see the twins: they are pinned here by name. Each must
    /// exist, differ from its base, and no longer say iPhone.
    @Test("Every device-naming key has an iPad twin", arguments: shippedLocales)
    func iPadTwinsExist(_ locale: String) throws {
        let t = try #require(table("Localizable", locale))
        for key in ["library.empty.subtitle", "library.empty.step1", "settings.nds.language.footer",
                    "guide.importRom.step1", "guide.importRom.step2", "guide.controller.step2",
                    "settings.sync.footer", "settings.externalDisplay.footer",
                    "prompt.externalDisplay.subtitle", "guide.airplay.intro", "guide.airplay.step1",
                    "guide.airplay.step3", "guide.airplay.step4", "guide.widget.footer",
                    "externalDisplay.idle.hint",
                    // 2026-09-07: the keyboard sentence says the touch controls hide
                    // on iPhone; the iPad twin drops that sentence.
                    "guide.controller.keyboard"] {
            let base = t[key] ?? ""
            let twin = t[key + ".ipad"] ?? ""
            // "iPhon", not "iPhone": Polish declines the noun (iPhonie, iPhone'a,
            // iPhone'em), and the stem is what every form shares.
            #expect(!twin.isEmpty, "\(locale) lacks \(key).ipad")
            #expect(twin != base, "\(locale): \(key).ipad is the phone sentence")
            #expect(!twin.contains("iPhon"), "\(locale): \(key).ipad still says iPhone")
            #expect(base.contains("iPhon"), "\(locale): \(key) no longer names the phone, drop its twin")
        }
    }

    @Test("Every key the code asks NSLocalizedString for exists in English")
    func everyRequestedKeyExists() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EmulateurGBA", isDirectory: true)
        // The scan reads the Mac's checkout. On the simulator that path exists;
        // on a physical device it does not, and an enumerator over a missing
        // directory yields nothing rather than failing. Say so loudly and stop,
        // the way the save-state fixture tests do, rather than fail a device run
        // for a reason that has nothing to do with the app.
        guard FileManager.default.fileExists(atPath: sourceRoot.path) else {
            print("[l10n] SKIPPED on this runtime: the source tree is not reachable at \(sourceRoot.path). "
                  + "This check reads the checkout on the Mac, so it only runs on the SIMULATOR; on a device it covers nothing.")
            return
        }
        let enumerator = try #require(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil),
                                      "source tree not found at \(sourceRoot.path)")
        let regex = try NSRegularExpression(pattern: "NSLocalizedString\\(\\s*\"([^\"\\\\]+)\"")
        var requested = Set<String>()
        var files = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files += 1
            let whole = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: whole) {
                if let r = Range(match.range(at: 1), in: text) { requested.insert(String(text[r])) }
            }
        }
        // Zero files with the folder present is a sandbox, not a wrong path: My Mac
        // (Designed for iPad) runs the tests inside an App Sandbox that lets the
        // folder be seen and nothing in it be read (2026-09-05). Skip loudly, as on a
        // device; a partial scan is still the wrong-path failure it always was.
        if files == 0 {
            print("[l10n] SKIPPED on this runtime: the source tree at \(sourceRoot.path) exists but "
                  + "nothing in it could be enumerated (an App Sandbox). This check covers nothing here.")
            return
        }
        #expect(files > 100, "only \(files) Swift files scanned, is the source root right?")
        let en = try #require(table("Localizable", "en"))
        let missing = requested.filter { en[$0] == nil }.sorted()
        #expect(missing.isEmpty, "keys the code requests that English does not define: \(missing)")
        print("[l10n] \(requested.count) NSLocalizedString keys requested across \(files) files, all defined in en")
    }

    @Test("Polish and Romanian plurals resolve through the stringsdict", arguments: pluralExpectations)
    func pluralsResolve(_ expectation: (locale: String, count: Int, expected: String)) throws {
        let path = try #require(appBundle.path(forResource: expectation.locale, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let format = bundle.localizedString(forKey: "prompt.speed.title", value: nil, table: nil)
        let text = String(format: format, locale: Locale(identifier: expectation.locale), expectation.count)
        #expect(text == expectation.expected,
                "a raw '%#@minutes@' here means the .stringsdict was not picked up by the build; a wrong plural means the rule is wrong")
        print("[l10n] \(expectation.locale) plural \(expectation.count) → \(text)")
    }
}
