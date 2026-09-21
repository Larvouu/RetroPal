//
//  ControllerManager.swift
//  EmulateurGBA
//
//  Watches for connected game controllers app-wide and maps the active
//  controller's input to the emulator's GBAInput bitmask.
//
//  `.shared` lives for the whole app lifetime so the connection state is
//  observable from anywhere: the emulator screen hides the on-screen touch
//  controls while a controller is connected, and Settings disables the
//  button-lock toggle (a physical pad does not need the long-press lock).
//
//  `buttonMask(from:)` is static and pure — it is unit-tested with a
//  hand-built ControllerInputSource, no hardware required (see the Week 3
//  ControllerManager tests in the test plan). The GCController connect/
//  disconnect glue is notification-driven and validated in the TestFlight beta.
//

import Combine
import CoreGraphics
import GameController
import UIKit

final class ControllerManager: ObservableObject {

    /// App-wide instance. Created once, lives for the process lifetime.
    static let shared = ControllerManager()

    /// True while an extended-gamepad controller is connected. `@Published`
    /// for SwiftUI (Settings). A keyboard never sets it: the pad rows, the
    /// library badge and the touch-settings lock describe a PAD.
    @Published private(set) var isConnected = false

    /// True while a hardware keyboard is attached (`GCKeyboard.coalesced`),
    /// published so Settings can show the keyboard row the moment one pairs.
    @Published private(set) var isKeyboardAttached: Bool = GCKeyboard.coalesced != nil

    /// Whether the on-screen controls should be out of the way: a pad is
    /// connected, or a keyboard is attached to a PHONE. On a phone a keyboard
    /// is a keyboard-mode pad in a shell (the 8BitDo Zero case) or a desk, and
    /// either way the glass is not the input surface. On an iPad it is often a
    /// Magic Keyboard under a screen the player still touches, so there the
    /// controls stay (decided 2026-09-07). This, not `isConnected`, is what
    /// the emulator screen reads for the controls, the layout key, the dress
    /// and the skin lock; its `didSet` drives `onConnectionChanged`.
    @Published private(set) var hidesTouchControls = false {
        didSet {
            guard oldValue != hidesTouchControls else { return }
            onConnectionChanged?(hidesTouchControls)
        }
    }

    /// The phone is the one idiom where a keyboard hides the controls.
    private static var keyboardHidesTouchControls: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private func updateTouchControlsMode() {
        hidesTouchControls = isConnected || (isKeyboardAttached && Self.keyboardHidesTouchControls)
    }

    /// Display name of the active controller (e.g. "Xbox Wireless Controller",
    /// "DualSense Wireless Controller"). `nil` when nothing is connected.
    /// `@Published` so the Settings status row + controller how-to sheet
    /// update live as a pad connects or disconnects.
    @Published private(set) var controllerName: String?

    /// The active pad's vendor family — the remap UI shows the buttons' own
    /// printed names (△, LB, ZL…) instead of the generic GC terms.
    @Published private(set) var controllerStyle: ControllerStyle = .generic

    /// The active pad's battery, 0...1. `nil` when nothing is connected or the
    /// pad reports no battery (wired, or a state of "unknown"). Read on
    /// adoption and once a minute after, which is the rate a battery moves
    /// at; the library's status badge shows it beside the controller icon.
    @Published private(set) var batteryLevel: Double?
    private var batteryTimer: Timer?

    /// Called on the main thread with the current GBAInput bitmask whenever the
    /// active controller's OR the hardware keyboard's input changes (the two
    /// sources are OR-combined). Carries 0 when a controller disconnects, so
    /// no button stays stuck pressed.
    var onButtonsChanged: ((UInt32) -> Void)?

    /// The thumbsticks, as analog, whenever the pad reports a change.
    ///
    /// A SEPARATE channel from the button mask on purpose. The mask is what
    /// every console understands and what the touch controls also produce; the
    /// sticks exist on no console here but the PlayStation, and on no input
    /// path but a physical pad. Keeping them apart is what lets the touch
    /// overlay stay exactly what it is: a producer of buttons.
    var onSticksChanged: ((_ leftX: CGFloat, _ leftY: CGFloat,
                           _ rightX: CGFloat, _ rightY: CGFloat) -> Void)?

    /// Called on the main thread when the touch controls should go (true) or
    /// come back (false): a pad connects or the last one disconnects, or, on a
    /// phone only, a keyboard is attached or removed. See `hidesTouchControls`.
    var onConnectionChanged: ((Bool) -> Void)?

    /// The custom button mapping applied to controller input (per console
    /// family, Pro). Set by EmulatorViewController at session start; nil = the
    /// built-in layout, byte-identical to the historical behavior.
    var activeMapping: ControllerMapping?
    /// The console being played, for the built-in layout only: a custom mapping
    /// is explicit and needs no console to interpret it.
    var activeSystem: PresetSystem?

    /// The keyboard mapping applied to key input (per console family, free;
    /// see `KeyboardMapping.swift`). Set by EmulatorViewController at session
    /// start, like `activeMapping`; the built-in layout until then.
    var activeKeyboardMapping: KeyboardMapping = .builtIn

    /// Key capture mode, the keyboard twin of `captureHandler`: while set, the
    /// next FRESH key press is reported here on the main thread instead of
    /// driving the game. The keyboard remap page sets it for one binding and
    /// clears it.
    var keyboardCaptureHandler: ((GCKeyCode) -> Void)?

    /// Fired on the main thread when the pad's spare "menu-ish" button is
    /// pressed (DualShock/DualSense touchpad click, Xbox Share) — the VC opens
    /// the in-game menu. These buttons sit outside PhysicalButton on purpose:
    /// they are never remappable and never game input.
    var onMenuRequested: (() -> Void)?

    /// Fired on the main thread when a bound shortcut verb's button changes
    /// state (true = pressed). Fast forward uses both edges (hold); the card
    /// verbs act on press only.
    var onActionChanged: ((RemapAction, Bool) -> Void)?
    private var actionStates: [RemapAction: Bool] = [:]

    /// Fired on a FRESH press of the pad's east button (Circle / B) — the
    /// universal "back" role. The VC uses it to close the pause menu (resume).
    /// A UI role, not game input: it follows the PHYSICAL east button whatever
    /// the custom mapping says, like the menu-ish button above.
    var onBackRequested: (() -> Void)?
    private var lastBackPressed = false

    /// Remap capture mode: while set, controller presses are routed HERE (the
    /// first newly-pressed mappable button per event) instead of the game, on
    /// the main thread. The remap UI sets it for one assignment and clears it.
    var captureHandler: ((PhysicalButton) -> Void)? {
        didSet {
            // Seed with the pad's LIVE state when capture arms: a button
            // already held (or an analog trigger resting past threshold) must
            // not bind itself on the first event — only a FRESH press captures.
            if captureHandler != nil, let pad = activeController?.extendedGamepad {
                lastSnapshot = ControllerInputSource(pad)
            } else {
                lastSnapshot = nil
            }
        }
    }
    private var lastSnapshot: ControllerInputSource?

    /// The one controller currently driving input. A second controller
    /// connected at the same time is ignored.
    private var activeController: GCController?

    /// The hardware keyboard's current GBAInput bitmask, through
    /// `activeKeyboardMapping` (free).
    private var keyboardMask: UInt32 = 0
    /// The controller's last emitted bitmask, kept so either source can
    /// re-emit the OR-combined state.
    private var controllerMask: UInt32 = 0

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleConnect(_:)),
                       name: .GCControllerDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(handleDisconnect(_:)),
                       name: .GCControllerDidDisconnect, object: nil)
        // Adopt a controller already paired before the app launched.
        if let existing = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            adopt(existing)
        }
        // Hardware keyboard (free; remappable since 1.3.1). GCKeyboard.coalesced
        // is the ONE object iOS offers for every attached keyboard, so two
        // keyboards are one keyboard here, which is also why a second
        // keyboard-mode pad cannot be a second player through this path.
        nc.addObserver(self, selector: #selector(handleKeyboardConnect(_:)),
                       name: .GCKeyboardDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(handleKeyboardDisconnect(_:)),
                       name: .GCKeyboardDidDisconnect, object: nil)
        if let keyboard = GCKeyboard.coalesced {
            adoptKeyboard(keyboard)
        }
        updateTouchControlsMode()
    }

    // MARK: - Button mapping (pure — unit-tested)

    /// Map a controller input snapshot to the emulator's `GBAInput` bitmask.
    /// The D-pad (+ left stick) always steers the console D-pad. With no
    /// custom `mapping` the built-in layout applies: X / Y are NDS-only (the
    /// GBA bridge ignores those bits) and Select is reachable two ways so
    /// every controller can produce it — the Options button, or clicking the
    /// left thumbstick (L3). A custom mapping (Pro) replaces the button
    /// assignments with its explicit ones.
    static func buttonMask(from s: ControllerInputSource,
                           mapping: ControllerMapping? = nil,
                           system: PresetSystem? = nil) -> UInt32 {
        var mask: UInt32 = 0
        if s.up         { mask |= GBAInput.up.rawValue }
        if s.down       { mask |= GBAInput.down.rawValue }
        if s.left       { mask |= GBAInput.left.rawValue }
        if s.right      { mask |= GBAInput.right.rawValue }

        if let mapping {
            for (input, physical) in mapping.assignments where s.isPressed(physical) {
                mask |= input.gbaInput.rawValue
            }
            return mask
        }

        if s.faceA      { mask |= GBAInput.a.rawValue }
        if s.faceB      { mask |= GBAInput.b.rawValue }
        // NDS X/Y are POSITIONAL, not name-matched: the NDS diamond puts X
        // north and Y west (SNES-style), while GC's buttonX is WEST and
        // buttonY NORTH. Name-matching crossed them (Square opened menus —
        // device report, 2026-07-25): pad west drives console Y, pad
        // north drives console X, like every other position in this map.
        if s.faceX      { mask |= GBAInput.y.rawValue }
        if s.faceY      { mask |= GBAInput.x.rawValue }
        if s.shoulderL  { mask |= GBAInput.l.rawValue }
        if s.shoulderR  { mask |= GBAInput.r.rawValue }
        if s.menu       { mask |= GBAInput.start.rawValue }

        // THE PLAYSTATION IS THE ONE CONSOLE WHOSE PAD HAS THESE, so it is the
        // one console where the built-in layout can offer them. Before this,
        // a physical pad reached ten of the fourteen buttons a DualShock has:
        // the triggers and both stick clicks had nowhere to go, which made
        // Gran Turismo's brake and Tomb Raider 3's fire button unreachable
        // without a Pro custom mapping.
        if system == .ps1 {
            if s.leftTrigger     { mask |= GBAInput.l2.rawValue }
            if s.rightTrigger    { mask |= GBAInput.r2.rawValue }
            if s.leftStickClick  { mask |= GBAInput.l3.rawValue }
            if s.rightStickClick { mask |= GBAInput.r3.rawValue }
            // Select comes from Options, and from L3 ONLY on a pad that has no
            // Options button. Everywhere else L3 is Select unconditionally,
            // which is right for a console with no L3 of its own and wrong for
            // this one: here it would fire Select every time a game asked for a
            // stick click. The fallback survives because a player on an
            // Options-less pad would otherwise have no Select at all, and the
            // custom mapping that would fix it is behind Pro.
            if s.options || (!s.hasOptions && s.leftStickClick) {
                mask |= GBAInput.select.rawValue
            }
            return mask
        }

        if s.options || s.leftStickClick { mask |= GBAInput.select.rawValue }
        return mask
    }

    // MARK: - GCController glue (notification-driven — beta-validated)

    /// Begin driving input from `controller`, if no controller is active yet
    /// and it exposes an extended gamepad.
    private func adopt(_ controller: GCController) {
        guard activeController == nil, let pad = controller.extendedGamepad else { return }
        activeController = controller
        pad.valueChangedHandler = { [weak self] pad, _ in
            guard let self else { return }
            let snapshot = ControllerInputSource(pad)
            // Remap capture: report the first NEWLY pressed mappable button
            // and swallow the event (no game input while assigning).
            if let capture = self.captureHandler {
                let previous = self.lastSnapshot
                self.lastSnapshot = snapshot
                if let pressed = snapshot.pressedButtons.first(where: { previous?.isPressed($0) != true }) {
                    capture(pressed)
                }
                return
            }
            self.controllerMask = ControllerManager.buttonMask(from: snapshot,
                                                               mapping: self.activeMapping,
                                                               system: self.activeSystem)
            // The "back" role (east button), edge-detected on fresh presses.
            if snapshot.faceB != self.lastBackPressed {
                self.lastBackPressed = snapshot.faceB
                if snapshot.faceB { self.onBackRequested?() }
            }
            // Shortcut verbs (wave 2): edge-detect each bound action.
            if let mapping = self.activeMapping, !mapping.actions.isEmpty {
                for (action, physical) in mapping.actions {
                    let pressed = snapshot.isPressed(physical)
                    if (self.actionStates[action] ?? false) != pressed {
                        self.actionStates[action] = pressed
                        self.onActionChanged?(action, pressed)
                    }
                }
            }
            self.emitButtons()
            self.onSticksChanged?(snapshot.leftStickX, snapshot.leftStickY,
                                  snapshot.rightStickX, snapshot.rightStickY)
        }
        // The spare menu-ish button some pads carry beyond Start/Select opens
        // the in-game menu directly (press only).
        let fireMenu: (GCControllerButtonInput, Float, Bool) -> Void = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.onMenuRequested?()
        }
        if let ds4 = pad as? GCDualShockGamepad {
            ds4.touchpadButton.pressedChangedHandler = fireMenu
        } else if let dualSense = pad as? GCDualSenseGamepad {
            dualSense.touchpadButton.pressedChangedHandler = fireMenu
        } else if let xbox = pad as? GCXboxGamepad {
            xbox.buttonShare?.pressedChangedHandler = fireMenu
        }
        controllerName = controller.vendorName
        controllerStyle = ControllerStyle.from(productCategory: controller.productCategory)
        isConnected = true
        updateTouchControlsMode()
        startBatteryPolling()
        Analytics.signalOnce("controller_connected")
    }

    // MARK: - Battery

    private func readBattery() {
        guard let battery = activeController?.battery, battery.batteryState != .unknown else {
            batteryLevel = nil
            return
        }
        batteryLevel = Double(battery.batteryLevel)
    }

    private func startBatteryPolling() {
        batteryTimer?.invalidate()
        readBattery()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.readBattery()
        }
    }

    private func stopBatteryPolling() {
        batteryTimer?.invalidate()
        batteryTimer = nil
        batteryLevel = nil
    }

    /// Emit the OR of both input sources (controller + hardware keyboard).
    private func emitButtons() {
        onButtonsChanged?(controllerMask | keyboardMask)
    }

    @objc private func handleConnect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        // adopt() guards on activeController == nil, so a second simultaneous
        // controller is ignored — only the first drives input.
        adopt(controller)
    }

    @objc private func handleDisconnect(_ note: Notification) {
        guard let controller = note.object as? GCController,
              controller === activeController else { return }
        activeController = nil
        controllerMask = 0
        stopBatteryPolling()
        emitButtons()  // release any buttons the controller was holding
        // Release any held shortcut verb (a stuck hold-to-fast-forward would
        // outlive the pad otherwise).
        for (action, pressed) in actionStates where pressed {
            onActionChanged?(action, false)
        }
        actionStates = [:]
        // Fall back to another still-connected controller, if one exists.
        if let next = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            adopt(next)
        } else {
            controllerName = nil
            controllerStyle = .generic
            isConnected = false
            updateTouchControlsMode()
        }
    }

    // MARK: - Hardware keyboard (free, remappable)

    /// Fired on keyboard connect/disconnect so hosts can re-evaluate.
    var onKeyboardChanged: (() -> Void)?

    private func adoptKeyboard(_ keyboard: GCKeyboard) {
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard let self else { return }
            // Remap capture: the first FRESH press binds, whatever the key, and
            // is swallowed (no game input while assigning). A release is not a
            // press, and neither is a key that was already down when capture
            // armed, since only a change reaches this handler.
            if let capture = self.keyboardCaptureHandler {
                if pressed { DispatchQueue.main.async { capture(keyCode) } }
                return
            }
            guard let input = self.activeKeyboardMapping.input(for: keyCode) else { return }
            // Recompute from the live key states rather than toggling bits:
            // two keys may share an input (both Shifts are Select), and a
            // missed release can't stick.
            if let keys = GCKeyboard.coalesced?.keyboardInput {
                self.keyboardMask = KeyboardMapping.mask(self.activeKeyboardMapping) {
                    keys.button(forKeyCode: $0)?.isPressed == true
                }
            } else if pressed {
                self.keyboardMask |= input.gbaInput.rawValue
            } else {
                self.keyboardMask &= ~input.gbaInput.rawValue
            }
            DispatchQueue.main.async { self.emitButtons() }
        }
    }

    @objc private func handleKeyboardConnect(_ note: Notification) {
        if let keyboard = GCKeyboard.coalesced { adoptKeyboard(keyboard) }
        isKeyboardAttached = GCKeyboard.coalesced != nil
        updateTouchControlsMode()
        onKeyboardChanged?()
    }

    @objc private func handleKeyboardDisconnect(_ note: Notification) {
        keyboardMask = 0
        emitButtons()
        isKeyboardAttached = GCKeyboard.coalesced != nil
        updateTouchControlsMode()
        onKeyboardChanged?()
    }

    #if DEBUG
    /// Debug-only: fake a connection state so the touch-controls hide and the
    /// Settings toggle disable can be verified without real hardware.
    func debugSetConnected(_ connected: Bool) {
        if !connected { onButtonsChanged?(0) }
        controllerName = connected ? "Debug Controller" : nil
        // A battery too, so the library's status badge can be seen.
        batteryLevel = connected ? 0.73 : nil
        isConnected = connected
        updateTouchControlsMode()
    }

    /// Debug-only: fake an attached keyboard so the keyboard remap row and
    /// page, and the phone-only hiding of the touch controls, can be reviewed
    /// without pairing one. Capture still waits for a REAL key, since there is
    /// none to fake; a real keyboard connecting or leaving overrides this.
    func debugSetKeyboardAttached(_ attached: Bool) {
        if !attached {
            keyboardMask = 0
            emitButtons()
        }
        isKeyboardAttached = attached
        updateTouchControlsMode()
        onKeyboardChanged?()
    }
    #endif
}
