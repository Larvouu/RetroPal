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
    var dressKind: DressKind = .ps1 { didSet { applyResting() } }
    var dressVariant: DressVariant = .nostalgia { didSet { applyResting() } }

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
        applyResting()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyResting() {
        if dressed {
            // The moving part is the SAME solid colour as a shoulder bar, not a
            // face tint: on this pad the cross, the shoulders and both sticks
            // are one plastic, and giving the thumb its own tone invented a
            // material the console does not have.
            let face = dressKind == .ps1
                ? (dressVariant.shoulderFace(dressKind) ?? dressKind.faceFill)
                : (dressVariant.abFace(dressKind) ?? dressKind.faceFill)
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
        } else {
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
    private var thumbRadius: CGFloat { dressed ? radius : radius * 0.38 }

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
            radius: max(radius * (1 + holeExcess), 1),
            startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
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
        for piece in [thumbDome, thumbGrain] as [CALayer] {
            piece.frame = box
            let mask = CAShapeLayer()
            mask.path = disc
            piece.mask = mask
        }
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
