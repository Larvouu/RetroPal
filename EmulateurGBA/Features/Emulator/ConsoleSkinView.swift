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
    /// NDS only: the slot-2 GBA game's box art, shown in a small recessed square on the dress,
    /// both orientations. nil = empty slot OR no cover — either way no square is drawn (an empty
    /// well would read as a rendering bug). Set by the host at game load.
    var slot2Cover: UIImage? = nil { didSet { if slot2Cover != oldValue { setNeedsDisplay() } } }

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
    /// (The NES has no dress yet: it would show a Game Boy body around an NES game, which is
    /// worse than the plain page it gets instead.)
    /// The PlayStation has no dress yet, and this is the sentence the file
    /// already anticipated: a per-console dress follows as its own release, and
    /// wrapping a PlayStation game in a Super Nintendo body would be worse than
    /// the plain page it gets instead.
    static func hasSkin(for system: PresetSystem) -> Bool { true }

    /// Whether the on-screen controls get the dressed look. Tracks `hasSkin`, and since the NES
    /// dress landed every console has one, so both answer yes for all of them. Kept as functions
    /// rather than deleted: a console added later starts undressed and these are where it says so.
    static func hasDressedControls(for system: PresetSystem) -> Bool { true }

    private var skin: ConsoleSkin? {
        switch system {
        case .gbc: return GameBoySkin(variant: variant, hideABSeat: hideABSeat, cardMode: cardMode,
                                      controllerConnected: controllerConnected)
        case .gba: return GameBoyAdvanceSkin(variant: variant, cardMode: cardMode,
                                             controllerConnected: controllerConnected, allButtons: allButtonFrames)
        case .nds: return NintendoDSSkin(screens: ndsScreens, micPressed: micPressed, variant: variant,
                                         cardMode: cardMode, controllerConnected: controllerConnected,
                                         slot2Cover: slot2Cover)
        case .snes: return SuperNintendoSkin(variant: variant, cardMode: cardMode,
                                             controllerConnected: controllerConnected)
        case .nes: return NintendoEntertainmentSystemSkin(variant: variant, cardMode: cardMode,
                                                          controllerConnected: controllerConnected)
        case .ps1: return PlayStationSkin(variant: variant, cardMode: cardMode,
                                          controllerConnected: controllerConnected)
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
    /// The slot-2 GBA game's box art (dual-slot): drawn in a small recessed square on the body,
    /// PORTRAIT ONLY for now. nil = no square at all.
    var slot2Cover: UIImage? = nil

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
        drawSlot2Well(bounds: bounds, buttons: buttons, isLandscape: isLandscape, scale: scale)
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

    /// Slot-2 dual-slot indicator: a small recessed square (the L/R-seat "incrusté" treatment —
    /// same corner factor, body fill) holding the slot-2 GBA game's box art at 0.8 opacity.
    /// Drawn only when there is art to show (an empty well would read as a defect). Body-fill +
    /// derived ink → custom-skin colour edits repaint it like every other structure element.
    ///
    /// PORTRAIT: vertical centre = the D-pad's bottom edge, horizontal centre = the SELECT+START
    /// block's centre, sized from the D-pad and shrinking to keep a gap above the SELECT/START row.
    ///
    /// LANDSCAPE (spec of 2026-07-27): same size rule, horizontally centred on MIC, and
    /// vertically centred in the empty band between the screens' bottom edge and MIC's top edge.
    /// Both landscape screens share a bottom edge, so screen swapping does not move it.
    ///
    /// Dress only: this draws, it never affects a hit box, so the controls layout engine and its
    /// closed NDS-landscape thread are untouched.
    private func drawSlot2Well(bounds: CGRect, buttons: [ControlElement: CGRect],
                               isLandscape: Bool, scale: CGFloat) {
        guard !cardMode, let cover = slot2Cover, let dpad = buttons[.dpad] else { return }

        let cx: CGFloat
        let cy: CGFloat
        var side = min(dpad.width * 0.55, 64 * scale)
        var rect: CGRect

        if isLandscape {
            guard let mic = buttons[.btnMic], screens.count == 2 else { return }
            let screensBottom = max(screens[0].maxY, screens[1].maxY)
            let bandTop = screensBottom + 8 * scale
            let bandBottom = mic.minY - 8 * scale
            guard bandBottom > bandTop else { return }
            cx = mic.midX
            cy = (bandTop + bandBottom) / 2
            // Never taller than the band it sits in.
            side = min(side, bandBottom - bandTop)
            rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
        } else {
            guard let sel = buttons[.btnSelect], let start = buttons[.btnStart] else { return }
            cx = sel.union(start).midX
            cy = dpad.maxY
            // Never collide with the SELECT/START row below: keep an 8pt gap.
            let bottomLimit = min(sel.minY, start.minY) - 8 * scale
            side = min(side, 2 * (bottomLimit - cy))
            guard side > 24 * scale else { return }
            // Product call after seeing both orientations: portrait reads
            // small next to landscape. Grow it by half, anchored on the SAME
            // bottom edge and the SAME horizontal centre, so it expands UP into
            // the empty band rather than towards the SELECT/START row. The
            // 8pt gap below is preserved by construction.
            let bottom = cy + side / 2
            side *= 1.5
            rect = CGRect(x: cx - side / 2, y: bottom - side, width: side, height: side)
        }

        guard side > 24 * scale else { return }
        // Keep it on the dress on narrow devices (the SE is always the tight one).
        let inset = 4 * scale
        if rect.maxX > bounds.maxX - inset { rect.origin.x = bounds.maxX - inset - side }
        if rect.minX < bounds.minX + inset { rect.origin.x = bounds.minX + inset }
        let corner = side * ShoulderButton.ndsCornerFactor
        drawRecessedCapsule(rect, fill: bodyMid, scale: scale, corner: corner)
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let art = rect.insetBy(dx: 3 * scale, dy: 3 * scale)
        let clip = UIBezierPath(roundedRect: art, cornerRadius: max(2 * scale, corner - 3 * scale))
        ctx.saveGState()
        clip.addClip()
        cover.draw(in: aspectFill(cover.size, in: art), blendMode: .normal, alpha: 0.8)
        ctx.restoreGState()
    }

    /// Aspect-FILL counterpart of `aspectFit`: the image covers `rect` entirely (centred,
    /// overflow clipped by the caller).
    private func aspectFill(_ imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let s = max(rect.width / imageSize.width, rect.height / imageSize.height)
        return CGRect(x: rect.midX - imageSize.width * s / 2, y: rect.midY - imageSize.height * s / 2,
                      width: imageSize.width * s, height: imageSize.height * s)
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

// MARK: - Super Nintendo skin

/// The Super Nintendo dress: a warm grey body, four coloured face buttons in a cluster, a
/// near-black cross in a round dish, a short SELECT/START pair, and the Game Boy's dark inlaid
/// panel around the screen. Inspired-by: our own art, the era's colours, no marks.
///
/// THE PAGE IS TWO PLACES, and that is the whole idea of the portrait dress (2026-08-17). The
/// top is the console's SCREEN: the dark inlaid panel, running the full width from the very top
/// of the device, ending just under the picture. Everything below it is the CONTROLLER: one
/// continuous grey shell carrying the shoulders, the pad, the face cluster and the pair. The
/// panel used to run down past the L · MENU · R strip, which put the shoulders inside the
/// screen's surround and made them read as part of the television rather than as part of the
/// pad. Landscape needs none of this: the picture is already a panel with a gutter each side.
///
/// The colours are the spec of 2026-08-12, verbatim: A #CF352E, B #EFC446 (2026-08-13,
/// replacing the first spec's #24379B, so the pair reads red-and-yellow like the pad), X #294091,
/// Y #366840; D-pad and the SELECT/START buttons #262628; the printed SELECT/START words the
/// body colour a little darker, so they read on it. Body #D7D3CF as of 2026-08-17, replacing the
/// lavender #C1BCD4. The A/B/X/Y letters were the body colour in that spec and are now black,
/// which is the only single colour that reads on all four faces (the measurement is in
/// `SNESTouchControlsView`). The FACE COLOURS themselves live on the buttons (DressKind +
/// ActionButton.dressFace) because they are worn, not drawn here.
///
/// What makes the lower half read as a controller rather than as loose buttons: the pad sits in
/// a round dish that clears its arm tips, the four faces sit in a recessed circle crossed by two
/// raised capsules, and every control has a carved seat.
struct SuperNintendoSkin: ConsoleSkin {

    /// Nostalgia vs the Retro Pal recolour. (Custom skins are not offered for this console yet,
    /// so `.custom` falls back to Nostalgia rather than rendering a palette from another one.)
    var variant: DressVariant = .nostalgia
    /// Card mode: the square share card. Reserved for the console share card; the in-game dress
    /// keeps it false.
    var cardMode: Bool = false
    /// A hardware controller is connected: the on-screen pad is hidden, so every decoration that
    /// anchors to a control is skipped and only the body + screen panel remain.
    var controllerConnected: Bool = false

    // MARK: Palette

    /// A custom skin's slots come first, then Retro Pal's, then Nostalgia's — the same order
    /// every other dress here reads them in.
    private var custom: SNESSkinPalette? { variant.snesPalette }
    private var bodyMid: UIColor {
        custom?.body ?? (variant == .retroPal ? RetroPalPalette.snesBody : DressKind.snesBody) }
    private var bodyTop: UIColor { RetroPalPalette.bodyGradient(bodyMid).top }
    private var bodyBottom: UIColor { RetroPalPalette.bodyGradient(bodyMid).bottom }
    /// The screen panel: the Game Boy's #6D6D6D, per the spec ("the same surround as GB/GBC").
    private var surround: UIColor {
        custom?.surround ?? (variant == .retroPal ? RetroPalPalette.snesSurround : DressKind.snesSurround) }
    /// The near-black the D-pad and the SELECT/START pills wear — used here for the shapes drawn
    /// UNDER them, so a pressed (shrinking) button reveals the same colour rather than the body.
    private var dark: UIColor { custom?.pad ?? DressKind.snesDark }
    /// The printed SELECT / START words: the body colour, moved away from itself far enough to
    /// read on it. Away, not down: Retro Pal's shell is the GBA's near-black, where "darker"
    /// prints an invisible word.
    private var printedLabel: UIColor {
        bodyMid.rpIsLight ? bodyMid.rpMixed(with: .black, 0.34)
                          : bodyMid.rpMixed(with: .white, 0.45) }
    /// The recessed seats, a touch darker than the body so a well reads as sunk rather than as
    /// a rim on flat plastic — the same relationship the Game Boy and the GBA dresses use, at
    /// the GBA's 15%. Under Retro Pal it IS the GBA's, which is lighter than that shell rather
    /// than darker, for the same reason the printed word inverts.
    private var creuse: UIColor {
        if custom != nil { return bodyMid.rpMixed(with: .black, 0.15) }
        return variant == .retroPal ? RetroPalPalette.snesCreuse : bodyMid.rpMixed(with: .black, 0.15) }

    /// How far the pad's dish clears the cross's arm tips, in reference points. The arms reach
    /// the hitbox edge, so this is the visible ring around them: was 5, doubled on 2026-08-17
    /// so the dish reads as a dish rather than as a rim.
    ///
    /// 12 is the ceiling and it is not a taste limit. In portrait the pad's own leading margin
    /// is 12pt, and the dish is centred on the pad, so at 12 the dish is exactly flush with the
    /// device edge and past it it runs off the page. 10 leaves 2pt of body showing.
    private static let padDishClearance: CGFloat = 10
    /// SELECT/START pill thickness as a fraction of the hitbox short side. Must match
    /// `SmallButton.pillThicknessRatio` so the carved seat lines up with the button.
    private static let pillThicknessRatio: CGFloat = 0.24
    /// The ring of surround colour wanted around the four face buttons, in reference points.
    /// Wanted rather than guaranteed: the circle gives it up before it will touch a neighbour.
    private static let clusterRing: CGFloat = 10
    /// Half-thickness added to each of the two capsules beyond a face button's own radius. Must
    /// stay above the 4pt seat `drawButtonWells` carves, so the seat lands inside the capsule.
    private static let capsulePad: CGFloat = 6
    /// How far the screen panel skirts below the picture in portrait, before the controller's
    /// shell begins. The L · MENU · R strip starts 36pt into the controls container, so this is
    /// what keeps the shoulders on the pad rather than in the screen's surround.
    private static let panelSkirt: CGFloat = 18

    /// The Retro Pal brand mark, tinted to read as printed into this body.
    private static let brandIcon: UIImage? = RetroPalPalette.brandIcon(tinted: DressKind.snesDark)
    private var brandColor: UIColor { printedLabel }
    /// A custom body can be any colour, so the mark is re-tinted for it rather than served from
    /// the Nostalgia-tinted cache (same treatment the other dresses give a custom body).
    private var brandImage: UIImage? {
        custom != nil || variant == .retroPal
            ? RetroPalPalette.brandIcon(tinted: printedLabel) : Self.brandIcon }

    // MARK: Draw

    func draw(in ctx: CGContext, bounds: CGRect, screenFrame screen: CGRect,
              buttons: [ControlElement: CGRect], isLandscape: Bool, usesJoystick: Bool, scale: CGFloat) {
        drawBody(ctx, bounds)
        guard !screen.isEmpty else { return }
        // The cluster goes under the wells: its circle and capsules are the ground the four
        // face buttons are then seated into.
        drawFaceCluster(buttons: buttons, bounds: bounds, screen: screen, scale: scale)
        drawButtonWells(buttons: buttons, isLandscape: isLandscape, usesJoystick: usesJoystick,
                        scale: scale)
        drawShoulderSeats(buttons: buttons, scale: scale)
        let panel = drawScreenPanel(ctx, bounds: bounds, screen: screen, buttons: buttons,
                                    isLandscape: isLandscape, scale: scale)
        drawSelectStartLabels(buttons: buttons, isLandscape: isLandscape, scale: scale)
        drawBrand(bounds: bounds, buttons: buttons, panel: panel, screen: screen,
                  isLandscape: isLandscape, scale: scale)
    }

    // MARK: Body

    /// Vertical gradient + corner vignette + the shared plastic grain, at the DS's half strength:
    /// the Super Nintendo's shell is smooth, not the Game Boy's coarse matte.
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
        ctx.saveGState(); ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: bounds)
        ctx.restoreGState()
    }

    // MARK: The face cluster

    /// The four face buttons as one piece of the pad rather than four loose discs: a recessed
    /// circle in the SCREEN'S SURROUND COLOUR holding all four, and two raised capsules in the
    /// body colour lying across it, one over B and A, one over X and Y.
    ///
    /// That pairing is the hardware's. On the real pad the cluster is a round recess crossed by
    /// two parallel diagonal plateaus, each carrying two buttons, and in this layout's diamond
    /// (X top, Y left, A right, B bottom) the two diagonal pairs are exactly {B, A} and {X, Y}.
    /// So the capsules follow the segment between each pair's centres and inherit their angle,
    /// which is why nothing here is hard-coded to 45 degrees: in landscape the four sit in the
    /// DS's staggered arrangement instead and the capsules follow that too.
    ///
    /// The capsules are drawn LAST so they read as lying ON the circle.
    ///
    /// The circle's radius is the tight one plus `clusterRing`, and the ring is what it gives up
    /// when there is no room: it is clamped so it never reaches the page edge, the picture, or
    /// any control that is not a face button. On an iPhone SE in portrait the clamp binds, on
    /// CLIP, and the ring closes to nearly nothing with the capsules touching its edge. If even
    /// the BUTTONS will not fit, nothing is drawn at all, since a circle cutting through the
    /// buttons it exists to hold is worse than no circle.
    private func drawFaceCluster(buttons: [ControlElement: CGRect], bounds: CGRect,
                                 screen: CGRect, scale: CGFloat) {
        // X/Y first, B/A second: the later capsule lies on the earlier one where they cross,
        // and A and B are the pair a thumb rests on.
        let pairs: [(ControlElement, ControlElement)] = [(.btnX, .btnY), (.btnB, .btnA)]
        let faces = [ControlElement.btnA, .btnB, .btnX, .btnY].compactMap { buttons[$0] }
        guard faces.count == 4 else { return }
        let c = CGPoint(x: faces.map(\.midX).reduce(0, +) / 4,
                        y: faces.map(\.midY).reduce(0, +) / 4)

        // Two radii, because the circle has two different jobs. It must HOLD the buttons, and it
        // wants to hold the capsules too: a capsule reaches its pair's far centre plus its own
        // half-thickness, which is a face radius plus `capsulePad`. When the page is tight the
        // capsules are what gives, reaching the ring's edge the way the real pad's plateaus do,
        // and only the buttons' radius is treated as a floor.
        var tightButtons: CGFloat = 0
        var tight: CGFloat = 0
        for f in faces {
            let d = hypot(f.midX - c.x, f.midY - c.y) + min(f.width, f.height) / 2
            tightButtons = max(tightButtons, d)
            tight = max(tight, d + Self.capsulePad * scale)
        }

        /// Distance from the cluster's centre to a rectangle (0 if the centre is inside it).
        func gap(to r: CGRect) -> CGFloat {
            let dx = max(r.minX - c.x, 0, c.x - r.maxX)
            let dy = max(r.minY - c.y, 0, c.y - r.maxY)
            return hypot(dx, dy)
        }
        var allowed = min(c.x - bounds.minX, bounds.maxX - c.x,
                          c.y - bounds.minY, bounds.maxY - c.y) - 2 * scale
        allowed = min(allowed, gap(to: screen.insetBy(dx: -8 * scale, dy: -8 * scale)))
        for e in [ControlElement.dpad, .btnMenu, .btnClip, .btnSelect, .btnStart, .btnL, .btnR] {
            guard let f = buttons[e] else { continue }
            // The pad is measured by its DISH, not by its hitbox: the dish is the drawn thing
            // the circle could visibly collide with, and it is the wider of the two.
            let margin = (e == .dpad ? Self.padDishClearance + 2 : 4) * scale
            allowed = min(allowed, gap(to: f.insetBy(dx: -margin, dy: -margin)))
        }
        let r = min(tight + Self.clusterRing * scale, allowed)
        guard r > tightButtons else { return }

        drawRecessedCircle(center: c, radius: r, fill: surround, scale: scale)

        for (first, second) in pairs {
            guard let f = buttons[first], let s = buttons[second] else { continue }
            let t = max(min(f.width, f.height), min(s.width, s.height)) + 2 * Self.capsulePad * scale
            let line = CGMutablePath()
            line.move(to: CGPoint(x: f.midX, y: f.midY))
            line.addLine(to: CGPoint(x: s.midX, y: s.midY))
            let capsule = UIBezierPath(cgPath: line.copy(strokingWithWidth: t, lineCap: .round,
                                                         lineJoin: .round, miterLimit: 0))
            drawRaised(capsule, fill: bodyMid, scale: scale)
        }
    }

    // MARK: Wells

    /// A carved seat under every control: the round dish the cross sits in, a circle under each
    /// face button, the diagonal slit under SELECT/START, and a circle under MENU and CLIP.
    private func drawButtonWells(buttons: [ControlElement: CGRect], isLandscape: Bool,
                                 usesJoystick: Bool, scale: CGFloat) {
        if let d = buttons[.dpad] {
            // The dish reads as the seat the whole cross sits in, so it has to clear the arm
            // tips by enough to be seen as a ring rather than as a rim (2026-08-17): the
            // arms reach the hitbox edge, so the radius is measured from there.
            let r = max(d.width, d.height) / 2 + Self.padDishClearance * scale
            drawRecessedCircle(center: CGPoint(x: d.midX, y: d.midY), radius: r,
                               fill: creuse, scale: scale)
            // The cross's own dark shape, a hair bigger, so a tilted press reveals it — the
            // joystick's round dish covers it, so it is drawn for the cross only.
            if !usesJoystick {
                dark.setFill()
                crossPath(in: d.insetBy(dx: -1 * scale, dy: -1 * scale),
                          armRatio: 0.336, cornerRadius: 6 * scale).fill()
            }
        }
        for e in [ControlElement.btnA, .btnB, .btnX, .btnY, .btnMenu, .btnClip] {
            guard let f = buttons[e] else { continue }
            let r = min(f.width, f.height) / 2 + 4 * scale
            drawRecessedCircle(center: CGPoint(x: f.midX, y: f.midY), radius: r, scale: scale)
        }
        for e in [ControlElement.btnA, .btnB, .btnX, .btnY, .btnMenu, .btnClip] {
            guard let f = buttons[e] else { continue }
            let r = min(f.width, f.height) / 2 + 1 * scale
            dark.setFill()
            UIBezierPath(ovalIn: CGRect(x: f.midX - r, y: f.midY - r, width: 2 * r, height: 2 * r)).fill()
        }
        for e in [ControlElement.btnSelect, .btnStart] {
            guard let f = buttons[e] else { continue }
            let pillT = min(f.width, f.height) * Self.pillThicknessRatio
            // The seat comes from the same endpoints the button's own pill is built from, so a
            // change to one is a change to both. The SNES pair draw at half length; the hitbox,
            // the diagonal and the printed word beside them are unchanged.
            let (p1, p2) = DressKind.pillEndpoints(in: f, thickness: pillT, isLandscape: isLandscape,
                                                   lengthRatio: DressKind.snes.pillLengthRatio)
            drawRecessedSlit(from: p1, to: p2, thickness: pillT + 4 * scale, scale: scale)
        }
    }

    /// A carved seat around each shoulder, capsule-matched — the ring only, no dark under-shape,
    /// because the shoulders wear the body colour and a dark ring would read as a gap.
    private func drawShoulderSeats(buttons: [ControlElement: CGRect], scale: CGFloat) {
        for e in [ControlElement.btnL, .btnR] {
            guard let f = buttons[e] else { continue }
            drawRecessedCapsule(f.insetBy(dx: -4 * scale, dy: -4 * scale), fill: bodyMid, scale: scale)
        }
    }

    // MARK: Screen panel

    /// The dark inlaid panel around the game screen — the Game Boy's treatment and its #6D6D6D,
    /// per the spec, on the Game Boy Advance's geometry (which is the layout this console wears).
    ///
    /// PORTRAIT: full width, and SYMMETRIC about the picture — the same skirt above it as below
    /// it, so the panel reads as a frame around the game rather than as the top of the device.
    /// It used to run from the very top of the screen down past the L · MENU · R strip, which
    /// put the status bar on the panel and seated the shoulders inside the screen's surround,
    /// making them read as television rather than as pad. Both ends are the same number now,
    /// and that is the whole rule.
    /// LANDSCAPE: grown from the screen with side margins, enveloping the SELECT · MENU · START
    /// row, clear of the device edges. Untouched by the above: that page already reads as a
    /// picture with a gutter of controller each side.
    @discardableResult
    private func drawScreenPanel(_ ctx: CGContext, bounds: CGRect, screen: CGRect,
                                 buttons: [ControlElement: CGRect], isLandscape: Bool,
                                 scale: CGFloat) -> CGRect {
        let sidePad = 8 * scale
        let botMargin = 10 * scale
        var bottom = screen.maxY + Self.panelSkirt * scale
        if isLandscape {
            let ys = [buttons[.btnSelect], buttons[.btnMenu], buttons[.btnStart]].compactMap { $0?.maxY }
            if let m = ys.max() { bottom = m + botMargin }
        }
        var rect: CGRect
        if cardMode {
            rect = screen.insetBy(dx: -18 * scale, dy: -18 * scale)
        } else if isLandscape {
            rect = CGRect(x: screen.minX - sidePad, y: screen.minY - 12 * scale,
                          width: screen.width + 2 * sidePad, height: bottom - (screen.minY - 12 * scale))
            rect = rect.intersection(bounds.insetBy(dx: 4 * scale, dy: 4 * scale))
        } else {
            let top = screen.minY - Self.panelSkirt * scale
            rect = CGRect(x: bounds.minX, y: top, width: bounds.width, height: bottom - top)
        }
        guard rect.width > 8, rect.height > 8 else { return .zero }

        // ONE radius on all four corners (2026-08-17). The Game Boy's panel carries an
        // oversized bottom-right curve, which is that console's own asymmetry; this one is a
        // television bezel and reads as a mistake unless its corners match. In portrait only
        // the two bottom corners are on the page at all, and they now mirror each other.
        let small = 8 * scale
        let panel = roundedPath(rect, tl: small, tr: small, br: small, bl: small)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5 * scale), blur: 5 * scale,
                      color: UIColor.black.withAlphaComponent(0.35).cgColor)
        surround.setFill(); panel.fill()
        ctx.restoreGState()
        let outer = roundedPath(rect.insetBy(dx: -2 * scale, dy: -2 * scale),
                                tl: small + 2 * scale, tr: small + 2 * scale,
                                br: small + 2 * scale, bl: small + 2 * scale)
        drawRecessRelief(panel, outer: outer, scale: scale)
        let lcd = roundedPath(screen.insetBy(dx: -1.5 * scale, dy: -1.5 * scale),
                              tl: 3 * scale, tr: 3 * scale, br: 3 * scale, bl: 3 * scale)
        UIColor.black.withAlphaComponent(0.45).setStroke()
        lcd.lineWidth = 1.5 * scale
        lcd.stroke()
        // Portrait only: the controller's own top edge, catching light just under the panel.
        // The panel's drop shadow already darkens the body below it; this is the lit lip on the
        // other side of that shadow, and the two together are what make the seam read as one
        // piece of plastic beginning where another ends.
        if !isLandscape && !cardMode {
            let y = rect.maxY + 2.5 * scale
            let lip = UIBezierPath()
            lip.move(to: CGPoint(x: bounds.minX, y: y))
            lip.addLine(to: CGPoint(x: bounds.maxX, y: y))
            UIColor.white.withAlphaComponent(0.35).setStroke()
            lip.lineWidth = 1 * scale
            lip.stroke()
        }
        return rect
    }

    // MARK: Printed labels

    /// SELECT and START printed on the case beside their pill — rotated to the diagonal in
    /// portrait, horizontal in landscape, in the body colour darkened so it reads.
    private func drawSelectStartLabels(buttons: [ControlElement: CGRect], isLandscape: Bool,
                                       scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for (e, text) in [(ControlElement.btnSelect, "SELECT"), (.btnStart, "START")] {
            guard let f = buttons[e] else { continue }
            let kern = 0.5 * scale
            if isLandscape {
                var size = 10 * scale
                var sz = measure(text, size: size, kern: kern)
                if sz.width > 0 { size *= (f.width * 0.7) / sz.width; sz = measure(text, size: size, kern: kern) }
                NSAttributedString(string: text, attributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: printedLabel, .kern: kern,
                ]).draw(at: CGPoint(x: f.midX - sz.width / 2,
                                    y: f.minY + f.height * 2 / 3 - sz.height / 2))
                continue
            }
            let dx = f.width, dy = -f.height
            let len = max(1, hypot(dx, dy))
            let angle = atan2(dy, dx)
            var size = 10 * scale
            var sz = measure(text, size: size, kern: kern)
            if sz.width > 0 { size *= (len * 0.7) / sz.width; sz = measure(text, size: size, kern: kern) }
            let nx = -dy / len, ny = dx / len
            let pillT = min(f.width, f.height) * Self.pillThicknessRatio
            let off = pillT / 2 + 2 * scale + sz.height / 2
            let center = CGPoint(x: f.midX + nx * off, y: f.midY + ny * off)
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: angle)
            NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: printedLabel, .kern: kern,
            ]).draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2))
            ctx.restoreGState()
        }
    }

    // MARK: Brand

    /// The Retro Pal mark, in whatever space the controller has left.
    ///
    /// PORTRAIT: the band across the bottom of the shell, under the SELECT/START row, centred on
    /// the D-pad's column. It inherited the Game Boy Advance's spot, level with CLIP and left of
    /// MENU, and that spot stopped existing when CLIP moved down into the bottom row: measured
    /// on a 14 Pro the plaque overlapped the SELECT pill by about 14pt. Sitting on the D-pad's
    /// column rather than the page's centre also keeps it out of the home indicator's path.
    /// LANDSCAPE: the left gutter, centred between the D-pad's bottom and the device's.
    /// CARD: above the picture, horizontally centred, at 1.5x — the GBA card's spot and the GBA
    /// card's size, deliberately, so the two cards read as one family. The card has no MENU and
    /// no CLIP (Menu is parked off it, Clip hidden), which is why the in-game anchors below
    /// cannot serve here and why this console's card carried no brand at all until now.
    private func drawBrand(bounds: CGRect, buttons: [ControlElement: CGRect], panel: CGRect,
                           screen: CGRect, isLandscape: Bool, scale: CGFloat) {
        guard !controllerConnected else { return }
        let txt = measure("PHONES", size: 9.5 * scale, kern: 0.5 * scale)
        let iconH = 14 * scale
        let icon = UIImage(systemName: "headphones")
        let aspect: CGFloat = icon.map { $0.size.width / max(1, $0.size.height) } ?? 1
        var w = (iconH * aspect + 5 * scale + txt.width + 36 * scale) * 1.125
        var h = (max(iconH, txt.height) + 14 * scale) * 1.125
        let rect: CGRect
        if cardMode {
            w *= 1.5; h *= 1.5
            let cy = max(h / 2 + 8 * scale, (bounds.minY + screen.minY) / 2)
            rect = CGRect(x: bounds.midX - w / 2, y: cy - h / 2, width: w, height: h)
        } else if isLandscape {
            // ABOVE the pad rather than below it, and 25% larger: the band over the pad is the
            // emptiest part of this page, and the band under it is where a thumb rests.
            //
            // On the PAD'S COLUMN, centre to centre, and centred in the band between the shoulder
            // row and the top of the pad's up arm. Both were the gutter's own centre lines before,
            // which put the plaque high and left of the pad and made it read as a stray label
            // rather than as the machine's badge; and the band it now takes is the one CLIP
            // vacated when it crossed to the right gutter.
            guard let d = buttons[.dpad] else { return }
            w *= 1.25; h *= 1.25
            let gutter = panel.minX - bounds.minX
            guard gutter > 24 * scale else { return }
            if w > gutter - 12 * scale { let f = (gutter - 12 * scale) / w; w *= f; h *= f }
            // Both shoulders, and the lower edge of the two, exactly as the layout reads it for
            // CLIP (`DressKind.snesLandscapeUtilityCenterY` is the shared line).
            let shoulderBottom = [buttons[.btnL], buttons[.btnR]]
                .compactMap { $0?.maxY }.max() ?? bounds.minY
            let availH = d.minY - shoulderBottom
            guard availH > h + 8 * scale else { return }
            let cy = DressKind.snesLandscapeUtilityCenterY(shoulderBottom: shoulderBottom,
                                                           padTop: d.minY)
            // Centred on the pad, then held inside the gutter. The clamp only engages where the
            // plaque would otherwise cross the picture's panel or the device edge, so on the
            // devices where the pad's column has the room the alignment is exact.
            let x = min(max(bounds.minX + 12 * scale, d.midX - w / 2),
                        panel.minX - 12 * scale - w)
            rect = CGRect(x: x, y: cy - h / 2, width: w, height: h)
        } else {
            let rowBottom = [buttons[.btnSelect], buttons[.btnStart], buttons[.btnClip]]
                .compactMap { $0?.maxY }.max() ?? bounds.midY
            let availH = bounds.maxY - rowBottom
            guard availH > h + 8 * scale else { return }
            let avail = bounds.width - 24 * scale
            if w > avail { let f = avail / w; w *= f; h *= f }
            let wanted = (buttons[.dpad]?.midX ?? bounds.midX) - w / 2
            let x = min(max(bounds.minX + 12 * scale, wanted), bounds.maxX - 12 * scale - w)
            rect = CGRect(x: x, y: (rowBottom + bounds.maxY) / 2 - h / 2, width: w, height: h)
        }
        drawBranding(in: rect, scale: scale)
    }

    private func drawBranding(in rect: CGRect, scale: CGFloat) {
        guard rect.width > 24 * scale, rect.height > 12 * scale else { return }
        drawRecessedCapsule(rect, fill: bodyMid, scale: scale)
        let inset = rect.insetBy(dx: rect.height * 0.34, dy: rect.height * 0.20)
        guard inset.width > 4, inset.height > 4 else { return }
        let iconSide = inset.height
        let gap = iconSide * 0.22
        if let icon = brandImage {
            icon.draw(in: aspectFit(icon.size, in: CGRect(x: inset.minX, y: inset.minY,
                                                          width: iconSide, height: iconSide)))
        }
        let textX = inset.minX + iconSide + gap
        let textRect = CGRect(x: textX, y: inset.minY, width: inset.maxX - textX, height: inset.height)
        guard textRect.width > 8 else { return }
        let kern = 0.5 * scale
        var fontSize = textRect.height * 0.95
        var sz = measure("Retro Pal", size: fontSize, kern: kern)
        if sz.width > textRect.width, sz.width > 0 {
            fontSize *= textRect.width / sz.width
            sz = measure("Retro Pal", size: fontSize, kern: kern)
        }
        drawEmbossedText("Retro Pal", at: CGPoint(x: textRect.minX, y: textRect.midY - sz.height / 2),
                         size: fontSize, color: brandColor, kern: kern, scale: scale)
    }

    // MARK: Relief primitives

    /// A RAISED shape: filled, grained, with a drop shadow under it, a light catch inside its top
    /// rim and a dark one inside its bottom rim. The inverse of `drawRecessRelief`, and what
    /// makes the two face capsules read as plateaus standing in the cluster's recess.
    private func drawRaised(_ path: UIBezierPath, fill: UIColor, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.6 * scale), blur: 3.4 * scale,
                      color: UIColor.black.withAlphaComponent(0.30).cgColor)
        fill.setFill(); path.fill()
        ctx.restoreGState()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: path.bounds)
        ctx.restoreGState()
        let outer = UIBezierPath(cgPath: path.cgPath)
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.4 * scale), blur: 1.8 * scale,
                      color: UIColor.white.withAlphaComponent(0.55).cgColor)
        UIColor.white.setStroke(); outer.lineWidth = 1.5 * scale; outer.stroke()
        ctx.restoreGState()
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.4 * scale), blur: 2.0 * scale,
                      color: UIColor.black.withAlphaComponent(0.35).cgColor)
        UIColor.black.setStroke(); outer.lineWidth = 1.5 * scale; outer.stroke()
        ctx.restoreGState()
    }

    private func drawRecessedCircle(center c: CGPoint, radius r: CGFloat,
                                    fill: UIColor? = nil, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        let path = UIBezierPath(ovalIn: rect)
        (fill ?? bodyMid).setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: rect); ctx.restoreGState()
        drawRecessRelief(path, outer: UIBezierPath(ovalIn: rect.insetBy(dx: -2 * scale, dy: -2 * scale)),
                         scale: scale)
    }

    private func drawRecessedCapsule(_ rect: CGRect, fill: UIColor, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius = min(rect.width, rect.height) / 2
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        fill.setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: rect); ctx.restoreGState()
        let outer = UIBezierPath(roundedRect: rect.insetBy(dx: -2 * scale, dy: -2 * scale),
                                 cornerRadius: radius + 2 * scale)
        drawRecessRelief(path, outer: outer, scale: scale)
    }

    /// A recessed capsule along an arbitrary segment (the diagonal SELECT/START seats).
    private func drawRecessedSlit(from p1: CGPoint, to p2: CGPoint, thickness t: CGFloat,
                                  scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let line = CGMutablePath(); line.move(to: p1); line.addLine(to: p2)
        let path = UIBezierPath(cgPath: line.copy(strokingWithWidth: t, lineCap: .round,
                                                  lineJoin: .round, miterLimit: 0))
        bodyMid.setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: path.bounds); ctx.restoreGState()
        let outer = UIBezierPath(cgPath: line.copy(strokingWithWidth: t + 4 * scale, lineCap: .round,
                                                   lineJoin: .round, miterLimit: 0))
        drawRecessRelief(path, outer: outer, scale: scale)
    }

    private func drawRecessRelief(_ path: UIBezierPath, outer: UIBezierPath, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.8 * scale), blur: 2.6 * scale,
                      color: UIColor.black.withAlphaComponent(0.45).cgColor)
        UIColor.black.setStroke(); outer.lineWidth = 2 * scale; outer.stroke()
        ctx.restoreGState()
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 1.6 * scale,
                      color: UIColor.white.withAlphaComponent(0.4).cgColor)
        UIColor.white.setStroke(); outer.lineWidth = 1.5 * scale; outer.stroke()
        ctx.restoreGState()
    }

    // MARK: Small helpers (ported, unchanged in behaviour)

    private func measure(_ s: String, size: CGFloat, kern: CGFloat) -> CGSize {
        NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold), .kern: kern,
        ]).size()
    }

    private func drawEmbossedText(_ s: String, at origin: CGPoint, size: CGFloat,
                                  color: UIColor, kern: CGFloat, scale: CGFloat) {
        let font = UIFont.systemFont(ofSize: size, weight: .semibold)
        NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.5), .kern: kern,
        ]).draw(at: CGPoint(x: origin.x - 0.6 * scale, y: origin.y - 0.6 * scale))
        NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: UIColor.black.withAlphaComponent(0.30), .kern: kern,
        ]).draw(at: CGPoint(x: origin.x + 0.6 * scale, y: origin.y + 0.6 * scale))
        NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .kern: kern,
        ]).draw(at: origin)
    }

    private func aspectFit(_ imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let s = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

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

    /// The rounded 12-point cross the dressed pad wears, so the dark shape under it lines up.
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

// MARK: - NES skin

/// The NES dress: the pad's light grey shell, a red band across it, two red round faces recessed
/// into their own dark panel, two black pills in a second one, a near-black cross in a round dish,
/// and the deep inlaid panel around the screen. Inspired-by: our own art, the era's colours, no
/// marks.
///
/// The palette is the `console-nes` imageset, the drawing this app already ships as the
/// Appearance button's icon, so the picture of the console and the console you hold cannot
/// describe the same machine differently. Body #D2D5DC, faces and band #D9412B, cross and pills
/// #262628, the wells #8A8F9C, screen panel #3A3550.
///
/// WHAT MAKES IT READ AS A NES RATHER THAN AS A SECOND SUPER NINTENDO, since the two share a body
/// family and a near-black pad: the two RECESSED WELLS. On this pad the buttons sit in sunken
/// panels rather than on a plateau, which is the opposite relief of the Super Nintendo's raised
/// capsules, and it is the first thing the eye picks up. The red band is the second, and the
/// screen panel's deeper, bluer surround is the third.
///
/// Same two-place portrait rule as the Super Nintendo: the panel is symmetric about the picture
/// and everything below it is the controller.
struct NintendoEntertainmentSystemSkin: ConsoleSkin {

    var variant: DressVariant = .nostalgia
    var cardMode: Bool = false
    var controllerConnected: Bool = false

    // MARK: Palette

    private var custom: NESSkinPalette? { variant.nesPalette }
    private var bodyMid: UIColor {
        custom?.body ?? (variant == .retroPal ? RetroPalPalette.nesBody : DressKind.nesBody) }
    private var bodyTop: UIColor { RetroPalPalette.bodyGradient(bodyMid).top }
    private var bodyBottom: UIColor { RetroPalPalette.bodyGradient(bodyMid).bottom }
    private var surround: UIColor {
        custom?.surround ?? (variant == .retroPal ? RetroPalPalette.nesSurround : DressKind.nesSurround) }
    /// The cross and the two pills (and the seats the face buttons sit on). Named for what it is
    /// on the Nostalgia dress; under Retro Pal it is the light control colour, which is the whole
    /// point of that recolour on this console.
    private var dark: UIColor {
        custom?.pad ?? (variant == .retroPal ? RetroPalPalette.nesFace : DressKind.snesDark) }
    /// The light grey the two wells, the A/B backing pill and the cross's outline share. Not a
    /// slot and not derived from the body: on this console the shell is near-black and the cross
    /// is near-black, so this tone is the only thing separating them. Deriving it from a custom
    /// body would let a skin lose that outline without ever choosing to.
    private var well: UIColor { DressKind.nesWell }
    /// The printed SELECT and START words: the face red, per the spec. It is the same colour as
    /// the buttons and the band, which is what makes the three read as one printed layer on a
    /// dark shell.
    private var printedLabel: UIColor { stripe }
    /// The brand plaque's own ink, which cannot be the red: it sits on a shell, not on a light
    /// panel, so it moves away from the body in whichever direction there is room.
    private var brandInk: UIColor {
        bodyMid.rpIsLight ? bodyMid.rpMixed(with: .black, 0.40)
                          : bodyMid.rpMixed(with: .white, 0.45) }
    private var creuse: UIColor {
        bodyMid.rpIsLight ? bodyMid.rpMixed(with: .black, 0.15)
                          : bodyMid.rpMixed(with: .white, 0.12) }

    /// The red band across the shell, the machine's own stripe. Follows the face colour, so a
    /// custom skin that repaints the buttons repaints the band with them.
    private var stripe: UIColor {
        custom?.face ?? (variant == .retroPal ? RetroPalPalette.nesFace : DressKind.nesFace) }

    /// The outline drawn around the cross (or the joystick), in reference points. This console
    /// has no dish behind its pad: the outline IS the separation.
    private static let padStrokeWidth: CGFloat = 4
    /// Half-thickness added around a button when its well is drawn.
    private static let wellPad: CGFloat = DressKind.nesWellPad
    /// SELECT/START pill thickness as a fraction of the hitbox short side (matches SmallButton).
    private static let pillThicknessRatio: CGFloat = 0.24
    /// The skirt above and below the picture. Symmetric, like the Super Nintendo's. Shared with
    /// the layout through `DressKind`, which places MENU and CLIP against the panel's lower edge.
    private static let panelSkirt: CGFloat = DressKind.nesPanelSkirt
    /// The red band's thickness and its gap below the screen panel.
    private static let stripeThickness: CGFloat = 6
    private static let stripeGap: CGFloat = 10

    private var brandImage: UIImage? { RetroPalPalette.brandIcon(tinted: brandInk) }

    // MARK: Draw

    func draw(in ctx: CGContext, bounds: CGRect, screenFrame screen: CGRect,
              buttons: [ControlElement: CGRect], isLandscape: Bool, usesJoystick: Bool, scale: CGFloat) {
        drawBody(ctx, bounds)
        guard !screen.isEmpty else { return }
        drawWells(buttons: buttons, isLandscape: isLandscape, scale: scale)
        drawButtonSeats(buttons: buttons, usesJoystick: usesJoystick, scale: scale)
        let panel = drawScreenPanel(ctx, bounds: bounds, screen: screen, buttons: buttons,
                                    isLandscape: isLandscape, scale: scale)
        drawStripe(ctx, bounds: bounds, panel: panel, buttons: buttons,
                   isLandscape: isLandscape, scale: scale)
        drawSelectStartLabels(buttons: buttons, isLandscape: isLandscape, scale: scale)
        drawBrand(bounds: bounds, buttons: buttons, panel: panel, screen: screen,
                  isLandscape: isLandscape, scale: scale)
    }

    // MARK: Body

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
        ctx.saveGState(); ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: bounds)
        ctx.restoreGState()
    }

    /// The red band. Portrait: full width, just under the screen panel, which is where the
    /// machine wears it. Landscape: skipped — the panel spans the middle of the page there and a
    /// band under it would cut the controls in half rather than decorate a shell.
    private func drawStripe(_ ctx: CGContext, bounds: CGRect, panel: CGRect,
                            buttons: [ControlElement: CGRect], isLandscape: Bool, scale: CGFloat) {
        guard !isLandscape, !cardMode, panel.height > 8 else { return }
        let y = panel.maxY + Self.stripeGap * scale
        let h = Self.stripeThickness * scale
        // Never let the band reach a control: it is decoration, and a control sitting on it would
        // read as a button that means something.
        let firstControlTop = [buttons[.btnMenu], buttons[.btnClip], buttons[.btnA], buttons[.btnB]]
            .compactMap { $0?.minY }.min() ?? bounds.maxY
        guard y + h + 6 * scale < firstControlTop else { return }
        let rect = CGRect(x: bounds.minX, y: y, width: bounds.width, height: h)
        stripe.setFill(); ctx.fill(rect)
        // A thin dark line under it, so the band reads as inlaid rather than painted on.
        UIColor.black.withAlphaComponent(0.18).setFill()
        ctx.fill(CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 1 * scale))
    }

    // MARK: Wells

    /// The two sunken panels: one holding A and B, one holding SELECT and START. This is the
    /// shape that says NES, and it is the inverse of the Super Nintendo's raised capsules.
    private func drawWells(buttons: [ControlElement: CGRect], isLandscape: Bool, scale: CGFloat) {
        if let a = buttons[.btnA], let b = buttons[.btnB] {
            // Thickness from `DressKind`, because the layout measures this same well's TOP edge
            // to place MENU and CLIP above it.
            let t = DressKind.nesFaceWellThickness(a: a, b: b, scale: scale)
            let line = CGMutablePath()
            line.move(to: CGPoint(x: b.midX, y: b.midY))
            line.addLine(to: CGPoint(x: a.midX, y: a.midY))
            let capsule = UIBezierPath(cgPath: line.copy(strokingWithWidth: t, lineCap: .round,
                                                         lineJoin: .round, miterLimit: 0))
            drawRecessed(capsule, fill: well, scale: scale)
        }
        guard let select = buttons[.btnSelect], let start = buttons[.btnStart] else { return }
        let pillT = min(select.width, select.height) * Self.pillThicknessRatio
        let pad = Self.wellPad * scale
        let union = select.union(start).insetBy(dx: -pad, dy: -pad)
        // One panel around the pair, at the pill's own corner radius plus the pad. Its OUTER
        // edge is the surround's light grey, per the spec: the carved look on this console comes
        // from a light rim around a light panel on a dark shell, not from a shadow.
        let path = UIBezierPath(roundedRect: union, cornerRadius: pillT / 2 + pad)
        drawRecessed(path, fill: well, scale: scale)
        surround.setStroke()
        let rim = UIBezierPath(roundedRect: union.insetBy(dx: -1.5 * scale, dy: -1.5 * scale),
                               cornerRadius: pillT / 2 + pad + 1.5 * scale)
        rim.lineWidth = 1.5 * scale
        rim.stroke()
    }

    /// A carved seat under the cross and under each of the other controls, so every button sits
    /// in something. The face buttons already have their well, so they take only their dark
    /// under-disc.
    private func drawButtonSeats(buttons: [ControlElement: CGRect], usesJoystick: Bool, scale: CGFloat) {
        if let d = buttons[.dpad] {
            // No dish. The cross wears an OUTLINE instead, which is what this pad has and what
            // it needs: near-black arms on a near-black shell would otherwise have no edge at
            // all. The joystick gets the same treatment as a circle, since it replaces the same
            // control and would have the same problem.
            let stroke = Self.padStrokeWidth * scale
            if usesJoystick {
                // Nothing covers this one: the dressed joystick hides its own base ring and
                // draws only a thumb, so a stroke centred on the hitbox's edge is all there is.
                let shape = UIBezierPath(ovalIn: d.insetBy(dx: stroke / 2, dy: stroke / 2))
                well.setStroke()
                shape.lineWidth = stroke
                shape.stroke()
            } else {
                // The cross VIEW fills this hitbox exactly, and it sits above the dress, so half
                // of any stroke centred on that same outline is covered by the cross itself.
                // Draw it at DOUBLE width and the half that survives is `stroke` all the way
                // round. Insetting the path instead (what this did first) moved the outline out
                // by the full inset at the arm tips but only a third of it along the arms, so
                // the pad looked like it had grown over its own edge, worst under Retro Pal
                // where the cross is light and the mismatch has nowhere to hide.
                //
                // Corner radius 6 UNSCALED, because that is the constant the cross view builds
                // its own path with: the two outlines have to be the same curve, not the same
                // formula. On the card there is no cross view on top, so the stroke stays
                // single-width and straddles the edge (same 4pt of light line, half each side).
                let shape = crossPath(in: d, armRatio: 0.336, cornerRadius: 6)
                dark.setFill()
                shape.fill()
                well.setStroke()
                shape.lineWidth = cardMode ? stroke : stroke * 2
                shape.stroke()
            }
        }
        for e in [ControlElement.btnMenu, .btnClip] {
            guard let f = buttons[e] else { continue }
            let r = min(f.width, f.height) / 2 + 4 * scale
            drawRecessedCircle(center: CGPoint(x: f.midX, y: f.midY), radius: r,
                               fill: creuse, scale: scale)
        }
        for e in [ControlElement.btnA, .btnB, .btnMenu, .btnClip] {
            guard let f = buttons[e] else { continue }
            let r = min(f.width, f.height) / 2 + 1 * scale
            dark.setFill()
            UIBezierPath(ovalIn: CGRect(x: f.midX - r, y: f.midY - r, width: 2 * r, height: 2 * r)).fill()
        }
    }

    // MARK: Screen panel

    /// The deep inlaid panel around the picture, in the cartridge flap's colour. Symmetric about
    /// the picture in portrait (the same skirt above and below), grown from it in landscape.
    @discardableResult
    private func drawScreenPanel(_ ctx: CGContext, bounds: CGRect, screen: CGRect,
                                 buttons: [ControlElement: CGRect], isLandscape: Bool,
                                 scale: CGFloat) -> CGRect {
        let sidePad = 8 * scale
        let botMargin = 10 * scale
        var bottom = screen.maxY + Self.panelSkirt * scale
        if isLandscape {
            let ys = [buttons[.btnSelect], buttons[.btnMenu], buttons[.btnStart]].compactMap { $0?.maxY }
            if let m = ys.max() { bottom = m + botMargin }
        }
        var rect: CGRect
        if cardMode {
            rect = screen.insetBy(dx: -18 * scale, dy: -18 * scale)
        } else if isLandscape {
            rect = CGRect(x: screen.minX - sidePad, y: screen.minY - 12 * scale,
                          width: screen.width + 2 * sidePad, height: bottom - (screen.minY - 12 * scale))
            rect = rect.intersection(bounds.insetBy(dx: 4 * scale, dy: 4 * scale))
        } else {
            let top = screen.minY - Self.panelSkirt * scale
            rect = CGRect(x: bounds.minX, y: top, width: bounds.width, height: bottom - top)
        }
        guard rect.width > 8, rect.height > 8 else { return .zero }

        let corner = 8 * scale
        let panel = UIBezierPath(roundedRect: rect, cornerRadius: corner)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5 * scale), blur: 5 * scale,
                      color: UIColor.black.withAlphaComponent(0.35).cgColor)
        surround.setFill(); panel.fill()
        ctx.restoreGState()
        let outer = UIBezierPath(roundedRect: rect.insetBy(dx: -2 * scale, dy: -2 * scale),
                                 cornerRadius: corner + 2 * scale)
        drawRecessRelief(panel, outer: outer, scale: scale)
        let lcd = UIBezierPath(roundedRect: screen.insetBy(dx: -1.5 * scale, dy: -1.5 * scale),
                               cornerRadius: 3 * scale)
        UIColor.black.withAlphaComponent(0.45).setStroke()
        lcd.lineWidth = 1.5 * scale
        lcd.stroke()
        if !isLandscape && !cardMode {
            let y = rect.maxY + 2.5 * scale
            let lip = UIBezierPath()
            lip.move(to: CGPoint(x: bounds.minX, y: y))
            lip.addLine(to: CGPoint(x: bounds.maxX, y: y))
            UIColor.white.withAlphaComponent(0.35).setStroke()
            lip.lineWidth = 1 * scale
            lip.stroke()
        }
        return rect
    }

    // MARK: Printed labels

    /// SELECT and START printed under their pills, horizontal in both orientations: this pad
    /// prints them straight, under a straight pair, unlike the Game Boy's diagonal.
    private func drawSelectStartLabels(buttons: [ControlElement: CGRect], isLandscape: Bool,
                                       scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for (e, text) in [(ControlElement.btnSelect, "SELECT"), (.btnStart, "START")] {
            guard let f = buttons[e] else { continue }
            let size = DressKind.nesPrintedSize * scale
            let kern = DressKind.nesPrintedKern * scale
            let sz = measure(text, size: size, kern: kern)
            // ABOVE the pill, not below it: this pad prints its words over the pair. Word, gap
            // and pill are ONE block and it is the block that centres in the well, so the pill's
            // own y comes from `pillCenterY` — the same call the button that draws it makes.
            let pillT = min(f.width, f.height) * Self.pillThicknessRatio
            let pillY = DressKind.nes.pillCenterY(in: f, scale: scale)
            let y = pillY - pillT / 2 - DressKind.nesPrintedGap * scale - sz.height / 2
            ctx.saveGState()
            NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: printedLabel, .kern: kern,
            ]).draw(at: CGPoint(x: f.midX - sz.width / 2, y: y - sz.height / 2))
            ctx.restoreGState()
        }
    }

    // MARK: Brand

    /// PORTRAIT: the band across the bottom of the shell, centred on the page. LANDSCAPE: the
    /// left gutter ABOVE the pad, on the pad's own column. CARD: above the picture, centred.
    ///
    /// Both non-card placements are centred on something the eye already uses as an axis (the
    /// page in portrait, the cross in landscape) rather than on the space that happened to be
    /// free, which is what the Super Nintendo's does and what this one did first.
    private func drawBrand(bounds: CGRect, buttons: [ControlElement: CGRect], panel: CGRect,
                           screen: CGRect, isLandscape: Bool, scale: CGFloat) {
        guard !controllerConnected else { return }
        let txt = measure("PHONES", size: 9.5 * scale, kern: 0.5 * scale)
        let iconH = 14 * scale
        let icon = UIImage(systemName: "headphones")
        let aspect: CGFloat = icon.map { $0.size.width / max(1, $0.size.height) } ?? 1
        var w = (iconH * aspect + 5 * scale + txt.width + 36 * scale) * 1.125
        var h = (max(iconH, txt.height) + 14 * scale) * 1.125
        let rect: CGRect
        if cardMode {
            w *= 1.5; h *= 1.5
            let cy = max(h / 2 + 8 * scale, (bounds.minY + screen.minY) / 2)
            rect = CGRect(x: bounds.midX - w / 2, y: cy - h / 2, width: w, height: h)
        } else if isLandscape {
            // Above the cross, on the cross's own centre line, in the band between the top of the
            // page and the top of the up arrow. That band is empty on this console (the picture
            // does not reach into the gutter) and it is where the machine's own name sits.
            guard let d = buttons[.dpad] else { return }
            let gutter = panel.minX - bounds.minX
            guard gutter > 24 * scale else { return }
            if w > gutter - 12 * scale { let f = (gutter - 12 * scale) / w; w *= f; h *= f }
            let availH = d.minY - bounds.minY
            guard availH > h + 8 * scale else { return }
            let x = min(max(bounds.minX + 6 * scale, d.midX - w / 2), panel.minX - 6 * scale - w)
            rect = CGRect(x: x, y: (bounds.minY + d.minY) / 2 - h / 2, width: w, height: h)
        } else {
            let rowBottom = [buttons[.btnSelect], buttons[.btnStart], buttons[.btnA]]
                .compactMap { $0?.maxY }.max() ?? bounds.midY
            let availH = bounds.maxY - rowBottom
            guard availH > h + 8 * scale else { return }
            let avail = bounds.width - 24 * scale
            if w > avail { let f = avail / w; w *= f; h *= f }
            rect = CGRect(x: bounds.midX - w / 2, y: (rowBottom + bounds.maxY) / 2 - h / 2,
                          width: w, height: h)
        }
        drawBranding(in: rect, scale: scale)
    }

    private func drawBranding(in rect: CGRect, scale: CGFloat) {
        guard rect.width > 24 * scale, rect.height > 12 * scale else { return }
        drawRecessedCapsule(rect, fill: creuse, scale: scale)
        let inset = rect.insetBy(dx: rect.height * 0.34, dy: rect.height * 0.20)
        guard inset.width > 4, inset.height > 4 else { return }
        let iconSide = inset.height
        let gap = iconSide * 0.22
        if let icon = brandImage {
            icon.draw(in: aspectFit(icon.size, in: CGRect(x: inset.minX, y: inset.minY,
                                                          width: iconSide, height: iconSide)))
        }
        let textX = inset.minX + iconSide + gap
        let textRect = CGRect(x: textX, y: inset.minY, width: inset.maxX - textX, height: inset.height)
        guard textRect.width > 8 else { return }
        let kern = 0.5 * scale
        var fontSize = textRect.height * 0.95
        var sz = measure("Retro Pal", size: fontSize, kern: kern)
        if sz.width > textRect.width, sz.width > 0 {
            fontSize *= textRect.width / sz.width
            sz = measure("Retro Pal", size: fontSize, kern: kern)
        }
        drawEmbossedText("Retro Pal", at: CGPoint(x: textRect.minX, y: textRect.midY - sz.height / 2),
                         size: fontSize, color: brandInk, kern: kern, scale: scale)
    }

    // MARK: Relief primitives (the Super Nintendo's, unchanged)

    private func drawRecessed(_ path: UIBezierPath, fill: UIColor, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        fill.setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: path.bounds); ctx.restoreGState()
        let outer = UIBezierPath(cgPath: path.cgPath)
        outer.lineWidth = 4 * scale
        drawRecessRelief(path, outer: outer, scale: scale)
    }

    private func drawRecessedCircle(center c: CGPoint, radius r: CGFloat,
                                    fill: UIColor, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        let path = UIBezierPath(ovalIn: rect)
        fill.setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: rect); ctx.restoreGState()
        drawRecessRelief(path, outer: UIBezierPath(ovalIn: rect.insetBy(dx: -2 * scale, dy: -2 * scale)),
                         scale: scale)
    }

    private func drawRecessedCapsule(_ rect: CGRect, fill: UIColor, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius = min(rect.width, rect.height) / 2
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        fill.setFill(); path.fill()
        ctx.saveGState(); path.addClip(); ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: rect); ctx.restoreGState()
        let outer = UIBezierPath(roundedRect: rect.insetBy(dx: -2 * scale, dy: -2 * scale),
                                 cornerRadius: radius + 2 * scale)
        drawRecessRelief(path, outer: outer, scale: scale)
    }

    private func drawRecessRelief(_ path: UIBezierPath, outer: UIBezierPath, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.8 * scale), blur: 2.6 * scale,
                      color: UIColor.black.withAlphaComponent(0.45).cgColor)
        UIColor.black.setStroke(); outer.lineWidth = 2 * scale; outer.stroke()
        ctx.restoreGState()
        ctx.saveGState(); path.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 1.6 * scale,
                      color: UIColor.white.withAlphaComponent(0.4).cgColor)
        UIColor.white.setStroke(); outer.lineWidth = 1.5 * scale; outer.stroke()
        ctx.restoreGState()
    }

    // MARK: Small helpers

    private func measure(_ s: String, size: CGFloat, kern: CGFloat) -> CGSize {
        NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold), .kern: kern,
        ]).size()
    }

    private func drawEmbossedText(_ s: String, at origin: CGPoint, size: CGFloat,
                                  color: UIColor, kern: CGFloat, scale: CGFloat) {
        let font = UIFont.systemFont(ofSize: size, weight: .semibold)
        NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.5), .kern: kern,
        ]).draw(at: CGPoint(x: origin.x - 0.6 * scale, y: origin.y - 0.6 * scale))
        NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: UIColor.black.withAlphaComponent(0.30), .kern: kern,
        ]).draw(at: CGPoint(x: origin.x + 0.6 * scale, y: origin.y + 0.6 * scale))
        NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .kern: kern,
        ]).draw(at: origin)
    }

    private func aspectFit(_ imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let s = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// The rounded 12-point cross the dressed pad wears, so the dark shape under it lines up.
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

// MARK: - PlayStation

/// The PlayStation dress.
///
/// ONE DARK TONE DOES EVERY CONTROL, and that is this console's colour logic
/// rather than a simplification. A Super Nintendo colours its four face
/// buttons; a PlayStation leaves all four the same plastic as the cross, the
/// shoulders, the sticks and the two little buttons in the middle, and prints a
/// pale symbol on each. So there is one `control` colour here where the Super
/// Nintendo's dress needs five, and the four inks are label colours.
///
/// THE SKIN OWNS MORE OF THIS PAD THAN OF THE OTHERS. Every engraved label is
/// drawn here rather than by its button: L1, L2, R1, R2 and ANALOG carry their
/// name INSIDE the plate, SELECT and START carry theirs BELOW, and the two
/// stick clicks carry theirs on a plate that is the body's own colour. Those
/// are three different relationships between a button and its word, and a
/// button view that had to know which one it was in would be a worse place for
/// that knowledge than the dress that decides it.
struct PlayStationSkin: ConsoleSkin {

    var variant: DressVariant = .nostalgia
    var cardMode: Bool = false
    var controllerConnected: Bool = false

    // MARK: Palette

    private var custom: PS1SkinPalette? { variant.ps1Palette }
    private var bodyMid: UIColor {
        custom?.body ?? (variant == .retroPal ? RetroPalPalette.ps1Body : DressKind.ps1Body) }
    private var bodyTop: UIColor { RetroPalPalette.bodyGradient(bodyMid).top }
    private var bodyBottom: UIColor { RetroPalPalette.bodyGradient(bodyMid).bottom }
    private var surround: UIColor {
        custom?.surround ?? (variant == .retroPal ? RetroPalPalette.ps1Surround : DressKind.ps1Surround) }
    /// The one control colour: cross arrows, stick dishes, face plastic, all
    /// four shoulders, ANALOG, SELECT, START, and the MENU / CLIP seats.
    private var control: UIColor {
        custom?.pad ?? (variant == .retroPal ? RetroPalPalette.ps1Face : DressKind.ps1Dark) }


    /// An engraved word, always DARKER than the plate it is cut into. Darker and
    /// not lighter because that is what carving does to a surface: the letter is
    /// a hole, and a hole in plastic is in shadow. It works on both dresses
    /// without a special case, since both plates are mid-tones.
    private func engraved(on plate: UIColor) -> UIColor {
        plate.rpMixed(with: .black, plate.rpIsLight ? 0.42 : 0.34)
    }

    private var brandInk: UIColor {
        bodyMid.rpIsLight ? bodyMid.rpMixed(with: .black, 0.34)
                          : bodyMid.rpMixed(with: .white, 0.40) }
    private var brandImage: UIImage? { RetroPalPalette.brandIcon(tinted: brandInk) }

    // MARK: Draw

    func draw(in ctx: CGContext, bounds: CGRect, screenFrame screen: CGRect,
              buttons: [ControlElement: CGRect], isLandscape: Bool, usesJoystick: Bool, scale: CGFloat) {
        drawBody(ctx, bounds)
        guard !screen.isEmpty else { return }
        // BEFORE the panel, not after. In landscape the diamond's plateau reaches
        // under the picture's frame, and drawn afterwards it printed a grey disc
        // ON the screen surround. Under it, the surround simply covers what it
        // overlaps, which is what a raised area behind a screen does.
        drawRaisedGround(buttons: buttons, isLandscape: isLandscape, scale: scale)
        drawScreenPanel(ctx, bounds: bounds, screen: screen, isLandscape: isLandscape, scale: scale)
        // EVERY CONTROL DRAWS ITSELF on this console, so the skin draws none of
        // them. It draws what a button cannot: the shell, the panel around the
        // picture, and the seat each face button sits in.
        drawSetControls(buttons: buttons, scale: scale)
        drawPadWedges(buttons: buttons, scale: scale)
        drawFaceSeats(buttons: buttons, scale: scale)
        drawBrand(bounds: bounds, screen: screen, buttons: buttons,
                  isLandscape: isLandscape, scale: scale)
    }

    /// The two round plateaus, one under the cross and one under the diamond.
    ///
    /// A shade lighter than the shell, which is what they are on the hardware and
    /// one of the very few marks on this pad that is neither a control nor a
    /// printed word. They are what tells a thumb it has arrived without looking.
    ///
    /// Sized from the CONTROLS' own frames rather than from a constant, so a
    /// custom preset that moves or resizes either cluster keeps its plateau under
    /// it. Circumscribed plus a lip: the cross's arm tips and the diamond's four
    /// outer edges then sit just inside the rim rather than crossing it.


    /// EVERYTHING ON THIS PAD THAT STANDS PROUD, as ONE shape.
    ///
    /// Four raised circles: a plateau under the cross, one under the diamond,
    /// and a boss under each stick. They overlap, and drawn one after another
    /// each carried its own rim, so the seams showed exactly where two raised
    /// areas met — which is the one place a moulded shell has no line at all.
    /// Unioned first and lit once, the four read as a single piece of plastic
    /// with four swellings in it, and there is no demarcation left to see.
    ///
    /// RAISED, not carved. Every other thing here is set INTO the shell (nine
    /// wells, two holes) and these are the parts of a DualShock that are not.
    private func drawRaisedGround(buttons: [ControlElement: CGRect], isLandscape: Bool,
                                  scale: CGFloat) {
        let lip = 6 * scale
        let faceRects = [ControlElement.btnA, .btnB, .btnX, .btnY].compactMap { buttons[$0] }
        var blocRect: CGRect?
        if var union = faceRects.first {
            for f in faceRects.dropFirst() { union = union.union(f) }
            blocRect = union
        }
        // A FIXED PROPORTION OF THE CLUSTER, on every page and every device.
        //
        // It was sized from the DISTANCE BETWEEN the two clusters in portrait, so
        // that they met in the middle by a set amount. That rule is wrong twice
        // over. It is not scale-invariant: on a 14 Pro it works out to 1.37 of
        // the cross, which is the proportion that looks right, but on an SE the
        // clusters are nearly as far apart while the cross is much smaller, so it
        // reached 1.91 and the two plateaus swallowed the page. And it means
        // nothing at all where the clusters are not a page-width apart — in
        // landscape they sit in opposite gutters, and on the card it worked out
        // to a 700-point disc on a 1080 canvas.
        //
        // What matters is the plateau against the thing it grounds, so that is
        // what is set. Whether they touch is then a consequence, and on most
        // phones they do.
        let paired: CGFloat? = {
            guard let pad = buttons[.dpad] else { return nil }
            return max(pad.width, pad.height) * ControlLayoutDefaults.ps1PlateauScale
        }()
        func circle(_ centre: CGPoint, _ d: CGFloat) -> UIBezierPath {
            UIBezierPath(ovalIn: CGRect(x: centre.x - d / 2, y: centre.y - d / 2,
                                        width: d, height: d))
        }
        var ground: [UIBezierPath] = []
        for cluster in [buttons[.dpad], blocRect].compactMap({ $0 }) {
            // Never smaller than the cluster it is the ground for.
            let d = max(paired ?? 0, max(cluster.width, cluster.height) + lip * 2)
            if d > 0 { ground.append(circle(CGPoint(x: cluster.midX, y: cluster.midY), d)) }
        }
        for element in [ControlElement.stickLeft, .stickRight] {
            guard let f = buttons[element] else { continue }
            ground.append(circle(CGPoint(x: f.midX, y: f.midY),
                                 max(f.width, f.height) * ControlLayoutDefaults.ps1StickBossSpan))
        }
        // THE TWO TONES ARE SWAPPED from where they started: the raised ground
        // now wears what the printed marks wore, and the marks wear the shell's
        // own lighter tone. It reads better because it is the right way round on
        // the hardware: the swelling is a piece of the CASE, and the mark on it
        // is ink, so the ink should be the darker of the two.
        if var merged = ground.first?.cgPath {
            for piece in ground.dropFirst() { merged = merged.union(piece.cgPath) }
            drawRaised(UIBezierPath(cgPath: merged), fill: raisedGroundFill, scale: scale)
        }

        // THE CROSS MARK, printed on each plateau: ONE shape big enough to hold
        // the four keys and the four wedges together, so the eight read as a
        // single object rather than as marks scattered over a disc.
        //
        // The diamond's is the SAME reach, so the two span the same distance,
        // but its arms are the width that gives each of its four buttons an
        // equal margin on every side — a cross inside a cross wants one width, a
        // diamond inside a cross wants another, and forcing them to share would
        // pick one of the two clusters to look wrong.
        //
        // In the SHELL's raised tone, which the ground used to carry.
        if let pad = buttons[.dpad] {
            // HALFWAY BETWEEN the mark's own tone and the ground it is printed
            // on. At full contrast the mark read as a second object sitting on
            // the plateau; at the midpoint it reads as a marking IN it, which is
            // what a moulded line on a shell actually is.
            groundTone.rpMixed(with: markInk, 0.5).setFill()
            CrossDPadView.ps1PlateauCross(in: pad).fill()
            if let bloc = blocRect, let a = buttons[.btnA] {
                let reach = CrossDPadView.ps1PlateauReach(in: pad)
                let step = abs(a.midX - bloc.midX)
                let moved = CrossDPadView.ps1PlateauCross(
                    in: pad,
                    armHalf: CrossDPadView.ps1DiamondArmHalf(reach: reach, step: step))
                moved.apply(CGAffineTransform(translationX: bloc.midX - pad.midX,
                                              y: bloc.midY - pad.midY))
                moved.fill()
            }
        }
    }

    // MARK: Body

    private func drawBody(_ ctx: CGContext, _ bounds: CGRect) {
        let colors = [bodyTop.cgColor, bodyMid.cgColor, bodyBottom.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: bounds.midX, y: bounds.minY),
                                   end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
        } else {
            bodyMid.setFill(); ctx.fill(bounds)
        }
        ctx.saveGState(); ctx.setAlpha(0.5)
        GameBoySkin.grain.drawAsPattern(in: bounds)
        ctx.restoreGState()
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let vig = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.12).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: vig, locations: [0.55, 1]) {
            ctx.drawRadialGradient(g, startCenter: centre, startRadius: 0, endCenter: centre,
                                   endRadius: max(bounds.width, bounds.height) * 0.62,
                                   options: .drawsAfterEndLocation)
        }
    }

    private func drawScreenPanel(_ ctx: CGContext, bounds: CGRect, screen: CGRect,
                                 isLandscape: Bool, scale: CGFloat) {
        // The two numbers live on `ControlLayoutDefaults` because the LAYOUT
        // needs them too: landscape places its SELECT · MENU · START row below
        // this skirt, not below the picture, and a row measured from one while
        // the frame is drawn from the other is a row that sits on the frame.
        let skirt = (isLandscape ? ControlLayoutDefaults.ps1LandscapeSkirt
                                 : ControlLayoutDefaults.ps1PortraitSkirt) * scale
        let panel = screen.insetBy(dx: -skirt, dy: -skirt)
        let path = UIBezierPath(roundedRect: panel, cornerRadius: 10 * scale)
        surround.setFill(); path.fill()
        drawRelief(path, inset: 2 * scale, corner: 10 * scale, scale: scale)
    }

    // MARK: Plates

    /// The seat under each face button: a dark area very slightly larger than
    /// the button, so at rest it is a hairline and on press it opens up as the
    /// button shrinks into it. Every other console here has one; this console
    /// went without and its faces floated on the shell.
    private func drawFaceSeats(buttons: [ControlElement: CGRect], scale: CGFloat) {
        let lip = 1.5 * scale
        // BLACK, not a dark grey. These read as holes the buttons come up
        // through, and a hole is not a shade of the shell: anything short of
        // black keeps looking like paint. The cross's seat below stays a
        // translucent dark, because it is a seat and not a hole.
        UIColor.black.setFill()
        for element in [ControlElement.btnA, .btnB, .btnX, .btnY] {
            guard let f = buttons[element] else { continue }
            UIBezierPath(ovalIn: f.insetBy(dx: -lip, dy: -lip)).fill()
        }
        UIColor.black.withAlphaComponent(0.30).setFill()
        // The cross gets the same treatment, and its seat is the FOUR KEYS
        // grown a little rather than a cross-shaped well: this pad's directions
        // are four separate mouldings, so one well behind all of them would be
        // a hole where the shell should be. The shape comes from the view that
        // draws the keys, so the seat cannot drift away from them.
        if let d = buttons[.dpad] {
            let keys = CrossDPadView.ps1KeysPath(in: d)
            let grow = 1 + (lip * 2) / max(d.width, 1)
            keys.apply(CGAffineTransform(translationX: -d.midX, y: -d.midY))
            keys.apply(CGAffineTransform(scaleX: grow, y: grow))
            keys.apply(CGAffineTransform(translationX: d.midX, y: d.midY))
            keys.fill()
        }
    }

    /// The shade a recess is against the shell: darker, because a hollow is in
    /// shadow. Derived from the body so a custom palette carves correctly too,
    /// and by more on a dark shell than a light one, since black added to
    /// near-black moves almost nothing.
    private var wellFill: UIColor {
        bodyMid.rpMixed(with: .black, bodyMid.rpIsLight ? 0.16 : 0.30)
    }

    /// The shell's raised tone: what a swelling in this plastic looks like.
    private var groundTone: UIColor {
        bodyMid.rpMixed(with: .white, bodyMid.rpIsLight ? 0.22 : 0.16)
    }

    /// What the four raised areas are FILLED with.
    ///
    /// The Retro Pal recolour takes the body's own colour, so the swellings are
    /// read entirely by their relief rather than by a change of tone — on a
    /// near-black shell a lighter disc reads as a separate part, where the point
    /// of them is that they are the same piece of plastic pushed up. Nostalgia
    /// keeps the printed tone, which on a pale grey shell it needs to be seen at
    /// all. A custom palette follows Nostalgia: its body can be any colour, and
    /// relief alone is not a safe bet on a colour nobody has chosen yet.
    /// ⚠ A CUSTOM PALETTE FOLLOWS THE BODY, not the ink (fixed 2026-08-27).
    /// It used to take `markInk`, which is the control colour 55% of the way to
    /// white, and 55% white washes ANY hue out to something that reads as grey.
    /// Set the shell to purple and these four discs stayed grey, which is what
    /// the device showed. They are swellings in the shell, so the shell is what
    /// they must follow, and `groundTone` already derives that correctly on a
    /// light body and a dark one.
    private var raisedGroundFill: UIColor {
        if custom != nil { return groundTone }
        return variant == .retroPal ? bodyMid : markInk
    }

    /// What the four wedges beside the cross are filled with. Lighter than the
    /// shell on the Retro Pal recolour, where the carved tone the other dress
    /// uses would be black on black; derived from the body rather than named, so
    /// it lands on a dark grey without a hex to keep in step.
    private var wedgeFill: UIColor {
        variant == .retroPal ? bodyMid.rpMixed(with: .white, 0.16) : wellFill
    }
    /// The printed-mark tone, the menu glyph's own, so everything on this pad
    /// that is INK rather than plastic agrees.
    /// ⚠ NOT the printed-text slot, despite the name. This fills the raised
    /// CROSS behind the pad and the diamond, which is plastic. It was wired to
    /// `custom?.print` for one commit on 2026-08-27 and recoloured those two
    /// shapes instead of any label, which is what the device showed. Printed text
    /// lives in `PS1TouchControlsView` and `SmallButton`, on the controls
    /// themselves, not on the shell.
    private var markInk: UIColor { control.rpMixed(with: .white, 0.55) }


    /// The inverse of `drawWell`: filled a shade LIGHTER than the shell, then a
    /// light catch falling from the top rim and a dark one rising from the
    /// bottom. Same two strokes, same clipping, opposite order — which is all
    /// that separates something raised from something hollow.
    private func drawRaised(_ shape: UIBezierPath, fill: UIColor, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        fill.setFill(); shape.fill()
        ctx.saveGState(); shape.addClip(); ctx.setAlpha(0.35)
        GameBoySkin.grain.drawAsPattern(in: shape.bounds); ctx.restoreGState()

        let outer = grown(shape, by: 2 * scale)
        ctx.saveGState(); shape.addClip()
        // TWICE AS PRESENT. Spent on the shadows' alpha AND their reach: doubling
        // the alpha alone deepens a rim that is already only two points wide, so
        // the offset and blur go with it and the curve has room to be seen.
        ctx.setShadow(offset: CGSize(width: 0, height: 3.6 * scale), blur: 4.8 * scale,
                      color: UIColor.white.withAlphaComponent(0.95).cgColor)
        UIColor.white.setStroke(); outer.lineWidth = 3 * scale; outer.stroke()
        ctx.restoreGState()
        ctx.saveGState(); shape.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: -3.2 * scale), blur: 4.4 * scale,
                      color: UIColor.black.withAlphaComponent(0.90).cgColor)
        UIColor.black.setStroke(); outer.lineWidth = 3 * scale; outer.stroke()
        ctx.restoreGState()
    }

    /// The four marks between the cross's keys and the pad's rim.
    ///
    /// Shell, not control: nothing hit-tests them, and they are here for the
    /// reason the console's own pad has relief around each direction. Carved
    /// with no lip at all, because a wedge this small grown by even a couple of
    /// points stops being a wedge.
    private func drawPadWedges(buttons: [ControlElement: CGRect], scale: CGFloat) {
        guard let pad = buttons[.dpad] else { return }
        drawWell(CrossDPadView.ps1SurroundWedges(in: pad), lip: 0, fill: wedgeFill,
                 scale: scale)
    }

    /// Every control on this pad that is SET INTO the shell rather than standing
    /// on it: the four shoulders, SELECT, START, ANALOG, MENU and CLIP.
    ///
    /// Each gets two things under it, in this order: a well carved into the
    /// shell, then the black hole the control comes up through. The well is the
    /// shell's business and the hole is the gap around the moving part, and
    /// drawing only one of them was what left these nine looking pasted on while
    /// the four faces, which have had a hole since the first pass, did not.
    ///
    /// EACH FOLLOWS THE CONTROL'S OWN SHAPE. That is the whole point and the
    /// only hard part: START prints a triangle, so a rounded rectangle behind it
    /// would read as a mistake rather than as a recess. The shapes come from
    /// `SmallButton.PS1Shape`, the same call the buttons themselves draw from,
    /// so a well and the thing in it cannot describe different objects.
    private func drawSetControls(buttons: [ControlElement: CGRect], scale: CGFloat) {
        // Both pulled in: the recess was reading as a border around each control
        // rather than as the shell dipping toward it.
        let wellLip = 2.5 * scale
        let holeLip = 1 * scale
        for shape in setControlShapes(buttons: buttons) {
            drawWell(shape, lip: wellLip, scale: scale)
            // Black, like the faces': a hole is not a shade of the shell.
            UIColor.black.setFill()
            grown(shape, by: holeLip).fill()
        }
    }

    /// The nine shapes, each as the control itself draws it.
    ///
    /// The shoulders take the bar's own fixed corner (`ShoulderButton.ps1Corner`,
    /// in points and not scaled, exactly as the view applies it). MENU and CLIP
    /// are the two that are not ps1 shapes at all: they wear `.circle` on every
    /// console, so theirs is the disc the button actually draws, the smaller
    /// side of its hitbox.
    private func setControlShapes(buttons: [ControlElement: CGRect]) -> [UIBezierPath] {
        var shapes: [UIBezierPath] = []
        for element in [ControlElement.btnL, .btnL2, .btnR, .btnR2] {
            guard let f = buttons[element] else { continue }
            shapes.append(UIBezierPath(roundedRect: f,
                                       cornerRadius: ShoulderButton.ps1Corner))
        }
        for element in [ControlElement.btnSelect, .btnStart, .btnMode] {
            guard let f = buttons[element],
                  let style = SmallButton.PS1Shape.style(for: element) else { continue }
            shapes.append(SmallButton.PS1Shape.path(style, in: f))
        }
        for element in [ControlElement.btnMenu, .btnClip] {
            guard let f = buttons[element] else { continue }
            let d = min(f.width, f.height)
            shapes.append(UIBezierPath(ovalIn: CGRect(x: f.midX - d / 2, y: f.midY - d / 2,
                                                      width: d, height: d)))
        }
        return shapes
    }

    /// `shape` grown outward by `lip` on every side, whatever the shape.
    ///
    /// Stroking it and unioning the stroke with the fill, rather than insetting
    /// a rectangle: an inset only means anything for a rect, and two of these
    /// five are a triangle and a disc.
    private func grown(_ shape: UIBezierPath, by lip: CGFloat) -> UIBezierPath {
        // A lip of nothing means the shape itself. The wedges around the cross
        // ask for that: they are small enough that growing them at all would
        // round the point off the thing that makes them wedges.
        guard lip > 0 else { return shape }
        // Not optional, unlike `copy()` and `copy(using:)`: this overload always
        // returns a path, so there is nothing here to unwrap.
        let ring = shape.cgPath.copy(strokingWithWidth: lip * 2, lineCap: .round,
                                     lineJoin: .round, miterLimit: 10)
        // A REAL union (iOS 16), not an append. Appended, the ring's inner
        // contour and the shape are wound opposite ways and cancel under the
        // non-zero rule, which would leave the well as a hollow outline with the
        // shell showing through the middle of it.
        return UIBezierPath(cgPath: shape.cgPath.union(ring))
    }

    /// The carved well: filled a shade darker than the shell, grained so it is
    /// the same plastic, then a dark inner shadow falling from the TOP rim and a
    /// light catch rising from the BOTTOM one. Those two are what make a filled
    /// area read as cut into a surface rather than laid on it, and they are the
    /// same pair the Game Boy's own recesses use.
    private func drawWell(_ shape: UIBezierPath, lip: CGFloat, fill: UIColor? = nil,
                          scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let well = grown(shape, by: lip)
        (fill ?? wellFill).setFill(); well.fill()
        ctx.saveGState(); well.addClip(); ctx.setAlpha(0.35)
        GameBoySkin.grain.drawAsPattern(in: well.bounds); ctx.restoreGState()

        // Strokes of a slightly LARGER outline, clipped to the well, so only the
        // shadows bleed inside and the stroke itself never shows.
        let outer = grown(shape, by: lip + 2 * scale)
        ctx.saveGState(); well.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.8 * scale), blur: 2.6 * scale,
                      color: UIColor.black.withAlphaComponent(0.5).cgColor)
        UIColor.black.setStroke(); outer.lineWidth = 2 * scale; outer.stroke()
        ctx.restoreGState()
        ctx.saveGState(); well.addClip()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 1.6 * scale,
                      color: UIColor.white.withAlphaComponent(0.4).cgColor)
        UIColor.white.setStroke(); outer.lineWidth = 1.5 * scale; outer.stroke()
        ctx.restoreGState()
    }

    // MARK: Pieces

    /// The carved rim: a dark catch along the top edge and a light one along the
    /// bottom, clipped to the shape, which is what makes a flat fill read as
    /// something sunk into a surface.
    private func drawRelief(_ path: UIBezierPath, inset: CGFloat, corner: CGFloat, scale: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        path.addClip()
        UIColor.black.withAlphaComponent(0.28).setStroke()
        let top = UIBezierPath(cgPath: path.cgPath)
        top.lineWidth = 2 * scale
        ctx.saveGState(); ctx.translateBy(x: 0, y: inset); top.stroke(); ctx.restoreGState()
        UIColor.white.withAlphaComponent(0.20).setStroke()
        let bottom = UIBezierPath(cgPath: path.cgPath)
        bottom.lineWidth = 2 * scale
        ctx.saveGState(); ctx.translateBy(x: 0, y: -inset); bottom.stroke(); ctx.restoreGState()
        ctx.restoreGState()
    }

    /// An engraved word, centred in `rect` and sized to `fraction` of its width.
    /// Two passes: the letter in shadow, and a one-point light catch below it,
    /// which is the whole trick that makes text look cut rather than printed.
    private func drawEngraved(_ text: String, in rect: CGRect, on plate: UIColor,
                              weight: UIFont.Weight, fraction: CGFloat, scale: CGFloat) {
        guard rect.width > 0, rect.height > 0 else { return }
        let kern = 0.6 * scale
        var size = 10 * scale
        func measure(_ s: CGFloat) -> CGSize {
            NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: s, weight: weight), .kern: kern]).size()
        }
        var sz = measure(size)
        if sz.width > 0 { size *= (rect.width * fraction) / sz.width; sz = measure(size) }
        size = min(size, rect.height * 0.72)
        sz = measure(size)
        let origin = CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2)
        NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: plate.rpMixed(with: .white, 0.16), .kern: kern,
        ]).draw(at: CGPoint(x: origin.x, y: origin.y + 1 * scale))
        NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: engraved(on: plate), .kern: kern,
        ]).draw(at: origin)
    }

    /// The plaque's width against its height. The mark is square and the
    /// wordmark runs about two and a half times its own height, plus the end
    /// caps: this is what that comes to, and it is the one number both pages
    /// size themselves from.
    private static let brandPlaqueAspect: CGFloat = 3.6

    /// The wordmark in one flat pass, sized to its box the way `drawEngraved`
    /// sizes its own, so the two land identically apart from the ink.
    private func drawFlatBrandText(_ text: String, in rect: CGRect, ink: UIColor,
                                   scale: CGFloat) {
        let kern = 0.6 * scale
        func measure(_ s: CGFloat) -> CGSize {
            NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: s, weight: .semibold), .kern: kern]).size()
        }
        var size = 10 * scale
        var sz = measure(size)
        if sz.width > 0 { size *= rect.width / sz.width; sz = measure(size) }
        size = min(size, rect.height * 0.72)
        sz = measure(size)
        NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: ink, .kern: kern,
        ]).draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
    }

    /// The Retro Pal plaque: the mark and the wordmark together in one pill,
    /// CARVED into the shell like every other flat thing on this pad.
    ///
    /// A pill, which no CONTROL here is allowed to be — that rule was about what
    /// a thumb presses, and this is the one mark on the page that is not a
    /// control at all. Reaching for the shape the controls are forbidden is what
    /// keeps it from being mistaken for one.
    private func drawBrandPlaque(in rect: CGRect, ink: UIColor? = nil, scale: CGFloat) {
        guard rect.width > 24 * scale, rect.height > 10 * scale else { return }
        let pill = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
        // Filled with the RAISED tone rather than the carved one, even though it
        // is carved. The wordmark is engraved into whatever it sits on, and
        // `engraved(on:)` always goes darker than its plate: on the Retro Pal
        // shell the carved tone is already near-black, so a letter darker still
        // is a letter nobody can read. The lighter plate is what gives the
        // engraving somewhere to go.
        drawWell(pill, lip: 0, fill: groundTone, scale: scale)
        // Clear of the round end caps and the recess rim.
        let inset = rect.insetBy(dx: rect.height * 0.34, dy: rect.height * 0.20)
        guard inset.width > 4 * scale, inset.height > 4 * scale else { return }
        let side = inset.height
        if let icon = brandImage {
            icon.draw(in: CGRect(x: inset.minX, y: inset.minY, width: side, height: side))
        }
        let textX = inset.minX + side + side * 0.22
        let text = CGRect(x: textX, y: inset.minY,
                          width: inset.maxX - textX, height: inset.height)
        if text.width > 8 * scale {
            if let ink {
                // PRINTED rather than engraved. Landscape hangs the plaque on the
                // shell above the picture instead of in a lane between controls,
                // and a groove disappears up there: it wants the ink the MENU
                // glyph wears, so the mark reads at the distance that band is
                // seen from.
                drawFlatBrandText("Retro Pal", in: text, ink: ink, scale: scale)
            } else {
                drawEngraved("Retro Pal", in: text, on: groundTone,
                             weight: .semibold, fraction: 1.0, scale: scale)
            }
        }
    }

    private func drawBrand(bounds: CGRect, screen: CGRect, buttons: [ControlElement: CGRect],
                           isLandscape: Bool, scale: CGFloat) {
        let aspect = Self.brandPlaqueAspect
        // ONE INK RULE FOR ALL THREE SURFACES. The Retro Pal shell prints the
        // wordmark in the MENU glyph's tone rather than engraving it: at that end
        // of the scale a groove is a letter darker than a near-black plate, which
        // is a letter nobody reads. Nostalgia keeps the engraving everywhere, its
        // shell being pale enough that a cut still shows.
        let ink: UIColor? = variant == .retroPal ? markInk : nil
        if cardMode {
            // THE CARD gets it above the picture, centred, like the landscape
            // page. It cannot take the portrait rule: that one hangs the plaque
            // on CLIP's line, and the card PARKS Clip three card-heights below
            // the canvas so it cannot be seen — the plaque would have followed
            // it off the image. And the card is the one surface where the mark
            // matters most, so returning early here (as this did) was the wrong
            // answer twice over.
            // THE SAME SIZE AND PLACE AS THE GBA CARD'S, formula for formula:
            // that card is the one every other console's was measured against,
            // and a plaque two thirds the size of its neighbours reads as a
            // different product rather than as a smaller machine.
            let top = screen.minY
            guard top > 20 * scale else { return }
            var h = Swift.min(34 * scale, (top - bounds.minY) * 0.4) * 2.5
            var w = h * aspect
            let room = bounds.width - 32 * scale
            if w > room { w = room; h = w / aspect }
            let cy = Swift.max(h / 2 + 8 * scale, (bounds.minY + top) / 2)
            drawBrandPlaque(in: CGRect(x: bounds.midX - w / 2, y: cy - h / 2,
                                       width: w, height: h), ink: ink, scale: scale)
            return
        }
        if isLandscape {
            // ABOVE THE PICTURE, centred on the page. This page puts the picture
            // in the middle, so the band above it is empty except for the
            // shoulder bars, and those live in the gutters — the middle of that
            // band is the only stretch of shell on either page wide enough for
            // the wordmark and touched by nothing.
            let top = screen.minY - ControlLayoutDefaults.ps1LandscapeSkirt * scale
            let band = top - bounds.minY
            guard band > 14 * scale else { return }
            var h = Swift.min(band * 0.62, 30 * scale)
            var w = h * aspect
            let room = bounds.width - 32 * scale
            if w > room { w = room; h = w / aspect }
            drawBrandPlaque(in: CGRect(x: bounds.midX - w / 2,
                                       y: (bounds.minY + top) / 2 - h / 2,
                                       width: w, height: h),
                            ink: ink, scale: scale)
            return
        }
        // PORTRAIT: the lane left of SELECT, on the line the three marks share.
        //
        // That lane exists because SELECT and START sit centred as a pair while
        // CLIP holds the right-hand end, so the left end of that row is the one
        // stretch of this page with nothing in it. Sized to the lane rather than
        // to a constant: it is as large as the space allows, and it disappears
        // rather than shrinking to a smear if a narrower phone ever leaves less.
        guard let select = buttons[.btnSelect] else { return }
        let margin = 10 * scale
        var w = (select.minX - bounds.minX) - margin * 2
        var h = w / aspect
        // Never deeper than the row it sits in.
        if h > select.height * 0.62 { h = select.height * 0.62; w = h * aspect }
        // CLIP's centre IS the marks' line: SELECT and START are dropped below it
        // by their own word's height, and the plaque has no word underneath.
        let line = buttons[.btnClip]?.midY ?? select.midY
        drawBrandPlaque(in: CGRect(x: (bounds.minX + select.minX) / 2 - w / 2,
                                   y: line - h / 2, width: w, height: h), ink: ink, scale: scale)
    }

}
