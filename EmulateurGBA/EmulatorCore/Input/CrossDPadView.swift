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
    /// The Nintendo 64's four triangles, one inside each arm pointing outward,
    /// in the palette's darker pad grey. Hidden on every other console.
    private let n64Arrows = CAShapeLayer()
    /// THE PSP'S ARROWS (2026-10-10, his notes and the PSP-1000's photographs):
    /// the PlayStation's four separate keys, glossy, each carrying an OUTLINED
    /// triangle pointing out, in the palette's print grey; on Retro Pal the keys
    /// are clear glass over the shell. The gloss is a light on each key's upper
    /// half and a bright line along its lower edge, the PSP-1000's highlight.
    private let pspTriangles = CAShapeLayer()
    private let pspGloss = CAShapeLayer()
    private let pspGlints = CAShapeLayer()

    // Per-direction highlight layers
    private let highlightUp = CAShapeLayer()
    private let highlightDown = CAShapeLayer()
    private let highlightLeft = CAShapeLayer()
    private let highlightRight = CAShapeLayer()

    // One short centered ridge line per arm (the light-faced dresses, plus the SNES).
    private let armLines = CAShapeLayer()

    /// THE MEGA DRIVE'S PAD IS A DISC, not a cross-shaped key (asked 2026-10-08:
    /// "draw the D-pad the way it is in real life"). On the six-button pad the
    /// D-pad is a matte round disc that rocks on a pivot under its middle,
    /// with a raised cross moulded on top (arms as thick as the cross every
    /// dressed console here has, reaching almost to its rim, rounded where
    /// they meet the disc), a
    /// concave dimple at the centre, a small engraved triangle in each of the
    /// four quarters between the arms, and the disc sitting in a round gap
    /// inside a glossy bowl in the shell (the bowl and the gap are the
    /// dress's, `MegaDriveSkin.drawCrossWell`). Read off close photographs of
    /// the six-button pad (MK-1653).
    ///
    /// It moves as ONE piece: pressing a direction rocks the whole disc, that
    /// edge sinking into the gap and going into shadow while the opposite edge
    /// rises into the light. So every layer of it lives in one container that
    /// takes the tilt, and nothing lights up on its own the way the other
    /// consoles' arms do. Mega Drive only; every other console's cross is
    /// untouched.
    private let mdRocker = CALayer()
    private let mdDisc = CAShapeLayer()
    /// The disc is dished between the arms, low toward the rim.
    private let mdDish = CAGradientLayer()
    private let mdCrossShadow = CAShapeLayer()
    private let mdCross = CAShapeLayer()
    private let mdRelief = ReliefLayer()
    /// The centre's dimple, sunk: its shading is a hollow's, dark at the top
    /// left where its wall hides the light, lit at the bottom right.
    private let mdNub = CAShapeLayer()
    private let mdNubShade = CAGradientLayer()
    private let mdMarks = CAShapeLayer()
    /// The light on the rocking disc: dark on the side pressed down, a little
    /// lighter on the side coming up.
    private let mdTiltShade = CAGradientLayer()
    /// THE GAME GEAR'S PAD IS A FACETED DISC (asked 2026-10-10, read off close
    /// photographs of the 1990 handheld): a round disc in a round hole, its top
    /// moulded in eight glossy faces. The four arms are each a "home plate",
    /// flat at the rim and coming to a point at the centre, so the four meet in
    /// a crease shaped like an X; the four corner faces between them sit a
    /// step lower and each carries one short engraved tick near the rim, on its
    /// diagonal. No dimple, no arrows. Like the Mega Drive's it rocks whole,
    /// so every layer lives in one container that takes the tilt. The hole and
    /// the bowl round it are the dress's (`GameGearSkin`).
    private let ggRocker = CALayer()
    /// The disc itself, which is what shows as the four lower corner faces.
    private let ggDisc = CAShapeLayer()
    private let ggArms = CAShapeLayer()
    /// The light edge every arm catches along its sides and its rim end.
    private let ggArmEdges = CAShapeLayer()
    /// The X where the four points meet.
    private let ggCrease = CAShapeLayer()
    private let ggTicks = CAShapeLayer()
    /// The gloss over the whole moulding, lit from the top.
    private let ggGloss = CAGradientLayer()
    private let ggTiltShade = CAGradientLayer()

    /// THE MASTER SYSTEM'S PAD IS A RUBBER SQUARE (asked 2026-10-10, read off
    /// photographs of the 3020 pad): a rounded square key, its top nearly
    /// flat with a soft edge, four short raised bars on its axes, four small
    /// raised arrowheads on its diagonals, and a concave cup in its middle
    /// (the socket of the screw-in stick). The grey plate it sits on, the
    /// channel round it and everything printed there are the dress's
    /// (`MasterSystemSkin`). It rocks whole, like the Mega Drive's.
    private let smsRocker = CALayer()
    private let smsKey = CAShapeLayer()
    private let smsKeyShade = CAGradientLayer()
    private let smsReliefs = CAShapeLayer()
    /// The light along each relief's upper edge.
    private let smsReliefCatch = CAShapeLayer()
    private let smsCup = CAShapeLayer()
    private let smsCupShade = CAGradientLayer()
    private let smsTiltShade = CAGradientLayer()

    /// The bombé, and its second offset layer. Built by `Bombe` rather than by
    /// hand here: the helper exists so the four button classes cannot disagree
    /// about the light, and a cross rebuilding the same gradient one file away
    /// was exactly the drift it was written to prevent.
    private let dome = Bombe.make()
    private let core = Bombe.makeCore()
    private let relief = ReliefLayer()   // the Nintendo 64's rim relief

    /// UNIFORM inset of the GBA cross from the full hitbox shape, as a fraction of the width.
    /// Combined with a matching arm-width reduction this leaves a CONSTANT gap all around, so
    /// the dark under-cross reads as an even stroke around the moving cross (not a big patch).
    private let gbaCrossInset: CGFloat = 0.02

    private var pressedButtons: UInt32 = 0

    // Cross proportions
    private let armRatio: CGFloat = CrossDPadView.armRatioShared  // arm width as fraction of view size (20% wider than the original 0.28)
    /// Same number, reachable without an instance: the skin carves the seat
    /// under the PlayStation's four keys and has to use the shape they are
    /// actually drawn from rather than a second guess at it.
    static let armRatioShared: CGFloat = 0.336

    /// Half-width of ONE PlayStation key, as a fraction of the pad's width.
    ///
    /// Narrower than `armRatioShared`, and the number is derived rather than
    /// picked. With the taper at 45 degrees (see `ps1KeyPath`) the straight part
    /// of a key measures `outer - 1.30 * halfArm` tall by `2 * halfArm` wide, and
    /// this is the ratio at which that comes out slightly taller than it is wide
    /// (about 1.15). A key that measures square reads as a tile; this pad's keys
    /// are upright. The skin reads it too, for the seat it carves under them.
    static let ps1ArmRatioShared: CGFloat = 0.278

    /// How far a key stops short of the centre, as a fraction of its half-width.
    ///
    /// It sets the width of the four diagonal channels between the keys, which is
    /// `gap * sqrt(2)`, and those channels ARE the shape: what a hand reads on
    /// this pad is not four mouldings, it is the cross of empty space they leave.
    static let ps1CentreGap: CGFloat = 0.60

    /// The wedge's own two proportions, named because THREE things read them
    /// now: the wedges, the cross mark that has to contain them, and the mark's
    /// arm width. A hair of shell between key and wedge, and a wedge that rises
    /// half of its own base.
    static let ps1WedgeClearance: CGFloat = 0.02   // of the pad's width
    static let ps1WedgeRise: CGFloat = 0.5         // of a key's half-width

    /// How much of the way to the pad's edge a key actually REACHES, measured
    /// from where its taper ends.
    ///
    /// The taper is the half a thumb reads and it is unchanged; what this
    /// shortens is the straight run behind it, so the four keys sit nearer the
    /// middle and the pad stops looking splayed. It shortens the KEY only: the
    /// hitbox still fills the whole control, because `buttonsForPoint` reads an
    /// angle from the centre and never asks how far the drawing got.
    static let ps1KeyReach: CGFloat = 0.70

    /// Where the UP key's middle sits, as a fraction of the pad's height above
    /// the pad's own centre.
    ///
    /// Derived from the two constants above rather than measured off a picture,
    /// so it cannot drift away from the shape actually drawn: the key runs from
    /// the bounds edge (half a height out) inward to `(1 + ps1CentreGap)` of a
    /// half-width short of the centre, and this is the midpoint of that run.
    /// The layout needs it because the cross is placed by where its up key
    /// reads, not by where its bounding box happens to be centred.
    /// The four keys' rotations, up first. One list because two places build the
    /// keys now: the outline itself, and the bombé's per-key core.
    static let ps1KeyRotations: [CGFloat] = [0, .pi, -.pi / 2, .pi / 2]

    static var ps1UpKeyMiddle: CGFloat {
        // Where the taper ends, as a fraction of the pad's height from centre.
        let inner = (1 + ps1CentreGap) * (ps1ArmRatioShared / 2)
        // And where the key now stops, short of the edge by `ps1KeyReach`.
        let outer = inner + ps1KeyReach * (0.5 - inner)
        return (outer + inner) / 2
    }

    // The dark-cross palette (GB/GBC charcoal, SNES near-black) now lives on DressKind, so the
    // cross asks the console for it instead of holding the Game Boy's own copy.

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

        n64Arrows.isHidden = true
        layer.addSublayer(n64Arrows)
        pspTriangles.fillColor = UIColor.clear.cgColor
        pspTriangles.lineJoin = .round
        pspGlints.fillColor = UIColor.clear.cgColor
        pspGlints.lineCap = .round
        for piece in [pspGloss, pspGlints, pspTriangles] as [CALayer] {
            piece.isHidden = true
            layer.addSublayer(piece)
        }

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
        // Above the body, below the direction highlights: a dome shades the
        // plastic, and a press still has to read on top of it.
        layer.insertSublayer(dome, above: baseLayer)
        layer.insertSublayer(core, above: dome)
        layer.insertSublayer(relief, above: core)

        mdRocker.isHidden = true
        mdDish.type = .radial
        mdDish.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor,
                         UIColor.black.withAlphaComponent(0.30).cgColor]
        mdDish.locations = [0, 0.5, 1]
        mdDish.startPoint = CGPoint(x: 0.5, y: 0.5)
        mdDish.endPoint = CGPoint(x: 1, y: 1)
        mdNubShade.colors = [UIColor.black.withAlphaComponent(0.40).cgColor,
                             UIColor.clear.cgColor,
                             UIColor.white.withAlphaComponent(0.16).cgColor]
        mdNubShade.locations = [0, 0.5, 1]
        mdNubShade.startPoint = CGPoint(x: 0.15, y: 0.15)
        mdNubShade.endPoint = CGPoint(x: 0.85, y: 0.85)
        mdMarks.lineJoin = .round
        mdTiltShade.colors = [UIColor.black.withAlphaComponent(0.32).cgColor,
                              UIColor.clear.cgColor,
                              UIColor.white.withAlphaComponent(0.10).cgColor]
        mdTiltShade.locations = [0, 0.5, 1]
        mdTiltShade.opacity = 0
        mdRelief.isHidden = false
        for sub in [mdDisc, mdDish, mdCrossShadow, mdCross, mdRelief, mdNub, mdNubShade,
                    mdMarks, mdTiltShade] as [CALayer] {
            mdRocker.addSublayer(sub)
        }
        layer.addSublayer(mdRocker)

        ggRocker.isHidden = true
        ggArms.lineJoin = .round
        ggArmEdges.fillColor = UIColor.clear.cgColor
        ggArmEdges.lineJoin = .round
        ggCrease.fillColor = UIColor.clear.cgColor
        ggCrease.lineCap = .round
        ggTicks.fillColor = UIColor.clear.cgColor
        ggTicks.lineCap = .round
        ggGloss.colors = [UIColor.white.withAlphaComponent(0.16).cgColor,
                          UIColor.clear.cgColor,
                          UIColor.black.withAlphaComponent(0.18).cgColor]
        ggGloss.locations = [0, 0.5, 1]
        ggGloss.startPoint = CGPoint(x: 0.5, y: 0)
        ggGloss.endPoint = CGPoint(x: 0.5, y: 1)
        ggTiltShade.colors = mdTiltShade.colors
        ggTiltShade.locations = mdTiltShade.locations
        ggTiltShade.opacity = 0
        for sub in [ggDisc, ggArms, ggArmEdges, ggCrease, ggTicks, ggGloss, ggTiltShade] as [CALayer] {
            ggRocker.addSublayer(sub)
        }
        layer.addSublayer(ggRocker)

        smsRocker.isHidden = true
        smsKeyShade.colors = [UIColor.white.withAlphaComponent(0.10).cgColor,
                              UIColor.clear.cgColor,
                              UIColor.black.withAlphaComponent(0.22).cgColor]
        smsKeyShade.locations = [0, 0.5, 1]
        smsKeyShade.startPoint = CGPoint(x: 0, y: 0)
        smsKeyShade.endPoint = CGPoint(x: 1, y: 1)
        smsReliefs.lineJoin = .round
        smsReliefCatch.fillColor = UIColor.clear.cgColor
        smsReliefCatch.lineCap = .round
        // A hollow: dark where its upper wall hides the light, lit below.
        smsCupShade.colors = [UIColor.black.withAlphaComponent(0.45).cgColor,
                              UIColor.clear.cgColor,
                              UIColor.white.withAlphaComponent(0.14).cgColor]
        smsCupShade.locations = [0, 0.55, 1]
        smsCupShade.startPoint = CGPoint(x: 0.5, y: 0)
        smsCupShade.endPoint = CGPoint(x: 0.5, y: 1)
        smsTiltShade.colors = mdTiltShade.colors
        smsTiltShade.locations = mdTiltShade.locations
        smsTiltShade.opacity = 0
        for sub in [smsKey, smsKeyShade, smsReliefs, smsReliefCatch, smsCup, smsCupShade,
                    smsTiltShade] as [CALayer] {
            smsRocker.addSublayer(sub)
        }
        layer.addSublayer(smsRocker)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Resting layer colours for the current `dressed` mode (charcoal cross when dressed,
    /// the default translucent white otherwise). Press highlights are unchanged — the white
    /// overlay reads as a lighten on the dark cross too.
    private func applyResting() {
        // Retro Pal / custom recolour for the dressed cross (nil = untouched, keep Nostalgia).
        let rp = dressVariant.dpadFace(dressKind)
        // The SNES wears the DS's engraved arm lines on a near-black cross instead of a light
        // one, so it joins the light-faced consoles here and takes an inverted ink below. The
        // Game Boy family is deliberately left out: its cross is bare and shipped that way.
        armLines.isHidden = !(dressed && (dressKind.usesLightFaces || dressKind == .snes))
        // THE PLAYSTATION'S CROSS IS FOUR KEYS, not one moulding with lines on
        // it. Everything that describes a continuous cross is switched off: the
        // inner bevel follows the outline of a shape this console does not have,
        // and the centre dot is the hub of a piece that here is a gap.
        let isPS1 = dressed && dressKind == .ps1
        centerDot.isHidden = isPS1
        bevelLayer.isHidden = isPS1
        // The PlayStation's keys wear the rim relief now, each its own
        // (asked 2026-10-09), in place of the bombé they wore until then.
        dome.isHidden = true
        core.isHidden = true
        // The Nintendo 64 wears its rim relief instead (asked 2026-09-27).
        relief.isHidden = !(dressed && (dressKind.wearsRelief || isPS1))
        n64Arrows.isHidden = !(dressed && dressKind == .n64)
        n64Arrows.fillColor = dressVariant.n64.dpadMarks.cgColor
        let isPSP = isPS1 && dressVariant.isPSP
        for piece in [pspGloss, pspGlints, pspTriangles] as [CALayer] { piece.isHidden = !isPSP }
        // The bright line on each arrow belongs to the glass look only (asked
        // 2026-10-10); Nostalgia's keys keep their sheen and their triangle.
        pspGlints.isHidden = !(isPSP && dressVariant.isPSPGlass)
        if isPSP {
            pspTriangles.strokeColor = (dressVariant.ps1Palette?.print ?? .white).cgColor
            let glass = dressVariant.isPSPGlass
            // The sheen on each key's outer half, the side the light falls on.
            pspGloss.fillColor = UIColor.white.withAlphaComponent(glass ? 0.35 : 0.10).cgColor
            pspGlints.strokeColor = UIColor.white.withAlphaComponent(glass ? 0.95 : 0.75).cgColor
            if glass {
                // Glass: the shell shows through, so the key itself is a faint
                // tint of it, its edge a darker line where the glass turns.
                let shell = dressVariant.ps1Palette?.body ?? .white
                baseLayer.fillColor = shell.rpMixed(with: .black, 0.06).withAlphaComponent(0.55).cgColor
                baseLayer.strokeColor = shell.rpMixed(with: .black, 0.38).cgColor
            }
        }
        // The Mega Drive's disc replaces the whole cross (see `mdRocker`).
        let isMD = dressed && dressKind == .md
        mdRocker.isHidden = !isMD
        // The Game Gear's faceted disc replaces it the same way (see `ggRocker`).
        let isGG = dressed && dressKind == .gg
        ggRocker.isHidden = !isGG
        let isSMS = dressed && dressKind == .sms
        smsRocker.isHidden = !isSMS
        for piece in [shadowLayer, baseLayer, bevelLayer, centerDot, relief,
                      highlightUp, highlightDown, highlightLeft, highlightRight] as [CALayer] {
            piece.opacity = (isMD || isGG || isSMS) ? 0 : 1
        }
        if isSMS {
            let rubber = rp ?? dressKind.darkPadFill
            smsKey.fillColor = rubber.cgColor
            smsReliefs.fillColor = rubber.rpMixed(with: .white, 0.10).cgColor
            smsReliefCatch.strokeColor = UIColor.white.withAlphaComponent(0.22).cgColor
            smsCup.fillColor = rubber.rpMixed(with: .black, 0.30).cgColor
        }
        if isGG {
            // One plastic: the arms in it, the corner faces a step lower and
            // so in shadow, the crease and the ticks cut into it.
            let plastic = rp ?? dressKind.darkPadFill
            ggArms.fillColor = plastic.rpMixed(with: .white, 0.08).cgColor
            ggDisc.fillColor = plastic.rpMixed(with: .black, 0.45).cgColor
            ggArmEdges.strokeColor = UIColor.white.withAlphaComponent(0.30).cgColor
            ggCrease.strokeColor = UIColor.black.withAlphaComponent(0.65).cgColor
            ggTicks.strokeColor = UIColor.white.withAlphaComponent(0.32).cgColor
        }
        if isMD {
            // One plastic, disc and cross, as on the pad; the cross's top a
            // shade lighter because it stands up into the light.
            let plastic = rp ?? dressKind.darkPadFill
            mdDisc.fillColor = plastic.cgColor
            mdCross.fillColor = plastic.rpMixed(with: .white, 0.07).cgColor
            mdCrossShadow.fillColor = UIColor.black.withAlphaComponent(0.45).cgColor
            mdNub.fillColor = plastic.rpMixed(with: .black, 0.06).cgColor
            // Engraved: a darker cut, with the light catching its lower edge.
            mdMarks.fillColor = plastic.rpMixed(with: .black, 0.55).cgColor
            mdMarks.shadowColor = UIColor.white.cgColor
            mdMarks.shadowOpacity = 0.14
            mdMarks.shadowRadius = 0
            mdMarks.shadowOffset = CGSize(width: 0, height: 0.75)
        }
        if dressed && dressKind.usesLightFaces {
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
            baseLayer.fillColor = (rp ?? dressKind.darkPadFill).cgColor
            // The NES's edge is the DRESS's job: it strokes the outline the cross has instead of
            // a dish, and a second edge on the view itself sat half a point outside it — a
            // darker line hugging a light one, which is what looked wrong under Retro Pal.
            baseLayer.strokeColor = dressKind == .nes
                ? UIColor.clear.cgColor
                : (rp?.rpEdge ?? dressKind.darkPadEdge).cgColor
            // SNES arm lines: the DS's engraving, inked against whatever the cross actually
            // wears. Nostalgia's cross is near-black and takes a light ink; Retro Pal's is the
            // GBA's light button colour and takes a dark one, so this cannot be a constant.
            // Set for the whole dark-pad branch and harmless to GB/GBC, whose lines stay hidden.
            let crossFill = rp ?? dressKind.darkPadFill
            armLines.strokeColor = crossFill.rpIsLight
                ? UIColor.black.withAlphaComponent(0.22).cgColor
                : UIColor.white.withAlphaComponent(0.28).cgColor
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
        // Nothing to draw until the cross has a size its shapes fit in. The first
        // layout pass reaches here before the controls view has placed it, at
        // 0x0, and the bevel below insets the cross by 2pt a side: `insetBy` on
        // a rect too small for that returns `CGRect.null`, whose origin is
        // infinite, and every point built from it went to CoreGraphics as an
        // invalid number (the "NaN" warnings logged when any game opened).
        guard bounds.width > 4, bounds.height > 4 else { return }
        if dressed && dressKind == .md {
            rebuildMDPaths()
            return
        }
        if dressed && dressKind == .gg {
            rebuildGGPaths()
            return
        }
        if dressed && dressKind == .sms {
            rebuildSMSPaths()
            return
        }
        // GBA: inset the cross by a UNIFORM amount g on every edge AND narrow the arms by the
        // same g, so the gap to the full-size under-cross is constant all around (an even stroke,
        // with the arms still reaching near the tips). Other modes use the full bounds.
        let isModern = dressed && dressKind.usesLightFaces
        let g = isModern ? bounds.width * gbaCrossInset : 0
        let r = bounds.insetBy(dx: g, dy: g)
        let cx = r.midX
        let cy = r.midY
        let halfArm = bounds.width * armRatio / 2 - g
        // Rounded corners on arm tips. The Nintendo 64's cross is rounder, its
        // tips a soft curve rather than a clipped corner (asked 2026-09-27).
        let cornerR: CGFloat = (dressed && dressKind.wearsRelief) ? Self.n64Corner(halfArm: halfArm) : 6

        // FOUR SEPARATE KEYS on the PlayStation, one continuous cross everywhere
        // else. This is the difference a hand notices first between this pad and
        // Nintendo's, and the hitbox is untouched by it: `buttonsForPoint` reads
        // an angle from the centre and never asks what was drawn.
        let isPS1 = dressed && dressKind == .ps1
        // A key is NARROWER than the arm of the continuous cross, because its
        // proportion is set by the space it leaves rather than by the arm width
        // the other six consoles share. `r == bounds` here: the uniform inset
        // above belongs to the light-faced dresses and this is not one.
        let keyHalf = r.width * Self.ps1ArmRatioShared / 2
        let crossPath = isPS1
            ? Self.ps1KeysPath(bounds: r, halfArm: keyHalf, cornerRadius: cornerR)
            : Self.roundedCrossPath(bounds: r, halfArm: halfArm, cornerRadius: cornerR)

        // Shadow offset
        let shadowPath = crossPath.copy() as! UIBezierPath
        shadowPath.apply(CGAffineTransform(translationX: 1, y: 2))
        shadowLayer.path = shadowPath.cgPath

        baseLayer.path = crossPath.cgPath

        // Both bombé layers are clipped to the four keys, so the light falls on
        // the shapes and never into the gaps between them. The core is fitted
        // per KEY rather than to the four at once: fitted to all four it would
        // shrink the whole cross toward one corner, and each key has to dome
        // about its own middle the way each face button does.
        Bombe.fit(dome, over: bounds, clippedTo: crossPath.cgPath)
        if isPS1 {
            let cores = UIBezierPath()
            for rotation in Self.ps1KeyRotations {
                let key = Self.ps1KeyPath(bounds: r, halfArm: keyHalf,
                                          cornerRadius: cornerR, rotation: rotation)
                cores.append(Bombe.coredPath(key))
            }
            Bombe.fit(core, over: bounds, clippedTo: cores.cgPath)
        }
        if dressed && dressKind.wearsRelief {
            relief.fit(over: bounds, clippedTo: crossPath.cgPath)
        } else if isPS1 {
            // One rim per key: the path is the four keys apart, so the rim
            // follows each one's outline, and it is sized for one key (its
            // width), not for the cross the four make together.
            relief.fit(over: bounds, clippedTo: crossPath.cgPath, across: keyHalf * 2)
        }
        if isPS1 {
            layoutPSPArrows(keysPath: crossPath, bounds: r, keyHalf: keyHalf, cornerRadius: cornerR)
        }

        // Bevel: slightly inset cross
        let insetPath = Self.roundedCrossPath(
            bounds: r.insetBy(dx: 2, dy: 2), halfArm: halfArm - 2, cornerRadius: cornerR - 1
        )
        bevelLayer.path = insetPath.cgPath

        // Center dot
        let dotR: CGFloat = halfArm * 0.45
        centerDot.path = UIBezierPath(
            arcCenter: CGPoint(x: cx, y: cy), radius: dotR,
            startAngle: 0, endAngle: .pi * 2, clockwise: true
        ).cgPath

        // THE NINTENDO 64'S TRIANGLES: one inside each arm, pointing out toward
        // the arm's tip, centred in the length of arm beyond the hub. Drawn for
        // the up arm and turned, so the four are the same shape exactly.
        let reach = min(r.width, r.height) / 2 - halfArm       // the arm beyond the hub
        let triHeight = min(reach * 0.5, halfArm * 0.9)
        let triHalfBase = halfArm * 0.55
        let triCentre = halfArm + reach * 0.5                  // from the pad's centre
        let arrows = UIBezierPath()
        for rotation in [CGFloat(0), .pi / 2, .pi, -.pi / 2] {
            let one = UIBezierPath()
            one.move(to: CGPoint(x: 0, y: -(triCentre + triHeight / 2)))
            one.addLine(to: CGPoint(x: triHalfBase, y: -(triCentre - triHeight / 2)))
            one.addLine(to: CGPoint(x: -triHalfBase, y: -(triCentre - triHeight / 2)))
            one.close()
            one.apply(CGAffineTransform(rotationAngle: rotation))
            one.apply(CGAffineTransform(translationX: cx, y: cy))
            arrows.append(one)
        }
        n64Arrows.path = arrows.cgPath

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

        // Direction highlight zones. On the PlayStation they are the KEYS
        // themselves, so a press lights the shape the player is looking at
        // rather than a rectangle over part of it.
        if isPS1 {
            for (hl, rot) in [(highlightUp, CGFloat(0)), (highlightDown, CGFloat.pi),
                              (highlightLeft, -CGFloat.pi / 2), (highlightRight, CGFloat.pi / 2)] {
                hl.path = Self.ps1KeyPath(bounds: r, halfArm: keyHalf,
                                          cornerRadius: cornerR, rotation: rot).cgPath
            }
            return
        }
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

    /// The Mega Drive's disc, cross, nub and marks, all in the rocker's own
    /// coordinates, which are the view's.
    private func rebuildMDPaths() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Bounds and position, not frame: the rocker may be tilted when this
        // runs, and a tilted layer's frame is not something to set.
        mdRocker.bounds = bounds
        mdRocker.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = Self.mdDiscRadius(in: bounds)
        let disc = UIBezierPath(arcCenter: c, radius: radius, startAngle: 0,
                                endAngle: .pi * 2, clockwise: true)
        mdDisc.path = disc.cgPath
        let cross = Self.mdCrossPath(in: bounds)
        mdCross.path = cross.cgPath
        let shadow = cross.copy() as! UIBezierPath
        let drop = max(1, radius * 0.03)
        shadow.apply(CGAffineTransform(translationX: drop * 0.5, y: drop))
        mdCrossShadow.path = shadow.cgPath
        mdRelief.fit(over: bounds, clippedTo: cross.cgPath)

        for gradient in [mdDish, mdTiltShade] {
            gradient.frame = bounds
            let mask = CAShapeLayer()
            mask.path = disc.cgPath
            gradient.mask = mask
        }

        let nubRadius = radius * Self.mdNubRatio
        let nubRect = CGRect(x: c.x - nubRadius, y: c.y - nubRadius,
                             width: nubRadius * 2, height: nubRadius * 2)
        mdNub.path = UIBezierPath(ovalIn: nubRect).cgPath
        mdNubShade.frame = nubRect
        let nubMask = CAShapeLayer()
        nubMask.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: nubRect.size)).cgPath
        mdNubShade.mask = nubMask

        // The marks: a small triangle in each quarter between the arms, near
        // the rim, pointing round the disc.
        let at = radius * Self.mdMarkDistance
        let side = radius * Self.mdMarkSide
        let height = side * CGFloat(3).squareRoot() / 2
        let marks = UIBezierPath()
        for quarter in 0..<4 {
            let one = UIBezierPath()
            // Drawn at the top, on the circle, pointing clockwise (+x), then
            // turned to its quarter's diagonal.
            one.move(to: CGPoint(x: height * 2 / 3, y: -at))
            one.addLine(to: CGPoint(x: -height / 3, y: -at - side / 2))
            one.addLine(to: CGPoint(x: -height / 3, y: -at + side / 2))
            one.close()
            one.apply(CGAffineTransform(rotationAngle: -.pi / 4 + CGFloat(quarter) * .pi / 2))
            one.apply(CGAffineTransform(translationX: c.x, y: c.y))
            marks.append(one)
        }
        mdMarks.path = marks.cgPath
        // The catch is the mark's own shape moved down: given as a path so the
        // rocking disc never makes Core Animation work it out off screen.
        mdMarks.shadowPath = marks.cgPath
    }

    /// The Game Gear's disc, its eight faces, crease and ticks, in the
    /// rocker's own coordinates, which are the view's.
    private func rebuildGGPaths() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        ggRocker.bounds = bounds
        ggRocker.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = Self.mdDiscRadius(in: bounds)
        let disc = UIBezierPath(arcCenter: c, radius: radius, startAngle: 0,
                                endAngle: .pi * 2, clockwise: true)
        ggDisc.path = disc.cgPath
        // The arms run past the rim and the disc cuts them, so their outer
        // ends follow its curve.
        let arms = Self.ggArmsPath(in: bounds).cgPath.intersection(disc.cgPath)
        ggArms.path = arms
        ggArmEdges.path = arms
        ggArmEdges.lineWidth = max(1, radius * 0.022)

        let half = radius * Self.ggArmHalf
        let crease = UIBezierPath()
        crease.move(to: CGPoint(x: c.x - half, y: c.y - half)); crease.addLine(to: CGPoint(x: c.x + half, y: c.y + half))
        crease.move(to: CGPoint(x: c.x + half, y: c.y - half)); crease.addLine(to: CGPoint(x: c.x - half, y: c.y + half))
        ggCrease.path = crease.cgPath
        ggCrease.lineWidth = max(1, radius * 0.025)

        // One tick per corner face, on its diagonal, near the rim.
        let ticks = UIBezierPath()
        for quarter in 0..<4 {
            let angle = CGFloat.pi / 4 + CGFloat(quarter) * .pi / 2
            let dx = cos(angle), dy = sin(angle)
            ticks.move(to: CGPoint(x: c.x + dx * radius * 0.74, y: c.y + dy * radius * 0.74))
            ticks.addLine(to: CGPoint(x: c.x + dx * radius * 0.88, y: c.y + dy * radius * 0.88))
        }
        ggTicks.path = ticks.cgPath
        ggTicks.lineWidth = max(1, radius * 0.03)

        for gradient in [ggGloss, ggTiltShade] {
            gradient.frame = bounds
            let mask = CAShapeLayer()
            mask.path = disc.cgPath
            gradient.mask = mask
        }
    }

    /// The PSP's marks over the PlayStation's four keys: an outlined triangle
    /// on each, pointing out, its base about 0.4 of the key's width, sitting
    /// on the key a little toward its outer edge; the gloss clipped to the
    /// keys; a short bright line inside each key's outer edge.
    private func layoutPSPArrows(keysPath: UIBezierPath, bounds r: CGRect, keyHalf a: CGFloat,
                                 cornerRadius: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let edge = r.height / 2
        let inner = a * Self.ps1CentreGap + a
        let outer = inner + Self.ps1KeyReach * (edge - inner)
        let centreAlong = (inner + outer) / 2 + (outer - inner) * 0.08
        let base = a * 0.78, height = base * 0.866
        let triangles = UIBezierPath(), glints = UIBezierPath()
        for rotation in Self.ps1KeyRotations {
            let one = UIBezierPath()
            one.move(to: CGPoint(x: 0, y: -(centreAlong + height / 2)))
            one.addLine(to: CGPoint(x: base / 2, y: -(centreAlong - height / 2)))
            one.addLine(to: CGPoint(x: -base / 2, y: -(centreAlong - height / 2)))
            one.close()
            let place = CGAffineTransform(rotationAngle: rotation)
                .concatenating(CGAffineTransform(translationX: r.midX, y: r.midY))
            one.apply(place)
            triangles.append(one)
        }
        // The highlight: one short bright line just inside each key's outer
        // edge, drawn in the key's own frame so it follows that edge and stays
        // on the key, and clipped to the keys besides.
        let glintAt = outer - max(1.5, a * 0.18)
        for rotation in Self.ps1KeyRotations {
            let one = UIBezierPath()
            one.move(to: CGPoint(x: -a * 0.55, y: -glintAt))
            one.addLine(to: CGPoint(x: a * 0.55, y: -glintAt))
            one.apply(CGAffineTransform(rotationAngle: rotation)
                .concatenating(CGAffineTransform(translationX: r.midX, y: r.midY)))
            glints.append(one)
        }
        pspTriangles.path = triangles.cgPath
        pspTriangles.lineWidth = max(0.9, a * 0.07)
        pspGlints.path = glints.cgPath
        pspGlints.lineWidth = max(0.75, a * 0.05)
        // The sheen: each key's outer half, cut from the key itself so it
        // cannot leave it. No masks: these layers tilt with the keys the way
        // the cross's own layers do (zero-size, at the view's origin), and a
        // mask on a zero-size layer would hide everything.
        let sheen = UIBezierPath()
        for rotation in Self.ps1KeyRotations {
            let half = UIBezierPath(rect: CGRect(x: -a * 2, y: -outer - a, width: a * 4,
                                                 height: (outer - inner) / 2 + a))
            half.apply(CGAffineTransform(rotationAngle: rotation)
                .concatenating(CGAffineTransform(translationX: r.midX, y: r.midY)))
            sheen.append(half)
        }
        pspGloss.path = keysPath.cgPath.intersection(sheen.cgPath)
    }

    /// The Master System's key and its reliefs, in the rocker's coordinates.
    private func rebuildSMSPaths() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        smsRocker.bounds = bounds
        smsRocker.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let key = Self.smsKeyRect(in: bounds)
        let keyPath = UIBezierPath(roundedRect: key, cornerRadius: key.width * 0.22)
        smsKey.path = keyPath.cgPath
        let c = CGPoint(x: key.midX, y: key.midY), s = key.width
        // Four bars on the axes, four arrowheads on the diagonals, pointing out.
        let reliefs = UIBezierPath(), catches = UIBezierPath()
        let barLength = s * 0.13, barHalf = s * 0.022, barAt = s * 0.30
        let arrowAt = s * 0.31, arrowSide = s * 0.055
        for quarter in 0..<4 {
            let turn = CGAffineTransform(rotationAngle: CGFloat(quarter) * .pi / 2)
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            let bar = UIBezierPath(roundedRect: CGRect(x: -barHalf, y: -barAt - barLength / 2,
                                                       width: barHalf * 2, height: barLength),
                                   cornerRadius: barHalf)
            bar.apply(turn); reliefs.append(bar)
            let lit = UIBezierPath()
            lit.move(to: CGPoint(x: -barHalf * 0.5, y: -barAt - barLength / 2 + barHalf))
            lit.addLine(to: CGPoint(x: -barHalf * 0.5, y: -barAt + barLength / 2 - barHalf))
            lit.apply(turn); catches.append(lit)
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: 0, y: -arrowAt - arrowSide))
            arrow.addLine(to: CGPoint(x: arrowSide * 0.8, y: -arrowAt + arrowSide * 0.5))
            arrow.addLine(to: CGPoint(x: -arrowSide * 0.8, y: -arrowAt + arrowSide * 0.5))
            arrow.close()
            arrow.apply(CGAffineTransform(rotationAngle: CGFloat(quarter) * .pi / 2 + .pi / 4)
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            reliefs.append(arrow)
        }
        smsReliefs.path = reliefs.cgPath
        smsReliefCatch.path = catches.cgPath
        smsReliefCatch.lineWidth = max(0.75, s * 0.008)
        let cupR = s * 0.17
        let cup = UIBezierPath(ovalIn: CGRect(x: c.x - cupR, y: c.y - cupR, width: cupR * 2, height: cupR * 2))
        smsCup.path = cup.cgPath
        smsCupShade.frame = CGRect(x: c.x - cupR, y: c.y - cupR, width: cupR * 2, height: cupR * 2)
        let cupMask = CAShapeLayer()
        cupMask.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: smsCupShade.frame.size)).cgPath
        smsCupShade.mask = cupMask
        for gradient in [smsKeyShade, smsTiltShade] {
            gradient.frame = bounds
            let mask = CAShapeLayer()
            mask.path = keyPath.cgPath
            gradient.mask = mask
        }
    }

    /// The Master System's key inside the control: 82% of it, centred, so the
    /// dress's plate shows round it as on the pad. The dress reads it to carve
    /// the channel the key sits in.
    static func smsKeyRect(in rect: CGRect) -> CGRect {
        let side = min(rect.width, rect.height) * 0.82
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    /// Half an arm's width, as a fraction of the disc's radius: each arm is
    /// about 0.31 of the disc's DIAMETER wide on the hardware.
    static let ggArmHalf: CGFloat = 0.31

    /// The four arms, each a "home plate": flat at the rim, its two sides
    /// parallel, then two edges meeting in a point at the centre, so where the
    /// four meet they draw an X. Run past the rim; the disc cuts them.
    static func ggArmsPath(in rect: CGRect) -> UIBezierPath {
        let radius = mdDiscRadius(in: rect)
        let a = radius * ggArmHalf
        let reach = radius * 1.05
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let path = UIBezierPath()
        for quarter in 0..<4 {
            let arm = UIBezierPath()
            arm.move(to: CGPoint(x: -a, y: -reach))
            arm.addLine(to: CGPoint(x: a, y: -reach))
            arm.addLine(to: CGPoint(x: a, y: -a))
            arm.addLine(to: .zero)
            arm.addLine(to: CGPoint(x: -a, y: -a))
            arm.close()
            arm.apply(CGAffineTransform(rotationAngle: CGFloat(quarter) * .pi / 2))
            arm.apply(CGAffineTransform(translationX: c.x, y: c.y))
            path.append(arm)
        }
        return path
    }

    /// The Mega Drive's disc: the whole control, less a hair so the gap the
    /// dress draws round it shows at rest.
    static func mdDiscRadius(in rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) / 2 - max(1, rect.width * 0.01)
    }
    /// The cross on the disc, as fractions of the disc's radius, read off
    /// close photographs of the six-button pad: reaching 0.90 of the way to
    /// the rim, their ends softly rounded and the four inside corners rounded
    /// wider, where the arm runs down into the disc; the dimple about a sixth
    /// of the disc; the marks small, near the rim on the quarters' diagonals.
    /// The arms keep the thickness the cross had before it sat on a disc
    /// (`armRatioShared` of the control's width, asked 2026-10-08: the
    /// photographs' fifth of the disc read too thin on the glass).
    static let mdArmReach: CGFloat = 0.90
    static let mdNubRatio: CGFloat = 0.17
    static let mdMarkDistance: CGFloat = 0.70
    static let mdMarkSide: CGFloat = 0.11

    static func mdCrossPath(in rect: CGRect) -> UIBezierPath {
        let radius = mdDiscRadius(in: rect)
        let reach = radius * mdArmReach
        let a = min(rect.width, rect.height) * armRatioShared / 2
        let cx = rect.midX, cy = rect.midY
        // Clockwise from the top arm's left end corner.
        let points: [CGPoint] = [
            CGPoint(x: cx - a, y: cy - reach), CGPoint(x: cx + a, y: cy - reach),
            CGPoint(x: cx + a, y: cy - a),
            CGPoint(x: cx + reach, y: cy - a), CGPoint(x: cx + reach, y: cy + a),
            CGPoint(x: cx + a, y: cy + a),
            CGPoint(x: cx + a, y: cy + reach), CGPoint(x: cx - a, y: cy + reach),
            CGPoint(x: cx - a, y: cy + a),
            CGPoint(x: cx - reach, y: cy + a), CGPoint(x: cx - reach, y: cy - a),
            CGPoint(x: cx - a, y: cy - a),
        ]
        let tip = a * 0.35, inside = a * 0.55
        let radii: [CGFloat] = [tip, tip, inside, tip, tip, inside,
                                tip, tip, inside, tip, tip, inside]
        return roundedPolygon(points, radii: radii)
    }

    /// The Nintendo 64's arm-tip radius, for an arm of half-width `halfArm`.
    static func n64Corner(halfArm: CGFloat) -> CGFloat { max(6, halfArm * 0.45) }

    /// The Nintendo 64's cross as the dressed view draws it in `rect`, for the
    /// dress to seat it: one shape, so the seat and the keys cannot disagree.
    static func n64CrossPath(in rect: CGRect) -> UIBezierPath {
        let halfArm = rect.width * armRatioShared / 2
        return roundedCrossPath(bounds: rect, halfArm: halfArm,
                                cornerRadius: n64Corner(halfArm: halfArm))
    }

    /// The four keys in an arbitrary rect, for the skin: the seat carved under
    /// them is this shape grown a little, so the two can never drift apart.
    static func ps1KeysPath(in rect: CGRect, cornerRadius: CGFloat = 6) -> UIBezierPath {
        ps1KeysPath(bounds: rect, halfArm: rect.width * ps1ArmRatioShared / 2,
                    cornerRadius: cornerRadius)
    }

    /// The four wedges the SKIN prints between the keys and the pad's rim.
    ///
    /// NOT CONTROLS. They are moulded marks on the shell, the way the pad's own
    /// plastic is relieved around each direction, and nothing hit-tests them.
    /// They live here rather than in the skin for the same reason the keys' seat
    /// does: every measurement below is taken off the key it sits above, so a
    /// change to the key's reach or width carries them with it instead of
    /// leaving them stranded where the key used to end.
    ///
    /// One wedge, described for the top and turned for the other three: its base
    /// is parallel to the key's outer edge and HALF the key's width, and it
    /// rises from there by half of its own base, pointing away from the centre.
    static func ps1SurroundWedges(in rect: CGRect) -> UIBezierPath {
        let a = rect.width * ps1ArmRatioShared / 2
        let outer = ps1KeyOuter(in: rect)
        let clearance = rect.width * ps1WedgeClearance
        let baseY = -(outer + clearance)
        let baseHalf = a / 2                     // base = half the key's width
        let rise = a * ps1WedgeRise              // and half of that base again

        let path = UIBezierPath()
        for rotation in ps1KeyRotations {
            let one = UIBezierPath()
            one.move(to: CGPoint(x: -baseHalf, y: baseY))
            one.addLine(to: CGPoint(x: baseHalf, y: baseY))
            one.addLine(to: CGPoint(x: 0, y: baseY - rise))
            one.close()
            one.apply(CGAffineTransform(rotationAngle: rotation))
            one.apply(CGAffineTransform(translationX: rect.midX, y: rect.midY))
            path.append(one)
        }
        return path
    }

    /// A cross-shaped mark for the SKIN to print on the plateau, reaching from
    /// wedge tip to wedge tip and wide enough to hold a key.
    ///
    /// It is what ties the four keys and the four wedges into one object instead
    /// of eight loose marks on a disc. Every measurement comes from the same
    /// three constants the keys and the wedges are built from, so it cannot end
    /// up describing a cross that no longer contains them. The corner is the
    /// keys' own arm-tip radius, so the mark and the keys round alike.
    ///
    /// The diamond takes the SAME cross, at the same size, which is why this
    /// takes the pad's rect and the caller re-centres it rather than deriving a
    /// second size from the diamond's own bloc.
    /// How far the mark reaches past a key's TIP: the clearance twice over plus
    /// the wedge itself, so the mark clears the wedge by the same hair that the
    /// wedge clears the key by.
    static func ps1PlateauEndMargin(in rect: CGRect) -> CGFloat {
        let a = rect.width * ps1ArmRatioShared / 2
        return 2 * rect.width * ps1WedgeClearance + a * ps1WedgeRise
    }

    /// Centre to the tip of one arm of the mark.
    static func ps1PlateauReach(in rect: CGRect) -> CGFloat {
        ps1KeyOuter(in: rect) + ps1PlateauEndMargin(in: rect)
    }

    /// The arm half-width that gives every face of a DIAMOND the same margin on
    /// all four sides.
    ///
    /// A face sits `step` out with radius `r`, so its margin outward is
    /// `reach - step - r` and its margin sideways is `armHalf - r`. Setting the
    /// two equal cancels `r` entirely and leaves `armHalf = reach - step`. The
    /// mark keeps the cross's own reach, so both marks span the same distance;
    /// only the arm's width differs, and it differs because what sits inside it
    /// is a diamond rather than a cross.
    static func ps1DiamondArmHalf(reach: CGFloat, step: CGFloat) -> CGFloat {
        Swift.max(1, reach - step)
    }

    static func ps1PlateauCross(in rect: CGRect, armHalf: CGFloat? = nil) -> UIBezierPath {
        let a = rect.width * ps1ArmRatioShared / 2
        let end = ps1PlateauEndMargin(in: rect)
        let reach = ps1KeyOuter(in: rect) + end
        // TWICE AS FAR AT THE ENDS AS ALONG THE FLANKS. An arm clearing its key
        // by the same amount all round reads as thick, because the eye measures
        // a band by its width and a cross by its span; half the margin sideways
        // is what makes this read as a cross drawn AROUND the keys rather than
        // as a slab behind them.
        let half = armHalf ?? (a + end / 2)
        // The INNER angles are rounded too, not just the tips. `roundedCrossPath`
        // leaves them square because every other console's cross is a moulding
        // with a hard shoulder; this is a printed mark, and a printed mark with
        // four sharp reflex corners is the one thing on this pad that looks
        // drawn by a machine.
        let inner = Swift.min(6, half * 0.6)
        let pts = [CGPoint(x: -half, y: -reach), CGPoint(x: half, y: -reach),
                   CGPoint(x: half, y: -half),
                   CGPoint(x: reach, y: -half), CGPoint(x: reach, y: half),
                   CGPoint(x: half, y: half),
                   CGPoint(x: half, y: reach), CGPoint(x: -half, y: reach),
                   CGPoint(x: -half, y: half),
                   CGPoint(x: -reach, y: half), CGPoint(x: -reach, y: -half),
                   CGPoint(x: -half, y: -half)]
        let radii: [CGFloat] = [6, 6, inner, 6, 6, inner, 6, 6, inner, 6, 6, inner]
        let path = roundedPolygon(pts, radii: radii)
        path.apply(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return path
    }

    /// Distance from the pad's centre to a key's OUTER edge — the tip of an
    /// arrow, as a hand sees it.
    ///
    /// The skin asks for it: it sizes the round plateau under the cross from the
    /// band of shell left between the arrow's tip and the plateau's own rim, and
    /// that band only exists because the keys stop short of the edge. Measured
    /// here so it moves with `ps1KeyReach` instead of being a number the skin
    /// keeps its own copy of.
    static func ps1KeyOuter(in rect: CGRect) -> CGFloat {
        let a = rect.width * ps1ArmRatioShared / 2
        let inner = a * (1 + ps1CentreGap)
        return inner + ps1KeyReach * (rect.height / 2 - inner)
    }

    /// The PlayStation's cross: four keys that do not touch.
    ///
    /// Each is ONE moulding: an upright rounded key that tapers to a point at
    /// the centre. It is the taper that tells a thumb which way it is pushing
    /// without a printed arrow, which is why this pad needs no lines drawn on it.
    ///
    /// The four never touch, and the gaps are the point. Their edges are
    /// parallel, so the empty space between them is a cross turned through 45
    /// degrees, and that cross is what the eye actually reads here.
    ///
    /// One path with four subpaths rather than four layers: they are filled and
    /// masked together, and nothing ever needs to address one of them alone.
    private static func ps1KeysPath(bounds b: CGRect, halfArm: CGFloat,
                                    cornerRadius r: CGFloat) -> UIBezierPath {
        // Each key keeps `gap` clear of the centre so the four read as separate,
        // and tapers `point` toward it. Both live in `ps1KeyPath`, which is the
        // only place that needs them.
        let path = UIBezierPath()
        for rotation in ps1KeyRotations {
            path.append(ps1KeyPath(bounds: b, halfArm: halfArm, cornerRadius: r,
                                   rotation: rotation))
        }
        return path
    }

    /// A closed polygon with a radius at every vertex, convex or concave.
    ///
    /// Written once because two shapes here need it and for the same reason:
    /// `addArc(tangent1End:tangent2End:)` is the only rounding that handles an
    /// INNER angle, and both a key and the plateau's cross mark have corners
    /// that turn both ways.
    static func roundedPolygon(_ pts: [CGPoint], radii: [CGFloat]) -> UIBezierPath {
        guard pts.count > 2, radii.count == pts.count else { return UIBezierPath() }
        // Start on the middle of the closing edge, which is straight, so the
        // first arc has a real segment to run back to.
        let path = CGMutablePath()
        let last = pts[pts.count - 1], first = pts[0]
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for i in pts.indices {
            path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % pts.count],
                        radius: radii[i])
        }
        path.closeSubpath()
        return UIBezierPath(cgPath: path)
    }

    /// One PlayStation key, built in "up" orientation and rotated into place.
    ///
    /// Written once and turned rather than four times by hand: four hand-built
    /// shapes drift, and on a cross the eye catches that immediately. The press
    /// highlights use this too, so what lights up is exactly what is drawn.
    private static func ps1KeyPath(bounds b: CGRect, halfArm a: CGFloat, cornerRadius r: CGFloat,
                                   rotation: CGFloat) -> UIBezierPath {
        // Centre-origin, "up" is negative y.
        let edge = b.height / 2       // centre to the bounds edge
        let gap = a * ps1CentreGap    // clearance from the centre
        // THE TAPER REACHES EXACTLY `a` INWARD, so its two edges lie at 45
        // degrees. That is not a styling choice, it is the whole reason the
        // centre reads as a cross: two adjacent keys then present edges of the
        // SAME slope, `gap * sqrt(2)` apart, so the space between them is a
        // parallel channel rather than a wedge, and the four channels meet at
        // the centre as one X. At any other depth the edges converge, which is
        // what the first attempt drew and why it read as four loose blocks.
        let point = a
        // THE KEY STOPS SHORT OF THE EDGE. The taper is untouched; the straight
        // run behind it keeps `ps1KeyReach` of the room it had, which pulls the
        // four keys in toward the middle without changing the half a thumb reads.
        let inner = gap + point
        let outer = inner + Self.ps1KeyReach * (edge - inner)
        let tip = r * 0.5

        // ONE OUTLINE, not a rectangle plus a triangle. Appended as two subpaths
        // they FILL as one shape but they do not LOOK like one: the rectangle
        // keeps its own rounded inner corners, which surface either side of the
        // triangle's base as two small notches, and the eye reads two mouldings
        // pushed together. Traced as a single polygon there is nothing to notch.
        let pts = [CGPoint(x: -a, y: -outer),          // outer edge, left
                   CGPoint(x:  a, y: -outer),          // outer edge, right
                   CGPoint(x:  a, y: -(gap + point)),  // where the taper starts
                   CGPoint(x:  0, y: -gap),            // the tip, at the centre
                   CGPoint(x: -a, y: -(gap + point))]
        // The two outer corners take the arm-tip radius; the three that shape
        // the taper take half of it, because a moulded tip is softened, not
        // rounded off.
        let radii = [r, r, tip, tip, tip]

        let one = Self.roundedPolygon(pts, radii: radii)
        one.apply(CGAffineTransform(rotationAngle: rotation))
        one.apply(CGAffineTransform(translationX: b.midX, y: b.midY))
        return one
    }

    /// STATIC because the skin needs it too: it prints a cross-shaped mark on
    /// the plateau big enough to hold the keys and the wedges together, and that
    /// mark has to be the same cross this view draws rather than a second one
    /// that happens to look similar today. Uses nothing but its arguments.
    static func roundedCrossPath(bounds: CGRect, halfArm: CGFloat, cornerRadius r: CGFloat) -> UIBezierPath {
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
        let pressColor = (dressed && dressKind.usesLightFaces)
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
        // The Mega Drive's disc rocks whole, about its own middle (its
        // container's anchor), and the light shifts across it.
        mdRocker.transform = rocker(for: pressedButtons)
        ggRocker.transform = mdRocker.transform
        smsRocker.transform = mdRocker.transform
        var vx: CGFloat = 0, vy: CGFloat = 0
        if pressedButtons & GBAInput.right.rawValue != 0 { vx += 1 }
        if pressedButtons & GBAInput.left.rawValue != 0  { vx -= 1 }
        if pressedButtons & GBAInput.down.rawValue != 0  { vy += 1 }
        if pressedButtons & GBAInput.up.rawValue != 0    { vy -= 1 }
        let length = (vx * vx + vy * vy).squareRoot()
        if length > 0 {
            vx /= length; vy /= length
            mdTiltShade.startPoint = CGPoint(x: 0.5 + 0.5 * vx, y: 0.5 + 0.5 * vy)
            mdTiltShade.endPoint = CGPoint(x: 0.5 - 0.5 * vx, y: 0.5 - 0.5 * vy)
            mdTiltShade.opacity = 1
            ggTiltShade.startPoint = mdTiltShade.startPoint
            ggTiltShade.endPoint = mdTiltShade.endPoint
            ggTiltShade.opacity = 1
            smsTiltShade.startPoint = mdTiltShade.startPoint
            smsTiltShade.endPoint = mdTiltShade.endPoint
            smsTiltShade.opacity = 1
        } else {
            mdTiltShade.opacity = 0
            ggTiltShade.opacity = 0
            smsTiltShade.opacity = 0
        }
        baseLayer.transform = tilt
        bevelLayer.transform = tilt
        centerDot.transform = tilt
        armLines.transform = tilt
        for hl in [highlightUp, highlightDown, highlightLeft, highlightRight] {
            hl.transform = tilt
        }
        // The PSP's marks ride on its keys.
        for piece in [pspTriangles, pspGlints, pspGloss] as [CALayer] {
            piece.transform = tilt
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
        let rp = rocker(for: buttons)
        guard !CATransform3DIsIdentity(rp) else { return rp }
        let cx = bounds.midX, cy = bounds.midY
        // Rotate about the view center: T(-c) * Rp * T(c).
        var t = CATransform3DConcat(CATransform3DMakeTranslation(-cx, -cy, 0), rp)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(cx, cy, 0))
        return t
    }

    /// The rocker's rotation alone, about whatever point the layer it is given
    /// to turns about: `tilt3D` moves it to the view's centre for the layers
    /// placed at the view's origin; the Mega Drive's container already turns
    /// about its own middle.
    private func rocker(for buttons: UInt32) -> CATransform3D {
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
        var rp = CATransform3DIdentity
        rp.m34 = -1.0 / 500.0
        rp = CATransform3DRotate(rp, ax, 1, 0, 0)
        rp = CATransform3DRotate(rp, ay, 0, 1, 0)
        return rp
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
