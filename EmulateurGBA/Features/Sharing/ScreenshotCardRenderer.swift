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
        let totalPlayTimeSeconds: TimeInterval
        let isPro: Bool
    }

    // MARK: - Gamer Tier

    enum GamerTier: String {
        case rookie = "Rookie"
        case player = "Player"
        case veteran = "Veteran"
        case legend = "Legend"

        var emoji: String {
            switch self {
            case .rookie: return "🎮"
            case .player: return "⚡"
            case .veteran: return "🔥"
            case .legend: return "👑"
            }
        }

        var pillColor: UIColor {
            switch self {
            case .rookie: return UIColor(white: 0.3, alpha: 1)
            case .player: return UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            case .veteran: return UIColor(red: 0.5, green: 0.2, blue: 0.8, alpha: 1)
            case .legend: return UIColor(red: 0.85, green: 0.65, blue: 0.15, alpha: 1)
            }
        }

        static func from(totalSeconds: TimeInterval) -> GamerTier {
            let hours = totalSeconds / 3600
            if hours >= 100 { return .legend }
            if hours >= 25 { return .veteran }
            if hours >= 5 { return .player }
            return .rookie
        }
    }

    // MARK: - Colors

    private static let purple = UIColor(red: 0.45, green: 0.2, blue: 0.85, alpha: 1)
    private static let gold = UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 1)

    // MARK: - Render

    static func render(gameFrame: CGImage, info: GameInfo) -> UIImage? {
        let cardW: CGFloat = 1080
        let cardH: CGFloat = 1350
        let sidePadding: CGFloat = 60

        // Game frame dimensions — upscale to fit card width with padding
        let maxFrameW = cardW - sidePadding * 2
        let maxFrameH: CGFloat = 760  // Leave room for header + footer
        let nativeW = CGFloat(gameFrame.width)
        let nativeH = CGFloat(gameFrame.height)
        let scaleToFit = min(maxFrameW / nativeW, maxFrameH / nativeH)
        let frameW = nativeW * scaleToFit
        let frameH = nativeH * scaleToFit

        let size = CGSize(width: cardW, height: cardH)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

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

        // --- Glow effect behind the game frame ---
        let glowCenter = CGPoint(x: cardW / 2, y: 520)
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
        // TOP SECTION: App icon + "Retro Pal" (large, centered)
        // ============================================================

        let topY: CGFloat = 70
        let iconSize: CGFloat = 56

        // App icon centered
        if let icon = UIImage(named: "SharingIcon") {
            let iconX = (cardW - iconSize) / 2
            let iconRect = CGRect(x: iconX, y: topY, width: iconSize, height: iconSize)
            ctx.saveGState()
            UIBezierPath(roundedRect: iconRect, cornerRadius: 12).addClip()
            icon.draw(in: iconRect)
            ctx.restoreGState()
        }

        // "Retro Pal" large, gold, centered below icon
        let brandAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 40, weight: .heavy),
            .foregroundColor: gold
        ]
        let brandText = "Retro Pal"
        let brandSize = (brandText as NSString).size(withAttributes: brandAttrs)
        (brandText as NSString).draw(
            at: CGPoint(x: (cardW - brandSize.width) / 2, y: topY + iconSize + 16),
            withAttributes: brandAttrs
        )

        // ============================================================
        // MIDDLE SECTION: Game frame with neon bezel
        // ============================================================

        let bezelPadding: CGFloat = 8
        let bezelRadius: CGFloat = 16
        let gameX = (cardW - frameW) / 2
        let gameY = topY + iconSize + 16 + brandSize.height + 40

        // Bezel with purple border glow
        let bezelRect = CGRect(
            x: gameX - bezelPadding,
            y: gameY - bezelPadding,
            width: frameW + bezelPadding * 2,
            height: frameH + bezelPadding * 2
        )

        // Outer glow (drawn as a slightly larger rounded rect with blur)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 20, color: purple.withAlphaComponent(0.5).cgColor)
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

        // Neon purple border on bezel
        purple.withAlphaComponent(0.6).setStroke()
        let bezelPath = UIBezierPath(roundedRect: bezelRect, cornerRadius: bezelRadius)
        bezelPath.lineWidth = 2.5
        bezelPath.stroke()

        // ============================================================
        // BOTTOM SECTION: Game name, play time, badges, footer
        // ============================================================

        var cursorY = gameY + frameH + bezelPadding + 32

        // Game name — large, white, centered. The caller is responsible for
        // any title cleanup (ROM-header filename → user-friendly name); we
        // render whatever was passed verbatim so a user-renamed title keeps
        // its punctuation and casing intact.
        let gameNameAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 36, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let gameNameSize = (info.name as NSString).size(withAttributes: gameNameAttrs)
        (info.name as NSString).draw(
            at: CGPoint(x: (cardW - gameNameSize.width) / 2, y: cursorY),
            withAttributes: gameNameAttrs
        )
        cursorY += gameNameSize.height + 8

        // Play time — gold, centered
        let playHours = Int(info.playTimeSeconds / 3600)
        let playMins = Int(info.playTimeSeconds.truncatingRemainder(dividingBy: 3600) / 60)
        let timeStr: String
        if info.playTimeSeconds < 60 {
            timeStr = NSLocalizedString("screenshot.newGame", comment: "")
        } else if playHours > 0 {
            timeStr = String(format: NSLocalizedString("library.playTime", comment: ""), "\(playHours)", "\(playMins)")
        } else {
            timeStr = String(format: NSLocalizedString("library.playTime.minutes", comment: ""), "\(playMins)")
        }

        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 28, weight: .medium),
            .foregroundColor: gold
        ]
        let timeSize = (timeStr as NSString).size(withAttributes: timeAttrs)
        (timeStr as NSString).draw(
            at: CGPoint(x: (cardW - timeSize.width) / 2, y: cursorY),
            withAttributes: timeAttrs
        )
        cursorY += timeSize.height + 20

        // Badges row: tier badge + Pro badge side by side
        let tier = GamerTier.from(totalSeconds: info.totalPlayTimeSeconds)
        let showTier = tier != .rookie
        let showPro = info.isPro

        if showTier || showPro {
            // Calculate badge sizes to center them together
            let badgeFont = UIFont.systemFont(ofSize: 18, weight: .semibold)
            let badgePadH: CGFloat = 18
            let badgePadV: CGFloat = 9
            let badgeSpacing: CGFloat = 12

            var badges: [(text: String, color: UIColor)] = []
            if showTier {
                badges.append(("\(tier.emoji) \(tier.rawValue)", tier.pillColor))
            }
            if showPro {
                badges.append((NSLocalizedString("screenshot.proMember", comment: ""), gold))
            }

            // Measure total width
            var totalBadgeWidth: CGFloat = 0
            var badgeSizes: [CGSize] = []
            for badge in badges {
                let size = (badge.text as NSString).size(withAttributes: [.font: badgeFont])
                badgeSizes.append(size)
                totalBadgeWidth += size.width + badgePadH * 2
            }
            totalBadgeWidth += CGFloat(max(0, badges.count - 1)) * badgeSpacing

            var badgeX = (cardW - totalBadgeWidth) / 2

            for (i, badge) in badges.enumerated() {
                let textSize = badgeSizes[i]
                let pillRect = CGRect(
                    x: badgeX,
                    y: cursorY,
                    width: textSize.width + badgePadH * 2,
                    height: textSize.height + badgePadV * 2
                )

                if badge.text.contains("Pro Member") {
                    // Pro badge: gold with glow
                    ctx.saveGState()
                    ctx.setShadow(offset: .zero, blur: 12, color: gold.withAlphaComponent(0.5).cgColor)
                    ctx.setFillColor(gold.withAlphaComponent(0.2).cgColor)
                    UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2).fill()
                    ctx.restoreGState()

                    // Gold border
                    gold.withAlphaComponent(0.7).setStroke()
                    let borderPath = UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2)
                    borderPath.lineWidth = 1.5
                    borderPath.stroke()

                    // Text in gold
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: badgeFont,
                        .foregroundColor: gold
                    ]
                    (badge.text as NSString).draw(
                        at: CGPoint(x: pillRect.minX + badgePadH, y: pillRect.minY + badgePadV),
                        withAttributes: attrs
                    )
                } else {
                    // Tier badge: solid fill
                    ctx.setFillColor(badge.color.cgColor)
                    UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2).fill()
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: badgeFont,
                        .foregroundColor: UIColor.white
                    ]
                    (badge.text as NSString).draw(
                        at: CGPoint(x: pillRect.minX + badgePadH, y: pillRect.minY + badgePadV),
                        withAttributes: attrs
                    )
                }

                badgeX += pillRect.width + badgeSpacing
            }
        }

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

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}
