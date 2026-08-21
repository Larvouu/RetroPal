//
//  RAShareCardView.swift
//  EmulateurGBA
//
//  The shareable card for ONE earned achievement, harmonized with the
//  screenshot / clip cards: the game's console dress fills the square card
//  (Nostalgia, the game's current skin, or the Classic neon card — the same
//  per-game style choice), and the CONSOLE SCREEN plays the role the game
//  frame has on the screenshot card. On that screen: the achievement badge
//  (its artbox) over the blurred box art, the title, the description, the
//  % of players who earned it, and a small RetroAchievements credit. Below
//  the screen, at the screenshot card's exact positions: the OFFICIAL RA
//  game name and a gold star + points line standing in for the play time
//  (with the crown + "Pro member" joining it for Pro owners).
//
//  `RAConsoleCardRenderer` is the shared core for ALL the RA console-skin
//  cards (this one + the per-game card): it composes a SwiftUI screen image
//  at the exact screen-rect pixel size and hands it to
//  `ScreenshotCardRenderer.render`, so the console geometry, the ink-follows-
//  body logic and the card edge stay pixel-identical to the screenshot card.
//

import SwiftUI

/// Shared core for the RA console-skin cards (achievement + per-game): compute
/// the console screen's size, compose the given SwiftUI screen content at its
/// exact pixel size, and pipe it through `ScreenshotCardRenderer.render` as the
/// game frame, with the RA stat line (gold star + points) below the game name.
enum RAConsoleCardRenderer {

    /// The console screen's pixel size on the 1080 card for `system` (GB/GBC
    /// 160×144, GBA 240×160; nil → the Classic card's 3:2). NDS returns the
    /// STACKED dual-screen size (the two 1.2×-scaled separated screens of the
    /// screenshot card; the renderer splits the composed image at half height,
    /// top half → upper screen, bottom half → touch screen). Identical for the
    /// dress and Classic styles: the console layouts anchor their screen to the
    /// standard card's rect.
    /// The standard-card screen rect for a system's native frame aspect.
    private static func baseScreenSize(system: PresetSystem?) -> CGSize {
        let native: CGSize
        switch system {
        case .gbc: native = CGSize(width: 160, height: 144)
        case .nds: native = CGSize(width: 256, height: 384)
        // 4:3, the shape these two were drawn for — not their buffer's own ratio.
        case .snes, .nes: native = CGSize(width: 4, height: 3)
        default:   native = CGSize(width: 240, height: 160)
        }
        let aspect = CGSize(width: native.width / native.height, height: 1)
        return ScreenshotCardRenderer.standardGameScreenRect(side: 1080, gameNativeSize: aspect).size
    }

    static func screenPixelSize(system: PresetSystem?) -> CGSize {
        let base = baseScreenSize(system: system)
        // NDS separated screens: each is 1.2× half the combined rect (see
        // GBCardLayout.nds), so the stacked source is the combined rect × 1.2.
        if system == .nds {
            return CGSize(width: base.width * 1.2, height: base.height * 1.2)
        }
        return base
    }

    /// The screen content's SwiftUI design size (rendered at scale 3).
    static func screenPointSize(system: PresetSystem?) -> CGSize {
        let px = screenPixelSize(system: system)
        return CGSize(width: px.width / 3, height: px.height / 3)
    }

    /// Render the 1080×1080 card. `system` nil (unknown game) forces the
    /// Classic card; otherwise `style` picks the dress exactly like the
    /// screenshot card (`.skin` mirrors `skinVariant`, nil falls back to
    /// Nostalgia). `screen` builds the screen content for its point size —
    /// for NDS that content is the STACKED pair (design each half as one
    /// screen; the split is exactly at half height).
    @MainActor
    static func render<Screen: View>(gameName: String, points: Int, isPro: Bool,
                                     statSuffix: String? = nil,
                                     style: ShareCardStyle, system: PresetSystem?,
                                     skinVariant: DressVariant?,
                                     @ViewBuilder screen: (CGSize) -> Screen) -> UIImage? {
        let sys = system ?? .gba
        let effStyle: ShareCardStyle = (system == nil) ? .retroPal : style

        // Composed at exactly the screen-rect pixel size, so the renderer's
        // nearest-neighbour draw into the screen rect is 1:1 lossless. The NDS
        // CLASSIC card shows the stacked pair in ONE bezel at the standard
        // rect (smaller than the separated console screens) — compose at that
        // size so nothing gets nearest-neighbour downscaled.
        let ndsClassic = (sys == .nds)
            && ScreenshotCardRenderer.consoleVariant(style: effStyle, skinVariant: skinVariant) == nil
        let px = ndsClassic ? baseScreenSize(system: system) : screenPixelSize(system: system)
        let renderer = ImageRenderer(content: screen(CGSize(width: px.width / 3, height: px.height / 3)))
        renderer.scale = 3
        guard let screenCG = renderer.uiImage?.cgImage else { return nil }

        let info = ScreenshotCardRenderer.GameInfo(name: gameName, playTimeSeconds: 0,
                                                   isPro: isPro, points: points,
                                                   statSuffix: statSuffix)
        return ScreenshotCardRenderer.render(gameFrame: screenCG, info: info,
                                             style: effStyle, system: sys, skinVariant: skinVariant)
    }
}

struct RAAchievementCardRenderer {

    /// Everything the card shows. Images are passed in already loaded
    /// (AsyncImage can't render into an ImageRenderer snapshot).
    struct Content {
        let badge: UIImage?
        let boxArt: UIImage?
        let title: String
        let detail: String
        let points: Int
        let rarity: Double   // % of players who earned it (0 = unknown)
        /// The OFFICIAL RetroAchievements set name, never the library rename.
        let gameName: String
        let isPro: Bool
    }

    @MainActor
    static func render(content: Content, style: ShareCardStyle,
                       system: PresetSystem?, skinVariant: DressVariant?) -> UIImage? {
        RAConsoleCardRenderer.render(gameName: content.gameName, points: content.points,
                                     isPro: content.isPro, style: style,
                                     system: system, skinVariant: skinVariant) { size in
            RAAchievementScreenView(content: content, size: size,
                                    dualScreen: system == .nds)
        }
    }
}

/// What the console screen displays: the badge hero over the blurred box art,
/// with the achievement's title, description and rarity. Sized in points at a
/// third of the target pixel size (rendered at scale 3). `dualScreen` (NDS)
/// composes the STACKED pair — the unlock header + badge on the top screen,
/// the words on the touch screen; the renderer splits at exactly half height.
struct RAAchievementScreenView: View {
    let content: RAAchievementCardRenderer.Content
    let size: CGSize
    var dualScreen: Bool = false

    private static let gold = Color(red: 0.98, green: 0.80, blue: 0.36)

    private var rarityText: String? {
        guard content.rarity > 0 else { return nil }
        let pct = content.rarity >= 10 ? String(format: "%.0f%%", content.rarity)
                                       : String(format: "%.1f%%", content.rarity)
        return String(format: String(localized: "ra.dashboard.rarity", defaultValue: "%@ of players"), pct)
    }

    var body: some View {
        Group {
            if dualScreen {
                dualBody
            } else {
                singleBody
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// Backdrop for one screen: the box art blurred + dimmed over a near-black
    /// purple, so every game tints its own screen (the pre-redesign card's trick).
    private func backdrop(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color(red: 0.05, green: 0.03, blue: 0.10)
            if let boxArt = content.boxArt {
                Image(uiImage: boxArt)
                    .resizable().scaledToFill()
                    .frame(width: width, height: height)
                    .blur(radius: 16)
                    .opacity(0.45)
            }
            LinearGradient(colors: [.black.opacity(0.30), .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private var singleBody: some View {
        ZStack {
            backdrop(width: size.width, height: size.height)

            VStack(spacing: 6) {
                unlockedHeader
                badgeView.frame(width: 70, height: 70)
                titleText
                detailText
                rarityLine
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            creditPinnedBottom
        }
    }

    /// NDS: top screen = the celebration (header + badge hero), touch screen =
    /// the words (title, description, rarity, credit). Each half is designed as
    /// its own screen; the badge shrinks with the half when the Classic card's
    /// smaller stacked rect is composed.
    private var dualBody: some View {
        let halfH = size.height / 2
        let badgeSide = min(74, halfH * 0.58)
        return VStack(spacing: 0) {
            ZStack {
                backdrop(width: size.width, height: halfH)
                VStack(spacing: 8) {
                    unlockedHeader
                    badgeView.frame(width: badgeSide, height: badgeSide)
                }
                .padding(10)
            }
            .frame(width: size.width, height: halfH)
            .clipped()

            ZStack {
                backdrop(width: size.width, height: halfH)
                VStack(spacing: 5) {
                    titleText
                    detailText
                    rarityLine
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                creditPinnedBottom
            }
            .frame(width: size.width, height: halfH)
            .clipped()
        }
    }

    // MARK: - Pieces (shared by both screen shapes)

    private var unlockedHeader: some View {
        Text(String(localized: "ra.card.unlocked", defaultValue: "ACHIEVEMENT UNLOCKED"))
            .font(.system(size: 10.5, weight: .heavy)).tracking(1.8)
            .foregroundStyle(Self.gold)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var titleText: some View {
        Text(content.title)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center).lineLimit(2)
            .minimumScaleFactor(0.75)
    }

    private var detailText: some View {
        Text(content.detail)
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center).lineLimit(3)
            .minimumScaleFactor(0.8)
    }

    @ViewBuilder private var rarityLine: some View {
        if let rarityText {
            Text(rarityText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var creditPinnedBottom: some View {
        VStack {
            Spacer(minLength: 0)
            Text("RetroAchievements")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 3)
        }
    }

    @ViewBuilder private var badgeView: some View {
        // Raw square badge, as RA serves it; only the gold glow remains.
        Group {
            if let badge = content.badge {
                Image(uiImage: badge).resizable().scaledToFit()
            } else {
                Image(systemName: "trophy.fill").resizable().scaledToFit().padding(10)
                    .foregroundStyle(Self.gold)
            }
        }
        .shadow(color: Self.gold.opacity(0.5), radius: 9)
    }
}
