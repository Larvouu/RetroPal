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
    // The PlayStation's second shoulder pair. Free bits: the mask has always
    // been 32 wide and only twelve were spoken for.
    case l2     = 0x1000 // 1 << 12 (PS1)
    case r2     = 0x2000 // 1 << 13 (PS1)
    // The DualShock's stick CLICKS. Late to the console and rare in its
    // library, but not optional: Tomb Raider 3 fires with R3, Ape Escape crawls
    // with both, Mega Man Legends 2 centres its camera with L3. A game that
    // needs one and cannot get it is a game that cannot be finished.
    case l3     = 0x4000 // 1 << 14 (PS1)
    case r3     = 0x8000 // 1 << 15 (PS1)
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

    /// The letters the pause menu names for the hold-to-lock gesture, in the
    /// order a player reads them off the pad.
    ///
    /// DERIVED from `lockableMask` rather than chosen beside it. The menu used to
    /// pick them from `hasTouchScreen`, which is a fact about the DS touchscreen
    /// and not about which buttons lock, so the Super Nintendo — whose subclass
    /// widens the mask to X and Y exactly like the DS does — was told its lock
    /// covered A and B. The gesture is the non-obvious kind that only works if
    /// the caption is right, so the caption now reads the mask.
    var lockableLetters: [String] {
        let pairs: [(GBAInput, String)] = [(.a, "A"), (.b, "B"), (.x, "X"), (.y, "Y")]
        return pairs.compactMap { pair -> String? in
            (lockableMask & pair.0.rawValue) != 0 ? pair.1 : nil
        }
    }

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
    /// A stick-click button waiting out its hold. See `holdTriggers`.
    private struct PendingHold {
        let view: UIView
        let buttonMask: UInt32
        let startTime: CFTimeInterval
        let ringLayer: CAShapeLayer
    }
    /// Holds in flight, by the touch that started them.
    private var pendingHolds: [ObjectIdentifier: PendingHold] = [:]
    /// Completed holds still under a finger, by that finger.
    private var completedHolds: [ObjectIdentifier: UInt32] = [:]
    /// Holds that have completed and are still under a finger. OR'd into the
    /// reported mask exactly as `lockedButtons` is.
    fileprivate var heldButtons: UInt32 = 0

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
    /// .soft, higher move through .medium to .heavy. Perceptual spacing is
    /// tuned by hand on hardware, not derived: the numbers are what felt evenly
    /// spaced, and there is no formula behind them to preserve.
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

    /// Controls a subclass hit-tests ITSELF, which the parent must still know
    /// about so a touch on one is not treated as landing on nothing.
    ///
    /// Everything in `buttonMap` is non-interactive and hit-tested here; these
    /// are the exceptions. Without them a tap passes straight through to the
    /// game screen whenever the controls are in pass-through mode.
    func extraClaimingViews() -> [UIView] { [] }

    /// Buttons that answer only to a HOLD, with the bit each contributes.
    ///
    /// Empty for every console but the PlayStation, whose L3 and R3 are these.
    /// They are not in `buttonMap` because a tap on them must do NOTHING: a
    /// stick click is a rare, deliberate input sitting next to a control the
    /// player's thumb is on constantly, and an instantaneous version of it
    /// would fire every time a thumb strayed. Holding is the whole feature.
    ///
    /// Once the hold completes the bit stays set until the finger lifts, which
    /// is what the games want: Tomb Raider 3 fires while R3 is down, Ape Escape
    /// crawls while L3 is.
    func holdTriggers() -> [(view: UIView, mask: UInt32)] { [] }

    /// How long a hold has to last. Shorter than the button-lock gesture's
    /// second, because this one is not a hidden power feature: it is how the
    /// button works at all, and every press pays it.
    private static let stickClickHoldDuration: CFTimeInterval = 0.35

    /// Let go of every input this view is holding. The base drops the button
    /// mask; a subclass with controls of its own adds them.
    func releaseAllInputs() {
        lockedButtons = 0
        // Holds too: a stick click left set by a finger nobody will ever lift
        // is a game firing forever, which is the same class of bug the sticks'
        // own `reset()` exists for.
        heldButtons = 0
        completedHolds.removeAll()
        for (_, pending) in pendingHolds { fadeAndRemoveRing(pending.ringLayer) }
        pendingHolds.removeAll()
        applyButtons(0)
    }

    /// Controls that are TAPS, not game inputs: checked like MENU and CLIP and
    /// reported through their own callback rather than through the bitmask.
    ///
    /// Empty for every console but the PlayStation, whose pad carries an ANALOG
    /// switch. That switch is not a button the console reads; it asks the
    /// CONTROLLER to change what it is, and that difference is the whole reason
    /// it cannot travel in `buttonMap` with everything else.
    func tapTriggers() -> [(view: UIView, fire: () -> Void)] { [] }

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

    /// The control view that owns the buttons a console has: the DS adds X, Y and Mic, the SNES
    /// adds X and Y, everything else uses the base set. One factory, because four call sites were
    /// each answering it separately and the skin picker's answer had already gone stale.
    static func make(for system: PresetSystem) -> TouchControlsView {
        switch system {
        case .nds:  return NDSTouchControlsView()
        case .snes: return SNESTouchControlsView()
        case .ps1:  return PS1TouchControlsView()
        case .gba, .gbc, .nes: return TouchControlsView()
        }
    }

    /// Which palette a console's dressed buttons wear. One place, because the two subclasses
    /// answered it separately and a fourth console would have had to be added three times.
    static func dressKind(for system: PresetSystem) -> DressKind {
        switch system {
        case .gba:  return .gba
        case .nds:  return .nds
        case .snes: return .snes
        case .nes:  return .nes
        case .ps1:  return .ps1
        case .gbc:  return .gbc
        }
    }

    func setDressed(_ on: Bool, isLandscape: Bool, system: PresetSystem,
                    variant: DressVariant = .nostalgia) {
        dressed = on
        dressVariant = variant
        // GB/GBC wear the DMG palette; GBA + NDS recolor the same shapes to their own palettes;
        // the SNES has its own (light body, dark pad, four coloured faces).
        let kind: DressKind = TouchControlsView.dressKind(for: system)
        btnA.dressVariant = variant; btnA.dressKind = kind; btnA.dressed = on
        btnB.dressVariant = variant; btnB.dressKind = kind; btnB.dressed = on
        // L/R shoulders (GBA + NDS — GB/GBC has none; theirs stay hidden so this is a no-op there).
        btnL.dressVariant = variant; btnL.dressKind = kind; btnL.dressed = on
        btnR.dressVariant = variant; btnR.dressKind = kind; btnR.dressed = on
        // SELECT/START: a diagonal pill in portrait, a horizontal top-stuck pill in landscape.
        let pillStyle: SmallButton.DressStyle = (isLandscape || kind.pillIsHorizontal) ? .pillTop : .pill
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
    /// - Parameter system: the console being laid out. `isNDS` still drives the
    ///   behaviours that really are about the DS page (clipping, the landscape
    ///   gutter fixes); `system` drives SIZING, which since the SNES arrived is a
    ///   per-element question: that console wears the DS's D-pad and diamond and
    ///   the Game Boy's SELECT/START.
    func applyLayout(_ layout: OrientationLayout, isLandscape: Bool, isNDS: Bool,
                     system: PresetSystem = .gba,
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
                element, system: system, isLandscape: isLandscape, deviceScale: deviceScale)

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
            (view as? SmallButton)?.dressScale = deviceScale
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
                            safeLeftInset: CGFloat = 0, safeRightInset: CGFloat = 0) {
        let isNDS = (system == .nds)
        var layout = ControlLayoutDefaults.defaultLayout(
            system: system, isLandscape: isLandscape, containerSize: bounds.size,
            scale: deviceScale, safeLeftInset: safeLeftInset, safeRightInset: safeRightInset)
        let globals = Self.globalOpacityScale()
        // The built-in default layout uses the global Settings choices.
        let useJoystick = UserDefaults.standard.bool(forKey: "useJoystick")
        // Clip-button visibility: global toggle, default ON. Custom presets are
        // unaffected (each carries its own btnClip.isHidden, set in the editor).
        let showClip = UserDefaults.standard.object(forKey: "showClipButton") as? Bool ?? true
        if !showClip {
            layout.buttons[ControlElement.btnClip.rawValue]?.isHidden = true
        }
        applyLayout(layout, isLandscape: isLandscape, isNDS: isNDS, system: system,
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
            releaseAllInputs()   // drop any current touch / lock / stick state
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
        if padClaims(point) { return true }
        return anotherControlClaims(point)
    }

    /// The pad's own claim: its bounds grown by 20pt, which is what makes a thumb that lands
    /// just off the cross still steer.
    private func padClaims(_ point: CGPoint) -> Bool {
        guard !dpad.isHidden, dpad.alpha > 0.01 else { return false }
        return dpad.bounds.insetBy(dx: -20, dy: -20).contains(convert(point, to: dpad))
    }

    /// Every control EXCEPT the pad, with the same forgiving hitboxes the input layer uses.
    ///
    /// Split out because the pad's 20pt margin has to yield to it. Inside the pad's own bounds
    /// nothing else can be hit — controls do not overlap — so the only place the two answers
    /// differ is that margin, and there a real button must win: a touch claimed by the pad is
    /// excluded from every button test for as long as it lasts, so the margin swallowing a
    /// corner of MENU does not merely add a direction, it makes MENU stop responding.
    private func anotherControlClaims(_ point: CGPoint) -> Bool {
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
        // Taps and self-hit-testing controls. Neither lives in `buttonMap`, and
        // both are still controls: a claim test that does not know them lets a
        // press on the PlayStation's ANALOG switch, or on either of its sticks,
        // fall through to the screen behind.
        for trigger in tapTriggers() where !trigger.view.isHidden && trigger.view.alpha > 0.01 {
            if trigger.view.bounds.insetBy(dx: -10, dy: -10)
                .contains(convert(point, to: trigger.view)) { return true }
        }
        for view in extraClaimingViews() where !view.isHidden && view.alpha > 0.01 {
            if view.bounds.contains(convert(point, to: view)) { return true }
        }
        // Hold buttons claim their touches too. A press that falls through
        // while the finger waits out the hold would reach the screen behind,
        // which on a pass-through layout is the game.
        for trigger in holdTriggers() where !trigger.view.isHidden && trigger.view.alpha > 0.01 {
            if trigger.view.bounds.contains(convert(point, to: trigger.view)) { return true }
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
            // The pad's 20pt margin yields to a control the touch actually lands on. Reported on
            // the NES, whose taller picture brings MENU down close to the pad: tapping MENU's
            // bottom-left corner steered instead, and because a claimed finger is excluded from
            // every button test for its whole life, MENU did not merely also fire — it stopped
            // working. Inside the pad's own bounds no other control can be hit, so this changes
            // nothing except where the margin was taking something that was not its own.
            let point = touch.location(in: self)
            if dpadTouch == nil, padClaims(point), !anotherControlClaims(point) {
                dpadTouch = touch
            }
        }
        startLockTrackersIfNeeded(touches)
        startHoldTrackersIfNeeded(touches)
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
        finishHoldTrackers(touches)
        updateButtons(for: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch === dpadTouch { dpadTouch = nil }
        }
        cancelLockTrackers(touches)
        finishHoldTrackers(touches)
        updateButtons(for: event)
    }

    // MARK: - Button-Lock Gesture (long-press to lock, tap to unlock)

    // MARK: - Hold-to-press (the PlayStation's stick clicks)

    private func startHoldTrackersIfNeeded(_ touches: Set<UITouch>) {
        let triggers = holdTriggers()
        guard !triggers.isEmpty else { return }
        for touch in touches {
            let point = touch.location(in: self)
            for (view, mask) in triggers where !view.isHidden && view.alpha > 0.01 {
                guard view.bounds.contains(convert(point, to: view)) else { continue }
                let ring = makeLockRing(for: view)
                view.layer.addSublayer(ring)
                pendingHolds[ObjectIdentifier(touch)] = PendingHold(
                    view: view, buttonMask: mask,
                    startTime: CACurrentMediaTime(), ringLayer: ring)
                startLockDisplayLinkIfNeeded()
                break   // one tracker per touch
            }
        }
    }

    /// The finger lifted. Whether the hold had completed or not, everything it
    /// was doing stops: a half-finished hold leaves no bit set, which is the
    /// point of the gesture.
    private func finishHoldTrackers(_ touches: Set<UITouch>) {
        guard !pendingHolds.isEmpty || heldButtons != 0 else { return }
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if let pending = pendingHolds.removeValue(forKey: id) {
                fadeAndRemoveRing(pending.ringLayer)
            }
            if let mask = completedHolds.removeValue(forKey: id) {
                heldButtons &= ~mask
            }
        }
        stopLockDisplayLinkIfIdle()
    }

    fileprivate func holdDisplayLinkTick(now: CFTimeInterval) {
        guard !pendingHolds.isEmpty else { return }
        var completed: [ObjectIdentifier] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, pending) in pendingHolds {
            let progress = min((now - pending.startTime) / Self.stickClickHoldDuration, 1.0)
            pending.ringLayer.strokeEnd = CGFloat(progress)
            if progress >= 1.0 { completed.append(id) }
        }
        CATransaction.commit()
        for id in completed {
            guard let pending = pendingHolds.removeValue(forKey: id) else { continue }
            completedHolds[id] = pending.buttonMask
            heldButtons |= pending.buttonMask
            (pending.view as? SmallButton)?.flashPress()
            fireHaptic()
            fadeAndRemoveRing(pending.ringLayer)
            // Push it out now: the finger is still and will generate no further
            // touch events, so nothing else would report this press.
            applyButtons(lastRawButtons)
        }
    }

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
        // One link drives both gestures. They are independent -- a hold can be
        // in flight with no lock pending -- so the holds tick FIRST and the
        // early return below only decides whether the lock half has work.
        let now = CACurrentMediaTime()
        holdDisplayLinkTick(now: now)
        guard !pendingLocks.isEmpty else {
            stopLockDisplayLinkIfIdle()
            return
        }
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
        guard pendingLocks.isEmpty, pendingHolds.isEmpty else { return }
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

            // Controls a subclass reports as TAPS rather than as pressed
            // buttons. Only on `.began`, unlike MENU and CLIP above: those are
            // idempotent (the menu is already open), while a toggle fired again
            // on every `.moved` would flip back and forth under a resting thumb.
            for trigger in tapTriggers() where !trigger.view.isHidden && trigger.view.alpha > 0.01 {
                guard touch.phase == .began else { continue }
                let local = convert(point, to: trigger.view)
                if trigger.view.bounds.insetBy(dx: -10, dy: -10).contains(local) {
                    fireHaptic()
                    (trigger.view as? SmallButton)?.flashPress()
                    trigger.fire()
                }
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
        let augmented = controllerModeActive ? 0 : (buttons | lockedButtons | heldButtons)

        // Haptic only on new *physical* presses, and skip buttons that are already
        // locked (silent re-press of a locked button — already pressed visually).
        let newlyPressedRaw = buttons & ~lastRawButtons & ~lockedButtons & ~heldButtons
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
    case gbc, gba, nds, snes, nes, ps1

    static let gbaButton        = UIColor(red: 0.769, green: 0.749, blue: 0.812, alpha: 1) // #C4BFCF
    static let gbaButtonPressed = UIColor(red: 0.640, green: 0.620, blue: 0.680, alpha: 1)
    static let gbaButtonEdge    = UIColor(red: 0.560, green: 0.540, blue: 0.600, alpha: 1)
    static let gbaSurround      = UIColor(red: 0.055, green: 0.055, blue: 0.063, alpha: 1) // #0E0E10

    // NDS palette: buttons #EBEBEB, ink #777777 (labels, icons, D-pad lines, under-discs).
    static let ndsButton        = UIColor(red: 0.922, green: 0.922, blue: 0.922, alpha: 1) // #EBEBEB
    static let ndsButtonPressed = UIColor(red: 0.820, green: 0.820, blue: 0.820, alpha: 1)
    static let ndsButtonEdge    = UIColor(red: 0.760, green: 0.760, blue: 0.760, alpha: 1)
    static let ndsInk           = UIColor(red: 0.467, green: 0.467, blue: 0.467, alpha: 1) // #777777

    // SNES palette (spec of 2026-08-12). The console is the first one whose four face
    // buttons are four DIFFERENT colours, so those live per button (see ActionButton.dressFace)
    // rather than in a single `faceFill`: what `faceFill` answers here is the SHOULDERS, which
    // are the body colour with dark letters, exactly like the real pad.
    static let snesBody   = UIColor(red: 0.843, green: 0.827, blue: 0.812, alpha: 1) // #D7D3CF
    static let snesDark   = UIColor(red: 0.149, green: 0.149, blue: 0.157, alpha: 1) // #262628
    static let snesA      = UIColor(red: 0.812, green: 0.208, blue: 0.180, alpha: 1) // #CF352E
    static let snesB      = UIColor(red: 0.937, green: 0.769, blue: 0.275, alpha: 1) // #EFC446
    static let snesX      = UIColor(red: 0.161, green: 0.251, blue: 0.569, alpha: 1) // #294091
    static let snesY      = UIColor(red: 0.212, green: 0.408, blue: 0.251, alpha: 1) // #366840

    // NES palette, taken from the console art this app already ships (the Appearance button's
    // icon, the `console-nes` imageset) so the drawing and the dress cannot describe the
    // same machine differently. Body is the pad's light grey, the cross and the two pills are
    // the same near-black the Super Nintendo uses (both consoles really do print them black),
    // A and B are the red the stripe uses, and the WELL is the darker panel those buttons are
    // recessed into — the detail that makes this pad unmistakable at a glance.
    static let nesBody = UIColor(red: 0.098, green: 0.102, blue: 0.110, alpha: 1) // #191A1C
    static let nesFace = UIColor(red: 0.522, green: 0.149, blue: 0.129, alpha: 1) // #852621
    static let nesPad  = UIColor(red: 0.039, green: 0.039, blue: 0.039, alpha: 1) // #0A0A0A
    static let nesWell = UIColor(red: 0.651, green: 0.631, blue: 0.659, alpha: 1) // #A6A1A8
    static let nesSurround = UIColor(red: 0.804, green: 0.800, blue: 0.820, alpha: 1) // #CDCCD1

    // PlayStation palette. The console this app has that is closest to the SNES in
    // shape and furthest from it in colour logic: the Super Nintendo colours the
    // BUTTONS, while the PlayStation leaves all four the same warm grey as the pad
    // and colours only the SYMBOL printed on them. So `ps1Face` answers for every
    // face button and the four values below are LABEL colours, which is why they
    // are not called `ps1A` and so on.
    static let ps1Body     = UIColor(rpHex: 0xBEBEBC)   // the shell, and every unpainted surface
    /// EVERY CONTROL IS THIS ONE DARK, which is the colour logic of this pad and
    /// the reason its four face buttons are not four colours: the cross's
    /// arrows, both stick dishes, the four faces' own plastic, all four
    /// shoulders, ANALOG, SELECT, START and the MENU / CLIP seats are one tone,
    /// and what distinguishes the faces is the symbol PRINTED on them.
    static let ps1Dark     = UIColor(rpHex: 0x404145)
    /// The face buttons are that same dark, so this is an alias and not a
    /// second decision. It stays a separate name because every other console
    /// here means something different by "face" and the call sites read better
    /// asking for the one they mean.
    static let ps1Face     = ps1Dark
    /// The screen panel. Derived from the shell rather than given, so a custom
    /// skin that repaints the body keeps its panel a shade of the same plastic.
    // BLACK, on both dresses. It is the frame around the picture, and a frame
    // that is a shade of the shell competes with the picture for the eye; black
    // steps back and lets the screen be the brightest thing on the page. It is
    // also what the console's own bezel does.
    static let ps1Surround = UIColor(rpHex: 0x000000)
    // The four printed symbols. PASTEL, and that is the hardware: they are inks
    // on grey plastic, not coloured buttons, so they are far softer than the
    // saturated versions the console ICON uses. The icon is 36pt and needs
    // punch; a control under a thumb does not, and the real pad is pale.
    static let ps1Triangle = UIColor(rpHex: 0xC0EAE8)
    static let ps1Circle   = UIColor(rpHex: 0xD7A59D)
    static let ps1Cross    = UIColor(rpHex: 0xC0D2F4)
    static let ps1Square   = UIColor(rpHex: 0xDDB9D3)

    /// The "modern recolor" family: a light face with a dark ink accent (GBA, NDS). This used to
    /// be written inline as `dressKind != .gbc` in every button view; it is named here because the
    /// SNES is neither family — light shoulders like the GBA, a dark pad and dark SELECT/START
    /// like the Game Boy, and four coloured faces that are like nothing else. Every `!= .gbc` in
    /// the views now asks this instead, which is the same answer for gbc / gba / nds.
    /// The "modern recolor" family: a light face with a dark ink accent.
    ///
    /// NOT the PlayStation, though it was listed here first. Its faces are the
    /// same near-black as everything else it has, and being in this family cost
    /// three things at once: SELECT and START rendered as the GBA's tiny circle
    /// instead of a real pill, the label branch sent its four printed symbols to
    /// the GBA's grey ink, and the cross drew the arm lines this console's pad
    /// does not have.
    var usesLightFaces: Bool { self == .gba || self == .nds }

    /// Whether SELECT/START render as the tiny circle beside a skin-drawn pill (GBA, NDS) or as
    /// the pill itself (GB/GBC, SNES).
    var selectIsTinyCircle: Bool { usesLightFaces }

    /// How much of the hitbox the visible SELECT/START pill spans. The Super Nintendo's pair are
    /// short studs rather than the Game Boy's long capsules, so they draw at half the length
    /// (2026-08-17) while the hitbox, the tilt and the printed word are untouched.
    var pillLengthRatio: CGFloat { self == .snes ? 0.5 : 1 }

    /// Whether SELECT and START are drawn straight in PORTRAIT too. The Game Boy family prints
    /// them on a diagonal and this console does not: its pair are two straight black pills side
    /// by side in one well, which is also why they keep their full length.
    var pillIsHorizontal: Bool { self == .nes }

    /// The NES prints SELECT and START ABOVE their pills, so what the eye reads is the PAIR —
    /// word, gap, pill — and it is the pair, not the pill, that has to sit in the middle of the
    /// well the dress carves around the two hitboxes. Centring the pill alone left the pair
    /// hanging in the top of its panel, which is what it looked like on device.
    ///
    /// These three numbers are the printed word's own metrics, in reference points, and they live
    /// here because the BUTTON draws the pill while the DRESS prints the word and carves the
    /// well: neither side can tell alone that they have stopped agreeing.
    static let nesPrintedSize: CGFloat = 8
    static let nesPrintedKern: CGFloat = 0.6
    /// The gap between the printed word and the pill, which is the well's own padding.
    static let nesPrintedGap: CGFloat = 9

    static func nesPrintedHeight(scale: CGFloat) -> CGFloat {
        NSAttributedString(string: "SELECT", attributes: [
            .font: UIFont.systemFont(ofSize: nesPrintedSize * scale, weight: .semibold),
            .kern: nesPrintedKern * scale,
        ]).size().height
    }

    /// Where the horizontal pill's centre goes inside its hitbox: the upper third on the Game Boy
    /// family (its landscape stud, unchanged), and on the NES the y that leaves word + gap + pill
    /// centred on the hitbox — which is the well's centre, since the well is that hitbox padded
    /// evenly. `scale` is the device scale, because the printed word scales with it.
    func pillCenterY(in bounds: CGRect, scale: CGFloat) -> CGFloat {
        guard self == .nes else { return bounds.minY + bounds.height / 3 }
        return bounds.midY
            + (DressKind.nesPrintedHeight(scale: scale) + DressKind.nesPrintedGap * scale) / 2
    }

    /// The NES's screen panel keeps this much body above AND below the picture, and the two are
    /// equal because the panel is symmetric about it. Shared with the LAYOUT, not just the dress:
    /// in portrait the controls container starts exactly at the picture's bottom edge, so this
    /// skirt is also the distance from the top of that container down to the panel's lower edge —
    /// which is the top of the band MENU and CLIP sit in.
    static let nesPanelSkirt: CGFloat = 18

    /// Half the padding the NES's sunken wells add around the buttons they hold. The well around
    /// A and B is a capsule stroked along the segment between their centres, so this is what
    /// stands between the buttons and the well's own edge.
    static let nesWellPad: CGFloat = 9

    /// The thickness of the capsule well the NES draws around A and B: the larger of the two
    /// buttons, padded on both sides.
    static func nesFaceWellThickness(a: CGRect, b: CGRect, scale: CGFloat) -> CGFloat {
        max(min(a.width, a.height), min(b.width, b.height)) + 2 * nesWellPad * scale
    }

    /// The top edge of that well. The capsule has round caps on the two button centres, so its
    /// highest point is the higher centre raised by half the thickness — the buttons sit on a
    /// diagonal, and it is the WELL's edge the eye reads, never the buttons'.
    ///
    /// Lives here because the DRESS draws the well and the LAYOUT places MENU and CLIP against
    /// it, and neither side can tell on its own that they have stopped agreeing.
    static func nesFaceWellTop(a: CGRect, b: CGRect, scale: CGFloat) -> CGFloat {
        Swift.min(a.midY, b.midY) - nesFaceWellThickness(a: a, b: b, scale: scale) / 2
    }

    /// The line the Retro Pal plaque and CLIP share on the SNES's landscape page: centred in the
    /// band between the shoulder's bottom edge and the top of the pad's up arm.
    ///
    /// Named rather than written twice for the same reason as `pillCenterY`: the plaque is drawn
    /// by the DRESS and CLIP is placed by the LAYOUT, and "the same vertical position" is a
    /// promise only a shared formula can keep.
    static func snesLandscapeUtilityCenterY(shoulderBottom: CGFloat, padTop: CGFloat) -> CGFloat {
        (shoulderBottom + padTop) / 2
    }

    /// The pill's two endpoints inside a hitbox, shared by the BUTTON (which draws the pill) and
    /// the DRESS (which carves its seat), because the two have to line up and there is no way to
    /// notice they stopped from either side alone.
    ///
    /// Portrait runs the hitbox's bottom-left to top-right diagonal, landscape a horizontal line
    /// across `centerY` (see `pillCenterY`). Both are inset by half the thickness so the round
    /// caps land inside the box, then shortened about their own midpoint, which keeps the centre
    /// and the angle.
    static func pillEndpoints(in bounds: CGRect, thickness t: CGFloat, isLandscape: Bool,
                              lengthRatio: CGFloat, centerY: CGFloat? = nil) -> (CGPoint, CGPoint) {
        let p1: CGPoint, p2: CGPoint
        if isLandscape {
            let y = centerY ?? (bounds.minY + bounds.height / 3)
            p1 = CGPoint(x: bounds.minX + t / 2, y: y)
            p2 = CGPoint(x: bounds.maxX - t / 2, y: y)
        } else {
            let dx = bounds.width, dy = -bounds.height
            let len = max(1, hypot(dx, dy))
            let inset = t / 2
            p1 = CGPoint(x: bounds.minX + dx / len * inset, y: bounds.maxY + dy / len * inset)
            p2 = CGPoint(x: bounds.maxX - dx / len * inset, y: bounds.minY - dy / len * inset)
        }
        guard lengthRatio < 1 else { return (p1, p2) }
        let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
        func pull(_ p: CGPoint) -> CGPoint {
            CGPoint(x: mid.x + (p.x - mid.x) * lengthRatio, y: mid.y + (p.y - mid.y) * lengthRatio)
        }
        return (pull(p1), pull(p2))
    }

    /// The dressed directional pad's fill when it is NOT a light cross: charcoal on the Game Boy,
    /// the SNES's near-black. (Read only in the dark branch, so the light consoles never see it.)
    var darkPadFill: UIColor {
        switch self {
        case .snes: return DressKind.snesDark
        case .nes:  return DressKind.nesPad
        case .ps1:  return DressKind.ps1Dark
        default: return UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
        }
    }
    var darkPadEdge: UIColor {
        switch self {
        case .snes: return DressKind.snesDark.rpEdge
        // The cross is near-black on a near-black shell, so its edge is the STROKE colour: the
        // outline is what separates the two, and it is a specified colour rather than a derived
        // one for exactly that reason.
        case .nes:  return DressKind.nesWell
        case .ps1:  return DressKind.ps1Dark.rpEdge
        default: return UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        }
    }

    /// SELECT / START (and the GB/GBC MENU/CLIP background): the Game Boy's grey, the SNES's
    /// near-black pills, or the light face for the modern pair. Pressed and edge are given
    /// explicitly rather than derived, because the Game Boy's three greys were hand-picked and
    /// deriving them would have shifted a shipped console by a few percent.
    var smallButtonFill: UIColor {
        switch self {
        case .gbc:  return DressKind.gbcSmall
        case .snes: return DressKind.snesDark
        case .nes:  return DressKind.nesPad
        // SELECT and START are the same grey plastic as everything else on this
        // pad; only the printing tells them apart.
        case .ps1:  return DressKind.ps1Face
        case .gba, .nds: return faceFill
        }
    }
    var smallButtonPressed: UIColor {
        switch self {
        case .gbc:  return DressKind.gbcSmallPressed
        case .snes: return DressKind.snesDark.rpPressed
        case .nes:  return DressKind.nesPad.rpMixed(with: .white, 0.18)
        case .ps1:  return DressKind.ps1Face.rpPressed
        case .gba, .nds: return facePressed
        }
    }
    var smallButtonEdge: UIColor {
        switch self {
        case .gbc:  return DressKind.gbcSmallEdge
        case .snes: return DressKind.snesDark.rpEdge
        case .nes:  return DressKind.nesPad.rpMixed(with: .white, 0.10)
        case .ps1:  return DressKind.ps1Face.rpEdge
        case .gba, .nds: return faceEdge
        }
    }

    // The Game Boy's SELECT/START greys, moved here verbatim from SmallButton so every console
    // answers the same question in the same place.
    static let gbcSmall        = UIColor(red: 0.30, green: 0.30, blue: 0.31, alpha: 1)
    static let gbcSmallPressed = UIColor(red: 0.22, green: 0.22, blue: 0.23, alpha: 1)
    static let gbcSmallEdge    = UIColor(red: 0.18, green: 0.18, blue: 0.19, alpha: 1)

    /// The MENU / CLIP glyph inside its round background. The SNES's is the body lavender on the
    /// near-black circle: the same colour on both would be an invisible icon.
    var circleGlyph: UIColor {
        switch self {
        case .gbc:  return UIColor.white.withAlphaComponent(0.85)
        case .snes: return DressKind.snesBody
        // The NES's MENU/CLIP sit on its near-black pill colour, so the glyph is the light
        // grey its wells and its cross outline use.
        case .nes:  return DressKind.nesWell
        case .ps1:  return DressKind.ps1Dark
        case .gba, .nds: return faceInk
        }
    }

    /// The SNES's screen surround, and the ring the four face buttons sit in. Lives here rather
    /// than only in the dress because the MENU and CLIP glyphs borrow it: it is the darkest tone
    /// on the console that is not the pad, so it reads on a light button without looking like a
    /// fifth face colour.
    static let snesSurround = UIColor(red: 0.427, green: 0.427, blue: 0.427, alpha: 1) // #6D6D6D

    /// The "modern recolor" dresses (GBA, NDS) share button shapes + a light fill with a dark ink
    /// accent; only the tokens differ. Not meaningful for `.gbc` (its views keep maroon/charcoal/grey).
    var faceFill: UIColor {
        switch self {
        case .nds:  return DressKind.ndsButton
        case .snes: return DressKind.snesBody
        // The NES's A and B ARE one colour, so unlike the Super Nintendo it needs no per-button
        // override: the console's own face fill answers for both.
        case .nes:  return DressKind.nesFace
        // All four faces, and the shoulders. The colour is on the SYMBOL, which
        // PS1TouchControlsView paints per button through `dressFaceLabel`.
        case .ps1:  return DressKind.ps1Face
        case .gbc, .gba: return DressKind.gbaButton
        }
    }
    var facePressed: UIColor {
        switch self {
        case .nds:  return DressKind.ndsButtonPressed
        case .snes: return DressKind.snesBody.rpPressed
        case .nes:  return DressKind.nesFace.rpPressed
        case .ps1:  return DressKind.ps1Face.rpPressed
        case .gbc, .gba: return DressKind.gbaButtonPressed
        }
    }
    var faceEdge: UIColor {
        switch self {
        case .nds:  return DressKind.ndsButtonEdge
        case .snes: return DressKind.snesBody.rpEdge
        case .nes:  return DressKind.nesFace.rpEdge
        case .ps1:  return DressKind.ps1Face.rpEdge
        case .gbc, .gba: return DressKind.gbaButtonEdge
        }
    }
    var faceInk: UIColor {
        switch self {
        case .nds:  return DressKind.ndsInk
        case .snes: return DressKind.snesDark
        case .nes:  return DressKind.nesWell
        // Darker than the plate it is cut into, because on this console the
        // plate IS `ps1Dark`: returning that would print a shoulder's word in
        // exactly its own background.
        case .ps1:  return DressKind.ps1Dark.rpMixed(with: .black, 0.34)
        case .gbc, .gba: return DressKind.gbaSurround
        }
    }
}

/// The "bombé": the shading that turns a flat fill into something domed.
///
/// One light direction for the whole console, from the TOP RIGHT, because a
/// page lit from two directions reads as a mistake rather than as two materials.
/// It is a gradient clipped to the shape, so a circle domes as a sphere and a
/// rectangle as a pillow without either knowing about the other.
///
/// Lives here rather than in each button class because there are four of them
/// and they would otherwise disagree by a hundredth of an alpha.
enum Bombe {
    static func make() -> CAGradientLayer {
        let g = CAGradientLayer()
        // The lit side is the strong one. It carries the whole read of a domed
        // surface, and at parity with the shadow the shape stayed flat.
        g.colors = [UIColor.white.withAlphaComponent(0.38).cgColor,
                    UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.20).cgColor]
        g.locations = [0, 0.5, 1]
        g.startPoint = CGPoint(x: 1, y: 0)
        g.endPoint = CGPoint(x: 0, y: 1)
        g.isHidden = true
        return g
    }

    /// Fit `dome` to `bounds` and clip it to a rounded rect. `corner` of nil
    /// means a full oval, which is what a face button wants.
    static func fit(_ dome: CAGradientLayer, to bounds: CGRect, corner: CGFloat?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dome.frame = bounds
        let mask = CAShapeLayer()
        let local = CGRect(origin: .zero, size: bounds.size)
        mask.path = corner.map { UIBezierPath(roundedRect: local, cornerRadius: $0).cgPath }
            ?? UIBezierPath(ovalIn: local).cgPath
        dome.mask = mask
        CATransaction.commit()
    }

    /// Fit `dome` over a view's whole bounds but clip it to an arbitrary shape
    /// given in that view's own coordinates. The small buttons need this: their
    /// visible shape is a rectangle or a triangle drawn inside a hitbox that is
    /// larger than it, so doming the hitbox would light up empty space.
    static func fit(_ dome: CAGradientLayer, over bounds: CGRect, clippedTo path: CGPath) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dome.frame = bounds
        let mask = CAShapeLayer()
        mask.path = path
        dome.mask = mask
        CATransaction.commit()
    }

    // MARK: The core — the bombé's second layer

    /// How much smaller the core is than the shape it sits in. "Almost the same
    /// size": a tenth, so what shows of the outer layer is a thin rim.
    static let coreInset: CGFloat = 0.10

    /// The SECOND layer of the bombé: the same shape again, a tenth smaller and
    /// CONCENTRIC, carrying a gradient that runs from nothing at the top right
    /// to black at the bottom left.
    ///
    /// Why two layers rather than one stronger gradient. A single gradient
    /// shades a flat shape; it never gives it an EDGE. A concentric second copy
    /// leaves an even rim of the lighter layer showing all the way round, and
    /// the shading inside that rim is what reads as the surface falling away.
    /// The light direction has to agree with `make()` above: both run top-right
    /// to bottom-left, so the two darken together instead of fighting.
    static func makeCore() -> CAGradientLayer {
        let g = CAGradientLayer()
        // CLEAR at the top right, not a pale black: the top right has to be the
        // background colour exactly, so the core disappears into the layer under
        // it there and only darkens as it falls to the bottom left. Any tint at
        // the light end draws a visible edge where the two layers meet.
        g.colors = [UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.34).cgColor]
        g.locations = [0, 1]
        g.startPoint = CGPoint(x: 1, y: 0)
        g.endPoint = CGPoint(x: 0, y: 1)
        g.isHidden = true
        return g
    }

    /// Fit `core` over `bounds`, clipped to `path` shrunk about its own centre.
    ///
    /// Any shape at all: the transform is applied to whatever path it is handed,
    /// so a triangle domes as a triangle and a bar as a bar.
    static func fitCore(_ core: CAGradientLayer, over bounds: CGRect, clippedTo path: CGPath) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        core.frame = bounds
        let mask = CAShapeLayer()
        mask.path = coredPath(UIBezierPath(cgPath: path)).cgPath
        core.mask = mask
        CATransaction.commit()
    }

    /// One shape's core: the same outline shrunk about its own centre.
    ///
    /// Exposed on its own because a control made of SEVERAL shapes has to core
    /// each one separately. The cross is the case: cored as one path its four
    /// keys would shrink toward the pad's own middle together, which domes the
    /// cross rather than the keys. Per key, each domes about its own centre,
    /// exactly as a face button does.
    static func coredPath(_ path: UIBezierPath) -> UIBezierPath {
        let box = path.cgPath.boundingBox
        guard box.width > 0, box.height > 0 else { return path }
        // AN EQUAL MARGIN IN POINTS on all four sides, not an equal fraction.
        // A uniform scale takes `coreInset` of each axis, which on a circle is
        // the same thing but on a BAR is a wide margin at the ends and a thin
        // one along the top and bottom -- the rim then looks like a mistake
        // rather than like the edge of something domed. The margin is set by the
        // SHORTER side, so the tight axis keeps the proportion it had.
        let d = min(box.width, box.height) * coreInset / 2
        let sx = max(0, box.width - d * 2) / box.width
        let sy = max(0, box.height - d * 2) / box.height
        var t = CGAffineTransform(translationX: box.midX, y: box.midY)
            .scaledBy(x: sx, y: sy)
            .translatedBy(x: -box.midX, y: -box.midY)
        return UIBezierPath(cgPath: path.cgPath.copy(using: &t) ?? path.cgPath)
    }
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
    /// Ported from `AnalogStickView` 2026-08-27 so the joystick alternative
    /// wears the same look as the PlayStation's sticks, in each console's own
    /// colours. Deliberately a COPY of those three layers rather than a shared
    /// renderer: extracting one would refactor a control class six consoles
    /// depend on and which is device-verified, to save about fifty lines.
    /// If a third stick-shaped control ever appears, extract it then.
    private let holeLayer = CAShapeLayer()
    private let thumbDome = CAGradientLayer()
    private let thumbGrain = CALayer()
    private let thumbRadius: CGFloat = 20

    /// How far past the cap the black hole shows, as a fraction of the radius.
    /// Same value the PlayStation stick uses.
    private let holeExcess: CGFloat = 0.07

    /// A stick is SMALLER than the cross it replaces, and the number is taken
    /// from this app's own layout rather than chosen: a PlayStation stick is
    /// 90pt where its cross is 165 (`ControlLayoutModels.size`), and the
    /// comment there says the 90 is not a taste, it is what fits the lane.
    ///
    /// Mirroring that ratio is the whole point. The first version of this made
    /// the cap fill the control, which is correct on the PlayStation only
    /// because a stick's FRAME is already stick-sized there. Dropped into a
    /// d-pad's much larger frame it produced a joystick the size of a d-pad.
    private static let stickToCrossRatio: CGFloat = 90.0 / 165.0

    /// The cap's radius. Dressed it is the PlayStation stick's proportion of
    /// the control; undressed it is the small knob the custom presets have
    /// always drawn, untouched.
    private var effectiveThumbRadius: CGFloat {
        dressed ? min(bounds.width, bounds.height) / 2 * Self.stickToCrossRatio
                : thumbRadius
    }

    /// How far the cap is DRAWN from centre at full push.
    ///
    /// ⚠ THIS IS DRAWING ONLY. The direction the game receives is computed by
    /// `TouchControlsView` from the pad's own centre and never reads this, so
    /// nothing here changes how hard the player has to push or which way the
    /// character walks.
    ///
    /// Dressed it is the cap's own radius, so the cap's trailing edge arrives
    /// exactly on the STICK's centre and no further: the largest move that
    /// still leaves the seat covered, and the same rule the PlayStation stick
    /// follows. Undressed it is the old rule, the room left between the knob
    /// and the ring.
    private var drawnTravel: CGFloat {
        dressed ? effectiveThumbRadius
                : min(bounds.width, bounds.height) / 2 - effectiveThumbRadius
    }

    private var thumbOffset: CGPoint = .zero

    // The dark thumb colour (GB/GBC charcoal, SNES near-black) comes from DressKind, so the
    // joystick and the cross cannot drift apart.

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
            // The hole is the shell, not the control: it does not move with the
            // cap, and it is what reads as the seat now the cap fills the frame.
            holeLayer.isHidden = false
            thumbDome.isHidden = false
            thumbGrain.isHidden = false
            // The face colour stays `dpadFace`. This control replaces the
            // D-PAD, so it takes the d-pad's ink on every console rather than
            // the shoulder tone the PlayStation stick borrows from its own pad.
            let rp = dressVariant.dpadFace(dressKind)
            if dressKind.usesLightFaces {
                thumbLayer.fillColor = (rp ?? dressKind.faceFill).cgColor
                thumbLayer.strokeColor = (rp?.rpEdge ?? dressKind.faceEdge).cgColor
            } else {
                thumbLayer.fillColor = (rp ?? dressKind.darkPadFill).cgColor
                thumbLayer.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
            }
            thumbDome.colors = [UIColor.white.withAlphaComponent(0.22).cgColor,
                                UIColor.clear.cgColor,
                                UIColor.black.withAlphaComponent(0.22).cgColor]
            thumbDome.locations = [0, 0.5, 1]
        } else {
            holeLayer.isHidden = true
            thumbDome.isHidden = true
            thumbGrain.isHidden = true
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

        // The hole sits UNDER the cap and above the ring, so the cap moves
        // across it rather than out of it.
        holeLayer.fillColor = UIColor.black.cgColor
        holeLayer.isHidden = true
        layer.addSublayer(holeLayer)

        // Inner thumb
        thumbLayer.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
        thumbLayer.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        thumbLayer.lineWidth = 1.5
        layer.addSublayer(thumbLayer)

        // Dome and grain ride ON the cap, clipped to it in updateThumbPosition,
        // so the light stays on the knob instead of washing the seat.
        // Light from the top right, shadow at the bottom left: the same
        // direction the PlayStation stick is lit from, and the same one every
        // dressed control in this app uses. A stick lit from a different angle
        // than the shell around it is the one thing that reads as pasted on.
        thumbDome.startPoint = CGPoint(x: 1, y: 0)
        thumbDome.endPoint = CGPoint(x: 0, y: 1)
        thumbDome.isHidden = true
        layer.addSublayer(thumbDome)

        thumbGrain.backgroundColor = UIColor(patternImage: GameBoySkin.grain).cgColor
        thumbGrain.opacity = 0.5
        thumbGrain.isHidden = true
        layer.addSublayer(thumbGrain)
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

        // Sized to the STICK, not to the control: the seat is the hole the
        // stick sits in, so a d-pad-wide black disc behind a stick-sized cap
        // would be a hole the hardware does not have.
        holeLayer.path = UIBezierPath(
            arcCenter: center,
            radius: max(effectiveThumbRadius * (1 + holeExcess), 1),
            startAngle: 0, endAngle: .pi * 2, clockwise: true
        ).cgPath

        updateThumbPosition()
    }

    /// Called from touch handling to move the visual thumb
    func setThumbDirection(dx: CGFloat, dy: CGFloat, maxDistance: CGFloat) {
        let dist = sqrt(dx * dx + dy * dy)
        let clampedDist = min(dist, maxDistance)
        let reach = max(drawnTravel, 0)

        if dist > 0 {
            let scale = min(clampedDist / maxDistance, 1.0) * reach
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
        let r = effectiveThumbRadius
        thumbLayer.path = UIBezierPath(
            arcCenter: center, radius: r,
            startAngle: 0, endAngle: .pi * 2, clockwise: true
        ).cgPath
        guard dressed, r > 0 else { return }
        // No implicit animation: the cap has to arrive with the finger, and a
        // quarter-second dissolve on a control is read as lag, not polish.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let box = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let disc = UIBezierPath(ovalIn: CGRect(origin: .zero, size: box.size)).cgPath
        // Named `piece`, not `layer`: `layer` is this view's own, and shadowing
        // it inside the loop is how the wrong one gets masked one edit later.
        for piece in [thumbDome, thumbGrain] as [CALayer] {
            piece.frame = box
            let mask = CAShapeLayer()
            mask.path = disc
            piece.mask = mask
        }
        CATransaction.commit()
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
    /// A face colour for THIS button, overriding the console's shared one. The SNES is the first
    /// console here whose four faces are four different colours, so the colour cannot live on the
    /// console: A is red, B and X two blues, Y green. nil (every other console) = unchanged.
    var dressFace: UIColor? { didSet { applyResting() } }
    /// The letter's colour when `dressFace` is set (the SNES prints A/B/X/Y in the body lavender).
    var dressFaceLabel: UIColor? { didSet { applyResting() } }

    /// The PlayStation's four marks, DRAWN rather than typed.
    ///
    /// They were the unicode glyphs in a label, and a glyph cannot be sized to
    /// order: a typeface draws triangle and square on different optical bodies,
    /// so at one point size they come out visibly different widths and the
    /// triangle reads as the runt of the four. Four paths sharing ONE box is
    /// what makes "the same size for all four" a fact rather than a hope.
    enum PS1Symbol { case circle, cross, triangle, square }

    /// Which mark this face prints. `nil` on every other console, where the face
    /// carries a letter and the label does the work.
    var ps1Symbol: PS1Symbol? {
        didSet { guard ps1Symbol != oldValue else { return }; applyResting(); setNeedsLayout() }
    }
    private let symbolLayer = CAShapeLayer()

    /// Side of the box all four marks are drawn in, as a fraction of the
    /// button's RADIUS.
    ///
    /// Set from the square, which is the tightest of the four: a square
    /// inscribed in the bombé's inner circle has a side of `sqrt(2)` times that
    /// circle's radius, and this takes 94% of it so the corners come close to
    /// the rim without touching it. The other three then take the same box.
    static var ps1SymbolBox: CGFloat {
        (1 - Bombe.coreInset) * CGFloat(2).squareRoot() * 0.94 * 0.90
    }
    /// Nostalgia vs the Retro Pal recolour (set by setDressed).
    var dressVariant: DressVariant = .nostalgia { didSet { applyResting() } }
    // `dressFace` is asked FIRST, and the order is load-bearing. It is the per-BUTTON answer and
    // `abFace` is the per-CONSOLE one, so the specific has to win: the SNES's Retro Pal recolour
    // gives the console a fill for everything that is not a face button, and with the general
    // answer first that fill was painting over all four face colours. Every other console leaves
    // `dressFace` nil, so this order changes nothing for them.
    private var fillColor: UIColor {
        if let c = dressFace { return c }
        if let c = dressVariant.abFace(dressKind) { return c }
        return dressKind == .gbc ? Self.maroon : dressKind.faceFill
    }
    private var pressedColor: UIColor {
        if let c = dressFace { return c.rpPressed }
        if let c = dressVariant.abFace(dressKind) { return c.rpPressed }
        return dressKind == .gbc ? Self.maroonPressed : dressKind.facePressed
    }
    private var edgeColor: UIColor {
        if let c = dressFace { return c.rpEdge }
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
                    // COLOURS ONLY. This used to call `applyResting()`, which rebuilds the
                    // letter's attributed string — and setting `attributedText` invalidates the
                    // label's intrinsic content size, which marks the layout engine dirty, which
                    // runs a window layout pass, which reaches the view controller's
                    // viewDidLayoutSubviews and re-lays the whole game view. On every button
                    // release. With a preset active that pass re-resolves the entire scene, so
                    // the release of a face button was buying a full layout of the game on the
                    // same thread the emulator runs on.
                    //
                    // Reported as SNES lag "after releasing B, only with a preset, never on the
                    // D-pad", and each clause is this bug: the D-pad has no label to invalidate,
                    // only the release branch called applyResting, and only a preset makes the
                    // resulting layout pass expensive. The letter cannot have changed between a
                    // press and a release, so rebuilding it there was always waste.
                    self.applyRestingColors()
                    self.transform = self.restingTransform
                    self.layer.shadowOpacity = 0.3
                }
            }
        }
    }

    /// GBA-dressed A/B rest a touch smaller (98%, centred); every other state rests at full size.
    private var restingScale: CGFloat { (dressed && dressKind.usesLightFaces) ? 0.98 : 1.0 }
    var restingTransform: CGAffineTransform { baseTransform.scaledBy(x: restingScale, y: restingScale) }

    /// Resting (un-pressed) fill + border for the current `dressed` mode, plus the letter.
    /// Called when the DRESS changes; a press/release uses `applyRestingColors` instead, because
    /// the letter cannot have changed and rebuilding it is what dirties layout.
    private func applyResting() {
        applyRestingColors()
        applyLabelStyle()
        if !isPressed { transform = restingTransform }
    }

    /// The half of `applyResting` that a press or a release actually needs: fill and border.
    /// Nothing here touches the label, so nothing here invalidates an intrinsic content size.
    private func applyRestingColors() {
        backgroundColor = dressed ? fillColor : UIColor.white.withAlphaComponent(0.2)
        layer.borderColor = (dressed ? edgeColor : UIColor.white.withAlphaComponent(0.45)).cgColor
        sheen.isHidden = true   // A/B keep ONE flat background behind the letter (no top sheen)
        dome.isHidden = !(dressed && dressKind == .ps1)
        core.isHidden = dome.isHidden
    }

    /// The A/B letter. GBA dress = "creusé" (engraved): a darker glyph of the button's own family
    /// with a light catch directly beneath, so it reads as incised into the plastic. Otherwise the
    /// plain white label (GB/GBC keeps its DONE look; the undressed default is untouched).
    ///
    /// The SNES joins the engraved branch even though its faces are not light: its letter is its
    /// OWN button's colour darkened, so the same incised treatment is what the four coloured
    /// buttons want. `dressFaceLabel` carries that per-button ink (see `SNESTouchControlsView`).
    private func applyLabelStyle() {
        // The PlayStation reaches the FLAT branch below, which is the one that
        // honours `dressFaceLabel`: its four symbols are inks printed on
        // plastic, not letters cut into it. It gets there by not being in
        // `usesLightFaces`, so there is no test for it here.
        if dressed && (dressKind.usesLightFaces
                       || (dressKind == .snes && dressFaceLabel != nil)
                       || dressKind == .nes) {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.white.withAlphaComponent(0.5)
            shadow.shadowOffset = CGSize(width: 0, height: 1)
            shadow.shadowBlurRadius = 0.5
            // GBA engraves in its edge tone (custom: the letters slot); NDS in the #777777 ink
            // (custom: the ink slot; Retro Pal: also #777777).
            let labelInk: UIColor
            if dressKind == .snes, let perButton = dressFaceLabel {
                labelInk = perButton
            } else if dressKind == .nes {
                // One face colour, so the ink derives from it here rather than per button — and
                // it has to invert with it. Nostalgia's face is a deep red, where a darkened red
                // would be invisible and the light grey the rest of this console uses reads;
                // Retro Pal's is a pale lilac, where the opposite is true.
                let face = dressVariant.abFace(dressKind) ?? DressKind.nesFace
                labelInk = face.rpIsLight ? face.rpMixed(with: .black, 0.55) : DressKind.nesWell
            } else if dressKind == .nds {
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
            label.textColor = (dressed ? (dressVariant.gbcPalette?.abLetters ?? dressFaceLabel) : nil) ?? .white
            label.font = .systemFont(ofSize: 20, weight: .bold)
        }
        // THE PLAYSTATION DRAWS ITS MARK AND HIDES THE LABEL. Its four are
        // shapes rather than letters, so they are stroked paths in a shared box
        // (see `ps1Symbol`); the label would otherwise print the glyph a second
        // time, at a different size, on top of it.
        let drawn = dressed && dressKind == .ps1 && ps1Symbol != nil
        symbolLayer.isHidden = !drawn
        label.isHidden = drawn
        if drawn {
            symbolLayer.strokeColor = (dressFaceLabel ?? .white).cgColor
            setNeedsLayout()
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
    private let dome = Bombe.make()       // the PlayStation's bombé
    private let core = Bombe.makeCore()   // its second, offset layer
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

    /// Change the character on the button after it was built.
    ///
    /// It exists for the PlayStation, whose A and B are not letters: the base
    /// class creates them labelled "A" and "B", and on that pad they are the
    /// circle and the cross. Relabelling in the subclass is better than making
    /// the base class take a per-console letter table, which would put five
    /// consoles' worth of knowledge in the one class that has none of it.
    ///
    /// `titleText` is kept in step because the dressed path restyles from it,
    /// and a label whose text and titleText disagree looks correct until the
    /// first time the dress is applied.
    func setTitle(_ text: String) {
        guard titleText != text else { return }
        titleText = text
        label.text = text
        applyResting()
    }

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
        layer.addSublayer(dome)
        layer.addSublayer(core)

        titleText = text
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // Above the bombé, because the mark is an ink printed ON the moulded
        // surface. Below the lock glyph, which is chrome rather than the pad.
        symbolLayer.fillColor = UIColor.clear.cgColor
        symbolLayer.lineJoin = .round
        symbolLayer.lineCap = .round
        symbolLayer.isHidden = true
        layer.addSublayer(symbolLayer)
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

    /// The mark, stroked inside a box that is the same for all four.
    private func layoutPS1Symbol() {
        guard let symbol = ps1Symbol, !symbolLayer.isHidden else { return }
        let side = (bounds.width / 2) * Self.ps1SymbolBox
        let box = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                         width: side, height: side)
        symbolLayer.lineWidth = side * 0.10
        let path = UIBezierPath()
        switch symbol {
        case .circle:
            path.append(UIBezierPath(ovalIn: box.insetBy(dx: symbolLayer.lineWidth / 2,
                                                         dy: symbolLayer.lineWidth / 2)))
        case .square:
            path.append(UIBezierPath(roundedRect: box.insetBy(dx: symbolLayer.lineWidth / 2,
                                                              dy: symbolLayer.lineWidth / 2),
                                     cornerRadius: side * 0.06))
        case .cross:
            // The two diagonals, pulled in by half a stroke so the round caps
            // land inside the box rather than hanging out of its corners.
            let i = box.insetBy(dx: symbolLayer.lineWidth / 2, dy: symbolLayer.lineWidth / 2)
            path.move(to: CGPoint(x: i.minX, y: i.minY))
            path.addLine(to: CGPoint(x: i.maxX, y: i.maxY))
            path.move(to: CGPoint(x: i.maxX, y: i.minY))
            path.addLine(to: CGPoint(x: i.minX, y: i.maxY))
        case .triangle:
            // EQUILATERAL, so it is `sqrt(3)/2` of its base tall rather than as
            // tall as the box. Centred in the box's height, so the three points
            // are equidistant from the button's middle and it does not sit low.
            let i = box.insetBy(dx: symbolLayer.lineWidth / 2, dy: symbolLayer.lineWidth / 2)
            let height = i.width * CGFloat(3).squareRoot() / 2
            // Centred on its CENTROID rather than its bounding box. A triangle's
            // weight sits a sixth of its height below the middle of the box it
            // fits in, so a box-centred one always reads as hanging low. Lifting
            // it by that sixth is what makes it look centred, which is the only
            // kind of centred that matters here.
            let lift = height / 6
            let top = i.midY - height / 2 - lift, bottom = i.midY + height / 2 - lift
            path.move(to: CGPoint(x: i.midX, y: top))
            path.addLine(to: CGPoint(x: i.maxX, y: bottom))
            path.addLine(to: CGPoint(x: i.minX, y: bottom))
            path.close()
        }
        symbolLayer.path = path.cgPath
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPS1Symbol()
        layer.cornerRadius = bounds.width / 2
        // Sheen on the top half, clipped to the circle (shadow needs masksToBounds off).
        sheen.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.55)
        sheen.cornerRadius = bounds.width / 2
        sheen.masksToBounds = true
        // A face is a circle: dome it as a sphere, and core it as one too.
        Bombe.fit(dome, to: bounds, corner: nil)
        Bombe.fitCore(core, over: bounds,
                      clippedTo: UIBezierPath(ovalIn: bounds).cgPath)
        // THE SHADOW NEEDS ITS PATH, and this is not a micro-optimisation.
        //
        // Without one, Core Animation has to derive the silhouette itself: it rasterises the
        // layer and its sublayers OFFSCREEN, blurs the alpha, then composites — and it redoes
        // that whenever the layer changes. `isPressed` animates the fill, the border, the
        // transform AND shadowOpacity over 0.06s, so every frame of every press and every
        // release paid for an offscreen pass, on the thread the emulator is drawing from.
        //
        // Reported as SNES lag felt "only when I release B after a jump, never on left/right",
        // which is exactly the shape of this bug: the D-pad draws its shadow as a filled
        // CAShapeLayer and has never had a layer shadow at all, and the release edge is the one
        // that animates the shadow back ON. The circle is the button, so the path is exact and
        // nothing changes on screen.
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
    }
}

// MARK: - Shoulder Button (L, R)

final class ShoulderButton: UIView, HighlightableButton {
    /// NDS L/R corner radius as a fraction of the short side — a rounded square, not a pill.
    /// The skin's L/R creusé seat mirrors this so the two stay concentric.
    /// The PlayStation's shoulder corner, in POINTS rather than a fraction, and
    /// that is the point of it: its bars take the corner an arrow of its own
    /// cross has on the outside, which is a fixed 6 (`CrossDPadView`'s arm-tip
    /// radius). A fraction would have made every bar's corner depend on the
    /// bar's own size, so the two shapes would only have matched at one scale.
    /// Half the height, the default here, read as a later console's trigger.
    static let ps1Corner: CGFloat = 6
    static let ndsCornerFactor: CGFloat = 0.3

    private let label = UILabel()
    private let sheen = CAGradientLayer()   // raised-plastic top highlight (dressed only)
    private let dome = Bombe.make()       // the PlayStation's bombé
    private let core = Bombe.makeCore()   // its second, offset layer

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
    /// Change the text on the bar after it was built.
    ///
    /// Exists for the same reason `ActionButton.setTitle` does: this class is
    /// built knowing nothing about consoles, and the PlayStation's shoulders
    /// are printed L1 and R1 rather than L and R. Relabelling in the subclass
    /// beats teaching the base class a per-console table.
    func setTitle(_ text: String) {
        label.text = text
    }

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
        layer.addSublayer(dome)
        layer.addSublayer(core)

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
        // The bombé belongs to the one console that has it, dressed or not, so
        // it is decided before the branch rather than inside it.
        dome.isHidden = !(dressed && dressKind == .ps1)
        core.isHidden = dome.isHidden
        if dressed {
            backgroundColor = fill
            layer.borderColor = edge.cgColor
            label.textColor = labelInk                 // dark moulded "L"/"R"
            // INCRUSTED on this console: a light catch one point BELOW the word,
            // which is what the lower wall of a groove does under a light from
            // above. Cleared on every other console, because a shoulder that is
            // already wearing a raised sheen must not also read as carved.
            if dressKind == .ps1 {
                // INVERTED, on purpose and as a trial: the word is the LIGHT one
                // and the catch beneath it the dark one. Read literally that is
                // a raised letter rather than a cut one, but on a plate this
                // dark the light letter is the one that can actually be read at
                // a glance. Swap these two lines back to return to the groove.
                // The custom skin's PRINTED TEXT slot lands here: L1, L2, R1 and
                // R2 carry a word printed ON the plate, not moulded into it, so
                // it is free to be any colour. The catch below it stays derived
                // from the plate, because the catch is light on plastic rather
                // than ink.
                label.textColor = dressVariant.ps1Palette?.print
                    ?? fill.rpMixed(with: .white, 0.55)
                label.shadowColor = fill.rpMixed(with: .black, 0.62)
                label.shadowOffset = CGSize(width: 0, height: 1)
                label.font = .systemFont(ofSize: 14, weight: .bold)
            } else {
                label.font = .systemFont(ofSize: 14, weight: .semibold)
                label.shadowColor = nil
                label.shadowOffset = .zero
            }
            // NOT ON THE PLAYSTATION. Its shoulders are flat mouldings in one
            // colour, and a raised-plastic highlight down them is the GBA's
            // trigger rather than this pad's bar. The bombé takes its place.
            sheen.isHidden = (dressKind == .ps1)
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 1.5)
            layer.shadowRadius = 2
            layer.shadowOpacity = 0.25
        } else {
            backgroundColor = UIColor.white.withAlphaComponent(0.2)
            layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
            label.textColor = .white
            label.shadowColor = nil
            label.shadowOffset = .zero
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
        // The PlayStation's bars are not capsules: they take the corner an arrow
        // of its own cross has at the outside, which is a small fixed radius
        // rather than half the bar's height. A capsule here read as a trigger
        // from a later console.
        let radius = dressed
            ? (dressKind == .ps1 ? ShoulderButton.ps1Corner
               : dressKind == .nds ? min(bounds.width, bounds.height) * ShoulderButton.ndsCornerFactor
                                   : min(bounds.height * 0.5, bounds.width * 0.5))
            : 8
        layer.cornerRadius = radius
        sheen.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.55)
        sheen.cornerRadius = radius
        sheen.masksToBounds = true
        Bombe.fit(dome, to: bounds, corner: radius)
        Bombe.fitCore(core, over: bounds,
                      clippedTo: UIBezierPath(roundedRect: bounds,
                                              cornerRadius: radius).cgPath)
        // Same reason as ActionButton's: a shadow with no path is an offscreen render pass, and
        // this one is redone every time the dress toggles it. The radius is the one computed
        // just above, so the path is the shape that is actually drawn.
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
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
    enum DressStyle {
        case none, pill, pillTop, iconOnly, circle, decal
        /// PlayStation. Three shapes rather than a pill, because this pad prints
        /// three different things in the middle of itself: SELECT is a plain
        /// horizontal rectangle with its word BELOW it, START is a triangle with
        /// its word below it, and ANALOG is a rectangle with its word engraved
        /// INSIDE. L3 and R3 take `ps1Plate` too, in the shell's own colour.
        case ps1Rect, ps1Triangle, ps1Plate, ps1Stub
        var isPS1: Bool {
            self == .ps1Rect || self == .ps1Triangle || self == .ps1Plate || self == .ps1Stub
        }
        /// Whether the word sits under the shape rather than in it.
        var ps1LabelBelow: Bool { self == .ps1Rect || self == .ps1Triangle }
    }

    // GB/GBC dressed palette (the three SELECT/START greys now live on DressKind, unchanged).
    private static let iconBody = UIColor(red: 0.753, green: 0.741, blue: 0.737, alpha: 1) // #C0BDBC (matches PHONES icon)
    // The landscape MENU icon colour — the .pillTop pills match it (per request).
    private static let menuIcon        = UIColor.white.withAlphaComponent(0.85)
    private static let menuIconPressed = UIColor.white.withAlphaComponent(0.6)

    /// Which console palette to use when dressed (GB/GBC grey/white vs GBA #C4BFCF).
    var dressKind: DressKind = .gbc { didSet { applyResting(); setNeedsLayout() } }
    /// The device scale the layout was built at. Only the NES reads it (its pill sits where the
    /// printed word above it says it should, and that word scales with the device), but it is set
    /// for every console so the two can never be out of step.
    var dressScale: CGFloat = 1 {
        didSet { guard dressScale != oldValue else { return }; setNeedsLayout() }
    }
    /// Nostalgia vs the Retro Pal recolour (set by setDressed).
    var dressVariant: DressVariant = .nostalgia { didSet { applyResting() } }
    /// GB/GBC SELECT/START/MENU/CLIP go near-black under Retro Pal and to the user's small-buttons
    /// colour under custom; GBA/NDS pills are untouched (nil → keep their built-in fill).
    // SELECT/START pill (.pill): every console's face goes to its small-button slot under custom
    // (GBC → smallButtons; GBA/NDS → buttons), to the Retro Pal recolour, or the built-in default.
    /// The shell colour, which is what L3 and R3 are moulded from: on the
    /// hardware they are not painted controls, they are two thumbed pads of the
    /// same plastic as the pad around them.
    private var ps1BodyColor: UIColor {
        if let p = dressVariant.ps1Palette { return p.body }
        if dressVariant == .retroPal { return RetroPalPalette.ps1Body }
        return DressKind.ps1Body
    }
    /// The plate a PlayStation style draws, and the word cut into it. The word
    /// is a shade of the plate rather than a colour of its own, because it is
    /// moulded into the plastic and not printed on it.
    private var ps1PlateColor: UIColor { dressStyle == .ps1Stub ? ps1BodyColor : pillBase }
    /// The light a cut in this plastic catches on its lower wall. Derived from
    /// whatever the style actually fills with, so it holds on both dresses and
    /// on a custom palette rather than being a constant that suits only one.
    private var ps1EngravedCatch: UIColor {
        // 0.55 rather than 0.30, for the same reason the ink went darker: the
        // catch is the half that carries the effect, and a faint one on a dark
        // plate is a catch nobody sees.
        (dressStyle == .circle ? circleBgColor : ps1PlateColor).rpMixed(with: .white, 0.55)
    }
    /// The custom skin's PRINTED TEXT slot, when there is one. This is the
    /// words on SELECT, START, ANALOG and the four shoulders, plus the MENU and
    /// CLIP glyphs through `circleIconC` below. It is the ink ON a control, not
    /// the plastic of one, which is why it earns a slot of its own: the built-in
    /// dresses derive it from the plate because a moulded word is a shade of its
    /// plate, but a printed one has no such obligation.
    private var ps1PrintSlot: UIColor? {
        dressKind == .ps1 ? dressVariant.ps1Palette?.print : nil
    }

    /// ⚠ THE PRINTED-TEXT SLOT DOES NOT REACH HERE, and that is deliberate.
    /// This serves SELECT, START, ANALOG, L3 and R3, whose words are MOULDED:
    /// SELECT and START print theirs on the shell beside the shape, the other
    /// three cut theirs into their own plate. A moulded word is a shade of what
    /// it is moulded into, so it derives and must keep deriving. The slot was
    /// wired through here for one commit and recoloured SELECT and START, which
    /// is not what it is for.
    private var ps1InkColor: UIColor {
        // SELECT and START print their word on the SHELL, beside the shape, so
        // there it is the plate's own colour standing on the body. ANALOG, L3
        // and R3 cut theirs INTO the plate, so those go darker than it.
        // 0.62 rather than 0.34: at a third the letter and the plate were two
        // dark greys a few percent apart, which is a groove you can find only if
        // you already know it is there. A cut goes properly dark; what makes it
        // read as cut rather than as painted is the light catch below it, not
        // the letter being timid.
        return dressStyle.ps1LabelBelow ? pillBase
                                        : ps1PlateColor.rpMixed(with: .black, 0.62)
    }

    private var pillBase: UIColor {
        if let c = dressVariant.smallButtonFace(dressKind) { return c }
        return dressKind.smallButtonFill }
    private var pillPressedC: UIColor {
        if let c = dressVariant.smallButtonFace(dressKind) { return c.rpPressed }
        return dressKind.smallButtonPressed }
    private var pillEdgeC: UIColor {
        if let c = dressVariant.smallButtonFace(dressKind) { return c.rpEdge }
        return dressKind.smallButtonEdge }
    // Landscape SELECT/START (.pillTop): GB/GBC keeps white for the BUILT-INS (custom uses the slot);
    // GBA/NDS follow their button face.
    private var pillTopBase: UIColor {
        if dressKind == .gbc { return dressVariant.gbcPalette?.smallButtons ?? Self.menuIcon }
        return dressVariant.smallButtonFace(dressKind) ?? dressKind.smallButtonFill }
    private var pillTopPressedC: UIColor {
        if dressKind == .gbc { return dressVariant.gbcPalette?.smallButtons.rpPressed ?? Self.menuIconPressed }
        return dressVariant.smallButtonFace(dressKind)?.rpPressed ?? dressKind.smallButtonPressed }
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
        if let printed = ps1PrintSlot { return printed }
        if let p = dressVariant.gbcPalette { return p.menuIcons }
        if let p = dressVariant.gbaPalette { return p.menuIcons }
        if let p = dressVariant.ndsPalette { return p.icons }
        if dressVariant == .retroPal, dressKind == .nds { return RetroPalPalette.ndsInk }
        // The SNES's glyph follows its own button. Nostalgia fills MENU and CLIP with the pad's
        // near-black and the pale body colour reads on it; Retro Pal fills them with the GBA's
        // pale button, where that same glyph disappeared. Dark then, and specifically the ring
        // the face buttons sit in, which is the console's own dark grey.
        // The PlayStation: its circle IS the control colour, so the glyph is that
        // colour carved, exactly as a shoulder's word is. Falling through to the
        // branches below gave it something near its own background and it
        // disappeared.
        if dressKind == .ps1 {
            return circleBgColor.rpMixed(with: .black, circleBgColor.rpIsLight ? 0.42 : 0.34)
        }
        if dressKind == .snes, circleBgColor.rpIsLight {
            if let p = dressVariant.snesPalette { return p.surround }
            return dressVariant == .retroPal ? RetroPalPalette.snesSurround : DressKind.snesSurround
        }
        if dressKind == .snes, let p = dressVariant.snesPalette { return p.body }
        // The NES's is the same problem the other way up: Nostalgia fills MENU and CLIP with a
        // near-black pill and the light grey glyph reads on it, while Retro Pal (and any custom
        // skin with a light pad) fills them with a light one, where that same glyph disappears.
        // The ink is then the shell's own colour, which is the darkest thing on this console.
        if dressKind == .nes, circleBgColor.rpIsLight {
            if let p = dressVariant.nesPalette { return p.body }
            return dressVariant == .retroPal ? RetroPalPalette.nesInk : DressKind.nesBody
        }
        return dressKind.circleGlyph
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
    /// The PlayStation styles print their word BELOW the shape for SELECT and
    /// START, so the label's vertical placement is not a constant. Held here and
    /// moved in layoutSubviews, where the shape's own height is known.
    private var labelCentreY: NSLayoutConstraint?
    /// Caps the word's width so `adjustsFontSizeToFitWidth` has a bound to work
    /// against. Only the styles that print their word INSIDE a plate want it.
    private var labelWidth: NSLayoutConstraint?
    /// The bombé, clipped to whichever of the four shapes is drawn.
    private let dome = Bombe.make()
    private let core = Bombe.makeCore()
    /// The word's default size, kept so the undressed look is untouched when a
    /// PlayStation layout scales the label and then the dress comes off.
    private static let labelPointSize: CGFloat = 10

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
            if dressKind.selectIsTinyCircle {
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
        case .ps1Rect, .ps1Triangle, .ps1Plate, .ps1Stub:
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pillBg.fillColor = (isPressed ? ps1PlateColor.rpPressed : ps1PlateColor).cgColor
            CATransaction.commit()
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

    /// Drop any incrusted-word treatment. Called by the styles that do not want
    /// one, because a label keeps its shadow until something takes it away and a
    /// console switch would otherwise carry this pad's groove onto another's.
    /// The emboss copy's own ink. Named because two styles now set it: the
    /// icon-only emboss wants it dark, and the PlayStation's disc re-tints it
    /// light to read as a groove instead.
    static let embossShadowInk = UIColor.black.withAlphaComponent(0.32)

    private func clearEngravedWord() {
        textLabel?.shadowColor = nil
        textLabel?.shadowOffset = .zero
    }

    /// Resting appearance for the current dress style.
    private func applyResting() {
        circleBg.isHidden = (dressStyle != .circle)
        pillBg.isHidden = (dressStyle != .pill && dressStyle != .pillTop && !dressStyle.isPS1)
        // The bombé belongs to the CONSOLE, not to the four ps1 shapes: MENU and
        // CLIP wear `.circle` here exactly as they do everywhere else, and they
        // are as much a moulding on this pad as SELECT is.
        dome.isHidden = !(dressKind == .ps1 && dressStyle != .none)
        core.isHidden = dome.isHidden
        // Dressed (SELECT/START): the identifier is printed on the case (slice 3c), so the
        // pill is bare. Its diagonal shape is built in layoutSubviews.
        // The PlayStation is the exception: its SELECT, START, ANALOG, L3 and R3
        // wear their word themselves, either under the shape or cut into it, so
        // the dress does not print it on the shell for them.
        textLabel?.isHidden = (dressStyle != .none && !dressStyle.isPS1)
        setNeedsLayout()
        // Enlarge the icon only when it stands alone (icon-only), to fill its round well.
        if iconView != nil {
            let big = (dressStyle == .iconOnly)
            NSLayoutConstraint.deactivate(big ? iconSmall : iconBig)
            NSLayoutConstraint.activate(big ? iconBig : iconSmall)
        }
        // Cleared for every style, then set again by the two that want one. A
        // label keeps its shadow until something takes it away, so resetting in
        // one place is what stops this pad's groove following a console switch.
        clearEngravedWord()
        // The word is capped only where it is printed inside something: ANALOG,
        // L3 and R3. SELECT and START stand theirs on the shell, with the whole
        // hitbox to spread into.
        labelWidth?.isActive = dressStyle.isPS1 && !dressStyle.ps1LabelBelow
        switch dressStyle {
        case .none:
            backgroundColor = UIColor.white.withAlphaComponent(0.15)
            layer.borderWidth = 1
            layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
            textLabel?.textColor = UIColor.white.withAlphaComponent(0.8)
            textLabel?.font = .systemFont(ofSize: Self.labelPointSize, weight: .medium)
            labelCentreY?.constant = 0
            iconView?.tintColor = UIColor.white.withAlphaComponent(0.8)
            iconHighlight?.isHidden = true
            iconShadow?.isHidden = true
        case .pill:
            // The visible pill is the shape layer, not the view background. GBA: a tiny clip-like
            // circle (no edge). GB/GBC: the grey diagonal pill (edged).
            backgroundColor = .clear
            layer.borderWidth = 0
            pillBg.fillColor = pillFill(pressed: false)
            pillBg.strokeColor = dressKind.selectIsTinyCircle ? UIColor.clear.cgColor : pillEdgeC.cgColor
            pillBg.lineWidth = dressKind.selectIsTinyCircle ? 0 : 1
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
        case .ps1Rect, .ps1Triangle, .ps1Plate, .ps1Stub:
            // Not a capsule, and not the same shape for all five: this pad
            // prints a rectangle for SELECT, a right-pointing triangle for
            // START, and a longer plate for ANALOG. L3 and R3 take the plate in
            // the shell's own colour, since they are moulded rather than
            // painted. The shapes themselves are built in layoutSubviews.
            backgroundColor = .clear
            layer.borderWidth = 0
            pillBg.fillColor = ps1PlateColor.cgColor
            pillBg.strokeColor = ps1PlateColor.rpEdge.cgColor
            pillBg.lineWidth = 1
            // INVERTED for the three that carry their word INSIDE the plate
            // (ANALOG, L3, R3): the light tone is the letter and the dark one
            // the catch under it. SELECT and START are untouched -- their word
            // stands on the shell, not in a plate, so there is nothing there to
            // invert. Swapping the two lines back restores the groove.
            let inverted = !dressStyle.ps1LabelBelow
            textLabel?.textColor = inverted ? ps1EngravedCatch : ps1InkColor
            textLabel?.shadowColor = inverted ? ps1InkColor : ps1EngravedCatch
            textLabel?.shadowOffset = CGSize(width: 0, height: 1)
            iconHighlight?.isHidden = true
            iconShadow?.isHidden = true
        case .circle:
            backgroundColor = .clear
            layer.borderWidth = 0
            circleBg.fillColor = circleBgColor.cgColor
            circleBg.strokeColor = circleEdgeC.cgColor
            circleBg.lineWidth = 1
            iconView?.tintColor = circleIconC
            // On this console the glyph is CUT INTO the disc, so it gets the
            // same light-below catch the words get. `iconShadow` is the copy
            // offset down-right, so it is the one that plays the catch here and
            // it is tinted light rather than dark; the up-left copy stays hidden,
            // because showing both would emboss instead of engrave.
            // INVERTED like the words: the glyph itself takes the light tone
            // and the copy behind it the dark one, so the mark reads at a glance
            // on a disc this dark.
            let engraved = (dressKind == .ps1)
            iconHighlight?.isHidden = true
            iconShadow?.isHidden = !engraved
            if engraved {
                iconView?.tintColor = ps1EngravedCatch
                iconShadow?.tintColor = circleBgColor.rpMixed(with: .black, 0.62)
            }
        case .iconOnly:
            backgroundColor = .clear
            layer.borderWidth = 0
            iconView?.tintColor = iconColorC
            iconHighlight?.isHidden = false
            iconShadow?.isHidden = false
            // Restated, not assumed: the PlayStation's `.circle` re-tints this
            // same copy LIGHT to play an engraved catch, and a style switch on
            // one button would otherwise leave an emboss lit from both sides.
            iconShadow?.tintColor = Self.embossShadowInk
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
            let circle = UIBezierPath(ovalIn: rect)
            circleBg.path = circle.cgPath
            Bombe.fit(dome, over: bounds, clippedTo: circle.cgPath)
            Bombe.fitCore(core, over: bounds, clippedTo: circle.cgPath)
        case .pill where dressKind.selectIsTinyCircle, .pillTop where dressKind.selectIsTinyCircle:
            // GBA/NDS: the visible "button" is a tiny circle at the right of the pill (the dress
            // draws the creusé pill bg + the label).
            pillBg.path = UIBezierPath(ovalIn: selectCircleRect()).cgPath
        case .pill, .pillTop:
            // GB/GBC and SNES: the visible button IS the pill. Portrait draws the hitbox's
            // bottom-left to top-right diagonal, landscape a thin horizontal one across its
            // upper third, and the SNES draws either at half length. The dress carves its seat
            // from the same two endpoints.
            let t = min(bounds.width, bounds.height) * Self.pillThicknessRatio
            let (q1, q2) = DressKind.pillEndpoints(
                in: bounds, thickness: t, isLandscape: dressStyle == .pillTop,
                lengthRatio: dressKind.pillLengthRatio,
                centerY: dressKind.pillCenterY(in: bounds, scale: dressScale))
            let line = CGMutablePath(); line.move(to: q1); line.addLine(to: q2)
            pillBg.path = line.copy(strokingWithWidth: t, lineCap: .round,
                                    lineJoin: .round, miterLimit: 0)
        case .ps1Rect, .ps1Triangle, .ps1Plate, .ps1Stub:
            let shape = ps1ShapePath()
            pillBg.path = shape.cgPath
            Bombe.fit(dome, over: bounds, clippedTo: shape.cgPath)
            Bombe.fitCore(core, over: bounds, clippedTo: shape.cgPath)
            // Bold, not semibold: a groove is read by its edges, and a heavier
            // stroke gives the catch below it more edge to fall on.
            textLabel?.font = .systemFont(ofSize: ps1LabelPointSize, weight: .bold)
            // SELECT and START carry their word under the shape; ANALOG, L3 and
            // R3 carry it inside, where the constraint's own centre is right.
            labelCentreY?.constant = dressStyle.ps1LabelBelow
                ? (ps1BlockTop + ps1BandHeight + ps1LabelGap + ps1LabelHeight / 2) - bounds.midY
                : 0
        case .none, .iconOnly, .decal:
            layer.cornerRadius = 6
        }
    }

    // MARK: The PlayStation shapes
    //
    // This pad does not print a capsule anywhere, so none of these is one. What
    // it prints between the sticks is a small rounded RECTANGLE for SELECT, a
    // right-pointing TRIANGLE for START, and a wider plate saying ANALOG between
    // them. The first two carry their word below the shape, as the hardware
    // does; the third has it cut into the plate.
    //
    // Every one of them is drawn inside a hitbox deliberately larger than the
    // shape, which is why the geometry is written as a block that is centred as
    // a whole: SELECT's rectangle and START's triangle are different heights,
    // and their two words have to sit on one line all the same.

    /// The PlayStation's centre shapes, as pure geometry.
    ///
    /// STATIC because the skin needs them too: it carves a recess around each of
    /// these controls, and a recess that is a rounded rectangle where the button
    /// drew a triangle is worse than no recess at all. Same arrangement as the
    /// cross's seat, which reads `CrossDPadView.ps1KeysPath` rather than guessing
    /// at the shape a second time — and the same reason it exists.
    enum PS1Shape {
        /// The base unit both centre shapes are measured in: the triangle's own
        /// height, and what SELECT's rectangle is a multiple of.
        static func unit(_ b: CGRect) -> CGFloat { b.height * 0.34 }
        /// SELECT's rectangle, TWICE the depth it used to draw. It was the
        /// flattest mark on the pad and read as a dash rather than as a button.
        static func rectHeight(_ b: CGRect) -> CGFloat { unit(b) * 0.82 * 2 }
        /// The band the shapes occupy. Shared by the rectangle and the triangle
        /// so the two words below them line up, and sized to whichever is TALLER
        /// so the taller is not clipped and the shorter simply centres inside it.
        /// That is what keeps SELECT and START on one line now that they differ.
        static func band(_ b: CGRect) -> CGFloat { max(unit(b), rectHeight(b)) }
        static func labelPointSize(_ style: DressStyle, _ b: CGRect) -> CGFloat {
            // SELECT and START (the two that print BELOW their shape) run 20%
            // larger: their word stands on the shell with nothing around it, so
            // it has the room, and they are the two a player actually hunts for.
            max(7, b.height * (style.ps1LabelBelow ? 0.252 : 0.24))
        }
        static func labelHeight(_ style: DressStyle, _ b: CGRect) -> CGFloat {
            labelPointSize(style, b) * 1.2
        }
        static func labelGap(_ b: CGRect) -> CGFloat { b.height * 0.08 }
        /// Top of the shape+gap+word block, centred in the hitbox as one piece.
        static func blockTop(_ style: DressStyle, _ b: CGRect) -> CGFloat {
            b.midY - (band(b) + labelGap(b) + labelHeight(style, b)) / 2
        }

        /// How far the drawn SHAPE sits above the hitbox's own centre.
        ///
        /// The block is shape + gap + word and it is the BLOCK that is centred,
        /// so on the two that carry a word below, the shape rides high by half
        /// the gap and word. The layout needs the number: aligning SELECT and
        /// START with CLIP means aligning what a player SEES, and what they see
        /// is the shape, not the hitbox it is centred in.
        static func shapeRise(_ style: DressStyle, _ b: CGRect) -> CGFloat {
            style.ps1LabelBelow ? (labelGap(b) + labelHeight(style, b)) / 2 : 0
        }

        /// Which shape each PlayStation control prints. ONE mapping, read by the
        /// control view when it dresses and by the skin when it carves.
        static func style(for element: ControlElement) -> DressStyle? {
            switch element {
            case .btnSelect: return .ps1Rect
            case .btnStart:  return .ps1Triangle
            case .btnMode:   return .ps1Plate
            case .btnL3, .btnR3: return .ps1Stub
            default: return nil
            }
        }

        static func path(_ style: DressStyle, in b: CGRect) -> UIBezierPath {
            let w = b.width
            switch style {
            case .ps1Rect:
                let sh = rectHeight(b), sw = w * 0.52
                let r = CGRect(x: b.midX - sw / 2, y: blockTop(style, b) + (band(b) - sh) / 2,
                               width: sw, height: sh)
                // Capped at a fraction of the WIDTH so a rectangle this deep
                // stays a rectangle: 0.30 of its height would round it into a
                // capsule, and nothing on this pad is a capsule.
                return UIBezierPath(roundedRect: r, cornerRadius: min(sh * 0.30, sw * 0.18))
            case .ps1Triangle:
                // AS WIDE AS SELECT'S RECTANGLE, which makes it a squat
                // horizontal triangle rather than the near-equilateral one it
                // was. The two sit side by side and are read as a pair, so the
                // pair has to share a width or the smaller reads as further away.
                let sh = unit(b), sw = w * 0.52
                let x = b.midX - sw / 2, y = blockTop(style, b) + (band(b) - sh) / 2
                let p = UIBezierPath()
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x + sw, y: y + sh / 2))
                p.addLine(to: CGPoint(x: x, y: y + sh))
                p.close()
                return p
            case .ps1Plate, .ps1Stub:
                let isPlate = (style == .ps1Plate)
                let sw = w * (isPlate ? 0.92 : 0.84)
                // L3 and R3 are SQUARE, at the width they already had. ANALOG
                // keeps its plate shape: it is a word in a slot and wants to be
                // wider than it is tall, while these two are thumb pads.
                let sh = isPlate ? b.height * 0.50 : sw
                let r = CGRect(x: b.midX - sw / 2, y: b.midY - sh / 2, width: sw, height: sh)
                return UIBezierPath(roundedRect: r,
                                    cornerRadius: min(ShoulderButton.ps1Corner, sh / 2))
            default:
                return UIBezierPath()
            }
        }
    }

    private var ps1LabelPointSize: CGFloat { PS1Shape.labelPointSize(dressStyle, bounds) }
    private var ps1LabelHeight: CGFloat { PS1Shape.labelHeight(dressStyle, bounds) }
    private var ps1LabelGap: CGFloat { PS1Shape.labelGap(bounds) }
    private var ps1BandHeight: CGFloat { PS1Shape.band(bounds) }
    private var ps1BlockTop: CGFloat { PS1Shape.blockTop(dressStyle, bounds) }

    private func ps1ShapePath() -> UIBezierPath { PS1Shape.path(dressStyle, in: bounds) }

    init(label text: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.15)
        layer.cornerRadius = 6
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor

        pillBg.isHidden = true
        layer.insertSublayer(pillBg, at: 0)
        layer.addSublayer(dome)
        layer.addSublayer(core)

        let lbl = UILabel()
        lbl.text = text
        lbl.textColor = UIColor.white.withAlphaComponent(0.8)
        lbl.font = .systemFont(ofSize: Self.labelPointSize, weight: .medium)
        lbl.textAlignment = .center
        // Only ever engages on the PlayStation styles, where the word is sized
        // from the hitbox and the longest of them (ANALOG) sits inside a plate.
        lbl.adjustsFontSizeToFitWidth = true
        lbl.minimumScaleFactor = 0.7
        lbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lbl)
        textLabel = lbl
        let centreY = lbl.centerYAnchor.constraint(equalTo: centerYAnchor)
        labelCentreY = centreY
        // `adjustsFontSizeToFitWidth` above did NOTHING without this: a label with
        // no width constraint sizes to its own text, so it is never too narrow
        // and never shrinks. ANALOG is the word that showed it — the longest on
        // the pad, printed inside a plate 0.92 of the hitbox, and running past
        // its own plate at the size the hitbox asked for. Off by default so no
        // other console's label changes; the styles that print INSIDE something
        // switch it on.
        let width = lbl.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor,
                                               multiplier: 0.80)
        width.isActive = false
        labelWidth = width
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: centerXAnchor),
            centreY,
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
        // MENU and CLIP get the bombé like everything else on this pad. They are
        // built by a DIFFERENT initializer from the labelled small buttons, and
        // this pair of lines was only in that one, so the two layers existed for
        // SELECT and START and simply were not there for these two.
        layer.addSublayer(dome)
        layer.addSublayer(core)

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
        sh.tintColor = Self.embossShadowInk
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
