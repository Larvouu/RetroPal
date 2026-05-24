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

    // Haptic feedback
    private let hapticLight = UIImpactFeedbackGenerator(style: .light)

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
    let btnMenu = SmallButton(label: "⋯")

    // Map each button view to its bitmask
    private(set) var buttonMap: [(UIView, UInt32)] = []

    var onMenuTap: (() -> Void)?

    /// Subclass sets this to enable a mic/blow button (NDS only)
    var micButton: UIView?
    private var micActive = false

    /// Subclasses call this to register additional button→bitmask mappings.
    func addNDSButtonMappings(_ mappings: [(UIView, UInt32)]) {
        buttonMap.append(contentsOf: mappings)
    }

    // Track which touch is on the joystick for visual thumb feedback
    private var dpadTouch: UITouch?

    /// Apply opacity and scale from user settings
    func applySettings() {
        let opacity = UserDefaults.standard.double(forKey: "controlOpacity")
        let scale = UserDefaults.standard.double(forKey: "controlScale")
        let effectiveOpacity = opacity > 0 ? opacity : 0.5
        let effectiveScale = scale > 0 ? scale : 1.0

        let scaleTransform = CGAffineTransform(scaleX: effectiveScale, y: effectiveScale)
        for v in [dpad, btnA, btnB, btnL, btnR, btnStart, btnSelect] as [UIView] {
            v.alpha = CGFloat(effectiveOpacity) * 2.0
            v.transform = scaleTransform
            // Store base transform on ActionButtons so press animation compounds correctly
            (v as? ActionButton)?.baseTransform = scaleTransform
        }
        btnMenu.alpha = max(0.5, CGFloat(effectiveOpacity) * 2.0)
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

        // Observe the Settings → Controls "Hold to lock buttons" toggle. When
        // the user turns it off mid-session we clear any active locks so they
        // aren't left with a stuck pressed-state and no way to release it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        for v in [dpad, btnA, btnB, btnL, btnR, btnStart, btnSelect, btnMenu] as [UIView] {
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
         (.btnR, btnR), (.btnStart, btnStart), (.btnSelect, btnSelect), (.btnMenu, btnMenu)]
    }

    /// Apply a custom layout from a preset. Positions are normalized 0–1 coordinates.
    /// Opacity and scale come from the preset, not from global UserDefaults.
    func applyCustomLayout(_ layout: OrientationLayout, isLandscape: Bool, isNDS: Bool,
                           presetOpacity: CGFloat, presetScale: CGFloat) {
        NSLayoutConstraint.deactivate(constraints.filter { $0.firstItem is UIView })
        removeAllSubviewConstraints()

        let containerW = bounds.width
        let containerH = bounds.height
        guard containerW > 0 && containerH > 0 else { return }

        let scaleTransform = CGAffineTransform(scaleX: presetScale, y: presetScale)
        let effectiveAlpha = presetOpacity * 2.0

        for (element, view) in allButtonViews() {
            guard let bl = layout.buttons[element.rawValue] else {
                view.isHidden = true
                continue
            }

            // Menu button can never be hidden. Other controls are also hidden
            // while a controller is connected, so a re-layout keeps them hidden.
            view.isHidden = (element != .btnMenu) && (bl.isHidden || controllerModeActive)

            let size: CGSize
            if isNDS {
                size = isLandscape ? element.defaultNDSLandscapeSize : element.defaultNDSPortraitSize
            } else {
                size = isLandscape ? element.defaultLandscapeSize : element.defaultSize
            }

            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: leadingAnchor, constant: containerW * bl.centerX),
                view.centerYAnchor.constraint(equalTo: topAnchor, constant: containerH * bl.centerY),
                view.widthAnchor.constraint(equalToConstant: size.width),
                view.heightAnchor.constraint(equalToConstant: size.height),
            ])

            // Apply per-preset opacity and scale to ALL buttons (including NDS X/Y/Mic)
            view.transform = scaleTransform
            (view as? ActionButton)?.baseTransform = scaleTransform
            if element == .btnMenu {
                view.alpha = max(0.5, effectiveAlpha)
            } else {
                view.alpha = effectiveAlpha
            }
        }
    }

    /// Apply per-preset opacity and scale to all buttons (including NDS X/Y/Mic).
    /// Used when the preset has no custom button positions but changed opacity/scale.
    func applyPresetOpacityScale(opacity: CGFloat, scale: CGFloat) {
        let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
        let effectiveAlpha = opacity * 2.0
        for (element, view) in allButtonViews() {
            view.transform = scaleTransform
            (view as? ActionButton)?.baseTransform = scaleTransform
            if element == .btnMenu {
                view.alpha = max(0.5, effectiveAlpha)
            } else {
                view.alpha = effectiveAlpha
            }
        }
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

    // MARK: - Layout

    func applyPortraitLayout() {
        NSLayoutConstraint.deactivate(constraints.filter { $0.firstItem is UIView })
        removeAllSubviewConstraints()

        // Ergonomic positions optimized for thumb arcs from bottom corners.
        // Thumbs pivot ~40pt inward from edges, ~10pt up from bottom.
        // Comfortable reach arc: 100-120pt radius.

        NSLayoutConstraint.activate([
            // Joystick: left thumb, raised for easier reach
            dpad.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            dpad.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -140),
            dpad.widthAnchor.constraint(equalToConstant: 165),
            dpad.heightAnchor.constraint(equalToConstant: 165),

            // A: primary action, raised to match joystick height
            btnA.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            btnA.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -170),
            btnA.widthAnchor.constraint(equalToConstant: 72.6),
            btnA.heightAnchor.constraint(equalToConstant: 72.6),

            // B: secondary, below-left of A (GBA diamond layout)
            btnB.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -100),
            btnB.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -120),
            btnB.widthAnchor.constraint(equalToConstant: 63.8),
            btnB.heightAnchor.constraint(equalToConstant: 63.8),

            // L shoulder: top-left, above joystick
            btnL.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            btnL.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            btnL.widthAnchor.constraint(equalToConstant: 90),
            btnL.heightAnchor.constraint(equalToConstant: 44),

            // R shoulder: top-right, above A/B
            btnR.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            btnR.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            btnR.widthAnchor.constraint(equalToConstant: 90),
            btnR.heightAnchor.constraint(equalToConstant: 44),

            // Start: right of center, lifted from palm zone (44pt min touch target)
            btnStart.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 35),
            btnStart.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -39),
            btnStart.widthAnchor.constraint(equalToConstant: 64),
            btnStart.heightAnchor.constraint(equalToConstant: 44),

            // Select: left of center, mirrors Start
            btnSelect.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -35),
            btnSelect.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -39),
            btnSelect.widthAnchor.constraint(equalToConstant: 64),
            btnSelect.heightAnchor.constraint(equalToConstant: 44),

            // Menu: top-center, between L and R, far from gameplay buttons
            btnMenu.centerXAnchor.constraint(equalTo: centerXAnchor),
            btnMenu.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            btnMenu.widthAnchor.constraint(equalToConstant: 44),
            btnMenu.heightAnchor.constraint(equalToConstant: 44),
        ])
        applySettings()
    }

    func applyLandscapeLayout() {
        NSLayoutConstraint.deactivate(constraints.filter { $0.firstItem is UIView })
        removeAllSubviewConstraints()

        // Landscape: thumbs pivot from side edges at vertical midpoint.
        // Left panel: joystick + L. Right panel: A/B + R.
        // Start/Select pushed toward side panels, away from game screen.

        NSLayoutConstraint.activate([
            // Joystick: left side, moved inward for easier reach (may overlap game)
            dpad.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 95),
            dpad.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 39),
            dpad.widthAnchor.constraint(equalToConstant: 143),
            dpad.heightAnchor.constraint(equalToConstant: 143),

            // A: right panel, mirroring joystick's 95pt margin from edge
            btnA.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -95),
            btnA.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 9),
            btnA.widthAnchor.constraint(equalToConstant: 66),
            btnA.heightAnchor.constraint(equalToConstant: 66),

            // B: below-left of A, classic GBA diamond
            btnB.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -163),
            btnB.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 49),
            btnB.widthAnchor.constraint(equalToConstant: 59.4),
            btnB.heightAnchor.constraint(equalToConstant: 59.4),

            // L: above joystick, wide for thumb reach
            btnL.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25),
            btnL.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            btnL.widthAnchor.constraint(equalToConstant: 110),
            btnL.heightAnchor.constraint(equalToConstant: 38),

            // R: above A/B, mirrors L
            btnR.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -25),
            btnR.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            btnR.widthAnchor.constraint(equalToConstant: 110),
            btnR.heightAnchor.constraint(equalToConstant: 38),

            // Start: toward right panel, out of game area (44pt min touch target)
            btnStart.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 70),
            btnStart.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            btnStart.widthAnchor.constraint(equalToConstant: 56),
            btnStart.heightAnchor.constraint(equalToConstant: 44),

            // Select: toward left panel, mirrors Start
            btnSelect.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -70),
            btnSelect.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            btnSelect.widthAnchor.constraint(equalToConstant: 56),
            btnSelect.heightAnchor.constraint(equalToConstant: 44),

            // Menu: top-center, above game, maximally out of the way
            btnMenu.centerXAnchor.constraint(equalTo: centerXAnchor),
            btnMenu.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            btnMenu.widthAnchor.constraint(equalToConstant: 44),
            btnMenu.heightAnchor.constraint(equalToConstant: 44),
        ])
        applySettings()
    }

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

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
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
        guard UserDefaults.standard.object(forKey: "buttonLockEnabled") as? Bool ?? true else { return }
        let mask = lockableMask
        guard mask != 0 else { return }

        for touch in touches {
            let point = touch.location(in: self)
            // Find the lockable action button this touch began on (if any)
            for (view, buttonMask) in buttonMap where (buttonMask & mask) != 0 {
                let local = convert(point, to: view)
                let expanded = view.bounds.insetBy(
                    dx: -view.bounds.width * 0.2,
                    dy: -view.bounds.height * 0.2
                )
                guard expanded.contains(local) else { continue }

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
            let expanded = pending.view.bounds.insetBy(
                dx: -pending.view.bounds.width * 0.2,
                dy: -pending.view.bounds.height * 0.2
            )
            if !expanded.contains(local) {
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
        if UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true {
            hapticLight.impactOccurred()
        }
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
        if UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true {
            hapticLight.impactOccurred()
        }
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

    @objc private func userDefaultsDidChange() {
        let enabled = UserDefaults.standard.object(forKey: "buttonLockEnabled") as? Bool ?? true
        if !enabled && (lockedButtons != 0 || !pendingLocks.isEmpty || !unlockCandidates.isEmpty) {
            clearAllLocks()
        }
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

    private func updateButtons(for event: UIEvent?) {
        var buttons: UInt32 = 0

        guard let allTouches = event?.allTouches else {
            applyButtons(0)
            return
        }

        var foundDpadTouch = false
        for touch in allTouches {
            guard touch.phase == .began || touch.phase == .moved || touch.phase == .stationary else {
                continue
            }
            let point = touch.location(in: self)

            // Fixed joystick: check touch position relative to joystick center.
            // Works for both taps (menus) and holds (movement).
            let localDpad = convert(point, to: dpad)
            let dpadHitArea = dpad.bounds.insetBy(dx: -20, dy: -20)
            if dpadHitArea.contains(localDpad) {
                let dpadButtons = dpadButtonsForPoint(localDpad)
                buttons |= dpadButtons

                // Update visual feedback if this is the tracked d-pad touch
                if touch === dpadTouch {
                    let center = CGPoint(x: dpad.bounds.midX, y: dpad.bounds.midY)
                    let dx = localDpad.x - center.x
                    let dy = localDpad.y - center.y
                    dpadSetThumbDirection(dx: dx, dy: dy, maxDistance: dpad.bounds.width / 2)
                    foundDpadTouch = true
                }
            }

            // Check action buttons
            for (view, mask) in buttonMap {
                let local = convert(point, to: view)
                let expanded = view.bounds.insetBy(
                    dx: -view.bounds.width * 0.2,
                    dy: -view.bounds.height * 0.2
                )
                if expanded.contains(local) {
                    buttons |= mask
                }
            }

            // Check menu button
            let menuLocal = convert(point, to: btnMenu)
            let menuExpanded = btnMenu.bounds.insetBy(dx: -10, dy: -10)
            if menuExpanded.contains(menuLocal) {
                onMenuTap?()
            }
        }

        // Reset d-pad visual when no touch is active
        if !foundDpadTouch {
            dpadResetThumb()
        }

        // Check mic/blow button (NDS only)
        if let mic = micButton {
            var micTouched = false
            for touch in allTouches where [.began, .moved, .stationary].contains(touch.phase) {
                let local = convert(touch.location(in: self), to: mic)
                let expanded = mic.bounds.insetBy(dx: -mic.bounds.width * 0.2, dy: -mic.bounds.height * 0.2)
                if expanded.contains(local) { micTouched = true; break }
            }
            if micTouched != micActive {
                micActive = micTouched
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
        if newlyPressedRaw != 0 && UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true {
            // Always a light tap — medium felt too strong on the action buttons.
            hapticLight.impactOccurred()
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
}

// MARK: - Button protocol for visual feedback

protocol HighlightableButton: UIView {
    var isPressed: Bool { get set }
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

    private var thumbOffset: CGPoint = .zero

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
        let radius = min(bounds.width, bounds.height) / 2 - thumbRadius

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
            arcCenter: center, radius: thumbRadius,
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

        var buttons: UInt32 = 0
        let angle = atan2(dy, dx)

        // 8-direction zones (each 45 degrees)
        if angle > -.pi * 0.875 && angle < -.pi * 0.375 { buttons |= GBAInput.up.rawValue }
        if angle > .pi * 0.375 && angle < .pi * 0.875 { buttons |= GBAInput.down.rawValue }
        if angle > .pi * 0.625 || angle < -.pi * 0.625 { buttons |= GBAInput.left.rawValue }
        if angle > -.pi * 0.375 && angle < .pi * 0.375 { buttons |= GBAInput.right.rawValue }

        return buttons
    }

    func updateHighlight(buttons: UInt32) {
        // Thumb visual is handled by setThumbDirection, not by button state
    }
}

// MARK: - Action Button (A, B)

final class ActionButton: UIView, HighlightableButton {
    var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            UIView.animate(withDuration: 0.06, delay: 0, options: [.allowUserInteraction]) {
                if self.isPressed {
                    self.backgroundColor = UIColor.white.withAlphaComponent(0.55)
                    self.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
                    self.transform = self.baseTransform.scaledBy(x: 0.88, y: 0.88)
                    self.layer.shadowOpacity = 0
                } else {
                    self.backgroundColor = UIColor.white.withAlphaComponent(0.2)
                    self.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
                    self.transform = self.baseTransform
                    self.layer.shadowOpacity = 0.3
                }
            }
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

    /// Stores the external transform (from applySettings) so press animation compounds with it.
    var baseTransform: CGAffineTransform = .identity

    private let label = UILabel()
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
    }
}

// MARK: - Shoulder Button (L, R)

final class ShoulderButton: UIView, HighlightableButton {
    var isPressed = false {
        didSet {
            backgroundColor = isPressed
                ? UIColor.white.withAlphaComponent(0.5)
                : UIColor.white.withAlphaComponent(0.2)
        }
    }

    init(label text: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.2)
        layer.cornerRadius = 8
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor

        let lbl = UILabel()
        lbl.text = text
        lbl.textColor = .white
        lbl.font = .systemFont(ofSize: 14, weight: .semibold)
        lbl.textAlignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Small Button (Start, Select, Menu)

final class SmallButton: UIView, HighlightableButton {
    var isPressed = false {
        didSet {
            backgroundColor = isPressed
                ? UIColor.white.withAlphaComponent(0.45)
                : UIColor.white.withAlphaComponent(0.15)
        }
    }

    init(label text: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.15)
        layer.cornerRadius = 6
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor

        let lbl = UILabel()
        lbl.text = text
        lbl.textColor = UIColor.white.withAlphaComponent(0.8)
        lbl.font = .systemFont(ofSize: 10, weight: .medium)
        lbl.textAlignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
