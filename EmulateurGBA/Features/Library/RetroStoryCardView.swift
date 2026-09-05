//
//  RetroStoryCardView.swift
//  EmulateurGBA
//

import SwiftUI

/// The "retro story" stats — ONE component, two faces, gated on `includesBranding`:
///   - false (library footer): plain black, full-size content, no bezel/logo/
///     footer; portrait is a 4:5 card, landscape lays the rankings side by side.
///   - true (shareable card): the screenshot-card look — purple-dark gradient,
///     the content inside a purple-neon bezel, Retro Pal logo on top, App Store
///     footer at the bottom, slightly smaller content, and game names sized to a
///     single shared size so none truncates.
/// The row helpers (medals, console icons, bars, durations) are shared.
struct RetroStoryCardView: View {
    let stats: LibraryStats
    var includesBranding: Bool = false
    /// Shareable-card visual style. `.nostalgia` adds a subtle gold neon edge; only
    /// ever applied on the shareable card (`includesBranding`), never the
    /// library face. Resolved by the share sheet from the user's choice.
    var style: ShareCardStyle = .retroPal
    /// Whether the viewer actually owns Pro. The crown badge shows whenever this
    /// is true on the shareable card, INDEPENDENT of `style` — a Pro user who
    /// switches to the Retro Pal card still keeps the crown. (`style` only drives
    /// the gold-neon treatment, which they're free to turn off.)
    var isPro: Bool = false

    @Environment(\.verticalSizeClass) private var vSizeClass
    private let leadingColumn: CGFloat = 18

    // Screenshot-card palette (shareable card only).
    private let purple = Color(red: 0.45, green: 0.2, blue: 0.85)
    private let bezelFill = Color(red: 0.08, green: 0.06, blue: 0.12)
    private let bgTop = Color(red: 0.10, green: 0.06, blue: 0.18)
    private let bgBottom = Color(red: 0.04, green: 0.02, blue: 0.08)

    /// The shareable card carrying the Nostalgia treatment: a faint warm wash in the
    /// background and one thin two-tone (gold/purple) edge line, blended with the
    /// card's existing purple. Deliberately barely-there, felt more than seen.
    /// Only the shareable card (`includesBranding`) shows it; the library face never does.
    private var isNostalgiaCard: Bool { includesBranding && style == .nostalgia }
    /// The crown badge follows real Pro ownership, not the chosen card style — so
    /// it stays on the card even when a Pro user selects the Standard UI.
    private var showsProBadge: Bool { includesBranding && isPro }

    // The bezel frame + glow: the shareable card keeps the purple neon; the
    // library uses the game-item background color so it blends with the list.
    private var bezelStroke: Color {
        includesBranding ? purple.opacity(0.6) : Color(.secondarySystemGroupedBackground)
    }
    private var bezelGlow: Color {
        includesBranding ? purple.opacity(0.5) : Color(.secondarySystemGroupedBackground)
    }
    /// Bezel interior: the card keeps the dark purple-tinted fill; the library
    /// uses the page background (black in dark mode) so the bezel reads as an
    /// outline on the list rather than a filled card.
    private var bezelFillColor: Color {
        includesBranding ? bezelFill : Color(.systemGroupedBackground)
    }

    /// Inner-bezel geometry. The shareable card uses a thin stroke + light glow,
    /// concentric with the rounded card edge (clean, not chunky); the library
    /// face keeps its heavier outline so it still reads against the list.
    private var bezelCorner: CGFloat { includesBranding ? 16 : 14 }
    private var bezelLineWidth: CGFloat { includesBranding ? 1 : 2 }
    private var bezelShadowRadius: CGFloat { includesBranding ? 5 : 12 }

    // Context-dependent sizes: the shareable card is a touch smaller to fit the bezel.
    private var nameSize: CGFloat { includesBranding ? 12 : 13 }
    private var timeSize: CGFloat { includesBranding ? 10 : 11 }
    private var headlineValueSize: CGFloat { includesBranding ? 15 : 17 }
    private var headlineLabelSize: CGFloat { includesBranding ? 8 : 9 }
    // Tighter on the shareable card so the content fits the square ratio; the
    // library bezel keeps the roomier spacing.
    private var rowSpacing: CGFloat { includesBranding ? 6 : 9 }
    private var bezelPad: CGFloat { includesBranding ? 10 : 12 }

    var body: some View {
        if includesBranding { cardBody } else { libraryBody }
    }

    // MARK: - Shareable card (gradient + neon bezel + logo + footer)

    // Mirror the clip card's vertical rhythm so the two square cards read as
    // siblings. The clip is drawn in 1080px; this card is a 360pt view rendered
    // ×3, so the clip's pixel anchors map in by ÷3: logo top at clip logoY (64),
    // logo size = clip's (56), and the content box top at clip gameTop (160) —
    // a fixed 40px gap below the logo, exactly as on the clip card.
    private let clipLogoTop: CGFloat = 64.0 / 3
    private let clipLogoSize: CGFloat = 56.0 / 3
    private let clipLogoToContent: CGFloat = 40.0 / 3   // clip: gameTop(160) − logo bottom(120)

    private var cardBody: some View {
        VStack(spacing: 0) {
            logo
                .padding(.top, clipLogoTop)
            Spacer().frame(height: clipLogoToContent)
            bezel { content(sideBySide: false) }
                .padding(.horizontal, 16)   // inset so the gradient shows around
                                            // the bezel, like the screenshot card
            // Pro members: the metal crown badge + "Pro member" label, just below
            // the content, mirroring the clip card's badge line. Shown on real Pro
            // ownership regardless of the chosen card style.
            if showsProBadge {
                proBadgeLine.padding(.top, 8)
            }
            Spacer(minLength: 2)
            footer
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .aspectRatio(1, contentMode: .fit)   // square
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { if includesBranding { cardEdge } }
    }

    /// The crown emblem + muted "Pro member" label, centered — the stats-card echo
    /// of the clip card's badge line. The emoji is stripped (the badge IS the
    /// crown) and the label uses the same muted color as the footer.
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

    /// The surrounding edge line, on the shareable card in BOTH modes so it always
    /// reads as a card: the two-tone gold/purple line for Nostalgia, a subtle purple line
    /// otherwise. The screenshot + clip cards draw the same edge (ScreenshotCardRenderer
    /// .drawCardEdge), so the three match.
    @ViewBuilder private var cardEdge: some View {
        if style == .nostalgia {
            proGoldEdge
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 1)
                .stroke(purple.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    /// Card background: the standard purple-dark gradient, plus (Nostalgia only) a warm
    /// gold glow in the upper corner echoing the Pro sheet, so the whole card
    /// reads premium and not just its edge. Subtle and inside the bounds so
    /// ImageRenderer captures it into the shared asset.
    private var cardBackground: some View {
        ZStack {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
            if isNostalgiaCard {
                // A faint, diffuse warm wash from the top: the main Pro tell, but
                // ambient rather than a spot. Large radius + low opacity so it
                // reads as warmth, not a gold blob.
                RadialGradient(
                    colors: [ProPalette.gold.opacity(0.07), .clear],
                    center: UnitPoint(x: 0.5, y: -0.05),
                    startRadius: 0, endRadius: 380)
            }
        }
    }

    /// The Pro edge: a single thin two-tone (gold to purple) line, modeled on the
    /// Pro button in Settings. The only hard line of the Pro treatment, kept faint
    /// and low-contrast so it blends with the card's purple and is felt more than
    /// seen. Drawn inside the bounds (no outer glow) so ImageRenderer keeps it in
    /// the shared asset. Tune opacity/width on device.
    private var proGoldEdge: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .inset(by: 1)
            .stroke(
                LinearGradient(
                    colors: [ProPalette.gold.opacity(0.40), purple.opacity(0.40)],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.0)
            .allowsHitTesting(false)
    }

    // MARK: - Library footer (plain black, unchanged)

    private var libraryBody: some View {
        // Just the neon bezel around the content — no gradient/logo/footer (those
        // belong to the shareable card). The bezel brings its own dark fill, so
        // there's no separate black card: it sits on the list background, and the
        // bezel is also the tappable area that opens the share sheet.
        Group {
            if vSizeClass == .compact {
                bezel { content(sideBySide: true) }
            } else {
                bezel { content(sideBySide: false) }
            }
        }
    }

    // MARK: - Shared content

    @ViewBuilder private func content(sideBySide: Bool) -> some View {
        if sideBySide {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 18) {
                    ranking(rows: gameRows).frame(maxWidth: .infinity)
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1)
                    ranking(rows: consoleRows).frame(maxWidth: .infinity)
                }
                divider
                headlineRow
            }
        } else {
            VStack(spacing: rowSpacing) {
                ranking(rows: gameRows)
                divider
                if !stats.topConsoles.isEmpty {
                    ranking(rows: consoleRows)
                    divider
                }
                headlineRow
            }
        }
    }

    // MARK: - Card chrome

    private var logo: some View {
        Group {
            if let icon = UIImage(named: "SharingIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: clipLogoSize, height: clipLogoSize)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    private var footer: some View {
        Text(NSLocalizedString("screenshot.footer", comment: ""))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.5))
    }

    private func bezel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(bezelPad)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: bezelCorner, style: .continuous).fill(bezelFillColor))
            .overlay(
                RoundedRectangle(cornerRadius: bezelCorner, style: .continuous)
                    .strokeBorder(bezelStroke, lineWidth: bezelLineWidth))
            .shadow(color: bezelGlow, radius: bezelShadowRadius)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
    }

    private func ranking<Content: View>(rows: Content) -> some View {
        VStack(spacing: rowSpacing) { rows }
    }

    // MARK: - Headline stats (bottom)

    private var headlineRow: some View {
        HStack(alignment: .top, spacing: 10) {
            statCell(value: Self.durationString(stats.totalSeconds),
                     label: NSLocalizedString("library.stats.totalTime", comment: ""))
            statCell(value: "\(stats.playedCount)",
                     label: NSLocalizedString("library.stats.gamesPlayed", comment: ""))
            statCell(value: "\(stats.sessionCount)",
                     label: NSLocalizedString("library.stats.sessions", comment: ""))
        }
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: headlineValueSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.localizedUppercase)
                .font(.system(size: headlineLabelSize, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Top games (medals)

    @ViewBuilder private var gameRows: some View {
        let maxSeconds = stats.topGames.map(\.seconds).max() ?? 1
        // On the shareable card, fit ALL game names to one shared size so none
        // truncates; the library keeps the regular size (and truncates as before).
        let gameNameSize = includesBranding ? uniformGameNameSize : nameSize
        ForEach(Array(stats.topGames.enumerated()), id: \.element.id) { index, game in
            rankingRow(
                leading: medal(rank: index + 1),
                label: game.title,
                nameSize: gameNameSize,
                seconds: game.seconds,
                fraction: maxSeconds > 0 ? CGFloat(game.seconds / maxSeconds) : 0,
                fill: Self.medalColors(rank: index + 1))
        }
    }

    /// The largest size (<= the card name size) at which every game name fits the
    /// card's name column, so the three share one size and none ends with "…".
    private var uniformGameNameSize: CGFloat {
        let availableWidth: CGFloat = 210   // ~360pt card minus bezel/medal/time
        var size = nameSize
        while size > 8 {
            let allFit = stats.topGames.allSatisfy { game in
                (game.title as NSString).size(withAttributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: .semibold)]).width <= availableWidth
            }
            if allFit { break }
            size -= 0.5
        }
        return size
    }

    private func medal(rank: Int) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: Self.medalColors(rank: rank),
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("\(rank)")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.6))
        }
        .frame(width: 14, height: 14)
    }

    // MARK: - Top consoles

    @ViewBuilder private var consoleRows: some View {
        let maxSeconds = stats.topConsoles.map(\.seconds).max() ?? 1
        ForEach(stats.topConsoles) { console in
            rankingRow(
                leading: consoleIcon(console.id),
                label: Self.consoleName(console.id),
                nameSize: nameSize,
                seconds: console.seconds,
                fraction: maxSeconds > 0 ? CGFloat(console.seconds / maxSeconds) : 0,
                fill: [SystemColor.color(console.id)])
        }
    }

    private func consoleIcon(_ system: String) -> some View {
        Image("console-\(system)")
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
    }

    // MARK: - Shared ranking row

    private func rankingRow<Leading: View>(leading: Leading, label: String, nameSize: CGFloat,
                                            seconds: TimeInterval, fraction: CGFloat,
                                            fill: [Color]) -> some View {
        HStack(spacing: 10) {
            leading.frame(width: leadingColumn)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(size: nameSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.durationString(seconds))
                        .font(.system(size: timeSize, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineLimit(1)
                }
                ProportionalBar(fraction: fraction, fill: fill)
                    .frame(height: 3)
            }
        }
    }

    // MARK: - Helpers

    private static func medalColors(rank: Int) -> [Color] {
        switch rank {
        case 1: return [Color(red: 1.0, green: 0.84, blue: 0.35), Color(red: 0.85, green: 0.62, blue: 0.15)]   // gold
        case 2: return [Color(red: 0.83, green: 0.85, blue: 0.89), Color(red: 0.55, green: 0.57, blue: 0.62)]   // silver
        default: return [Color(red: 0.85, green: 0.56, blue: 0.30), Color(red: 0.55, green: 0.34, blue: 0.16)]  // bronze
        }
    }

    private static func consoleName(_ system: String) -> String {
        switch system {
        case "gb": return "Game Boy"
        case "gbc": return "Game Boy Color"
        case "nds": return "Nintendo DS"
        case "snes": return "Super Nintendo"
        case "nes": return "NES"
        case "ps1": return "PlayStation"
        default: return "Game Boy Advance"
        }
    }

    /// "Xh Ym" / "Ym", flooring a sub-minute amount to "1m".
    private static func durationString(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        var m = (Int(seconds) % 3600) / 60
        if h == 0 && m == 0 && seconds > 0 { m = 1 }
        if h > 0 {
            return String(format: NSLocalizedString("library.stats.duration", comment: ""), "\(h)", "\(m)")
        }
        return String(format: NSLocalizedString("library.stats.durationMin", comment: ""), "\(m)")
    }
}

/// A thin bar showing only its filled portion (no track), width proportional to
/// the row's value, so entries compare at a glance.
private struct ProportionalBar: View {
    let fraction: CGFloat
    let fill: [Color]

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(LinearGradient(colors: fill, startPoint: .leading, endPoint: .trailing))
                .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
        }
    }
}

#if DEBUG
/// Debug-only: preview the shareable card (with branding) at the smallest and
/// largest current iPhone widths. Reachable from Settings ▸ Debug.
struct StatsCardPreviewGallery: View {
    private let devices: [(name: String, width: CGFloat)] = [
        ("iPhone SE", 375),
        ("iPhone 16 Pro Max", 440),
    ]

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(devices, id: \.name) { device in
                        let scale = min(1, (geo.size.width - 32) / device.width)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(device.name) · \(Int(device.width))pt wide")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            RetroStoryCardView(stats: Self.dummy, includesBranding: true)
                                .frame(width: device.width)
                                .scaleEffect(scale, anchor: .topLeading)
                                .frame(width: device.width * scale,
                                       height: device.width * scale,
                                       alignment: .topLeading)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Stats card preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let dummy = LibraryStats(
        totalSeconds: 47 * 3600 + 25 * 60,
        sessionCount: 92,
        libraryCount: 14,
        playedCount: 9,
        topGames: [
            .init(id: "1", title: "Pokémon Mystery Dungeon: Explorers", seconds: 31 * 3600),
            .init(id: "2", title: "Zelda: The Minish Cap", seconds: 12 * 3600 + 40 * 60),
            .init(id: "3", title: "Mario Kart Super Circuit", seconds: 5 * 3600 + 10 * 60),
        ],
        topConsoles: [
            .init(id: "gba", seconds: 38 * 3600),
            .init(id: "nds", seconds: 7 * 3600),
            .init(id: "gb", seconds: 2 * 3600 + 25 * 60),
        ])
}
#endif
