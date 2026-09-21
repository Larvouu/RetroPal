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
//  covers nothing, by design. The one-time wiring and the capture procedure are
//  written up in Fixtures/SaveStateCompat/CAPTURE.md, which is NOT part of the
//  public source snapshot: a save state is a dump of a running game's memory,
//  so the fixtures and their notes stay with whoever owns the games.
//
//  REQUIRES TEST-TARGET WIRING (one-time): a bridging header
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

    /// PCSX-ReARMed serialises through libretro's `retro_serialize`, so what
    /// this guards is the CORE's own state layout across a submodule bump.
    ///
    /// Two things make it worth having even though nothing has bumped yet. Its
    /// state is about 4.4 MB, an order of magnitude more than the SNES's, so a
    /// silent layout change is not something a reader would spot by eye. And a
    /// disc game's fixture is a FOLDER rather than a file, which the harness
    /// already handles: it locates a fixture by extension, and `.cue` and
    /// `.chd` are extensions like any other.
    ///
    /// This case runs the moment a fixture is captured for it and skips until
    /// then, which is the same contract the other three have. See CAPTURE.md.
    @Test("PCSX-ReARMed: a save state from the shipped core still loads")
    func pcsxStateStillLoads() throws {
        try runCompatCase(coreDir: "pcsx", romExtensions: ["chd", "cue", "m3u"]) {
            PCSXBridge()
        }
    }

    // MARK: - Harness

    private func runCompatCase(coreDir: String,
                               romExtensions: [String],
                               makeBridge: () -> any EmulatorBridge) throws {
        guard let fx = Self.locateFixture(coreDir: coreDir, romExtensions: romExtensions) else {
            // Nothing on disk. Which of the two things that means is decided by the manifest:
            //
            //   EXPECTED-<core>.txt present -> a fixture WAS captured for this core and is now gone.
            //     The binaries are game content and stay out of git, so a fresh clone or a
            //     wiped Mac loses them. Fail, loudly. A guard that quietly returns to green
            //     when its evidence disappears is worse than no guard: green then reads as
            //     "the format is fine" while meaning "nothing was checked".
            //
            //   no manifest -> never captured for this core. No-op, as before.
            //
            // One runtime cannot tell the two apart: My Mac (Designed for iPad) runs the
            // tests in an App Sandbox that answers `fileExists` for the manifest and refuses
            // to LIST the folder, so the fixture reads as gone while it is there (2026-09-05).
            // A folder that cannot be listed is a skip, said loudly, never a verdict.
            if !Self.fixtureFolderIsListable(coreDir: coreDir) {
                print("[SaveStateCompat] SKIPPED on this runtime: Fixtures/SaveStateCompat/\(coreDir) "
                      + "cannot be listed (an App Sandbox). This guard covers nothing here.")
                return
            }
            if Self.manifestExists(coreDir: coreDir) {
                Issue.record("Fixtures/SaveStateCompat/\(coreDir) has an EXPECTED-\(coreDir).txt but no fixture beside it, so that core's save-state guard is NOT running. Restore the files the manifest names, or delete it if the fixture is retired on purpose. See CAPTURE.md.")
                return
            }
            print("[SaveStateCompat] No fixture in Fixtures/SaveStateCompat/\(coreDir) yet. "
                  + "Skipping. This test covers nothing until you capture one.")
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
    ///
    /// ⚠ THE FILENAME CARRIES THE CORE, and that is a build constraint rather
    /// than a naming preference. This target is a filesystem-synchronized
    /// group, so Xcode picks up every file under it and copies it into the test
    /// bundle FLAT, folder names discarded. Two cores each holding an
    /// `EXPECTED.txt` therefore produced two copy commands writing the same
    /// destination, and the build failed with "Multiple commands produce". The
    /// per-core name makes the flattened names unique, so a third core is safe
    /// to add. Nothing reads these from the bundle: the loader below uses
    /// `#filePath` and reads the source tree.
    private static func manifestExists(coreDir: String) -> Bool {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SaveStateCompat/\(coreDir)/EXPECTED-\(coreDir).txt")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    /// Whether the fixture folder can be enumerated at all on this runtime.
    private static func fixtureFolderIsListable(coreDir: String) -> Bool {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SaveStateCompat/\(coreDir)", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) != nil
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
