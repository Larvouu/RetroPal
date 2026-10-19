//
//  NewConsoleCoresTests.swift
//  EmulateurGBATests
//
//  The bridges of the four consoles of 1.3.4 and after (Mega Drive on BlastEm,
//  Master System and Game Gear on MesenCE, PSP on PPSSPP), at the points of the
//  10-10 core audit that a test can reach without running a core: the cores are
//  device-only libraries, so what is checked here is each bridge's own file
//  handling, through the class methods the bridges read and write with.
//
//  What the audit proved on the Linux box against the real cores, and why each
//  test exists:
//   - Mega Drive: BlastEm's `fatal_error` ENDS THE PROCESS, and a state of the
//     wrong shape reaches it. Of 400 damaged copies of the fixture, 108 stopped
//     the core; the bridge's check refuses 105 of them (the other three are
//     damage inside a section of the right length, which only a digest would
//     catch). The check is `BlastEmBridge.isLoadableStateFile`.
//   - Mega Drive: a state loaded right after a reset was reset itself (patch
//     0002, Vendor/blastem-ios/patches): 0 of 600 pictures of the fixture's
//     replay matched before it, 600 of 600 after.
//   - Master System, Game Gear: libretro's cheat files, which the cheat browser
//     offers, print Pro Action Replay codes with a dash, which Mesen refused.
//   - PSP: a slot holds our header, the state's length and digest, before the
//     state; the core reads a state with no length, so nothing else may reach it.
//

import Testing
import Foundation
@testable import EmulateurGBA

struct NewConsoleCoresTests {

    // MARK: - Mega Drive: what a slot must look like before BlastEm reads it

    /// A state as BlastEm writes it (libblastem.c, `retro_serialize`): its
    /// length as a host size_t, then sections of a big-endian 16-bit id and
    /// 32-bit length, then the slack the core pads with. `sections` are
    /// (id, payload) pairs.
    private static func mdState(_ sections: [(UInt16, [UInt8])], slack: Int = 64) -> Data {
        var body: [UInt8] = []
        for (id, payload) in sections {
            body += [UInt8(id >> 8), UInt8(id & 0xFF)]
            let n = UInt32(payload.count)
            body += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            body += payload
        }
        var length = UInt(body.count)
        var file = Data(bytes: &length, count: MemoryLayout<UInt>.size)
        file.append(contentsOf: body)
        file.append(Data(count: slack))
        return file
    }

    /// The three sections every Mega Drive state carries, with the sizes
    /// genesis.c writes: the 68000, the video chip, 64 KB of work RAM.
    private static func mdMinimalSections(ramKB: UInt8 = 64) -> [(UInt16, [UInt8])] {
        [(1, [UInt8](repeating: 0x11, count: 90)),
         (3, [UInt8](repeating: 0x22, count: 200)),
         (10, [ramKB] + [UInt8](repeating: 0x33, count: 64))]
    }

    @Test func aStateOfTheCoresShapeIsAccepted() {
        #expect(BlastEmBridge.isLoadableStateFile(Self.mdState(Self.mdMinimalSections())),
                "A state framed as BlastEm writes it was refused.")
        // An 8 KB Z80 RAM section, as a real state has, is fine.
        let withZ80RAM = Self.mdMinimalSections() + [(11, [8] + [UInt8](repeating: 0, count: 16))]
        #expect(BlastEmBridge.isLoadableStateFile(Self.mdState(withZ80RAM)))
        // No slack at all is still a whole state.
        #expect(BlastEmBridge.isLoadableStateFile(Self.mdState(Self.mdMinimalSections(), slack: 0)))
    }

    /// Every way a file could reach `fatal_error` through the framing.
    @Test func aStateTheCoreWouldStopOnIsRefused() {
        let good = Self.mdState(Self.mdMinimalSections())

        // Empty, and shorter than the length field.
        #expect(!BlastEmBridge.isLoadableStateFile(Data()))
        #expect(!BlastEmBridge.isLoadableStateFile(good.prefix(MemoryLayout<UInt>.size - 1)))

        // Cut into the slack only: the state is whole, as the core would read it.
        #expect(BlastEmBridge.isLoadableStateFile(good.prefix(good.count - 64)))
        // Cut into the state itself: the declared length runs past the file.
        for cut in [65, 100, good.count - MemoryLayout<UInt>.size - 1] {
            #expect(!BlastEmBridge.isLoadableStateFile(good.prefix(good.count - cut)),
                    "A state cut by \(cut) bytes was accepted.")
        }

        // A declared length of zero.
        var zero = good
        zero.replaceSubrange(0..<MemoryLayout<UInt>.size, with: Data(count: MemoryLayout<UInt>.size))
        #expect(!BlastEmBridge.isLoadableStateFile(zero))

        // A section longer than what is left ("Section is bigger than remaining space").
        var oversized = good
        let firstLength = MemoryLayout<UInt>.size + 2
        oversized[firstLength] = 0x7F
        #expect(!BlastEmBridge.isLoadableStateFile(oversized))

        // The same, on the LAST section, after the three a state needs: the
        // core reads them, then stops on this one.
        var lastTooLong = Self.mdState(Self.mdMinimalSections() + [(4, [UInt8](repeating: 0, count: 16))], slack: 0)
        lastTooLong[lastTooLong.count - 16 - 1] = 17
        #expect(!BlastEmBridge.isLoadableStateFile(lastTooLong))

        // More work RAM, or more Z80 RAM, than the console has (genesis.c fatals).
        #expect(!BlastEmBridge.isLoadableStateFile(Self.mdState(Self.mdMinimalSections(ramKB: 128))))
        let bigZ80 = Self.mdMinimalSections() + [(11, [16] + [UInt8](repeating: 0, count: 16))]
        #expect(!BlastEmBridge.isLoadableStateFile(Self.mdState(bigZ80)))
    }

    /// A file that is not a Mega Drive state at all: another core's, or noise.
    @Test func aForeignStateIsRefused() {
        // Framed correctly but missing the work RAM, as a Master System state
        // from BlastEm's other path would be.
        let noRAM = Array(Self.mdMinimalSections().prefix(2))
        #expect(!BlastEmBridge.isLoadableStateFile(Self.mdState(noRAM)))

        // Another app's or another core's bytes: a Mesen state's "MSS" header,
        // a PSP slot's, and noise.
        var mesen = Data("MSS".utf8)
        mesen.append(Data(repeating: 0x5A, count: 4096))
        #expect(!BlastEmBridge.isLoadableStateFile(mesen))
        #expect(!BlastEmBridge.isLoadableStateFile(Data("RPPSPZ1\0".utf8) + Data(count: 4096)))
        var x: UInt32 = 0x9E3779B9
        let noise = Data((0..<150_000).map { _ -> UInt8 in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            return UInt8(truncatingIfNeeded: x)
        })
        #expect(!BlastEmBridge.isLoadableStateFile(noise))
    }

    /// The real state, from the core 1.3.4 ships (the SaveStateCompatibility
    /// fixture): accepted as it is, refused once cut. Read from the test bundle,
    /// where every fixture is copied flat, so this runs on the phone too.
    @Test func theShippedCoresOwnStateIsAccepted() throws {
        let bundle = Bundle(for: NewConsoleCoresBundleToken.self)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SaveStateCompat/md/kleleatoms.state")
        guard let url = bundle.url(forResource: "kleleatoms", withExtension: "state")
                ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil)
        else {
            print("[NewConsoleCoresTests] SKIPPED: the Mega Drive fixture kleleatoms.state is neither in the test bundle nor at \(source.path). The real-state check covers nothing here.")
            return
        }
        let state = try Data(contentsOf: url)
        #expect(BlastEmBridge.isLoadableStateFile(state),
                "The Mega Drive fixture, a state the shipped core wrote, is refused by the bridge's check.")
        #expect(!BlastEmBridge.isLoadableStateFile(state.prefix(state.count / 2)))
    }

    // MARK: - Mega Drive: the patch that keeps a loaded state from being reset

    /// The patch is applied by the build, from a folder; a patch that is
    /// deleted or renamed away would rebuild the core without it and bring the
    /// reboot-on-resume back, silently. Source tree only.
    @Test func theResetCancellingPatchIsInTheBuild() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let patch = root.appendingPathComponent("Vendor/blastem-ios/patches/0002-a-loaded-state-cancels-a-pending-reset.patch")
        let script = root.appendingPathComponent("Vendor/blastem-ios/build.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            print("[NewConsoleCoresTests] SKIPPED: the source tree is not readable here (\(script.path)). The patch check covers nothing on this runtime.")
            return
        }
        let text = try String(contentsOf: patch, encoding: .utf8)
        #expect(text.contains("gen->reset_cycle = CYCLE_NEVER;"),
                "Patch 0002 no longer cancels the pending reset cycle.")
        #expect(text.contains("gen->reset_requested = 0;"),
                "Patch 0002 no longer cancels a reset already requested.")
    }

    // MARK: - Master System, Game Gear: Pro Action Replay as code lists print it

    @Test func aProActionReplayCodeIsReadWhicheverWayItIsPrinted() {
        for printed in ["00C0:0F05", "00C0 0F05", "00C0-0F05", "00C00F05", " 00C0 - 0F05 "] {
            #expect(MesenBridge.sega8BitProActionReplayDigits(printed) == "00C00F05",
                    "\(printed) did not give the eight digits Mesen reads.")
        }
    }

    /// A Game Genie code stripped of its dashes is six or nine digits, never
    /// the eight a Pro Action Replay code has, so it cannot be read as one.
    @Test func aGameGenieCodeNeverBecomesAProActionReplayCode() {
        for genie in ["00A-19F-E66", "ABC-DEF"] {
            #expect(MesenBridge.sega8BitProActionReplayDigits(genie).count != 8,
                    "\(genie) would pass as a Pro Action Replay code once its dashes are gone.")
        }
    }

    // MARK: - PSP: a slot's header

    /// What PPSSPP writes: "SaveStart" first, then the machine.
    private static func pspState(length: Int = 2_000_000, seed: UInt32 = 7) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let magic = Array("SaveStart".utf8)
        bytes.replaceSubrange(0..<magic.count, with: magic)
        var x = seed
        for i in magic.count..<min(length, 300_000) where i % 4 != 0 {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            bytes[i] = UInt8(truncatingIfNeeded: x)
        }
        return Data(bytes)
    }

    @Test func aPSPStateComesBackExactlyAsSaved() {
        let state = Self.pspState()
        let file = PSPBridge.stateFileData(fromState: state)
        #expect(file.prefix(8) == Data("RPPSPZ1\0".utf8), "A PSP slot was written without our header.")
        #expect(file.count < state.count, "A PSP state that packs was written unpacked.")
        #expect(PSPBridge.state(fromStateFile: file) == state)
    }

    /// The core reads a state with no length, so a damaged or truncated slot
    /// must never reach it as a state.
    @Test func aDamagedOrTruncatedPSPSlotIsRefused() {
        let file = PSPBridge.stateFileData(fromState: Self.pspState())
        for cut in [1, 100, file.count / 2] {
            #expect(PSPBridge.state(fromStateFile: file.prefix(file.count - cut)) == nil,
                    "A PSP slot cut by \(cut) bytes was read.")
        }
        for offset in [40, 41, file.count / 3, file.count - 1] {
            var damaged = file
            damaged[offset] ^= 0x40
            #expect(PSPBridge.state(fromStateFile: damaged) == nil,
                    "A PSP slot damaged at byte \(offset) was read as a state.")
        }
    }

    /// Nothing that is not a PPSSPP state is ever written, and a bare state
    /// (no header of ours) is not read.
    @Test func onlyAPPSSPPStateIsWrittenAndOnlyOurSlotIsRead() {
        #expect(PSPBridge.stateFileData(fromState: Data(repeating: 0x41, count: 4096)).isEmpty)
        #expect(PSPBridge.state(fromStateFile: Self.pspState(length: 4096)) == nil)
    }
}

/// Anchors `Bundle(for:)` on the test bundle (a Swift Testing suite is a struct).
private final class NewConsoleCoresBundleToken {}
