//
//  ControllerFocusRing.swift
//  EmulateurGBA
//
//  The controller highlight: one ring around the focused control, drawn above
//  everything in the key window, following the control on every frame while
//  it shows (so a list scrolling, a sheet sliding or the phone turning carry
//  it along).
//
//  Its look (decided 2026-09-27): WHITE, with a soft glow in the chosen
//  look's accent, on the app's dark and themed surfaces; the ACCENT itself on
//  a light surface (the Classic list in light mode), where white would vanish.
//  The accent is the chosen look's (`LandscapeThemeStore`), so the ring
//  changes with the look like every button does.
//
//  MOVING FROM ONE CONTROL TO THE NEXT, the ring's rectangle AND its corner
//  radius travel together, eased on every frame toward where the new control
//  is (device report, 2026-09-27: the first version slid its frame while its
//  outline jumped to the new shape, so a cover's rounded square became the
//  plus button's circle in one step). Easing toward the target every frame,
//  rather than animating to a fixed end, also keeps the glide right when the
//  target itself moves meanwhile (the list scrolling it into view). Outside a
//  glide the ring sits exactly on its control.
//
//  It lives in the key window rather than a window of its own on purpose: a
//  second window on top would take over the status bar's appearance, which
//  the game screen and the looks each set. The ring is brought back to the
//  front on every frame, above any sheet presented since, and never takes a
//  touch.
//

import UIKit

final class ControllerFocusRing {
    private let ringView = RingView()
    private var displayLink: CADisplayLink?
    private weak var navigator: ControllerNavigator?
    private weak var tracked: UIView?
    /// Frames since the last attempt to find the highlight a new place, so a
    /// screen with nothing to reach is not searched sixty times a second.
    private var framesSinceRefocus = 0

    /// What the ring draws now, in window coordinates, and until when it is
    /// still gliding toward its control.
    private var shown: (rect: CGRect, radius: CGFloat)?
    private var glideEnds: CFTimeInterval = 0

    /// Distance between the control's edge and the ring's.
    private static let outset: CGFloat = 4
    /// How long a glide lasts at most, and how much of the remaining way it
    /// covers per 60 Hz frame (about 90 % in 100 ms, all of it by the end).
    private static let glideDuration: CFTimeInterval = 0.32
    private static let glideRatePerFrame: CGFloat = 0.3

    func start(tracking navigator: ControllerNavigator) {
        self.navigator = navigator
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func hide() {
        displayLink?.invalidate()
        displayLink = nil
        tracked = nil
        shown = nil
        ringView.removeFromSuperview()
    }

    /// Put the ring on `view`: gliding there from where it is when `animated`
    /// and it is showing, at once otherwise.
    func moveTo(_ view: UIView, animated: Bool) {
        tracked = view
        guard let window = view.window, let navigator else { return }
        attach(to: window)
        ringView.style(lightSurface: navigator.trackedViewIsOnLightSurface,
                       accent: LandscapeThemeStore.shared.theme.accentUIColor)
        let target = self.target(for: view, navigator: navigator)
        if animated, shown != nil {
            glideEnds = CACurrentMediaTime() + Self.glideDuration
        } else {
            shown = target
            glideEnds = 0
        }
        draw()
    }

    /// A short press answer when A is pressed.
    func pulse() {
        ringView.pulse()
    }

    private func attach(to window: UIWindow) {
        if ringView.superview !== window {
            ringView.removeFromSuperview()
            window.addSubview(ringView)
        } else if window.subviews.last !== ringView {
            window.bringSubviewToFront(ringView)
        }
        if ringView.frame != window.bounds { ringView.frame = window.bounds }
    }

    /// Where the ring belongs around `view`: its frame grown by the outset,
    /// and the corner radius its shape asks for at that size.
    private func target(for view: UIView, navigator: ControllerNavigator) -> (rect: CGRect, radius: CGFloat) {
        let rect = navigator.frameInWindow(view).insetBy(dx: -Self.outset, dy: -Self.outset)
        let radius: CGFloat
        switch navigator.trackedShape {
        case .rounded(let r): radius = r + Self.outset
        case .capsule: radius = rect.height / 2
        case .cell: radius = 10 + Self.outset
        }
        return (rect, min(radius, rect.width / 2, rect.height / 2))
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let navigator else { return hide() }
        framesSinceRefocus += 1
        if framesSinceRefocus >= 6 {
            framesSinceRefocus = 0
            navigator.refocusIfNeeded()
        }
        guard let view = navigator.trackedView, let window = view.window else {
            ringView.isHidden = true
            return
        }
        if view !== tracked {
            moveTo(view, animated: true)
            return
        }
        attach(to: window)
        ringView.isHidden = false
        let target = self.target(for: view, navigator: navigator)
        if let current = shown, CACurrentMediaTime() < glideEnds {
            // Frame-rate independent: the same share of the way per 1/60 s.
            let frames = max(1, CGFloat(link.targetTimestamp - link.timestamp) * 60)
            let t = 1 - pow(1 - Self.glideRatePerFrame, frames)
            shown = (Self.mix(current.rect, target.rect, t), current.radius + (target.radius - current.radius) * t)
        } else {
            shown = target
        }
        draw()
    }

    private func draw() {
        guard let shown else { return }
        ringView.show(rect: shown.rect, radius: shown.radius)
    }

    private static func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }

    /// CADisplayLink retains its target; this breaks the cycle.
    private final class DisplayLinkProxy: NSObject {
        weak var owner: ControllerFocusRing?
        init(owner: ControllerFocusRing) {
            self.owner = owner
            super.init()
        }
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
}

/// The ring itself, spanning the window: one stroke layer whose frame and
/// outline are set on every frame, and, on a dark surface, a glow.
private final class RingView: UIView {
    private let stroke = CAShapeLayer()
    private static let lineWidth: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        stroke.fillColor = UIColor.clear.cgColor
        stroke.lineWidth = Self.lineWidth
        stroke.shadowOffset = .zero
        layer.addSublayer(stroke)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func style(lightSurface: Bool, accent: UIColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if lightSurface {
            stroke.strokeColor = accent.cgColor
            stroke.shadowColor = accent.cgColor
            stroke.shadowOpacity = 0.35
            stroke.shadowRadius = 6
        } else {
            stroke.strokeColor = UIColor.white.cgColor
            stroke.shadowColor = accent.cgColor
            stroke.shadowOpacity = 0.95
            stroke.shadowRadius = 10
        }
        CATransaction.commit()
    }

    /// Draw the ring around `rect` (window coordinates) with `radius`. The
    /// layer is framed on the rect, so a pulse scales it about its own centre.
    func show(rect: CGRect, radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.bounds = CGRect(origin: .zero, size: rect.size)
        stroke.position = CGPoint(x: rect.midX, y: rect.midY)
        let inset = Self.lineWidth / 2
        let body = stroke.bounds.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath(roundedRect: body,
                                cornerRadius: max(0, min(radius - inset, body.width / 2, body.height / 2))).cgPath
        stroke.path = path
        stroke.shadowPath = path.copy(strokingWithWidth: Self.lineWidth, lineCap: .round,
                                      lineJoin: .round, miterLimit: 1)
        CATransaction.commit()
    }

    func pulse() {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1, 0.94, 1.02, 1]
        animation.keyTimes = [0, 0.3, 0.7, 1]
        animation.duration = 0.24
        stroke.add(animation, forKey: "pulse")
    }
}
