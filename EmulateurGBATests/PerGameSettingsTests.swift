//
//  PerGameSettingsTests.swift
//  EmulateurGBATests
//
//  Deleting a game forgets every per-game setting stored under its key, so a
//  different game imported later under the same name starts clean (audit
//  2026-10-12: its cheats were applied to the new game at launch).
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("Per-game settings")
struct PerGameSettingsTests {

    @Test func forgettingAGameClearsEveryPrefixAndNothingElse() throws {
        let suite = "PerGameSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for prefix in PerGameSettings.prefixes {
            defaults.set("x", forKey: prefix + "Tetris")
            defaults.set("y", forKey: prefix + "Tetris 2")
        }
        PerGameSettings.forget(romBasename: "Tetris", in: defaults)
        for prefix in PerGameSettings.prefixes {
            #expect(defaults.object(forKey: prefix + "Tetris") == nil, "a setting of the deleted game survived")
            #expect(defaults.string(forKey: prefix + "Tetris 2") == "y", "another game's setting was cleared")
        }
    }

    /// Every per-game key the app's source writes is one `forget` clears: a
    /// setting added later without joining the list would be inherited again.
    /// Reads the source, so it runs on the simulator and says SKIPPED elsewhere.
    @Test func everyPerGameKeyInTheSourceIsForgotten() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EmulateurGBA", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            print("[PerGameSettings] SKIPPED on this runtime: no source at \(root.path)")
            return
        }
        let pattern = try NSRegularExpression(pattern: "\"([A-Za-z0-9]+_)\\\\\\((romName|gameName)\\)\"")
        var found = Set<String>()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(match.range(at: 1), in: text) { found.insert(String(text[r])) }
            }
        }
        #expect(!found.isEmpty, "the scan found no per-game key at all")
        for prefix in found {
            #expect(PerGameSettings.prefixes.contains(prefix), "a per-game key is missing from PerGameSettings.prefixes")
        }
    }
}
