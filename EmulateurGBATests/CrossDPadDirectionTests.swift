//
//  CrossDPadDirectionTests.swift
//  EmulateurGBATests
//
//  Regression coverage for the diagonal bug: the touch D-pad / joystick share
//  CrossDPadView.buttonsForPoint, whose angle sectors were skewed left, so
//  right diagonals (up+right / down+right) collapsed to pure right while left
//  diagonals worked. These lock in symmetric 8-way behaviour.
//

import Testing
import UIKit
@testable import EmulateurGBA

// The suite instantiates UIView subclasses (CrossDPadView / DPadView). Swift
// Testing runs suites off the main thread by default, which trips the Main Thread
// Checker on `UIView.init(frame:)`; pin the whole suite to the main actor.
@MainActor
struct CrossDPadDirectionTests {
    // 120x120 pad: center (60,60), deadzone = 120 * 0.12 = 14.4pt.
    private func pad() -> CrossDPadView {
        CrossDPadView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
    }

    private let up = GBAInput.up.rawValue
    private let down = GBAInput.down.rawValue
    private let left = GBAInput.left.rawValue
    private let right = GBAInput.right.rawValue

    @Test func cardinalsFireExactlyOneDirection() {
        let p = pad()
        #expect(p.buttonsForPoint(CGPoint(x: 60, y: 5))   == up)
        #expect(p.buttonsForPoint(CGPoint(x: 60, y: 115)) == down)
        #expect(p.buttonsForPoint(CGPoint(x: 5,  y: 60))  == left)
        #expect(p.buttonsForPoint(CGPoint(x: 115, y: 60)) == right)
    }

    @Test func diagonalsFireBothDirectionsOnLeftAndRight() {
        let p = pad()
        // Left diagonals always worked.
        #expect(p.buttonsForPoint(CGPoint(x: 20, y: 20))  == (up | left))
        #expect(p.buttonsForPoint(CGPoint(x: 20, y: 100)) == (down | left))
        // Right diagonals are the bug: these used to return `right` alone.
        #expect(p.buttonsForPoint(CGPoint(x: 100, y: 20))  == (up | right))
        #expect(p.buttonsForPoint(CGPoint(x: 100, y: 100)) == (down | right))
    }

    @Test func deadzoneReturnsNothing() {
        let p = pad()
        #expect(p.buttonsForPoint(CGPoint(x: 62, y: 62)) == 0)
    }

    /// The shared mapping both styles (d-pad + joystick) delegate to.
    @Test func sharedGeometryFiresBothDirectionsOnEveryDiagonal() {
        #expect(DPadGeometry.buttons(forAngle: -.pi / 4)     == (up | right))
        #expect(DPadGeometry.buttons(forAngle: .pi / 4)      == (down | right))
        #expect(DPadGeometry.buttons(forAngle: -.pi * 3 / 4) == (up | left))
        #expect(DPadGeometry.buttons(forAngle: .pi * 3 / 4)  == (down | left))
        #expect(DPadGeometry.buttons(forAngle: -.pi / 2)     == up)
        #expect(DPadGeometry.buttons(forAngle: .pi / 2)      == down)
        #expect(DPadGeometry.buttons(forAngle: 0)            == right)
        #expect(DPadGeometry.buttons(forAngle: .pi)          == left)
    }

    /// The joystick style (DPadView) shares the same mapping — right diagonals
    /// used to collapse to pure right here too.
    @Test func joystickFiresBothDirectionsOnRightDiagonals() {
        let j = DPadView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        #expect(j.buttonsForPoint(CGPoint(x: 100, y: 20))  == (up | right))
        #expect(j.buttonsForPoint(CGPoint(x: 100, y: 100)) == (down | right))
    }

    // MARK: - Narrowed diagonals (cardinalHalfWidth = 56°)

    /// The core UX fix: a thumb roll NEAR a cardinal must fire that cardinal ONLY.
    /// With the old ±67.5° sectors a 30° offset fired right+down; the ±56° sectors
    /// keep the 68°-wide pure-cardinal band, so it stays a single direction.
    @Test func nearCardinalDoesNotFireAccidentalDiagonal() {
        let deg = CGFloat.pi / 180
        // 30° off +x toward down (old: right|down) and toward up (old: right|up).
        #expect(DPadGeometry.buttons(forAngle:  30 * deg) == right)
        #expect(DPadGeometry.buttons(forAngle: -30 * deg) == right)
        // 33° is still inside the pure-cardinal band (boundary is 34°).
        #expect(DPadGeometry.buttons(forAngle:  33 * deg) == right)
        // Same near every other cardinal.
        #expect(DPadGeometry.buttons(forAngle:  90 * deg + 30 * deg) == down)
        #expect(DPadGeometry.buttons(forAngle: -90 * deg - 30 * deg) == up)
        #expect(DPadGeometry.buttons(forAngle: 180 * deg - 30 * deg) == left)
    }

    /// A diagonal must be AIMED at the corner: the both-pressed band is the narrow
    /// 22° around each 45° corner (34°…56°). 45° fires both; 35° just enters it;
    /// 33° does not.
    @Test func diagonalRequiresAimingNearTheCorner() {
        let deg = CGFloat.pi / 180
        #expect(DPadGeometry.buttons(forAngle: 45 * deg) == (down | right))
        #expect(DPadGeometry.buttons(forAngle: 35 * deg) == (down | right))
        #expect(DPadGeometry.buttons(forAngle: 33 * deg) == right)
    }
}
