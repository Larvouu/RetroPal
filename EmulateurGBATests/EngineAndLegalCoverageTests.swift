//
//  EngineAndLegalCoverageTests.swift
//  EmulateurGBATests
//
//  The surfaces that NAME the cores and the consoles they run, held to each
//  other (the Settings and Legal surfaces). Each of these went stale once
//  already, silently, because nothing tied it to the code:
//
//   - the Legal page said MesenCE runs "SNES and NES games" in all fifteen
//     languages after it had gained the Master System and the Game Gear
//     (found 2026-10-10);
//   - the Emulation engines screen miscounted the patches of melonDS and of
//     the Nintendo 64 until 2026-10-08;
//   - an engine without its Legal row, its third-party licence block or its
//     name in the compliance sentence is a GPL notice not given.
//
//  The What's New check holds the sheet's keys to all fifteen tables and the
//  `{PRO}` / `{PALETTE}` tokens to English, since a locale that drops `{PRO}`
//  shows a Pro feature as free.
//

import Testing
import Foundation
@testable import EmulateurGBA

// On the main actor: `EmulationEnginesView` is a SwiftUI view, so its static
// list takes the view's main-actor isolation.
@MainActor
struct EngineAndLegalCoverageTests {

    private var appBundle: Bundle { Bundle(for: ROMImporter.self) }

    private func table(_ locale: String) -> [String: String]? {
        guard let path = appBundle.path(forResource: "Localizable", ofType: "strings",
                                        inDirectory: nil, forLocalization: locale) else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    /// Engine name on the engines screen → the `legal.<id>` key family on the
    /// Legal page. Every engine must appear here (checked below), so a new core
    /// cannot ship an engines row without deciding its Legal row.
    private static let legalKey: [String: String] = [
        "mGBA": "mgba",
        "melonDS": "melonds",
        "MesenCE": "mesen",
        "PCSX-ReARMed": "pcsx",
        "Mupen64Plus-Next": "mupen",
        "BlastEm": "blastem",
        "PPSSPP": "ppsspp",
    ]

    /// Engine name → its folder of build-time patches, `Vendor/<dir>/patches`.
    private static let patchDir: [String: String] = [
        "mGBA": "mgba-ios",
        "melonDS": "melonds-ios",
        "MesenCE": "mesen-ios",
        "PCSX-ReARMed": "pcsx-ios",
        "Mupen64Plus-Next": "n64-ios",
        "BlastEm": "blastem-ios",
        "PPSSPP": "ppsspp-ios",
    ]

    /// Every console the app plays: the drawings' own list, one per console.
    private static let allConsoles: [PixelConsole] = [.gb, .gbc, .gba, .nds, .nes, .snes,
                                                      .ps1, .n64, .md, .sms, .gg, .psp]

    // MARK: - The engines screen

    @Test func everyConsoleSitsUnderExactlyOneEngine() {
        let listed = EmulationEnginesView.engines.flatMap(\.consoles)
        for console in Self.allConsoles {
            let count = listed.filter { $0 == console }.count
            #expect(count == 1, "\(console.label) appears under \(count) engines on the engines screen, expected 1")
        }
        let undrawn = EmulationEnginesView.engines.flatMap(\.undrawn)
        #expect(undrawn.isEmpty, "consoles still shown as a pill on the engines screen though every console has a drawing: \(undrawn)")
    }

    @Test func everyEngineHasItsLegalMapping() {
        for engine in EmulationEnginesView.engines {
            #expect(Self.legalKey[engine.name] != nil, "\(engine.name) has no Legal row mapping in this test: add its legal.<id> keys and its row")
            #expect(Self.patchDir[engine.name] != nil, "\(engine.name) has no patch folder mapping in this test")
        }
    }

    /// The patch count the engines screen states is the number of `.patch`
    /// files its build script applies. Reads the checkout, so it runs on the
    /// simulator; on a device the tree is not there and it says so.
    @Test func patchCountsMatchThePatchFolders() throws {
        let vendor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor", isDirectory: true)
        guard FileManager.default.fileExists(atPath: vendor.path) else {
            print("[engines] SKIPPED on this runtime: the source tree is not reachable at \(vendor.path). This check reads the checkout on the Mac, so it only runs on the SIMULATOR.")
            return
        }
        for engine in EmulationEnginesView.engines {
            let dirName = try #require(Self.patchDir[engine.name], "\(engine.name) has no patch folder mapping")
            let dir = vendor.appendingPathComponent(dirName, isDirectory: true)
            // A core's build folder must exist; its patches folder may not (no patch).
            guard FileManager.default.fileExists(atPath: dir.path) else {
                print("[engines] SKIPPED \(engine.name): \(dir.path) is not readable on this runtime.")
                continue
            }
            let patches = vendor.appendingPathComponent("\(dirName)/patches", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: patches.path)) ?? []
            let count = files.filter { $0.hasSuffix(".patch") }.count
            #expect(count == engine.patches, "\(engine.name): the engines screen says \(engine.patches) patches, Vendor/\(dirName)/patches holds \(count)")
        }
    }

    // MARK: - The Legal page

    @Test("Every engine has its Legal row, in every language", arguments: shippedLocales)
    func everyEngineHasLegalStrings(_ locale: String) throws {
        let t = try #require(table(locale), "no compiled Localizable.strings for \(locale)")
        for engine in EmulationEnginesView.engines {
            guard let id = Self.legalKey[engine.name] else { continue }
            for suffix in ["", ".licenseLine", ".description"] {
                let key = "legal.\(id)\(suffix)"
                #expect(t[key]?.isEmpty == false, "\(locale) lacks \(key)")
            }
            // The compliance sentence names every core, by its project name.
            let compliance = t["legal.compliance"] ?? ""
            #expect(compliance.contains(engine.name), "\(locale): legal.compliance does not name \(engine.name)")
        }
    }

    /// The engine's description says which consoles it runs. Checked in English
    /// against the engines screen: each console that engine runs is named in it.
    @Test func legalDescriptionsNameEveryConsoleTheEngineRuns() throws {
        let en = try #require(table("en"), "no compiled English Localizable.strings")
        for engine in EmulationEnginesView.engines {
            guard let id = Self.legalKey[engine.name],
                  let description = en["legal.\(id).description"] else { continue }
            // The Game Boy family is described by mGBA as "Game Boy Advance"
            // emulation; it is the one engine whose consoles are a family name.
            if engine.name == "mGBA" { continue }
            for console in engine.consoles {
                let english = englishName(console)
                #expect(description.contains(english), "legal.\(id).description does not name \(english), which \(engine.name) runs")
            }
        }
    }

    private func englishName(_ console: PixelConsole) -> String {
        switch console {
        case .md: return "Mega Drive"
        case .sms: return "Master System"
        case .gg: return "Game Gear"
        case .psp: return "PSP"
        default: return console.label
        }
    }

    /// Every component an engine's Legal row points to has a block on the
    /// third-party licences page.
    @Test func everyEngineHasAThirdPartyLicenceBlock() {
        let names = ThirdPartyLicense.all.flatMap(\.components).map(\.name)
        for engine in EmulationEnginesView.engines {
            #expect(names.contains { $0.hasPrefix(engine.name) },
                    "\(engine.name) has no block on the third-party licences page")
        }
    }

    // MARK: - What's New

    @Test("Every What's New key exists, with the same tokens as English", arguments: shippedLocales)
    func whatsNewKeysExistWithTheirTokens(_ locale: String) throws {
        let en = try #require(table("en"), "no compiled English Localizable.strings")
        let t = try #require(table(locale), "no compiled Localizable.strings for \(locale)")
        let content = WhatsNewContent.current
        var keys = content.sections.flatMap { [$0.titleKey] + $0.bulletKeys }
        if let notice = content.noticeKey { keys.append(notice) }
        #expect(!keys.isEmpty, "the current What's New has no keys")
        for key in keys {
            let value = try #require(t[key], "\(locale) lacks \(key)")
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(locale): \(key) is empty")
            let english = en[key] ?? ""
            for token in ["{PRO}", "{PALETTE}"] {
                let want = english.components(separatedBy: token).count - 1
                let have = value.components(separatedBy: token).count - 1
                #expect(have == want, "\(locale): \(key) carries \(token) \(have) times, English \(want)")
            }
            #expect(!value.contains("\u{2014}"), "\(locale): \(key) contains an em dash")
        }
    }

    /// The notes describe the version being built. A release that forgets to
    /// bump them never shows its sheet (the gate compares against this string).
    @Test func whatsNewVersionIsTheBuildsVersion() throws {
        let built = try #require(appBundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                                 "the app bundle has no marketing version")
        #expect(WhatsNewContent.current.version == built,
                "What's New describes \(WhatsNewContent.current.version) but the app is \(built): rewrite the notes before submitting")
    }
}
