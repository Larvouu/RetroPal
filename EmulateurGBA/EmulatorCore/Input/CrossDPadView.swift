//
//  CrossDPadView.swift
//  EmulateurGBA
//
//  Realistic cross-shaped D-pad with 3D depth, beveled edges,
//  and per-direction press highlighting. Drop-in replacement for DPadView.
//

import UIKit

final class CrossDPadView: UIView {
    // Layers for the 3D cross effect
    private let shadowLayer = CAShapeLayer()   // Drop shadow beneath
    private let baseLayer = CAShapeLayer()     // Main cross body
    private let bevelLayer = CAShapeLayer()    // Inner bevel/highlight
    private let centerDot = CAShapeLayer()     // Center circle indent

    // Per-direction highlight layers
    private let highlightUp = CAShapeLayer()
    private let highlightDown = CAShapeLayer()
    private let highlightLeft = CAShapeLayer()
    private let highlightRight = CAShapeLayer()

    private var pressedButtons: UInt32 = 0

    // Cross proportions
    private let armRatio: CGFloat = 0.336  // arm width as fraction of view size (20% wider than the original 0.28)

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Shadow
        shadowLayer.fillColor = UIColor.black.withAlphaComponent(0.15).cgColor
        layer.addSublayer(shadowLayer)

        // Base cross — uses white with alpha to match button transparency style
        baseLayer.fillColor = UIColor.white.withAlphaComponent(0.2).cgColor
        baseLayer.strokeColor = UIColor.white.withAlphaComponent(0.45).cgColor
        baseLayer.lineWidth = 1.5
        baseLayer.lineJoin = .round
        layer.addSublayer(baseLayer)

        // Bevel highlight (inner edge)
        bevelLayer.fillColor = UIColor.clear.cgColor
        bevelLayer.strokeColor = UIColor.white.withAlphaComponent(0.08).cgColor
        bevelLayer.lineWidth = 1.0
        bevelLayer.lineJoin = .round
        layer.addSublayer(bevelLayer)

        // Direction highlights (shown when pressed)
        for hl in [highlightUp, highlightDown, highlightLeft, highlightRight] {
            hl.fillColor = UIColor.white.withAlphaComponent(0.0).cgColor
            hl.lineWidth = 0
            layer.addSublayer(hl)
        }

        // Center indent circle
        centerDot.fillColor = UIColor.white.withAlphaComponent(0.1).cgColor
        centerDot.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        centerDot.lineWidth = 1.0
        layer.addSublayer(centerDot)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildPaths()
        updateHighlights()
    }

    // MARK: - Path building

    private func rebuildPaths() {
        let w = bounds.width
        let h = bounds.height
        let cx = w / 2
        let cy = h / 2
        let halfArm = w * armRatio / 2
        let cornerR: CGFloat = 6  // rounded corners on arm tips

        let crossPath = roundedCrossPath(
            bounds: bounds, halfArm: halfArm, cornerRadius: cornerR
        )

        // Shadow offset
        let shadowPath = crossPath.copy() as! UIBezierPath
        shadowPath.apply(CGAffineTransform(translationX: 1, y: 2))
        shadowLayer.path = shadowPath.cgPath

        baseLayer.path = crossPath.cgPath

        // Bevel: slightly inset cross
        let insetPath = roundedCrossPath(
            bounds: bounds.insetBy(dx: 2, dy: 2), halfArm: halfArm - 2, cornerRadius: cornerR - 1
        )
        bevelLayer.path = insetPath.cgPath

        // Center dot
        let dotR: CGFloat = halfArm * 0.45
        centerDot.path = UIBezierPath(
            arcCenter: CGPoint(x: cx, y: cy), radius: dotR,
            startAngle: 0, endAngle: .pi * 2, clockwise: true
        ).cgPath

        // Direction highlight zones (arm rectangles)
        highlightUp.path = UIBezierPath(
            roundedRect: CGRect(x: cx - halfArm, y: 0, width: halfArm * 2, height: cy - halfArm),
            cornerRadius: cornerR
        ).cgPath
        highlightDown.path = UIBezierPath(
            roundedRect: CGRect(x: cx - halfArm, y: cy + halfArm, width: halfArm * 2, height: cy - halfArm),
            cornerRadius: cornerR
        ).cgPath
        highlightLeft.path = UIBezierPath(
            roundedRect: CGRect(x: 0, y: cy - halfArm, width: cx - halfArm, height: halfArm * 2),
            cornerRadius: cornerR
        ).cgPath
        highlightRight.path = UIBezierPath(
            roundedRect: CGRect(x: cx + halfArm, y: cy - halfArm, width: cx - halfArm, height: halfArm * 2),
            cornerRadius: cornerR
        ).cgPath
    }

    private func roundedCrossPath(bounds: CGRect, halfArm: CGFloat, cornerRadius r: CGFloat) -> UIBezierPath {
        let w = bounds.width
        let h = bounds.height
        let cx = bounds.midX
        let cy = bounds.midY
        let ox = bounds.origin.x
        let oy = bounds.origin.y

        // 12-point cross with rounded corners
        let path = UIBezierPath()
        // Start at top-left of top arm
        path.move(to: CGPoint(x: cx - halfArm + r, y: oy))
        path.addLine(to: CGPoint(x: cx + halfArm - r, y: oy))
        path.addArc(withCenter: CGPoint(x: cx + halfArm - r, y: oy + r), radius: r, startAngle: -.pi/2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: cx + halfArm, y: cy - halfArm))
        // Right arm
        path.addLine(to: CGPoint(x: ox + w - r, y: cy - halfArm))
        path.addArc(withCenter: CGPoint(x: ox + w - r, y: cy - halfArm + r), radius: r, startAngle: -.pi/2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: ox + w, y: cy + halfArm - r))
        path.addArc(withCenter: CGPoint(x: ox + w - r, y: cy + halfArm - r), radius: r, startAngle: 0, endAngle: .pi/2, clockwise: true)
        path.addLine(to: CGPoint(x: cx + halfArm, y: cy + halfArm))
        // Bottom arm
        path.addLine(to: CGPoint(x: cx + halfArm, y: oy + h - r))
        path.addArc(withCenter: CGPoint(x: cx + halfArm - r, y: oy + h - r), radius: r, startAngle: 0, endAngle: .pi/2, clockwise: true)
        path.addLine(to: CGPoint(x: cx - halfArm + r, y: oy + h))
        path.addArc(withCenter: CGPoint(x: cx - halfArm + r, y: oy + h - r), radius: r, startAngle: .pi/2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: cx - halfArm, y: cy + halfArm))
        // Left arm
        path.addLine(to: CGPoint(x: ox + r, y: cy + halfArm))
        path.addArc(withCenter: CGPoint(x: ox + r, y: cy + halfArm - r), radius: r, startAngle: .pi/2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: ox, y: cy - halfArm + r))
        path.addArc(withCenter: CGPoint(x: ox + r, y: cy - halfArm + r), radius: r, startAngle: .pi, endAngle: -.pi/2, clockwise: true)
        path.addLine(to: CGPoint(x: cx - halfArm, y: cy - halfArm))
        // Back to top
        path.addLine(to: CGPoint(x: cx - halfArm, y: oy + r))
        path.addArc(withCenter: CGPoint(x: cx - halfArm + r, y: oy + r), radius: r, startAngle: .pi, endAngle: -.pi/2, clockwise: true)
        path.close()
        return path
    }

    // MARK: - Highlight animation

    private func updateHighlights() {
        let pressColor = UIColor.white.withAlphaComponent(0.25).cgColor
        let clearColor = UIColor.white.withAlphaComponent(0.0).cgColor

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.06)
        highlightUp.fillColor    = (pressedButtons & GBAInput.up.rawValue != 0) ? pressColor : clearColor
        highlightDown.fillColor  = (pressedButtons & GBAInput.down.rawValue != 0) ? pressColor : clearColor
        highlightLeft.fillColor  = (pressedButtons & GBAInput.left.rawValue != 0) ? pressColor : clearColor
        highlightRight.fillColor = (pressedButtons & GBAInput.right.rawValue != 0) ? pressColor : clearColor

        // Subtle tilt toward pressed direction
        var tx: CGFloat = 0, ty: CGFloat = 0
        if pressedButtons & GBAInput.up.rawValue != 0    { ty -= 2 }
        if pressedButtons & GBAInput.down.rawValue != 0  { ty += 2 }
        if pressedButtons & GBAInput.left.rawValue != 0  { tx -= 2 }
        if pressedButtons & GBAInput.right.rawValue != 0 { tx += 2 }
        baseLayer.transform = CATransform3DMakeTranslation(tx, ty, 0)
        bevelLayer.transform = CATransform3DMakeTranslation(tx, ty, 0)
        centerDot.transform = CATransform3DMakeTranslation(tx, ty, 0)
        for hl in [highlightUp, highlightDown, highlightLeft, highlightRight] {
            hl.transform = CATransform3DMakeTranslation(tx, ty, 0)
        }
        CATransaction.commit()
    }

    // MARK: - Public API

    func buttonsForPoint(_ point: CGPoint) -> UInt32 {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        let deadzone = min(bounds.width, bounds.height) * 0.12
        guard dist > deadzone else { return 0 }

        var buttons: UInt32 = 0
        let angle = atan2(dy, dx)
        if angle > -.pi * 0.875 && angle < -.pi * 0.375 { buttons |= GBAInput.up.rawValue }
        if angle > .pi * 0.375 && angle < .pi * 0.875   { buttons |= GBAInput.down.rawValue }
        if angle > .pi * 0.625 || angle < -.pi * 0.625   { buttons |= GBAInput.left.rawValue }
        if angle > -.pi * 0.375 && angle < .pi * 0.375   { buttons |= GBAInput.right.rawValue }
        return buttons
    }

    func setThumbDirection(dx: CGFloat, dy: CGFloat, maxDistance: CGFloat) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let point = CGPoint(x: center.x + dx, y: center.y + dy)
        pressedButtons = buttonsForPoint(point)
        updateHighlights()
    }

    func resetThumb() {
        pressedButtons = 0
        updateHighlights()
    }

    func updateHighlight(buttons: UInt32) {
        pressedButtons = buttons
        updateHighlights()
    }
}
