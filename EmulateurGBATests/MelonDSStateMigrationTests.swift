//
//  MelonDSStateMigrationTests.swift
//  EmulateurGBATests
//
//  1.3.3 changes the DS save-state format (Vendor/melonds-ios/patches/0002): a
//  DS state stores the console's own 4 MB of main RAM instead of the DSi's
//  16 MB, format 13.1 instead of 13.0, about 7 MB instead of 19. Every save slot
//  a player made before 1.3.3 is a 13.0 state, so the one thing that must never
//  break is loading those.
//
//  SaveStateCompatibilityTests already asserts that the 13.0 fixture LOADS.
//  This suite asserts what a player would notice if the migration were wrong:
//  that the game then plays exactly as it would have, that what 1.3.3 writes is
//  the new format and reloads exactly, that a state this build cannot read is
//  refused without touching the running game, and that the rewind survives the
//  change of size. The same properties were proven frame by frame on real games
//  with Tools/nds-bench before the patch was committed; these run them on the
//  phone, through the real bridge, its lock and its 3D render thread.
//
//  The fixture is the 13.0 state of a freely redistributable homebrew game,
//  committed with the repository (Fixtures/SaveStateCompat/melonds), so this
//  suite runs on every device ⌘U and never skips.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("DS save states: the 1.3.3 format and the migration from 1.3.2", .serialized)
struct MelonDSStateMigrationTests {

    /// Both screens, 256 x 384 pixels of 4 bytes.
    private static let pictureBytes = 256 * 384 * 4

    @Test("A state written before 1.3.3 plays on exactly as the same moment saved again by 1.3.3")
    func legacyStateAndItsResaveAreTheSameGame() throws {
        let fx = try legacyFixture()
        let bridge = try boot(fx)

        // The old file, straight: 60 frames on.
        #expect(bridge.loadState(fromPath: fx.state.path))
        run(bridge, frames: 60)
        let fromLegacy = picture(bridge)

        // The same moment written again by this build, then loaded: 60 frames on.
        #expect(bridge.loadState(fromPath: fx.state.path))
        let resaved = temporaryFile("state")
        defer { try? FileManager.default.removeItem(at: resaved) }
        #expect(bridge.saveState(toPath: resaved.path))
        #expect(bridge.loadState(fromPath: resaved.path))
        run(bridge, frames: 60)
        let fromResaved = picture(bridge)

        #expect(fromLegacy == fromResaved,
                "The 13.1 copy of a 13.0 state does not play on identically: the migration loses or misplaces something.")
        bridge.shutdown()
    }

    @Test("What 1.3.3 writes is format 13.1, about 7 MB, and reloads exactly")
    func newStatesAreTheSmallFormatAndRoundTrip() throws {
        let fx = try legacyFixture()
        let bridge = try boot(fx)
        #expect(bridge.loadState(fromPath: fx.state.path))
        run(bridge, frames: 30)

        let saved = temporaryFile("state")
        defer { try? FileManager.default.removeItem(at: saved) }
        #expect(bridge.saveState(toPath: saved.path))

        let header = try stateHeader(saved)
        #expect(header.major == 13 && header.minor == 1,
                "Expected a 13.1 state, got \(header.major).\(header.minor): is patch 0002 applied (Vendor/melonds-ios/build.sh)?")
        #expect(header.fileSize > 4 * 1024 * 1024 && header.fileSize < 8 * 1024 * 1024,
                "A DS state should be about 7 MB, this one is \(header.fileSize) bytes.")
        #expect(header.fileSize == header.declaredLength)

        // Straight on from the save, then back to it and on again: same picture.
        run(bridge, frames: 60)
        let straight = picture(bridge)
        #expect(bridge.loadState(fromPath: saved.path))
        run(bridge, frames: 60)
        #expect(picture(bridge) == straight, "A 13.1 state does not restore exactly.")
        bridge.shutdown()
    }

    @Test("A state from a newer format is refused and the running game is untouched")
    func futureStateIsRefusedCleanly() throws {
        let fx = try legacyFixture()
        let bridge = try boot(fx)
        #expect(bridge.loadState(fromPath: fx.state.path))
        run(bridge, frames: 30)

        let saved = temporaryFile("state")
        let future = temporaryFile("state")
        defer {
            try? FileManager.default.removeItem(at: saved)
            try? FileManager.default.removeItem(at: future)
        }
        #expect(bridge.saveState(toPath: saved.path))

        // The same file, marked as written by a newer melonDS (minor version 2),
        // which is what an older build meets when a newer one synced a slot.
        var data = try Data(contentsOf: saved)
        data[6] = 2
        data[7] = 0
        try data.write(to: future)

        #expect(!bridge.loadState(fromPath: future.path), "A state from a newer format was accepted.")
        run(bridge, frames: 30)
        let afterRefusal = picture(bridge)

        // Had the refusal touched the console, this would differ.
        #expect(bridge.loadState(fromPath: saved.path))
        run(bridge, frames: 30)
        #expect(picture(bridge) == afterRefusal, "Refusing a state changed the running game.")
        bridge.shutdown()
    }

    @Test("The rewind works after loading a state written before 1.3.3")
    func rewindAcrossTheFormatChange() throws {
        let fx = try legacyFixture()
        let bridge = try boot(fx)
        #expect(bridge.loadState(fromPath: fx.state.path))
        bridge.initRewind(35)
        // Snapshots fall due every five seconds (300 frames): 700 frames hold at
        // least one, plus the anchor.
        for _ in 0..<700 {
            bridge.runFrame()
            bridge.rewindAppend()
        }
        #expect(bridge.rewindFrames(300), "Rewind refused after a 13.0 state was loaded.")
        run(bridge, frames: 10)
        bridge.shutdown()
    }

    // MARK: - Helpers

    private func legacyFixture() throws -> SaveStateCompatibilityTests.Fixture {
        guard let fx = SaveStateCompatibilityTests.locateFixture(coreDir: "melonds", romExtensions: ["nds"]) else {
            Issue.record("The committed DS fixture (Fixtures/SaveStateCompat/melonds) was not found in the source tree nor in the test bundle.")
            throw FixtureMissing()
        }
        let header = try stateHeader(fx.state)
        #expect(header.major == 13 && header.minor == 0,
                "The DS fixture must stay the 13.0 format players have. Never recapture it with a newer core.")
        return fx
    }

    /// Boot as the app does (loadROM, setSavePath, reset, one frame), with the
    /// battery save on a throwaway file.
    private func boot(_ fx: SaveStateCompatibilityTests.Fixture) throws -> MelonDSBridge {
        let bridge = MelonDSBridge()
        #expect(bridge.loadROM(atPath: fx.rom.path), "ROM failed to load: \(fx.rom.lastPathComponent)")
        let save = temporaryFile("sav")
        bridge.setSavePath(save.path)
        bridge.reset()
        bridge.runFrame()
        return bridge
    }

    private func run(_ bridge: MelonDSBridge, frames: Int) {
        for _ in 0..<frames { bridge.runFrame() }
    }

    private func picture(_ bridge: MelonDSBridge) -> Data {
        guard let pixels = bridge.frameBuffer() else { return Data() }
        return Data(bytes: pixels, count: Self.pictureBytes)
    }

    private func temporaryFile(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    /// melonDS's header: "MELN", u16 major, u16 minor, u32 length, little-endian.
    private func stateHeader(_ url: URL) throws -> (major: Int, minor: Int, declaredLength: Int, fileSize: Int) {
        let data = try Data(contentsOf: url)
        guard data.count >= 16, data.prefix(4) == Data("MELN".utf8) else {
            Issue.record("\(url.lastPathComponent) is not a melonDS state.")
            throw FixtureMissing()
        }
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        return (u16(4), u16(6), u32(8), data.count)
    }

    private struct FixtureMissing: Error {}
}
