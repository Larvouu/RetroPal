//
//  TouchControlsView.swift
//  EmulateurGBA
//
//  Touch input overlay with D-pad, A/B, L/R, Start/Select.
//  Tracks multi-touch to support simultaneous button presses
//  and diagonal D-pad input. Reports a GBAButton bitmask.
//

import UIKit

// Button bitmask values (matches GBAButton + NDS X/Y extensions)
enum GBAInput: UInt32 {
    case a      = 0x001  // 1 << 0
    case b      = 0x002  // 1 << 1
    case select = 0x004  // 1 << 2
    case start  = 0x008  // 1 << 3
    case right  = 0x010  // 1 << 4
    case left   = 0x020  // 1 << 5
    case up     = 0x040  // 1 << 6
    case down   = 0x080  // 1 << 7
    case r      = 0x100  // 1 << 8
    case l      = 0x200  // 1 << 9
    case x      = 0x400  // 1 << 10 (NDS)
    case y      = 0x800  // 1 << 11 (NDS)
}

protocol TouchControlsDelegate: AnyObject {
    func touchControlsDidChange(buttons: UInt32)
    func touchControlsMicBlowStateChanged(active: Bool)
}

extension TouchControlsDelegate {
    func touchControlsMicBlowStateChanged(active: Bool) {}
}

class TouchControlsView: UIView {
    weak var delegate: TouchControlsDelegate?

    // Last delegate-visible button state (raw touch ∪ lockedButtons)
    private var activeButtons: UInt32 = 0
    // Last raw touch-only state, used to detect new *physical* presses for haptics
    private var lastRawButtons: UInt32 = 0

    /// Buttons currently locked in pressed-state via the long-press gesture.
    /// Cleared automatically when the view is deallocated (game switch / quit).
    fileprivate var lockedButtons: UInt32 = 0

    /// Buttons eligible for long-press lock. GBA: A, B. NDS subclass widens to A, B, X, Y.
    var lockableMask: UInt32 { GBAInput.a.rawValue | GBAInput.b.rawValue }

    /// Whether the hold-to-lock gesture is active. Set PER-GAME by the emulator
    /// VC (off by default) — it's an assist for hold-heavy games and noise in
    /// most others. Turning it off clears any active lock so the player is never
    /// left with a stuck button.
    var buttonLockEnabled = false {
        didSet {
            guard oldValue != buttonLockEnabled, !buttonLockEnabled else { return }
            clearAllLocks()
        }
    }

    /// True while a game controller is connected. When set, the on-screen game
    /// controls are hidden and touch input is ignored — but the Menu button
    /// stays visible and tappable, so the player can always reach the pause
    /// overlay (save, quit, Pro). The pre-controller `isHidden` state of each
    /// game control is captured so a custom layout's hidden buttons restore
    /// correctly when the controller disconnects.
    var controllerModeActive = false {
        didSet {
            guard oldValue != controllerModeActive else { return }
            applyControllerMode()
        }
    }
    private var preControllerHidden: [ObjectIdentifier: Bool] = [:]

    // Long-press lock gesture state
    private struct PendingLock {
        let view: UIView
        let buttonMask: UInt32
        let startTime: CFTimeInterval
        let startLocation: CGPoint
        let ringLayer: CAShapeLayer
    }
    private struct UnlockCandidate {
        let buttonMask: UInt32
        let startTime: CFTimeInterval
        let startLocation: CGPoint
    }
    private var pendingLocks: [ObjectIdentifier: PendingLock] = [:]
    private var unlockCandidates: [ObjectIdentifier: UnlockCandidate] = [:]
    private var lockDisplayLink: CADisplayLink?
    private var lockDisplayProxy: LockDisplayProxy?

    private static let lockHoldDuration: CFTimeInterval = 1.0
    // White stroke + soft dark shadow — matches the rest of the control palette
    // and reads cleanly without drawing as much attention as the brand gold did.
    private static let lockRingColor = UIColor.white.withAlphaComponent(0.6)
    private static let unlockMaxDuration: CFTimeInterval = 0.5
    private static let unlockMaxDisplacement: CGFloat = 10

    // Haptic feedback — game-button taps honor the Settings strength (1-6).
    /// Level → (style, intensity) map. Level 3 IS the historical feel (.light at
    /// full intensity, the pre-1.2.4 constant); lower levels soften through
    /// .soft, higher move through .medium to .heavy. Perceptual spacing owes a
    /// device pass.
    static let hapticLevels: [(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat)] = [
        (.soft, 0.5), (.soft, 0.8), (.light, 1.0), (.medium, 0.8), (.medium, 1.0), (.heavy, 1.0)
    ]
    private var hapticGenerator = UIImpactFeedbackGenerator(style: .light)
    private var hapticGeneratorLevel = 3

    /// One-off haptic at `level` — the Settings strength picker answers each
    /// selection with the strength it just picked, so choosing is by feel.
    static func previewHaptic(level: Int) {
        let map = hapticLevels[min(max(level, 1), 6) - 1]
        UIImpactFeedbackGenerator(style: map.style).impactOccurred(intensity: map.intensity)
    }

    // Button views (internal for subclass access)
    private(set) var dpad: UIView  // Either DPadView (joystick) or CrossDPadView (d-pad)
    private var joystickDPad: DPadView?
    private var crossDPad: CrossDPadView?
    let btnA = ActionButton(label: "A")
    let btnB = ActionButton(label: "B")
    let btnL = ShoulderButton(label: "L")
    let btnR = ShoulderButton(label: "R")
    let btnStart = SmallButton(label: "START")
    let btnSelect = SmallButton(label: "SELECT")
    let btnMenu = SmallButton(systemImage: "gearshape.fill")
    let btnClip = SmallButton(systemImage: "film.fill")

    // Map each button view to its bitmask
    private(set) var buttonMap: [(UIView, UInt32)] = []

    var onMenuTap: (() -> Void)?
    /// Fired when the in-game clip button is tapped. An action trigger like the
    /// Menu (not a game input); the pad's claimed finger is excluded the same way.
    var onClipTap: (() -> Void)?

    /// Subclass sets this to enable a mic/blow button (NDS only)
    var micButton: UIView?
    private var micActive = false

    /// Subclasses call this to register additional button→bitmask mappings.
    func addNDSButtonMappings(_ mappings: [(UIView, UInt32)]) {
        buttonMap.append(contentsOf: mappings)
    }

    // Track which touch is on the joystick for visual thumb feedback
    private var dpadTouch: UITouch?

    /// Small translucent puck that follows the steering finger while the pad is
    /// held, so the player can see the touch is still active even after the
    /// finger has left the pad. Parented to the controls view's SUPERVIEW so the
    /// controls' own clipping (NDS portrait) never cuts it off.
    private lazy var fingerDot: UIView = {
        let size: CGFloat = 18
        let v = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        v.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        v.layer.cornerRadius = size / 2
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        v.layer.borderWidth = 1.5
        v.isUserInteractionEnabled = false
        v.isHidden = true
        return v
    }()

    /// The global (no-preset) control opacity and scale from Settings, with the
    /// historical fallbacks (opacity 0.5, size 1.0) applied when unset.
    static func globalOpacityScale() -> (opacity: CGFloat, scale: CGFloat) {
        let opacity = UserDefaults.standard.double(forKey: "controlOpacity")
        let scale = UserDefaults.standard.double(forKey: "controlScale")
        return (opacity > 0 ? opacity : 0.5, scale > 0 ? scale : 1.0)
    }

    override init(frame: CGRect) {
        let useCross = !UserDefaults.standard.bool(forKey: "useJoystick")
        if useCross {
            let cross = CrossDPadView()
            dpad = cross
            crossDPad = cross
        } else {
            let joy = DPadView()
            dpad = joy
            joystickDPad = joy
        }
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        let useCross = !UserDefaults.standard.bool(forKey: "useJoystick")
        if useCross {
            let cross = CrossDPadView()
            dpad = cross
            crossDPad = cross
        } else {
            let joy = DPadView()
            dpad = joy
            joystickDPad = joy
        }
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        for v in [dpad, btnA, btnB, btnL, btnR, btnStart, btnSelect, btnMenu, btnClip] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false // We handle touches at this level
            addSubview(v)
        }

        // Accessibility labels
        dpad.accessibilityLabel = "Directional pad"
        btnA.accessibilityLabel = "A button"
        btnB.accessibilityLabel = "B button"
        btnL.accessibilityLabel = "L shoulder button"
        btnR.accessibilityLabel = "R shoulder button"
        btnStart.accessibilityLabel = "Start button"
        btnSelect.accessibilityLabel = "Select button"
        btnMenu.accessibilityLabel = "Pause menu"
        btnClip.accessibilityLabel = "Share clip"

        buttonMap = [
            (btnA, GBAInput.a.rawValue),
            (btnB, GBAInput.b.rawValue),
            (btnL, GBAInput.l.rawValue),
            (btnR, GBAInput.r.rawValue),
            (btnStart, GBAInput.start.rawValue),
            (btnSelect, GBAInput.select.rawValue),
        ]
    }

    // MARK: - Custom Layout Support

    /// Maps ControlElement to the corresponding button view. Subclasses override to add NDS buttons.
    func allButtonViews() -> [(ControlElement, UIView)] {
        [(.dpad, dpad), (.btnA, btnA), (.btnB, btnB), (.btnL, btnL),
         (.btnR, btnR), (.btnStart, btnStart), (.btnSelect, btnSelect), (.btnMenu, btnMenu),
         (.btnClip, btnClip)]
    }

    /// Frames of the currently-visible control buttons, in `target`'s coordinate space.
    /// The console dress reads these to place decorations (and button wells) without
    /// overlapping the controls. Call after layout so the frames are resolved.
    func visibleButtonFrames(in target: UIView) -> [ControlElement: CGRect] {
        var result: [ControlElement: CGRect] = [:]
        for (element, v) in allButtonViews() where !v.isHidden {
            result[element] = target.convert(v.bounds, from: v)
        }
        return result
    }

    /// Frames of ALL control buttons, including the ones hidden by controller mode (they are still
    /// laid out at their normal positions). The console dress reads these so a decoration can anchor
    /// to a hidden button (e.g. the GBA brand to the hidden Clip) when a controller is connected.
    func allButtonFrames(in target: UIView) -> [ControlElement: CGRect] {
        var result: [ControlElement: CGRect] = [:]
        for (element, v) in allButtonViews() {
            result[element] = target.convert(v.bounds, from: v)
        }
        return result
    }

    /// Toggle the GB/GBC console-dress look on the buttons (maroon A/B, grey pills, charcoal
    /// cross). The host calls this for the GB/GBC built-in default layout — matching the
    /// console skin's visibility — so any custom preset or other system keeps the default
    /// translucent-white look. Re-applied each layout pass, so a D-pad swap stays in sync.
    private(set) var dressed = false
    /// The dressed palette variant in force (Nostalgia or the Retro Pal recolour). The NDS
    /// override reads this to dress its extra buttons with the same variant.
    private(set) var dressVariant: DressVariant = .nostalgia
    func setDressed(_ on: Bool, isLandscape: Bool, system: PresetSystem,
                    variant: DressVariant = .nostalgia) {
        dressed = on
        dressVariant = variant
        // GB/GBC wear the DMG palette; GBA + NDS recolor the same shapes to their own palettes.
        let kind: DressKind = (system == .gba) ? .gba : (system == .nds) ? .nds : .gbc
        btnA.dressVariant = variant; btnA.dressKind = kind; btnA.dressed = on
        btnB.dressVariant = variant; btnB.dressKind = kind; btnB.dressed = on
        // L/R shoulders (GBA + NDS — GB/GBC has none; theirs stay hidden so this is a no-op there).
        btnL.dressVariant = variant; btnL.dressKind = kind; btnL.dressed = on
        btnR.dressVariant = variant; btnR.dressKind = kind; btnR.dressed = on
        // SELECT/START: a diagonal pill in portrait, a horizontal top-stuck pill in landscape.
        let pillStyle: SmallButton.DressStyle = isLandscape ? .pillTop : .pill
        btnStart.dressVariant = variant; btnStart.dressKind = kind; btnStart.dressStyle = on ? pillStyle : .none
        btnSelect.dressVariant = variant; btnSelect.dressKind = kind; btnSelect.dressStyle = on ? pillStyle : .none
        // MENU + CLIP both wear the round-backed .circle dress in BOTH orientations, for BOTH
        // consoles (GB/GBC mirrors the GBA "real button" render; Clip keeps its film icon).
        btnClip.dressVariant = variant; btnClip.dressKind = kind
        btnMenu.dressVariant = variant; btnMenu.dressKind = kind
        btnClip.dressStyle = on ? .circle : .none
        btnMenu.dressStyle = on ? .circle : .none
        crossDPad?.dressVariant = variant; crossDPad?.dressKind = kind; crossDPad?.dressed = on
        joystickDPad?.dressVariant = variant; joystickDPad?.dressKind = kind; joystickDPad?.dressed = on
    }

    /// Lay out every control from a resolved layout (normalized 0–1 positions),
    /// device-scaling each button's size and applying the given opacity/scale.
    /// This is the single apply path for BOTH the built-in default and custom
    /// presets — the caller decides which `layout`/`opacity`/`scale` to pass.
    func applyLayout(_ layout: OrientationLayout, isLandscape: Bool, isNDS: Bool,
                     deviceScale: CGFloat, opacity: CGFloat, scale: CGFloat, useJoystick: Bool,
                     wideSelectStart: Bool = false, wideShoulders: Bool = false,
                     ndsBigSelectStart: Bool = false) {
        // Resolve the directional control type (cross D-pad vs joystick) for this
        // layout first, so the swapped-in view gets positioned in the pass below.
        setUsesJoystick(useJoystick)

        NSLayoutConstraint.deactivate(constraints.filter { $0.firstItem is UIView })
        removeAllSubviewConstraints()

        // NDS landscape lets the L/R bars extend up into the screen area; every
        // other case keeps controls inside their own bounds.
        clipsToBounds = isNDS && !isLandscape

        let containerW = bounds.width
        let containerH = bounds.height
        guard containerW > 0 && containerH > 0 else { return }

        let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
        let effectiveAlpha = opacity * 2.0

        for (element, view) in allButtonViews() {
            guard let bl = layout.buttons[element.rawValue] else {
                view.isHidden = true
                continue
            }

            // Menu can never be hidden. Other controls are also hidden while a
            // controller is connected, so a re-layout keeps them hidden.
            view.isHidden = (element != .btnMenu) && (bl.isHidden || controllerModeActive)

            let baseSize = EmulatorLayoutGeometry.buttonSize(
                element, isNDS: isNDS, isLandscape: isLandscape, deviceScale: deviceScale)

            // NDS landscape: keep the L/R bars in the gutter beside the screens and
            // lift Mic clear of the bottom row (the iPhone-SE overlaps). No-op on
            // devices that don't need it, like the 14 Pro.
            let adj = EmulatorLayoutGeometry.ndsLandscapeAdjusted(
                element: element, isNDS: isNDS, isLandscape: isLandscape,
                center: CGPoint(x: containerW * bl.centerX, y: containerH * bl.centerY),
                size: baseSize, container: bounds.size, layout: layout, deviceScale: deviceScale)

            // GBA SELECT/START: 30% wider, extending OUTWARD (away from center) so the inner
            // edge (Select's right, Start's left) stays put and they don't collide in portrait.
            var finalSize = adj.size, finalCenter = adj.center
            if wideSelectStart, element == .btnSelect || element == .btnStart {
                let extra = adj.size.width * 0.3
                finalSize.width += extra
                finalCenter.x += (element == .btnSelect) ? -extra / 2 : extra / 2
            }
            // NDS portrait L/R: 40% wider, extending INWARD (toward center) so the exterior
            // edge (L's left, R's right) stays put.
            if wideShoulders, element == .btnL || element == .btnR {
                let extra = adj.size.width * 0.4
                finalSize.width += extra
                finalCenter.x += (element == .btnL) ? extra / 2 : -extra / 2
            }
            // NDS default: SELECT/START mirror the GBA component SIZE; CLIP/MIC reflow so every
            // gap in the bottom row stays the same. Portrait grows symmetric about centre;
            // landscape grows the SELECT·CLIP·START bloc leftward (its right end stays put).
            if ndsBigSelectStart {
                let k = deviceScale
                if element == .btnSelect || element == .btnStart {
                    let ref = isLandscape ? ControlElement.btnSelect.defaultLandscapeSize
                                          : ControlElement.btnSelect.defaultSize
                    finalSize = CGSize(width: ref.width * k, height: ref.height * k)
                }
                if isLandscape {
                    switch element {
                    case .btnSelect: finalCenter.x -= 6 * k
                    case .btnStart:  finalCenter.x -= 2 * k
                    case .btnClip:   finalCenter.x -= 4 * k
                    default: break
                    }
                } else {
                    switch element {
                    case .btnSelect: finalCenter.x -= 6 * k
                    case .btnStart:  finalCenter.x += 6 * k
                    case .btnClip:   finalCenter.x -= 12 * k
                    case .btnMic:    finalCenter.x += 12 * k
                    default: break
                    }
                }
            }

            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: leadingAnchor, constant: finalCenter.x),
                view.centerYAnchor.constraint(equalTo: topAnchor, constant: finalCenter.y),
                view.widthAnchor.constraint(equalToConstant: finalSize.width),
                view.heightAnchor.constraint(equalToConstant: finalSize.height),
            ])

            // Opacity + the user's size slider apply to ALL buttons (incl. NDS X/Y/Mic).
            view.transform = scaleTransform
            if let a = view as? ActionButton {
                a.baseTransform = scaleTransform
                if !a.isPressed { a.transform = a.restingTransform }   // GBA-dressed A/B rest at 98%
            }
            (view as? SmallButton)?.baseTransform = scaleTransform
            (view as? ShoulderButton)?.baseTransform = scaleTransform
            view.alpha = (element == .btnMenu) ? max(0.5, effectiveAlpha) : effectiveAlpha
        }
    }

    /// Lay out every control from a fully-resolved preset scene: absolute
    /// view-space centers with per-component size, scale, opacity, and
    /// visibility, straight from PresetLayoutResolver (the same source the
    /// editor renders from, so the two cannot drift). The controls view must be
    /// pinned to the FULL game view for these coordinates to apply 1:1 — the
    /// preset path does that; the built-in default keeps the legacy below-screen
    /// container and goes through applyDefaultLayout instead.
    func applyResolvedScene(buttons: [ControlElement: PresetLayoutResolver.ResolvedControl],
                            useJoystick: Bool) {
        setUsesJoystick(useJoystick)

        NSLayoutConstraint.deactivate(constraints.filter { $0.firstItem is UIView })
        removeAllSubviewConstraints()

        // Full-view container: components can live anywhere in it, nothing to clip.
        clipsToBounds = false

        for (element, view) in allButtonViews() {
            guard let rc = buttons[element] else {
                view.isHidden = true
                continue
            }

            // Menu can never be hidden (and survives controller mode); other
            // controls also hide while a controller is connected.
            view.isHidden = (element != .btnMenu) && (rc.isHidden || controllerModeActive)

            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: leadingAnchor, constant: rc.center.x),
                view.centerYAnchor.constraint(equalTo: topAnchor, constant: rc.center.y),
                view.widthAnchor.constraint(equalToConstant: rc.baseSize.width),
                view.heightAnchor.constraint(equalToConstant: rc.baseSize.height),
            ])

            // Per-component scale as a transform (like the legacy global slider),
            // so labels, borders, and corner radii scale with the shape.
            let scaleTransform = CGAffineTransform(scaleX: rc.scale, y: rc.scale)
            view.transform = scaleTransform
            if let a = view as? ActionButton {
                a.baseTransform = scaleTransform
                if !a.isPressed { a.transform = a.restingTransform }
            }
            (view as? SmallButton)?.baseTransform = scaleTransform
            (view as? ShoulderButton)?.baseTransform = scaleTransform
            view.alpha = rc.opacity
        }
    }

    /// Apply the built-in default layout for the current orientation/system, using
    /// the global (no-preset) opacity and scale. Reads the container from `bounds`,
    /// so the caller must size the view first.
    func applyDefaultLayout(isLandscape: Bool, system: PresetSystem, deviceScale: CGFloat,
                            safeLeftInset: CGFloat = 0) {
        let isNDS = (system == .nds)
        var layout = ControlLayoutDefaults.defaultLayout(
            system: system, isLandscape: isLandscape, containerSize: bounds.size,
            scale: deviceScale, safeLeftInset: safeLeftInset)
        let globals = Self.globalOpacityScale()
        // The built-in default layout uses the global Settings choices.
        let useJoystick = UserDefaults.standard.bool(forKey: "useJoystick")
        // Clip-button visibility: global toggle, default ON. Custom presets are
        // unaffected (each carries its own btnClip.isHidden, set in the editor).
        let showClip = UserDefaults.standard.object(forKey: "showClipButton") as? Bool ?? true
        if !showClip {
            layout.buttons[ControlElement.btnClip.rawValue]?.isHidden = true
        }
        applyLayout(layout, isLandscape: isLandscape, isNDS: isNDS,
                    deviceScale: deviceScale, opacity: globals.opacity, scale: globals.scale,
                    useJoystick: useJoystick, wideSelectStart: system == .gba,
                    wideShoulders: isNDS && !isLandscape, ndsBigSelectStart: isNDS)
    }

    /// Swap the directional control between the cross D-pad and the joystick to
    /// match the resolved per-preset (or default) choice. Rebuilds the dpad view
    /// only when the type actually changes; `applyLayout` then positions it. The
    /// dpad is not in `buttonMap` (its input is routed via joystickDPad/crossDPad
    /// + buttonsForPoint), so only the view + those refs need updating.
    private func setUsesJoystick(_ useJoystick: Bool) {
        let currentlyJoystick = joystickDPad != nil
        guard useJoystick != currentlyJoystick else { return }

        dpad.removeFromSuperview()
        joystickDPad = nil
        crossDPad = nil

        let newDpad: UIView
        if useJoystick {
            let joy = DPadView()
            joystickDPad = joy
            newDpad = joy
        } else {
            let cross = CrossDPadView()
            crossDPad = cross
            newDpad = cross
        }
        newDpad.translatesAutoresizingMaskIntoConstraints = false
        newDpad.isUserInteractionEnabled = false
        newDpad.accessibilityLabel = "Directional pad"
        addSubview(newDpad)
        dpad = newDpad
    }

    /// Apply (or undo) controller mode: every game control is hidden while a
    /// controller is connected; only the Menu button stays. The previous
    /// `isHidden` state is captured so custom-layout hidden buttons restore
    /// correctly on disconnect.
    private func applyControllerMode() {
        if controllerModeActive {
            preControllerHidden.removeAll()
            for (element, view) in allButtonViews() where element != .btnMenu {
                preControllerHidden[ObjectIdentifier(view)] = view.isHidden
                view.isHidden = true
            }
            lockedButtons = 0
            applyButtons(0)   // drop any current touch / lock state
        } else {
            for (element, view) in allButtonViews() where element != .btnMenu {
                view.isHidden = preControllerHidden[ObjectIdentifier(view)] ?? false
            }
            preControllerHidden.removeAll()
        }
    }

    // MARK: - Constraint cleanup

    func removeAllSubviewConstraints() {
        for constraint in constraints {
            removeConstraint(constraint)
        }
        // Also remove width/height constraints owned by subviews
        for sub in subviews {
            sub.removeConstraints(sub.constraints.filter {
                ($0.firstAttribute == .width || $0.firstAttribute == .height)
                && $0.secondItem == nil
            })
        }
    }

    // MARK: - Hit Testing (allow touches on subviews outside bounds, e.g. L/R in landscape)

    /// Preset mode: the controls view spans the WHOLE game view and sits above
    /// the screens, so it must claim ONLY the touches that land on a visible
    /// control and let everything else fall through to the NDS stylus overlay /
    /// screens below. Off (default layouts), the view claims its whole bounds
    /// as it always did. A touch that begins on a control stays routed to this
    /// view for its whole lifetime (UIKit semantics), so the sticky D-pad
    /// steering finger still works when dragged across a screen — and a stylus
    /// drag that begins on the touch screen never gets stolen by a button it
    /// crosses.
    var passThroughUnusedTouches = false

    /// Whether a touch at `point` (this view's coords) lands on a visible
    /// control, using the same forgiving hitboxes as the input layer
    /// (touchHits' 20% expansion / inscribed circles, the D-pad's -20pt claim,
    /// Menu/Clip's -10pt, Mic's 20%).
    private func controlClaims(_ point: CGPoint) -> Bool {
        if !dpad.isHidden, dpad.alpha > 0.01,
           dpad.bounds.insetBy(dx: -20, dy: -20).contains(convert(point, to: dpad)) {
            return true
        }
        for (view, _) in buttonMap where !view.isHidden && view.alpha > 0.01 {
            if touchHits(convert(point, to: view), in: view) { return true }
        }
        for trigger in [btnMenu, btnClip] where !trigger.isHidden && trigger.alpha > 0.01 {
            if trigger.bounds.insetBy(dx: -10, dy: -10).contains(convert(point, to: trigger)) {
                return true
            }
        }
        if let mic = micButton, !mic.isHidden, mic.alpha > 0.01 {
            let local = convert(point, to: mic)
            if mic.bounds.insetBy(dx: -mic.bounds.width * 0.2,
                                  dy: -mic.bounds.height * 0.2).contains(local) {
                return true
            }
        }
        return false
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if passThroughUnusedTouches && !controlClaims(point) { return nil }
        // First try the default hit test (within bounds)
        if let hit = super.hitTest(point, with: event) { return hit }
        // Then check subviews that are outside bounds (L/R buttons in landscape NDS)
        for sub in subviews.reversed() where !sub.isHidden && sub.alpha > 0.01 {
            let subPoint = sub.convert(point, from: self)
            if sub.bounds.contains(subPoint) { return self }
        }
        return nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if passThroughUnusedTouches { return controlClaims(point) }
        if super.point(inside: point, with: event) { return true }
        // Also accept points that land on out-of-bounds subviews
        for sub in subviews where !sub.isHidden && sub.alpha > 0.01 {
            let subPoint = sub.convert(point, from: self)
            if sub.bounds.contains(subPoint) { return true }
        }
        return false
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Track which touch is on the joystick for thumb visual
        for touch in touches {
            let local = convert(touch.location(in: self), to: dpad)
            if dpadTouch == nil && dpad.bounds.insetBy(dx: -20, dy: -20).contains(local) {
                dpadTouch = touch
            }
        }
        startLockTrackersIfNeeded(touches)
        updateButtons(for: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLockTrackersIfMoved(touches)
        updateButtons(for: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch === dpadTouch { dpadTouch = nil }
        }
        finishLockTrackers(touches)
        updateButtons(for: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch === dpadTouch { dpadTouch = nil }
        }
        cancelLockTrackers(touches)
        updateButtons(for: event)
    }

    // MARK: - Button-Lock Gesture (long-press to lock, tap to unlock)

    private func startLockTrackersIfNeeded(_ touches: Set<UITouch>) {
        // Respect the Settings → Controls toggle. Default ON (current behavior);
        // OFF disables the gesture entirely, matching pre-feature behavior.
        guard buttonLockEnabled else { return }
        let mask = lockableMask
        guard mask != 0 else { return }

        for touch in touches {
            let point = touch.location(in: self)
            // Find the lockable action button this touch began on (if any)
            for (view, buttonMask) in buttonMap where (buttonMask & mask) != 0 {
                let local = convert(point, to: view)
                guard touchHits(local, in: view) else { continue }

                let id = ObjectIdentifier(touch)
                let isLocked = (lockedButtons & buttonMask) != 0
                let now = CACurrentMediaTime()

                if isLocked {
                    // Candidate for tap-to-unlock on this touch's release.
                    unlockCandidates[id] = UnlockCandidate(
                        buttonMask: buttonMask, startTime: now, startLocation: point
                    )
                } else {
                    // Fresh long-press attempt: add a filling ring and start the display link.
                    let ring = makeLockRing(for: view)
                    view.layer.addSublayer(ring)
                    pendingLocks[id] = PendingLock(
                        view: view, buttonMask: buttonMask,
                        startTime: now, startLocation: point, ringLayer: ring
                    )
                    startLockDisplayLinkIfNeeded()
                }
                break // One tracker per touch
            }
        }
    }

    private func cancelLockTrackersIfMoved(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard let pending = pendingLocks[id] else { continue }
            let point = touch.location(in: self)
            let local = convert(point, to: pending.view)
            if !touchHits(local, in: pending.view) {
                fadeAndRemoveRing(pending.ringLayer)
                pendingLocks.removeValue(forKey: id)
            }
        }
        // Unlock-candidates aren't displacement-canceled mid-move; we re-check at touchesEnded.
    }

    private func finishLockTrackers(_ touches: Set<UITouch>) {
        let now = CACurrentMediaTime()
        for touch in touches {
            let id = ObjectIdentifier(touch)

            // Pending lock that ended before completing — cancel ring.
            if let pending = pendingLocks.removeValue(forKey: id) {
                fadeAndRemoveRing(pending.ringLayer)
            }

            // Tap-to-unlock evaluation
            if let candidate = unlockCandidates.removeValue(forKey: id) {
                let duration = now - candidate.startTime
                let endPoint = touch.location(in: self)
                let dx = endPoint.x - candidate.startLocation.x
                let dy = endPoint.y - candidate.startLocation.y
                let displacement = sqrt(dx * dx + dy * dy)
                if duration < Self.unlockMaxDuration && displacement < Self.unlockMaxDisplacement {
                    unlockButton(mask: candidate.buttonMask)
                }
            }
        }
        stopLockDisplayLinkIfIdle()
    }

    private func cancelLockTrackers(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if let pending = pendingLocks.removeValue(forKey: id) {
                fadeAndRemoveRing(pending.ringLayer)
            }
            unlockCandidates.removeValue(forKey: id)
        }
        stopLockDisplayLinkIfIdle()
    }

    private func makeLockRing(for view: UIView) -> CAShapeLayer {
        let ring = CAShapeLayer()
        let radius = min(view.bounds.width, view.bounds.height) / 2 + 3
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let path = UIBezierPath(
            arcCenter: center, radius: radius,
            startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2,
            clockwise: true
        )
        ring.path = path.cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = Self.lockRingColor.cgColor
        ring.lineWidth = 3
        ring.lineCap = .round
        ring.strokeEnd = 0
        ring.frame = view.bounds
        // Dark shadow gives the white stroke definition against any background.
        ring.shadowColor = UIColor.black.cgColor
        ring.shadowOpacity = 0.45
        ring.shadowRadius = 3
        ring.shadowOffset = .zero
        return ring
    }

    private func fadeAndRemoveRing(_ ring: CAShapeLayer) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = ring.presentation()?.opacity ?? 1.0
        fade.toValue = 0.0
        fade.duration = 0.15
        ring.add(fade, forKey: "fadeOut")
        ring.opacity = 0
        CATransaction.commit()
    }

    fileprivate func lockDisplayLinkTick() {
        guard !pendingLocks.isEmpty else {
            stopLockDisplayLinkIfIdle()
            return
        }
        let now = CACurrentMediaTime()
        var completedIds: [ObjectIdentifier] = []

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, pending) in pendingLocks {
            let elapsed = now - pending.startTime
            let progress = min(elapsed / Self.lockHoldDuration, 1.0)
            pending.ringLayer.strokeEnd = CGFloat(progress)
            if progress >= 1.0 {
                completedIds.append(id)
            }
        }
        CATransaction.commit()

        for id in completedIds {
            guard let pending = pendingLocks.removeValue(forKey: id) else { continue }
            activateLock(for: pending)
        }
        stopLockDisplayLinkIfIdle()
    }

    private func activateLock(for pending: PendingLock) {
        lockedButtons |= pending.buttonMask
        // Update glyph directly: applyButtons()'s guard may early-return when the
        // raw touch already pressed this button (augmented unchanged).
        (pending.view as? ActionButton)?.isLocked = true
        fireHaptic()
        fadeAndRemoveRing(pending.ringLayer)
        // Push augmented state to delegate immediately (in case raw touch matches it already).
        applyButtons(lastRawButtons)
    }

    private func unlockButton(mask: UInt32) {
        lockedButtons &= ~mask
        // Directly fade the glyph on the affected button(s) — applyButtons() will
        // catch the augmented state change for isPressed via updateButtons().
        for (view, buttonMask) in buttonMap where (buttonMask & mask) != 0 {
            (view as? ActionButton)?.isLocked = false
        }
        fireHaptic()
    }

    private func startLockDisplayLinkIfNeeded() {
        guard lockDisplayLink == nil else { return }
        let proxy = LockDisplayProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(LockDisplayProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        lockDisplayLink = link
        lockDisplayProxy = proxy
    }

    private func stopLockDisplayLinkIfIdle() {
        guard pendingLocks.isEmpty else { return }
        lockDisplayLink?.invalidate()
        lockDisplayLink = nil
        lockDisplayProxy = nil
    }

    private func clearAllLocks() {
        // Cancel in-flight ring animations and their trackers
        for (_, pending) in pendingLocks {
            fadeAndRemoveRing(pending.ringLayer)
        }
        pendingLocks.removeAll()
        unlockCandidates.removeAll()
        stopLockDisplayLinkIfIdle()

        // Clear locked-state + glyphs
        lockedButtons = 0
        for (view, _) in buttonMap {
            (view as? ActionButton)?.isLocked = false
        }
        // Force a state push so the emulator sees the released buttons.
        applyButtons(lastRawButtons)
    }

    deinit {
        lockDisplayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// Fire the game-button haptic at the Settings strength, if haptics are
    /// enabled. One chokepoint for every in-game haptic (button presses, the
    /// Menu/Clip triggers, hold-to-lock); the generator is rebuilt only when
    /// the strength level changed since the last fire.
    private func fireHaptic() {
        guard UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true else { return }
        let stored = UserDefaults.standard.object(forKey: "hapticStrength") as? Int ?? 3
        let level = min(max(stored, 1), 6)
        if level != hapticGeneratorLevel {
            hapticGeneratorLevel = level
            hapticGenerator = UIImpactFeedbackGenerator(style: Self.hapticLevels[level - 1].style)
        }
        hapticGenerator.impactOccurred(intensity: Self.hapticLevels[level - 1].intensity)
    }

    /// Whether a touch (in `view`'s coordinates) hits the button. Round (inscribed circle) for the
    /// face buttons flagged `roundHitbox` — so the NDS diamond's circles don't overlap like the
    /// square frames; a forgiving 20%-expanded rect for everything else.
    private func touchHits(_ local: CGPoint, in view: UIView) -> Bool {
        if let a = view as? ActionButton, a.roundHitbox {
            let r = min(view.bounds.width, view.bounds.height) / 2
            return hypot(local.x - view.bounds.midX, local.y - view.bounds.midY) <= r
        }
        return view.bounds.insetBy(dx: -view.bounds.width * 0.2, dy: -view.bounds.height * 0.2).contains(local)
    }

    private func updateButtons(for event: UIEvent?) {
        var buttons: UInt32 = 0

        guard let allTouches = event?.allTouches else {
            applyButtons(0)
            updateDpadTrackerDot(at: nil)
            return
        }

        // Sticky directional input: once a finger is claimed by the pad (in
        // touchesBegan) it keeps steering from its LIVE position relative to the
        // pad center until released, even after leaving the pad — no bounds gate.
        // Direction comes only from this claimed finger, which is then excluded
        // from the button/menu/mic hit-tests below so a far drag can't trigger
        // them. Dragging back inside the center deadzone reads as neutral.
        var dpadPoint: CGPoint?
        if let dt = dpadTouch,
           dt.phase == .began || dt.phase == .moved || dt.phase == .stationary {
            let point = dt.location(in: self)
            dpadPoint = point
            let localDpad = convert(point, to: dpad)
            buttons |= dpadButtonsForPoint(localDpad)
            let center = CGPoint(x: dpad.bounds.midX, y: dpad.bounds.midY)
            dpadSetThumbDirection(dx: localDpad.x - center.x, dy: localDpad.y - center.y,
                                  maxDistance: dpad.bounds.width / 2)
        } else {
            dpadResetThumb()
        }
        updateDpadTrackerDot(at: dpadPoint)

        for touch in allTouches {
            guard touch.phase == .began || touch.phase == .moved || touch.phase == .stationary else {
                continue
            }
            // The pad's claimed finger only steers; never let it press a button
            // or the menu (it may have been dragged far across the screen).
            if touch === dpadTouch { continue }
            let point = touch.location(in: self)

            // Check action buttons
            for (view, mask) in buttonMap {
                if touchHits(convert(point, to: view), in: view) {
                    buttons |= mask
                }
            }

            // Check menu button
            let menuLocal = convert(point, to: btnMenu)
            let menuExpanded = btnMenu.bounds.insetBy(dx: -10, dy: -10)
            if menuExpanded.contains(menuLocal) {
                if touch.phase == .began { fireHaptic() }
                btnMenu.flashPress()
                onMenuTap?()
            }

            // Check clip button (action trigger like Menu, never a game input). The
            // pad's claimed finger already `continue`d above, so sliding the D-pad
            // finger here can't fire it. Skip when hidden (controller mode / preset).
            if !btnClip.isHidden {
                let clipLocal = convert(point, to: btnClip)
                let clipExpanded = btnClip.bounds.insetBy(dx: -10, dy: -10)
                if clipExpanded.contains(clipLocal) {
                    if touch.phase == .began { fireHaptic() }
                    btnClip.flashPress()
                    onClipTap?()
                }
            }
        }

        // Check mic/blow button (NDS only)
        if let mic = micButton {
            var micTouched = false
            for touch in allTouches where touch !== dpadTouch
                && [.began, .moved, .stationary].contains(touch.phase) {
                let local = convert(touch.location(in: self), to: mic)
                let expanded = mic.bounds.insetBy(dx: -mic.bounds.width * 0.2, dy: -mic.bounds.height * 0.2)
                if expanded.contains(local) { micTouched = true; break }
            }
            if micTouched != micActive {
                micActive = micTouched
                if micTouched { fireHaptic() }   // press haptic, like the other controls
                delegate?.touchControlsMicBlowStateChanged(active: micTouched)
                (mic as? HighlightableButton)?.isPressed = micTouched
            }
        }

        applyButtons(buttons)
    }

    private func applyButtons(_ buttons: UInt32) {
        // While a controller is connected the game controls are hidden, so
        // touch contributes nothing. The Menu button is checked separately in
        // updateButtons and still works.
        let buttons = controllerModeActive ? 0 : buttons
        // Augment raw touch state with locked buttons before reporting to the emulator
        let augmented = controllerModeActive ? 0 : (buttons | lockedButtons)

        // Haptic only on new *physical* presses, and skip buttons that are already
        // locked (silent re-press of a locked button — already pressed visually).
        let newlyPressedRaw = buttons & ~lastRawButtons & ~lockedButtons
        lastRawButtons = buttons
        if newlyPressedRaw != 0 {
            // Strength is the user's Settings choice; the default level keeps
            // the historical light tap (medium felt too strong as a constant).
            fireHaptic()
        }

        guard augmented != activeButtons else { return }
        activeButtons = augmented
        delegate?.touchControlsDidChange(buttons: augmented)

        // Visual feedback (locked buttons stay pressed-style automatically)
        for (view, mask) in buttonMap {
            (view as? HighlightableButton)?.isPressed = (augmented & mask) != 0
            // Only action buttons carry the lock glyph; the cast naturally skips L/R/Start/Select.
            if let action = view as? ActionButton {
                action.isLocked = (lockedButtons & mask) != 0
            }
        }
        crossDPad?.updateHighlight(buttons: augmented)
    }

    // MARK: - D-Pad dispatch helpers (work with either DPadView or CrossDPadView)

    private func dpadButtonsForPoint(_ point: CGPoint) -> UInt32 {
        if let cross = crossDPad { return cross.buttonsForPoint(point) }
        if let joy = joystickDPad { return joy.buttonsForPoint(point) }
        return 0
    }

    private func dpadSetThumbDirection(dx: CGFloat, dy: CGFloat, maxDistance: CGFloat) {
        crossDPad?.setThumbDirection(dx: dx, dy: dy, maxDistance: maxDistance)
        joystickDPad?.setThumbDirection(dx: dx, dy: dy, maxDistance: maxDistance)
    }

    private func dpadResetThumb() {
        crossDPad?.resetThumb()
        joystickDPad?.resetThumb()
    }

    /// Show/move the finger-tracker puck at `pointInSelf` (this view's coords),
    /// or hide it when nil. Parented to the superview, inserted just above the
    /// controls, so it sits above the pad yet below the pause overlay and is
    /// never clipped by the controls view's bounds.
    private func updateDpadTrackerDot(at pointInSelf: CGPoint?) {
        guard let point = pointInSelf, let parent = superview else {
            fingerDot.isHidden = true
            return
        }
        if fingerDot.superview !== parent {
            parent.insertSubview(fingerDot, aboveSubview: self)
        }
        fingerDot.center = convert(point, to: parent)
        fingerDot.isHidden = false
    }

    /// When the whole controls view is hidden (the pause overlay is shown), drop
    /// any in-flight steering finger and hide the tracker puck so it can't linger
    /// on screen behind the menu.
    override var isHidden: Bool {
        didSet {
            guard isHidden, !oldValue else { return }
            dpadTouch = nil
            fingerDot.isHidden = true
        }
    }
}

// MARK: - Button protocol for visual feedback

protocol HighlightableButton: UIView {
    var isPressed: Bool { get set }
}

// MARK: - Dress kind (which console palette the dressed buttons wear)

/// The console whose palette the dressed buttons use. GB/GBC keeps the DMG look (maroon A/B,
/// charcoal D-pad, grey pills); GBA recolors the SAME button shapes to its palette (light
/// #C4BFCF buttons + D-pad). Only consulted while `dressed` is on — the undressed path is
/// untouched. `gbaButton` shades are derived from #C4BFCF.
enum DressKind {
    case gbc, gba, nds

    static let gbaButton        = UIColor(red: 0.769, green: 0.749, blue: 0.812, alpha: 1) // #C4BFCF
    static let gbaButtonPressed = UIColor(red: 0.640, green: 0.620, blue: 0.680, alpha: 1)
    static let gbaButtonEdge    = UIColor(red: 0.560, green: 0.540, blue: 0.600, alpha: 1)
    static let gbaSurround      = UIColor(red: 0.055, green: 0.055, blue: 0.063, alpha: 1) // #0E0E10

    // NDS palette: buttons #EBEBEB, ink #777777 (labels, icons, D-pad lines, under-discs).
    static let ndsButton        = UIColor(red: 0.922, green: 0.922, blue: 0.922, alpha: 1) // #EBEBEB
    static let ndsButtonPressed = UIColor(red: 0.820, green: 0.820, blue: 0.820, alpha: 1)
    static let ndsButtonEdge    = UIColor(red: 0.760, green: 0.760, blue: 0.760, alpha: 1)
    static let ndsInk           = UIColor(red: 0.467, green: 0.467, blue: 0.467, alpha: 1) // #777777

    /// The "modern recolor" dresses (GBA, NDS) share button shapes + a light fill with a dark ink
    /// accent; only the tokens differ. Not meaningful for `.gbc` (its views keep maroon/charcoal/grey).
    var faceFill: UIColor    { self == .nds ? DressKind.ndsButton        : DressKind.gbaButton }
    var facePressed: UIColor { self == .nds ? DressKind.ndsButtonPressed : DressKind.gbaButtonPressed }
    var faceEdge: UIColor    { self == .nds ? DressKind.ndsButtonEdge    : DressKind.gbaButtonEdge }
    var faceInk: UIColor     { self == .nds ? DressKind.ndsInk           : DressKind.gbaSurround }
}

// MARK: - CADisplayLink weak proxy (breaks the link → target → self → link retain cycle)

final class LockDisplayProxy {
    weak var owner: TouchControlsView?
    init(owner: TouchControlsView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) {
        owner?.lockDisplayLinkTick()
    }
}

// MARK: - Joystick View (visual only — input handled by floating touch logic)

final class DPadView: UIView {
    private let baseLayer = CAShapeLayer()
    private let thumbLayer = CAShapeLayer()
    private let thumbRadius: CGFloat = 20

    /// The thumb is 1.6x larger when dressed (the GB/GBC console look).
    private var effectiveThumbRadius: CGFloat { dressed ? thumbRadius * 1.6 : thumbRadius }

    private var thumbOffset: CGPoint = .zero

    // GB/GBC dressed palette: a dark recessed dish + a charcoal raised thumb (matches the
    // dressed cross). Applied only when `dressed` is on.
    private static let dpadFill = UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)

    /// When on, the joystick wears the GB/GBC console-dress look (dark dish + charcoal thumb)
    /// instead of the default translucent white. Set by TouchControlsView for the GB/GBC
    /// default layout; the undressed look is untouched (GBA/NDS/presets).
    var dressed = false {
        didSet { guard dressed != oldValue else { return }; applyResting() }
    }

    /// Which console palette to wear when dressed: GB/GBC charcoal thumb vs GBA light #C4BFCF.
    var dressKind: DressKind = .gbc {
        didSet { guard dressKind != oldValue else { return }; applyResting() }
    }
    /// Nostalgia vs the Retro Pal recolour (set by setDressed).
    var dressVariant: DressVariant = .nostalgia {
        didSet { guard dressVariant != oldValue else { return }; applyResting() }
    }

    private func applyResting() {
        if dressed {
            // No outer ring — the dress always draws a recessed well behind the joystick.
            baseLayer.isHidden = true
            let rp = dressVariant.dpadFace(dressKind)
            if dressKind != .gbc {
                thumbLayer.fillColor = (rp ?? dressKind.faceFill).cgColor
                thumbLayer.strokeColor = (rp?.rpEdge ?? dressKind.faceEdge).cgColor
            } else {
                thumbLayer.fillColor = (rp ?? Self.dpadFill).cgColor
                thumbLayer.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
            }
        } else {
            baseLayer.isHidden = false
            baseLayer.fillColor = UIColor.white.withAlphaComponent(0.1).cgColor
            baseLayer.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
            thumbLayer.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
            thumbLayer.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        }
        updateThumbPosition()   // the thumb radius depends on `dressed`
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Outer ring (base)
        baseLayer.fillColor = UIColor.white.withAlphaComponent(0.1).cgColor
        baseLayer.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        baseLayer.lineWidth = 2
        layer.addSublayer(baseLayer)

        // Inner thumb
        thumbLayer.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
        thumbLayer.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        thumbLayer.lineWidth = 1.5
        layer.addSublayer(thumbLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2

        baseLayer.path = UIBezierPath(
            arcCenter: center, radius: radius,
            startAngle: 0, endAngle: .pi * 2, clockwise: true
        ).cgPath

        updateThumbPosition()
    }

    /// Called from touch handling to move the visual thumb
    func setThumbDirection(dx: CGFloat, dy: CGFloat, maxDistance: CGFloat) {
        let dist = sqrt(dx * dx + dy * dy)
        let clampedDist = min(dist, maxDistance)
        let radius = min(bounds.width, bounds.height) / 2 - effectiveThumbRadius

        if dist > 0 {
            let scale = min(clampedDist / maxDistance, 1.0) * radius
            thumbOffset = CGPoint(x: dx / dist * scale, y: dy / dist * scale)
        } else {
            thumbOffset = .zero
        }
        updateThumbPosition()
    }

    func resetThumb() {
        thumbOffset = .zero
        updateThumbPosition()
    }

    private func updateThumbPosition() {
        let center = CGPoint(x: bounds.midX + thumbOffset.x, y: bounds.midY + thumbOffset.y)
        thumbLayer.path = UIBezierPath(
            arcCenter: center, radius: effectiveThumbRadius,
            startAngle: 0, endAngle: .pi * 2, clockwise: true
        ).cgPath
    }

    // Fallback for non-floating touches (fixed position)
    func buttonsForPoint(_ point: CGPoint) -> UInt32 {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        let deadzone = min(bounds.width, bounds.height) * 0.15

        guard dist > deadzone else { return 0 }

        // Shared 8-way mapping (was a duplicate of CrossDPadView's, with the same
        // left-skew bug that collapsed right diagonals to pure right).
        return DPadGeometry.buttons(forAngle: atan2(dy, dx))
    }

    func updateHighlight(buttons: UInt32) {
        // Thumb visual is handled by setThumbDirection, not by button state
    }
}

// MARK: - Action Button (A, B)

final class ActionButton: UIView, HighlightableButton {
    // GB/GBC dressed palette (maroon disc), applied only when `dressed` is on.
    private static let maroon        = UIColor(red: 0.549, green: 0.1255, blue: 0.3294, alpha: 1) // #8C2054
    private static let maroonPressed = UIColor(red: 0.43,  green: 0.095,  blue: 0.255,  alpha: 1)
    private static let maroonEdge    = UIColor(red: 0.40,  green: 0.10,   blue: 0.245,  alpha: 1) // lighter rim (reads brighter)

    /// When on, the button wears the GB/GBC console-dress look (maroon) instead of the
    /// default translucent white. Set by TouchControlsView for the GB/GBC default layout.
    var dressed = false {
        didSet { guard dressed != oldValue else { return }; applyResting() }
    }

    /// When true, the touch hit-test uses the inscribed circle (not the square frame) so the NDS
    /// diamond's round buttons don't overlap at the corners the way the square frames do.
    var roundHitbox = false

    /// Which console palette to use when dressed (GB/GBC maroon vs GBA #C4BFCF).
    var dressKind: DressKind = .gbc { didSet { applyResting() } }
    /// Nostalgia vs the Retro Pal recolour (set by setDressed).
    var dressVariant: DressVariant = .nostalgia { didSet { applyResting() } }
    private var fillColor: UIColor {
        if let c = dressVariant.abFace(dressKind) { return c }
        return dressKind == .gbc ? Self.maroon : dressKind.faceFill
    }
    private var pressedColor: UIColor {
        if let c = dressVariant.abFace(dressKind) { return c.rpPressed }
        return dressKind == .gbc ? Self.maroonPressed : dressKind.facePressed
    }
    private var edgeColor: UIColor {
        if let c = dressVariant.abFace(dressKind) { return c.rpEdge }
        return dressKind == .gbc ? Self.maroonEdge : dressKind.faceEdge
    }

    var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            UIView.animate(withDuration: 0.06, delay: 0, options: [.allowUserInteraction]) {
                if self.isPressed {
                    self.backgroundColor = self.dressed
                        ? self.pressedColor : UIColor.white.withAlphaComponent(0.55)
                    self.layer.borderColor = (self.dressed
                        ? self.edgeColor : UIColor.white.withAlphaComponent(0.8)).cgColor
                    // Dressed A/B shrink less (0.95); undressed keeps the original 0.88.
                    let s: CGFloat = self.dressed ? 0.95 : 0.88
                    self.transform = self.baseTransform.scaledBy(x: s, y: s)
                    self.layer.shadowOpacity = 0
                } else {
                    self.applyResting()
                    self.transform = self.restingTransform
                    self.layer.shadowOpacity = 0.3
                }
            }
        }
    }

    /// GBA-dressed A/B rest a touch smaller (98%, centred); every other state rests at full size.
    private var restingScale: CGFloat { (dressed && dressKind != .gbc) ? 0.98 : 1.0 }
    var restingTransform: CGAffineTransform { baseTransform.scaledBy(x: restingScale, y: restingScale) }

    /// Resting (un-pressed) fill + border for the current `dressed` mode.
    private func applyResting() {
        backgroundColor = dressed ? fillColor : UIColor.white.withAlphaComponent(0.2)
        layer.borderColor = (dressed ? edgeColor : UIColor.white.withAlphaComponent(0.45)).cgColor
        sheen.isHidden = true   // A/B keep ONE flat background behind the letter (no top sheen)
        applyLabelStyle()
        if !isPressed { transform = restingTransform }
    }

    /// The A/B letter. GBA dress = "creusé" (engraved): a darker glyph of the button's own family
    /// with a light catch directly beneath, so it reads as incised into the plastic. Otherwise the
    /// plain white label (GB/GBC keeps its DONE look; the undressed default is untouched).
    private func applyLabelStyle() {
        if dressed && dressKind != .gbc {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.white.withAlphaComponent(0.5)
            shadow.shadowOffset = CGSize(width: 0, height: 1)
            shadow.shadowBlurRadius = 0.5
            // GBA engraves in its edge tone (custom: the letters slot); NDS in the #777777 ink
            // (custom: the ink slot; Retro Pal: also #777777).
            let labelInk: UIColor
            if dressKind == .nds {
                labelInk = dressVariant.ndsPalette?.letters
                    ?? (dressVariant == .retroPal ? RetroPalPalette.ndsInk : DressKind.ndsInk)
            } else {
                labelInk = dressVariant.gbaPalette?.letters ?? DressKind.gbaButtonEdge
            }
            label.attributedText = NSAttributedString(string: titleText, attributes: [
                .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                .foregroundColor: labelInk,   // darker than the disc → reads recessed
                .shadow: shadow,
            ])
        } else {
            // GB/GBC + undressed: a flat letter. Custom uses the A/B-letters slot; built-ins
            // keep plain white.
            label.attributedText = nil
            label.text = titleText
            label.textColor = (dressed ? dressVariant.gbcPalette?.abLetters : nil) ?? .white
            label.font = .systemFont(ofSize: 20, weight: .bold)
        }
    }

    /// Long-press lock indicator. Pressed visual remains the same; only the
    /// small corner glyph telegraphs that the button is held by lock rather
    /// than by the user's finger.
    var isLocked = false {
        didSet {
            guard isLocked != oldValue else { return }
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction]) {
                self.lockGlyph.alpha = self.isLocked ? 1.0 : 0.0
                self.lockGlyph.transform = self.isLocked
                    ? .identity
                    : CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
        }
    }

    /// Stores the external transform (from applyLayout) so press animation compounds with it.
    var baseTransform: CGAffineTransform = .identity

    private let label = UILabel()
    private var titleText = ""               // the "A" / "B" letter, for restyling the label
    private let sheen = CAGradientLayer()   // raised-plastic top highlight (dressed only), mirrors L/R
    private let lockGlyph: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        let img = UIImage(systemName: "lock.fill", withConfiguration: config)
        let iv = UIImageView(image: img)
        // White-on-translucent matches the rest of the controls; the dark
        // shadow gives the small glyph definition against the pressed button.
        iv.tintColor = UIColor.white.withAlphaComponent(0.85)
        iv.alpha = 0
        iv.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.layer.shadowColor = UIColor.black.cgColor
        iv.layer.shadowOpacity = 0.5
        iv.layer.shadowRadius = 2
        iv.layer.shadowOffset = .zero
        return iv
    }()

    var currentTitle: String? { label.text }

    init(label text: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.2)
        layer.cornerRadius = 30
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 3
        layer.shadowOpacity = 0.3

        sheen.colors = [UIColor.white.withAlphaComponent(0.35).cgColor, UIColor.clear.cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 0)
        sheen.endPoint = CGPoint(x: 0.5, y: 1)
        sheen.isHidden = true
        layer.insertSublayer(sheen, at: 0)

        titleText = text
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(lockGlyph)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Glyph sits slightly inside the top-right rim (button is circular, cornerRadius = W/2)
            lockGlyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            lockGlyph.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        // Sheen on the top half, clipped to the circle (shadow needs masksToBounds off).
        sheen.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.55)
        sheen.cornerRadius = bounds.width / 2
        sheen.masksToBounds = true
    }
}

// MARK: - Shoulder Button (L, R)

final class ShoulderButton: UIView, HighlightableButton {
    /// NDS L/R corner radius as a fraction of the short side — a rounded square, not a pill.
    /// The skin's L/R creusé seat mirrors this so the two stay concentric.
    static let ndsCornerFactor: CGFloat = 0.3

    private let label = UILabel()
    private let sheen = CAGradientLayer()   // raised-plastic top highlight (dressed only)

    /// When on, wears the GBA shoulder-trigger dress: a light (#C4BFCF) raised, rounded bar with
    /// a top sheen and a dark moulded L/R label. GB/GBC has no L/R, so this only shows on GBA;
    /// undressed (GBA presets) keeps the default translucent white.
    var dressed = false {
        didSet { guard dressed != oldValue else { return }; applyResting(); setNeedsLayout() }
    }

    /// Which palette the dressed L/R wear (GBA #C4BFCF vs NDS #B6B6B6). GB/GBC has no L/R.
    var dressKind: DressKind = .gba {
        didSet { guard dressKind != oldValue else { return }; applyResting() }
    }
    /// Nostalgia vs the Retro Pal recolour (NDS L/R only — GBA L/R is untouched).
    var dressVariant: DressVariant = .nostalgia {
        didSet { guard dressVariant != oldValue else { return }; applyResting() }
    }
    private var fill: UIColor {
        if let c = dressVariant.shoulderFace(dressKind) { return c }
        return dressKind.faceFill
    }
    private var pressedFill: UIColor {
        if let c = dressVariant.shoulderFace(dressKind) { return c.rpPressed }
        return dressKind.facePressed
    }
    private var edge: UIColor {
        if let c = dressVariant.shoulderFace(dressKind) { return c.rpEdge }
        return dressKind.faceEdge
    }
    /// L/R label: custom uses the letters slot (GBA + NDS); Retro Pal NDS recolours it to #777777.
    private var labelInk: UIColor {
        if let p = dressVariant.gbaPalette { return p.letters }
        if let p = dressVariant.ndsPalette { return p.letters }
        if dressVariant == .retroPal, dressKind == .nds { return RetroPalPalette.ndsInk }
        return dressKind.faceInk
    }

    /// Stores the size-slider transform so the press shrink compounds with it (like ActionButton).
    var baseTransform: CGAffineTransform = .identity

    var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            if dressed {
                backgroundColor = isPressed ? pressedFill : fill
                // Dressed L/R shrink 5% on press, centred (same centre pressed vs not).
                let s: CGFloat = isPressed ? 0.95 : 1.0
                UIView.animate(withDuration: 0.06, delay: 0, options: [.allowUserInteraction]) {
                    self.transform = self.baseTransform.scaledBy(x: s, y: s)
                }
            } else {
                backgroundColor = isPressed ? UIColor.white.withAlphaComponent(0.5)
                                            : UIColor.white.withAlphaComponent(0.2)
            }
        }
    }

    init(label text: String) {
        super.init(frame: .zero)
        layer.cornerRadius = 8
        layer.borderWidth = 1

        sheen.colors = [UIColor.white.withAlphaComponent(0.35).cgColor, UIColor.clear.cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 0)
        sheen.endPoint = CGPoint(x: 0.5, y: 1)
        sheen.isHidden = true
        layer.insertSublayer(sheen, at: 0)

        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyResting()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyResting() {
        if dressed {
            backgroundColor = fill
            layer.borderColor = edge.cgColor
            label.textColor = labelInk                 // dark moulded "L"/"R"
            sheen.isHidden = false
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 1.5)
            layer.shadowRadius = 2
            layer.shadowOpacity = 0.25
        } else {
            backgroundColor = UIColor.white.withAlphaComponent(0.2)
            layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
            label.textColor = .white
            sheen.isHidden = true
            layer.shadowOpacity = 0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Dressed: a rounded "trigger" bar (rounder than the default rect) with the sheen on the
        // top band. The drop shadow needs masksToBounds off, so the sheen clips itself instead.
        // NDS: a rounded SQUARE (small corner) rather than the GBA pill. The skin's L/R seat
        // matches this with ShoulderButton.ndsCornerFactor (keep in sync).
        let radius = dressed
            ? (dressKind == .nds ? min(bounds.width, bounds.height) * ShoulderButton.ndsCornerFactor
                                 : min(bounds.height * 0.5, bounds.width * 0.5))
            : 8
        layer.cornerRadius = radius
        sheen.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.55)
        sheen.cornerRadius = radius
        sheen.masksToBounds = true
    }
}

// MARK: - Small Button (Start, Select, Menu)

final class SmallButton: UIView, HighlightableButton {
    /// How the button is dressed for the GB/GBC console look.
    ///  - none: default translucent white (GBA/NDS + custom presets).
    ///  - pill: thin grey diagonal pill, bottom-left → top-right of the hitbox (SELECT/START, portrait).
    ///  - pillTop: thin horizontal pill at the hitbox's upper third, menu-icon coloured (SELECT/START, landscape).
    ///  - iconOnly: no chrome; the icon recoloured to the PHONES-icon body colour (#C0BDBC), sized
    ///    to fill its round well, with the same two-sided emboss as the dress's PHONES icon
    ///    (light up-left + dark down-right) (CLIP both orientations, MENU portrait).
    ///  - circle: a true-circle grey background behind the icon (MENU landscape).
    ///  - decal: the button draws nothing; the skin draws the decoration over it (NDS Mic).
    enum DressStyle { case none, pill, pillTop, iconOnly, circle, decal }

    // GB/GBC dressed palette.
    private static let grey         = UIColor(red: 0.30, green: 0.30, blue: 0.31, alpha: 1)
    private static let greyPressed  = UIColor(red: 0.22, green: 0.22, blue: 0.23, alpha: 1)
    private static let greyEdge     = UIColor(red: 0.18, green: 0.18, blue: 0.19, alpha: 1)
    private static let iconBody = UIColor(red: 0.753, green: 0.741, blue: 0.737, alpha: 1) // #C0BDBC (matches PHONES icon)
    // The landscape MENU icon colour — the .pillTop pills match it (per request).
    private static let menuIcon        = UIColor.white.withAlphaComponent(0.85)
    private static let menuIconPressed = UIColor.white.withAlphaComponent(0.6)

    /// Which console palette to use when dressed (GB/GBC grey/white vs GBA #C4BFCF).
    var dressKind: DressKind = .gbc { didSet { applyResting() } }
    /// Nostalgia vs the Retro Pal recolour (set by setDressed).
    var dressVariant: DressVariant = .nostalgia { didSet { applyResting() } }
    /// GB/GBC SELECT/START/MENU/CLIP go near-black under Retro Pal and to the user's small-buttons
    /// colour under custom; GBA/NDS pills are untouched (nil → keep their built-in fill).
    // SELECT/START pill (.pill): every console's face goes to its small-button slot under custom
    // (GBC → smallButtons; GBA/NDS → buttons), to the Retro Pal recolour, or the built-in default.
    private var pillBase: UIColor {
        if let c = dressVariant.smallButtonFace(dressKind) { return c }
        return dressKind == .gbc ? Self.grey : dressKind.faceFill }
    private var pillPressedC: UIColor {
        if let c = dressVariant.smallButtonFace(dressKind) { return c.rpPressed }
        return dressKind == .gbc ? Self.greyPressed : dressKind.facePressed }
    private var pillEdgeC: UIColor {
        if let c = dressVariant.smallButtonFace(dressKind) { return c.rpEdge }
        return dressKind == .gbc ? Self.greyEdge : dressKind.faceEdge }
    // Landscape SELECT/START (.pillTop): GB/GBC keeps white for the BUILT-INS (custom uses the slot);
    // GBA/NDS follow their button face.
    private var pillTopBase: UIColor {
        if dressKind == .gbc { return dressVariant.gbcPalette?.smallButtons ?? Self.menuIcon }
        return dressVariant.smallButtonFace(dressKind) ?? dressKind.faceFill }
    private var pillTopPressedC: UIColor {
        if dressKind == .gbc { return dressVariant.gbcPalette?.smallButtons.rpPressed ?? Self.menuIconPressed }
        return dressVariant.smallButtonFace(dressKind)?.rpPressed ?? dressKind.facePressed }
    // MENU/CLIP icon-only glyph (GBA portrait): the menu-icons slot under custom, else the face.
    private var iconColorC: UIColor {
        if let p = dressVariant.gbaPalette { return p.menuIcons }
        if let p = dressVariant.ndsPalette { return p.icons }
        return dressKind == .gbc ? Self.iconBody : dressKind.faceFill }
    // The MENU/CLIP circle BACKGROUND: GBA gets its own slot; others follow the pill face (so the
    // built-ins + GB/GBC + NDS are unchanged).
    private var circleBgColor: UIColor { dressVariant.gbaPalette?.menuButtons ?? pillBase }
    private var circlePressedColor: UIColor { dressVariant.gbaPalette.map { $0.menuButtons.rpPressed } ?? pillPressedC }
    private var circleEdgeC: UIColor { dressVariant.gbaPalette != nil ? circleBgColor.rpEdge : pillEdgeC }
    // The MENU/CLIP circle ICON: custom uses the menu-icons (GBC/GBA) / icons (NDS) slot.
    private var circleIconC: UIColor {
        if let p = dressVariant.gbcPalette { return p.menuIcons }
        if let p = dressVariant.gbaPalette { return p.menuIcons }
        if let p = dressVariant.ndsPalette { return p.icons }
        if dressVariant == .retroPal, dressKind == .nds { return RetroPalPalette.ndsInk }
        return dressKind == .gbc ? UIColor.white.withAlphaComponent(0.85) : dressKind.faceInk
    }

    var dressStyle: DressStyle = .none {
        didSet { guard dressStyle != oldValue else { return }; applyResting() }
    }

    // Icon-variant pieces (nil on the label variant). `iconHighlight` (light, up-left) and
    // `iconShadow` (dark, down-right) are the two-sided emboss copies behind the icon, shown
    // only in `.iconOnly`; the icon grows (iconSmall -> iconBig) in `.iconOnly` to fill its
    // round well. `circleBg` is the true-circle background for `.circle` (MENU landscape),
    // inscribed in layoutSubviews.
    private var iconView: UIImageView?
    private var iconHighlight: UIImageView?
    private var iconShadow: UIImageView?
    private var textLabel: UILabel?            // label variant only (SELECT/START); hidden when dressed
    private var iconSmall: [NSLayoutConstraint] = []
    private var iconBig: [NSLayoutConstraint] = []
    private let circleBg = CAShapeLayer()
    private let pillBg = CAShapeLayer()        // diagonal capsule for .pill (SELECT/START)

    /// Pill thickness as a fraction of the hitbox short side. Must match
    /// `GameBoySkin.pillThicknessRatio` so the dress's recessed seat lines up.
    private static let pillThicknessRatio: CGFloat = 0.24

    /// GBA/NDS SELECT/START: the dress draws a creusé pill (brand ratio) + the label; the BUTTON is
    /// just a tiny "clip-like" circle — at the RIGHT of the pill on GBA, mirrored to the LEFT on
    /// NDS. Ratio must match the skins' `selectPillRatio`.
    static let selectPillRatio: CGFloat = 3.4
    private func selectCircleRect() -> CGRect {
        let pillH = bounds.width / Self.selectPillRatio
        let d = pillH * 0.7
        let pad = pillH * 0.25
        let x = (dressKind == .nds) ? bounds.minX + pad : bounds.maxX - pad - d
        return CGRect(x: x, y: bounds.midY - d / 2, width: d, height: d)
    }

    /// Resting/pressed fill for the pill, by orientation: grey diagonal pill (portrait, .pill)
    /// vs the menu-icon-coloured horizontal pill (landscape, .pillTop).
    private func pillFill(pressed: Bool) -> CGColor {
        if dressStyle == .pillTop {
            return (pressed ? pillTopPressedC : pillTopBase).cgColor
        }
        return (pressed ? pillPressedC : pillBase).cgColor
    }

    /// The external transform (size slider) from applyLayout, so the press feedback compounds
    /// with it — same pattern as ActionButton.baseTransform.
    var baseTransform: CGAffineTransform = .identity

    var isPressed = false { didSet { applyPressed() } }

    /// A momentary press pulse for the action triggers (MENU/CLIP), which fire on tap and
    /// never get a held `isPressed` from the game-input loop. Dressed buttons only, so the
    /// undressed GBA/NDS/preset path is unchanged.
    func flashPress() {
        guard dressStyle != .none else { return }
        isPressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.dressStyle != .none else { return }
            self.isPressed = false
        }
    }

    private func applyPressed() {
        switch dressStyle {
        case .none:
            // Undressed (GBA/NDS/presets): unchanged — background only, no transform.
            backgroundColor = isPressed ? UIColor.white.withAlphaComponent(0.45)
                                        : UIColor.white.withAlphaComponent(0.15)
            return
        case .decal:
            return   // skin-drawn decal; nothing on the button itself
        case .pill, .pillTop:
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pillBg.fillColor = pillFill(pressed: isPressed)
            CATransaction.commit()
            if dressKind != .gbc {
                // GBA/NDS tiny "button": shrink around ITS OWN center (mirror A — no sink, same
                // center), instead of the view-level shrink below.
                let cc = CGPoint(x: selectCircleRect().midX, y: selectCircleRect().midY)
                let s: CGFloat = isPressed ? 0.85 : 1.0
                var t = CATransform3DMakeTranslation(cc.x, cc.y, 0)
                t = CATransform3DScale(t, s, s, 1)
                t = CATransform3DTranslate(t, -cc.x, -cc.y, 0)
                CATransaction.begin(); CATransaction.setAnimationDuration(0.06)
                pillBg.transform = t
                CATransaction.commit()
                return
            }
        case .circle:
            CATransaction.begin(); CATransaction.setDisableActions(true)
            circleBg.fillColor = (isPressed ? circlePressedColor : circleBgColor).cgColor
            CATransaction.commit()
        case .iconOnly:
            iconView?.alpha = isPressed ? 0.6 : 1.0
        }
        // Slice 4: dressed buttons shrink into their well on press (visual only). Center-
        // anchored, so the full and shrunk button share their center.
        UIView.animate(withDuration: 0.06, delay: 0, options: [.allowUserInteraction]) {
            self.transform = self.isPressed
                ? self.baseTransform.scaledBy(x: 0.9, y: 0.9)
                : self.baseTransform
        }
    }

    /// Resting appearance for the current dress style.
    private func applyResting() {
        circleBg.isHidden = (dressStyle != .circle)
        pillBg.isHidden = (dressStyle != .pill && dressStyle != .pillTop)
        // Dressed (SELECT/START): the identifier is printed on the case (slice 3c), so the
        // pill is bare. Its diagonal shape is built in layoutSubviews.
        textLabel?.isHidden = (dressStyle != .none)
        setNeedsLayout()
        // Enlarge the icon only when it stands alone (icon-only), to fill its round well.
        if iconView != nil {
            let big = (dressStyle == .iconOnly)
            NSLayoutConstraint.deactivate(big ? iconSmall : iconBig)
            NSLayoutConstraint.activate(big ? iconBig : iconSmall)
        }
        switch dressStyle {
        case .none:
            backgroundColor = UIColor.white.withAlphaComponent(0.15)
            layer.borderWidth = 1
            layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
            iconView?.tintColor = UIColor.white.withAlphaComponent(0.8)
            iconHighlight?.isHidden = true
            iconShadow?.isHidden = true
        case .pill:
            // The visible pill is the shape layer, not the view background. GBA: a tiny clip-like
            // circle (no edge). GB/GBC: the grey diagonal pill (edged).
            backgroundColor = .clear
            layer.borderWidth = 0
            pillBg.fillColor = pillFill(pressed: false)
            pillBg.strokeColor = (dressKind != .gbc) ? UIColor.clear.cgColor : pillEdgeC.cgColor
            pillBg.lineWidth = (dressKind != .gbc) ? 0 : 1
            iconHighlight?.isHidden = true
            iconShadow?.isHidden = true
        case .pillTop:
            // Horizontal top-stuck pill, menu-icon coloured, no edge.
            backgroundColor = .clear
            layer.borderWidth = 0
            pillBg.fillColor = pillFill(pressed: false)
            pillBg.strokeColor = UIColor.clear.cgColor
            pillBg.lineWidth = 0
            iconHighlight?.isHidden = true
            iconShadow?.isHidden = true
        case .circle:
            backgroundColor = .clear
            layer.borderWidth = 0
            circleBg.fillColor = circleBgColor.cgColor
            circleBg.strokeColor = circleEdgeC.cgColor
            circleBg.lineWidth = 1
            iconView?.tintColor = circleIconC
            iconHighlight?.isHidden = true
            iconShadow?.isHidden = true
        case .iconOnly:
            backgroundColor = .clear
            layer.borderWidth = 0
            iconView?.tintColor = iconColorC
            iconHighlight?.isHidden = false
            iconShadow?.isHidden = false
        case .decal:
            // Pure skin decal (NDS Mic): the button draws nothing; the skin draws slit + label.
            backgroundColor = .clear
            layer.borderWidth = 0
            iconHighlight?.isHidden = true
            iconShadow?.isHidden = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        switch dressStyle {
        case .circle:
            let d = min(bounds.width, bounds.height)
            let rect = CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
            circleBg.path = UIBezierPath(ovalIn: rect).cgPath
        case .pill where dressKind != .gbc, .pillTop where dressKind != .gbc:
            // GBA/NDS: the visible "button" is a tiny circle at the right of the pill (the dress
            // draws the creusé pill bg + the label).
            pillBg.path = UIBezierPath(ovalIn: selectCircleRect()).cgPath
        case .pill:
            // GB/GBC: a thin diagonal capsule from the hitbox bottom-left to its top-right, so
            // the bare pill "draws the diagonal". The dress draws a matching seat + rotated label.
            let dx = bounds.width, dy = -bounds.height
            let len = max(1, hypot(dx, dy))
            let t = min(bounds.width, bounds.height) * Self.pillThicknessRatio
            let inset = t / 2
            let q1 = CGPoint(x: bounds.minX + dx / len * inset, y: bounds.maxY + dy / len * inset)
            let q2 = CGPoint(x: bounds.maxX - dx / len * inset, y: bounds.minY - dy / len * inset)
            let line = CGMutablePath(); line.move(to: q1); line.addLine(to: q2)
            pillBg.path = line.copy(strokingWithWidth: t, lineCap: .round,
                                    lineJoin: .round, miterLimit: 0)
        case .pillTop:
            // GB/GBC: a thin horizontal pill at the upper third of the hitbox.
            let t = min(bounds.width, bounds.height) * Self.pillThicknessRatio
            let y = bounds.minY + bounds.height / 3
            let q1 = CGPoint(x: bounds.minX + t / 2, y: y)
            let q2 = CGPoint(x: bounds.maxX - t / 2, y: y)
            let line = CGMutablePath(); line.move(to: q1); line.addLine(to: q2)
            pillBg.path = line.copy(strokingWithWidth: t, lineCap: .round,
                                    lineJoin: .round, miterLimit: 0)
        case .none, .iconOnly, .decal:
            layer.cornerRadius = 6
        }
    }

    init(label text: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.15)
        layer.cornerRadius = 6
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor

        pillBg.isHidden = true
        layer.insertSublayer(pillBg, at: 0)

        let lbl = UILabel()
        lbl.text = text
        lbl.textColor = UIColor.white.withAlphaComponent(0.8)
        lbl.font = .systemFont(ofSize: 10, weight: .medium)
        lbl.textAlignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lbl)
        textLabel = lbl
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Icon variant (Menu / Clip): same rounded-rect chrome as the labelled small buttons,
    /// with an SF Symbol centered instead of text, plus the dressed-relief pieces.
    init(systemImage name: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.15)
        layer.cornerRadius = 6
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor

        circleBg.isHidden = true
        layer.insertSublayer(circleBg, at: 0)

        let img = UIImage(systemName: name)
        // Two-sided emboss matching the dress's drawEmbossedImage (PHONES badge): a light copy
        // up-left + a dark copy down-right behind the body-coloured icon, so it reads sculpted.
        let hl = UIImageView(image: img)               // emboss highlight (light, offset up-left)
        hl.tintColor = UIColor.white.withAlphaComponent(0.5)
        hl.contentMode = .scaleAspectFit
        hl.translatesAutoresizingMaskIntoConstraints = false
        hl.isHidden = true
        addSubview(hl)
        let sh = UIImageView(image: img)               // emboss shadow (dark, offset down-right)
        sh.tintColor = UIColor.black.withAlphaComponent(0.32)
        sh.contentMode = .scaleAspectFit
        sh.translatesAutoresizingMaskIntoConstraints = false
        sh.isHidden = true
        addSubview(sh)
        let iv = UIImageView(image: img)
        iv.tintColor = UIColor.white.withAlphaComponent(0.8)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)
        iconView = iv
        iconHighlight = hl
        iconShadow = sh
        // Centers stay fixed; only the size toggles. Small = the original chrome look; big =
        // icon-only, a square ~0.74 of the larger side so it fills the round well cleanly.
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            hl.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -0.6),
            hl.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.6),
            sh.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 0.6),
            sh.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.6),
        ])
        iconSmall = [
            iv.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5),
            iv.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5),
            hl.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5),
            hl.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5),
            sh.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5),
            sh.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5),
        ]
        iconBig = [
            iv.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.74),
            iv.heightAnchor.constraint(equalTo: widthAnchor, multiplier: 0.74),
            hl.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.74),
            hl.heightAnchor.constraint(equalTo: widthAnchor, multiplier: 0.74),
            sh.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.74),
            sh.heightAnchor.constraint(equalTo: widthAnchor, multiplier: 0.74),
        ]
        NSLayoutConstraint.activate(iconSmall)
    }

    required init?(coder: NSCoder) { fatalError() }
}
