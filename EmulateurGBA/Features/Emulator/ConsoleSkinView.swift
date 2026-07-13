//
//  ConsoleSkinView.swift
//  EmulateurGBA
//
//  The "console dress": a purely cosmetic layer drawn BEHIND the game screen and the
//  on-screen controls, turning the plain black in-game page into a console-like shell
//  (Game Boy grey body, screen surround, printed decorations). It consumes the same
//  geometry as the screen + controls (screenFrame, deviceScale) and never affects
//  input — `isUserInteractionEnabled` is false. Only the built-in default layout is
//  dressed; with a custom preset the host hides this view (plain background returns).
//
//  Inspired-by, not a replica: we evoke the era's colours/shapes with our own art and
//  use NO third-party logos or wordmarks.
//
//  Slice 1: GB/GBC body (grain texture) + screen surround (extended under the screen
//  identity) + the interrupted "DOT MATRIX WITH STEREO SOUND" stripe band + the BATTERY
//  power LED. Speaker / power switch / PHONES decals, button wells and the restyled
//  buttons land in later slices.
//

import UIKit
import CoreImage

/// Draws one console's dress into a Core Graphics context, from the in-game geometry.
/// Implementations are stateless; the view owns the geometry and triggers redraws.
protocol ConsoleSkin {
    func draw(in ctx: CGContext, bounds: CGRect, screenFrame: CGRect,
              buttons: [ControlElement: CGRect], isLandscape: Bool, usesJoystick: Bool, scale: CGFloat)
}

final class ConsoleSkinView: UIView {
    /// The system whose dress to draw. `.gbc` (DMG) and `.gba` have skins.
    var system: PresetSystem = .gba { didSet { if system != oldValue { setNeedsDisplay() } } }
    /// The game-screen rect (this view's coordinates) the surround is drawn around.
    var screenFrame: CGRect = .zero { didSet { if screenFrame != oldValue { setNeedsDisplay() } } }
    /// Per-device scale (matches `EmulatorLayoutGeometry.deviceScale`).
    var deviceScale: CGFloat = 1 { didSet { if deviceScale != oldValue { setNeedsDisplay() } } }
    /// Current on-screen control frames (this view's coords) — used to place decorations
    /// (and later button wells) clear of the controls. Set by the host after layout.
    var buttonFrames: [ControlElement: CGRect] = [:] { didSet { setNeedsDisplay() } }
    /// Whether the directional control is the joystick (vs the cross D-pad). Set by the host;
    /// the GBA dress hides its under-cross when the joystick is in use.
    var usesJoystick: Bool = false { didSet { if usesJoystick != oldValue { setNeedsDisplay() } } }

    /// NDS only: the two game-screen sub-frames (this view's coords) — portrait [top, bottom],
    /// landscape [left, right]. The combined box stays in `screenFrame`; the skin outlines each
    /// screen and places the speakers relative to them. Set by the host after layout.
    var ndsScreens: [CGRect] = [] { didSet { if ndsScreens != oldValue { setNeedsDisplay() } } }
    /// NDS only: whether the Mic button is held (its dress label shrinks + recolours on press).
    var micPressed: Bool = false { didSet { if micPressed != oldValue { setNeedsDisplay() } } }

    /// Nostalgia vs the Retro Pal recolour (set by the host alongside the controls' variant).
    var variant: DressVariant = .nostalgia { didSet { if variant != oldValue { setNeedsDisplay() } } }

    /// GB/GBC only: drop the A/B seat relief (the recessed pill + under-discs around A/B). Used by
    /// the Pro screenshot card, where those reliefs read as stray lines around the buttons.
    var hideABSeat: Bool = false { didSet { if hideABSeat != oldValue { setNeedsDisplay() } } }

    /// GB/GBC Pro screenshot card: re-place the decorations for the square card (PHONES at 25%
    /// width, speaker rotated 90° under the A/B block, the brand mark above the screen).
    var cardMode: Bool = false { didSet { if cardMode != oldValue { setNeedsDisplay() } } }

    /// Whether a hardware controller is connected (the on-screen pad is hidden and the screen grows).
    /// The dress hides/repositions the controls-relative decorations only in this state; the
    /// no-controller dress is untouched. Set by the host after layout.
    var controllerConnected: Bool = false { didSet { if controllerConnected != oldValue { setNeedsDisplay() } } }
    /// ALL control frames (including the ones hidden by controller mode), in this view's coords.
    /// Lets a decoration anchor to a button that is hidden but still laid out at its normal spot
    /// (used only in `controllerConnected` branches). Set by the host after layout.
    var allButtonFrames: [ControlElement: CGRect] = [:] { didSet { setNeedsDisplay() } }

    /// Whether a system has a dress at all — the host uses this to show/hide the view.
    static func hasSkin(for system: PresetSystem) -> Bool {
        system == .gbc || system == .gba || system == .nds
    }

    /// Whether the on-screen controls get the dressed look. Tracks `hasSkin`.
    static func hasDressedControls(for system: PresetSystem) -> Bool {
        system == .gbc || system == .gba || system == .nds
    }

    private var skin: ConsoleSkin? {
        switch system {
        case .gbc: return GameBoySkin(variant: variant, hideABSeat: hideABSeat, cardMode: cardMode,
                                      controllerConnected: controllerConnected)
        case .gba: return GameBoyAdvanceSkin(variant: variant, cardMode: cardMode,
                                             controllerConnected: controllerConnected, allButtons: allButtonFrames)
        case .nds: return NintendoDSSkin(screens: ndsScreens, micPressed: micPressed, variant: variant,
                                         cardMode: cardMode, controllerConnected: controllerConnected)
        default:   return nil
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false   // never intercepts touches
        backgroundColor = .clear
        contentMode = .redraw              // redraw when bounds change (rotation)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let skin else { return }
        skin.draw(in: ctx, bounds: bounds, screenFrame: screenFrame, buttons: buttonFrames,
                  isLandscape: bounds.width > bounds.height, usesJoystick: usesJoystick, scale: deviceScale)
    }
}

// MARK: - Game Boy (DMG) skin

/// The original Game Boy (DMG-01) dress: warm grained-grey body, a dark screen surround
/// (extended to carry the screen-identity decorations) with the iconic oversized
/// bottom-right curve, the maroon/indigo stripe band interrupted by the
/// "DOT MATRIX WITH STEREO SOUND" text, and the red BATTERY LED. Decoration positions
/// adapt to the space around the screen (above it when there's room; beside it otherwise).
struct GameBoySkin: ConsoleSkin {

    /// Nostalgia vs the Retro Pal recolour.
    var variant: DressVariant = .nostalgia
    /// Drop the A/B seat relief (Pro screenshot card only).
    var hideABSeat: Bool = false
    /// Pro screenshot card: re-place PHONES / speaker / brand for the square card.
    var cardMode: Bool = false
    /// A hardware controller is connected: the on-screen pad is hidden. GB/GBC then hides the
    /// speaker (both orientations) and the PHONES badge (portrait); the rest is unchanged.
    var controllerConnected: Bool = false

    // Palette derived from the DMG reference (hex codes are the device-verified targets). Body,
    // surround, creusé and the A/B under-disc swap to the Retro Pal palette under `.retroPal`;
    // everything else is untouched per the draft. Under `.custom`, the user palette drives each
    // element from its own slot (`body`, `surround`, `dpad`, `stripe`, `printedText`, `labels`,
    // `brand`, `led`); recessed seats stay derived from `body`.
    private var customPalette: GBCSkinPalette? { variant.gbcPalette }

    private var bodyTop: UIColor {
        if let p = customPalette { return RetroPalPalette.bodyGradient(p.body).top }
        return variant == .retroPal ? RetroPalPalette.bodyGradient(RetroPalPalette.gbcBody).top
                                    : UIColor(red: 0.808, green: 0.796, blue: 0.792, alpha: 1) }
    private var bodyMid: UIColor {
        if let p = customPalette { return p.body }
        return variant == .retroPal ? RetroPalPalette.gbcBody
                                    : UIColor(red: 0.753, green: 0.741, blue: 0.737, alpha: 1) } // #C0BDBC
    private var bodyBottom: UIColor {
        if let p = customPalette { return RetroPalPalette.bodyGradient(p.body).bottom }
        return variant == .retroPal ? RetroPalPalette.bodyGradient(RetroPalPalette.gbcBody).bottom
                                    : UIColor(red: 0.643, green: 0.627, blue: 0.620, alpha: 1) }
    private var creuse: UIColor {
        // The recessed seats / wells keep the same darker-than-body relationship Nostalgia has
        // (#C0BDBC body → #9E9D9B creusé ≈ body −18% luminance).
        if let p = customPalette { return p.body.rpMixed(with: .black, 0.18) }
        return variant == .retroPal ? RetroPalPalette.gbcCreuse
                                    : UIColor(red: 0.620, green: 0.616, blue: 0.608, alpha: 1) } // #9E9D9B
    private var dpadDark: UIColor {
        if let p = customPalette { return p.dpad }
        return variant == .retroPal ? RetroPalPalette.gbcDark
                                    : UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1) } // under-disc, matches dressed D-pad
    private var surround: UIColor {
        if let p = customPalette { return p.surround }
        return variant == .retroPal ? RetroPalPalette.gbcSurround
                                    : UIColor(red: 0.427, green: 0.427, blue: 0.427, alpha: 1) } // #6D6D6D
    /// The two "DOT MATRIX" stripe lines: maroon + indigo (Nostalgia) → both #ECCE5B (Retro Pal)
    /// → the user's single stripe colour (custom).
    private var stripeTop: UIColor {
        if let p = customPalette { return p.stripe }
        return variant == .retroPal ? RetroPalPalette.gbcStripe : maroon }
    private var stripeBottom: UIColor {
        if let p = customPalette { return p.stripe }
        return variant == .retroPal ? RetroPalPalette.gbcStripe : indigo }
    /// Printed BATTERY + DOT MATRIX text: warm white (built-ins) → the user's printed-text colour.
    private var printedTextColor: UIColor { customPalette?.printedText ?? label }
    /// The battery LED: red (built-ins) → the user's LED colour (custom).
    private var ledColor: UIColor { customPalette?.led ?? ledOn }
    /// Portrait SELECT/START printed label: indigo (built-ins) → the user's labels colour (custom).
    private var ssPortraitLabelColor: UIColor { customPalette?.labels ?? indigo }
    private let maroon     = UIColor(red: 0.549, green: 0.122, blue: 0.325, alpha: 1) // #8C1F53 (stripe line)
    private let indigo     = UIColor(red: 0.106, green: 0.098, blue: 0.451, alpha: 1) // #1B1973 (stripe + SELECT/START labels)
    private let label      = UIColor(red: 0.937, green: 0.933, blue: 0.902, alpha: 1) // warm white (printed labels)
    private let ledOn      = UIColor(red: 0.831, green: 0.157, blue: 0.176, alpha: 1)

    /// Retro Pal: the brand mark icon + "Retro Pal" wordmark mirror the PORTRAIT SELECT label
    /// colour (indigo). Built once.
    private static let retroPalBrandIcon: UIImage? = RetroPalPalette.brandIcon(
        tinted: UIColor(red: 0.106, green: 0.098, blue: 0.451, alpha: 1))   // indigo #1B1973
    /// The brand mark colour (icon + wordmark): not a user slot. Custom auto-derives a contrasting
    /// same-hue tint from the body so it always reads on the body yet fits it.
    private var brandColor: UIColor {
        if customPalette != nil { return bodyMid.rpContrastingMark }
        return variant == .retroPal ? indigo : surround }
    /// Landscape SELECT/START printed label: Retro Pal → the menu-icon colour (matches the pill);
    /// custom → the user's labels colour (unified with portrait).
    private var ssLandscapeLabelColor: UIColor {
        if let p = customPalette { return p.labels }
        return variant == .retroPal ? UIColor.white.withAlphaComponent(0.85) : indigo
    }

    /// Subtle plastic grain, generated once and tiled over the body. Shared with the GBA skin
    /// (it's a neutral black/white speckle, independent of either palette).
    static let grain: UIImage = makeGrain()

    /// The Retro Pal brand mark, tinted to a body-coloured duotone (sepia-like monochrome:
    /// dark → #C0BDBC) so it reads like printed-in-the-plastic art. Built once.
    private static let ciContext = CIContext(options: nil)
    private static let brandIcon: UIImage? = {
        guard let base = UIImage(named: "RetroPalBrand"), let ci = CIImage(image: base),
              let f = CIFilter(name: "CIColorMonochrome", parameters: [
                  kCIInputImageKey: ci,
                  "inputColor": CIColor(red: 0.753, green: 0.741, blue: 0.737),  // #C0BDBC
                  "inputIntensity": 1.0,
              ]),
              let out = f.outputImage,
              let cg = Self.ciContext.createCGImage(out, from: out.extent) else { return UIImage(named: "RetroPalBrand") }
        return UIImage(cgImage: cg)
    }()

    func draw(in ctx: CGContext, bounds: CGRect, screenFrame screen: CGRect,
              buttons: [ControlElement: CGRect], isLandscape: Bool, usesJoystick: Bool, scale: CGFloat) {
        drawBody(ctx, bounds)
        guard !screen.isEmpty else { return }
        // Recessed seats under every control (both orientations). Drawn before the surround
        // and decals so those sit on top where they meet.
        drawButtonWells(buttons: buttons, isLandscape: isLandscape, scale: scale)
        // Portrait and landscape are independent paths so tuning one never touches the
        // other. Portrait carries the full screen identity (stripes + BATTERY); landscape
        // is just a clean frame for now (identity returns when we polish landscape).
        if isLandscape {
            let surroundRect = drawLandscapeSurround(ctx, bounds: bounds, screen: screen, scale: scale)
            drawLandscapeDecals(bounds: bounds, screen: screen, surround: surroundRect,
                                buttons: buttons, scale: scale)
        } else {
            let deco = portraitDeco(screen: screen, bounds: bounds, scale: scale)
            drawPortraitSurround(ctx, screen: screen, deco: deco, scale: scale)
            drawStripeBand(ctx, in: deco.band, scale: scale)
            drawBatteryLED(ctx, deco: deco, scale: scale)
            drawPortraitDecals(bounds: bounds, screen: screen, surround: deco.surroundRect,
                               buttons: buttons, scale: scale)
        }
        // Case-printed SELECT/START identifiers, drawn last so they always sit on top of the
        // body and the recessed wells.
        drawButtonLabels(buttons: buttons, isLandscape: isLandscape, scale: scale)
    }

    // MARK: Body

    private func drawBody(_ ctx: CGContext, _ bounds: CGRect) {
        // Base vertical gradient.
        let colors = [bodyTop.cgColor, bodyMid.cgColor, bodyBottom.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: bounds.midX, y: bounds.minY),
                                   end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
        } else {
            bodyMid.setFill(); ctx.fill(bounds)
        }
        // Soft corner vignette for depth.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let vigColors = [UIColor.clear.cgColor,
                         UIColor.black.withAlphaComponent(0.12).cgColor] as CFArray
        if let vig = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: vigColors, locations: [0.55, 1]) {
            let radius = max(bounds.width, bounds.height) * 0.62
            ctx.drawRadialGradient(vig, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius,
                                   options: .drawsAfterEndLocation)
        }
        // Plastic grain, tiled at low opacity.
        Self.grain.drawAsPattern(in: bounds)
    }

    /// 64×64 deterministic speckle tile (stable across redraws).
    private static func makeGrain() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size).image { rc in
            let ctx = rc.cgContext
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 40) & 0xFFFFFF) / CGFloat(0xFFFFFF)
            }
            for _ in 0..<1100 {
                let x = rnd() * size.width, y = rnd() * size.height
                let dark = rnd() < 0.5
                let a = 0.03 + rnd() * 0.05
                (dark ? UIColor.black : UIColor.white).withAlphaComponent(a).setFill()
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }

    // MARK: Decoration layout

    private struct DecoLayout {
        let band: CGRect          // the interrupted-stripe band (above the screen)
        let ledCenter: CGPoint
        let ledRadius: CGFloat
        let batteryOrigin: CGPoint   // top-left where "BATTERY" is drawn
        let batteryFont: CGFloat
        let surroundRect: CGRect  // the surround panel (already clamped clear of the edges)
    }

    /// Portrait screen identity: the surround is grown from the screen by the decoration
    /// margins (mirrored right/bottom) but kept clear of the device edges. The stripe band
    /// is centered in the actual top margin and the LED + BATTERY cluster in the actual
    /// left margin (so it reads centered there, and never overlaps the screen).
    private func portraitDeco(screen: CGRect, bounds: CGRect, scale: CGFloat) -> DecoLayout {
        let bandH = 22 * scale
        let ledR = 5 * scale
        let battFont = 6.5 * scale
        let battSize = measure("BATTERY", size: battFont, kern: 0.5 * scale)
        let gap = 8 * scale
        let edgeMargin = 8 * scale

        let clusterW = max(ledR * 2, battSize.width)
        let desiredPadH = clusterW + 2 * gap
        let desiredPadV = bandH + 2 * gap

        // Grow from the screen, then clamp so the surround keeps a little space to the
        // device edges (never edge-to-edge).
        let surroundRect = screen.insetBy(dx: -desiredPadH, dy: -desiredPadV)
            .intersection(bounds.insetBy(dx: edgeMargin, dy: edgeMargin))

        // Cluster centered in the ACTUAL left margin; band centered in the actual top margin.
        let cx = (surroundRect.minX + screen.minX) / 2
        let ledCenter = CGPoint(x: cx, y: screen.minY + ledR + 4 * scale)
        let battOrigin = CGPoint(x: cx - battSize.width / 2,
                                 y: ledCenter.y + ledR + 5 * scale)

        let bandCenterY = (surroundRect.minY + screen.minY) / 2
        let band = CGRect(x: screen.minX, y: bandCenterY - bandH / 2,
                          width: screen.width, height: bandH)

        return DecoLayout(band: band, ledCenter: ledCenter, ledRadius: ledR,
                          batteryOrigin: battOrigin, batteryFont: battFont,
                          surroundRect: surroundRect)
    }

    // MARK: Button wells (slice 3a)

    /// Recessed seats under each control so the buttons read as seated in the case. Uses the
    /// real laid-out button frames (default layout only) and the same creusé recess finish
    /// as the PHONES badge / speaker. Hitboxes are untouched — this is purely cosmetic.
    ///  - D-pad: a round dished well.
    ///  - A/B: one diagonal pill recess around the pair (the DMG shared seat).
    ///  - SELECT/START/MENU/CLIP: a capsule well each.
    private func drawButtonWells(buttons: [ControlElement: CGRect], isLandscape: Bool, scale: CGFloat) {
        if let d = buttons[.dpad] {
            let r = max(d.width, d.height) / 2 + 4 * scale
            let c = CGPoint(x: d.midX, y: d.midY)
            drawRecessedCapsule(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r),
                                scale: scale)
        }
        if !hideABSeat, let a = buttons[.btnA], let b = buttons[.btnB] {
            // Shared diagonal pill recess around the pair (the DMG seat)...
            let dia = max(a.width, a.height, max(b.width, b.height)) + 12 * scale
            drawRecessedSlit(from: CGPoint(x: a.midX, y: a.midY),
                             to: CGPoint(x: b.midX, y: b.midY), thickness: dia, scale: scale,
                             textured: true)
            // ...plus a button-sized charcoal disc (the D-pad colour) under each, so a
            // pressed (shrinking) button reveals it — deepening the "incrustée" feel.
            for f in [a, b] {
                let r = min(f.width, f.height) / 2
                let rect = CGRect(x: f.midX - r, y: f.midY - r, width: 2 * r, height: 2 * r)
                let disc = UIBezierPath(ovalIn: rect)
                dpadDark.setFill(); disc.fill()
                drawRecessedRelief(disc, outer: UIBezierPath(ovalIn: rect.insetBy(dx: -2 * scale,
                                                                                  dy: -2 * scale)),
                                   scale: scale)
            }
        }
        for e in [ControlElement.btnSelect, .btnStart] {
            if let f = buttons[e] {
                // Recessed seat matching the button's pill. Endpoints inset by half the
                // thickness so the rounded ends land within the hitbox.
                let pillT = min(f.width, f.height) * Self.pillThicknessRatio
                let p1: CGPoint, p2: CGPoint
                if isLandscape {
                    // Horizontal seat at the upper third of the hitbox (matches the .pillTop
                    // pill — pill at 1/3, label at 2/3, evenly spread).
                    let y = f.minY + f.height / 3
                    p1 = CGPoint(x: f.minX + pillT / 2, y: y)
                    p2 = CGPoint(x: f.maxX - pillT / 2, y: y)
                } else {
                    // Diagonal seat (bottom-left → top-right).
                    let dx = f.width, dy = -f.height
                    let len = max(1, hypot(dx, dy))
                    let inset = pillT / 2
                    p1 = CGPoint(x: f.minX + dx / len * inset, y: f.maxY + dy / len * inset)
                    p2 = CGPoint(x: f.maxX - dx / len * inset, y: f.minY - dy / len * inset)
                }
                drawRecessedSlit(from: p1, to: p2, thickness: pillT + 4 * scale,
                                 scale: scale, textured: true)
            }
        }
        // Clip + Menu → a perfect-circle well each (wider than the rectangular hitbox), so the
        // round button reads as set into a recess.
        for e in [ControlElement.btnClip, .btnMenu] {
            if let f = buttons[e] {
                let r = max(f.width, f.height) / 2 + 4 * scale
                drawRecessedCapsule(CGRect(x: f.midX - r, y: f.midY - r, width: 2 * r, height: 2 * r),
                                    scale: scale)
            }
        }
        // Clip: a dark round under-disc inside its well, so the round button reads with relief
        // (shows a little at rest, more on press) — mirrors the GBA clip.
        if let c = buttons[.btnClip] {
            let r = min(c.width, c.height) / 2 + 1 * scale
            dpadDark.setFill()
            UIBezierPath(ovalIn: CGRect(x: c.midX - r, y: c.midY - r, width: 2 * r, height: 2 * r)).fill()
        }
    }

    // MARK: Button labels (slice 3c)

    /// SELECT / START printed on the case in the stripe-band indigo. Portrait: rotated to the
    /// diagonal pill, just below it. Landscape: horizontal, bottom-aligned in the hitbox.
    /// Default layout only; hitboxes untouched. (A/B keep their in-button letters.)
    private func drawButtonLabels(buttons: [ControlElement: CGRect], isLandscape: Bool, scale: CGFloat) {
        for (e, text) in [(ControlElement.btnSelect, "SELECT"), (.btnStart, "START")] {
            guard let f = buttons[e] else { continue }
            if isLandscape { drawHorizontalLabel(text, in: f, scale: scale) }
            else { drawDiagonalLabel(text, in: f, scale: scale) }
        }
    }

    /// Portrait: a flat indigo line rotated to the bottom-left → top-right diagonal of `f`, its
    /// width fitted to 70% of the diagonal length, centered just below the pill (offset along the
    /// downward perpendicular so it runs parallel to the pill).
    private func drawDiagonalLabel(_ text: String, in f: CGRect, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let dx = f.width, dy = -f.height          // bottom-left → top-right
        let len = max(1, hypot(dx, dy))
        let angle = atan2(dy, dx)                  // negative — points up to the right
        let kern = 0.5 * scale

        // Size the word to 70% of the diagonal length (30% smaller than spanning it).
        var size = 10 * scale
        var sz = measure(text, size: size, kern: kern)
        if sz.width > 0 { size *= (len * 0.7) / sz.width; sz = measure(text, size: size, kern: kern) }

        // Offset to the lower side of the pill along the downward perpendicular (ny = dx/len > 0).
        let nx = -dy / len, ny = dx / len
        let pillT = min(f.width, f.height) * Self.pillThicknessRatio
        let off = pillT / 2 + 2 * scale + sz.height / 2
        let center = CGPoint(x: f.midX + nx * off, y: f.midY + ny * off)

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: ssPortraitLabelColor, .kern: kern,
        ]).draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2))
        ctx.restoreGState()
    }

    /// Landscape: a flat horizontal indigo word fitted to 70% of the hitbox width, centered
    /// horizontally, its center at the lower third of the hitbox (pill at 1/3, label at 2/3 —
    /// evenly spread vertically, matching the .pillTop pill).
    private func drawHorizontalLabel(_ text: String, in f: CGRect, scale: CGFloat) {
        let kern = 0.5 * scale
        var size = 10 * scale
        var sz = measure(text, size: size, kern: kern)
        if sz.width > 0 { size *= (f.width * 0.7) / sz.width; sz = measure(text, size: size, kern: kern) }
        let cy = f.minY + f.height * 2 / 3
        NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: ssLandscapeLabelColor, .kern: kern,
        ]).draw(at: CGPoint(x: f.midX - sz.width / 2, y: cy - sz.height / 2))
    }

    // MARK: Branding ("Retro Pal" mark)

    /// Draws the Retro Pal brand mark (tinted icon + embossed wordmark) inside a recessed
    /// capsule — the same incrusted recess as the PHONES badge, filled with the page colour.
    private func drawBranding(in rect: CGRect, scale: CGFloat) {
        guard rect.width > 24 * scale, rect.height > 12 * scale else { return }
        // Same recess as PHONES, but filled with the page background colour (incrusted).
        drawRecessedCapsule(rect, scale: scale, fill: bodyMid)
        // Keep the content clear of the round end-caps + recess rim.
        let inset = rect.insetBy(dx: rect.height * 0.34, dy: rect.height * 0.20)
        guard inset.width > 4, inset.height > 4 else { return }
        let iconSide = inset.height
        let gap = iconSide * 0.22
        // Custom tints the brand icon to the auto-derived brand colour (matching the wordmark);
        // the built-ins use their prebuilt duotone icons.
        let brandImage: UIImage? = customPalette != nil
            ? RetroPalPalette.brandIcon(tinted: brandColor)
            : (variant == .retroPal ? Self.retroPalBrandIcon : Self.brandIcon)
        if let icon = brandImage {
            icon.draw(in: aspectFit(icon.size,
                                    in: CGRect(x: inset.minX, y: inset.minY,
                                               width: iconSide, height: iconSide)))
        }
        let textX = inset.minX + iconSide + gap
        let textRect = CGRect(x: textX, y: inset.minY, width: inset.maxX - textX, height: inset.height)
        if textRect.width > 8 { drawBrandText("Retro Pal", in: textRect, scale: scale) }
    }

    /// "Retro Pal" in the body colour with the PHONES embossed relief (no custom font);
    /// sized to the height and shrunk to fit the width, vertically centered.
    private func drawBrandText(_ s: String, in rect: CGRect, scale: CGFloat) {
        let kern = 0.5 * scale
        var fontSize = rect.height * 0.95
        var sz = measure(s, size: fontSize, kern: kern)
        if sz.width > rect.width, sz.width > 0 {
            fontSize *= rect.width / sz.width
            sz = measure(s, size: fontSize, kern: kern)
        }
        drawEmbossedText(s, at: CGPoint(x: rect.minX, y: rect.midY - sz.height / 2),
                         size: fontSize, color: brandColor, kern: kern, scale: scale)
    }

    private func aspectFit(_ imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let s = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: Screen surround (extended under the decorations)

    /// Portrait: symmetric rounded rectangle grown from the screen by the decoration
    /// margins (left mirrored to right, top mirrored to bottom) for a balanced shell.
    private func drawPortraitSurround(_ ctx: CGContext, screen: CGRect,
                                      deco: DecoLayout, scale: CGFloat) {
        drawSurroundPanel(ctx, rect: deco.surroundRect, screen: screen, scale: scale)
    }

    /// Landscape (interim): a thin frame around the screen whose BOTTOM extends to cover
    /// the SELECT·MENU·START row, with the same gap below the row as between the screen and
    /// the row (matches the row anchoring in ControlLayoutDefaults.gbcLandscape). No screen
    /// identity yet — that returns when we polish landscape.
    @discardableResult
    private func drawLandscapeSurround(_ ctx: CGContext, bounds: CGRect, screen: CGRect,
                                       scale: CGFloat) -> CGRect {
        let frame = 14 * scale
        let gap = EmulatorLayoutGeometry.gbcLandscapeRowGap * scale
        let rowH = EmulatorLayoutGeometry.buttonSize(.btnStart, isNDS: false,
                                                     isLandscape: true, deviceScale: scale).height
        let bottom = min(screen.maxY + gap + rowH + gap, bounds.maxY - 1)
        var r = screen.insetBy(dx: -frame, dy: -frame)
        r.size.height = bottom - r.minY
        r = r.intersection(bounds)
        drawSurroundPanel(ctx, rect: r, screen: screen, scale: scale)
        return r
    }

    /// Landscape decals: the PHONES badge in the left gutter (centered between the iPhone
    /// screen's left edge and the surround), the BATTERY LED in the surround band level
    /// with SELECT, and the speaker in the bottom-right corner rotated 45° forward.
    private func drawLandscapeDecals(bounds: CGRect, screen: CGRect, surround: CGRect,
                                     buttons: [ControlElement: CGRect], scale: CGFloat) {
        // BATTERY LED (no label) — surround band, vertically level with SELECT (center to
        // center), horizontally centered between the surround's left edge and SELECT's left.
        if let sel = buttons[.btnSelect] {
            drawLED(center: CGPoint(x: (surround.minX + sel.minX) / 2, y: sel.midY),
                    radius: 5 * scale, scale: scale)
        }

        // Speaker — bottom-right gutter, rotated 90° forward (two 45° flips). Centered
        // horizontally in the space between the end of the surround and the right edge of
        // the iPhone screen; sized as large as fits that gutter below the A/B buttons,
        // bottom-anchored. The rotated bounding box is compW·(|cos|+R|sin|) wide and
        // compW·(|sin|+R|cos|) tall (R = compH/compW), so it fits when both stay in range.
        let rot: CGFloat = 3 * .pi / 2                 // 90° + a further 180°
        let ratio: CGFloat = 2.0                       // compH / compW (taller than wide)
        let ct = CGFloat(abs(cos(Double(rot)))), st = CGFloat(abs(sin(Double(rot))))
        let bboxWPerW = ct + ratio * st
        let bboxHPerW = st + ratio * ct
        let bBottom = buttons[.btnB]?.maxY ?? screen.midY
        let belowAB = max(buttons[.btnA]?.maxY ?? screen.midY, bBottom)
        let m = 6 * scale
        let cornerW = bounds.maxX - surround.maxX
        let cornerH = bounds.maxY - belowAB
        // Fit the gutter, then 25% smaller (ratio kept, so width scales with the height).
        let compW = min((cornerW - 2 * m) / bboxWPerW, (cornerH - 2 * m) / bboxHPerW) * 0.75
        // Vertically centered between the bottom of the B button and the screen bottom.
        let speakerCenter = CGPoint(x: (surround.maxX + bounds.maxX) / 2,
                                    y: (bBottom + bounds.maxY) / 2)
        // A connected controller hides the speaker (the widened screen covers its gutter).
        let speakerDrawn = compW > 8 * scale && !controllerConnected
        if speakerDrawn {
            drawSpeakerGrille(center: speakerCenter, compW: compW, compH: ratio * compW,
                              rotation: rot, scale: scale, spread: 1.4, flipH: true)
        }
        // The speaker's rotated bounding box is compW·bboxHPerW tall, so its bottom edge is:
        let speakerBottom = speakerCenter.y + compW * bboxHPerW / 2

        // PHONES badge — centered horizontally between the iPhone screen's left edge
        // (bounds.minX) and the beginning of the surround, with its BOTTOM aligned to the
        // speaker's bottom. Scaled down if that left gutter is narrower than the badge.
        let gutter = surround.minX - bounds.minX
        if gutter > 24 * scale {
            let natural = phonesBadgeRect(center: .zero, scale: scale).width
            let fit = min(1, (gutter - 8 * scale) / max(1, natural))
            let badgeScale = scale * max(0.45, fit)
            let natH = phonesBadgeRect(center: .zero, scale: badgeScale).height
            let cx = (bounds.minX + surround.minX) / 2
            let cy = speakerDrawn ? speakerBottom - natH / 2
                                  : min(buttons[.btnSelect]?.midY ?? screen.maxY,
                                        bounds.maxY - natH / 2 - 4 * scale)
            drawPhonesBadge(rect: phonesBadgeRect(center: CGPoint(x: cx, y: cy), scale: badgeScale),
                            scale: badgeScale)
        }

        // Brand mark: in the left gutter (horizontally centered between the screen's left edge
        // and the surround), vertically centered in the space between the iPhone's top edge and
        // the top of the D-pad. Target 1.5x PHONES, clamped to that (narrow) left gutter.
        let phones = phonesBadgeRect(center: .zero, scale: scale)
        var bw = phones.width * 1.125 * 1.3, bh = phones.height * 1.125 * 1.3  // 1.5x PHONES, -25%, +30%
        let bavail = (surround.minX - bounds.minX) - 12 * scale
        if bavail > 24 * scale, bw > bavail { let f = bavail / bw; bw *= f; bh *= f }
        let bcx = (bounds.minX + surround.minX) / 2
        let dpadTop = buttons[.dpad]?.minY ?? bounds.maxY
        let bcy = (bounds.minY + dpadTop) / 2
        drawBranding(in: CGRect(x: bcx - bw / 2, y: bcy - bh / 2, width: bw, height: bh), scale: scale)
    }

    /// Fills the dark surround panel (rounded, oversized bottom-right curve, soft shadow)
    /// and strokes the recessed bevel around the LCD.
    private func drawSurroundPanel(_ ctx: CGContext, rect r: CGRect, screen: CGRect, scale: CGFloat) {
        let small = 8 * scale
        let bigBR = 28 * scale
        let panel = roundedPath(r, tl: small, tr: small, br: bigBR, bl: small)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5 * scale), blur: 5 * scale,
                      color: UIColor.black.withAlphaComponent(0.35).cgColor)
        surround.setFill()
        panel.fill()
        ctx.restoreGState()

        // Recessed-edge relief so the surround reads as inlaid (incrusted) into the body:
        // a dark inner shadow at the top rim + a light catch at the bottom rim — the same
        // "en relief" used on the recessed PHONES badge and the speaker slits.
        let outer = roundedPath(r.insetBy(dx: -2 * scale, dy: -2 * scale),
                                tl: small + 2 * scale, tr: small + 2 * scale,
                                br: bigBR + 2 * scale, bl: small + 2 * scale)
        drawRecessedRelief(panel, outer: outer, scale: scale)

        // Thin dark bevel right around the LCD for a recessed-screen feel.
        let lcd = roundedPath(screen.insetBy(dx: -1.5 * scale, dy: -1.5 * scale),
                              tl: 3 * scale, tr: 3 * scale, br: 6 * scale, bl: 3 * scale)
        UIColor.black.withAlphaComponent(0.45).setStroke()
        lcd.lineWidth = 1.5 * scale
        lcd.stroke()
    }

    // MARK: Stripe band — two stripes interrupted by the text (4 segments)

    private func drawStripeBand(_ ctx: CGContext, in rect: CGRect, scale: CGFloat) {
        guard rect.width > 30 * scale else { return }
        let lineW = max(1, 1.5 * scale)
        let lineGap = 6 * scale
        let mid = rect.midY
        let redY = mid - lineGap / 2     // maroon line (top)
        let blueY = mid + lineGap / 2    // indigo line (bottom)

        // Lay the text out first so the stripes can break around it.
        let fontSize = 8 * scale
        let (str, textSize) = fittedText("DOT MATRIX WITH STEREO SOUND", size: fontSize,
                                         color: printedTextColor, kern: 0.6 * scale,
                                         maxWidth: rect.width * 0.66)
        let textRect = CGRect(x: rect.midX - textSize.width / 2, y: mid - textSize.height / 2,
                              width: textSize.width, height: textSize.height)
        let gap = 5 * scale

        func segment(y: CGFloat, color: UIColor, x1: CGFloat, x2: CGFloat) {
            guard x2 - x1 > 1 else { return }
            color.setStroke()
            let p = UIBezierPath()
            p.move(to: CGPoint(x: x1, y: y))
            p.addLine(to: CGPoint(x: x2, y: y))
            p.lineWidth = lineW
            p.stroke()
        }
        // 2 top + 2 bottom segments, one before and one after the text (Retro Pal: both #ECCE5B).
        segment(y: redY, color: stripeTop, x1: rect.minX, x2: textRect.minX - gap)
        segment(y: redY, color: stripeTop, x1: textRect.maxX + gap, x2: rect.maxX)
        segment(y: blueY, color: stripeBottom, x1: rect.minX, x2: textRect.minX - gap)
        segment(y: blueY, color: stripeBottom, x1: textRect.maxX + gap, x2: rect.maxX)

        drawSoftLabel(ctx, str, at: textRect.origin, scale: scale)
    }

    // MARK: Battery LED

    /// The recessed BATTERY LED on its own (ring + lit dot + specular highlight), no label.
    private func drawLED(center c: CGPoint, radius r: CGFloat, scale: CGFloat) {
        UIColor.black.withAlphaComponent(0.4).setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - r - 1.5 * scale, y: c.y - r - 1.5 * scale,
                                    width: (r + 1.5 * scale) * 2, height: (r + 1.5 * scale) * 2)).fill()
        ledColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        UIColor.white.withAlphaComponent(0.55).setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - r * 0.5, y: c.y - r * 0.65,
                                    width: r * 0.6, height: r * 0.6)).fill()
    }

    private func drawBatteryLED(_ ctx: CGContext, deco: DecoLayout, scale: CGFloat) {
        drawLED(center: deco.ledCenter, radius: deco.ledRadius, scale: scale)
        let str = NSAttributedString(string: "BATTERY", attributes: [
            .font: UIFont.systemFont(ofSize: deco.batteryFont, weight: .semibold),
            .foregroundColor: printedTextColor, .kern: 0.5 * scale,
        ])
        drawSoftLabel(ctx, str, at: deco.batteryOrigin, scale: scale)
    }

    // MARK: Decals (speaker grille + PHONES)

    /// Non-button chrome below the controls. (The DMG power switch lives on the top edge —
    /// that maps to the iOS status-bar area, so we don't draw it.) The PHONES badge is
    /// centered in the thin strip below the lowest control; the speaker grille is a tall
    /// rotated grille in the bottom-right region.
    private func drawPortraitDecals(bounds: CGRect, screen: CGRect, surround: CGRect,
                                    buttons: [ControlElement: CGRect], scale: CGFloat) {
        let lowest = buttons.values.map { $0.maxY }.max() ?? surround.maxY

        // SELECT/START vertical level (card): PHONES and the speaker align to it.
        let ssY = (buttons[.btnSelect] ?? buttons[.btnStart])?.midY ?? lowest

        // PHONES badge. Card: at 25% of the card width, level with SELECT/START (always drawn).
        // In-game: centred in the strip below the lowest control.
        if cardMode {
            let phonesRect = phonesBadgeRect(center: CGPoint(x: bounds.width * 0.35, y: ssY), scale: scale)
            drawPhonesBadge(rect: phonesRect, scale: scale)
        } else if !controllerConnected {
            // A connected controller hides the PHONES badge (no controls strip to sit in).
            let stripTop = lowest + 6 * scale
            let stripBottom = bounds.maxY - 6 * scale
            if stripBottom - stripTop > 20 * scale {
                let midY = (stripTop + stripBottom) / 2
                let phonesRect = phonesBadgeRect(center: CGPoint(x: bounds.midX, y: midY), scale: scale)
                drawPhonesBadge(rect: phonesRect, scale: scale)
            }
        }

        // Speaker grille. In-game: bottom-right region, upright. Card: rotated 90°, flipped (slits
        // point the other way), 1.5x size, tucked into the bottom-right corner with a small padding.
        let startRight = buttons[.btnStart]?.maxX ?? bounds.midX
        let bBottom = buttons[.btnB]?.maxY ?? lowest
        let (sw, sh) = speakerSize(availableW: bounds.maxX - startRight,
                                   availableH: bounds.maxY - bBottom, scale: scale)
        if cardMode {
            // 1.5x, rotated 90°, flipped, at 65% of the card width and level with SELECT/START.
            let cw = sw * 1.5, ch = sh * 1.5
            let center = CGPoint(x: bounds.width * 0.65, y: ssY)
            drawSpeakerGrille(center: center, compW: cw, compH: ch, rotation: .pi / 2,
                              scale: scale, spread: 1.4, anchorBottom: false, flipH: true)
        } else if !controllerConnected {
            // A connected controller hides the speaker (no controls area to anchor it in).
            let center = CGPoint(x: (startRight + bounds.maxX) / 2, y: (bBottom + bounds.maxY) / 2)
            drawSpeakerGrille(center: center, compW: sw, compH: sh, rotation: 0,
                              scale: scale, spread: 1.4, anchorBottom: true)
        }

        // Brand mark. Card: above the screen, centred (where the standard card's app logo sits).
        if cardMode {
            let phones = phonesBadgeRect(center: .zero, scale: scale)
            let brandScale: CGFloat = 1.5                              // 1.5x larger brand mark
            let w = phones.width * 1.7 * brandScale, h = phones.height * 1.5 * brandScale
            let cy = max(h / 2 + 8, (bounds.minY + screen.minY) / 2)   // above the surround
            drawBranding(in: CGRect(x: bounds.midX - w / 2, y: cy - h / 2, width: w, height: h),
                         scale: scale)
        } else if let menu = buttons[.btnMenu] {
            // In-game: vertically level with Menu, in the space left of it. 1.5x PHONES, clamped.
            let phones = phonesBadgeRect(center: .zero, scale: scale)
            var w = phones.width * 1.125, h = phones.height * 1.125
            let avail = (menu.minX - bounds.minX) - 12 * scale
            if avail > 24 * scale, w > avail { let f = avail / w; w *= f; h *= f }
            let cx = (bounds.minX + menu.minX) / 2
            drawBranding(in: CGRect(x: cx - w / 2, y: menu.midY - h / 2, width: w, height: h),
                         scale: scale)
        }
    }

    private static let phonesFontSize: CGFloat = 9.5
    private static let phonesIconHeight: CGFloat = 14
    private static let phonesContentGap: CGFloat = 5
    /// Thickness of the SELECT/START pill as a fraction of the hitbox short side.
    /// Must match `SmallButton.pillThicknessRatio` so the dress seat lines up with the button.
    private static let pillThicknessRatio: CGFloat = 0.24

    /// Geometry of the PHONES badge (a capsule with rounded sides) for the given center.
    /// Pulled out so the speaker can be laid out clear of it before either is drawn.
    private func phonesBadgeRect(center: CGPoint, scale: CGFloat) -> CGRect {
        let txtSize = measure("PHONES", size: Self.phonesFontSize * scale, kern: 0.5 * scale)
        let iconH = Self.phonesIconHeight * scale
        let icon = UIImage(systemName: "headphones")
        let iconAspect: CGFloat = icon.map { $0.size.width / max(1, $0.size.height) } ?? 1
        let iconW = iconH * iconAspect
        let padX = 18 * scale, padY = 7 * scale
        let contentW = iconW + Self.phonesContentGap * scale + txtSize.width
        let contentH = max(iconH, txtSize.height)
        return CGRect(x: center.x - (contentW + 2 * padX) / 2,
                      y: center.y - (contentH + 2 * padY) / 2,
                      width: contentW + 2 * padX, height: contentH + 2 * padY)
    }

    /// The DMG "PHONES" mark: a recessed (creusé) capsule with rounded sides, filled with
    /// the engraved-area colour and the body grain (so it reads as carved into the same
    /// plastic), with a headphone icon + "PHONES" sculpted out of it in RELIEF in the page
    /// colour so they read as moulded plastic.
    private func drawPhonesBadge(rect: CGRect, scale: CGFloat) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let fontSize = Self.phonesFontSize * scale
        let txtSize = measure("PHONES", size: fontSize, kern: 0.5 * scale)
        let iconH = Self.phonesIconHeight * scale
        let icon = UIImage(systemName: "headphones")
        let iconAspect: CGFloat = icon.map { $0.size.width / max(1, $0.size.height) } ?? 1
        let iconW = iconH * iconAspect
        let gap = Self.phonesContentGap * scale
        let contentW = iconW + gap + txtSize.width

        drawRecessedCapsule(rect, scale: scale)

        let contentX = center.x - contentW / 2
        if let icon {
            drawEmbossedImage(icon, in: CGRect(x: contentX, y: center.y - iconH / 2,
                                               width: iconW, height: iconH),
                              color: bodyMid, scale: scale)
        }
        drawEmbossedText("PHONES", at: CGPoint(x: contentX + iconW + gap,
                                               y: center.y - txtSize.height / 2),
                         size: fontSize, color: bodyMid, kern: 0.5 * scale, scale: scale)
    }

    /// Sizes the speaker component (taller than wide, ~2× the original footprint), clamped
    /// to the available region so it never runs off.
    private func speakerSize(availableW: CGFloat, availableH: CGFloat,
                             scale: CGFloat) -> (CGFloat, CGFloat) {
        var compW = min(availableW * 0.55, 52 * scale)
        var compH = compW * 2.2
        if compH > availableH * 0.92 {
            compH = availableH * 0.92
            compW = min(compW, compH / 2.2)
        }
        return (compW, compH)
    }

    /// Draws the speaker component centered on `center`, optionally rotated. The slits are
    /// drawn in a LOCAL zone so a rotation is applied uniformly via the context transform
    /// (portrait passes rotation 0; landscape tilts it 45°).
    private func drawSpeakerGrille(center: CGPoint, compW: CGFloat, compH: CGFloat,
                                   rotation: CGFloat, scale: CGFloat,
                                   spread: CGFloat = 1, anchorBottom: Bool = false,
                                   flipH: Bool = false) {
        guard compW > 10 * scale, compH > 10 * scale,
              let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        if flipH { ctx.scaleBy(x: -1, y: 1) }   // mirror left-right (in screen space)
        if rotation != 0 { ctx.rotate(by: rotation) }
        drawSpeakerSlits(in: CGRect(x: -compW / 2, y: -compH / 2, width: compW, height: compH),
                         scale: scale, spread: spread, anchorBottom: anchorBottom)
        ctx.restoreGState()
    }

    /// The 6 parallel "/" slits stacked vertically inside a (local) zone — each a recessed
    /// (creusé) groove in the engraved-area colour; 5 of the 6 carry a real cut-through hole
    /// (a smaller, darker line inside the groove). Rotated 90° vs the original DMG so the
    /// component reads taller than wide.
    private func drawSpeakerSlits(in zone: CGRect, scale: CGFloat,
                                  spread: CGFloat = 1, anchorBottom: Bool = false) {
        let count = 6
        let margin = 3 * scale
        let hSpan = zone.width - 2 * margin
        guard hSpan > 6 else { return }
        let half = hSpan / 2          // 45°: vertical half-span == horizontal half-span
        let usableH = max(0, zone.height - 2 * margin - 2 * half)
        let pitch = (count > 1 ? usableH / CGFloat(count - 1) : 0) * spread
        // anchorBottom (portrait): keep the lowest slit where it is and let the extra spread
        // grow upward only. Otherwise (landscape) keep the block centered as it spreads.
        let firstCy: CGFloat = anchorBottom
            ? (zone.maxY - margin - half) - pitch * CGFloat(count - 1)
            : zone.midY - pitch * CGFloat(count - 1) / 2
        let cx = zone.midX
        for i in 0..<count {
            let cy = firstCy + CGFloat(i) * pitch
            let p1 = CGPoint(x: cx - half, y: cy + half)   // "/" direction (rotated "\")
            let p2 = CGPoint(x: cx + half, y: cy - half)

            // Each slit gets the recessed "creusé" treatment of the PHONES badge: a
            // creusé-filled stadium with a dark-top / light-bottom relief.
            drawRecessedSlit(from: p1, to: p2, thickness: 6 * scale, scale: scale)

            // Real cut-through hole on 5 of the 6 slits (the first is a groove only).
            if i > 0 {
                let s: CGFloat = 0.82
                let hole = UIBezierPath()
                hole.move(to: CGPoint(x: cx - half * s, y: cy + half * s))
                hole.addLine(to: CGPoint(x: cx + half * s, y: cy - half * s))
                hole.lineWidth = 2.6 * scale; hole.lineCapStyle = .round
                UIColor.black.withAlphaComponent(0.80).setStroke(); hole.stroke()
            }
        }
    }

    /// A recessed (engraved) capsule — rounded sides (corner radius = half the height).
    /// Filled with the engraved-area colour and the page grain (so the recess carries the
    /// same plastic texture as the body), then a dark inner-shadow at the top rim and a
    /// light catch at the bottom rim so it reads as carved into the body.
    private func drawRecessedCapsule(_ rect: CGRect, scale: CGFloat, fill: UIColor? = nil) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius = rect.height / 2
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        (fill ?? creuse).setFill(); path.fill()
        // Same grain as the body, clipped to the recess, so the texture is continuous.
        ctx.saveGState(); path.addClip(); Self.grain.drawAsPattern(in: rect); ctx.restoreGState()

        let outer = UIBezierPath(roundedRect: rect.insetBy(dx: -2 * scale, dy: -2 * scale),
                                 cornerRadius: radius + 2 * scale)
        drawRecessedRelief(path, outer: outer, scale: scale)
    }

    /// The "en relief" carved look, reusable for any filled shape: clipped to `path`, a dark
    /// inner shadow falls from the top rim and a light catch from the bottom rim (strokes of
    /// the slightly-larger `outer` path, so only their shadows bleed inside). Makes a filled
    /// region read as recessed into the surrounding plastic.
    private func drawRecessedRelief(_ path: UIBezierPath, outer: UIBezierPath, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.8 * scale), blur: 2.6 * scale,
                      color: UIColor.black.withAlphaComponent(0.5).cgColor)
        UIColor.black.setStroke(); outer.lineWidth = 2 * scale; outer.stroke()
        ctx.restoreGState()
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 1.6 * scale,
                      color: UIColor.white.withAlphaComponent(0.4).cgColor)
        UIColor.white.setStroke(); outer.lineWidth = 1.5 * scale; outer.stroke()
        ctx.restoreGState()
    }

    /// One speaker slit rendered with the recessed-capsule "creusé" effect: a creusé-filled
    /// stadium along the p1→p2 diagonal, with the same relief as the PHONES badge.
    private func drawRecessedSlit(from p1: CGPoint, to p2: CGPoint, thickness t: CGFloat,
                                  scale: CGFloat, textured: Bool = false) {
        func stadium(_ w: CGFloat) -> UIBezierPath {
            let line = CGMutablePath(); line.move(to: p1); line.addLine(to: p2)
            return UIBezierPath(cgPath: line.copy(strokingWithWidth: w, lineCap: .round,
                                                  lineJoin: .round, miterLimit: 0))
        }
        let path = stadium(t)
        creuse.setFill(); path.fill()
        // Larger seats (the A/B well) carry the body grain; thin slits skip it (invisible).
        if textured, let ctx = UIGraphicsGetCurrentContext() {
            ctx.saveGState(); path.addClip()
            Self.grain.drawAsPattern(in: path.bounds); ctx.restoreGState()
        }
        drawRecessedRelief(path, outer: stadium(t + 4 * scale), scale: scale)
    }

    /// Text drawn in RELIEF (emboss): a light copy up-left + a dark copy down-right behind
    /// a `color` fill, so it looks raised/sculpted (used for the body-coloured PHONES).
    private func drawEmbossedText(_ s: String, at origin: CGPoint, size: CGFloat,
                                  color: UIColor, kern: CGFloat, scale: CGFloat) {
        let d = 0.6 * scale
        func mk(_ c: UIColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: c, .kern: kern,
            ])
        }
        mk(UIColor.white.withAlphaComponent(0.5)).draw(at: CGPoint(x: origin.x - d, y: origin.y - d))
        mk(UIColor.black.withAlphaComponent(0.32)).draw(at: CGPoint(x: origin.x + d, y: origin.y + d))
        mk(color).draw(at: origin)
    }

    /// A template image drawn in RELIEF (emboss), matching `drawEmbossedText`.
    private func drawEmbossedImage(_ img: UIImage, in rect: CGRect, color: UIColor, scale: CGFloat) {
        let d = 0.6 * scale
        img.withTintColor(UIColor.white.withAlphaComponent(0.5), renderingMode: .alwaysTemplate)
            .draw(in: rect.offsetBy(dx: -d, dy: -d))
        img.withTintColor(UIColor.black.withAlphaComponent(0.32), renderingMode: .alwaysTemplate)
            .draw(in: rect.offsetBy(dx: d, dy: d))
        img.withTintColor(color, renderingMode: .alwaysTemplate).draw(in: rect)
    }

    // MARK: Text helpers

    private func measure(_ s: String, size: CGFloat, kern: CGFloat) -> CGSize {
        NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold), .kern: kern,
        ]).size()
    }

    private func fittedText(_ s: String, size: CGFloat, color: UIColor, kern: CGFloat,
                            maxWidth: CGFloat) -> (NSAttributedString, CGSize) {
        func make(_ fontSize: CGFloat) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color, .kern: kern,
            ])
        }
        var str = make(size)
        var sz = str.size()
        if sz.width > maxWidth, maxWidth > 0 {
            str = make(max(5, size * maxWidth / sz.width))
            sz = str.size()
        }
        return (str, sz)
    }

    /// Draws the text with a soft, blurry drop shadow (depth, not relief) — keeps the
    /// white printed labels legible on the surround without an embossed/engraved look.
    private func drawSoftLabel(_ ctx: CGContext, _ str: NSAttributedString,
                               at origin: CGPoint, scale: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0.5 * scale), blur: 2 * scale,
                      color: UIColor.black.withAlphaComponent(0.5).cgColor)
        str.draw(at: origin)
        ctx.restoreGState()
    }

    // MARK: Path helper

    /// Rounded-rect path with independent corner radii (clockwise from top-left).
    private func roundedPath(_ rect: CGRect, tl: CGFloat, tr: CGFloat,
                             br: CGFloat, bl: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(withCenter: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                 startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(withCenter: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                 startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(withCenter: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                 startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(withCenter: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                 startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        p.close()
        return p
    }
}

// MARK: - Game Boy Advance skin

/// The Game Boy Advance dress: a textured body, a near-black screen surround (the distinctive
/// GBA bezel shape), POWER LED, speaker, and reshaped L/R shoulders. Built slice by slice.
/// Slices 1-3: textured body + screen surround + decals (POWER LED, speaker). L/R dress next.
struct GameBoyAdvanceSkin: ConsoleSkin {

    /// Nostalgia vs the Retro Pal recolour.
    var variant: DressVariant = .nostalgia
    /// Card mode: the square share card. Decorations are placed for the card (mirroring the GB/GBC
    /// card) instead of the in-game portrait layout — no off-card Menu references. Set by the
    /// GBA console card view; the in-game skin keeps it false.
    var cardMode: Bool = false
    /// A hardware controller is connected: the speaker is hidden and the brand is shown — in
    /// portrait at the same spot as no-controller (Clip-anchored), in landscape at the speaker's slot.
    var controllerConnected: Bool = false
    /// ALL control frames (including hidden ones), so the portrait brand can anchor to the Clip
    /// button (hidden in controller mode, but still laid out at its normal no-controller position
    /// because the GBA portrait screen does not grow). Used only in `controllerConnected` branches.
    var allButtons: [ControlElement: CGRect] = [:]

    // Palette: body #7558EB (purple, textured), surround #0E0E10, buttons #C4BFCF. The body
    // keeps the GBA purple — only the GB/GBC TEXTURE treatment (grain + vignette) is reused.
    // Retro Pal recolours body → #050505, surround → #2C2E2D, the creusé grooves → #191A19
    // (between the two); buttons are untouched per the draft.
    /// The user custom palette when `variant == .custom(.gba)`, else nil. `body`/`surround`/`led`
    /// drive their slots; the creusé grooves derive from `body`; faces live in the button views.
    private var gba: GBASkinPalette? { variant.gbaPalette }

    private var bodyTop: UIColor {
        if let p = gba { return RetroPalPalette.bodyGradient(p.body).top }
        return variant == .retroPal ? RetroPalPalette.bodyGradient(RetroPalPalette.gbaBody).top
                                    : UIColor(red: 0.510, green: 0.410, blue: 0.950, alpha: 1) }
    private var bodyMid: UIColor {
        if let p = gba { return p.body }
        return variant == .retroPal ? RetroPalPalette.gbaBody
                                    : UIColor(red: 0.459, green: 0.345, blue: 0.922, alpha: 1) } // #7558EB
    private var bodyBottom: UIColor {
        if let p = gba { return RetroPalPalette.bodyGradient(p.body).bottom }
        return variant == .retroPal ? RetroPalPalette.bodyGradient(RetroPalPalette.gbaBody).bottom
                                    : UIColor(red: 0.380, green: 0.270, blue: 0.800, alpha: 1) }
    private var surround: UIColor {
        if let p = gba { return p.surround }
        return variant == .retroPal ? RetroPalPalette.gbaSurround
                                    : UIColor(red: 0.055, green: 0.055, blue: 0.063, alpha: 1) } // #0E0E10

    // Green POWER LED (deliberate: the real AGB-001 LED is red). Custom recolours it.
    private let ledGreen = UIColor(red: 0.22, green: 0.82, blue: 0.31, alpha: 1)
    private var ledColor: UIColor { gba?.led ?? ledGreen }
    /// Printed labels on the case (SELECT/START, POWER) — the button colour in Nostalgia/Retro Pal,
    /// the custom `buttons` slot otherwise.
    private var buttonLabelColor: UIColor { gba?.buttons ?? DressKind.gbaButton }
    /// SELECT/START creusé pill width/height ratio (the Retro Pal brand ratio). Must match
    /// `SmallButton.selectPillRatio` so the dress pill and the button's tiny circle line up.
    private static let selectPillRatio: CGFloat = 3.4
    // Recessed speaker groove: a darker shade of the purple body (Retro Pal: the creusé #191A19;
    // custom: derived from the body so it keeps the same darker-than-body relationship).
    private var speakerGroove: UIColor {
        if let p = gba { return p.body.rpMixed(with: .black, 0.35) }
        return variant == .retroPal ? RetroPalPalette.gbaCreuse
                                    : UIColor(red: 0.300, green: 0.220, blue: 0.560, alpha: 1) }
    // The L / R shoulder creusé areas (landscape + portrait): a touch darker than the body so the
    // recess reads clearly — between bodyMid and the speaker groove.
    private var shoulderCreuse: UIColor {
        if let p = gba { return p.body.rpMixed(with: .black, 0.15) }
        return variant == .retroPal ? RetroPalPalette.gbaCreuse
                                    : UIColor(red: 0.390, green: 0.293, blue: 0.784, alpha: 1) }

    /// The Retro Pal brand mark, tinted to the GBA body purple duotone (so it reads as printed
    /// into the plastic) — same treatment as GB/GBC, recoloured. Built once.
    private static let ciContext = CIContext(options: nil)
    private static let brandIcon: UIImage? = {
        guard let base = UIImage(named: "RetroPalBrand"), let ci = CIImage(image: base),
              let f = CIFilter(name: "CIColorMonochrome", parameters: [
                  kCIInputImageKey: ci,
                  "inputColor": CIColor(red: 0.459, green: 0.345, blue: 0.922),  // #7558EB
                  "inputIntensity": 1.0,
              ]),
              let out = f.outputImage,
              let cg = ciContext.createCGImage(out, from: out.extent) else { return UIImage(named: "RetroPalBrand") }
        return UIImage(cgImage: cg)
    }()

    /// The brand text colour: the average (alpha-weighted) colour of the icon drawn next to it,
    /// so the wordmark reads in the same tone as the mark rather than the flat body purple.
    /// Falls back to `#7558EB` if the icon can't be sampled.
    private static let brandTextColor: UIColor =
        averageVisibleColor(of: brandIcon) ?? UIColor(red: 0.459, green: 0.345, blue: 0.922, alpha: 1)

    /// Retro Pal: brand icon + "Retro Pal" wordmark mirror the START label colour (#C4BFCF).
    /// Custom auto-derives a contrasting same-hue tint from the body (not a user slot).
    private static let retroPalBrandIcon: UIImage? = RetroPalPalette.brandIcon(tinted: DressKind.gbaButton)
    private var brandColor: UIColor {
        if gba != nil { return bodyMid.rpContrastingMark }
        return variant == .retroPal ? DressKind.gbaButton : Self.brandTextColor }

    /// Alpha-weighted average colour of an image's visible pixels (transparent pixels contribute
    /// nothing). Sampled once at a small size — fine for a static, build-once swatch.
    private static func averageVisibleColor(of image: UIImage?) -> UIColor? {
        guard let cg = image?.cgImage else { return nil }
        let s = min(1.0, 48.0 / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int((CGFloat(cg.width) * s).rounded()))
        let h = max(1, Int((CGFloat(cg.height) * s).rounded()))
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // premultipliedLast: stored r/g/b are already (straight · alpha); dividing the channel
        // sums by the alpha sum yields the straight alpha-weighted average colour.
        var rSum = 0.0, gSum = 0.0, bSum = 0.0, aSum = 0.0
        var i = 0
        while i < data.count {
            rSum += Double(data[i]); gSum += Double(data[i + 1]); bSum += Double(data[i + 2])
            aSum += Double(data[i + 3]); i += 4
        }
        guard aSum > 0 else { return nil }
        return UIColor(red: CGFloat(rSum / aSum), green: CGFloat(gSum / aSum),
                       blue: CGFloat(bSum / aSum), alpha: 1)
    }

    func draw(in ctx: CGContext, bounds: CGRect, screenFrame screen: CGRect,
              buttons: [ControlElement: CGRect], isLandscape: Bool, usesJoystick: Bool, scale: CGFloat) {
        drawBody(ctx, bounds)
        guard !screen.isEmpty else { return }
        drawButtonWells(buttons: buttons, usesJoystick: usesJoystick, scale: scale)
        let surroundRect = drawSurround(ctx, bounds: bounds, screen: screen, buttons: buttons,
                                        isLandscape: isLandscape, scale: scale)
        if isLandscape {
            drawShoulderCorners(buttons: buttons, bounds: bounds, surroundRect: surroundRect, scale: scale)
        } else if !cardMode {
            // The portrait shoulder creusé band re-dresses the Menu strip, which doesn't exist on
            // the card; the per-button L/R seats (drawShoulderButtonSeats) carry the card instead.
            drawPortraitShoulders(buttons: buttons, bounds: bounds, screen: screen,
                                  surroundRect: surroundRect, scale: scale)
        }
        drawShoulderButtonSeats(buttons: buttons, scale: scale)
        drawPower(ctx, bounds: bounds, screen: screen, buttons: buttons, surroundRect: surroundRect,
                  isLandscape: isLandscape, scale: scale)
        drawSpeaker(buttons: buttons, bounds: bounds, screen: screen, surroundRect: surroundRect,
                    isLandscape: isLandscape, scale: scale)
        drawSelectStart(buttons: buttons, scale: scale)
        drawBrand(bounds: bounds, screen: screen, buttons: buttons, surroundRect: surroundRect,
                  isLandscape: isLandscape, scale: scale)
    }

    // MARK: SELECT / START dress (slice 5 redesign)

    /// SELECT / START: a horizontal creusé pill (the Retro Pal brand's width/height ratio, its
    /// width = the hitbox width, centered) holding the embossed label on the left; the BUTTON
    /// itself (drawn by SmallButton) is the tiny clip-like circle on the right.
    private func drawSelectStart(buttons: [ControlElement: CGRect], scale: CGFloat) {
        for (e, text) in [(ControlElement.btnSelect, "SELECT"), (.btnStart, "START")] {
            guard let f = buttons[e] else { continue }
            let pillH = f.width / Self.selectPillRatio
            let pillRect = CGRect(x: f.minX, y: f.midY - pillH / 2, width: f.width, height: pillH)
            drawRecessedCapsule(pillRect, fill: bodyMid, scale: scale)
            // The tiny "button" on the right (matches SmallButton.gbaSelectCircleRect): a creusé
            // seat + a dark under-disc behind it, mirroring the A button (the light circle itself
            // is drawn by SmallButton).
            let d = pillH * 0.7, pad = pillH * 0.25
            let circleC = CGPoint(x: f.maxX - pad - d / 2, y: f.midY)
            drawRecessedCircle(center: circleC, radius: d / 2 + 3 * scale, scale: scale)
            let ur = d / 2 + 1 * scale
            surround.setFill()
            UIBezierPath(ovalIn: CGRect(x: circleC.x - ur, y: circleC.y - ur, width: 2 * ur, height: 2 * ur)).fill()
            // Label: same colour as the button (#C4BFCF), embossed for contrast on the purple pill.
            let circleLeft = f.maxX - pad - d
            let labelLeft = pillRect.minX + pillH * 0.5
            let labelW = circleLeft - labelLeft - pillH * 0.25
            guard labelW > 8 else { continue }
            let kern = 0.5 * scale
            var size = pillRect.height * 0.72
            var sz = measureLabel(text, size: size, kern: kern)
            if sz.width > labelW, sz.width > 0 { size *= labelW / sz.width; sz = measureLabel(text, size: size, kern: kern) }
            drawEmbossedLabel(text, at: CGPoint(x: labelLeft, y: pillRect.midY - sz.height / 2),
                              size: size, color: buttonLabelColor, kern: kern, scale: scale)
        }
    }

    // MARK: Branding ("Retro Pal" mark, slice 5)

    /// Brand reference size = the GB/GBC PHONES badge × 1.125, so the GBA brand keeps the same
    /// dimension as the GB/GBC one.
    private func brandSize(scale: CGFloat) -> CGSize {
        let txt = measureLabel("PHONES", size: 9.5 * scale, kern: 0.5 * scale)
        let iconH = 14 * scale
        let icon = UIImage(systemName: "headphones")
        let aspect: CGFloat = icon.map { $0.size.width / max(1, $0.size.height) } ?? 1
        let contentW = iconH * aspect + 5 * scale + txt.width
        let contentH = max(iconH, txt.height)
        return CGSize(width: (contentW + 36 * scale) * 1.125, height: (contentH + 14 * scale) * 1.125)
    }

    /// Brand placement. Portrait: same as GB/GBC — level with Menu, centered between the
    /// screen's left edge and Menu. Landscape: above the screen + surround, horizontally
    /// centered, vertically centered between the iPhone top edge and the top of the surround.
    private func drawBrand(bounds: CGRect, screen: CGRect, buttons: [ControlElement: CGRect],
                           surroundRect: CGRect, isLandscape: Bool, scale: CGFloat) {
        let size = brandSize(scale: scale)
        var w = size.width, h = size.height
        let rect: CGRect
        if cardMode {
            // Card: above the screen, horizontally centred — the same spot as the GB/GBC card's
            // brand mark (1.5× larger). Tunable.
            w *= 1.5; h *= 1.5
            let cy = max(h / 2 + 8 * scale, (bounds.minY + screen.minY) / 2)
            rect = CGRect(x: bounds.midX - w / 2, y: cy - h / 2, width: w, height: h)
        } else if controllerConnected {
            // Controller connected (speaker hidden — see drawSpeaker).
            if isLandscape {
                // The brand TAKES the speaker's slot: same centre + width, height by natural ratio.
                // Mirrors drawSpeaker's landscape geometry (rot 270° → footprint width = compW × 2).
                let ratio: CGFloat = 2.0
                let bBottom = buttons[.btnB]?.maxY ?? screen.midY
                let belowAB = max(buttons[.btnA]?.maxY ?? screen.midY, bBottom)
                let m = 6 * scale
                let cornerW = bounds.maxX - surroundRect.maxX
                let cornerH = bounds.maxY - belowAB
                let compW = min((cornerW - 2 * m) / ratio, cornerH - 2 * m) * 0.75
                guard compW > 8 * scale else { return }
                let center = CGPoint(x: (surroundRect.maxX + bounds.maxX) / 2, y: (bBottom + bounds.maxY) / 2)
                w = compW * ratio                       // the rotated speaker's visual width
                h = w * (size.height / size.width)       // keep the brand's natural ratio
                rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            } else {
                // Portrait: the EXACT no-controller spot. Clip is hidden in controller mode but
                // still laid out at its normal position (the GBA portrait screen does not grow), so
                // read it from the full frames.
                guard let menu = allButtons[.btnMenu], let clip = allButtons[.btnClip] else { return }
                let avail = (menu.minX - bounds.minX) - 12 * scale
                if avail > 24 * scale, w > avail { let f = avail / w; w *= f; h *= f }
                let cx = (bounds.minX + menu.minX) / 2
                rect = CGRect(x: cx - w / 2, y: clip.midY - h / 2, width: w, height: h)
            }
        } else if isLandscape {
            // +20%, clamped to the space between the iPhone top edge and the surround top.
            w *= 1.2; h *= 1.2
            let availH = (surroundRect.minY - bounds.minY) - 8 * scale
            if availH > 12 * scale, h > availH { let f = availH / h; w *= f; h *= f }
            let cy = (bounds.minY + surroundRect.minY) / 2
            rect = CGRect(x: bounds.midX - w / 2, y: cy - h / 2, width: w, height: h)
        } else {
            // Below the surround, horizontally in the left gutter, vertically centered on Clip.
            guard let menu = buttons[.btnMenu], let clip = buttons[.btnClip] else { return }
            let avail = (menu.minX - bounds.minX) - 12 * scale
            if avail > 24 * scale, w > avail { let f = avail / w; w *= f; h *= f }
            let cx = (bounds.minX + menu.minX) / 2
            rect = CGRect(x: cx - w / 2, y: clip.midY - h / 2, width: w, height: h)
        }
        drawBranding(in: rect, scale: scale)
    }

    /// The Retro Pal mark inside a recessed capsule (incrusted purple) + tinted icon + embossed
    /// "Retro Pal" — the GB/GBC brand, recoloured for the GBA.
    private func drawBranding(in rect: CGRect, scale: CGFloat) {
        guard rect.width > 24 * scale, rect.height > 12 * scale else { return }
        drawRecessedCapsule(rect, fill: bodyMid, scale: scale)
        let inset = rect.insetBy(dx: rect.height * 0.34, dy: rect.height * 0.20)
        guard inset.width > 4, inset.height > 4 else { return }
        let iconSide = inset.height
        let gap = iconSide * 0.22
        // Custom tints the brand icon to the auto-derived brand colour (matches the wordmark).
        let brandImage: UIImage? = gba != nil
            ? RetroPalPalette.brandIcon(tinted: brandColor)
            : (variant == .retroPal ? Self.retroPalBrandIcon : Self.brandIcon)
        if let icon = brandImage {
            icon.draw(in: aspectFit(icon.size, in: CGRect(x: inset.minX, y: inset.minY,
                                                          width: iconSide, height: iconSide)))
        }
        let textX = inset.minX + iconSide + gap
        let textRect = CGRect(x: textX, y: inset.minY, width: inset.maxX - textX, height: inset.height)
        if textRect.width > 8 { drawBrandText("Retro Pal", in: textRect, scale: scale) }
    }

    private func drawBrandText(_ s: String, in rect: CGRect, scale: CGFloat) {
        let kern = 0.5 * scale
        var fontSize = rect.height * 0.95
        var sz = measureLabel(s, size: fontSize, kern: kern)
        if sz.width > rect.width, sz.width > 0 {
            fontSize *= rect.width / sz.width
            sz = measureLabel(s, size: fontSize, kern: kern)
        }
        // Brand text in the icon's average colour (see brandTextColor), same embossed relief.
        drawEmbossedLabel(s, at: CGPoint(x: rect.minX, y: rect.midY - sz.height / 2),
                          size: fontSize, color: brandColor, kern: kern, scale: scale)
    }

    private func aspectFit(_ imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let s = min(rect.width / imageSize.width, rect.height / imageSize.height)
        return CGRect(x: rect.midX - imageSize.width * s / 2, y: rect.midY - imageSize.height * s / 2,
                      width: imageSize.width * s, height: imageSize.height * s)
    }

    // MARK: Decals — speaker (slice 3)

    /// The speaker grille — placement, orientation, dimension and slit spread MIRROR the GB/GBC
    /// speaker exactly (portrait: bottom-right region, rotation 0, spread 1.4 growing upward;
    /// landscape: bottom-right gutter, rotated 90° + mirrored, spread 1.4). Recolored to a
    /// recessed darker-purple groove, and the hole-less first line is dropped → 5 holed slits.
    private func drawSpeaker(buttons: [ControlElement: CGRect], bounds: CGRect, screen: CGRect,
                             surroundRect: CGRect, isLandscape: Bool, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        // A connected controller hides the speaker; the brand takes its place (see drawBrand).
        if controllerConnected && !cardMode { return }
        let bBottom = buttons[.btnB]?.maxY ?? screen.midY
        let center: CGPoint, compW: CGFloat, compH: CGFloat, rotation: CGFloat
        let flipH: Bool, anchorBottom: Bool

        if cardMode {
            // Card: mirror the GB/GBC card speaker — 1.5×, rotated 90° + flipped, at 65% of the
            // card width and level with SELECT/START. Tunable.
            let ssY = (buttons[.btnSelect] ?? buttons[.btnStart])?.midY ?? screen.maxY
            let (sw, sh) = speakerSize(availableW: bounds.width * 0.30,
                                       availableH: bounds.height * 0.20, scale: scale)
            compW = sw * 1.5; compH = sh * 1.5
            center = CGPoint(x: bounds.width * 0.65, y: ssY)
            rotation = .pi / 2; flipH = true; anchorBottom = false
        } else if isLandscape {
            // Rotated 90° forward (taller than wide), bottom-right gutter — GB/GBC's math.
            let rot = 3 * CGFloat.pi / 2
            let ratio: CGFloat = 2.0
            let ct = CGFloat(abs(cos(Double(rot)))), st = CGFloat(abs(sin(Double(rot))))
            let bboxWPerW = ct + ratio * st, bboxHPerW = st + ratio * ct
            let belowAB = max(buttons[.btnA]?.maxY ?? screen.midY, bBottom)
            let m = 6 * scale
            let cornerW = bounds.maxX - surroundRect.maxX
            let cornerH = bounds.maxY - belowAB
            compW = min((cornerW - 2 * m) / bboxWPerW, (cornerH - 2 * m) / bboxHPerW) * 0.75
            compH = ratio * compW
            center = CGPoint(x: (surroundRect.maxX + bounds.maxX) / 2, y: (bBottom + bounds.maxY) / 2)
            rotation = rot; flipH = true; anchorBottom = false
        } else {
            // Bottom-right region between START's right edge and the device edge — GB/GBC's math.
            let startRight = buttons[.btnStart]?.maxX ?? bounds.midX
            let (sw, sh) = speakerSize(availableW: bounds.maxX - startRight,
                                       availableH: bounds.maxY - bBottom, scale: scale)
            compW = sw; compH = sh
            center = CGPoint(x: (startRight + bounds.maxX) / 2, y: (bBottom + bounds.maxY) / 2)
            rotation = 0; flipH = false; anchorBottom = true
        }
        guard compW > 10 * scale, compH > 10 * scale else { return }

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        if flipH { ctx.scaleBy(x: -1, y: 1) }
        if rotation != 0 { ctx.rotate(by: rotation) }
        drawSpeakerSlits(in: CGRect(x: -compW / 2, y: -compH / 2, width: compW, height: compH),
                         scale: scale, spread: 1.4, anchorBottom: anchorBottom)
        ctx.restoreGState()
    }

    /// Sizes the portrait speaker (taller than wide), clamped to the region — GB/GBC's math.
    private func speakerSize(availableW: CGFloat, availableH: CGFloat,
                             scale: CGFloat) -> (CGFloat, CGFloat) {
        var compW = min(availableW * 0.55, 52 * scale)
        var compH = compW * 2.2
        if compH > availableH * 0.92 {
            compH = availableH * 0.92
            compW = min(compW, compH / 2.2)
        }
        return (compW, compH)
    }

    /// 5 "/" slits stacked vertically in the (local) zone — the GB/GBC spread/positions (6-slit
    /// pitch) with the hole-less first line skipped, so the 5 holed slits land exactly where
    /// GB/GBC's do. Each is a recessed darker-purple groove with a real cut-through hole.
    private func drawSpeakerSlits(in zone: CGRect, scale: CGFloat,
                                  spread: CGFloat, anchorBottom: Bool) {
        let count = 6                       // pitch matches GB/GBC; we draw slits 1...5
        let margin = 3 * scale
        let hSpan = zone.width - 2 * margin
        guard hSpan > 6 else { return }
        let half = hSpan / 2
        let usableH = max(0, zone.height - 2 * margin - 2 * half)
        let pitch = (count > 1 ? usableH / CGFloat(count - 1) : 0) * spread
        let firstCy: CGFloat = anchorBottom
            ? (zone.maxY - margin - half) - pitch * CGFloat(count - 1)
            : zone.midY - pitch * CGFloat(count - 1) / 2
        let cx = zone.midX
        for i in 1..<count {                // skip i == 0 (the GB/GBC hole-less line)
            let cy = firstCy + CGFloat(i) * pitch
            let p1 = CGPoint(x: cx - half, y: cy + half)
            let p2 = CGPoint(x: cx + half, y: cy - half)
            let line = CGMutablePath(); line.move(to: p1); line.addLine(to: p2)
            let groove = UIBezierPath(cgPath: line.copy(strokingWithWidth: 6 * scale, lineCap: .round,
                                                        lineJoin: .round, miterLimit: 0))
            speakerGroove.setFill(); groove.fill()
            let hole = UIBezierPath()
            hole.move(to: CGPoint(x: cx - half * 0.82, y: cy + half * 0.82))
            hole.addLine(to: CGPoint(x: cx + half * 0.82, y: cy - half * 0.82))
            hole.lineWidth = 2.6 * scale; hole.lineCapStyle = .round
            UIColor.black.withAlphaComponent(0.8).setStroke(); hole.stroke()
        }
    }

    // MARK: Decals — POWER indicator (slice 3)

    /// The green POWER indicator. Portrait: just the LED, in the top-right corner of the
    /// surround's bottom strip (below the screen) — no label. Landscape: LED + an embossed
    /// "POWER" label (moulded body-colour relief, 1.2x bigger), level with Clip and centered in
    /// the gap between the surround's right edge and Clip.
    private func drawPower(_ ctx: CGContext, bounds: CGRect, screen: CGRect,
                           buttons: [ControlElement: CGRect], surroundRect: CGRect,
                           isLandscape: Bool, scale: CGFloat) {
        let r = 3.5 * scale
        if cardMode {
            // Card: the LED + "POWER" label at 35% of the card width, level with SELECT/START —
            // the GBA analogue of the GB/GBC card's PHONES badge. Tunable.
            let ssY = (buttons[.btnSelect] ?? buttons[.btnStart])?.midY ?? screen.maxY
            let cr = r * 1.5
            let gap = 5 * scale
            let fontSize = 9 * scale
            let kern = 0.5 * scale
            let tsz = measureLabel("POWER", size: fontSize, kern: kern)
            let unitW = cr * 2 + gap + tsz.width
            let originX = bounds.width * 0.35 - unitW / 2
            drawLed(CGPoint(x: originX + cr, y: ssY), r: cr, scale: scale)
            drawEmbossedLabel("POWER", at: CGPoint(x: originX + cr * 2 + gap, y: ssY - tsz.height / 2),
                              size: fontSize, color: buttonLabelColor, kern: kern, scale: scale)
            return
        }
        if isLandscape {
            guard let clip = buttons[.btnClip] else { return }
            let gap = 4 * scale
            let fontSize = 8 * scale * 1.2          // 1.2x bigger than portrait was
            let kern = 0.5 * scale
            let tsz = measureLabel("POWER", size: fontSize, kern: kern)
            let unitW = r * 2 + gap + tsz.width
            let center = CGPoint(x: (surroundRect.maxX + clip.minX) / 2, y: clip.midY)
            let originX = center.x - unitW / 2
            drawLed(CGPoint(x: originX + r, y: center.y), r: r, scale: scale)
            // Embossed; same colour + relief as the SELECT/START labels (the button colour).
            drawEmbossedLabel("POWER", at: CGPoint(x: originX + r * 2 + gap, y: center.y - tsz.height / 2),
                              size: fontSize, color: buttonLabelColor, kern: kern, scale: scale)
        } else {
            // Portrait: LED only — centered vertically between the screen bottom and MENU's top,
            // horizontally on MENU's centre.
            guard let menu = buttons[.btnMenu] else { return }
            let ledCenter = CGPoint(x: menu.midX, y: (screen.maxY + menu.minY) / 2)
            drawLed(ledCenter, r: r, scale: scale)
        }
    }

    /// The LED disc: dark seat + green dot + specular highlight.
    private func drawLed(_ c: CGPoint, r: CGFloat, scale: CGFloat) {
        UIColor.black.withAlphaComponent(0.35).setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - r - 1.5 * scale, y: c.y - r - 1.5 * scale,
                                    width: (r + 1.5 * scale) * 2, height: (r + 1.5 * scale) * 2)).fill()
        ledColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        UIColor.white.withAlphaComponent(0.6).setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - r * 0.5, y: c.y - r * 0.65,
                                    width: r * 0.6, height: r * 0.6)).fill()
    }

    private func measureLabel(_ s: String, size: CGFloat, kern: CGFloat) -> CGSize {
        NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold), .kern: kern,
        ]).size()
    }

    /// Text drawn in RELIEF (emboss): a light copy up-left + a dark copy down-right behind a
    /// `color` fill, so it reads as moulded plastic — the GB/GBC label treatment.
    private func drawEmbossedLabel(_ s: String, at origin: CGPoint, size: CGFloat,
                                   color: UIColor, kern: CGFloat, scale: CGFloat) {
        let d = 0.6 * scale
        func mk(_ c: UIColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: c, .kern: kern,
            ])
        }
        mk(UIColor.white.withAlphaComponent(0.5)).draw(at: CGPoint(x: origin.x - d, y: origin.y - d))
        mk(UIColor.black.withAlphaComponent(0.32)).draw(at: CGPoint(x: origin.x + d, y: origin.y + d))
        mk(color).draw(at: origin)
    }

    // MARK: Screen surround (slice 2)

    /// The GBA screen bezel: a glossy near-black panel grown from the screen and extended DOWN
    /// to envelop the MENU (portrait) / SELECT·MENU·START row (landscape) — the spot where
    /// "GAME BOY ADVANCE" sits on the real device (we draw neither that nor the NINTENDO mark,
    /// and leave body space above the panel for the latter). Small top corners + larger bottom
    /// corners give it the GBA's softer-bottom character. First cut — iterate visually.
    @discardableResult
    private func drawSurround(_ ctx: CGContext, bounds: CGRect, screen: CGRect,
                              buttons: [ControlElement: CGRect], isLandscape: Bool, scale: CGFloat) -> CGRect {
        let sidePad = 8 * scale     // landscape only: the dark surround margin beyond each screen side
        let topPad = 12 * scale
        let botMargin = 10 * scale

        // Bottom edge envelops the menu (portrait) or the SELECT·MENU·START row (landscape).
        var bottom = screen.maxY + 18 * scale
        if isLandscape {
            let ys = [buttons[.btnSelect], buttons[.btnMenu], buttons[.btnStart]].compactMap { $0?.maxY }
            if let m = ys.max() { bottom = m + botMargin }
        } else if let menu = buttons[.btnMenu] {
            bottom = menu.maxY + botMargin
        }

        // Portrait: extend the surround above the screen by the same height as the strip below it
        // (screen bottom → MENU top), so the bezel frames the screen symmetrically. Landscape
        // keeps the small top pad.
        let top: CGFloat
        if !isLandscape, let menu = buttons[.btnMenu] {
            top = screen.minY - max(topPad, menu.minY - screen.maxY)
        } else {
            top = screen.minY - topPad
        }
        var rect: CGRect
        if cardMode {
            // Card: a panel hugging the screen on all sides (there is no Menu strip to envelop),
            // with a small symmetric pad. Tunable.
            let pad = 18 * scale
            rect = screen.insetBy(dx: -pad, dy: -pad)
        } else if isLandscape {
            // Landscape: grow from the screen with side margins, clear of the device edges.
            rect = CGRect(x: screen.minX - sidePad, y: top,
                          width: screen.width + 2 * sidePad, height: bottom - top)
            rect = rect.intersection(bounds.insetBy(dx: 4 * scale, dy: 4 * scale))
        } else {
            // Portrait: edge-to-edge horizontally — the game screen runs full-width, so the
            // bezel matches it (no side margin, no edge inset).
            rect = CGRect(x: bounds.minX, y: top, width: bounds.width, height: bottom - top)
        }
        guard rect.width > 8, rect.height > 8 else { return .zero }

        let path = surroundPath(rect, topR: 10 * scale, botR: 24 * scale)

        // Glossy raised black panel: a soft drop shadow so it sits proud of the body.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2 * scale), blur: 6 * scale,
                      color: UIColor.black.withAlphaComponent(0.40).cgColor)
        surround.setFill(); path.fill()
        ctx.restoreGState()

        // A faint top sheen on the panel (glossy plastic), clipped to the panel.
        ctx.saveGState(); path.addClip()
        let sheen = [UIColor.white.withAlphaComponent(0.06).cgColor, UIColor.clear.cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheen, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.4), options: [])
        }
        ctx.restoreGState()

        // Thin groove around the LCD so the screen reads as set into the panel.
        UIColor.black.withAlphaComponent(0.6).setStroke()
        let groove = UIBezierPath(roundedRect: screen.insetBy(dx: -1.5 * scale, dy: -1.5 * scale),
                                  cornerRadius: 4 * scale)
        groove.lineWidth = 1.5 * scale; groove.stroke()
        UIColor.white.withAlphaComponent(0.05).setStroke()
        let rim = UIBezierPath(roundedRect: screen.insetBy(dx: -3 * scale, dy: -3 * scale),
                               cornerRadius: 5 * scale)
        rim.lineWidth = 1; rim.stroke()
        return rect
    }

    /// Rounded-rect path with independent top / bottom corner radii (clockwise from top-left).
    private func surroundPath(_ r: CGRect, topR: CGFloat, botR: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: r.minX + topR, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - topR, y: r.minY))
        p.addArc(withCenter: CGPoint(x: r.maxX - topR, y: r.minY + topR), radius: topR,
                 startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - botR))
        p.addArc(withCenter: CGPoint(x: r.maxX - botR, y: r.maxY - botR), radius: botR,
                 startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: r.minX + botR, y: r.maxY))
        p.addArc(withCenter: CGPoint(x: r.minX + botR, y: r.maxY - botR), radius: botR,
                 startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + topR))
        p.addArc(withCenter: CGPoint(x: r.minX + topR, y: r.minY + topR), radius: topR,
                 startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        p.close()
        return p
    }

    /// Body: vertical gradient + soft corner vignette + the shared plastic grain (same
    /// treatment as the GB/GBC body, just the GBA colours).
    private func drawBody(_ ctx: CGContext, _ bounds: CGRect) {
        let colors = [bodyTop.cgColor, bodyMid.cgColor, bodyBottom.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: bounds.midX, y: bounds.minY),
                                   end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
        } else {
            bodyMid.setFill(); ctx.fill(bounds)
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let vigColors = [UIColor.clear.cgColor,
                         UIColor.black.withAlphaComponent(0.12).cgColor] as CFArray
        if let vig = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: vigColors, locations: [0.55, 1]) {
            let radius = max(bounds.width, bounds.height) * 0.62
            ctx.drawRadialGradient(vig, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius,
                                   options: .drawsAfterEndLocation)
        }
        ctx.saveGState(); ctx.setAlpha(0.5)           // half grain (matches NDS — smoother plastic)
        GameBoySkin.grain.drawAsPattern(in: bounds)   // shared neutral grain
        ctx.restoreGState()
    }

    // MARK: Shoulder corners (landscape) — creusé areas that englobe L / R

    /// In landscape, the top-left / top-right corners get the same creusé look as the D-pad
    /// seat, in an area that englobes L / R. For L: the region above the polyline that runs
    /// along the bottom (left edge → L's right edge at y1 = L.bottom + the top gap) then up to
    /// the surround's top-left at the iPhone top edge. R mirrors it.
    private func drawShoulderCorners(buttons: [ControlElement: CGRect], bounds: CGRect,
                                     surroundRect: CGRect, scale: CGFloat) {
        let rad = 22 * scale   // rounded join between the two lines
        if let l = buttons[.btnL] {
            let y1 = l.maxY + (l.minY - bounds.minY)
            let corner = CGPoint(x: l.maxX, y: y1)
            let end = CGPoint(x: surroundRect.minX, y: bounds.minY)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
            p.addLine(to: CGPoint(x: bounds.minX, y: y1))
            p.addLine(to: pointToward(corner, from: CGPoint(x: bounds.minX, y: y1), by: rad))
            p.addQuadCurve(to: pointToward(corner, from: end, by: rad), controlPoint: corner)
            p.addLine(to: end)
            p.close()
            drawRecessedPolygon(p, scale: scale)
        }
        if let r = buttons[.btnR] {
            let y1 = r.maxY + (r.minY - bounds.minY)
            let corner = CGPoint(x: r.minX, y: y1)
            let end = CGPoint(x: surroundRect.maxX, y: bounds.minY)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: bounds.maxX, y: bounds.minY))
            p.addLine(to: CGPoint(x: bounds.maxX, y: y1))
            p.addLine(to: pointToward(corner, from: CGPoint(x: bounds.maxX, y: y1), by: rad))
            p.addQuadCurve(to: pointToward(corner, from: end, by: rad), controlPoint: corner)
            p.addLine(to: end)
            p.close()
            drawRecessedPolygon(p, scale: scale)
        }
    }

    /// In portrait, the L / R buttons get the same creusé treatment as the landscape shoulder
    /// corners — a re-dress of the surround's bottom strip (which holds the L · MENU · R row).
    /// For L: a horizontal line at `y1` (halfway between the screen bottom and L's top) runs from
    /// the device's left edge to L's right edge; from that vertex a second line drops to the
    /// surround's bottom at MENU's left edge. Both the top join and the bottom join (where the
    /// second line meets the bezel bottom) are rounded like the landscape corner. The enclosed
    /// area (holding L) is filled with the creusé look and clipped to the bezel; its bottom edge
    /// overshoots the surround so the fill reaches the bezel with no surround line showing. MENU
    /// stays on the plain surround between the two areas; R mirrors L.
    private func drawPortraitShoulders(buttons: [ControlElement: CGRect], bounds: CGRect,
                                       screen: CGRect, surroundRect: CGRect, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext(), let menu = buttons[.btnMenu] else { return }
        let rad = 22 * scale                     // rounded joins — matches the landscape corners
        let bottom = surroundRect.maxY
        let over = 6 * scale                     // overshoot below the bezel (clipped away)
        let clip = surroundPath(surroundRect, topR: 10 * scale, botR: 24 * scale)

        func creuse(button b: CGRect, deviceEdgeX: CGFloat, vertexX: CGFloat, endX: CGFloat) {
            let y1 = (screen.maxY + b.minY) / 2
            let edgeX = deviceEdgeX + (deviceEdgeX <= bounds.minX ? -over : over)  // overshoot the iPhone side edge
            let v1 = CGPoint(x: vertexX, y: y1)              // top vertex = L's right edge
            let start = CGPoint(x: edgeX, y: y1)
            let e = CGPoint(x: endX, y: bottom)              // bottom vertex = 2nd line meets the area bottom
            let menuWard = CGPoint(x: menu.midX, y: bottom)  // round the MENU-pointing (obtuse) angle:
                                                             // a convex fillet that extends the area toward MENU.
            let diagInset = 6 * scale                        // tiny — so the 2nd line descends to the bottom (the
                                                             // obtuse round barely shortens it, unlike the menu side)
            let p = UIBezierPath()
            p.move(to: start)
            p.addLine(to: pointToward(v1, from: start, by: rad))
            p.addQuadCurve(to: pointToward(v1, from: e, by: rad), controlPoint: v1)             // round top
            p.addLine(to: pointToward(e, from: v1, by: diagInset))                              // 2nd line reaches bottom
            p.addQuadCurve(to: pointToward(e, from: menuWard, by: rad), controlPoint: e)        // round bottom toward MENU
            p.addLine(to: CGPoint(x: edgeX, y: bottom + over))   // overshoot the bezel bottom + side edge
            p.close()
            ctx.saveGState(); clip.addClip()
            drawRecessedPolygon(p, scale: scale)
            ctx.restoreGState()
        }

        if let l = buttons[.btnL] {
            creuse(button: l, deviceEdgeX: bounds.minX, vertexX: l.maxX, endX: menu.minX)
        }
        if let r = buttons[.btnR] {
            creuse(button: r, deviceEdgeX: bounds.maxX, vertexX: r.minX, endX: menu.maxX)
        }
    }

    /// A creusé seat around each shoulder button (L / R), both orientations — the same engraved
    /// ring the A button gets (a recess slightly larger than the button), WITHOUT the dark under-
    /// disc. Filled with the shoulder-area colour so only the carved relief shows, matching the
    /// button's capsule shape.
    private func drawShoulderButtonSeats(buttons: [ControlElement: CGRect], scale: CGFloat) {
        for e in [ControlElement.btnL, .btnR] {
            guard let f = buttons[e] else { continue }
            drawRecessedCapsule(f.insetBy(dx: -4 * scale, dy: -4 * scale), fill: shoulderCreuse, scale: scale)
        }
    }

    /// A point `d` away from `corner`, toward `from` (for rounding a polygon vertex).
    private func pointToward(_ corner: CGPoint, from: CGPoint, by d: CGFloat) -> CGPoint {
        let dx = from.x - corner.x, dy = from.y - corner.y
        let len = max(1, hypot(dx, dy))
        return CGPoint(x: corner.x + dx / len * d, y: corner.y + dy / len * d)
    }

    /// Fill an arbitrary polygon with the engraved purple + grain, then an inner-edge shadow so
    /// it reads recessed (the D-pad creusé look, for the shoulder-corner areas).
    private func drawRecessedPolygon(_ path: UIBezierPath, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        shoulderCreuse.setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5); GameBoySkin.grain.drawAsPattern(in: path.bounds); ctx.restoreGState()
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.8 * scale), blur: 2.6 * scale,
                      color: UIColor.black.withAlphaComponent(0.5).cgColor)
        // The black L/MENU/R framing lines follow the surround colour under a custom skin.
        (gba?.surround ?? UIColor.black).setStroke(); path.lineWidth = 2 * scale; path.stroke()
        ctx.restoreGState()
    }

    // MARK: Button wells + under-shapes (slice 5)

    /// Recessed "creusé" seats behind the round controls (D-pad, A, B, Clip), plus a dark
    /// surround-coloured shape under each (1pt bigger), revealed when the button shrinks/tilts.
    /// So A/B/Clip read like the clip: a creusé ring + a dark ring around the button.
    private func drawButtonWells(buttons: [ControlElement: CGRect], usesJoystick: Bool, scale: CGFloat) {
        if let d = buttons[.dpad] {
            let r = max(d.width, d.height) / 2 + 4 * scale
            drawRecessedCircle(center: CGPoint(x: d.midX, y: d.midY), radius: r, scale: scale)
        }
        // A/B/Clip: a slightly-larger creusé seat behind each (back), then the dark under-disc.
        for e in [ControlElement.btnA, .btnB, .btnClip] {
            if let f = buttons[e] {
                let r = min(f.width, f.height) / 2 + 4 * scale
                drawRecessedCircle(center: CGPoint(x: f.midX, y: f.midY), radius: r, scale: scale)
            }
        }
        for e in [ControlElement.btnA, .btnB, .btnClip] {
            if let f = buttons[e] { drawUnderDisc(f, scale: scale) }
        }
        // The under-cross only fits the cross D-pad; hide it for the joystick.
        if !usesJoystick, let d = buttons[.dpad] { drawUnderCross(d, scale: scale) }
    }

    /// A circle the surround colour, 1pt bigger than the (round) button on every edge.
    private func drawUnderDisc(_ f: CGRect, scale: CGFloat) {
        let r = min(f.width, f.height) / 2 + 1 * scale
        surround.setFill()
        UIBezierPath(ovalIn: CGRect(x: f.midX - r, y: f.midY - r, width: 2 * r, height: 2 * r)).fill()
    }

    /// A cross the surround colour, 1pt bigger than the D-pad on every edge (matches the
    /// cross D-pad; for the joystick variant the creusé circle covers it).
    private func drawUnderCross(_ d: CGRect, scale: CGFloat) {
        surround.setFill()
        crossPath(in: d.insetBy(dx: -1 * scale, dy: -1 * scale),
                  armRatio: 0.336, cornerRadius: 6 * scale).fill()
    }

    /// A recessed circle: fill with the brand-creusé colour (body purple), carry the body grain,
    /// then the carved relief.
    private func drawRecessedCircle(center c: CGPoint, radius r: CGFloat, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        let path = UIBezierPath(ovalIn: rect)
        bodyMid.setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5); GameBoySkin.grain.drawAsPattern(in: rect); ctx.restoreGState()
        drawRecessRelief(path, outer: UIBezierPath(ovalIn: rect.insetBy(dx: -2 * scale, dy: -2 * scale)),
                         scale: scale)
    }

    /// A recessed capsule (rounded sides), filled with `fill` + grain + carved relief — the
    /// PHONES/brand recess, ported for the GBA brand mark.
    private func drawRecessedCapsule(_ rect: CGRect, fill: UIColor, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius = rect.height / 2
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        fill.setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5); GameBoySkin.grain.drawAsPattern(in: rect); ctx.restoreGState()
        let outer = UIBezierPath(roundedRect: rect.insetBy(dx: -2 * scale, dy: -2 * scale),
                                 cornerRadius: radius + 2 * scale)
        drawRecessRelief(path, outer: outer, scale: scale)
    }

    /// The carved "en relief" look: a dark top-rim inner shadow + a light bottom catch, clipped
    /// to `path` (strokes of the slightly-larger `outer`). Reusable for any recessed shape.
    private func drawRecessRelief(_ path: UIBezierPath, outer: UIBezierPath, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.8 * scale), blur: 2.6 * scale,
                      color: UIColor.black.withAlphaComponent(0.5).cgColor)
        UIColor.black.setStroke(); outer.lineWidth = 2 * scale; outer.stroke()
        ctx.restoreGState()
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 1.6 * scale,
                      color: UIColor.white.withAlphaComponent(0.4).cgColor)
        UIColor.white.setStroke(); outer.lineWidth = 1.5 * scale; outer.stroke()
        ctx.restoreGState()
    }

    /// A rounded 12-point cross filling `bounds` (arm width = bounds·armRatio) — mirrors the
    /// cross D-pad's shape so the under-cross lines up with the dressed pad.
    private func crossPath(in bounds: CGRect, armRatio: CGFloat, cornerRadius rr: CGFloat) -> UIBezierPath {
        let w = bounds.width, h = bounds.height
        let cx = bounds.midX, cy = bounds.midY
        let ox = bounds.origin.x, oy = bounds.origin.y
        let halfArm = w * armRatio / 2
        let r = min(rr, halfArm)
        let p = UIBezierPath()
        p.move(to: CGPoint(x: cx - halfArm + r, y: oy))
        p.addLine(to: CGPoint(x: cx + halfArm - r, y: oy))
        p.addArc(withCenter: CGPoint(x: cx + halfArm - r, y: oy + r), radius: r, startAngle: -.pi/2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: cx + halfArm, y: cy - halfArm))
        p.addLine(to: CGPoint(x: ox + w - r, y: cy - halfArm))
        p.addArc(withCenter: CGPoint(x: ox + w - r, y: cy - halfArm + r), radius: r, startAngle: -.pi/2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: ox + w, y: cy + halfArm - r))
        p.addArc(withCenter: CGPoint(x: ox + w - r, y: cy + halfArm - r), radius: r, startAngle: 0, endAngle: .pi/2, clockwise: true)
        p.addLine(to: CGPoint(x: cx + halfArm, y: cy + halfArm))
        p.addLine(to: CGPoint(x: cx + halfArm, y: oy + h - r))
        p.addArc(withCenter: CGPoint(x: cx + halfArm - r, y: oy + h - r), radius: r, startAngle: 0, endAngle: .pi/2, clockwise: true)
        p.addLine(to: CGPoint(x: cx - halfArm + r, y: oy + h))
        p.addArc(withCenter: CGPoint(x: cx - halfArm + r, y: oy + h - r), radius: r, startAngle: .pi/2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: cx - halfArm, y: cy + halfArm))
        p.addLine(to: CGPoint(x: ox + r, y: cy + halfArm))
        p.addArc(withCenter: CGPoint(x: ox + r, y: cy + halfArm - r), radius: r, startAngle: .pi/2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: ox, y: cy - halfArm + r))
        p.addArc(withCenter: CGPoint(x: ox + r, y: cy - halfArm + r), radius: r, startAngle: .pi, endAngle: -.pi/2, clockwise: true)
        p.addLine(to: CGPoint(x: cx - halfArm, y: cy - halfArm))
        p.addLine(to: CGPoint(x: cx - halfArm, y: oy + r))
        p.addArc(withCenter: CGPoint(x: cx - halfArm + r, y: oy + r), radius: r, startAngle: .pi, endAngle: -.pi/2, clockwise: true)
        p.close()
        return p
    }
}

// MARK: - Nintendo DS skin

/// The Nintendo DS dress: a light-grey grained body, a thin printed outline around each screen,
/// dot-grid speakers, and (later slices) the shared button dress recolored to the DS palette.
/// Inspired-by, no Nintendo marks. The host hands it the two screen sub-frames (dual screen):
/// portrait [top, bottom], landscape [left, right].
struct NintendoDSSkin: ConsoleSkin {
    let screens: [CGRect]
    var micPressed: Bool = false
    /// Nostalgia vs the Retro Pal recolour.
    var variant: DressVariant = .nostalgia
    /// Card mode: the square share card. `screens` holds a SINGLE combined screen rect (the stacked
    /// dual-screen image, like the Classic card), and the decorations (brand, speakers, light) are
    /// placed for the card instead of the in-game dual-screen / Menu layout.
    var cardMode: Bool = false
    /// A hardware controller is connected: the brand (which otherwise anchors to the now-hidden
    /// D-pad and so disappears) is drawn relative to MENU instead — below it in portrait, at 75%
    /// width level with it in landscape. Speakers / light are left as-is.
    var controllerConnected: Bool = false

    // Palette: body #C4C4C4, buttons #B6B6B6, ink #777777. Retro Pal recolours only the body
    // (fond → #595A76); the ink/decals are untouched per the draft (the D-pad lines + A/B label,
    // which DO recolour, are drawn by the buttons, not here).
    /// The user custom palette when `variant == .custom(.nds)`, else nil. `body`/`ink`/`led` drive
    /// their slots (NDS is near-monochrome, so `ink` covers outlines, speakers, MIC, labels…);
    /// the button faces live in the button views.
    private var nds: NDSSkinPalette? { variant.ndsPalette }

    private var bodyTop: UIColor {
        if let p = nds { return RetroPalPalette.bodyGradient(p.body).top }
        return variant == .retroPal ? RetroPalPalette.bodyGradient(RetroPalPalette.ndsBody).top
                                    : UIColor(red: 0.820, green: 0.820, blue: 0.820, alpha: 1) }
    private var bodyMid: UIColor {
        if let p = nds { return p.body }
        return variant == .retroPal ? RetroPalPalette.ndsBody
                                    : UIColor(red: 0.769, green: 0.769, blue: 0.769, alpha: 1) } // #C4C4C4
    private var bodyBottom: UIColor {
        if let p = nds { return RetroPalPalette.bodyGradient(p.body).bottom }
        return variant == .retroPal ? RetroPalPalette.bodyGradient(RetroPalPalette.ndsBody).bottom
                                    : UIColor(red: 0.680, green: 0.680, blue: 0.680, alpha: 1) }
    /// The dress STRUCTURE ink (screen outlines, speaker/MIC/light grooves, under-discs, card rails).
    /// Built-ins use #777777; a custom skin derives it from the body so the structure adapts to the
    /// chosen body while keeping the Nostalgia contrast (#C4C4C4 body → #777777 ≈ body −39% luma).
    /// The button MARKINGS (letters / icons) are separate slots, applied in the button views.
    private var ink: UIColor {
        if nds != nil { return bodyMid.rpMixed(with: .black, 0.39) }
        return UIColor(red: 0.467, green: 0.467, blue: 0.467, alpha: 1) }
    private let ledGreen   = UIColor(red: 0.22, green: 0.82, blue: 0.31, alpha: 1)    // GBA green LED
    private var ledColor: UIColor { nds?.led ?? ledGreen }
    /// Printed labels on the case (SELECT/START, MIC at rest) — the button colour, or the custom slot.
    private var buttonLabelColor: UIColor { nds?.buttons ?? DressKind.ndsButton }

    /// Retro Pal: brand icon + "Retro Pal" wordmark mirror the SELECT label colour (#EBEBEB).
    /// Custom auto-derives a contrasting same-hue tint from the body (not a user slot).
    private static let retroPalBrandIcon: UIImage? = RetroPalPalette.brandIcon(tinted: DressKind.ndsButton)
    private var brandColor: UIColor {
        if nds != nil { return bodyMid.rpContrastingMark }
        return variant == .retroPal ? DressKind.ndsButton : ink }
    /// The landscape light's two-line pitch (pt ×scale). The speakers compute their pitch from the
    /// gutter; the portrait light spreads on the gutter thirds.
    private let speakerColPitch: CGFloat = 21
    /// SELECT/START pill ratio — must match `SmallButton.selectPillRatio`.
    private static let selectPillRatio: CGFloat = 3.4

    /// The Retro Pal brand mark, tinted to a #777777 monochrome (printed-into-the-plastic look).
    private static let ciContext = CIContext(options: nil)
    private static let brandIcon: UIImage? = {
        guard let base = UIImage(named: "RetroPalBrand"), let ci = CIImage(image: base),
              let f = CIFilter(name: "CIColorMonochrome", parameters: [
                  kCIInputImageKey: ci,
                  "inputColor": CIColor(red: 0.467, green: 0.467, blue: 0.467),  // #777777
                  "inputIntensity": 1.0,
              ]),
              let out = f.outputImage,
              let cg = ciContext.createCGImage(out, from: out.extent) else { return UIImage(named: "RetroPalBrand") }
        return UIImage(cgImage: cg)
    }()

    func draw(in ctx: CGContext, bounds: CGRect, screenFrame screen: CGRect,
              buttons: [ControlElement: CGRect], isLandscape: Bool, usesJoystick: Bool, scale: CGFloat) {
        drawBody(ctx, bounds)
        if cardMode {
            drawCardCorners(bounds: bounds, scale: scale)
            drawCardRails(buttons: buttons, bounds: bounds, scale: scale)
        }
        drawButtonWells(buttons: buttons, scale: scale)
        drawShoulderButtonSeats(buttons: buttons, scale: scale)
        drawSelectStart(buttons: buttons, scale: scale)
        drawMic(buttons: buttons, scale: scale)
        drawSpeakers(bounds: bounds, buttons: buttons, isLandscape: isLandscape, scale: scale)
        drawLight(bounds: bounds, buttons: buttons, isLandscape: isLandscape, scale: scale)
        drawBrand(bounds: bounds, buttons: buttons, isLandscape: isLandscape, scale: scale)
        drawScreenOutlines(ctx, scale: scale)
    }

    /// Card: two full-width horizontal rails (the surround colour, with a slight relief) that
    /// bracket the L/R/MIC/light row. The top rail sits a quarter of the left-gutter HStack spacer
    /// above L's top; the bottom rail mirrors it below. Full width and drawn before the controls +
    /// screen, so the game screen sits in front of them.
    /// Card: a small "creusé" (engraved) recess in each of the four rounded corners.
    private func drawCardCorners(bounds: CGRect, scale: CGFloat) {
        let inset = 36 * scale
        let r = 13 * scale
        for x in [bounds.minX + inset, bounds.maxX - inset] {
            for y in [bounds.minY + inset, bounds.maxY - inset] {
                drawRecessedCircle(center: CGPoint(x: x, y: y), radius: r, scale: scale)
            }
        }
    }

    private func drawCardRails(buttons: [ControlElement: CGRect], bounds: CGRect, scale: CGFloat) {
        guard let l = buttons[.btnL] else { return }
        // A quarter of the left-gutter spacer above L's top / below L's bottom.
        let gap = (l.minX - bounds.minX) / 4
        let h = 5 * scale
        for y in [l.minY - gap, l.maxY + gap] {
            drawRecessedCapsule(CGRect(x: bounds.minX, y: y - h / 2, width: bounds.width, height: h),
                                fill: ink, scale: scale)
        }
    }

    /// Body: vertical gradient + soft corner vignette + the shared plastic grain — the same
    /// treatment as the GB/GBC and GBA bodies, in the DS greys.
    private func drawBody(_ ctx: CGContext, _ bounds: CGRect) {
        let colors = [bodyTop.cgColor, bodyMid.cgColor, bodyBottom.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: bounds.midX, y: bounds.minY),
                                   end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
        } else {
            bodyMid.setFill(); ctx.fill(bounds)
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let vigColors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.12).cgColor] as CFArray
        if let vig = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: vigColors, locations: [0.55, 1]) {
            let radius = max(bounds.width, bounds.height) * 0.62
            ctx.drawRadialGradient(vig, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius, options: .drawsAfterEndLocation)
        }
        // NDS plastic is smoother ("lisse") than the GB/GBA shells — half the grain.
        ctx.saveGState()
        ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: bounds)
        ctx.restoreGState()
    }

    /// A thin printed rim around each screen: a #777777 stroke 2pt outside the screen, 2px wide,
    /// with a soft drop shadow so the screen reads as set into the body (the 3D effect).
    private func drawScreenOutlines(_ ctx: CGContext, scale: CGFloat) {
        for s in screens where !s.isEmpty {
            let path = UIBezierPath(roundedRect: s.insetBy(dx: -2 * scale, dy: -2 * scale),
                                    cornerRadius: 4 * scale)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1.5 * scale), blur: 3 * scale,
                          color: UIColor.black.withAlphaComponent(0.45).cgColor)
            ink.setStroke()
            path.lineWidth = 2 * scale
            path.stroke()
            ctx.restoreGState()
        }
    }

    // MARK: Button wells (creusé seats + under-shapes) — ported from the GBA dress, NDS colours.

    /// Recessed creusé seats behind the round controls (A/B/X/Y, MENU, CLIP) + a dark under-disc
    /// revealed on press. The D-pad gets neither a recessed circle nor an under-cross in the NDS dress.
    private func drawButtonWells(buttons: [ControlElement: CGRect], scale: CGFloat) {
        let round: [ControlElement] = [.btnA, .btnB, .btnX, .btnY, .btnClip, .btnMenu]
        for e in round {
            if let f = buttons[e] {
                let r = min(f.width, f.height) / 2 + 4 * scale
                drawRecessedCircle(center: CGPoint(x: f.midX, y: f.midY), radius: r, scale: scale)
            }
        }
        for e in round {
            if let f = buttons[e] { drawUnderDisc(f, scale: scale) }
        }
    }

    /// A creusé seat around each shoulder button (L / R), capsule-matched — the engraved ring,
    /// no dark under-disc, filled with the body colour so only the relief shows.
    private func drawShoulderButtonSeats(buttons: [ControlElement: CGRect], scale: CGFloat) {
        for e in [ControlElement.btnL, .btnR] {
            guard let f = buttons[e] else { continue }
            // Rounded SQUARE seat that mimics the button's angle: the SAME corner factor applied
            // to the seat's own (slightly larger) dimensions (ShoulderButton.ndsCornerFactor).
            let seat = f.insetBy(dx: -4 * scale, dy: -4 * scale)
            drawRecessedCapsule(seat, fill: bodyMid, scale: scale,
                                corner: min(seat.width, seat.height) * ShoulderButton.ndsCornerFactor)
        }
    }

    /// SELECT / START: a horizontal creusé pill (body fill) holding the embossed #777777 label on
    /// the RIGHT; the BUTTON itself (SmallButton) is the tiny circle on the LEFT — the mirror of GBA.
    private func drawSelectStart(buttons: [ControlElement: CGRect], scale: CGFloat) {
        for (e, text) in [(ControlElement.btnSelect, "SELECT"), (.btnStart, "START")] {
            guard let f = buttons[e] else { continue }
            let pillH = f.width / Self.selectPillRatio
            let pillRect = CGRect(x: f.minX, y: f.midY - pillH / 2, width: f.width, height: pillH)
            drawRecessedCapsule(pillRect, fill: bodyMid, scale: scale)
            // Tiny "button" on the LEFT: creusé seat + dark under-disc (the light circle is SmallButton's).
            let d = pillH * 0.7, pad = pillH * 0.25
            let circleC = CGPoint(x: f.minX + pad + d / 2, y: f.midY)
            drawRecessedCircle(center: circleC, radius: d / 2 + 3 * scale, scale: scale)
            let ur = d / 2 + 1 * scale
            ink.setFill()
            UIBezierPath(ovalIn: CGRect(x: circleC.x - ur, y: circleC.y - ur, width: 2 * ur, height: 2 * ur)).fill()
            // Label to the RIGHT of the tiny circle, in the #EBEBEB button colour, embossed.
            let circleRight = f.minX + pad + d
            let labelLeft = circleRight + pillH * 0.25
            let labelW = (pillRect.maxX - pillH * 0.5) - labelLeft
            guard labelW > 8 else { continue }
            let kern = 0.5 * scale
            var size = pillRect.height * 0.72
            var sz = measureLabel(text, size: size, kern: kern)
            if sz.width > labelW, sz.width > 0 { size *= labelW / sz.width; sz = measureLabel(text, size: size, kern: kern) }
            drawEmbossedLabel(text, at: CGPoint(x: labelLeft, y: pillRect.midY - sz.height / 2),
                              size: size, color: buttonLabelColor, kern: kern, scale: scale)
        }
    }

    /// MIC: a single vertical slit (recessed #777777 groove + a black cut-through hole, like a GBA
    /// speaker line) on the left, with the "MIC." label to its right in the #EBEBEB button colour.
    private func drawMic(buttons: [ControlElement: CGRect], scale: CGFloat) {
        guard let f = buttons[.btnMic] else { return }
        let lineH = f.height * 0.55
        let lineX = f.minX + f.width * 0.16
        drawVerticalSlit(x: lineX, cy: f.midY, height: lineH,
                         holeColor: UIColor.black.withAlphaComponent(0.8), scale: scale)

        let labelLeft = lineX + 7 * scale
        let labelW = f.maxX - labelLeft
        guard labelW > 6 else { return }
        let kern = 0.5 * scale
        var size = f.height * 0.4
        var sz = measureLabel("MIC.", size: size, kern: kern)
        if sz.width > labelW, sz.width > 0 { size *= labelW / sz.width; sz = measureLabel("MIC.", size: size, kern: kern) }
        // The resting label is left-aligned; on press it shrinks 5% about its own centre and
        // recolours to the clip-icon ink (#777777).
        let centerX = labelLeft + sz.width / 2, centerY = f.midY
        if micPressed { size *= 0.95; sz = measureLabel("MIC.", size: size, kern: kern) }
        drawEmbossedLabel("MIC.", at: CGPoint(x: centerX - sz.width / 2, y: centerY - sz.height / 2),
                          size: size, color: micPressed ? ink : buttonLabelColor, kern: kern, scale: scale)
    }

    /// A single vertical slit (recessed #777777 groove + a cut-through `holeColor` hole) — the GBA
    /// speaker-line look. Reused by the MIC decal and the "light" component.
    private func drawVerticalSlit(x: CGFloat, cy: CGFloat, height: CGFloat, holeColor: UIColor, scale: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x, y: cy - height / 2))
        p.addLine(to: CGPoint(x: x, y: cy + height / 2))
        let groove = UIBezierPath(cgPath: p.copy(strokingWithWidth: 5 * scale, lineCap: .round,
                                                 lineJoin: .round, miterLimit: 0))
        ink.setFill(); groove.fill()
        let hole = UIBezierPath()
        hole.move(to: CGPoint(x: x, y: cy - height * 0.42))
        hole.addLine(to: CGPoint(x: x, y: cy + height * 0.42))
        hole.lineWidth = 2.2 * scale; hole.lineCapStyle = .round
        holeColor.setStroke(); hole.stroke()
    }

    /// The "light": two vertical slits side by side (the speaker column pitch apart), same size as
    /// the MIC slit — the first hole dark (like MIC), the second the GBA green LED. Portrait:
    /// centred on the two screens' combined vertical centre, in the right gutter beside the upper
    /// screen. Landscape: level with MENU, centred in the gap between MENU's end and the X button.
    private func drawLight(bounds: CGRect, buttons: [ControlElement: CGRect],
                           isLandscape: Bool, scale: CGFloat) {
        guard let mic = buttons[.btnMic] else { return }
        let lineH = mic.height * 0.55
        let cy: CGFloat, x1: CGFloat, x2: CGFloat
        if cardMode {
            // Card: the two-slit "light" sits on the L/R/MIC row (the screens' meet), in the right
            // gutter at the mirror of MIC — the [Spacer, light, Spacer, R, Spacer] inner slot.
            let pitch = speakerColPitch * scale
            let cx = bounds.maxX - mic.midX        // mirror of MIC across the card centre
            cy = mic.midY                          // the components row (follows L/R/MIC)
            x1 = cx - pitch / 2; x2 = cx + pitch / 2
            drawVerticalSlit(x: x1, cy: cy, height: lineH,
                             holeColor: UIColor.black.withAlphaComponent(0.8), scale: scale)
            drawVerticalSlit(x: x2, cy: cy, height: lineH, holeColor: ledColor, scale: scale)
            return
        }
        if isLandscape {
            guard let menu = buttons[.btnMenu], let x = buttons[.btnX] else { return }
            let cx = (menu.maxX + x.minX) / 2
            let pitch = speakerColPitch * scale
            cy = menu.midY
            x1 = cx - pitch / 2; x2 = cx + pitch / 2
        } else {
            guard screens.count == 2 else { return }
            let upper = screens[0]
            cy = (min(screens[0].minY, screens[1].minY) + max(screens[0].maxY, screens[1].maxY)) / 2
            // Even thirds in the gutter (Spacer · line · Spacer · line · Spacer).
            let gutter = bounds.maxX - upper.maxX
            x1 = upper.maxX + gutter / 3; x2 = upper.maxX + gutter * 2 / 3
        }
        drawVerticalSlit(x: x1, cy: cy, height: lineH,
                         holeColor: UIColor.black.withAlphaComponent(0.8), scale: scale)
        drawVerticalSlit(x: x2, cy: cy, height: lineH, holeColor: ledColor, scale: scale)
    }

    // MARK: Speakers (dot grids — the DS's twin 6-hole speakers)

    /// Two speaker packs (2 columns × 3 rows of dark "hole" dots). Portrait: one each side of the
    /// UPPER screen, vertically centred on it. Landscape: in the left/right gutters, vertically
    /// centred between the iPhone top edge and the L / R button top.
    private func drawSpeakers(bounds: CGRect, buttons: [ControlElement: CGRect],
                              isLandscape: Bool, scale: CGFloat) {
        if cardMode {
            // Card: a dot-grid pack in each gutter, rotated 90° (3 cols × 2 rows), pack centre + x
            // position from the (upper) screen. The separated screenshot card (two screens) centres
            // the packs on the UPPER screen's vertical centre with 30% larger dots; the combined /
            // clip card (one screen) keeps the between-top-and-screen centre and the 2× dots.
            guard let screen = screens.first else { return }
            let separated = screens.count == 2
            let cy = separated ? screen.midY : (bounds.minY + screen.midY) / 2
            let dots: CGFloat = separated ? 2 * 1.3 : 2
            let lg = screen.minX - bounds.minX
            drawSpeakerPack(center: CGPoint(x: bounds.minX + lg / 2, y: cy),
                            cols: 3, rows: 2, pitch: lg / 6, scale: scale, dotScale: dots)
            let rg = bounds.maxX - screen.maxX
            drawSpeakerPack(center: CGPoint(x: screen.maxX + rg / 2, y: cy),
                            cols: 3, rows: 2, pitch: rg / 6, scale: scale, dotScale: dots)
            return
        }
        guard screens.count == 2 else { return }
        if isLandscape {
            // Rotated 90° (3 columns × 2 rows). The 3 columns sit on the gutter quarters
            // (Spacer·dot·Spacer·dot·Spacer·dot·Spacer); the 2 rows mirror that spacing.
            let left = screens[0], right = screens[1]
            if let l = buttons[.btnL] {
                let gutter = left.minX - bounds.minX
                drawSpeakerPack(center: CGPoint(x: bounds.minX + gutter / 2, y: (bounds.minY + l.minY) / 2),
                                cols: 3, rows: 2, pitch: gutter / 4, scale: scale)
            }
            if let r = buttons[.btnR] {
                let gutter = bounds.maxX - right.maxX
                drawSpeakerPack(center: CGPoint(x: right.maxX + gutter / 2, y: (bounds.minY + r.minY) / 2),
                                cols: 3, rows: 2, pitch: gutter / 4, scale: scale)
            }
        } else {
            // 2 columns on the gutter thirds (aligned with the light's two lines); rows mirror it.
            let upper = screens[0]
            let cy = upper.midY
            let lg = upper.minX - bounds.minX
            drawSpeakerPack(center: CGPoint(x: bounds.minX + lg / 2, y: cy),
                            cols: 2, rows: 3, pitch: lg / 3, scale: scale)
            let rg = bounds.maxX - upper.maxX
            drawSpeakerPack(center: CGPoint(x: upper.maxX + rg / 2, y: cy),
                            cols: 2, rows: 3, pitch: rg / 3, scale: scale)
        }
    }

    /// A `cols × rows` grid of dark hole-dots, uniform `pitch` on both axes, centred on `center`.
    /// The dot radius adapts to the pitch so tight gutters (iPhone SE) don't crowd.
    private func drawSpeakerPack(center: CGPoint, cols: Int, rows: Int, pitch: CGFloat, scale: CGFloat,
                                 dotScale: CGFloat = 1) {
        guard pitch > 1 else { return }
        let outerR = min(2.8 * scale, pitch * 0.33) * dotScale
        for col in 0..<cols {
            for row in 0..<rows {
                let p = CGPoint(x: center.x + (CGFloat(col) - CGFloat(cols - 1) / 2) * pitch,
                                y: center.y + (CGFloat(row) - CGFloat(rows - 1) / 2) * pitch)
                drawSpeakerDot(at: p, outerR: outerR)
            }
        }
    }

    /// One recessed "hole": a #777777 ring + a black centre + a faint bottom catch-light.
    private func drawSpeakerDot(at c: CGPoint, outerR: CGFloat) {
        let innerR = outerR * 0.6
        ink.setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - outerR, y: c.y - outerR, width: 2 * outerR, height: 2 * outerR)).fill()
        UIColor.black.withAlphaComponent(0.72).setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - innerR, y: c.y - innerR, width: 2 * innerR, height: 2 * innerR)).fill()
        UIColor.white.withAlphaComponent(0.22).setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - innerR * 0.45, y: c.y + innerR * 0.25,
                                    width: innerR * 0.9, height: innerR * 0.6)).fill()
    }

    // MARK: Branding ("Retro Pal" mark)

    /// The Retro Pal mark. Portrait: centred on MENU, in the gap between MENU's bottom and the
    /// D-pad's top. Landscape: centred on the D-pad vertically (centre-to-centre), on MENU's x.
    /// As big as fits the available gap without colliding. Icon + text both #777777.
    private func drawBrand(bounds: CGRect, buttons: [ControlElement: CGRect],
                           isLandscape: Bool, scale: CGFloat) {
        let aspect = brandAspect(scale: scale)
        if cardMode {
            // Card: scaled to the space above the (upper) screen — the dimension is the same on both
            // the separated screenshot card and the combined / clip card.
            guard let screen = screens.first else { return }
            var h = min(34 * scale, (screen.minY - bounds.minY) * 0.4) * 2.5
            var w = h * aspect
            let availW = bounds.width - 16 * scale
            if w > availW { w = availW; h = w / aspect }
            guard h > 8 * scale, w > 24 * scale else { return }
            // Separated screenshot card (two screens): same size, relocated — horizontally on the
            // A/B/X/Y column (X's centre), vertically centred between the bottom rail (derived from
            // L like drawCardRails) and the X button's top. Combined / clip card: above the screen,
            // horizontally centred.
            if screens.count == 2, let x = buttons[.btnX], let l = buttons[.btnL] {
                let bottomRailY = l.maxY + (l.minX - bounds.minX) / 4
                let cy = (bottomRailY + x.minY) / 2
                drawBranding(in: CGRect(x: x.midX - w / 2, y: cy - h / 2, width: w, height: h), scale: scale)
                return
            }
            let cy = max(h / 2 + 8 * scale, (bounds.minY + screen.minY) / 2)
            drawBranding(in: CGRect(x: bounds.midX - w / 2, y: cy - h / 2, width: w, height: h), scale: scale)
            return
        }
        if controllerConnected {
            // The D-pad (the brand's normal anchor) is hidden, so the brand would vanish. Re-place it
            // relative to the still-visible MENU. ONE size for both orientations — the landscape size,
            // from the landscape D-pad's height (a pure function of the layout).
            guard let menu = buttons[.btnMenu] else { return }
            let dpadH = EmulatorLayoutGeometry.buttonSize(.dpad, isNDS: true, isLandscape: true,
                                                          deviceScale: scale).height
            let h = min(dpadH * 0.5, 34 * scale)
            let w = h * aspect
            let cx: CGFloat, cy: CGFloat
            if isLandscape {
                cx = bounds.width * 0.75                 // 75% of the iPhone screen width
                cy = menu.midY                           // level with MENU (centre to centre)
            } else {
                cx = menu.midX                           // aligned with MENU
                cy = (menu.maxY + bounds.maxY) / 2       // centred between MENU's bottom and screen bottom
            }
            drawBranding(in: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), scale: scale)
            return
        }
        guard let menu = buttons[.btnMenu], let dpad = buttons[.dpad] else { return }
        var h: CGFloat, w: CGFloat, cx: CGFloat, cy: CGFloat, availW: CGFloat
        if isLandscape {
            // Centred in the gap between the D-pad's end and MENU's start, level with MENU.
            h = min(dpad.height * 0.5, 34 * scale)
            w = h * aspect
            cx = (dpad.maxX + menu.minX) / 2
            cy = menu.midY
            availW = (menu.minX - dpad.maxX) - 8 * scale
        } else {
            // 2.5x bigger, centred on the D-pad's TOP; horizontal position unchanged (on MENU).
            h = min((dpad.minY - menu.maxY) * 0.5, 34 * scale) * 2.5
            w = h * aspect
            cx = menu.midX
            cy = dpad.minY
            availW = min(cx - bounds.minX, bounds.maxX - cx) * 2 - 8 * scale
        }
        if availW > 24 * scale, w > availW { w = availW; h = w / aspect }
        guard h > 8 * scale, w > 24 * scale else { return }
        drawBranding(in: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), scale: scale)
    }

    /// The brand mark's width/height ratio (icon + "Retro Pal" inside the capsule).
    private func brandAspect(scale: CGFloat) -> CGFloat {
        let txt = measureLabel("Retro Pal", size: 11 * scale, kern: 0.5 * scale)
        let iconH = 16 * scale
        let contentW = iconH + 5 * scale + txt.width
        let contentH = max(iconH, txt.height)
        return (contentW + 20 * scale) / max(1, contentH + 10 * scale)
    }

    /// Recessed capsule (body fill) + the tinted icon + the embossed "Retro Pal" text (#777777).
    private func drawBranding(in rect: CGRect, scale: CGFloat) {
        guard rect.width > 24 * scale, rect.height > 12 * scale else { return }
        drawRecessedCapsule(rect, fill: bodyMid, scale: scale)
        let inset = rect.insetBy(dx: rect.height * 0.34, dy: rect.height * 0.20)
        guard inset.width > 4, inset.height > 4 else { return }
        let iconSide = inset.height
        let gap = iconSide * 0.22
        // Custom tints the brand icon to the auto-derived brand colour (matches the wordmark).
        let brandImage: UIImage? = nds != nil
            ? RetroPalPalette.brandIcon(tinted: brandColor)
            : (variant == .retroPal ? Self.retroPalBrandIcon : Self.brandIcon)
        if let icon = brandImage {
            icon.draw(in: aspectFit(icon.size, in: CGRect(x: inset.minX, y: inset.minY,
                                                          width: iconSide, height: iconSide)))
        }
        let textX = inset.minX + iconSide + gap
        let textRect = CGRect(x: textX, y: inset.minY, width: inset.maxX - textX, height: inset.height)
        if textRect.width > 8 { drawBrandText("Retro Pal", in: textRect, scale: scale) }
    }

    private func drawBrandText(_ s: String, in rect: CGRect, scale: CGFloat) {
        let kern = 0.5 * scale
        var fontSize = rect.height * 0.95
        var sz = measureLabel(s, size: fontSize, kern: kern)
        if sz.width > rect.width, sz.width > 0 { fontSize *= rect.width / sz.width; sz = measureLabel(s, size: fontSize, kern: kern) }
        drawEmbossedLabel(s, at: CGPoint(x: rect.minX, y: rect.midY - sz.height / 2),
                          size: fontSize, color: brandColor, kern: kern, scale: scale)
    }

    private func aspectFit(_ imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let s = min(rect.width / imageSize.width, rect.height / imageSize.height)
        return CGRect(x: rect.midX - imageSize.width * s / 2, y: rect.midY - imageSize.height * s / 2,
                      width: imageSize.width * s, height: imageSize.height * s)
    }

    private func measureLabel(_ s: String, size: CGFloat, kern: CGFloat) -> CGSize {
        NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold), .kern: kern,
        ]).size()
    }

    /// Text in RELIEF: a light copy up-left + a dark copy down-right behind a `color` fill.
    private func drawEmbossedLabel(_ s: String, at origin: CGPoint, size: CGFloat,
                                   color: UIColor, kern: CGFloat, scale: CGFloat) {
        let d = 0.6 * scale
        func mk(_ c: UIColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: c, .kern: kern,
            ])
        }
        mk(UIColor.white.withAlphaComponent(0.5)).draw(at: CGPoint(x: origin.x - d, y: origin.y - d))
        mk(UIColor.black.withAlphaComponent(0.32)).draw(at: CGPoint(x: origin.x + d, y: origin.y + d))
        mk(color).draw(at: origin)
    }

    /// A dark (#777777) circle 1pt bigger than the round button — the under-disc revealed on press.
    private func drawUnderDisc(_ f: CGRect, scale: CGFloat) {
        let r = min(f.width, f.height) / 2 + 1 * scale
        ink.setFill()
        UIBezierPath(ovalIn: CGRect(x: f.midX - r, y: f.midY - r, width: 2 * r, height: 2 * r)).fill()
    }

    /// A recessed circle: body-colour fill + half grain + carved relief (only the relief shows).
    private func drawRecessedCircle(center c: CGPoint, radius r: CGFloat, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        let path = UIBezierPath(ovalIn: rect)
        bodyMid.setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5); GameBoySkin.grain.drawAsPattern(in: rect); ctx.restoreGState()
        drawRecessRelief(path, outer: UIBezierPath(ovalIn: rect.insetBy(dx: -2 * scale, dy: -2 * scale)),
                         scale: scale)
    }

    /// A recessed rounded rect: `fill` + half grain + carved relief. `corner` defaults to a full
    /// capsule (height/2); the L/R seat passes a small radius for the rounded-square look.
    private func drawRecessedCapsule(_ rect: CGRect, fill: UIColor, scale: CGFloat, corner: CGFloat? = nil) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius = corner ?? rect.height / 2
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        fill.setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5); GameBoySkin.grain.drawAsPattern(in: rect); ctx.restoreGState()
        let outer = UIBezierPath(roundedRect: rect.insetBy(dx: -2 * scale, dy: -2 * scale),
                                 cornerRadius: radius + 2 * scale)
        drawRecessRelief(path, outer: outer, scale: scale)
    }

    /// The carved "en relief" look: a dark top-rim inner shadow + a light bottom catch, clipped to
    /// `path` (strokes of the slightly-larger `outer`).
    private func drawRecessRelief(_ path: UIBezierPath, outer: UIBezierPath, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.8 * scale), blur: 2.6 * scale,
                      color: UIColor.black.withAlphaComponent(0.5).cgColor)
        UIColor.black.setStroke(); outer.lineWidth = 2 * scale; outer.stroke()
        ctx.restoreGState()
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 1.6 * scale,
                      color: UIColor.white.withAlphaComponent(0.4).cgColor)
        UIColor.white.setStroke(); outer.lineWidth = 1.5 * scale; outer.stroke()
        ctx.restoreGState()
    }
}
