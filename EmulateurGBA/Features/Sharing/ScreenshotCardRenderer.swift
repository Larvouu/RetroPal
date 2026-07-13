//
//  ScreenshotCardRenderer.swift
//  EmulateurGBA
//
//  Renders a branded sharing card from a game frame.
//  Output: 1080x1350px (4:5 ratio). Purple/gold neon aesthetic
//  matching the Pro sheet — the card IS the brand.
//

import UIKit

struct ScreenshotCardRenderer {

    struct GameInfo {
        let name: String
        let playTimeSeconds: TimeInterval
        /// Real Pro ownership. The crown shows whenever this is true, INDEPENDENT of
        /// `style` — a Pro user on the Standard card UI keeps the crown.
        let isPro: Bool
        /// RetroAchievements points. When set, the stat line shows a gold star +
        /// "<points> pts" INSTEAD of the play time (the achievement share card);
        /// nil keeps the play-time line (screenshot + clip cards, unchanged).
        var points: Int? = nil
        /// Appended to the points value as " · <suffix>" (e.g. the localized
        /// "Completed" on a 100% per-game card). Only used with `points`.
        var statSuffix: String? = nil
    }

    // MARK: - Colors

    private static let purple = UIColor(red: 0.45, green: 0.2, blue: 0.85, alpha: 1)
    private static let gold = UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 1)

    /// 0xRRGGBB → opaque UIColor, for the metallic badge's gradient stops.
    private static func hex(_ v: Int) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255.0,
                green: CGFloat((v >> 8) & 0xFF) / 255.0,
                blue: CGFloat(v & 0xFF) / 255.0, alpha: 1)
    }

    // MARK: - Pro crown badge (metallic "gym badge")

    /// The crown silhouette filled with a vertical gradient, returned as an image.
    /// The gradient is drawn over `rect`, then masked to the crown's alpha with
    /// `.destinationIn`, so we get a crisp crown-shaped fill at any scale.
    private static func crownFilled(_ crown: UIImage, in rect: CGRect, canvas: CGSize,
                                    colors: [UIColor], locations: [CGFloat]) -> UIImage {
        UIGraphicsImageRenderer(size: canvas).image { r in
            let c = r.cgContext
            c.saveGState()
            c.clip(to: rect)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors.map { $0.cgColor } as CFArray,
                                  locations: locations) {
                c.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY),
                                     end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
            }
            c.restoreGState()
            crown.draw(in: rect, blendMode: .destinationIn, alpha: 1)
        }
    }

    /// Renders the Pro crown as a Pokémon-gym-style metal badge: a gold crown with
    /// a silver beveled rim (the "extruded" edge), a glossy top highlight, a 3D
    /// drop shadow and a warm gold halo. Square `side`, with extra margin around
    /// it for the glow so it isn't clipped. Icon only — no background, no text.
    static func proCrownBadgeImage(side: CGFloat) -> UIImage {
        let margin = side * 0.26
        let canvas = CGSize(width: side + margin * 2, height: side + margin * 2)
        let cfg = UIImage.SymbolConfiguration(pointSize: side * 0.74, weight: .bold)
        let crown = UIImage(systemName: "crown.fill", withConfiguration: cfg)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)

        return UIGraphicsImageRenderer(size: canvas).image { rctx in
            let ctx = rctx.cgContext
            guard let crown = crown else { return }

            // Aspect-fit the crown (wider than tall) into the square box.
            let box = CGRect(x: margin, y: margin, width: side, height: side)
            let cs = crown.size
            let fit = min(box.width / cs.width, box.height / cs.height)
            let cw = cs.width * fit, ch = cs.height * fit
            let crownRect = CGRect(x: box.midX - cw / 2, y: box.midY - ch / 2, width: cw, height: ch)

            // Bevel gradients: bright top → dark bottom with a re-brighten band, the
            // double-highlight that reads as polished metal.
            let silver: [UIColor] = [hex(0xFAFBFC), hex(0xC9CFD8), hex(0x99A1AD), hex(0xE9ECF1), hex(0x5C6470)]
            let silverLoc: [CGFloat] = [0, 0.38, 0.58, 0.82, 1]
            let goldStops: [UIColor] = [hex(0xFFF6D6), hex(0xFFD451), hex(0xE3A626), hex(0xFFE07C), hex(0xAE781B)]
            let goldLoc: [CGFloat] = [0, 0.34, 0.56, 0.78, 1]

            // Silver rim = the crown scaled up; the gold face nests inside it, so the
            // silver shows only as the edge.
            let rimScale: CGFloat = 1.16
            let rimRect = crownRect.insetBy(dx: -crownRect.width * (rimScale - 1) / 2,
                                            dy: -crownRect.height * (rimScale - 1) / 2)
            let rim = crownFilled(crown, in: rimRect, canvas: canvas, colors: silver, locations: silverLoc)
            let face = crownFilled(crown, in: crownRect, canvas: canvas, colors: goldStops, locations: goldLoc)
            let gloss = crownFilled(crown, in: crownRect, canvas: canvas,
                                    colors: [UIColor.white.withAlphaComponent(0.85),
                                             UIColor.white.withAlphaComponent(0.35),
                                             UIColor.white.withAlphaComponent(0.0)],
                                    locations: [0, 0.16, 0.5])

            // 3D lift: a dark drop shadow under the silver rim.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: side * 0.05), blur: side * 0.10,
                          color: UIColor.black.withAlphaComponent(0.5).cgColor)
            rim.draw(at: .zero)
            ctx.restoreGState()

            // Brilliance: a warm gold halo around the whole badge.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: side * 0.18, color: gold.withAlphaComponent(0.6).cgColor)
            rim.draw(at: .zero)
            ctx.restoreGState()

            // Gold face inside the silver rim, then the glossy top highlight.
            face.draw(at: .zero)
            gloss.draw(at: .zero)
        }
    }

    // MARK: - Shared card pieces (used by the screenshot card AND the clip card)

    /// The game-screen rect on the square (1080) Classic card: the native aspect fit
    /// into (side − 120) × 640, centred, at y = 174. This is the SAME rect the standard
    /// screenshot card draws (see `render`) and the GB/GBC console card anchors to
    /// (`GBCardLayout.screen`), so the screenshot, console and clip cards line up. The
    /// clip card (preview `neonCardBody` + export `compositeCard`) reads it from here so
    /// toggling Nostalgia <-> Classic never shifts the game / name / play-time row.
    static func standardGameScreenRect(side: CGFloat, gameNativeSize g: CGSize) -> CGRect {
        // Guard against zero only — NOT 1: callers pass the aspect as (aspect, 1), and a portrait
        // aspect < 1 (NDS = 0.667) must keep its ratio, not be clamped up to a square.
        let gw = max(g.width, 0.01), gh = max(g.height, 0.01)
        let fit = min((side - 120) / gw, 640 / gh)
        let fW = gw * fit, fH = gh * fit
        return CGRect(x: (side - fW) / 2, y: 174, width: fW, height: fH)
    }

    /// The Y centre of the play-time / crown / Pro-member line on the standard info block, for a
    /// max-font (un-shrunk) title — so the console cards can align their own components to that line.
    /// Mirrors the cursor math in `drawGBInfoBlock` (screen.maxY + 8 + 32, then the title, then +8).
    static func standardPlayLineCenterY(screen: CGRect) -> CGFloat {
        let titleLH = UIFont.systemFont(ofSize: 36, weight: .bold).lineHeight
        let ptLH = UIFont.systemFont(ofSize: 28, weight: .medium).lineHeight
        return screen.maxY + 8 + 32 + titleLH + 8 + ptLH / 2
    }

    /// The Retro Pal logo, centered, clipped to a rounded square — the brand
    /// anchor at the top of both cards. (The gold "Retro Pal" wordmark was
    /// dropped: the footer already names the app, more subtly.)
    static func drawLogo(in ctx: CGContext, cardW: CGFloat, y: CGFloat, size: CGFloat) {
        guard let icon = UIImage(named: "SharingIcon") else { return }
        let rect = CGRect(x: (cardW - size) / 2, y: y, width: size, height: size)
        ctx.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: 12).addClip()
        icon.draw(in: rect)
        ctx.restoreGState()
    }

    /// "Xh Ymin" / "Ymin" play-time string, or the "new game" label under 60s.
    /// Single source so the two cards format play time identically.
    static func playTimeString(seconds: TimeInterval) -> String {
        if seconds < 60 { return NSLocalizedString("screenshot.newGame", comment: "") }
        let hours = Int(seconds / 3600)
        let mins = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 {
            return String(format: NSLocalizedString("library.playTime", comment: ""), "\(hours)", "\(mins)")
        }
        return String(format: NSLocalizedString("library.playTime.minutes", comment: ""), "\(mins)")
    }

    /// Draw the game title centered at `y`, shrinking the font from 36pt down to
    /// 24pt to fit `maxWidth` on one line, then truncating with "…" if it still
    /// overflows. Returns the line height so the caller can advance its cursor.
    @discardableResult
    static func drawFittedTitle(_ title: String, cardW: CGFloat, y: CGFloat, maxWidth: CGFloat,
                               color: UIColor = .white) -> CGFloat {
        let maxFont: CGFloat = 36, minFont: CGFloat = 24
        var fontSize = maxFont
        var font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        while fontSize > minFont,
              (title as NSString).size(withAttributes: [.font: font]).width > maxWidth {
            fontSize -= 1
            font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let rect = CGRect(x: (cardW - maxWidth) / 2, y: y, width: maxWidth, height: font.lineHeight)
        (title as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para])
        return font.lineHeight
    }

    /// The horizontally-centred stat line every card carries below the game name,
    /// with its TOP at `y`: the play time, or — when `info.points` is set (the
    /// achievement card) — a gold star + "<points> pts". For Pro, the metal crown
    /// badge + "Pro member" label join it on the same line:
    ///     [★] <stat>   [crown]  Pro member
    /// One implementation for the Classic card and the console cards (the callers
    /// pass their ink: gold/muted-white on a dark body, the dark set on a light
    /// one). `fontSize` scales the whole line (the NDS separated card shrinks it
    /// to fit its gap); 28 is the standard cards' size.
    private static func drawStatLine(in ctx: CGContext, cardW: CGFloat, y: CGFloat, info: GameInfo,
                                     statColor: UIColor, labelColor: UIColor,
                                     fontSize: CGFloat = 28) {
        let k = fontSize / 28   // scale the separators with the font
        let statStr: NSString
        if let points = info.points {
            var text = "\(points) \(NSLocalizedString("ra.pointsSuffix", comment: ""))"
            if let suffix = info.statSuffix { text += " · \(suffix)" }
            statStr = text as NSString
        } else {
            statStr = playTimeString(seconds: info.playTimeSeconds) as NSString
        }
        let statAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: statColor]
        let statSize = statStr.size(withAttributes: statAttrs)
        let centerY = y + statSize.height / 2

        // The small gold star ahead of the points value (gold on every ink set —
        // it matches the badge glow inside the screen).
        var star: UIImage?
        var starAdvance: CGFloat = 0
        if info.points != nil {
            let cfg = UIImage.SymbolConfiguration(pointSize: statSize.height * 0.62, weight: .semibold)
            star = UIImage(systemName: "star.fill", withConfiguration: cfg)?
                .withTintColor(gold, renderingMode: .alwaysOriginal)
            starAdvance = (star?.size.width ?? 0) + 8
        }

        func drawStat(at x: CGFloat) {
            if let star {
                star.draw(at: CGPoint(x: x, y: centerY - star.size.height / 2))
            }
            statStr.draw(at: CGPoint(x: x + starAdvance, y: centerY - statSize.height / 2),
                         withAttributes: statAttrs)
        }

        if info.isPro {
            let cfg = UIImage.SymbolConfiguration(pointSize: 100, weight: .bold)
            let aspect = (UIImage(systemName: "crown.fill", withConfiguration: cfg)?.size)
                .map { $0.width / max($0.height, 1) } ?? 1.5
            let badgeSide = statSize.height * aspect   // crown ~ the stat-text height
            let emblem = proCrownBadgeImage(side: badgeSide)
            let emblemMargin = badgeSide * 0.26        // matches proCrownBadgeImage's glow margin

            let label = (NSLocalizedString("screenshot.proMember", comment: "")
                .replacingOccurrences(of: "👑", with: "")
                .trimmingCharacters(in: .whitespaces)) as NSString
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: labelColor]
            let lSize = label.size(withAttributes: labelAttrs)

            let sep: CGFloat = 20 * k   // little empty space between the stat and the badge
            let gap: CGFloat = 12 * k   // between the crown and its label
            let lineW = starAdvance + statSize.width + sep + badgeSide + gap + lSize.width
            var x = (cardW - lineW) / 2
            drawStat(at: x)
            x += starAdvance + statSize.width + sep
            emblem.draw(at: CGPoint(x: x - emblemMargin, y: centerY - emblem.size.height / 2))
            x += badgeSide + gap
            label.draw(at: CGPoint(x: x, y: centerY - lSize.height / 2), withAttributes: labelAttrs)
        } else {
            drawStat(at: (cardW - starAdvance - statSize.width) / 2)
        }
    }

    // MARK: - Pro treatment + card edge (shared by the screenshot AND clip cards)

    /// Nostalgia-only warm gold wash from the top: the ambient premium tell, matching
    /// the stats card. No-op for the Retro Pal style. Draw it right after the
    /// background gradient so the content sits on top.
    static func drawProWash(in ctx: CGContext, cardW: CGFloat, cardH: CGFloat, style: ShareCardStyle) {
        guard style == .nostalgia else { return }
        let center = CGPoint(x: cardW / 2, y: 0)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [gold.withAlphaComponent(0.07).cgColor, UIColor.clear.cgColor] as CFArray,
                              locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: cardW * 1.05, options: [])
        }
    }

    /// The surrounding edge line every shared card carries: a thin two-tone
    /// gold/purple line for Nostalgia, a subtle purple line otherwise. It defines the
    /// card's rounded outline so the card reads as a card on any background, and
    /// so the clip's rounded corners stay visible against its dark surround.
    /// Matches the stats card's edge. Draw it LAST (on top of everything).
    /// Inset slightly so the full stroke is visible inside the rounded clip.
    static func drawCardEdge(in ctx: CGContext, cardW: CGFloat, cardH: CGFloat,
                             cornerRadius: CGFloat, style: ShareCardStyle) {
        let inset: CGFloat = 2
        let lineWidth: CGFloat = 3
        let rect = CGRect(x: inset, y: inset, width: cardW - inset * 2, height: cardH - inset * 2)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius - inset)
        if style == .nostalgia {
            // Two-tone gold -> purple, stroked via a clipped gradient.
            ctx.saveGState()
            ctx.addPath(path.cgPath)
            ctx.setLineWidth(lineWidth)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [gold.withAlphaComponent(0.40).cgColor,
                                           purple.withAlphaComponent(0.40).cgColor] as CFArray,
                                  locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: cardW, y: cardH), options: [])
            }
            ctx.restoreGState()
        } else {
            purple.withAlphaComponent(0.45).setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        }
    }

    // MARK: - Render

    /// The console dress a card renders with for `style`, or nil for the neon
    /// Classic card. `.skin` mirrors the game's current dress (`skinVariant`,
    /// passed by the share views from the per-game skin context); a missing
    /// variant falls back to Nostalgia. Shared with the clip renderer + preview.
    static func consoleVariant(style: ShareCardStyle, skinVariant: DressVariant?) -> DressVariant? {
        switch style {
        case .nostalgia: return .nostalgia
        case .skin:      return skinVariant ?? .nostalgia
        case .retroPal:  return nil
        }
    }

    static func render(gameFrame: CGImage, info: GameInfo, style: ShareCardStyle,
                       system: PresetSystem = .gba, skinVariant: DressVariant? = nil) -> UIImage? {
        // The Nostalgia and "current skin" styles render as the actual console (body,
        // dressed controls, dress decorations — in the chosen dress's palette) with
        // the screenshot in the console screen. Classic keeps the branded card below.
        if let variant = consoleVariant(style: style, skinVariant: skinVariant) {
            let aspect = CGFloat(gameFrame.width) / CGFloat(max(gameFrame.height, 1))
            switch system {
            case .gbc:
                return gbConsoleCard(gameFrame: gameFrame, gameAspect: aspect, info: info, variant: variant)
            case .gba:
                return gbaConsoleCard(gameFrame: gameFrame, gameAspect: aspect, info: info, variant: variant)
            case .nds:
                return ndsConsoleCard(gameFrame: gameFrame, gameAspect: aspect, info: info,
                                      separatedScreens: true, variant: variant)
            }
        }

        let cardW: CGFloat = 1080
        let cardH: CGFloat = 1080   // square, harmonized with the clip + stats cards
        let sidePadding: CGFloat = 60
        // Rounded card on a pure-black surround, matching the stats + clip cards.
        let cardCorner: CGFloat = 48

        // Game frame dimensions — upscale to fit card width with padding
        let maxFrameW = cardW - sidePadding * 2
        let maxFrameH: CGFloat = 640  // Leave room for header + footer in the square card
        let nativeW = CGFloat(gameFrame.width)
        let nativeH = CGFloat(gameFrame.height)
        let scaleToFit = min(maxFrameW / nativeW, maxFrameH / nativeH)
        let frameW = nativeW * scaleToFit
        let frameH = nativeH * scaleToFit

        // Layout anchors (computed up front so the glow can center on the game).
        let topY: CGFloat = 70
        let iconSize: CGFloat = 56
        let bezelPadding: CGFloat = 8
        let bezelRadius: CGFloat = 16
        let gameX = (cardW - frameW) / 2
        let gameY = topY + iconSize + 48   // logo, gap, then the game frame

        let size = CGSize(width: cardW, height: cardH)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        // Pure-black surround with a rounded card clipped on top, so the card reads
        // as a card (matching the stats + clip cards). The opaque context + black
        // fill keeps the four corners SOLID black — never transparent, which is what
        // made the earlier transparency attempt show white corners when shared.
        UIColor.black.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.saveGState()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size),
                     cornerRadius: cardCorner).addClip()

        // --- Background: deep purple-dark gradient ---
        let bgTop = UIColor(red: 0.10, green: 0.06, blue: 0.18, alpha: 1)
        let bgBot = UIColor(red: 0.04, green: 0.02, blue: 0.08, alpha: 1)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [bgTop.cgColor, bgBot.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: cardH), options: [])
        }

        // Pro: faint warm gold wash from the top (no-op for standard), right after
        // the gradient so the content sits on top.
        drawProWash(in: ctx, cardW: cardW, cardH: cardH, style: style)

        // --- Glow effect behind the game frame ---
        let glowCenter = CGPoint(x: cardW / 2, y: gameY + frameH / 2)
        if let glowGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                purple.withAlphaComponent(0.25).cgColor,
                purple.withAlphaComponent(0.08).cgColor,
                UIColor.clear.cgColor
            ] as CFArray,
            locations: [0, 0.5, 1]
        ) {
            ctx.drawRadialGradient(glowGradient,
                startCenter: glowCenter, startRadius: 0,
                endCenter: glowCenter, endRadius: 500,
                options: [])
        }

        // ============================================================
        // TOP SECTION: Retro Pal logo — the sole element above the game frame.
        // (The gold wordmark was dropped; the footer already names the app.)
        // ============================================================

        drawLogo(in: ctx, cardW: cardW, y: topY, size: iconSize)

        // ============================================================
        // MIDDLE SECTION: Game frame with neon bezel
        // ============================================================

        // Bezel with purple border glow
        let bezelRect = CGRect(
            x: gameX - bezelPadding,
            y: gameY - bezelPadding,
            width: frameW + bezelPadding * 2,
            height: frameH + bezelPadding * 2
        )

        // Outer glow (drawn as a slightly larger rounded rect with blur). Light
        // glow, matching the thin clean inner bezel of the stats card.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 12, color: purple.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(UIColor(red: 0.08, green: 0.06, blue: 0.12, alpha: 1).cgColor)
        UIBezierPath(roundedRect: bezelRect, cornerRadius: bezelRadius).fill()
        ctx.restoreGState()

        // Bezel fill (on top, no shadow)
        ctx.setFillColor(UIColor(red: 0.08, green: 0.06, blue: 0.12, alpha: 1).cgColor)
        UIBezierPath(roundedRect: bezelRect, cornerRadius: bezelRadius).fill()

        // Game image: pre-convert from mGBA RGBX to RGBA
        let convertedGame: UIImage
        if let convertCtx = CGContext(
            data: nil, width: Int(frameW), height: Int(frameH),
            bitsPerComponent: 8, bytesPerRow: Int(frameW) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            convertCtx.interpolationQuality = .none
            convertCtx.draw(gameFrame, in: CGRect(x: 0, y: 0, width: frameW, height: frameH))
            if let converted = convertCtx.makeImage() {
                convertedGame = UIImage(cgImage: converted)
            } else {
                convertedGame = UIImage(cgImage: gameFrame)
            }
        } else {
            convertedGame = UIImage(cgImage: gameFrame)
        }

        let gameRect = CGRect(x: gameX, y: gameY, width: frameW, height: frameH)
        ctx.saveGState()
        UIBezierPath(roundedRect: gameRect, cornerRadius: bezelRadius - 4).addClip()
        convertedGame.draw(in: gameRect)
        ctx.restoreGState()

        // Thin neon purple border on bezel (matches the stats card's clean inner frame).
        purple.withAlphaComponent(0.6).setStroke()
        let bezelPath = UIBezierPath(roundedRect: bezelRect, cornerRadius: bezelRadius)
        bezelPath.lineWidth = 1.5
        bezelPath.stroke()

        // ============================================================
        // BOTTOM SECTION: Game name, play time (+ Pro crown line), footer
        // ============================================================

        var cursorY = gameY + frameH + bezelPadding + 32

        // Game name — centered, shrinks then truncates with "…" for long titles.
        // The caller passes the display name verbatim (user rename respected).
        cursorY += drawFittedTitle(info.name, cardW: cardW, y: cursorY,
                                   maxWidth: cardW - sidePadding * 2) + 8

        // Stat line (play time, or star + points on the achievement card). For Pro,
        // the metal crown badge + "Pro member" label join it on ONE horizontally-
        // centered line, mirroring the clip card. The crown follows real Pro
        // ownership (info.isPro), NOT the card style — a Pro user on the Standard UI
        // keeps it. (Nothing sits between this line and the footer; the cards match.)
        drawStatLine(in: ctx, cardW: cardW, y: cursorY, info: info,
                     statColor: gold, labelColor: UIColor.white.withAlphaComponent(0.55))

        // Footer — "Retro Pal on the App Store"
        let footerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.55)
        ]
        let footerText = NSLocalizedString("screenshot.footer", comment: "")
        let footerSize = (footerText as NSString).size(withAttributes: footerAttrs)
        (footerText as NSString).draw(
            at: CGPoint(x: (cardW - footerSize.width) / 2, y: cardH - 56 - footerSize.height),
            withAttributes: footerAttrs
        )

        ctx.restoreGState()   // end the rounded-card clip; the corners stay black

        // Surrounding card edge (two-tone gold for Pro, subtle purple otherwise),
        // tracing the rounded outline so the card reads against the black surround.
        // Matches the stats + clip cards.
        drawCardEdge(in: ctx, cardW: cardW, cardH: cardH, cornerRadius: cardCorner, style: style)

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    // MARK: - GB/GBC console card (Pro)

    /// The Pro GB/GBC card: the console dress fills the square, with the game in the GB screen (a
    /// screenshot, or one clip frame, or nothing = chrome only for the live clip preview), plus the
    /// game name + play-time / crown / Pro-member line and the unicolor surround edge. Shared by the
    /// screenshot card and both clip paths (export per-frame + live-preview chrome). `variant` picks
    /// the dress palette (Nostalgia / Retro Pal / a user custom skin); the info ink and the card
    /// edge follow it (dark ink on a light body, the light set on a dark one).
    static func gbConsoleCard(gameFrame: CGImage?, gameAspect: CGFloat, info: GameInfo,
                              variant: DressVariant = .nostalgia) -> UIImage? {
        let cardW: CGFloat = 1080, cardH: CGFloat = 1080
        let cardCorner: CGFloat = 48
        let size = CGSize(width: cardW, height: cardH)

        let layout = GBCardLayout.make(side: cardW, gameNativeSize: CGSize(width: gameAspect, height: 1))
        let console = GBConsoleCardView.image(layout: layout, side: cardW, variant: variant)

        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        // Black surround + rounded-card clip (matches the other cards).
        UIColor.black.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.saveGState()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cardCorner).addClip()

        console.draw(in: CGRect(origin: .zero, size: size))   // body + dress fill the card

        // The game frame, drawn into the GB screen via CGContext (the same RGBX->RGBA conversion the
        // standard card uses). Skipped for the live clip preview, which overlays the looping clip.
        if let gameFrame {
            let game = cleanGameImage(gameFrame, target: layout.screen.size)
            ctx.saveGState()
            UIBezierPath(roundedRect: layout.screen, cornerRadius: 6).addClip()
            game.draw(in: layout.screen)
            ctx.restoreGState()
        }

        // Game name + play time + crown + "Pro member", at the standard card's size + position.
        // Ink follows the body: the default dark set on a light body (Nostalgia DMG grey), the
        // standard card's light set (white / gold / muted white) on a dark custom body.
        if variant.bodyColor(for: .gbc).rpLuminance > 0.5 {
            drawGBInfoBlock(in: ctx, cardW: cardW, screen: layout.screen, info: info)
        } else {
            drawGBInfoBlock(in: ctx, cardW: cardW, screen: layout.screen, info: info,
                            titleColor: .white, playTimeColor: gold,
                            labelColor: UIColor.white.withAlphaComponent(0.55))
        }

        ctx.restoreGState()

        // Unicolor card edge in the dress's screen-surround colour (#6D6D6D for Nostalgia) — not
        // the gold/purple gradient.
        let inset: CGFloat = 2
        let edgeRect = CGRect(x: inset, y: inset, width: cardW - inset * 2, height: cardH - inset * 2)
        let edgePath = UIBezierPath(roundedRect: edgeRect, cornerRadius: cardCorner - inset)
        variant.cardEdgeColor(for: .gbc).setStroke()
        edgePath.lineWidth = 3
        edgePath.stroke()

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    // MARK: - GBA console card (Nostalgia)

    /// The GBA Nostalgia card: the GBA console dress fills the square — the shared components
    /// (D-pad, A/B, SELECT/START, speaker, brand) sit at the GB/GBC card positions, in the GBA
    /// dress, plus the GBA-only L/R + POWER. The game sits in the screen, then the name + play-time /
    /// crown / Pro-member line, and the card edge in the GBA SURROUND colour (#0E0E10). First dynamic
    /// cut: positions live in GBCardLayout.gba + GameBoyAdvanceSkin.cardMode, tuned on device.
    static func gbaConsoleCard(gameFrame: CGImage?, gameAspect: CGFloat, info: GameInfo,
                               variant: DressVariant = .nostalgia) -> UIImage? {
        let cardW: CGFloat = 1080, cardH: CGFloat = 1080
        let cardCorner: CGFloat = 48
        let size = CGSize(width: cardW, height: cardH)

        let layout = GBCardLayout.gba(side: cardW, gameNativeSize: CGSize(width: gameAspect, height: 1))
        let console = GBConsoleCardView.image(layout: layout, side: cardW, system: .gba, variant: variant)

        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        UIColor.black.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.saveGState()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cardCorner).addClip()

        console.draw(in: CGRect(origin: .zero, size: size))   // body + dress fill the card

        if let gameFrame {
            let game = cleanGameImage(gameFrame, target: layout.screen.size)
            ctx.saveGState()
            UIBezierPath(roundedRect: layout.screen, cornerRadius: 6).addClip()
            game.draw(in: layout.screen)
            ctx.restoreGState()
        }

        // Ink follows the body: the light set (white title, gold play time, muted-white label) on
        // the dark Nostalgia GBA purple; the dark set on a light custom body.
        if variant.bodyColor(for: .gba).rpLuminance > 0.5 {
            drawGBInfoBlock(in: ctx, cardW: cardW, screen: layout.screen, info: info)
        } else {
            drawGBInfoBlock(in: ctx, cardW: cardW, screen: layout.screen, info: info,
                            titleColor: .white, playTimeColor: gold,
                            labelColor: UIColor.white.withAlphaComponent(0.55))
        }

        ctx.restoreGState()

        // Card edge = the dress's screen SURROUND colour (#0E0E10 for Nostalgia), the bezel framing
        // the whole card.
        let inset: CGFloat = 2
        let edgeRect = CGRect(x: inset, y: inset, width: cardW - inset * 2, height: cardH - inset * 2)
        let edgePath = UIBezierPath(roundedRect: edgeRect, cornerRadius: cardCorner - inset)
        variant.cardEdgeColor(for: .gba).setStroke()
        edgePath.lineWidth = 3
        edgePath.stroke()

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    // MARK: - NDS console card (Nostalgia)

    /// The NDS Nostalgia card: the NDS console dress fills the square. The stacked dual-screen image
    /// (256×384) sits in ONE combined screen rect at the standard size (same height as the GBA card,
    /// ratio intact), with the shared components — game name / play time / crown / Pro-member row —
    /// below it, and the NDS set around: D-pad, A/B/X/Y, L/R, SELECT/START, MIC, the "light" + two
    /// speakers, and the brand above the screen. The NDS body is light grey, so the info block uses
    /// the default dark ink (like GB/GBC). Card edge = the NDS screen surround (#777777). First
    /// dynamic cut: positions live in GBCardLayout.nds + NintendoDSSkin.cardMode, tuned on device.
    static func ndsConsoleCard(gameFrame: CGImage?, gameAspect: CGFloat, info: GameInfo,
                               separatedScreens: Bool = false,
                               variant: DressVariant = .nostalgia) -> UIImage? {
        let cardW: CGFloat = 1080, cardH: CGFloat = 1080
        let cardCorner: CGFloat = 48
        let size = CGSize(width: cardW, height: cardH)

        let layout = GBCardLayout.nds(side: cardW, gameNativeSize: CGSize(width: gameAspect, height: 1),
                                      separatedScreens: separatedScreens)
        let console = GBConsoleCardView.image(layout: layout, side: cardW, system: .nds, variant: variant)

        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        UIColor.black.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.saveGState()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cardCorner).addClip()

        console.draw(in: CGRect(origin: .zero, size: size))   // body + dress fill the card

        if let gameFrame {
            if layout.ndsScreens.count == 2 {
                // Screenshot card: the two screens were split + placed by GBCardLayout.nds (the
                // surround rim follows each via NintendoDSSkin.drawScreenOutlines). Draw the top half
                // of the stacked frame into the upper rect and the bottom half into the lower rect.
                let upper = layout.ndsScreens[0], lower = layout.ndsScreens[1]
                let H = gameFrame.height
                let topHalf = gameFrame.cropping(to: CGRect(x: 0, y: 0, width: gameFrame.width, height: H / 2))
                let bottomHalf = gameFrame.cropping(to: CGRect(x: 0, y: H / 2, width: gameFrame.width, height: H - H / 2))
                func drawScreen(_ cg: CGImage?, into rect: CGRect) {
                    guard let cg else { return }
                    let img = cleanGameImage(cg, target: rect.size)
                    ctx.saveGState()
                    UIBezierPath(roundedRect: rect, cornerRadius: 6).addClip()
                    img.draw(in: rect)
                    ctx.restoreGState()
                }
                drawScreen(topHalf, into: upper)
                drawScreen(bottomHalf, into: lower)
            } else {
                // Combined-screen path (NDS clip chrome / fallback): the stacked frame in one rect.
                let game = cleanGameImage(gameFrame, target: layout.screen.size)
                ctx.saveGState()
                UIBezierPath(roundedRect: layout.screen, cornerRadius: 6).addClip()
                game.draw(in: layout.screen)
                ctx.restoreGState()
            }
        }

        // Info ink follows the body: dark on the light Nostalgia grey (like GB/GBC), the light set
        // on a dark body (Retro Pal / a dark custom). The separated screenshot card splits the info:
        // the game name becomes the 5th element of the centred components row, and the play-time /
        // crown / Pro-member line sits between the bottom rail and the lower screen. The combined /
        // clip card keeps the standard stacked block.
        let lightBody = variant.bodyColor(for: .nds).rpLuminance > 0.5
        if layout.ndsScreens.count == 2 {
            // Anchors mirror GBCardLayout.nds (separated path): row centred on the card; bottom rail
            // at rowCentre + lh/2 + spacerL/4.
            let k = layout.deviceScale
            let lh = ControlElement.btnL.defaultNDSPortraitSize.height * k
            let lw = ControlElement.btnL.defaultNDSPortraitSize.width * k
            let micw = ControlElement.btnMic.defaultNDSPortraitSize.width * k
            let spacerL = max(0, (layout.screen.minX - lw - micw) / 3)
            let rowCenterY = cardH / 2
            let bottomRailY = rowCenterY + lh / 2 + spacerL / 4
            drawNDSSeparatedInfo(in: ctx, cardW: cardW, info: info, rowCenterY: rowCenterY,
                                 componentsLineHeight: lh, bottomRailY: bottomRailY,
                                 lowerScreenTop: layout.ndsScreens[1].minY,
                                 titleColor: lightBody ? UIColor(white: 0.12, alpha: 0.92) : .white,
                                 mutedColor: lightBody ? UIColor(white: 0.12, alpha: 0.75)
                                                       : UIColor.white.withAlphaComponent(0.55))
        } else if lightBody {
            drawGBInfoBlock(in: ctx, cardW: cardW, screen: layout.screen, info: info)
        } else {
            drawGBInfoBlock(in: ctx, cardW: cardW, screen: layout.screen, info: info,
                            titleColor: .white, playTimeColor: gold,
                            labelColor: UIColor.white.withAlphaComponent(0.55))
        }

        ctx.restoreGState()

        // Card edge = the dress's structure ink (#777777 for the built-ins; derived from the body
        // for a custom skin), the bezel framing the whole card.
        let inset: CGFloat = 2
        let edgeRect = CGRect(x: inset, y: inset, width: cardW - inset * 2, height: cardH - inset * 2)
        let edgePath = UIBezierPath(roundedRect: edgeRect, cornerRadius: cardCorner - inset)
        variant.cardEdgeColor(for: .nds).setStroke()
        edgePath.lineWidth = 3
        edgePath.stroke()

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    /// Game name + the play-time / crown / "Pro member" line, at the SAME size and position as the
    /// standard card (computed off the screen rect the same way). Colours default to the dark ink
    /// that reads on the light DMG-grey GB/GBC body; a dark-bodied console (GBA) passes the standard
    /// card's light palette (white title, gold play time, muted-white label). The crown stays metal.
    private static func drawGBInfoBlock(in ctx: CGContext, cardW: CGFloat, screen: CGRect, info: GameInfo,
                                        titleColor: UIColor = UIColor(white: 0.12, alpha: 0.92),
                                        playTimeColor: UIColor = UIColor(white: 0.12, alpha: 0.75),
                                        labelColor: UIColor = UIColor(white: 0.12, alpha: 0.75)) {
        let sidePadding: CGFloat = 60
        let bezelPadding: CGFloat = 8

        // Same cursor as the standard card: below the framed screen.
        var cursorY = screen.maxY + bezelPadding + 32
        cursorY += drawFittedTitle(info.name, cardW: cardW, y: cursorY,
                                   maxWidth: cardW - sidePadding * 2, color: titleColor) + 8

        drawStatLine(in: ctx, cardW: cardW, y: cursorY, info: info,
                     statColor: playTimeColor, labelColor: labelColor)
    }

    /// NDS SEPARATED screenshot card only. The standard stacked info block is split in two:
    /// - the game name becomes the "5th component" of the centred components row — centred
    ///   horizontally (unchanged), centred vertically on the row, sized so its line height matches
    ///   the components line height;
    /// - the play-time / crown / Pro-member line is centred horizontally (unchanged) and vertically
    ///   in the gap between the bottom rail and the lower screen, shrunk to fit that gap if needed.
    /// Ink colours follow the body (dark on the light Nostalgia grey, light on a dark custom body).
    /// The shared `drawGBInfoBlock` is left untouched so the Classic, GB/GBC, GBA and NDS-clip
    /// cards are unaffected.
    private static func drawNDSSeparatedInfo(in ctx: CGContext, cardW: CGFloat, info: GameInfo,
                                             rowCenterY: CGFloat, componentsLineHeight: CGFloat,
                                             bottomRailY: CGFloat, lowerScreenTop: CGFloat,
                                             titleColor: UIColor = UIColor(white: 0.12, alpha: 0.92),
                                             mutedColor: UIColor = UIColor(white: 0.12, alpha: 0.75)) {
        let sidePadding: CGFloat = 60
        let dark = titleColor
        let darkMuted = mutedColor

        // --- Game name: line height == components line height, then shrink to fit the width. -------
        let maxWidth = cardW - sidePadding * 2
        let probe = UIFont.systemFont(ofSize: 100, weight: .bold)
        let lhPerPoint = probe.lineHeight / 100
        var titlePt = max(8, componentsLineHeight / max(lhPerPoint, 0.01))
        let title = info.name as NSString
        while titlePt > 8,
              title.size(withAttributes: [.font: UIFont.systemFont(ofSize: titlePt, weight: .bold)]).width > maxWidth {
            titlePt -= 1
        }
        let titleFont = UIFont.systemFont(ofSize: titlePt, weight: .bold)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        title.draw(in: CGRect(x: (cardW - maxWidth) / 2, y: rowCenterY - titleFont.lineHeight / 2,
                              width: maxWidth, height: titleFont.lineHeight),
                   withAttributes: [.font: titleFont, .foregroundColor: dark, .paragraphStyle: para])

        // --- Stat / crown / Pro-member line: fit the gap below the bottom rail. --------------------
        // Delegated to the shared drawStatLine (same math, scaled font), which
        // also brings the RA points/star/"Completed" variant to the NDS card.
        let gap = max(1, lowerScreenTop - bottomRailY)
        let centerY = (bottomRailY + lowerScreenTop) / 2
        let basePt: CGFloat = 28
        let baseLH = UIFont.systemFont(ofSize: basePt, weight: .medium).lineHeight
        let ptFontSize = baseLH > gap * 0.9 ? basePt * (gap * 0.9 / baseLH) : basePt

        let statLH = UIFont.systemFont(ofSize: ptFontSize, weight: .medium).lineHeight
        drawStatLine(in: ctx, cardW: cardW, y: centerY - statLH / 2, info: info,
                     statColor: darkMuted, labelColor: darkMuted, fontSize: ptFontSize)
    }

    /// The shared info block (game name + play-time / crown / "Pro member") rendered onto a
    /// transparent card-size image with the light palette (white title, gold play time, muted-white
    /// label). The SwiftUI clip Classic preview overlays this so its block is byte-identical — size,
    /// position and colour — to the CG screenshot card and the baked export (all four go through
    /// `drawGBInfoBlock`). Position is the standard cursor (screen.maxY + 8 + 32).
    static func classicInfoImage(side: CGFloat, screen: CGRect, info: GameInfo) -> UIImage? {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1; fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { rctx in
            drawGBInfoBlock(in: rctx.cgContext, cardW: side, screen: screen, info: info,
                            titleColor: .white, playTimeColor: gold,
                            labelColor: UIColor.white.withAlphaComponent(0.55))
        }
    }

    /// mGBA frames are RGBX (no real alpha). Redraw opaque at the target size with the SAME
    /// premultiplied-RGBA conversion the standard card uses, so the screen renders with correct
    /// colours (the earlier noneSkipLast path drew black).
    private static func cleanGameImage(_ cg: CGImage, target: CGSize) -> UIImage {
        let w = max(1, Int(target.width.rounded())), h = max(1, Int(target.height.rounded()))
        if let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                             bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            c.interpolationQuality = .none
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let out = c.makeImage() { return UIImage(cgImage: out) }
        }
        return UIImage(cgImage: cg)
    }
}
