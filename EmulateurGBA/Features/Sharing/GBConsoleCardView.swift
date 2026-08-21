//
//  GBConsoleCardView.swift
//  EmulateurGBA
//
//  Renders the GB/GBC Nostalgia console as a square (1:1) image for the Pro screenshot card. The
//  SCREEN is the immovable anchor (sized + positioned exactly like the standard card); every other
//  component is placed around it by `GBCardLayout`. The renderer draws the game frame + the
//  pro-info row on top of this snapshot.
//
//  Component sizes are the in-game defaults at a fixed card scale (0.78). Positions are bespoke to
//  the square (not the in-game default layout): the D-pad and A/B sit in the band below the
//  surround, and Menu / pro-row / SELECT-START stack down the centre. Tunable.
//

import UIKit

/// The full square layout for the GB/GBC console card — shared by the view (button positions) and
/// the renderer (screen rect + pro-row anchor).
struct GBCardLayout {
    let screen: CGRect
    let buttons: [String: ButtonLayout]   // fractions of the full card (controls fill the card)
    let deviceScale: CGFloat
    /// NDS screenshot card only: the two separated game-screen rects (upper, lower). Empty for every
    /// other layout (GB/GBC, GBA, and the NDS clip/combined path), which use the single `screen` rect.
    /// When populated, the skin draws a surround rim around each, and the renderer splits the stacked
    /// frame into these two rects.
    var ndsScreens: [CGRect] = []

    static func make(side S: CGFloat, gameNativeSize g: CGSize) -> GBCardLayout {
        let k: CGFloat = 0.78   // fixed: keeps the components at the size already validated

        // Screen: identical to the standard card (fit into (S-120) x 640, centred, y = 174).
        // Guard against zero only — NOT 1: a portrait aspect < 1 (NDS = 0.667) passed as (aspect, 1)
        // must keep its ratio, not be clamped up to a square.
        let gw = max(g.width, 0.01), gh = max(g.height, 0.01)
        let fit = min((S - 120) / gw, 640 / gh)
        let fW = gw * fit, fH = gh * fit
        let screen = CGRect(x: (S - fW) / 2, y: 174, width: fW, height: fH)

        // The band below the surround (mirrors GameBoySkin.portraitDeco's vertical pad = 38·scale).
        let surroundBottom = min(screen.maxY + 38 * k, S - 8 * k)
        let bandCenterY = (surroundBottom + S) / 2

        // A↔B gaps (match gbcPortrait offsets): vertical centre gap + half the horizontal A↔B gap.
        let abGap = 54.4 * k
        let abHalfX = 65.6 * k / 2

        // D-pad: CENTRE on the screen's left edge. A/B block: CENTRE on the screen's right edge
        // (A just right of it, B just left), both centred vertically in the band.
        let dpadCX = screen.minX
        let aCX = screen.maxX + abHalfX
        let bCX = screen.maxX - abHalfX
        let aCY = bandCenterY - abGap / 2
        let bCY = bandCenterY + abGap / 2

        // SELECT/START keep their spot: the bottom of a 4-spacer VStack (Menu / info / SELECT-START)
        // — the info block + Menu are no longer drawn here (Menu removed, info uses the standard
        // card's position), but the spacing is kept so SELECT/START stay where they were validated.
        let menuH = ControlElement.btnMenu.defaultSize.height * k
        let ssH = ControlElement.btnSelect.defaultSize.height * k
        let proRowH: CGFloat = 44
        let H = S - surroundBottom
        let spacer = max(0, (H - (menuH + proRowH + ssH)) / 4)
        let ssCY = S - spacer - ssH / 2
        let selCX = S / 2 - 38 * k, staCX = S / 2 + 38 * k

        func bl(_ x: CGFloat, _ y: CGFloat, _ hidden: Bool = false) -> ButtonLayout {
            ButtonLayout(centerX: x / S, centerY: y / S, isHidden: hidden)
        }
        var buttons: [String: ButtonLayout] = [:]
        buttons[ControlElement.dpad.rawValue]    = bl(dpadCX, bandCenterY)
        buttons[ControlElement.btnA.rawValue]    = bl(aCX, aCY)
        buttons[ControlElement.btnB.rawValue]    = bl(bCX, bCY)
        buttons[ControlElement.btnSelect.rawValue] = bl(selCX, ssCY)
        buttons[ControlElement.btnStart.rawValue]  = bl(staCX, ssCY)
        // Menu is forced-visible by applyLayout, so it can't be hidden via isHidden — park it far
        // off the card instead (removed from the card). Clip is hidden.
        buttons[ControlElement.btnMenu.rawValue] = bl(S / 2, S * 3)
        buttons[ControlElement.btnClip.rawValue] = bl(S / 2, S * 3, true)

        return GBCardLayout(screen: screen, buttons: buttons, deviceScale: k)
    }

    /// GBA card layout: the SAME shared positions as the GB/GBC card (screen + D-pad / A·B /
    /// SELECT·START), plus the GBA-only L / R shoulders at the top corners. First-cut shoulder
    /// positions — dynamic, to be tuned on device (like the GB/GBC card build).
    static func gba(side S: CGFloat, gameNativeSize g: CGSize) -> GBCardLayout {
        let base = make(side: S, gameNativeSize: g)
        var buttons = base.buttons
        // D-pad: at 18% of the card width (keep its vertical band position).
        if let d = buttons[ControlElement.dpad.rawValue] {
            buttons[ControlElement.dpad.rawValue] = ButtonLayout(centerX: 0.18, centerY: d.centerY, isHidden: d.isHidden)
        }
        // A/B block: re-centre horizontally at 82% of the card width, preserving the A↔B gap + heights.
        if let a = buttons[ControlElement.btnA.rawValue], let b = buttons[ControlElement.btnB.rawValue] {
            let halfGap = (a.centerX - b.centerX) / 2
            buttons[ControlElement.btnA.rawValue] = ButtonLayout(centerX: 0.82 + halfGap, centerY: a.centerY, isHidden: a.isHidden)
            buttons[ControlElement.btnB.rawValue] = ButtonLayout(centerX: 0.82 - halfGap, centerY: b.centerY, isHidden: b.isHidden)
        }
        // L / R: top corners, vertically in the band above the screen surround. Tunable.
        let lrY = base.screen.minY * 0.5
        buttons[ControlElement.btnL.rawValue] = ButtonLayout(centerX: 0.13, centerY: lrY / S, isHidden: false)
        buttons[ControlElement.btnR.rawValue] = ButtonLayout(centerX: 0.87, centerY: lrY / S, isHidden: false)
        return GBCardLayout(screen: base.screen, buttons: buttons, deviceScale: base.deviceScale)
    }

    /// SNES card layout: the GBA card's, with the A/B pair replaced by the four-button diamond.
    ///
    /// The GBA card is the right base because this console wears the GBA's page in the game too:
    /// one screen, shoulders at the top corners, D-pad left and faces right. What differs is the
    /// same thing that differs in the game, so it is replaced the same way — as one bloc, in the
    /// arrangement the hardware has (X above B, Y left of A) rather than the DS's staggered pair.
    static func snes(side S: CGFloat, gameNativeSize g: CGSize) -> GBCardLayout {
        let base = gba(side: S, gameNativeSize: g)
        let k = base.deviceScale
        var buttons = base.buttons
        guard let a = buttons[ControlElement.btnA.rawValue],
              let b = buttons[ControlElement.btnB.rawValue] else { return base }
        // The diamond takes the A/B bloc's centre, so nothing else on the card has to move.
        let cx = (a.centerX + b.centerX) / 2
        let cy = (a.centerY + b.centerY) / 2
        let r = ControlElement.btnX.defaultNDSPortraitSize.height * k * 0.92 / S
        buttons[ControlElement.btnX.rawValue] = ButtonLayout(centerX: cx,     centerY: cy - r)
        buttons[ControlElement.btnB.rawValue] = ButtonLayout(centerX: cx,     centerY: cy + r)
        buttons[ControlElement.btnY.rawValue] = ButtonLayout(centerX: cx - r, centerY: cy)
        buttons[ControlElement.btnA.rawValue] = ButtonLayout(centerX: cx + r, centerY: cy)
        return GBCardLayout(screen: base.screen, buttons: buttons, deviceScale: k)
    }

    /// NES card layout: `make`'s, unchanged. This console wears the Game Boy's page in the game
    /// too — one screen, no shoulders, D-pad left and A/B right — so it wants the Game Boy card's
    /// arrangement rather than a shape of its own. Named anyway, so the card mapping has one
    /// entry per console and nothing falls through to another console's layout by default.
    static func nes(side S: CGFloat, gameNativeSize g: CGSize) -> GBCardLayout {
        make(side: S, gameNativeSize: g)
    }

    /// NDS card layout: the shared screen + SELECT/START positions from `make`, plus the NDS set —
    /// D-pad at 18%, the A/B/X/Y diamond centred at 82%, L/R top corners, and the MIC in the left
    /// gutter. First-cut positions (the screen is tall + narrow, so there is room in the gutters);
    /// tuned on device like the GB/GBC + GBA cards.
    static func nds(side S: CGFloat, gameNativeSize g: CGSize, separatedScreens: Bool = false) -> GBCardLayout {
        let base = make(side: S, gameNativeSize: g)
        let k = base.deviceScale
        var buttons = base.buttons

        // Screenshot card only (the clip + every other caller keep the combined-screen layout below,
        // unchanged). The L/R/MIC/light bloc (top rail + components row + bottom rail) is centred on
        // the card so it is symmetric about the vertical centre; the two screens are split out at
        // +20% around it (upper between the card top and the top rail, lower between the bottom rail
        // and the card bottom); the D-pad + A/B/X/Y diamond share one line in the lower band. The
        // row's HORIZONTAL layout is identical to the combined-screen path (same gutter), only its Y
        // moves to the centre. Rail Ys (NintendoDSSkin.drawCardRails) fall at row.midY ∓ (lh/2 + spacerL/4).
        if separatedScreens {
            let lw = ControlElement.btnL.defaultNDSPortraitSize.width * k
            let lh = ControlElement.btnL.defaultNDSPortraitSize.height * k
            let micw = ControlElement.btnMic.defaultNDSPortraitSize.width * k
            let spacerL = max(0, (base.screen.minX - lw - micw) / 3)
            let lCenter = spacerL + lw / 2
            let micCenter = 2 * spacerL + lw + micw / 2
            let rowCenterY = S / 2
            let rowY = rowCenterY / S
            buttons[ControlElement.btnL.rawValue]   = ButtonLayout(centerX: lCenter / S,       centerY: rowY, isHidden: false)
            buttons[ControlElement.btnMic.rawValue] = ButtonLayout(centerX: micCenter / S,     centerY: rowY, isHidden: false)
            buttons[ControlElement.btnR.rawValue]   = ButtonLayout(centerX: (S - lCenter) / S, centerY: rowY, isHidden: false)
            let topRailY = rowCenterY - lh / 2 - spacerL / 4
            let bottomRailY = rowCenterY + lh / 2 + spacerL / 4

            // Two screens, +20%, on the combined screen's horizontal centre.
            let perW = base.screen.width * 1.2
            let perH = (base.screen.height / 2) * 1.2
            let cx = base.screen.midX
            let upper = CGRect(x: cx - perW / 2, y: topRailY / 2 - perH / 2, width: perW, height: perH)
            let lower = CGRect(x: cx - perW / 2, y: (bottomRailY + S) / 2 - perH / 2, width: perW, height: perH)

            // D-pad + diamond: one vertical line at 60% from the bottom rail (0%) to the card bottom
            // (100%). D-pad centred in the left gutter (card edge → screen left); diamond centred in
            // the right gutter (lower screen's right edge → card edge).
            let blocY = (bottomRailY + 0.6 * (S - bottomRailY)) / S
            let dpadX = (upper.minX / 2) / S
            let diamondX = ((lower.maxX + S) / 2) / S
            buttons[ControlElement.dpad.rawValue] = ButtonLayout(centerX: dpadX, centerY: blocY, isHidden: false)
            // Diamond: X top, B bottom, Y left, A right.
            let r = ControlElement.btnX.defaultSize.height * k * 0.92 / S
            buttons[ControlElement.btnX.rawValue] = ButtonLayout(centerX: diamondX,     centerY: blocY - r, isHidden: false)
            buttons[ControlElement.btnB.rawValue] = ButtonLayout(centerX: diamondX,     centerY: blocY + r, isHidden: false)
            buttons[ControlElement.btnY.rawValue] = ButtonLayout(centerX: diamondX - r, centerY: blocY,     isHidden: false)
            buttons[ControlElement.btnA.rawValue] = ButtonLayout(centerX: diamondX + r, centerY: blocY,     isHidden: false)
            // SELECT/START: keep make()'s vertical position; re-centre the pair horizontally on the
            // diamond column (the same ±38·k arrangement make() used, shifted from the card centre).
            let ssOff = 38 * k / S
            if let sel = buttons[ControlElement.btnSelect.rawValue] {
                buttons[ControlElement.btnSelect.rawValue] = ButtonLayout(centerX: diamondX - ssOff, centerY: sel.centerY, isHidden: sel.isHidden)
            }
            if let sta = buttons[ControlElement.btnStart.rawValue] {
                buttons[ControlElement.btnStart.rawValue] = ButtonLayout(centerX: diamondX + ssOff, centerY: sta.centerY, isHidden: sta.isHidden)
            }
            return GBCardLayout(screen: base.screen, buttons: buttons, deviceScale: k, ndsScreens: [upper, lower])
        }

        // D-pad and the A/B/X/Y diamond: vertically aligned with the play-time / crown / Pro-member
        // line, and horizontally aligned with the speakers — D-pad under the left speaker, the
        // diamond (one bloc) under the right speaker. (The speaker centres match
        // NintendoDSSkin.drawSpeakers: left = screen.minX/2, right = (screen.maxX+S)/2.)
        let blocY = ScreenshotCardRenderer.standardPlayLineCenterY(screen: base.screen) / S
        let dpadX = base.screen.minX / 2 / S
        let diamondX = (base.screen.maxX + S) / 2 / S
        buttons[ControlElement.dpad.rawValue] = ButtonLayout(centerX: dpadX, centerY: blocY, isHidden: false)
        // Diamond: X top, B bottom, Y left, A right.
        let r = ControlElement.btnX.defaultSize.height * k * 0.92 / S
        buttons[ControlElement.btnX.rawValue] = ButtonLayout(centerX: diamondX,     centerY: blocY - r, isHidden: false)
        buttons[ControlElement.btnB.rawValue] = ButtonLayout(centerX: diamondX,     centerY: blocY + r, isHidden: false)
        buttons[ControlElement.btnY.rawValue] = ButtonLayout(centerX: diamondX - r, centerY: blocY,     isHidden: false)
        buttons[ControlElement.btnA.rawValue] = ButtonLayout(centerX: diamondX + r, centerY: blocY,     isHidden: false)
        // L / R / MIC / light sit on ONE horizontal line at the meet of the two screens (the
        // combined screen's vertical centre). Left gutter is an even HStack [Spacer, L, Spacer,
        // MIC, Spacer]; the right gutter mirrors it [Spacer, light, Spacer, R, Spacer] — R is the
        // mirror of L (outer), and the light decal is the mirror of MIC (inner, drawn by the skin).
        let lw = ControlElement.btnL.defaultNDSPortraitSize.width * k
        let lh = ControlElement.btnL.defaultNDSPortraitSize.height * k
        let micw = ControlElement.btnMic.defaultNDSPortraitSize.width * k
        let leftGutter = base.screen.minX
        let spacerL = max(0, (leftGutter - lw - micw) / 3)
        // Lower the whole bloc (top rail + row + bottom rail) so the TOP rail (L.top − spacerL/4)
        // lands on the lower screen's top = the screens' meet = the combined screen's vertical centre.
        // The rail↔row gap is spacerL/4 (half the previous spacerL/2).
        let rowY = (base.screen.midY + lh / 2 + spacerL / 4) / S
        let lCenter = spacerL + lw / 2
        let micCenter = 2 * spacerL + lw + micw / 2
        buttons[ControlElement.btnL.rawValue]   = ButtonLayout(centerX: lCenter / S,       centerY: rowY, isHidden: false)
        buttons[ControlElement.btnMic.rawValue] = ButtonLayout(centerX: micCenter / S,     centerY: rowY, isHidden: false)
        buttons[ControlElement.btnR.rawValue]   = ButtonLayout(centerX: (S - lCenter) / S, centerY: rowY, isHidden: false)
        return GBCardLayout(screen: base.screen, buttons: buttons, deviceScale: k)
    }
}

final class GBConsoleCardView: UIView {
    private let layout: GBCardLayout
    private let system: PresetSystem
    private let variant: DressVariant
    private let consoleSkin = ConsoleSkinView()
    private let controls: TouchControlsView

    init(layout: GBCardLayout, system: PresetSystem = .gbc, variant: DressVariant = .nostalgia) {
        self.layout = layout
        self.system = system
        self.variant = variant
        // NDS needs the X/Y/MIC buttons, which live on the NDS subclass.
        self.controls = TouchControlsView.make(for: system)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        addSubview(consoleSkin)
        controls.translatesAutoresizingMaskIntoConstraints = true
        addSubview(controls)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let S = bounds.width
        guard S > 0, bounds.height > 0 else { return }
        let k = layout.deviceScale

        let isNDS = system == .nds
        consoleSkin.frame = bounds
        consoleSkin.system = system
        consoleSkin.screenFrame = layout.screen
        // NDS reads its screen geometry from `ndsScreens`. The screenshot card splits the screens
        // (layout.ndsScreens holds the two rects, so the surround rim follows each); the clip +
        // combined path leave it empty and fall back to the single `screen` rect.
        consoleSkin.ndsScreens = isNDS ? (layout.ndsScreens.isEmpty ? [layout.screen] : layout.ndsScreens) : []
        consoleSkin.deviceScale = k
        consoleSkin.usesJoystick = false
        consoleSkin.variant = variant
        consoleSkin.hideABSeat = true        // no A/B seat relief on the card (GB/GBC; GBA/NDS ignore it)
        consoleSkin.cardMode = true          // card decoration placement (PHONES / speaker / brand)

        controls.frame = bounds              // full-card container: button fractions are of the card
        controls.layoutIfNeeded()
        controls.applyLayout(OrientationLayout(buttons: layout.buttons),
                             isLandscape: false, isNDS: isNDS, system: system, deviceScale: k,
                             opacity: 1.0, scale: 1.0, useJoystick: false)
        controls.setDressed(true, isLandscape: false, system: system, variant: variant)
        controls.layoutIfNeeded()
        consoleSkin.buttonFrames = controls.visibleButtonFrames(in: consoleSkin)
    }

    /// Lay the console out at `side`×`side` and snapshot it (no game screen, no info block — the
    /// renderer draws those on top). The A/B (ActionButton) and L/R (ShoulderButton) borders are
    /// removed first: `layer.render` strokes them as the button's SQUARE bounds (the "hitbox" lines
    /// around the buttons), so the card keeps only the rounded fill + the letter (+ shadow).
    /// Cache of the rendered console (body + dress + dressed controls) — it's identical for a
    /// given side + screen rect, so building it once makes Standard<->Pro toggles instant. Only the
    /// game screen + the info text (drawn by the renderer) are dynamic.
    private static var cache: [String: UIImage] = [:]

    static func image(layout: GBCardLayout, side: CGFloat,
                      system: PresetSystem = .gbc, variant: DressVariant = .nostalgia) -> UIImage {
        let key = "\(system.rawValue)-\(variant.cacheKey)-\(Int(side))-\(Int(layout.screen.width))x\(Int(layout.screen.height))"
        if let cached = cache[key] { return cached }

        let view = GBConsoleCardView(layout: layout, system: system, variant: variant)
        view.frame = CGRect(x: 0, y: 0, width: side, height: side)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        var stack: [UIView] = [view]
        while let v = stack.popLast() {
            if v is ActionButton || v is ShoulderButton { v.layer.borderWidth = 0 }
            v.setNeedsDisplay()
            stack.append(contentsOf: v.subviews)
        }
        let result = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            view.layer.render(in: ctx.cgContext)
        }
        cache[key] = result
        return result
    }
}
