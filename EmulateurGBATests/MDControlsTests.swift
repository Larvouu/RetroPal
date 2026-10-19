//
//  MDControlsTests.swift
//  EmulateurGBATests
//
//  The Mega Drive's own controls, added in 1.3.4: the buttons the six-button
//  pad has and nothing else, the letter each element prints, and where a
//  physical pad's buttons land (BlastEmBridge.h maps the bits so that a pad
//  with no mapping has A B C on its left, bottom and right faces).
//
//  The overlap, off-page and picture sweeps over every phone and tablet run in
//  EmulatorLayoutGeometryTests and TabletLayoutTests, which carry `.md` in
//  their console lists. What is here is what only this console has.
//

import Testing
import UIKit
@testable import EmulateurGBA

struct MDControlsTests {

    // MARK: - The pad

    @Test func theElementSetIsThePadsOwn() {
        let set = Set(ControlElement.elements(for: .md))
        for element in [ControlElement.dpad, .btnA, .btnB, .btnX, .btnY, .btnL, .btnR,
                        .btnStart, .btnSelect, .btnMenu, .btnClip] {
            #expect(set.contains(element), "\(element.rawValue) is on the Mega Drive pad")
        }
        for element in [ControlElement.btnL2, .btnR2, .btnMic, .stickLeft, .stickRight,
                        .btnCUp, .btnCDown, .btnCLeft, .btnCRight] {
            #expect(!set.contains(element), "\(element.rawValue) is not on the Mega Drive pad")
        }
    }

    /// The six faces print the pad's own letters, lower row A B C, upper row
    /// X Y Z, and SELECT's place is MODE.
    @Test func eachElementPrintsThePadsLetter() {
        let letters = (ControlElement.mdLowerRow + ControlElement.mdUpperRow)
            .map { $0.displayName(for: .md) }
        #expect(letters == ["A", "B", "C", "X", "Y", "Z"])
        #expect(ControlElement.btnSelect.displayName(for: .md) == "Mode")
    }

    // MARK: - A physical pad

    private func mask(_ apply: (inout ControllerInputSource) -> Void) -> UInt32 {
        var s = ControllerInputSource()
        apply(&s)
        return ControllerManager.buttonMask(from: s, mapping: nil, system: .md)
    }

    /// With no mapping, the left, bottom and right faces are A, B and C, the
    /// top face and the bumpers are Y, X and Z, Menu is START and Options is
    /// MODE: the bits each element above carries (`mdLowerRow`, `mdUpperRow`).
    @Test func aPadPressesABCOnItsLeftBottomAndRightFaces() {
        #expect(mask { $0.faceX = true } == GBAInput.y.rawValue)      // A
        #expect(mask { $0.faceA = true } == GBAInput.a.rawValue)      // B
        #expect(mask { $0.faceB = true } == GBAInput.b.rawValue)      // C
        #expect(mask { $0.shoulderL = true } == GBAInput.l.rawValue)  // X
        #expect(mask { $0.faceY = true } == GBAInput.x.rawValue)      // Y
        #expect(mask { $0.shoulderR = true } == GBAInput.r.rawValue)  // Z
        #expect(mask { $0.menu = true } == GBAInput.start.rawValue)
        #expect(mask { $0.options = true; $0.hasOptions = true } == GBAInput.select.rawValue)
    }
}
