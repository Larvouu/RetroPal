//
//  StoryCardView.swift
//  EmulateurGBA
//
//  The Retro story's share cards (2026-10-28), three of them: the whole story,
//  one game, one console. Each is a 360-point square rendered at ×3 (1080 ×
//  1080), in the chrome the share cards already wear (the purple-dark ground,
//  the neon bezel, the Retro Pal mark above, the App Store line below, the
//  crown line for a Pro member), so the three sit beside the screenshot and
//  clip cards. What changes is the content: the old card ranked three games
//  and three consoles, which fitted four consoles and says little with
//  thirteen; these lead with the line a player shares ("87 h on Pokémon
//  Emerald").
//

import SwiftUI

enum StoryCard: Identifiable {
    case overall
    case game(PlayStats.GameStat)
    case console(PlayStats.ConsoleStat)

    var id: String {
        switch self {
        case .overall: return "overall"
        case .game(let g): return "game-\(g.romHash)"
        case .console(let c): return "console-\(c.system)"
        }
    }

    /// The share signal's value: a new VALUE of the existing `cardType`, which
    /// the signal freeze allows (`project_analytics_telemetrydeck`).
    var cardType: String {
        switch self {
        case .overall: return "story"
        case .game: return "story_game"
        case .console: return "story_console"
        }
    }
}

extension LandscapeTheme {
    /// The 3D preview's edge for a card in this look (presentation only, the
    /// saved image is the flat face): the accent darkened into the ground,
    /// a neutral grey into black for Classic.
    var cardEdgeColors: [Color] {
        if isClassic {
            return [Color(white: 0.22), Color(white: 0.06)]
        }
        let a = accentRGB, g = groundRGB
        return [Color(red: a.r * 0.45 + g.r * 0.55, green: a.g * 0.45 + g.g * 0.55, blue: a.b * 0.45 + g.b * 0.55),
                Color(red: g.r * 1.2, green: g.g * 1.2, blue: g.b * 1.2)]
    }

    /// The preview's halo: the accent, white-ish for Classic.
    var cardGlowColor: Color { isClassic ? Color.white.opacity(0.6) : accent }
}

struct StoryCardView: View {
    let card: StoryCard
    /// The overall story's stats; nil for the cards that carry their own
    /// (a game, a console).
    let stats: PlayStats?
    var isPro: Bool = false
    /// The covers of the games the card shows, by ROM hash, loaded by the
    /// share sheet before rendering (`ImageRenderer` draws one frame, so
    /// nothing can load inside it). A game without one shows its console.
    var covers: [String: UIImage] = [:]

    /// The games a card shows, for the share sheet to load their covers.
    static func gamesShown(by card: StoryCard, stats: PlayStats?) -> [PlayStats.GameStat] {
        switch card {
        case .overall: return Array(stats?.games.prefix(3) ?? [])
        case .game(let game): return [game]
        case .console(let console): return Array(console.games.prefix(3))
        }
    }

    /// The look the card wears (his ask of 10-28: the app's own look, by
    /// theme): its ground, its glows still, a glass panel, its accent.
    private var theme: LandscapeTheme { LandscapeThemeStore.shared.theme }
    private var purple: Color { theme.accent }

    /// The band above the panel, the logo centred in it.
    private static let topBand: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            logo
                .frame(height: Self.topBand)
            // The panel takes the height the card has (his feedback of 10-28:
            // the room under it was empty), the games' rows spreading in it.
            bezel { content.frame(maxHeight: .infinity, alignment: .top) }
                .padding(.horizontal, 16)
            if isPro {
                proBadgeLine.padding(.top, 8)
            }
            Text(NSLocalizedString("screenshot.footer", comment: ""))
                .padding(.top, 8)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(width: 360, height: 360)
        .background(StoryCardGround(theme: theme))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 1)
                .stroke(theme.isClassic ? Color.white.opacity(0.18) : purple.opacity(0.45), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch card {
        case .overall:
            if let stats { overall(stats) }
        case .game(let game): gameCard(game)
        case .console(let console): consoleCard(console)
        }
    }

    // MARK: The three contents

    /// Measured for the panel left under the logo, the footer and a Pro
    /// member's crown line (his report of 10-28: it ran past the card). No
    /// "Retro story" label above the total: the logo and the footer say it.
    private func overall(_ stats: PlayStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // As on the page: one line, plain white (his feedback of 10-28).
            Text(String(format: NSLocalizedString("story.totalPlayed", comment: ""),
                        RetroStoryFormat.duration(stats.totalSeconds)))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            divider
            coverRows(Array(stats.games.prefix(3)), coverSide: 32)
            divider
            HStack {
                fact("\(stats.gamesPlayed)", NSLocalizedString("library.stats.gamesPlayed", comment: ""))
                fact("\(stats.consoles.count)", NSLocalizedString("story.consolesPlayed", comment: ""))
            }
        }
    }

    private func gameCard(_ game: PlayStats.GameStat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let cover = covers[game.romHash] {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            ConsoleMark(systemType: game.system, width: 48, height: 34)
                        }
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    ConsoleMark(systemType: game.system, width: 30, height: 20)
                    Text(game.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                }
            }
            Text(RetroStoryFormat.duration(game.seconds))
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let first = game.firstPlayed {
                label(String(format: NSLocalizedString("story.since", comment: ""), RetroStoryFormat.date(first)))
            }
        }
    }

    private func consoleCard(_ console: PlayStats.ConsoleStat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ConsoleMark(systemType: console.system, width: 72, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SystemColor.name(console.system))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(RetroStoryFormat.duration(console.seconds))
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
            divider
            coverRows(Array(console.games.prefix(3)))
        }
    }

    /// The top games as rows with their covers (his feedback of 10-28: a
    /// cover says more than a rank digit), spread over the room they have.
    private func coverRows(_ games: [PlayStats.GameStat], coverSide: CGFloat = 40) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(games.enumerated()), id: \.offset) { index, game in
                if index > 0 { Spacer(minLength: 6) }
                HStack(spacing: 10) {
                    smallCover(game, side: coverSide)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(coverSide < 40 ? 1 : 2)
                            .minimumScaleFactor(0.8)
                        Text(RetroStoryFormat.duration(game.seconds))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func smallCover(_ game: PlayStats.GameStat, side: CGFloat) -> some View {
        Group {
            if let image = covers[game.romHash] {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    ConsoleMark(systemType: game.system, width: side * 0.6, height: side * 0.42)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
    }

    // MARK: Pieces

    /// Two lines at most, shrinking a little before that: the card is a
    /// fixed square, and the longest language must still say it whole.
    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    private func fact(_ value: String, _ name: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(name)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
    }

    private var logo: some View {
        Group {
            if let icon = UIImage(named: "SharingIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56.0 / 3, height: 56.0 / 3)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    private var proBadgeLine: some View {
        HStack(spacing: 3) {
            Image(uiImage: ScreenshotCardRenderer.proCrownBadgeImage(side: 18))
            Text(NSLocalizedString("screenshot.proMember", comment: "")
                    .replacingOccurrences(of: "👑", with: "")
                    .trimmingCharacters(in: .whitespaces))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    /// The app's glass card (the library hero's, `LandscapeChrome`'s
    /// opacities) on the look's ground.
    private func bezel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(LandscapeChrome.cardFill)))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(LandscapeChrome.cardStroke), lineWidth: 1))
    }
}

/// The look's ground for a share card, still: its colour, its four glows where
/// the moving ground starts them, the same gradient stops, its grain, and (the
/// year's slides) its dust held at one moment. Its
/// own view because `ImageRenderer` draws one frame and no UIKit view (the
/// moving ground has a particle layer); Classic is its plain black, as
/// everywhere.
struct StoryCardGround: View {
    let theme: LandscapeTheme
    /// The content pages' film over it; the year's slides lay their own.
    var film: Bool = true
    /// The moving ground's dust, held still: the year's slides, whose screen
    /// shows it (his report of 10-30); the cards never had it.
    var dust: Bool = false

    private struct Glow {
        let x: CGFloat, y: CGFloat, radius: CGFloat, opacity: Double, accent: Bool
    }

    /// The moving ground's dust, still (his report of 10-30: a saved slide
    /// had no coloured dots where the screen has them). The live dust is a
    /// particle layer (`LibraryLandscapeParticleLayerView`), which a one-frame
    /// image cannot draw, so it is drawn here as that layer looks at any
    /// moment: its four cells at their steady counts (birth rate x lifetime:
    /// 60 and 36 specks, 10 and 6 motes) on an upright phone's area, fewer or
    /// more with the card's; their size as the layer draws them (the 8-point
    /// sprite is rendered at 3x and a cell draws its pixels, so 24 x 0.35 and
    /// 24 x 1.6 points, +/- a quarter, growing 2 % a second); the look's
    /// accent and highlight at 0.6 x its glow, each partway through its fade;
    /// added onto the ground as the layer adds them. A fixed seed places them,
    /// so the same card always comes out the same.
    private struct Speck {
        let x: CGFloat, y: CGFloat, size: CGFloat, alpha: Double
    }

    /// The four cells, as the layer has them: how many on the reference area,
    /// their base size, their colour.
    private static let cells: [(count: Int, size: CGFloat, accent: Bool)] = [
        (60, 24 * 0.35, true), (36, 24 * 0.35, false), (10, 24 * 1.6, true), (6, 24 * 1.6, false),
    ]
    /// The area those counts are for: an upright 6.1-inch phone, where the
    /// review is read.
    private static let referenceArea: CGFloat = 393 * 852

    /// Each cell's specks, placed once, more than any card needs (four times
    /// the reference); a card draws the first ones its area calls for.
    private static let specks: [[Speck]] = {
        var seed: UInt64 = 0x5EED_2026
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        return cells.map { cell in
            (0..<(cell.count * 4)).map { _ in
                let age = next()   // how far through its life, as the fade has it
                return Speck(x: CGFloat(next()), y: CGFloat(next()),
                             size: cell.size * CGFloat(0.75 + 0.5 * next()) * CGFloat(1 + 0.24 * age),
                             alpha: 0.6 * (1 - age))
            }
        }
    }()

    private static func stillDust(theme: LandscapeTheme) -> some View {
        Canvas { context, size in
            context.blendMode = .plusLighter
            let share = size.width * size.height / referenceArea
            for (index, cell) in cells.enumerated() {
                let color = cell.accent ? theme.accent : theme.highlight
                let count = min(specks[index].count, Int((CGFloat(cell.count) * share).rounded()))
                for speck in specks[index].prefix(count) {
                    let rect = CGRect(x: speck.x * size.width - speck.size / 2,
                                      y: speck.y * size.height - speck.size / 2,
                                      width: speck.size, height: speck.size)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(speck.alpha * theme.glow)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The moving ground's four glows at their starting points.
    private static let glows: [Glow] = [
        Glow(x: 0.12, y: 0.20, radius: 0.55, opacity: 0.7, accent: true),
        Glow(x: 0.88, y: 0.85, radius: 0.50, opacity: 0.5, accent: false),
        Glow(x: 0.92, y: 0.05, radius: 0.42, opacity: 0.5, accent: true),
        Glow(x: 0.18, y: 0.95, radius: 0.38, opacity: 0.4, accent: false),
    ]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let base = min(size.width, size.height)
            ZStack {
                theme.ground
                if !theme.isClassic {
                    ForEach(0..<Self.glows.count, id: \.self) { i in
                        let glow = Self.glows[i]
                        let r = glow.radius * base
                        let color = glow.accent ? theme.accent : theme.highlight
                        let strength = glow.opacity * theme.glow
                        Circle()
                            .fill(RadialGradient(
                                gradient: Gradient(stops: [
                                    .init(color: color.opacity(strength), location: 0),
                                    .init(color: color.opacity(strength * 0.55), location: 0.28),
                                    .init(color: color.opacity(strength * 0.18), location: 0.6),
                                    .init(color: color.opacity(0), location: 1),
                                ]),
                                center: .center, startRadius: 0, endRadius: r))
                            .frame(width: r * 2, height: r * 2)
                            .blendMode(.plusLighter)
                            .position(x: glow.x * size.width, y: glow.y * size.height)
                    }
                    Image(uiImage: LibraryLandscapeBackground.grain)
                        .resizable(resizingMode: .tile)
                        .interpolation(.none)
                        .opacity(0.05)
                    if dust {
                        Self.stillDust(theme: theme)
                    }
                }
                // The film the content pages carry, so the type reads over the glows.
                if film {
                    Color.black.opacity(LandscapeChrome.groundFilm)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }
}
