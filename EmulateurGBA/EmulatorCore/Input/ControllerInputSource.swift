//
//  ControllerInputSource.swift
//  EmulateurGBA
//
//  A value snapshot of a game controller's button states at one instant.
//  ControllerManager snapshots the live GCExtendedGamepad into this struct,
//  and the button-mapping logic then works off the snapshot. That keeps the
//  mapping pure and unit-testable with a hand-built value, no hardware.
//

import CoreGraphics
import GameController

/// One instant of a controller's button states, in controller terms (face
/// buttons, d-pad, shoulders, menu/options, left-stick click). Mapping these
/// to the emulator's `GBAInput` bitmask is `ControllerManager.buttonMask`.
struct ControllerInputSource {
    var faceA = false
    var faceB = false
    var faceX = false
    var faceY = false
    var up = false
    var down = false
    var left = false
    var right = false
    var shoulderL = false
    var shoulderR = false
    var menu = false            // physical Menu/Start button
    var options = false         // physical Options button (absent on some pads)
    /// Whether the pad HAS one, which is a different question from whether it
    /// is pressed and the one the PlayStation's Select fallback turns on.
    var hasOptions = false
    var leftStickClick = false  // L3 — the Select fallback for pads without Options
    var leftTrigger = false     // L2 / LT / ZL (mappable, unbound by default)
    var rightTrigger = false    // R2 / RT / ZR
    var rightStickClick = false // R3

    /// The thumbsticks as ANALOG, each axis -1...1, y positive UP as
    /// GameController reports it.
    ///
    /// Kept beside the directions rather than instead of them. Every console
    /// before the PlayStation has a digital pad and nothing else, so the sticks
    /// are digitised into `up`/`down`/`left`/`right` above and that stays the
    /// whole story for them. The PlayStation is the first console that can use
    /// the real value, and it needs BOTH: a DualShock reports its stick and its
    /// d-pad separately, so a player using the cross still gets the cross.
    var leftStickX: CGFloat = 0
    var leftStickY: CGFloat = 0
    var rightStickX: CGFloat = 0
    var rightStickY: CGFloat = 0

    /// Whether either stick is meaningfully away from centre. What switches the
    /// emulated pad to a DualShock: see `PCSXBridge.noteAnalogInput` for why
    /// that is done on first movement rather than on connection.
    var hasAnalogInput: Bool {
        let dead: CGFloat = 0.25
        return (leftStickX * leftStickX + leftStickY * leftStickY).squareRoot() > dead
            || (rightStickX * rightStickX + rightStickY * rightStickY).squareRoot() > dead
    }
}

extension ControllerInputSource {
    /// Resolve the left stick into directions BY ANGLE, through the same
    /// shared `DPadGeometry` sectors as the on-screen joystick (56°-wide
    /// cardinals with true diagonal corners), so a pad's stick feels exactly
    /// like the touch joystick. Replaces GCController's per-axis `isPressed`,
    /// whose horizontal threshold proved unreliable on some pads (DualShock 4
    /// left/right dead — device report, 2026-07-24). GC's yAxis is +up;
    /// DPadGeometry is screen-space (+y down), so y flips.
    static func stickDirections(x: CGFloat, y: CGFloat) -> UInt32 {
        let dist = (x * x + y * y).squareRoot()
        guard dist > 0.25 else { return 0 }   // radial deadzone
        return DPadGeometry.buttons(forAngle: atan2(-y, x))
    }
}

extension ControllerInputSource {
    /// Whether a given physical button is pressed in this snapshot — the
    /// custom-mapping and capture paths read buttons by identity.
    func isPressed(_ button: PhysicalButton) -> Bool {
        switch button {
        case .faceA: return faceA
        case .faceB: return faceB
        case .faceX: return faceX
        case .faceY: return faceY
        case .shoulderL: return shoulderL
        case .shoulderR: return shoulderR
        case .menu: return menu
        case .options: return options
        case .leftStickClick: return leftStickClick
        case .leftTrigger: return leftTrigger
        case .rightTrigger: return rightTrigger
        case .rightStickClick: return rightStickClick
        }
    }

    /// Every mappable physical button currently pressed (capture uses the
    /// first NEWLY pressed one vs the previous snapshot).
    var pressedButtons: [PhysicalButton] {
        PhysicalButton.allCases.filter { isPressed($0) }
    }
}

extension ControllerInputSource {
    /// Snapshot the current state of a live extended gamepad. The d-pad
    /// directions fold in the left thumbstick, resolved by ANGLE via
    /// `stickDirections` (see above). `GCControllerButtonInput.isPressed`
    /// applies a sensible activation threshold for the buttons.
    init(_ g: GCExtendedGamepad) {
        faceA = g.buttonA.isPressed
        faceB = g.buttonB.isPressed
        faceX = g.buttonX.isPressed
        faceY = g.buttonY.isPressed
        leftStickX = CGFloat(g.leftThumbstick.xAxis.value)
        leftStickY = CGFloat(g.leftThumbstick.yAxis.value)
        rightStickX = CGFloat(g.rightThumbstick.xAxis.value)
        rightStickY = CGFloat(g.rightThumbstick.yAxis.value)
        let stick = Self.stickDirections(x: leftStickX, y: leftStickY)
        up = g.dpad.up.isPressed || stick & GBAInput.up.rawValue != 0
        down = g.dpad.down.isPressed || stick & GBAInput.down.rawValue != 0
        left = g.dpad.left.isPressed || stick & GBAInput.left.rawValue != 0
        right = g.dpad.right.isPressed || stick & GBAInput.right.rawValue != 0
        shoulderL = g.leftShoulder.isPressed
        shoulderR = g.rightShoulder.isPressed
        menu = g.buttonMenu.isPressed
        options = g.buttonOptions?.isPressed ?? false
        hasOptions = (g.buttonOptions != nil)
        leftStickClick = g.leftThumbstickButton?.isPressed ?? false
        leftTrigger = g.leftTrigger.isPressed
        rightTrigger = g.rightTrigger.isPressed
        rightStickClick = g.rightThumbstickButton?.isPressed ?? false
    }
}
