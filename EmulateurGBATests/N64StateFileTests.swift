//
//  N64StateFileTests.swift
//  EmulateurGBATests
//
//  From 1.3.4 an N64 save slot holds the state PACKED: a header of ours (magic,
//  the state's length, a digest of it) and the state compressed with LZFSE
//  (N64Bridge.mm, Save states). An N64 state is a fixed 16,793,412 bytes and
//  the manual slots sync to iCloud, so packing is the difference between up to
//  84 MB of a player's iCloud per game and a few.
//
//  What must never happen, and what these check, through the two class methods
//  the bridge itself reads and writes slots with:
//   - a slot written before 1.3.4 (the bare state) stops loading;
//   - a packed slot comes back as anything but the exact state that was saved;
//   - a damaged or truncated file reaches the core: LZFSE carries no checksum,
//     and one bad byte unpacks to a full-size state that differs from there on,
//     which the core would take as it is. The digest is what refuses it;
//   - a state that does not pack smaller is written any way but as it was.
//
//  The format needs no core and no GPU, so nothing here creates an N64Bridge.
//  The real core's side (the 1.3.3 fixture loads; this build's packed state
//  loads back) is the N64 case of SaveStateCompatibilityTests.
//
//  The same checks were run on the Linux box against the LZFSE reference
//  library before this shipped, on states of four homebrew games: 32x to 218x
//  smaller, and 200 single-bit corruptions per file, every one refused.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("N64 save-state files: the packed format of 1.3.4")
struct N64StateFileTests {

    /// The core's fixed state size (retro_serialize_size()).
    static let stateLength = 16_793_412

    /// What the core writes: "M64+SAVE", then the machine. Mostly zeros, as a
    /// real state is (two nearly empty 4 MB tables and unused RAM), with enough
    /// varied bytes that a damaged byte is not lost in a run of zeros.
    static func makeState(length: Int = stateLength, seed: UInt32 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let magic = Array("M64+SAVE".utf8)
        bytes.replaceSubrange(0..<magic.count, with: magic)
        var x = seed
        // A varied first megabyte, like the part of RAM a game uses.
        for i in magic.count..<min(length, 1 << 20) where i % 3 != 0 {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            bytes[i] = UInt8(truncatingIfNeeded: x)
        }
        return Data(bytes)
    }

    static func packedMagic(_ data: Data) -> Bool {
        data.prefix(8) == Data([0x52, 0x50, 0x4E, 0x36, 0x34, 0x5A, 0x31, 0x00])   // "RPN64Z1\0"
    }

    @Test("A state is written packed, and unpacks to exactly the state that was saved")
    func packedRoundTrip() {
        let state = Self.makeState()
        let file = N64Bridge.stateFileData(fromState: state)
        #expect(Self.packedMagic(file), "The file does not start with the packed format's magic.")
        #expect(file.count < state.count / 4,
                "A mostly empty state packed to \(file.count) bytes of \(state.count): far less than expected.")
        #expect(N64Bridge.state(fromStateFile: file, expectedLength: Self.stateLength) == state,
                "The packed state did not unpack to the exact bytes that were saved.")
    }

    @Test("A slot written before 1.3.4, the bare state, is read as it is")
    func bareStateStillReads() {
        let state = Self.makeState()
        #expect(N64Bridge.state(fromStateFile: state, expectedLength: Self.stateLength) == state,
                "A bare Mupen64Plus state, the format of every slot before 1.3.4, was not read back unchanged.")
    }

    @Test("A damaged packed file never reaches the core as a different state")
    func damagedFileIsRefused() {
        let state = Self.makeState()
        let file = N64Bridge.stateFileData(fromState: state)
        let header = 24
        // One flipped bit at 64 places spread over the payload.
        for k in 0..<64 {
            var damaged = file
            let at = header + k * (file.count - header - 1) / 63
            damaged[at] ^= UInt8(1 << (k % 8))
            // Refused, or (if that bit happened to change nothing the unpacking
            // reads) the exact state: never a state that differs.
            let read = N64Bridge.state(fromStateFile: damaged, expectedLength: Self.stateLength)
            #expect(read == nil || read == state,
                    "A packed file with byte \(at) damaged was accepted as a state that differs from the saved one.")
        }
    }

    @Test("A truncated packed file is refused")
    func truncatedFileIsRefused() {
        let file = N64Bridge.stateFileData(fromState: Self.makeState())
        for cut in [1, 2, 100, file.count / 2, file.count - 25] {
            let read = N64Bridge.state(fromStateFile: file.prefix(file.count - cut), expectedLength: Self.stateLength)
            #expect(read == nil, "A packed file missing its last \(cut) bytes was accepted as a state.")
        }
    }

    @Test("Nothing of another length, and nothing that is not a state, is accepted")
    func wrongLengthOrContentIsRefused() {
        let state = Self.makeState()
        let file = N64Bridge.stateFileData(fromState: state)
        // A state from a core whose size differs from this one's.
        #expect(N64Bridge.state(fromStateFile: file, expectedLength: Self.stateLength - 4) == nil)
        #expect(N64Bridge.state(fromStateFile: state.prefix(Self.stateLength - 1), expectedLength: Self.stateLength) == nil)
        // The right size, but not a Mupen64Plus state.
        var notAState = state
        notAState[0] = UInt8(ascii: "X")
        #expect(N64Bridge.state(fromStateFile: notAState, expectedLength: Self.stateLength) == nil)
        #expect(N64Bridge.state(fromStateFile: N64Bridge.stateFileData(fromState: notAState),
                                expectedLength: Self.stateLength) == nil,
                "A packed file holding something that is not a Mupen64Plus state was accepted.")
        #expect(N64Bridge.state(fromStateFile: Data(), expectedLength: Self.stateLength) == nil)
    }

    @Test("A state that does not pack smaller is written as it was, and still reads")
    func incompressibleStateIsWrittenBare() {
        // 1 MB is enough to be incompressible and keeps the test quick; the
        // format does not depend on the length.
        let length = 1 << 20
        var bytes = [UInt8](repeating: 0, count: length)
        var x: UInt32 = 0x9E37_79B9
        for i in 0..<length {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            bytes[i] = UInt8(truncatingIfNeeded: x)
        }
        bytes.replaceSubrange(0..<8, with: Array("M64+SAVE".utf8))
        let state = Data(bytes)
        let file = N64Bridge.stateFileData(fromState: state)
        #expect(file == state, "An incompressible state was not written unchanged.")
        #expect(N64Bridge.state(fromStateFile: file, expectedLength: length) == state)
    }
}
