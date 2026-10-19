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

    /// PPSSPP serialises through libretro's `retro_serialize` (about 40 MB for
    /// this game), and PSPBridge writes it behind its own header, packed with
    /// LZFSE. The fixture is a slot from the core the PSP first ships with
    /// (Vendor/ppsspp v1.20.4, unpatched) made from redistributable homebrew
    /// (2048, MIT), so it is in git and runs on the phone.
    ///
    /// The load alone is not the proof here. PPSSPP boots asynchronously, and a
    /// load issued before its boot has finished is KEPT by the port and applied
    /// as the boot ends, so `loadState` answers YES before the core has read a
    /// byte. The game's own state is therefore read back from RAM once the
    /// machine runs: its board, score and best score, at the address the
    /// state restores (EXPECTED-psp.txt). RAM, not the picture: a blinking
    /// cursor's phase is presentation. Proved on the host with
    /// `Tools/psp-bench verify` (600 of 600 frames, RAM and sound, either
    /// side of the boot).
    @Test("PPSSPP: a save state from the shipped core still loads, and the game's board comes back")
    func pspStateStillLoads() throws {
        // FIRST in this serialized suite: PPSSPP reserves a 2 GB window for the
        // PSP's memory, and after five other cores have run in the test process
        // its address space can be too fragmented to give one (`vm_remap`
        // failures, ⌘U 2026-10-11; the app itself boots it, device check of
        // MHFU after N64 the same day). Since 2026-10-12 the app (the test
        // host) carries the extended-virtual-addressing entitlement, which
        // gives the process the whole 64-bit address space, so the window
        // should always be found; the order stays as a belt. A core that never
        // starts is reported as that, not as a format change, and still fails:
        // a guard that could not run is not green.
        let didNotStart = BootFailureFlag()
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("PSPBridgeBootFailedNotification"), object: nil, queue: nil) { _ in didNotStart.set() }
        defer { NotificationCenter.default.removeObserver(observer) }
        try runCompatCase(coreDir: "psp", romExtensions: ["pbp", "iso", "cso"],
                          coreDidNotStart: { didNotStart.waitBriefly() }) {
            let bridge = PSPBridge()
            // The app gives every PSP game a memory stick folder before the
            // load; the core reads it while it initialises.
            bridge.setMemoryStickDirectory(FileManager.default.temporaryDirectory
                .appendingPathComponent("SaveStateCompat-psp-\(UUID().uuidString)", isDirectory: true).path)
            return bridge
        } afterLoad: { bridge, _ in
            var frames = 0
            while !(bridge.isMemoryReadable?() ?? true) && frames < 3000 {
                bridge.runFrame()
                frames += 1
            }
            // The frame the boot ends in is the one that applies a kept state.
            bridge.runFrame()
            #expect(bridge.isMemoryReadable?() ?? true,
                    "The PSP never finished booting after the fixture's state was loaded.")

            // GameState: cells[4][4], previous_cells[4][4], score, previous_score, best_score.
            var words = [Int32](repeating: -1, count: 35)
            let read = words.withUnsafeMutableBytes { raw in
                bridge.readMemory(atAddress: 0x09FB_FBA0,
                                  into: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                  length: raw.count)
            }
            #expect(read == 35 * 4, "The PSP's RAM could not be read where the fixture's game keeps its board.")
            let board = Array(words[0..<16]).map { Int32(littleEndian: $0) }
            #expect(board == [0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 2, 0, 4],
                    "The state loaded but the game's board did not come back from it.")
            let score = Array(words[32..<35]).map { Int32(littleEndian: $0) }
            #expect(score == [4, 0, 4],
                    "The state loaded but the game's score and best score did not come back from it.")
        }
    }


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

    /// Mupen64Plus-Next serialises through libretro's `retro_serialize`: a fixed
    /// 16,793,412-byte state. The fixture is a state from the 1.3.3 core, the
    /// bare format every N64 slot written before 1.3.4 holds, made from
    /// redistributable homebrew (Minesweeper 64, Unlicense), so it is in git and
    /// runs on the phone.
    ///
    /// From 1.3.4 a slot is written PACKED (N64Bridge.mm, Save states), so this
    /// case checks both directions on the real core: the old bare state still
    /// loads, and a state this build writes is packed and loads back. The format
    /// itself, damaged files included, is N64StateFileTests.
    ///
    /// In this suite and nowhere else, because the N64 core is one global
    /// instance (one N64Bridge at a time) and this suite runs its cases one
    /// after another.
    @Test("Mupen64Plus-Next: a save state from the shipped core still loads, and this build's packed one loads back")
    func n64StateStillLoads() throws {
        try runCompatCase(coreDir: "n64", romExtensions: ["z64", "n64", "v64"]) {
            N64Bridge()
        } afterLoad: { bridge, fixture in
            for _ in 0..<60 { bridge.runFrame() }
            let original = try Data(contentsOf: fixture.state)
            let written = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("state")
            defer { try? FileManager.default.removeItem(at: written) }

            #expect(bridge.saveState(toPath: written.path),
                    "This build could not write an N64 save state.")
            let file = try Data(contentsOf: written)
            #expect(file.count < original.count,
                    "An N64 state was written at \(file.count) bytes, not packed below the core's \(original.count).")
            #expect(N64Bridge.state(fromStateFile: file, expectedLength: original.count) != nil,
                    "The state this build wrote does not unpack to a state of the core's size.")
            #expect(bridge.loadState(fromPath: written.path),
                    "A state this build wrote does not load back into it.")
        }
    }

    /// BlastEm serialises through libretro's `retro_serialize`: its own
    /// length, then the state (about 142 KB). The fixture is a state from the
    /// core 1.3.4 ships, its first (the pinned `Vendor/blastem` with
    /// `Vendor/blastem-ios/patches` applied), made from redistributable homebrew
    /// (KłełeAtoms, MIT), so it is in git and runs on the phone.
    ///
    /// The state carries no cartridge save (BlastEm serialises cart RAM only
    /// on its Master System path), so there is no golden `.sav` beside it.
    /// Proved on the host with `Tools/md-bench` before committing: the state
    /// loads and the next 600 frames of play match the shipped core's, picture
    /// and sound; a state from another moment, a damaged one and a truncated
    /// one all fail.
    @Test("BlastEm: a save state from the shipped core still loads")
    func blastemStateStillLoads() throws {
        try runCompatCase(coreDir: "md", romExtensions: ["md", "gen", "smd", "bin"]) {
            BlastEmBridge()
        }
    }

    // MARK: - Harness

    /// `afterLoad` runs on the same bridge once the fixture's state has loaded,
    /// for a core whose own write path needs checking against the real core too.
    private func runCompatCase(coreDir: String,
                               romExtensions: [String],
                               coreDidNotStart: () -> Bool = { false },
                               makeBridge: () -> any EmulatorBridge,
                               afterLoad: ((any EmulatorBridge, Fixture) throws -> Void)? = nil) throws {
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
        if coreDidNotStart() {
            Issue.record("The \(coreDir) core could not START in this test process (its log says why), so the save-state guard did not run. This is not a format change. Run this suite alone, or on a fresh launch, before reading it as one.")
            return
        }
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

        if loaded, let afterLoad {
            try afterLoad(bridge, fx)
        }
    }

    // MARK: - Fixture location

    struct Fixture {
        let rom: URL
        let state: URL
        let goldenSav: URL?
    }

    /// Fixtures live in the source tree next to this file:
    ///   EmulateurGBATests/Fixtures/SaveStateCompat/<coreDir>/
    /// holding one ROM (matching `romExtensions`), one `.state`, and an optional
    /// `.sav` golden. Located via `#filePath` where the source tree can be read
    /// (a Mac), and in the test bundle where it cannot (a phone), for the cores
    /// whose manifest names its files (`locateBundledFixture`).
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
    /// to add. The bundle copy is read only for a manifest whose first line
    /// names its files (`locateBundledFixture`); this check reads the source tree.
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

    static func locateFixture(coreDir: String, romExtensions: [String]) -> Fixture? {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SaveStateCompat/\(coreDir)", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return locateBundledFixture(coreDir: coreDir)
        }
        guard let rom = entries.first(where: { romExtensions.contains($0.pathExtension.lowercased()) }),
              let state = entries.first(where: { $0.pathExtension.lowercased() == "state" })
        else { return nil }
        let goldenSav = entries.first(where: { $0.pathExtension.lowercased() == "sav" })
        return Fixture(rom: rom, state: state, goldenSav: goldenSav)
    }

    /// On a device, and anywhere else the source tree cannot be read. Every file
    /// under Fixtures/ is also copied into the test bundle, FLAT (see
    /// `manifestExists`), so a fixture can be found there by NAME, and the names
    /// come from the first line of the core's manifest:
    ///   files: <rom> <state> [<sav>]
    /// Only the fixtures committed with the repository carry that line (melonds,
    /// mgba, n64 and md, freely redistributable homebrew). A manifest without it, or no
    /// manifest in the bundle, is nil, which the caller reports as a skip,
    /// exactly as before this existed.
    ///
    /// Why it exists: before 1.3.3 no case of this suite ever ran anywhere. The
    /// app cannot build for the Simulator (the cores are built for iphoneos
    /// only), a phone cannot read `#filePath`, and My Mac's sandbox refuses the
    /// listing. Green meant "skipped" on every runtime.
    private static func locateBundledFixture(coreDir: String) -> Fixture? {
        let bundle = Bundle(for: FixtureBundleToken.self)
        guard let manifest = bundle.url(forResource: "EXPECTED-\(coreDir)", withExtension: "txt"),
              let text = try? String(contentsOf: manifest, encoding: .utf8),
              let first = text.split(separator: "\n", omittingEmptySubsequences: false).first,
              first.hasPrefix("files:")
        else { return nil }
        let names = first.dropFirst("files:".count).split(separator: " ").map(String.init)
        guard names.count >= 2 else { return nil }
        let urls = names.map { name -> URL? in
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            return bundle.url(forResource: base, withExtension: ext)
        }
        // A manifest that names files the bundle does not hold is a capture that
        // went missing, not one that was never taken: say so rather than skip.
        guard let rom = urls[0], let state = urls[1] else {
            Issue.record("EXPECTED-\(coreDir).txt names \(names.joined(separator: ", ")) but the test bundle does not hold them all. Check that Fixtures/SaveStateCompat/\(coreDir) is in the test target.")
            return nil
        }
        return Fixture(rom: rom, state: state, goldenSav: urls.count > 2 ? urls[2] : nil)
    }
}

/// Anchors `Bundle(for:)` on the test bundle (a Swift Testing suite is a struct).
private final class FixtureBundleToken {}

/// Set from the PSP bridge's boot-failed notification, which is posted on the
/// main queue while the test may run on another thread; read after a short wait.
private final class BootFailureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    /// True if the core said it could not start within half a second.
    func waitBriefly() -> Bool {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            lock.lock(); let v = value; lock.unlock()
            if v { return true }
            if Thread.isMainThread {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            } else {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        return false
    }
}
