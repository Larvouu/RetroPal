//
//  ControllerManager.swift
//  EmulateurGBA
//
//  Watches for connected game controllers app-wide, keeps them IN PLAYER
//  ORDER, and maps each one's input to the emulator's GBAInput bitmask for
//  its player.
//
//  `.shared` lives for the whole app lifetime so the connection state is
//  observable from anywhere: the emulator screen hides the on-screen touch
//  controls while a controller is connected, and Settings disables the
//  button-lock toggle (a physical pad does not need the long-press lock).
//
//  PLAYERS. Up to `maxPlayers` controllers are adopted at once, numbered in
//  the order they connected; Settings can reorder them (`movePad`). Player 1
//  is the controller that matters most: it plays every one-player console,
//  and it alone owns the app's own roles (the pause menu, "back", moving
//  around the app); the shortcut verbs and remap capture, which are about pad
//  buttons, go with the first GAME CONTROLLER. A keyboard is a player of its own on a
//  phone and folded into player 1 on an iPad (`keyboardIsAPlayer`). A game
//  hears as many players as its console had (`activePlayerCount`, from
//  `PresetSystem.playerCount`); a controller past that number is ignored
//  while it runs. When a controller leaves, the ones after it move up a
//  place, so there is never a gap: the remaining controllers are always
//  players 1 to N, and a lone survivor is always player 1.
//
//  iOS gives an app no identity for a controller that survives a
//  disconnection (two identical pads report the same name), so the order is
//  the order of THIS connection and is not remembered across reconnections.
//  Each pad's player lights show its number where it has them.
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

    /// One connected controller, as the rest of the app sees it.
    struct Pad: Identifiable, Equatable {
        /// This connection's identity. A new one on every connection, since
        /// iOS offers none that lasts (see the file header).
        let id: UUID
        /// The controller's own name ("DualSense Wireless Controller"), nil
        /// when it reports none.
        var name: String?
        /// Its vendor family, for the buttons' printed names.
        var style: ControllerStyle
        /// Its battery, 0...1. nil when it reports none (wired, or a state
        /// of "unknown"). Read on adoption and once a minute after, which is
        /// the rate a battery moves at.
        var batteryLevel: Double?
        /// A DEBUG stand-in (`debugSetSimulatedControllers`): no hardware
        /// behind it, so it never sends input.
        var isSimulated: Bool = false
        /// What it is: a game controller, or the hardware keyboard, which on
        /// a phone is a player of its own (`keyboardIsAPlayer`).
        var kind: Kind = .gamepad

        enum Kind { case gamepad, keyboard }
    }

    /// Whether the hardware keyboard is a PLAYER of its own, numbered with the
    /// controllers, or folded into player 1.
    ///
    /// On a phone a keyboard is a controller: a keyboard-mode pad in a shell
    /// (the 8BitDo Zero), which is also why it hides the touch controls there
    /// (decided 2026-09-07). So it takes a player like any pad, and a keyboard
    /// pad, a USB-C pad and a Bluetooth pad are players 1, 2 and 3 in the
    /// order they arrived (asked 2026-09-27). On an iPad a keyboard is most
    /// often a Magic Keyboard under a screen the player touches, and making it
    /// player 1 would push the pad actually in their hands to player 2, where a
    /// one-player console no longer hears it: there it stays player 1's.
    static var keyboardIsAPlayer: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// The connected controllers, IN PLAYER ORDER: `pads[0]` is player 1.
    /// Never more than `maxPlayers`. Everything the app shows about
    /// controllers (the library badge, the Settings rows) reads this.
    @Published private(set) var pads: [Pad] = [] {
        didSet { refreshPlayerOneSummary() }
    }

    /// True while at least one game controller is connected (see `isUsable`).
    /// `@Published` for SwiftUI (Settings). A keyboard never sets it, even as a
    /// player: the pad rows, the library badge and the touch-settings lock
    /// describe a PAD.
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

    /// The FIRST GAME CONTROLLER's name in player order (e.g. "Xbox Wireless
    /// Controller"): player 1's, unless player 1 is the keyboard. `nil` when
    /// no controller is connected. `@Published` so the Settings status row +
    /// controller how-to sheet update live as a pad connects or disconnects.
    @Published private(set) var controllerName: String?

    /// The first game controller's vendor family — the remap UI shows the
    /// buttons' own printed names (△, LB, ZL…) instead of the generic GC terms.
    /// That controller is the one remap capture listens to, so its names are
    /// the right ones.
    @Published private(set) var controllerStyle: ControllerStyle = .generic

    /// The first game controller's battery, 0...1. `nil` when none is
    /// connected or it reports no battery. Every pad's own reading is on `pads`.
    @Published private(set) var batteryLevel: Double?
    private var batteryTimer: Timer?

    /// The first game controller in player order: what the pad-specific
    /// roles (remap capture, the shortcut verbs bound to pad buttons) listen
    /// to, since a keyboard has no pad buttons.
    private var firstGamepad: Pad? { pads.first { $0.kind == .gamepad } }

    /// Mirror the first game controller into the single-controller properties
    /// above, which is what every screen written before several controllers
    /// reads, and keep the touch-controls decision current.
    private func refreshPlayerOneSummary() {
        let first = firstGamepad
        if isConnected != (first != nil) { isConnected = (first != nil) }
        if controllerName != first?.name { controllerName = first?.name }
        if controllerStyle != (first?.style ?? .generic) { controllerStyle = first?.style ?? .generic }
        if batteryLevel != first?.batteryLevel { batteryLevel = first?.batteryLevel }
        updateTouchControlsMode()
    }

    /// Fires with a controller's id on every FRESH press of any of its buttons
    /// or directions, so Settings can show which row is the pad in the
    /// player's hands. A press, not a stream: a held button fires once.
    let padActivity = PassthroughSubject<UUID, Never>()

    /// Called on the main thread with one PLAYER's GBAInput bitmask (player 0
    /// is player 1) whenever that player's input changes. On an iPad player
    /// 1's is the OR of its controller and the hardware keyboard; on a phone
    /// the keyboard is a player of its own. Carries 0 when a
    /// player's controller disconnects, so no button stays stuck pressed. Only
    /// players below `activePlayerCount` are ever reported.
    var onButtonsChanged: ((_ player: Int, _ mask: UInt32) -> Void)?

    /// One player's thumbsticks, as analog, whenever that pad reports a change.
    ///
    /// A SEPARATE channel from the button mask on purpose. The mask is what
    /// every console understands and what the touch controls also produce; the
    /// sticks exist on no console here but the PlayStation and the Nintendo 64,
    /// and on no input path but a physical pad. Keeping them apart is what lets
    /// the touch overlay stay exactly what it is: a producer of buttons.
    var onSticksChanged: ((_ player: Int, _ leftX: CGFloat, _ leftY: CGFloat,
                           _ rightX: CGFloat, _ rightY: CGFloat) -> Void)?

    /// Called on the main thread when the touch controls should go (true) or
    /// come back (false): a pad connects or the last one disconnects, or, on a
    /// phone only, a keyboard is attached or removed. See `hidesTouchControls`.
    var onConnectionChanged: ((Bool) -> Void)?

    /// Called on the main thread with the number of connected controllers
    /// whenever the roster changes (a pad connects, leaves, or is moved). The
    /// emulator screen caps it at its console's count for the consoles whose
    /// ports must be told (`EmulatorSession.setConnectedPlayers`).
    var onPlayersChanged: ((Int) -> Void)?

    /// How many players the running game hears: its console's
    /// `PresetSystem.playerCount`, set by the emulator screen at session start.
    /// 1 outside a game. Controllers past it are ignored, which is what keeps a
    /// one-player console on player 1 alone.
    var activePlayerCount = 1 {
        didSet {
            guard oldValue != activePlayerCount else { return }
            // Release anything a player who is no longer heard was holding,
            // then report every player now heard.
            for player in activePlayerCount..<max(oldValue, activePlayerCount) {
                onButtonsChanged?(player, 0)
            }
            for player in 0..<activePlayerCount { emitButtons(player: player) }
        }
    }

    /// Whether the buttons iOS keeps a gesture on belong to the game instead:
    /// Home (which then opens the pause menu), and the Share button of a
    /// PlayStation pad (Create on a DualSense), which is its SELECT, and the
    /// Xbox pad's Share, which opens the pause menu. True only while a game is
    /// on screen (the emulator screen claims and releases them), so everywhere
    /// else they keep their system meaning (see `applySystemButtonClaim`).
    var claimsSystemButtons = false {
        didSet {
            guard oldValue != claimsSystemButtons else { return }
            for controller in hardware.values { applySystemButtonClaim(to: controller) }
        }
    }

    /// The custom button mapping applied to controller input (per console
    /// family, Pro), for every player. Set by EmulatorViewController at
    /// session start; nil = the built-in layout, byte-identical to the
    /// historical behavior.
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

    /// Fired on the main thread when player 1 asks for the pause menu: its
    /// Home button (while `claimsSystemButtons`), its spare "menu-ish" button
    /// (DualShock/DualSense touchpad click, Xbox Share), or Start and Select
    /// held together for `menuHoldDuration`, which every pad can do. These sit
    /// outside PhysicalButton on purpose: they are never remappable and, apart
    /// from the Start+Select hold, never game input.
    var onMenuRequested: (() -> Void)?

    /// How long Start and Select must be held together to open the pause
    /// menu. Long enough that no game's own Start+Select press (a soft reset
    /// is a quick press) reaches it by accident.
    static let menuHoldDuration: TimeInterval = 1.0
    private var menuComboHeld = false
    private var menuHoldWork: DispatchWorkItem?

    /// Fired on the main thread when a bound shortcut verb's button changes
    /// state on player 1's pad (true = pressed). Fast forward uses both edges
    /// (hold); the card verbs act on press only.
    var onActionChanged: ((RemapAction, Bool) -> Void)?
    private var actionStates: [RemapAction: Bool] = [:]

    /// Fired on a FRESH press of player 1's east button (Circle / B) — the
    /// universal "back" role. The VC uses it to close the pause menu (resume).
    /// A UI role, not game input: it follows the PHYSICAL east button whatever
    /// the custom mapping says, like the menu-ish button above.
    var onBackRequested: (() -> Void)?
    private var lastBackPressed = false

    /// Remap capture mode: while set, player 1's presses are routed HERE (the
    /// first newly-pressed mappable button per event) instead of the game, on
    /// the main thread. The remap UI sets it for one assignment and clears it.
    var captureHandler: ((PhysicalButton) -> Void)? {
        didSet {
            // Seed with the pad's LIVE state when capture arms: a button
            // already held (or an analog trigger resting past threshold) must
            // not bind itself on the first event — only a FRESH press captures.
            if captureHandler != nil, let controller = captureController {
                lastSnapshot = Self.snapshot(of: controller)
            } else {
                lastSnapshot = nil
            }
        }
    }
    private var lastSnapshot: ControllerInputSource?

    /// The hardware behind each real pad, by pad id.
    private var hardware: [UUID: GCController] = [:]
    /// Each pad's last emitted bitmask and sticks, by pad id, so a player's
    /// state follows its controller when the order changes.
    private var padMasks: [UUID: UInt32] = [:]
    private var padSticks: [UUID: Sticks] = [:]
    /// Each pad's previous snapshot, for `padActivity`'s fresh-press test.
    private var activitySnapshots: [UUID: ControllerInputSource] = [:]

    private struct Sticks {
        var leftX: CGFloat = 0, leftY: CGFloat = 0, rightX: CGFloat = 0, rightY: CGFloat = 0
    }

    /// The hardware behind the first game controller, which remap capture
    /// listens to. nil when it is simulated or absent.
    private var captureController: GCController? {
        firstGamepad.flatMap { hardware[$0.id] }
    }

    /// The hardware keyboard's current GBAInput bitmask, through
    /// `activeKeyboardMapping` (free): its own player on a phone, folded into
    /// player 1 on an iPad (`keyboardIsAPlayer`).
    private var keyboardMask: UInt32 = 0
    /// The keyboard's place in `pads` while it is a player.
    private var keyboardPadID: UUID?
    /// The keyboard's previous mask, for its fresh presses.
    private var lastKeyboardMask: UInt32 = 0

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleConnect(_:)),
                       name: .GCControllerDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(handleDisconnect(_:)),
                       name: .GCControllerDidDisconnect, object: nil)
        // Adopt the controllers already paired before the app launched, in
        // the order iOS lists them.
        for controller in GCController.controllers() { adopt(controller) }
        // Explicit, not left to `pads`' observer: this still runs inside
        // `init`, and the summary must be right before anyone reads it.
        refreshPlayerOneSummary()
        rosterChanged(previousCount: 0)
        // Hardware keyboard (free; remappable since 1.3.1). GCKeyboard.coalesced
        // is the ONE object iOS offers for every attached keyboard, so two
        // keyboards are one keyboard here, and two keyboard-mode pads are one
        // player. On a phone that keyboard is a player of its own, after the
        // pads already paired (`keyboardIsAPlayer`).
        nc.addObserver(self, selector: #selector(handleKeyboardConnect(_:)),
                       name: .GCKeyboardDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(handleKeyboardDisconnect(_:)),
                       name: .GCKeyboardDidDisconnect, object: nil)
        if let keyboard = GCKeyboard.coalesced {
            adoptKeyboard(keyboard)
            let before = pads.count
            if addKeyboardPlayer() { rosterChanged(previousCount: before) }
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
        // The Nintendo 64 reads its D-pad alone. Its stick reaches the core as
        // analog (`onSticksChanged`), and folded into the D-pad as well, every
        // push of it would also press a D-pad the game reads for something else.
        let n64 = (system == .n64)
        if n64 ? s.padUp : s.up          { mask |= GBAInput.up.rawValue }
        if n64 ? s.padDown : s.down      { mask |= GBAInput.down.rawValue }
        if n64 ? s.padLeft : s.left      { mask |= GBAInput.left.rawValue }
        if n64 ? s.padRight : s.right    { mask |= GBAInput.right.rawValue }

        if let mapping {
            for (input, physical) in mapping.assignments where s.isPressed(physical) {
                mask |= input.gbaInput.rawValue
            }
            return mask
        }

        // THE NINTENDO 64, whose pad has none of the others' letters in the
        // others' places. The core's own RetroPad layout, which RetroArch players
        // already know: the bottom button is A and the left one B, the top and
        // right ones are C up and C down, the bumpers L and R, the left trigger
        // Z. The right stick reaches all four C buttons as analog, beside these.
        // No SELECT: the console has none. `ControllerMapping.defaults(for:)`
        // states the same layout, which is what a custom mapping starts from.
        if n64 {
            if s.faceA       { mask |= GBAInput.a.rawValue }
            if s.faceX       { mask |= GBAInput.b.rawValue }
            if s.faceY       { mask |= GBAInput.cUp.rawValue }
            if s.faceB       { mask |= GBAInput.cDown.rawValue }
            if s.shoulderL   { mask |= GBAInput.l.rawValue }
            if s.shoulderR   { mask |= GBAInput.r.rawValue }
            if s.leftTrigger { mask |= GBAInput.l2.rawValue }
            if s.menu        { mask |= GBAInput.start.rawValue }
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

    /// Whether a connected controller can drive the game. The extended gamepad
    /// is the profile every full pad offers (Xbox, PlayStation, MFi, most
    /// Bluetooth pads) and the path this app was built on. A pad iOS offers
    /// WITHOUT it, such as the stick-less USB-C 8BitDo FlipPad, is still
    /// usable when its physical profile carries a d-pad and an A button, read
    /// by name (`ControllerInputSource.init(profile:)`). Before 2026-09-26
    /// such a pad was ignored in silence: no name in Settings, the touch
    /// controls left in place, while the other emulators on the same phone
    /// worked (support mail).
    static func isUsable(_ controller: GCController) -> Bool {
        if controller.extendedGamepad != nil { return true }
        let profile = controller.physicalInputProfile
        let hasDpad = profile.dpads[GCInputDirectionPad] != nil
            || profile.dpads[GCInputMicroGamepadDpad] != nil
        let hasA = profile.buttons[GCInputButtonA] != nil
            || profile.buttons[GCInputMicroGamepadButtonA] != nil
        return hasDpad && hasA
    }

    /// The controller's live state: through the extended gamepad when it has
    /// one (the historical path, unchanged), by element name otherwise.
    private static func snapshot(of controller: GCController) -> ControllerInputSource {
        if let pad = controller.extendedGamepad { return ControllerInputSource(pad) }
        return ControllerInputSource(profile: controller.physicalInputProfile)
    }

    /// Begin driving a player from `controller`: it becomes the next player,
    /// if it is usable (see `isUsable`), not already adopted, and a player is
    /// free. A controller turned away for lack of room is adopted later, when
    /// one leaves (`handleDisconnect`). The caller reports the roster change.
    @discardableResult
    private func adopt(_ controller: GCController) -> Bool {
        guard pads.count < Self.maxPlayers, Self.isUsable(controller),
              !hardware.values.contains(where: { $0 === controller }) else { return false }
        let id = UUID()
        hardware[id] = controller
        if let pad = controller.extendedGamepad {
            pad.valueChangedHandler = { [weak self] pad, _ in
                self?.handleInput(ControllerInputSource(pad), from: id)
            }
        } else {
            controller.physicalInputProfile.valueDidChangeHandler = { [weak self] profile, _ in
                self?.handleInput(ControllerInputSource(profile: profile), from: id)
            }
        }
        // The pause menu, from the buttons that are never game input: the
        // spare menu-ish button some pads carry beyond Start/Select, and the
        // Home button while a game claims it. Player 1's only; press only.
        let fireMenu: (GCControllerButtonInput, Float, Bool) -> Void = { [weak self] _, _, pressed in
            guard pressed, let self, self.pads.first?.id == id else { return }
            self.onMenuRequested?()
        }
        let pad = controller.extendedGamepad
        if let ds4 = pad as? GCDualShockGamepad {
            ds4.touchpadButton.pressedChangedHandler = fireMenu
        } else if let dualSense = pad as? GCDualSenseGamepad {
            dualSense.touchpadButton.pressedChangedHandler = fireMenu
        } else if let xbox = pad as? GCXboxGamepad {
            xbox.buttonShare?.pressedChangedHandler = fireMenu
        }
        homeButton(of: controller)?.pressedChangedHandler = { [weak self] button, value, pressed in
            // Only while claimed: otherwise the press is iOS's, and acting on
            // it as well would open a menu behind whatever iOS shows.
            guard self?.claimsSystemButtons == true else { return }
            fireMenu(button, value, pressed)
        }
        applySystemButtonClaim(to: controller)
        pads.append(Pad(id: id,
                        name: controller.vendorName,
                        style: ControllerStyle.from(productCategory: controller.productCategory),
                        batteryLevel: Self.batteryLevel(of: controller)))
        Analytics.signalOnce("controller_connected")
        return true
    }

    /// The controller's Home button, when it has one iOS lets an app see.
    private func homeButton(of controller: GCController) -> GCControllerButtonInput? {
        controller.physicalInputProfile.buttons[GCInputButtonHome]
    }

    /// Ask iOS to leave these buttons' presses to the game while it claims
    /// them, and give them back otherwise.
    ///
    /// iOS puts its own gesture on a pad's Share button: a press takes a
    /// screenshot, a hold records the screen. On a PlayStation pad that button
    /// is the one the app reads as SELECT (`buttonOptions`), so without this
    /// every Select in a game, and the Start+Select hold that opens the pause
    /// menu, also reached iOS, which started recording (device report with a
    /// DualShock 4, 2026-09-27). The Xbox Share button (the menu's) and Home
    /// are claimed for the same reason. A request, not a guarantee: a pad whose
    /// Home press iOS keeps still opens the menu with Start+Select.
    private func applySystemButtonClaim(to controller: GCController) {
        let state: GCControllerElement.SystemGestureState = claimsSystemButtons ? .disabled : .enabled
        let buttons = controller.physicalInputProfile.buttons
        for name in [GCInputButtonHome, GCInputButtonOptions, GCInputButtonShare] {
            buttons[name]?.preferredSystemGestureState = state
        }
        // And by the very element read as SELECT, whatever name the profile
        // files it under on a given pad.
        controller.extendedGamepad?.buttonOptions?.preferredSystemGestureState = state
    }

    /// One input change from a controller, whichever profile it came through:
    /// remap capture (player 1), then the player's game mask and sticks, and,
    /// for player 1, the back role, the shortcut verbs and the menu hold.
    private func handleInput(_ snapshot: ControllerInputSource, from id: UUID) {
        guard let player = pads.firstIndex(where: { $0.id == id }) else { return }
        let isPlayerOne = (player == 0)
        // Remap capture and the verbs bound to pad buttons listen to the first
        // game controller, which is player 1's unless player 1 is the keyboard.
        let isFirstGamepad = (id == firstGamepad?.id)

        let previous = activitySnapshots[id]
        activitySnapshots[id] = snapshot
        if Self.hasFreshPress(snapshot, since: previous) { padActivity.send(id) }

        // Remap capture: report the first NEWLY pressed mappable button on
        // player 1's pad and swallow the event (no game input while
        // assigning). The other pads are silent meanwhile.
        if let capture = captureHandler {
            guard isFirstGamepad else { return }
            let previous = lastSnapshot
            lastSnapshot = snapshot
            if let pressed = snapshot.pressedButtons.first(where: { previous?.isPressed($0) != true }) {
                capture(pressed)
            }
            return
        }
        padMasks[id] = ControllerManager.buttonMask(from: snapshot,
                                                    mapping: activeMapping,
                                                    system: activeSystem)
        padSticks[id] = Sticks(leftX: snapshot.leftStickX, leftY: snapshot.leftStickY,
                               rightX: snapshot.rightStickX, rightY: snapshot.rightStickY)
        if isFirstGamepad, let mapping = activeMapping, !mapping.actions.isEmpty {
            // Shortcut verbs (wave 2): edge-detect each bound action.
            for (action, physical) in mapping.actions {
                let pressed = snapshot.isPressed(physical)
                if (actionStates[action] ?? false) != pressed {
                    actionStates[action] = pressed
                    onActionChanged?(action, pressed)
                }
            }
        }
        if isPlayerOne { applyPlayerOneRoles(snapshot) }
        emitButtons(player: player)
        emitSticks(player: player)
    }

    /// What player 1 alone does, whatever it is (a pad, or the keyboard read
    /// as the pad its mapping makes of it): "back" on the east button, the
    /// pause menu on Start+Select held, and moving around the app.
    private func applyPlayerOneRoles(_ snapshot: ControllerInputSource) {
        // The "back" role (east button), edge-detected on fresh presses.
        if snapshot.faceB != lastBackPressed {
            lastBackPressed = snapshot.faceB
            if snapshot.faceB { onBackRequested?() }
        }
        updateMenuHold(Self.isMenuCombo(snapshot))
        emitNavigation(snapshot)
    }

    /// Player 1's previous snapshot, for the navigation edges.
    private var lastNavigationSnapshot: ControllerInputSource?

    /// Player 1 moves around the app (`ControllerNavigator`): each change of a
    /// direction (the D-pad or the left stick), and each fresh press of A, B,
    /// L or R. Sent during a game as well; the navigator ignores them while
    /// the game owns the input.
    private func emitNavigation(_ s: ControllerInputSource) {
        let was = lastNavigationSnapshot ?? ControllerInputSource()
        lastNavigationSnapshot = s
        let navigator = ControllerNavigator.shared
        let directions: [(ControllerNavigator.Direction, Bool, Bool)] = [
            (.up, s.up, was.up), (.down, s.down, was.down),
            (.left, s.left, was.left), (.right, s.right, was.right),
        ]
        for (direction, now, before) in directions where now != before {
            navigator.handle(.direction(direction, pressed: now))
        }
        if s.faceA && !was.faceA { navigator.handle(.activate) }
        if s.faceB && !was.faceB { navigator.handle(.back) }
        if s.shoulderL && !was.shoulderL { navigator.handle(.tab(-1)) }
        if s.shoulderR && !was.shoulderR { navigator.handle(.tab(1)) }
    }

    /// Start and Select, the pair every pad can press. Select is Options, or
    /// the left stick click on a pad without Options, as in `buttonMask`.
    static func isMenuCombo(_ s: ControllerInputSource) -> Bool {
        s.menu && (s.options || (!s.hasOptions && s.leftStickClick))
    }

    /// Open the pause menu once Start+Select has been held for
    /// `menuHoldDuration`; letting go of either before that cancels it. The
    /// presses also reach the game meanwhile, as any press does.
    private func updateMenuHold(_ held: Bool) {
        guard held != menuComboHeld else { return }
        menuComboHeld = held
        menuHoldWork?.cancel()
        menuHoldWork = nil
        guard held else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.menuComboHeld else { return }
            self.menuHoldWork = nil
            self.onMenuRequested?()
        }
        menuHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.menuHoldDuration, execute: work)
    }

    /// Whether `now` presses a button or a direction that `before` did not.
    static func hasFreshPress(_ now: ControllerInputSource, since before: ControllerInputSource?) -> Bool {
        let was = before ?? ControllerInputSource()
        if now.pressedButtons.contains(where: { !was.isPressed($0) }) { return true }
        return (now.up && !was.up) || (now.down && !was.down)
            || (now.left && !was.left) || (now.right && !was.right)
    }

    // MARK: - Players

    /// Move a controller to another player number (0-based), shifting the
    /// ones in between. Settings' reorder. Every player's state follows its
    /// controller, so nothing is left held on the port it left.
    func movePad(_ id: UUID, toPlayer index: Int) {
        guard let from = pads.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), pads.count - 1)
        guard from != to else { return }
        let previousPlayerOne = pads.first?.id
        let previousGamepad = firstGamepad?.id
        let pad = pads.remove(at: from)
        pads.insert(pad, at: to)
        if pads.first?.id != previousPlayerOne || firstGamepad?.id != previousGamepad { playerOneChanged() }
        rosterChanged(previousCount: pads.count)
    }

    /// Player 1 (or the first game controller) is a different controller now
    /// (moved, or the old one left): release what the app's own roles were
    /// holding on the old one.
    private func playerOneChanged() {
        for (action, pressed) in actionStates where pressed {
            onActionChanged?(action, false)
        }
        actionStates = [:]
        lastBackPressed = false
        // Release any direction the old player 1 held, or the navigator would
        // keep repeating it.
        if lastNavigationSnapshot != nil { emitNavigation(ControllerInputSource()) }
        lastNavigationSnapshot = nil
        updateMenuHold(false)
        if captureHandler != nil {
            lastSnapshot = captureController.map { Self.snapshot(of: $0) }
        }
    }

    /// After any change to `pads`: number the pads' lights, report every
    /// player's state under its new controller (or released, for a player
    /// whose controller left), and tell the listeners.
    private func rosterChanged(previousCount: Int) {
        for (index, pad) in pads.enumerated() {
            hardware[pad.id]?.playerIndex = GCControllerPlayerIndex(rawValue: index) ?? .indexUnset
        }
        for player in 0..<activePlayerCount {
            emitButtons(player: player)
            // Sticks only for a player who has, or just had, a controller: a
            // stick report switches a PlayStation port to a DualShock, which
            // must stay the result of a real pad, never of a touch player's
            // roster event.
            if player < max(pads.count, previousCount) { emitSticks(player: player) }
        }
        if pads.contains(where: { !$0.isSimulated }) {
            startBatteryPolling()
        } else {
            stopBatteryPolling()
        }
        onPlayersChanged?(pads.count)
    }

    // MARK: - Emission

    /// A player's mask: its controller's (the keyboard's, for the keyboard's
    /// player). Where the keyboard is not a player (an iPad, or a phone whose
    /// four players are all taken), player 1's is OR-ed with the keyboard's,
    /// so a key is never lost.
    private func mask(forPlayer player: Int) -> UInt32 {
        var mask: UInt32 = 0
        if player < pads.count {
            let pad = pads[player]
            mask = pad.kind == .keyboard ? keyboardMask : (padMasks[pad.id] ?? 0)
        }
        if player == 0, keyboardPadID == nil { mask |= keyboardMask }
        return mask
    }

    private func emitButtons(player: Int) {
        guard player < activePlayerCount else { return }
        onButtonsChanged?(player, mask(forPlayer: player))
    }

    private func emitSticks(player: Int) {
        guard player < activePlayerCount else { return }
        // A keyboard has no stick, and a stick report switches a PlayStation
        // port to a DualShock: never on the keyboard's behalf.
        if player < pads.count, pads[player].kind == .keyboard { return }
        let sticks = player < pads.count ? (padSticks[pads[player].id] ?? Sticks()) : Sticks()
        onSticksChanged?(player, sticks.leftX, sticks.leftY, sticks.rightX, sticks.rightY)
    }

    // MARK: - Battery

    private static func batteryLevel(of controller: GCController) -> Double? {
        guard let battery = controller.battery, battery.batteryState != .unknown else { return nil }
        return Double(battery.batteryLevel)
    }

    private func readBatteries() {
        for index in pads.indices {
            guard let controller = hardware[pads[index].id] else { continue }
            let level = Self.batteryLevel(of: controller)
            if pads[index].batteryLevel != level { pads[index].batteryLevel = level }
        }
    }

    private func startBatteryPolling() {
        readBatteries()
        guard batteryTimer == nil else { return }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.readBatteries()
        }
    }

    private func stopBatteryPolling() {
        batteryTimer?.invalidate()
        batteryTimer = nil
    }

    @objc private func handleConnect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        let previousCount = pads.count
        // adopt() turns a controller away when every player is taken; it is
        // adopted when one of them leaves.
        if adopt(controller) { rosterChanged(previousCount: previousCount) }
    }

    @objc private func handleDisconnect(_ note: Notification) {
        guard let controller = note.object as? GCController,
              let id = hardware.first(where: { $0.value === controller })?.key else { return }
        removePad(id)
    }

    /// Take a controller out of the roster; the ones after it move up a
    /// player, and a controller waiting for a free player is adopted.
    private func removePad(_ id: UUID) {
        guard let index = pads.firstIndex(where: { $0.id == id }) else { return }
        let previousCount = pads.count
        let previousGamepad = firstGamepad?.id
        let wasKeyboard = (id == keyboardPadID)
        pads.remove(at: index)
        if wasKeyboard { keyboardPadID = nil }
        hardware[id]?.playerIndex = .indexUnset
        hardware[id] = nil
        padMasks[id] = nil
        padSticks[id] = nil
        activitySnapshots[id] = nil
        // Release any held shortcut verb (a stuck hold-to-fast-forward would
        // outlive the pad otherwise).
        if index == 0 || firstGamepad?.id != previousGamepad { playerOneChanged() }
        // A controller that found every player taken gets the free place, and
        // so does a keyboard that did.
        for waiting in GCController.controllers() where pads.count < Self.maxPlayers {
            adopt(waiting)
        }
        if !wasKeyboard, isKeyboardAttached { addKeyboardPlayer() }
        rosterChanged(previousCount: previousCount)
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
            DispatchQueue.main.async { self.keyboardInputChanged() }
        }
    }

    /// Make the keyboard a player, after the ones already there, where it is
    /// one (`keyboardIsAPlayer`) and a player is free. True when it became one.
    @discardableResult
    private func addKeyboardPlayer() -> Bool {
        guard Self.keyboardIsAPlayer, keyboardPadID == nil, pads.count < Self.maxPlayers else { return false }
        let id = UUID()
        keyboardPadID = id
        pads.append(Pad(id: id,
                        name: NSLocalizedString("controllers.keyboard", comment: ""),
                        style: .generic,
                        batteryLevel: nil,
                        kind: .keyboard))
        return true
    }

    /// The keyboard's mask changed: report its player (player 1 on an iPad,
    /// where it is folded in), and when it IS player 1, what player 1 alone
    /// does, read from the pad its mapping makes of it.
    private func keyboardInputChanged() {
        let fresh = keyboardMask & ~lastKeyboardMask
        lastKeyboardMask = keyboardMask
        guard let id = keyboardPadID, let player = pads.firstIndex(where: { $0.id == id }) else {
            emitButtons(player: 0)
            return
        }
        if fresh != 0 { padActivity.send(id) }
        if player == 0 { applyPlayerOneRoles(Self.snapshot(fromMask: keyboardMask)) }
        emitButtons(player: player)
    }

    /// The pad a GBAInput mask describes, for the roles player 1 plays with
    /// the keyboard: its directions, A, B, L, R, Start and Select (the
    /// keyboard's own Select, so "has Options" is true).
    static func snapshot(fromMask mask: UInt32) -> ControllerInputSource {
        func on(_ input: GBAInput) -> Bool { mask & input.rawValue != 0 }
        var s = ControllerInputSource()
        s.up = on(.up); s.down = on(.down); s.left = on(.left); s.right = on(.right)
        s.padUp = s.up; s.padDown = s.down; s.padLeft = s.left; s.padRight = s.right
        s.faceA = on(.a)
        s.faceB = on(.b)
        s.shoulderL = on(.l)
        s.shoulderR = on(.r)
        s.menu = on(.start)
        s.options = on(.select)
        s.hasOptions = true
        return s
    }

    @objc private func handleKeyboardConnect(_ note: Notification) {
        if let keyboard = GCKeyboard.coalesced { adoptKeyboard(keyboard) }
        isKeyboardAttached = GCKeyboard.coalesced != nil
        let before = pads.count
        if isKeyboardAttached, addKeyboardPlayer() { rosterChanged(previousCount: before) }
        updateTouchControlsMode()
        onKeyboardChanged?()
    }

    @objc private func handleKeyboardDisconnect(_ note: Notification) {
        detachKeyboard(stillAttached: GCKeyboard.coalesced != nil)
    }

    /// The keyboard left (or, in DEBUG, a fake one is taken away): release
    /// its keys, and its player when it had one.
    private func detachKeyboard(stillAttached: Bool) {
        keyboardMask = 0
        lastKeyboardMask = 0
        isKeyboardAttached = stillAttached
        if !stillAttached, let id = keyboardPadID {
            removePad(id)
        } else {
            emitButtons(player: 0)
        }
        updateTouchControlsMode()
        onKeyboardChanged?()
    }

    #if DEBUG
    /// Debug-only: simulate `count` connected controllers (0 to
    /// `maxPlayers`, real pads and a keyboard player included), so the
    /// several-controller surfaces (the library badge, the Settings players
    /// list and its reorder, the hidden touch controls) can be reviewed
    /// without the hardware. The stand-ins follow the others in player order,
    /// carry distinct batteries so each chip reads differently, and send no
    /// input of their own (tests send it with `debugSendInput`). Real pads
    /// connecting or leaving keep working alongside them.
    func debugSetSimulatedControllers(_ count: Int) {
        let previousCount = pads.count
        let hadPlayerOne = pads.first?.id
        let hadGamepad = firstGamepad?.id
        pads.removeAll { $0.isSimulated }
        let batteries: [Double?] = [0.73, 0.41, 0.96, 0.18]
        var number = 1
        while pads.count < min(max(count, 0), Self.maxPlayers) {
            pads.append(Pad(id: UUID(),
                            name: "Debug Controller \(number)",
                            style: .generic,
                            batteryLevel: batteries[(number - 1) % batteries.count],
                            isSimulated: true))
            number += 1
        }
        if pads.first?.id != hadPlayerOne || firstGamepad?.id != hadGamepad { playerOneChanged() }
        rosterChanged(previousCount: previousCount)
    }

    /// Debug-only: fake an attached keyboard so the keyboard remap row and
    /// page, the keyboard's player on a phone, and the phone-only hiding of the
    /// touch controls can be reviewed without pairing one. Capture still waits
    /// for a REAL key, since there is none to fake; a real keyboard connecting
    /// or leaving overrides this.
    func debugSetKeyboardAttached(_ attached: Bool) {
        if attached {
            isKeyboardAttached = true
            let before = pads.count
            if addKeyboardPlayer() { rosterChanged(previousCount: before) }
            updateTouchControlsMode()
            onKeyboardChanged?()
        } else {
            detachKeyboard(stillAttached: false)
        }
    }

    /// Debug-only (tests): one input change from the pad at `id`, exactly as
    /// its hardware would deliver it, for the simulated pads.
    func debugSendInput(_ snapshot: ControllerInputSource, fromPad id: UUID) {
        handleInput(snapshot, from: id)
    }

    /// Debug-only (tests): the keyboard's keys, as the GBAInput mask its
    /// mapping would produce.
    func debugSendKeyboardMask(_ mask: UInt32) {
        keyboardMask = mask
        keyboardInputChanged()
    }
    #endif
}
