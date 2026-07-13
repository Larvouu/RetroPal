//
//  RAGameShareView.swift
//  EmulateurGBA
//
//  The shareable per-game RetroAchievements card, harmonized with the
//  achievement + screenshot cards: the game's console dress fills the square
//  card (same per-game style choice: current skin / Nostalgia / Classic), and
//  the CONSOLE SCREEN shows the earned set — "ACHIEVEMENTS", the "X of Y
//  unlocked" summary, and an ADAPTIVE grid of only the unlocked achievements'
//  artboxes over the blurred box art (the grid solver fits any count; sets
//  that outgrow the screen fold into a "+N" chip). Below the screen: the
//  official RA game name + the gold star / earned-points line (crown + "Pro
//  member" for Pro owners). Opened from the in-game dashboard's share button
//  and from a game's "Share your progress" row in the library profile.
//
//  (The old flat card's ProgressView could not render inside ImageRenderer —
//  it exported as a broken 100% bar with a stray glyph. Gone with the redesign.)
//

import SwiftUI

/// Largest-cell layout for a badge grid: scan the column counts and keep the
/// one that yields the biggest square cell fitting `cells` in `area`. Two
/// spacing tiers: airy 5pt while the badges stay comfortably big, tight 2pt
/// once a large set (a full Fire-Red-sized 157) needs every point of surface —
/// the whole set fits as a mosaic instead of folding into the chip.
struct RABadgeGridSpec {
    let columns: Int
    let side: CGFloat
    let spacing: CGFloat

    static func fit(cells: Int, in area: CGSize, maxSide: CGFloat = 40) -> RABadgeGridSpec {
        let spacious = solve(cells: cells, in: area, spacing: 5, maxSide: maxSide)
        if spacious.side >= 16 { return spacious }
        return solve(cells: cells, in: area, spacing: 2, maxSide: maxSide)
    }

    private static func solve(cells: Int, in area: CGSize, spacing: CGFloat,
                              maxSide: CGFloat) -> RABadgeGridSpec {
        guard cells > 0 else { return RABadgeGridSpec(columns: 1, side: maxSide, spacing: spacing) }
        var best = RABadgeGridSpec(columns: 1, side: 0, spacing: spacing)
        for cols in 1...cells {
            let rows = (cells + cols - 1) / cols
            let w = (area.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            let h = (area.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            let side = min(maxSide, w, h)
            if side > best.side { best = RABadgeGridSpec(columns: cols, side: side, spacing: spacing) }
        }
        return best
    }

    /// How many cells fit at the absolute floor (8pt, tight spacing — ~24px on
    /// the card, still a readable mosaic). Bounds the badge fetch; only a set
    /// past THIS (300+ unlocked) folds into the overflow chip.
    static func capacity(in area: CGSize, minSide: CGFloat = 8) -> Int {
        let spacing: CGFloat = 2
        let cols = max(1, Int((area.width + spacing) / (minSide + spacing)))
        let rows = max(1, Int((area.height + spacing) / (minSide + spacing)))
        return cols * rows
    }
}

/// What the console screen displays: the unlocked-badges grid with the set
/// summary. Sized in points at a third of the target pixel size (scale 3).
/// `dualScreen` (NDS) composes the STACKED pair — the header, summary and
/// credit on the top screen, the badge grid filling the touch screen; the
/// renderer splits at exactly half height.
struct RAGameScreenView: View {
    let boxArt: UIImage?
    /// Earned badges actually loaded, most-achieved first.
    let badges: [UIImage]
    /// Unlocked achievements NOT depicted (fetch cap or load failures);
    /// > 0 shows the "+N" chip in the last cell.
    let overflow: Int
    let unlockedCount: Int
    let total: Int
    let size: CGSize
    var dualScreen: Bool = false

    private static let gold = Color(red: 0.98, green: 0.80, blue: 0.36)

    /// The area the badge grid may occupy, also used by the host to bound the
    /// badge fetch BEFORE loading (keep in sync with the chrome below). On the
    /// dual-screen card the grid owns the touch screen (the lower half).
    static func gridArea(for size: CGSize, dualScreen: Bool = false) -> CGSize {
        dualScreen ? CGSize(width: size.width - 24, height: size.height / 2 - 20)
                   : CGSize(width: size.width - 28, height: size.height - 76)
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

    private func backdrop(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // The box art blurred + dimmed over a near-black purple (same
            // treatment as the achievement card's screen).
            Color(red: 0.05, green: 0.03, blue: 0.10)
            if let boxArt {
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

            VStack(spacing: 5) {
                headerText
                summaryText

                Spacer(minLength: 2)
                badgeGrid
                Spacer(minLength: 2)

                creditText
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// NDS: top screen = the set's identity (header + summary + credit over
    /// the game's art), touch screen = the badge wall.
    private var dualBody: some View {
        let halfH = size.height / 2
        return VStack(spacing: 0) {
            ZStack {
                backdrop(width: size.width, height: halfH)
                VStack(spacing: 7) {
                    Spacer(minLength: 4)
                    headerText
                    summaryText
                    Spacer(minLength: 4)
                    creditText
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(width: size.width, height: halfH)
            .clipped()

            ZStack {
                backdrop(width: size.width, height: halfH)
                badgeGrid
            }
            .frame(width: size.width, height: halfH)
            .clipped()
        }
    }

    private var headerText: some View {
        Text(String(localized: "ra.card.game", defaultValue: "ACHIEVEMENTS"))
            .font(.system(size: dualScreen ? 10.5 : 9, weight: .heavy)).tracking(1.6)
            .foregroundStyle(Self.gold)
    }

    private var summaryText: some View {
        Text(String(format: String(localized: "ra.dashboard.summary",
                                   defaultValue: "%lld of %lld unlocked"),
                    unlockedCount, total))
            .font(.system(size: dualScreen ? 11.5 : 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
    }

    private var creditText: some View {
        Text("RetroAchievements")
            .font(.system(size: dualScreen ? 8 : 7, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
    }

    /// Raw square badges (no rounding, no borders — the settled RA aesthetic),
    /// laid out by the grid solver; the last cell becomes the "+N" chip when
    /// the set overflows.
    private var badgeGrid: some View {
        let cells = badges.count + (overflow > 0 ? 1 : 0)
        let spec = RABadgeGridSpec.fit(cells: cells,
                                       in: Self.gridArea(for: size, dualScreen: dualScreen))
        let rows = cells > 0 ? (cells + spec.columns - 1) / spec.columns : 0
        return VStack(spacing: spec.spacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: spec.spacing) {
                    ForEach(0..<spec.columns, id: \.self) { col in
                        let index = row * spec.columns + col
                        if index < badges.count {
                            Image(uiImage: badges[index])
                                .resizable().scaledToFill()
                                .frame(width: spec.side, height: spec.side)
                        } else if index < cells {
                            overflowChip(side: spec.side)
                        }
                    }
                }
            }
        }
    }

    private func overflowChip(side: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: side, height: side)
            .overlay(
                Text("+\(overflow)")
                    .font(.system(size: max(8, side * 0.34), weight: .heavy))
                    .foregroundStyle(.white.opacity(0.85))
                    .minimumScaleFactor(0.6)
                    .padding(1))
    }
}

/// Host: resolves the game's console + skin, loads the box art + earned
/// badges, renders the console card, and shares it with the style picker.
struct RAGameShareView: View {
    /// The OFFICIAL RA set name (never the library rename).
    let gameName: String
    let boxArtURL: URL?
    /// The game's full achievement list; the card keeps the unlocked ones.
    let achievements: [RAAchievementInfo]
    let onClose: () -> Void

    /// The game's console (nil = Classic-only card, no style picker).
    private let system: PresetSystem?
    private let skinContext: ShareCardSkinContext

    @AppStorage("isPro") private var isPro = false
    @AppStorage private var styleChoice: String
    @State private var boxArt: UIImage?
    @State private var badges: [UIImage] = []
    @State private var imagesLoaded = false
    @State private var cardImage: UIImage?

    init(gameName: String, boxArtURL: URL?, achievements: [RAAchievementInfo],
         romFilename: String? = nil, onClose: @escaping () -> Void) {
        self.gameName = gameName
        self.boxArtURL = boxArtURL
        self.achievements = achievements
        self.onClose = onClose
        // Every console gets its console-skin styles (NDS composes the
        // dual-screen pair); an unknown game falls back to the Classic card.
        if let romFilename,
           let sys = PresetSystem.forRomFilename(romFilename) {
            self.system = sys
            self.skinContext = .forRom(romName: (romFilename as NSString).deletingPathExtension,
                                       system: sys)
        } else {
            self.system = nil
            self.skinContext = .none
        }
        _styleChoice = AppStorage(wrappedValue: "", skinContext.styleKey)
    }

    private var unlocked: [RAAchievementInfo] {
        achievements.filter { $0.unlocked }.sorted { $0.rarity > $1.rarity }
    }

    private var effectiveStyle: ShareCardStyle {
        guard system != nil else { return .retroPal }
        return ShareCardStyle.effective(choice: styleChoice, skinAvailable: skinContext.skin != nil)
    }

    var body: some View {
        RAShareScaffold(cardImage: cardImage,
                        shareFilename: "retropal-game-achievements",
                        cardType: "ra_game",
                        edgeColors: effectiveStyle.extrudeEdgeColors(system: system,
                                                                     skin: skinContext.skin),
                        onClose: onClose) {
            if let system {
                CardStylePicker(styleKey: skinContext.styleKey,
                                skinOption: skinContext.skin.map {
                                    ($0.name, $0.variant.bodyColor(for: system))
                                })
            }
        }
        .task { await loadAndRender() }
        .onChange(of: effectiveStyle) { _ in renderCard() }
    }

    @MainActor private func loadAndRender() async {
        guard !imagesLoaded else { return }
        boxArt = await UIImage.loaded(from: boxArtURL)

        // Fetch only what the screen's grid can depict (the readability-floor
        // capacity); one slot is reserved for the "+N" chip when overflowing.
        let unlocked = self.unlocked
        let area = RAGameScreenView.gridArea(for: RAConsoleCardRenderer.screenPointSize(system: system),
                                             dualScreen: system == .nds)
        let capacity = RABadgeGridSpec.capacity(in: area)
        let fetchCount = unlocked.count <= capacity ? unlocked.count : capacity - 1
        let targets = Array(unlocked.prefix(fetchCount))

        // Concurrent loads, original (most-achieved-first) order preserved.
        let loaded: [UIImage?] = await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, ach) in targets.enumerated() {
                group.addTask {
                    (index, await UIImage.loaded(from: ach.badgeURL.flatMap(URL.init(string:))))
                }
            }
            var out = [UIImage?](repeating: nil, count: targets.count)
            for await (index, image) in group { out[index] = image }
            return out
        }
        badges = loaded.compactMap { $0 }
        imagesLoaded = true
        renderCard()
    }

    @MainActor private func renderCard() {
        guard imagesLoaded else { return }
        let unlocked = self.unlocked
        // 100% of the set earned: RA's softcore award wording, next to the points.
        let completed = !achievements.isEmpty && unlocked.count == achievements.count
        cardImage = RAConsoleCardRenderer.render(
            gameName: gameName,
            points: unlocked.reduce(0) { $0 + $1.points },
            isPro: isPro,
            statSuffix: completed
                ? String(localized: "ra.card.completed", defaultValue: "Completed") : nil,
            style: effectiveStyle, system: system,
            skinVariant: skinContext.skin?.variant) { size in
                RAGameScreenView(boxArt: boxArt,
                                 badges: badges,
                                 overflow: unlocked.count - badges.count,
                                 unlockedCount: unlocked.count,
                                 total: achievements.count,
                                 size: size,
                                 dualScreen: system == .nds)
            }
    }
}

#if DEBUG
/// Debug preview (Settings ▸ Debug): the per-game card with a Fire-Red-sized
/// set — 157 unlocked badges, generated locally (no network) — to verify the
/// grid solver shrinks the whole set onto the console screen. The style picker
/// is live (global debug key), so Nostalgia (GBA) / Classic can both be checked.
struct RAGameCardDebugPreview: View {
    let onClose: () -> Void

    @State private var cardImage: UIImage?
    @AppStorage(ShareCardStyle.choiceKey) private var styleChoice = ""

    private var effectiveStyle: ShareCardStyle {
        ShareCardStyle.effective(choice: styleChoice)
    }

    var body: some View {
        RAShareScaffold(cardImage: cardImage,
                        shareFilename: "retropal-debug-ra-game",
                        cardType: "ra_game",
                        edgeColors: effectiveStyle.extrudeEdgeColors(system: .gba, skin: nil),
                        onClose: onClose) {
            CardStylePicker()
        }
        .onAppear(perform: render)
        .onChange(of: effectiveStyle) { _ in render() }
    }

    @MainActor private func render() {
        let badges = Self.placeholderBadges(157)
        // 157/157 → also previews the localized "Completed" stat suffix.
        cardImage = RAConsoleCardRenderer.render(
            gameName: "Pokémon FireRed Version",
            points: 845, isPro: false,
            statSuffix: String(localized: "ra.card.completed", defaultValue: "Completed"),
            style: effectiveStyle, system: .gba, skinVariant: nil) { size in
                RAGameScreenView(boxArt: nil, badges: badges, overflow: 0,
                                 unlockedCount: 157, total: 157, size: size)
            }
    }

    /// Hue-rotating two-tone squares standing in for badge art, so the mosaic's
    /// cell size and spacing read clearly at a glance.
    private static func placeholderBadges(_ count: Int) -> [UIImage] {
        (0..<count).map { i in
            UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { ctx in
                let hue = CGFloat(i % 24) / 24
                UIColor(hue: hue, saturation: 0.65, brightness: 0.85, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                UIColor(hue: hue, saturation: 0.80, brightness: 0.50, alpha: 1).setFill()
                ctx.fill(CGRect(x: 7, y: 7, width: 18, height: 18))
            }
        }
    }
}
#endif
