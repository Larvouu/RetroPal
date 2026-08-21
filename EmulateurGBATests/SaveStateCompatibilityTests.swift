//
//  SaveStateCompatibilityTests.swift
//  EmulateurGBATests
//
//  Guards "Risk 2": a future emulator-core upgrade silently breaking save
//  states that were written by the previously shipped core. (App Store updates
//  never DELETE saves; everything persistent lives in Documents/. The only real
//  save-state risk is a core-version format change making old states unreadable.)
//
//  WHAT KIND OF TEST THIS IS:
//  A golden-fixture, CROSS-VERSION regression test. The fixtures under
//  Fixtures/SaveStateCompat/<core>/ are REAL save states captured from the
//  currently shipped core build. The test loads each one with the build under
//  test and asserts it still restores.
//
//    GREEN -> save states from the version users already have will keep working
//             after this update.
//    RED   -> this build's core changed the save-state format. Decide
//             CONSCIOUSLY: keep the old core, add a migration, or accept the
//             break and tell users to make an in-game (battery) save before
//             updating. Do NOT "fix" red by recapturing the fixture from the new
//             core: that hides the exact breakage this test exists to catch.
//
//  A naive save-then-load test would always pass, because it writes and reads
//  with the SAME core. The whole point is loading a state from an OLDER core, so
//  the state binary MUST be a frozen fixture, never regenerated to go green.
//
//  STATUS WITHOUT FIXTURES:
//  With no fixtures captured yet, each case NO-OPS (stays green) on purpose, so
//  the suite is not red before the first capture. Until you capture fixtures it
//  covers nothing, by design. See Fixtures/SaveStateCompat/CAPTURE.md for the
//  one-time wiring + the capture procedure.
//
//  REQUIRES TEST-TARGET WIRING (one-time, see CAPTURE.md): a bridging header
//  exposing the ObjC cores (MGBABridge / MelonDSBridge) to this target. Without
//  it, this file will not compile once added to the target.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("Save-state cross-version compatibility", .serialized)
struct SaveStateCompatibilityTests {

    // One case per core family. mGBA shares one save-state format across
    // GBA/GB/GBC; melonDS covers NDS.

    @Test("mGBA: a save state from the shipped core still loads")
    func mgbaStateStillLoads() throws {
        try runCompatCase(coreDir: "mgba", romExtensions: ["gba", "gb", "gbc"]) {
            MGBABridge()
        }
    }

    @Test("melonDS: a save state from the shipped core still loads")
    func melondsStateStillLoads() throws {
        try runCompatCase(coreDir: "melonds", romExtensions: ["nds"]) {
            MelonDSBridge()
        }
    }

    /// MesenCE covers SNES and NES with one save-state format, written through
    /// its own SaveStateManager, which stamps a version and a console type in
    /// the header. A core bump that changes either is exactly what this catches.
    ///
    /// Worth knowing when a fixture is captured for it: this core is pinned to
    /// upstream plus one patch of ours, so "the shipped core" means the pinned
    /// SHA with Vendor/mesen-ios/patches applied, which is what build.sh
    /// produces. The patch touches the frame limiter and nothing serialised.
    @Test("MesenCE: a save state from the shipped core still loads")
    func mesenStateStillLoads() throws {
        try runCompatCase(coreDir: "mesen", romExtensions: ["sfc", "smc", "nes"]) {
            MesenBridge()
        }
    }

    // MARK: - Harness

    private func runCompatCase(coreDir: String,
                               romExtensions: [String],
                               makeBridge: () -> any EmulatorBridge) throws {
        guard let fx = Self.locateFixture(coreDir: coreDir, romExtensions: romExtensions) else {
            // Nothing on disk. Which of the two things that means is decided by the manifest:
            //
            //   EXPECTED.txt present -> a fixture WAS captured for this core and is now gone.
            //     The binaries are game content and stay out of git, so a fresh clone or a
            //     wiped Mac loses them. Fail, loudly. A guard that quietly returns to green
            //     when its evidence disappears is worse than no guard: green then reads as
            //     "the format is fine" while meaning "nothing was checked".
            //
            //   no manifest -> never captured for this core. No-op, as before.
            if Self.manifestExists(coreDir: coreDir) {
                Issue.record("Fixtures/SaveStateCompat/\(coreDir) has an EXPECTED.txt but no fixture beside it, so that core's save-state guard is NOT running. Restore the files the manifest names, or delete it if the fixture is retired on purpose. See CAPTURE.md.")
                return
            }
            print("[SaveStateCompat] No fixture in Fixtures/SaveStateCompat/\(coreDir) yet. "
                  + "Skipping. This test covers nothing until you capture one (see CAPTURE.md).")
            return
        }

        let bridge = makeBridge()

        // Boot the homebrew ROM the way the app does (loadROM -> setSavePath ->
        // reset -> one frame), with the battery save pointed at a throwaway file
        // so the test never touches a real save container.
        #expect(bridge.loadROM(atPath: fx.rom.path),
                "ROM failed to load: \(fx.rom.lastPathComponent)")

        let tmpSave = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("sav")
        defer { try? FileManager.default.removeItem(at: tmpSave) }
        bridge.setSavePath(tmpSave.path)
        bridge.reset()
        bridge.runFrame()

        // PRIMARY assertion: the state written by the previously shipped core
        // still loads in this build's core. A format/version bump makes the core
        // reject it and this returns false.
        let loaded = bridge.loadState(fromPath: fx.state.path)
        #expect(loaded,
                "This build's \(coreDir) core REJECTED a save state from the shipped core. The save-state format changed. Read this file's header BEFORE shipping.")

        // STRONGER assertion (only when a golden battery save was captured):
        // after restoring the state, dumping the game's battery save must match
        // the bytes captured at snapshot time. Battery-save format is hardware-
        // native and stable across core versions, so this catches a state that
        // "loads" (version ok) but restored into the wrong place.
        if loaded, let goldenSav = fx.goldenSav {
            bridge.flushSaveData()
            let produced = try? Data(contentsOf: tmpSave)
            let expected = try Data(contentsOf: goldenSav)
            #expect(produced == expected,
                    "State loaded but the restored battery save does not match the golden capture for \(coreDir). The state may be restoring into the wrong place.")
        }
    }

    // MARK: - Fixture location

    private struct Fixture {
        let rom: URL
        let state: URL
        let goldenSav: URL?
    }

    /// Fixtures live in the source tree next to this file:
    ///   EmulateurGBATests/Fixtures/SaveStateCompat/<coreDir>/
    /// holding one ROM (matching `romExtensions`), one `.state`, and an optional
    /// `.sav` golden. Located via `#filePath` so no Copy-Bundle-Resources wiring
    /// is needed. Consequence: run these on the iOS Simulator or a Mac, not a
    /// physical device (a device cannot read the Mac source tree). To run on a
    /// device instead, add the fixtures to the test target's Copy Bundle
    /// Resources and load them from `Bundle(for:)`.
    /// Whether a capture was ever committed for this core. The manifest is the only part of a
    /// fixture that CAN be committed, so it is what tells a MISSING capture apart from one that
    /// was never taken.
    private static func manifestExists(coreDir: String) -> Bool {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SaveStateCompat/\(coreDir)/EXPECTED.txt")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    private static func locateFixture(coreDir: String, romExtensions: [String]) -> Fixture? {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SaveStateCompat/\(coreDir)", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        guard let rom = entries.first(where: { romExtensions.contains($0.pathExtension.lowercased()) }),
              let state = entries.first(where: { $0.pathExtension.lowercased() == "state" })
        else { return nil }
        let goldenSav = entries.first(where: { $0.pathExtension.lowercased() == "sav" })
        return Fixture(rom: rom, state: state, goldenSav: goldenSav)
    }
}
