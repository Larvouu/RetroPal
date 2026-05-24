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
import GameController

final class ControllerManager: ObservableObject {

    /// App-wide instance. Created once, lives for the process lifetime.
    static let shared = ControllerManager()

    /// True while an extended-gamepad controller is connected. `@Published`
    /// for SwiftUI (Settings); the `didSet` also drives the closure below for
    /// the UIKit emulator screen.
    @Published private(set) var isConnected = false {
        didSet {
            guard oldValue != isConnected else { return }
            onConnectionChanged?(isConnected)
        }
    }

    /// Display name of the active controller (e.g. "Xbox Wireless Controller",
    /// "DualSense Wireless Controller"). `nil` when nothing is connected.
    /// `@Published` so the Settings status row + controller how-to sheet
    /// update live as a pad connects or disconnects.
    @Published private(set) var controllerName: String?

    /// Called on the main thread with the current GBAInput bitmask whenever the
    /// active controller's input changes. Carries 0 when a controller
    /// disconnects, so no button stays stuck pressed.
    var onButtonsChanged: ((UInt32) -> Void)?

    /// Called on the main thread when a controller connects (true) or the last
    /// one disconnects (false).
    var onConnectionChanged: ((Bool) -> Void)?

    /// The one controller currently driving input. A second controller
    /// connected at the same time is ignored.
    private var activeController: GCController?

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
    }

    // MARK: - Button mapping (pure — unit-tested)

    /// Map a controller input snapshot to the emulator's `GBAInput` bitmask.
    /// X / Y are NDS-only; the GBA bridge ignores those bits. Select is
    /// reachable two ways so every controller can produce it: the Options
    /// button, or clicking the left thumbstick (L3).
    static func buttonMask(from s: ControllerInputSource) -> UInt32 {
        var mask: UInt32 = 0
        if s.faceA      { mask |= GBAInput.a.rawValue }
        if s.faceB      { mask |= GBAInput.b.rawValue }
        if s.faceX      { mask |= GBAInput.x.rawValue }
        if s.faceY      { mask |= GBAInput.y.rawValue }
        if s.up         { mask |= GBAInput.up.rawValue }
        if s.down       { mask |= GBAInput.down.rawValue }
        if s.left       { mask |= GBAInput.left.rawValue }
        if s.right      { mask |= GBAInput.right.rawValue }
        if s.shoulderL  { mask |= GBAInput.l.rawValue }
        if s.shoulderR  { mask |= GBAInput.r.rawValue }
        if s.menu       { mask |= GBAInput.start.rawValue }
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
            self?.onButtonsChanged?(ControllerManager.buttonMask(from: ControllerInputSource(pad)))
        }
        controllerName = controller.vendorName
        isConnected = true
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
        onButtonsChanged?(0)  // release any buttons the controller was holding
        // Fall back to another still-connected controller, if one exists.
        if let next = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            adopt(next)
        } else {
            controllerName = nil
            isConnected = false
        }
    }

    #if DEBUG
    /// Debug-only: fake a connection state so the touch-controls hide and the
    /// Settings toggle disable can be verified without real hardware.
    func debugSetConnected(_ connected: Bool) {
        if !connected { onButtonsChanged?(0) }
        controllerName = connected ? "Debug Controller" : nil
        isConnected = connected
    }
    #endif
}
