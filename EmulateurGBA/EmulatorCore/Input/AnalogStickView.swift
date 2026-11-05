//
//  AnalogStickView.swift
//  EmulateurGBA
//
//  An on-screen analog stick, for the one console whose pad has two of them.
//
//  WHY THIS IS NOT `DPadView`. The app already draws something that looks
//  exactly like this: the preset "joystick" directional type, a dish with a
//  thumb. It is a CROSS wearing a round coat. Whatever angle you push it to, it
//  reports one of eight directions, because every console before the
//  PlayStation had a digital pad and nothing else to report.
//
//  A real stick reports the direction AND how far. That difference is the whole
//  point of the control: it is what lets a character walk instead of run, and
//  what a camera needs in order to pan slowly. Making the existing joystick
//  answer both questions would have left one control returning two different
//  kinds of answer depending on the console, so this is its own view.
//
//  IT HANDLES ITS OWN TOUCHES, which no other control here does. TouchControlsView
//  hit-tests every button itself and keeps them non-interactive, and that is
//  right for buttons: they are a bitmask assembled from all the fingers at once.
//  A stick is not a bit. It owns a finger from the moment it lands until it
//  lifts, it follows that finger outside its own bounds, and two sticks have to
//  be draggable at the same time without either noticing the other. UIKit does
//  all of that already for a view with `isMultipleTouchEnabled`; reproducing it
//  in the parent's shared touch loop would be re-implementing the framework.
//

import UIKit

final class AnalogStickView: UIView {

    /// The stick's position, each axis -1...1, y positive DOWN.
    ///
    /// Down-positive because that is what UIKit, libretro and the PlayStation
    /// all use. GameController is the odd one out, and its flip lives at that
    /// boundary rather than in here.
    private(set) var value: CGPoint = .zero

    /// Fired whenever `value` changes, including the return to centre.
    var onChange: ((CGPoint) -> Void)?

    /// How far the thumb may travel from the centre, as a fraction of the
    /// control's radius. The rest is the rim, which is there to be seen rather
    /// than reached.
    private let travelFraction: CGFloat = 0.62

    /// Below this the stick reads as centred. A thumb resting on glass drifts by
    /// a pixel or two constantly, and a PlayStation game reading a stick that
    /// never quite returns to zero walks slowly forever.
    private let deadzone: CGFloat = 0.12

    /// The hole the cap sits in: black, and a little WIDER than the cap, so what
    /// shows of it is a thin ring all the way round. It is the only thing on this
    /// control that is not the cap.
    private let holeLayer = CAShapeLayer()
    private let baseLayer = CAShapeLayer()
    private let thumbLayer = CAShapeLayer()
    /// The thumb's dome: a light catch from the top right falling to shadow at
    /// the bottom left, clipped to the thumb. A stick is the one control here
    /// that is spherical, and a flat disc reads as a hole rather than a knob.
    private let thumbDome = CAGradientLayer()
    /// The cap's plastic texture, the SAME pattern the shell is grained with, so
    /// the cap reads as moulded from the case rather than printed on it. A
    /// pattern-image background rather than a drawn fill, because this layer
    /// moves with the thumb and a pattern follows its layer for free.
    private let thumbGrain = CALayer()
    /// THE NINTENDO 64'S CAP, which is not the PlayStation's: a disc with two
    /// concentric rings set into it a shade darker, and a small dark hole at its
    /// centre that reads as a recess. All three move with the cap.
    private let n64Rings = CAShapeLayer()
    private let n64RingCatch = CAShapeLayer()
    private let n64Hole = CAShapeLayer()
    /// The hole's inner wall: shadow on the side the light comes from (the top
    /// right), light on the far wall, which is what makes a disc read as a hole.
    private let n64HoleWall = CAGradientLayer()
    private var activeTouch: UITouch?

    // MARK: Dress

    /// `setNeedsLayout` as well as a restyle: dressing now changes the cap's SIZE
    /// (it becomes the whole control) and how far it is drawn, not just colours.
    var dressed = false {
        didSet { guard dressed != oldValue else { return }; applyResting(); setNeedsLayout() }
    }
    var dressKind: DressKind = .ps1 { didSet { applyResting(); setNeedsLayout() } }
    // A relayout too: the PSP's nub is drawn smaller (`thumbRadius`).
    var dressVariant: DressVariant = .nostalgia { didSet { applyResting(); setNeedsLayout() } }

    /// THE 3DS'S CIRCLE PAD upright (his design, 2026-10-21, third pass).
    /// The control is two things: the SURROUND, the outer ring, which never
    /// moves because it is the shell's hole the pad sits in (carved by the skin,
    /// `ConsoleSkinView.drawButtonWells`), and the PAD inside it, the only part
    /// that moves, as far as the other sticks' caps do (its edge to the
    /// control's centre). The pad wears the PlayStation's cap, as the C-stick
    /// does; the black under it is the pad's size. What the finger does is
    /// unchanged (`travel`, `deadzone`).
    enum CTRLook { case none, circlePad }
    var ctrLook: CTRLook = .none { didSet { guard ctrLook != oldValue else { return }; applyResting(); setNeedsLayout() } }
    /// THE 3DS'S HOLE, under both its sticks (his ask, 2026-10-21): not a flat
    /// black disc but a well, the wall a dark grey at the lip falling to black,
    /// the far (lower-left) wall catching a little light.
    private let ctrHole = CAGradientLayer()
    private let ctrHoleWall = CAGradientLayer()
    /// THE CIRCLE PAD'S DISH (his ask, 2026-10-21): highest at its rim, sinking
    /// steadily to its centre, the deepest point. Two layers clipped to the cap:
    /// the depth (clear at the rim, darker to the centre) and the light, which
    /// in a dish falls the other way from a dome's (the inner slope facing the
    /// top-right light is the far one, lower left). The raised rim catches the
    /// light on its own top-right edge (`ctrRim`).
    private let ctrDepth = CAGradientLayer()
    private let ctrDishLight = CAGradientLayer()
    private let ctrRim = CAShapeLayer()

    /// The circle pad's raised rim, as a fraction of the pad's radius.
    static let circlePadRim: CGFloat = 0.12

    /// How much of the control the circle pad itself is: the rest is the
    /// still surround.
    static let circlePadScale = ControlLayoutDefaults.AnalogStickViewMetrics.circlePadScale

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false   // one finger per stick; two sticks, two views
        baseLayer.lineWidth = 2
        thumbLayer.lineWidth = 1.5
        holeLayer.fillColor = UIColor.black.cgColor
        layer.addSublayer(holeLayer)
        layer.addSublayer(baseLayer)
        layer.addSublayer(thumbLayer)
        thumbDome.startPoint = CGPoint(x: 1, y: 0)     // light from the top right
        thumbDome.endPoint = CGPoint(x: 0, y: 1)       // shadow at the bottom left
        // Under the dome so the light falls ON the grain, not beside it.
        thumbGrain.backgroundColor = UIColor(patternImage: GameBoySkin.grain).cgColor
        thumbGrain.opacity = 0.5
        thumbGrain.isHidden = true
        layer.addSublayer(thumbGrain)
        layer.addSublayer(thumbDome)
        n64RingCatch.fillColor = UIColor.clear.cgColor
        n64Rings.fillColor = UIColor.clear.cgColor
        n64HoleWall.startPoint = CGPoint(x: 1, y: 0)
        n64HoleWall.endPoint = CGPoint(x: 0, y: 1)
        n64HoleWall.colors = [UIColor.black.withAlphaComponent(0.85).cgColor,
                              UIColor.black.withAlphaComponent(0.35).cgColor,
                              UIColor.white.withAlphaComponent(0.18).cgColor]
        n64HoleWall.locations = [0, 0.6, 1]
        for piece in [n64RingCatch, n64Rings, n64Hole, n64HoleWall] as [CALayer] {
            piece.isHidden = true
            layer.addSublayer(piece)
        }
        // The 3DS's hole over the plain black one (which it hides), under the cap.
        ctrHole.type = .radial
        ctrHole.startPoint = CGPoint(x: 0.5, y: 0.5)
        ctrHole.endPoint = CGPoint(x: 1, y: 0.5)   // the gradient's edge on the disc's
        ctrHole.colors = [UIColor.black.cgColor, UIColor.black.cgColor,
                          UIColor(white: 0.10, alpha: 1).cgColor, UIColor(white: 0.22, alpha: 1).cgColor]
        ctrHole.locations = [0, 0.62, 0.86, 1]
        ctrHoleWall.startPoint = CGPoint(x: 1, y: 0)
        ctrHoleWall.endPoint = CGPoint(x: 0, y: 1)
        ctrHoleWall.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor,
                              UIColor.white.withAlphaComponent(0.16).cgColor]
        ctrHoleWall.locations = [0, 0.6, 1]
        layer.insertSublayer(ctrHole, above: holeLayer)
        layer.insertSublayer(ctrHoleWall, above: ctrHole)
        ctrDepth.type = .radial
        ctrDepth.startPoint = CGPoint(x: 0.5, y: 0.5)
        ctrDepth.endPoint = CGPoint(x: 1, y: 0.5)   // the gradient's edge on the disc's
        ctrDepth.colors = [UIColor.black.withAlphaComponent(0.30).cgColor,
                           UIColor.black.withAlphaComponent(0.12).cgColor,
                           UIColor.clear.cgColor]
        // Flat (clear) across the rim, so the dish starts where the rim ends.
        ctrDepth.locations = [NSNumber(value: 0), NSNumber(value: 0.55),
                              NSNumber(value: Double(1 - Self.circlePadRim))]
        ctrDishLight.startPoint = CGPoint(x: 1, y: 0)
        ctrDishLight.endPoint = CGPoint(x: 0, y: 1)
        ctrDishLight.colors = [UIColor.black.withAlphaComponent(0.18).cgColor,
                               UIColor.clear.cgColor,
                               UIColor.white.withAlphaComponent(0.20).cgColor]
        ctrDishLight.locations = [0, 0.5, 1]
        ctrRim.fillColor = UIColor.clear.cgColor
        ctrRim.lineCap = .round
        for piece in [ctrHole, ctrHoleWall] as [CALayer] { piece.isHidden = true }
        for piece in [ctrDepth, ctrDishLight, ctrRim] as [CALayer] {
            piece.isHidden = true
            layer.addSublayer(piece)
        }
        applyResting()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyResting() {
        if dressed {
            // The moving part is the SAME solid colour as a shoulder bar, not a
            // face tint: on this pad the cross, the shoulders and both sticks
            // are one plastic, and giving the thumb its own tone invented a
            // material the console does not have.
            var face = dressKind == .ps1
                ? (dressVariant.shoulderFace(dressKind) ?? dressKind.faceFill)
                : (dressVariant.abFace(dressKind) ?? dressKind.faceFill)
            // The PSP's nub (2026-10-10): the shell's black on Nostalgia, as on
            // the PSP-1000; #AFB2B6 on Retro Pal.
            if dressKind == .ps1, dressVariant.isPSP {
                face = dressVariant.pspPalette?.stick ?? UIColor(rpHex: 0x1E1E1E)
            }
            // The 3DS's circle pad and C-stick, their own slot.
            if let ctr = dressVariant.ctrPalette { face = ctr.sticks }
            // THE DISH IS GONE. The cap now fills the control, so a dish behind it
            // would never be seen; what reads as the seat is the black hole, which
            // is a real thing on the hardware where the dish never was.
            baseLayer.isHidden = true
            holeLayer.isHidden = false
            // OPAQUE. The cap was translucent so the dish showed through it; with
            // no dish there is nothing behind it but the shell, and a control you
            // can see the case through is a control that reads as a decal.
            thumbLayer.fillColor = face.cgColor
            thumbLayer.strokeColor = face.rpEdge.cgColor
            thumbDome.isHidden = false
            thumbGrain.isHidden = false
            // The N64's stick has neither the PlayStation's grain nor the black
            // ring of its hole: a plain grey disc, carved as described above.
            let isN64 = dressKind == .n64
            thumbGrain.isHidden = isN64
            holeLayer.isHidden = isN64
            for piece in [n64Rings, n64RingCatch, n64Hole, n64HoleWall] as [CALayer] {
                piece.isHidden = !isN64
            }
            if isN64 {
                let stick = dressVariant.n64.stick
                thumbLayer.fillColor = stick.cgColor
                thumbLayer.strokeColor = stick.rpEdge.cgColor
                n64Rings.strokeColor = DressKind.n64Incised(stick).cgColor
                n64RingCatch.strokeColor = stick.rpMixed(with: .white, 0.30).cgColor
                n64Hole.fillColor = stick.rpMixed(with: .black, 0.70).cgColor
            }
            thumbDome.colors = [UIColor.white.withAlphaComponent(0.22).cgColor,
                                UIColor.clear.cgColor,
                                UIColor.black.withAlphaComponent(0.22).cgColor]
            thumbDome.locations = [0, 0.5, 1]
            // The 3DS: a well under both sticks, and the circle pad's dish.
            let isCTR = dressVariant.ctrPalette != nil
            for piece in [ctrHole, ctrHoleWall] as [CALayer] { piece.isHidden = !isCTR }
            let dish = isCTR && ctrLook == .circlePad
            for piece in [ctrDepth, ctrDishLight, ctrRim] as [CALayer] { piece.isHidden = !dish }
            if dish {
                thumbDome.isHidden = true
                thumbGrain.isHidden = true
                ctrRim.strokeColor = face.rpMixed(with: .white, 0.55).cgColor
            }
        } else {
            for piece in [ctrHole, ctrHoleWall, ctrDepth, ctrDishLight, ctrRim] as [CALayer] {
                piece.isHidden = true
            }
            thumbDome.isHidden = true
            thumbGrain.isHidden = true
            for piece in [n64Rings, n64RingCatch, n64Hole, n64HoleWall] as [CALayer] {
                piece.isHidden = true
            }
            baseLayer.isHidden = false
            holeLayer.isHidden = true
            baseLayer.fillColor = UIColor.white.withAlphaComponent(0.15).cgColor
            baseLayer.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
            thumbLayer.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
            thumbLayer.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
        }
    }

    // MARK: Geometry

    private var radius: CGFloat { min(bounds.width, bounds.height) / 2 }

    /// How far past the cap the black hole shows, as a fraction of the radius.
    private let holeExcess: CGFloat = 0.07

    /// The cap. DRESSED IT IS THE WHOLE CONTROL; undressed it keeps the small
    /// knob-in-a-dish the custom-preset look has always drawn.
    private var thumbRadius: CGFloat {
        guard dressed else { return radius * 0.38 }
        if ctrLook == .circlePad { return radius * Self.circlePadScale }
        // The PSP's nub is drawn smaller than the other consoles' sticks (asked
        // 2026-10-10); what a thumb can touch, and how far it pushes, is not.
        return dressKind == .ps1 && dressVariant.isPSP ? radius * Self.pspNubScale : radius
    }
    /// How much of the control the PSP's nub draws.
    static let pspNubScale: CGFloat = 0.72

    /// How far the finger may travel, for INPUT. Unchanged by any of the drawing
    /// below: this is what the value is divided by, so touching it would change
    /// how hard the player has to push, which is not a look.
    private var travel: CGFloat { radius * travelFraction }

    /// How far the cap is DRAWN from centre at full tilt: far enough that its
    /// trailing EDGE arrives exactly on the control's own centre, and no
    /// further. A cap the size of the control travelling by its own radius is
    /// the largest move that still leaves the centre covered, so the control
    /// never reads as having slid off the hole it sits in.
    ///
    /// Separate from `travel`, which maps the FINGER and is untouched by any of
    /// this: changing that would change how hard the player has to push, which
    /// is not a look.
    private var drawnTravel: CGFloat { dressed ? thumbRadius : travel }

    override func layoutSubviews() {
        super.layoutSubviews()
        baseLayer.path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(radius - 1, 1),
            startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        // The hole does not move with the cap: it is the shell, not the control.
        holeLayer.path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            // Round the cap actually drawn (the PSP's is smaller than the control).
            radius: max((dressed ? thumbRadius : radius) * (1 + holeExcess), 1),
            startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        // The 3DS's well, the hole's own disc.
        let holeR = max((dressed ? thumbRadius : radius) * (1 + holeExcess), 1)
        let holeBox = CGRect(x: bounds.midX - holeR, y: bounds.midY - holeR, width: holeR * 2, height: holeR * 2)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for piece in [ctrHole, ctrHoleWall] as [CALayer] {
            piece.frame = holeBox
            let mask = CAShapeLayer()
            mask.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: holeBox.size)).cgPath
            piece.mask = mask
        }
        CATransaction.commit()
        drawThumb()
    }

    private func drawThumb() {
        guard radius > 0 else { return }
        let centre = CGPoint(x: bounds.midX + value.x * drawnTravel,
                             y: bounds.midY + value.y * drawnTravel)
        let path = UIBezierPath(
            arcCenter: centre, radius: thumbRadius,
            startAngle: 0, endAngle: .pi * 2, clockwise: true)
        thumbLayer.path = path.cgPath
        // The dome travels with the thumb, clipped to it, so the light stays on
        // the knob rather than washing the dish it moves in.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let box = CGRect(x: centre.x - thumbRadius, y: centre.y - thumbRadius,
                         width: thumbRadius * 2, height: thumbRadius * 2)
        let disc = UIBezierPath(ovalIn: CGRect(origin: .zero, size: box.size)).cgPath
        // Named `piece`, not `layer`: `layer` is this view's own and shadowing it
        // inside the loop is how the wrong one gets masked one edit from now.
        for piece in [thumbDome, thumbGrain, ctrDepth, ctrDishLight] as [CALayer] {
            piece.frame = box
            let mask = CAShapeLayer()
            mask.path = disc
            piece.mask = mask
        }
        // The dish's raised rim, lit on its top-right edge (the light's side).
        // Twice as wide since 2026-10-21 (his ask), growing inward: its outer
        // edge stays the pad's, as the radius below keeps it.
        ctrRim.lineWidth = max(1, thumbRadius * Self.circlePadRim)
        ctrRim.path = UIBezierPath(arcCenter: centre, radius: thumbRadius - ctrRim.lineWidth / 2,
                                   startAngle: -.pi * 0.85, endAngle: .pi * 0.15, clockwise: true).cgPath
        // The N64's carving, centred on the cap wherever it has moved.
        let ringWidth = max(1, thumbRadius * 0.05)
        let rings = UIBezierPath()
        for fraction in [CGFloat(0.72), 0.46] {
            rings.append(UIBezierPath(arcCenter: centre, radius: thumbRadius * fraction,
                                      startAngle: 0, endAngle: .pi * 2, clockwise: true))
        }
        n64Rings.lineWidth = ringWidth
        n64RingCatch.lineWidth = ringWidth
        n64Rings.path = rings.cgPath
        let catchRings = rings.copy() as! UIBezierPath
        catchRings.apply(CGAffineTransform(translationX: 0, y: 1))
        n64RingCatch.path = catchRings.cgPath
        let holeRadius = thumbRadius * 0.16
        let hole = UIBezierPath(arcCenter: centre, radius: holeRadius,
                                startAngle: 0, endAngle: .pi * 2, clockwise: true)
        n64Hole.path = hole.cgPath
        n64HoleWall.frame = CGRect(x: centre.x - holeRadius, y: centre.y - holeRadius,
                                   width: holeRadius * 2, height: holeRadius * 2)
        let wallMask = CAShapeLayer()
        wallMask.path = UIBezierPath(ovalIn: CGRect(origin: .zero,
                                                    size: n64HoleWall.frame.size)).cgPath
        n64HoleWall.mask = wallMask
        CATransaction.commit()
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        track(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        track(active)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        activeTouch = nil
        recentre()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    /// The finger is followed OUTSIDE the control, which is what makes a stick
    /// usable on glass: a thumb pushed hard travels further than the dish, and
    /// stopping at the rim would read as the player letting go at full tilt.
    private func track(_ touch: UITouch) {
        guard travel > 0 else { return }
        let p = touch.location(in: self)
        var dx = (p.x - bounds.midX) / travel
        var dy = (p.y - bounds.midY) / travel
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > 1 { dx /= distance; dy /= distance }
        if (dx * dx + dy * dy).squareRoot() < deadzone { dx = 0; dy = 0 }
        set(CGPoint(x: dx, y: dy))
    }

    private func recentre() {
        set(.zero)
    }

    private func set(_ new: CGPoint) {
        guard new != value else { return }
        value = new
        drawThumb()
        onChange?(new)
    }

    /// Drop any finger and return to centre. Called when the controls are
    /// hidden or the layout changes under them, so a stick cannot be left
    /// held down by a touch nobody will ever end.
    func reset() {
        activeTouch = nil
        recentre()
    }
}
