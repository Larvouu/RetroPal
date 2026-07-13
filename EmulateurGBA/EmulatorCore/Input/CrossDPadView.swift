//
//  CrossDPadView.swift
//  EmulateurGBA
//
//  Realistic cross-shaped D-pad with 3D depth, beveled edges,
//  and per-direction press highlighting. Drop-in replacement for DPadView.
//

import UIKit

/// Shared direction mapping for BOTH touch-control styles — the cross
/// `CrossDPadView` and the joystick `DPadView` — so the angle sectors live in
/// ONE place (they were duplicated, and a fix to one silently missed the other).
///
/// Angles are in `atan2(dy, dx)` screen space: 0 = right, +π/2 = down, ±π = left,
/// -π/2 = up (y grows downward). Each cardinal fires within `cardinalHalfWidth`
/// of its axis. The four cardinals sit 90° apart, so two adjacent ones overlap by
/// `2*cardinalHalfWidth - 90°` around each 45° corner, and BOTH fire there (a
/// diagonal). At 56° that overlap is a narrow 22°: a diagonal must be aimed at the
/// corner, while a thumb roll near a cardinal no longer trips an accidental second
/// direction (the actual UX complaint on 4-way games). 67.5° would restore the old
/// equal 45° wedges, where a full half of the circle fired a diagonal.
/// Deadzone/distance gating stays per-view; this maps only the angle.
enum DPadGeometry {
    /// Half-width of each cardinal's active sector. 56° → 68°-wide pure-cardinal
    /// zones + 22°-wide diagonal zones centred on each corner. Tunable: raise
    /// toward 67.5° for easier diagonals, lower toward 45° for stricter cardinals.
    static let cardinalHalfWidth: CGFloat = 56 * .pi / 180

    static func buttons(forAngle angle: CGFloat) -> UInt32 {
        let h = cardinalHalfWidth
        var buttons: UInt32 = 0
        if angle > -.pi / 2 - h && angle < -.pi / 2 + h { buttons |= GBAInput.up.rawValue }
        if angle >  .pi / 2 - h && angle <  .pi / 2 + h { buttons |= GBAInput.down.rawValue }
        if angle > -h && angle < h                       { buttons |= GBAInput.right.rawValue }
        if angle > .pi - h || angle < -.pi + h           { buttons |= GBAInput.left.rawValue }
        return buttons
    }
}

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

    // One short centered ridge line per arm (GBA dress only).
    private let armLines = CAShapeLayer()

    /// UNIFORM inset of the GBA cross from the full hitbox shape, as a fraction of the width.
    /// Combined with a matching arm-width reduction this leaves a CONSTANT gap all around, so
    /// the dark under-cross reads as an even stroke around the moving cross (not a big patch).
    private let gbaCrossInset: CGFloat = 0.02

    private var pressedButtons: UInt32 = 0

    // Cross proportions
    private let armRatio: CGFloat = 0.336  // arm width as fraction of view size (20% wider than the original 0.28)

    // GB/GBC dressed palette (charcoal cross), applied only when `dressed` is on.
    private static let dpadFill = UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
    private static let dpadEdge = UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)

    /// When on, the cross wears the GB/GBC console-dress look (near-black) instead of the
    /// default translucent white. Set by TouchControlsView for the GB/GBC default layout.
    var dressed = false {
        didSet { guard dressed != oldValue else { return }; applyResting(); setNeedsLayout() }
    }

    /// Which console palette to wear when dressed: GB/GBC charcoal cross vs GBA light #C4BFCF.
    var dressKind: DressKind = .gbc {
        didSet { guard dressKind != oldValue else { return }; applyResting(); updateHighlights(); setNeedsLayout() }
    }

    /// Nostalgia vs the Retro Pal recolour (set by TouchControlsView.setDressed).
    var dressVariant: DressVariant = .nostalgia {
        didSet { guard dressVariant != oldValue else { return }; applyResting(); updateHighlights(); setNeedsLayout() }
    }

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

        // Arm ridge lines (GBA only; shown via applyResting).
        armLines.fillColor = UIColor.clear.cgColor
        armLines.lineWidth = 1.5
        armLines.lineCap = .round
        armLines.isHidden = true
        layer.addSublayer(armLines)

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

    /// Resting layer colours for the current `dressed` mode (charcoal cross when dressed,
    /// the default translucent white otherwise). Press highlights are unchanged — the white
    /// overlay reads as a lighten on the dark cross too.
    private func applyResting() {
        // Retro Pal / custom recolour for the dressed cross (nil = untouched, keep Nostalgia).
        let rp = dressVariant.dpadFace(dressKind)
        armLines.isHidden = !(dressed && dressKind != .gbc)
        if dressed && dressKind != .gbc {
            // GBA/NDS: a light cross, so the relief lines invert to dark. NDS draws its arm lines
            // in the #777777 ink; GBA keeps a translucent-black engraving.
            baseLayer.fillColor = (rp ?? dressKind.faceFill).cgColor
            baseLayer.strokeColor = (rp?.rpEdge ?? dressKind.faceEdge).cgColor
            bevelLayer.strokeColor = UIColor.black.withAlphaComponent(0.10).cgColor
            centerDot.fillColor = UIColor.black.withAlphaComponent(0.10).cgColor
            centerDot.strokeColor = UIColor.white.withAlphaComponent(0.40).cgColor
            shadowLayer.fillColor = UIColor.black.withAlphaComponent(0.25).cgColor
            // NDS arm lines: #777777 ink (custom: the ink slot; Retro Pal: also #777777).
            armLines.strokeColor = dressKind == .nds
                ? (dressVariant.ndsPalette?.letters
                   ?? (dressVariant == .retroPal ? RetroPalPalette.ndsInk : DressKind.ndsInk)).cgColor
                : UIColor.black.withAlphaComponent(0.22).cgColor
        } else if dressed {
            baseLayer.fillColor = (rp ?? Self.dpadFill).cgColor
            baseLayer.strokeColor = (rp?.rpEdge ?? Self.dpadEdge).cgColor
            bevelLayer.strokeColor = UIColor.white.withAlphaComponent(0.10).cgColor
            centerDot.fillColor = UIColor.black.withAlphaComponent(0.25).cgColor
            centerDot.strokeColor = UIColor.white.withAlphaComponent(0.15).cgColor
            shadowLayer.fillColor = UIColor.black.withAlphaComponent(0.25).cgColor
        } else {
            baseLayer.fillColor = UIColor.white.withAlphaComponent(0.2).cgColor
            baseLayer.strokeColor = UIColor.white.withAlphaComponent(0.45).cgColor
            bevelLayer.strokeColor = UIColor.white.withAlphaComponent(0.08).cgColor
            centerDot.fillColor = UIColor.white.withAlphaComponent(0.1).cgColor
            centerDot.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
            shadowLayer.fillColor = UIColor.black.withAlphaComponent(0.15).cgColor
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildPaths()
        updateHighlights()
    }

    // MARK: - Path building

    private func rebuildPaths() {
        // GBA: inset the cross by a UNIFORM amount g on every edge AND narrow the arms by the
        // same g, so the gap to the full-size under-cross is constant all around (an even stroke,
        // with the arms still reaching near the tips). Other modes use the full bounds.
        let isModern = dressed && dressKind != .gbc
        let g = isModern ? bounds.width * gbaCrossInset : 0
        let r = bounds.insetBy(dx: g, dy: g)
        let cx = r.midX
        let cy = r.midY
        let halfArm = bounds.width * armRatio / 2 - g
        let cornerR: CGFloat = 6  // rounded corners on arm tips

        let crossPath = roundedCrossPath(bounds: r, halfArm: halfArm, cornerRadius: cornerR)

        // Shadow offset
        let shadowPath = crossPath.copy() as! UIBezierPath
        shadowPath.apply(CGAffineTransform(translationX: 1, y: 2))
        shadowLayer.path = shadowPath.cgPath

        baseLayer.path = crossPath.cgPath

        // Bevel: slightly inset cross
        let insetPath = roundedCrossPath(
            bounds: r.insetBy(dx: 2, dy: 2), halfArm: halfArm - 2, cornerRadius: cornerR - 1
        )
        bevelLayer.path = insetPath.cgPath

        // Center dot
        let dotR: CGFloat = halfArm * 0.45
        centerDot.path = UIBezierPath(
            arcCenter: CGPoint(x: cx, y: cy), radius: dotR,
            startAngle: 0, endAngle: .pi * 2, clockwise: true
        ).cgPath

        // One short centered ridge line per arm, ALONG the arm direction (vertical on the
        // up/down arms, horizontal on the left/right arms).
        let lines = UIBezierPath()
        let len = halfArm * 0.9
        let upY = (r.minY + (cy - halfArm)) / 2
        lines.move(to: CGPoint(x: cx, y: upY - len / 2)); lines.addLine(to: CGPoint(x: cx, y: upY + len / 2))
        let dnY = ((cy + halfArm) + r.maxY) / 2
        lines.move(to: CGPoint(x: cx, y: dnY - len / 2)); lines.addLine(to: CGPoint(x: cx, y: dnY + len / 2))
        let lX = (r.minX + (cx - halfArm)) / 2
        lines.move(to: CGPoint(x: lX - len / 2, y: cy)); lines.addLine(to: CGPoint(x: lX + len / 2, y: cy))
        let rX = ((cx + halfArm) + r.maxX) / 2
        lines.move(to: CGPoint(x: rX - len / 2, y: cy)); lines.addLine(to: CGPoint(x: rX + len / 2, y: cy))
        armLines.path = lines.cgPath

        // Direction highlight zones (arm rectangles, within the drawn cross rect r)
        highlightUp.path = UIBezierPath(
            roundedRect: CGRect(x: cx - halfArm, y: r.minY, width: halfArm * 2, height: (cy - halfArm) - r.minY),
            cornerRadius: cornerR
        ).cgPath
        highlightDown.path = UIBezierPath(
            roundedRect: CGRect(x: cx - halfArm, y: cy + halfArm, width: halfArm * 2, height: r.maxY - (cy + halfArm)),
            cornerRadius: cornerR
        ).cgPath
        highlightLeft.path = UIBezierPath(
            roundedRect: CGRect(x: r.minX, y: cy - halfArm, width: (cx - halfArm) - r.minX, height: halfArm * 2),
            cornerRadius: cornerR
        ).cgPath
        highlightRight.path = UIBezierPath(
            roundedRect: CGRect(x: cx + halfArm, y: cy - halfArm, width: r.maxX - (cx + halfArm), height: halfArm * 2),
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
        // Light GBA cross darkens on press; the dark GB/GBC cross lightens.
        let pressColor = (dressed && dressKind != .gbc)
            ? UIColor.black.withAlphaComponent(0.18).cgColor
            : UIColor.white.withAlphaComponent(0.25).cgColor
        let clearColor = UIColor.white.withAlphaComponent(0.0).cgColor

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.06)
        highlightUp.fillColor    = (pressedButtons & GBAInput.up.rawValue != 0) ? pressColor : clearColor
        highlightDown.fillColor  = (pressedButtons & GBAInput.down.rawValue != 0) ? pressColor : clearColor
        highlightLeft.fillColor  = (pressedButtons & GBAInput.left.rawValue != 0) ? pressColor : clearColor
        highlightRight.fillColor = (pressedButtons & GBAInput.right.rawValue != 0) ? pressColor : clearColor

        // Press feedback: a true perspective 3D tilt when dressed (the pressed arm rocks down
        // into the case), or the original flat nudge when undressed (byte-identical).
        let tilt = dressed ? tilt3D(for: pressedButtons) : flatNudge(for: pressedButtons)
        baseLayer.transform = tilt
        bevelLayer.transform = tilt
        centerDot.transform = tilt
        armLines.transform = tilt
        for hl in [highlightUp, highlightDown, highlightLeft, highlightRight] {
            hl.transform = tilt
        }
        CATransaction.commit()
    }

    /// The original flat nudge toward the pressed direction (undressed).
    private func flatNudge(for buttons: UInt32) -> CATransform3D {
        var tx: CGFloat = 0, ty: CGFloat = 0
        if buttons & GBAInput.up.rawValue != 0    { ty -= 2 }
        if buttons & GBAInput.down.rawValue != 0  { ty += 2 }
        if buttons & GBAInput.left.rawValue != 0  { tx -= 2 }
        if buttons & GBAInput.right.rawValue != 0 { tx += 2 }
        return CATransform3DMakeTranslation(tx, ty, 0)
    }

    /// A perspective tilt that rocks the cross toward the pressed direction (the pressed arm
    /// recedes into the case), rotated about the view center. Dressed only. If the rocker
    /// tilts the wrong way on device, negate `maxTilt`.
    private func tilt3D(for buttons: UInt32) -> CATransform3D {
        // 0.14: a single-axis press tilts the same amount a clean diagonal already did
        // (diagonal normalizes 0.20 to 0.20/√2 ≈ 0.14 per axis), so the dark under-cross no
        // longer reveals broadly on a single up/left press.
        let maxTilt: CGFloat = 0.14   // ~8° max rocker angle
        var ax: CGFloat = 0, ay: CGFloat = 0
        if buttons & GBAInput.up.rawValue != 0    { ax += maxTilt }   // top arm sinks
        if buttons & GBAInput.down.rawValue != 0  { ax -= maxTilt }
        if buttons & GBAInput.left.rawValue != 0  { ay -= maxTilt }
        if buttons & GBAInput.right.rawValue != 0 { ay += maxTilt }
        guard ax != 0 || ay != 0 else { return CATransform3DIdentity }
        // Normalize so a diagonal (two arrows) tilts by the same total angle as one arrow,
        // instead of compounding to ~1.4-2x toward the corner.
        let mag = (ax * ax + ay * ay).squareRoot()
        if mag > maxTilt { ax *= maxTilt / mag; ay *= maxTilt / mag }
        let cx = bounds.midX, cy = bounds.midY
        var rp = CATransform3DIdentity
        rp.m34 = -1.0 / 500.0
        rp = CATransform3DRotate(rp, ax, 1, 0, 0)
        rp = CATransform3DRotate(rp, ay, 0, 1, 0)
        // Rotate about the view center: T(-c) * Rp * T(c).
        var t = CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0), rp)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(cx, cy, 0))
        return t
    }

    // MARK: - Public API

    func buttonsForPoint(_ point: CGPoint) -> UInt32 {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        let deadzone = min(bounds.width, bounds.height) * 0.12
        guard dist > deadzone else { return 0 }

        return DPadGeometry.buttons(forAngle: atan2(dy, dx))
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
