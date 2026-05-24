//
//  EmulateurGBATests.swift
//  EmulateurGBATests
//
//  Created 2026-05-18. Week-2 test target stub, populated in Week 3
//  with the ControllerManager button-mapping tests called out by the
//  /plan-eng-review 2026-05-15 test plan.
//

import Testing
@testable import EmulateurGBA

// MARK: - ControllerManager button-mapping tests
//
// Outside-voice review caught that wrong-button-mapping regressions are
// silent in TestFlight (testers assume "my controller is weird" and do
// not file). These tests give us automated coverage of the pure mapping
// function `ControllerManager.buttonMask(from:)`, plus the disconnect
// safety path that releases any held button when the active controller
// goes away.

@Suite("ControllerManager", .serialized)
struct ControllerManagerTests {

    /// Each single-button press maps to exactly one GBAInput bit, with
    /// no extra bits set. The 13 sources are 12 distinct controller
    /// buttons plus the leftStickClick fallback for Select (so pads
    /// without a dedicated Options button can still reach Select via
    /// L3).
    @Test
    func test_extendedGamepad_mapsAllButtonsCorrectly() {
        func mask(_ apply: (inout ControllerInputSource) -> Void) -> UInt32 {
            var src = ControllerInputSource()
            apply(&src)
            return ControllerManager.buttonMask(from: src)
        }

        // Face buttons
        #expect(mask { $0.faceA = true } == GBAInput.a.rawValue)
        #expect(mask { $0.faceB = true } == GBAInput.b.rawValue)
        #expect(mask { $0.faceX = true } == GBAInput.x.rawValue)
        #expect(mask { $0.faceY = true } == GBAInput.y.rawValue)
        // D-pad / left stick (the snapshot folds the stick into the d-pad)
        #expect(mask { $0.up    = true } == GBAInput.up.rawValue)
        #expect(mask { $0.down  = true } == GBAInput.down.rawValue)
        #expect(mask { $0.left  = true } == GBAInput.left.rawValue)
        #expect(mask { $0.right = true } == GBAInput.right.rawValue)
        // Shoulders
        #expect(mask { $0.shoulderL = true } == GBAInput.l.rawValue)
        #expect(mask { $0.shoulderR = true } == GBAInput.r.rawValue)
        // Menu/Start
        #expect(mask { $0.menu = true } == GBAInput.start.rawValue)
        // Select is reachable two ways so every controller can produce
        // it. Both must map to the same Select bit.
        #expect(mask { $0.options        = true } == GBAInput.select.rawValue)
        #expect(mask { $0.leftStickClick = true } == GBAInput.select.rawValue)
        // An empty snapshot maps to the identity mask (no bits set).
        #expect(mask { _ in } == 0)
    }

    /// Pressing A and B at the same time produces a mask with BOTH bits
    /// set in one update. The bridge must see them together, not as two
    /// independent sequential events that race.
    @Test
    func test_extendedGamepad_simultaneousPress_dispatchesBoth() {
        var src = ControllerInputSource()
        src.faceA = true
        src.faceB = true
        let mask = ControllerManager.buttonMask(from: src)
        #expect(mask & GBAInput.a.rawValue != 0, "A bit must be set")
        #expect(mask & GBAInput.b.rawValue != 0, "B bit must be set")
        #expect(mask == GBAInput.a.rawValue | GBAInput.b.rawValue,
                "only A and B should be set, got \(mask)")
    }

    /// Regression guard: when the active controller goes away,
    /// `onButtonsChanged` must fire once with mask = 0 so any button
    /// the user was holding (B during a boss fight, the analog stick
    /// pushed left in a runner) is released on the bridge side.
    /// Without this the emulator core would keep the button stuck
    /// pressed and the game would behave like the user never let go.
    @Test
    func test_disconnect_clearsHeldButtons() {
        let manager = ControllerManager.shared

        // Stash any handler the rest of the app may have registered so
        // we don't leak our test handler past the test boundary.
        let previousHandler = manager.onButtonsChanged
        defer { manager.onButtonsChanged = previousHandler }

        var receivedMasks: [UInt32] = []
        manager.onButtonsChanged = { receivedMasks.append($0) }

        // Drive a connect -> disconnect cycle through the DEBUG-only
        // simulator. `debugSetConnected(false)` takes the same path the
        // real `GCControllerDidDisconnect` notification takes when the
        // last controller goes away: dispatch mask=0, then drop the
        // connected state. No real GCController needed to verify it.
        manager.debugSetConnected(true)
        manager.debugSetConnected(false)

        #expect(receivedMasks.contains(0),
                "disconnect must dispatch mask=0 so held buttons release")
    }
}
