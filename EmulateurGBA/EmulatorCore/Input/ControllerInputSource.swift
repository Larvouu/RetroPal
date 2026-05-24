//
//  ControllerInputSource.swift
//  EmulateurGBA
//
//  A value snapshot of a game controller's button states at one instant.
//  ControllerManager snapshots the live GCExtendedGamepad into this struct,
//  and the button-mapping logic then works off the snapshot. That keeps the
//  mapping pure and unit-testable with a hand-built value, no hardware.
//

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
    var leftStickClick = false  // L3 — the Select fallback for pads without Options
}

extension ControllerInputSource {
    /// Snapshot the current state of a live extended gamepad. The d-pad
    /// directions fold in the left thumbstick, so the analog stick works as a
    /// d-pad. `GCControllerButtonInput.isPressed` already applies a sensible
    /// activation threshold, so no manual deadzone is needed here.
    init(_ g: GCExtendedGamepad) {
        faceA = g.buttonA.isPressed
        faceB = g.buttonB.isPressed
        faceX = g.buttonX.isPressed
        faceY = g.buttonY.isPressed
        up = g.dpad.up.isPressed || g.leftThumbstick.up.isPressed
        down = g.dpad.down.isPressed || g.leftThumbstick.down.isPressed
        left = g.dpad.left.isPressed || g.leftThumbstick.left.isPressed
        right = g.dpad.right.isPressed || g.leftThumbstick.right.isPressed
        shoulderL = g.leftShoulder.isPressed
        shoulderR = g.rightShoulder.isPressed
        menu = g.buttonMenu.isPressed
        options = g.buttonOptions?.isPressed ?? false
        leftStickClick = g.leftThumbstickButton?.isPressed ?? false
    }
}
