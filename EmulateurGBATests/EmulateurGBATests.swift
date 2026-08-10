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

        // Face buttons. X/Y are POSITIONAL: the NDS diamond has X north and
        // Y west, while GC's faceX is west and faceY north — so they cross
        // (name-matching made Square open NDS menus).
        #expect(mask { $0.faceA = true } == GBAInput.a.rawValue)
        #expect(mask { $0.faceB = true } == GBAInput.b.rawValue)
        #expect(mask { $0.faceX = true } == GBAInput.y.rawValue)
        #expect(mask { $0.faceY = true } == GBAInput.x.rawValue)
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

    // MARK: - Custom mapping (1.2.4 remapping, wave one)

    /// A nil mapping is the byte-identical built-in path (locked by the tests
    /// above); a custom mapping replaces the BUTTON assignments with its own
    /// while the d-pad stays direct.
    @Test
    func test_customMapping_swapsFaceButtons() {
        var mapping = ControllerMapping.defaults(for: .gba)
        mapping.assignments[.a] = .faceB     // Nintendo-vs-Xbox style swap
        mapping.assignments[.b] = .faceA

        var src = ControllerInputSource()
        src.faceA = true
        #expect(ControllerManager.buttonMask(from: src, mapping: mapping) == GBAInput.b.rawValue)
        src.faceA = false
        src.faceB = true
        #expect(ControllerManager.buttonMask(from: src, mapping: mapping) == GBAInput.a.rawValue)
    }

    /// The d-pad is not remappable: it maps directly under any custom mapping.
    @Test
    func test_customMapping_dpadStaysDirect() {
        let mapping = ControllerMapping(assignments: [:])   // nothing assigned at all
        var src = ControllerInputSource()
        src.left = true
        #expect(ControllerManager.buttonMask(from: src, mapping: mapping) == GBAInput.left.rawValue)
    }

    /// A custom mapping is explicit: the built-in Select-via-L3 fallback does
    /// NOT apply unless the user binds it, and an unassigned physical button
    /// produces nothing.
    @Test
    func test_customMapping_isExplicit() {
        let defaults = ControllerMapping.defaults(for: .gba)
        var src = ControllerInputSource()
        src.leftStickClick = true
        #expect(ControllerManager.buttonMask(from: src, mapping: defaults) == 0,
                "L3 is unbound in the default custom mapping")

        var mapping = defaults
        mapping.assignments[.select] = .leftStickClick
        #expect(ControllerManager.buttonMask(from: src, mapping: mapping) == GBAInput.select.rawValue)
    }

    /// Two console inputs may deliberately share one physical button; both
    /// bits set together.
    @Test
    func test_customMapping_sharedPhysicalPressesBoth() {
        var mapping = ControllerMapping.defaults(for: .gba)
        mapping.assignments[.a] = .faceA
        mapping.assignments[.b] = .faceA
        var src = ControllerInputSource()
        src.faceA = true
        #expect(ControllerManager.buttonMask(from: src, mapping: mapping)
                == (GBAInput.a.rawValue | GBAInput.b.rawValue))
    }

    // MARK: - Left-stick angle resolution (DualShock 4 left/right regression)

    /// The stick resolves by ANGLE through the shared DPadGeometry sectors —
    /// full deflection on any axis must produce that direction (the per-axis
    /// isPressed path lost horizontal deflection on some pads).
    @Test
    func test_stickDirections_cardinalsAndDiagonals() {
        // GC coordinates: x +right, y +up.
        #expect(ControllerInputSource.stickDirections(x: 1, y: 0) == GBAInput.right.rawValue)
        #expect(ControllerInputSource.stickDirections(x: -1, y: 0) == GBAInput.left.rawValue)
        #expect(ControllerInputSource.stickDirections(x: 0, y: 1) == GBAInput.up.rawValue)
        #expect(ControllerInputSource.stickDirections(x: 0, y: -1) == GBAInput.down.rawValue)
        // A true 45° diagonal fires both bits (the corner zones).
        #expect(ControllerInputSource.stickDirections(x: 0.8, y: 0.8)
                == (GBAInput.right.rawValue | GBAInput.up.rawValue))
        // Inside the radial deadzone: neutral.
        #expect(ControllerInputSource.stickDirections(x: 0.1, y: 0.1) == 0)
    }

    /// Round-trip: the store persists and restores a mapping exactly, and
    /// reset restores the nil (built-in) state.
    @Test
    func test_mappingStore_roundTripAndReset() {
        defer { ControllerMappingStore.reset(for: .gbc) }
        var mapping = ControllerMapping.defaults(for: .gbc)
        mapping.assignments[.a] = .faceY
        ControllerMappingStore.save(mapping, for: .gbc)
        #expect(ControllerMappingStore.stored(for: .gbc) == mapping)
        ControllerMappingStore.reset(for: .gbc)
        #expect(ControllerMappingStore.stored(for: .gbc) == nil)
    }
}
