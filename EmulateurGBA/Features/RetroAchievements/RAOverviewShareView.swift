//
//  RAOverviewShareView.swift
//  EmulateurGBA
//
//  The shareable RetroAchievements OVERVIEW card, restyled after the official
//  retroachievements.org profile: the RA dark-charcoal theme (no console
//  dress — the games span consoles), the RA masthead, username + totals, then
//  EVERY eligible game, most points first, at a density that adapts to how
//  many there are:
//    • ≤ 4 games  → full RA-site panels (icon, title, console, points, n/m,
//      gold progress bar, gold "mastered" border on a 100% set)
//    • ≤ 8 games  → compact rows (icon, title, points, n/m, thin bar)
//    • more       → a mosaic grid of box-art tiles (the same solver as the
//      per-game badge grid) — a 100% game wears the gold "mastered" stroke —
//      so ALL games show; only a set past the mosaic's floor folds into a
//      wordless "+N" tile.
//  Titles shrink to fit instead of truncating with "…". The progress bars are
//  hand-drawn Capsules: ProgressView is UIKit-backed and cannot render inside
//  an ImageRenderer snapshot. Opened from the library profile's share button.
//

import SwiftUI

/// One game on the overview card.
struct RAOverviewGameLine {
    let boxArt: UIImage?
    let title: String
    let unlocked: Int
    let total: Int
    let consoleID: UInt32
    /// Points earned in this game (nil until it was loaded once in-app).
    let points: Int?
}

struct RAOverviewCardView: View {
    let username: String
    let points: Int
    let gamesCount: Int
    let unlockedTotal: Int
    let games: [RAOverviewGameLine]   // sorted most-points-first by the host
    /// Eligible games beyond what even the mosaic can depict (rare; > 0 shows
    /// the "+N" tile as the mosaic's last cell).
    let hiddenGames: Int
    let isPro: Bool

    static let side: CGFloat = 360
    /// The area the games section may occupy (side minus padding, header block
    /// and footer). The host uses it to bound the mosaic's box-art fetch.
    static let gamesArea = CGSize(width: 324, height: 196)
    private static let gold = Color(red: 0.98, green: 0.80, blue: 0.36)

    var body: some View {
        ZStack {
            // The RA site's neutral dark charcoal, not the Retro Pal purple.
            LinearGradient(
                colors: [Color(red: 0.118, green: 0.118, blue: 0.133),
                         Color(red: 0.055, green: 0.055, blue: 0.063)],
                startPoint: .top, endPoint: .bottom)

            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    Image("RABrand")
                        .resizable().scaledToFit()
                        .frame(height: 15)
                    Text("RetroAchievements")
                        .font(.system(size: 12, weight: .heavy)).tracking(1)
                        .foregroundStyle(.white.opacity(0.85))
                }

                Text(username)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 0) {
                    stat(value: "\(gamesCount)",
                         label: String(localized: "ra.card.games", defaultValue: "Games"))
                    // "SUCCÈS" / "ACHIEVEMENTS", not "unlocked": the bare
                    // participle read as nothing in FR (settled).
                    stat(value: "\(unlockedTotal)",
                         label: String(localized: "ra.card.game", defaultValue: "ACHIEVEMENTS"))
                    stat(value: "\(points)",
                         label: String(localized: "ra.pointsSuffix", defaultValue: "pts"))
                }
                .padding(.bottom, 3)

                gamesSection

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Spacer()
                    if isPro {
                        Image(uiImage: ScreenshotCardRenderer.proCrownBadgeImage(side: 12))
                            .resizable().scaledToFit()
                            .frame(height: 17)
                    }
                    Text("Retro Pal")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Self.gold)
                }
            }
            .padding(18)
        }
        .frame(width: Self.side, height: Self.side)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Self.gold)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Games section (density adapts to the count)

    @ViewBuilder private var gamesSection: some View {
        if games.count <= 4 {
            VStack(spacing: 6) {
                ForEach(Array(games.enumerated()), id: \.offset) { _, game in
                    gamePanel(game)
                }
            }
        } else if games.count <= 8 {
            VStack(spacing: 4) {
                ForEach(Array(games.enumerated()), id: \.offset) { _, game in
                    compactRow(game)
                }
            }
        } else {
            mosaic
        }
    }

    /// A hand-drawn progress bar (Capsule pair; never ProgressView — it cannot
    /// render inside ImageRenderer). Keeps a minimal nub once anything is earned.
    private func progressBar(fraction: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Self.gold)
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * fraction))
            }
        }
        .frame(height: height)
    }

    private func fraction(_ game: RAOverviewGameLine) -> CGFloat {
        game.total > 0 ? min(1, CGFloat(game.unlocked) / CGFloat(game.total)) : 0
    }

    private func isMastered(_ game: RAOverviewGameLine) -> Bool {
        game.total > 0 && game.unlocked == game.total
    }

    @ViewBuilder private func gameIcon(_ game: RAOverviewGameLine, side: CGFloat,
                                       corner: CGFloat) -> some View {
        Group {
            if let boxArt = game.boxArt {
                Image(uiImage: boxArt).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "trophy.fill")
                        .font(.system(size: side * 0.4))
                        .foregroundStyle(Self.gold.opacity(0.7))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    /// ≤ 4 games: the full RA-site panel.
    private func gamePanel(_ game: RAOverviewGameLine) -> some View {
        HStack(spacing: 9) {
            gameIcon(game, side: 26, corner: 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(game.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Spacer(minLength: 4)
                    if let points = game.points {
                        Text("\(points) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                            .font(.system(size: 10.5, weight: .heavy))
                            .foregroundStyle(Self.gold)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 5) {
                    if let console = Self.consoleName(game.consoleID) {
                        Text(console)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("\(game.unlocked)/\(game.total)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                }
                progressBar(fraction: fraction(game), height: 3.5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isMastered(game) ? Self.gold.opacity(0.85) : Color.white.opacity(0.08),
                          lineWidth: 1))
    }

    /// 5-8 games: a slim row (RA "completion progress" style).
    private func compactRow(_ game: RAOverviewGameLine) -> some View {
        VStack(spacing: 2.5) {
            HStack(spacing: 6) {
                gameIcon(game, side: 14, corner: 3)
                Text(game.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 4)
                if let points = game.points {
                    Text("\(points) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Self.gold)
                        .monospacedDigit()
                }
                Text("\(game.unlocked)/\(game.total)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(isMastered(game) ? 0.9 : 0.6))
                    .monospacedDigit()
            }
            progressBar(fraction: fraction(game), height: 2)
        }
    }

    /// 9+ games: a mosaic of box-art tiles laid out by the shared grid solver
    /// so EVERY game shows; a 100% game wears the gold "mastered" stroke.
    private var mosaic: some View {
        let cells = games.count + (hiddenGames > 0 ? 1 : 0)
        let spec = RABadgeGridSpec.fit(cells: cells, in: Self.gamesArea, maxSide: 44)
        let rows = cells > 0 ? (cells + spec.columns - 1) / spec.columns : 0
        return VStack(spacing: spec.spacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: spec.spacing) {
                    ForEach(0..<spec.columns, id: \.self) { col in
                        let index = row * spec.columns + col
                        if index < games.count {
                            mosaicTile(games[index], side: spec.side)
                        } else if index < cells {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.08))
                                .frame(width: spec.side, height: spec.side)
                                .overlay(
                                    Text("+\(hiddenGames)")
                                        .font(.system(size: max(8, spec.side * 0.3), weight: .heavy))
                                        .foregroundStyle(Self.gold.opacity(0.9))
                                        .minimumScaleFactor(0.6))
                        }
                    }
                }
            }
        }
    }

    /// A plain box-art tile; a 100% game wears the gold "mastered" stroke
    /// (the tile carries no progress bar — completion is the one signal).
    private func mosaicTile(_ game: RAOverviewGameLine, side: CGFloat) -> some View {
        gameIcon(game, side: side, corner: 4)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isMastered(game) ? Self.gold.opacity(0.95) : Color.clear,
                              lineWidth: 1.5))
    }

    /// RA console names for the ids RA support covers here (rcheevos ids).
    private static func consoleName(_ id: UInt32) -> String? {
        switch id {
        case 4: return "Game Boy"
        case 5: return "Game Boy Advance"
        case 6: return "Game Boy Color"
        case 18: return "Nintendo DS"
        default: return nil
        }
    }
}

/// Host: aggregates the eligible records, loads the box arts, renders.
struct RAOverviewShareView: View {
    let username: String
    let points: Int
    /// Eligible records, any order; the host sorts and truncates.
    let records: [RAGameRecord]
    let onClose: () -> Void

    @AppStorage("isPro") private var isPro = false
    @State private var cardImage: UIImage?

    var body: some View {
        RAShareScaffold(cardImage: cardImage,
                        shareFilename: "retropal-ra-overview",
                        cardType: "ra_overview",
                        // Isometric tilt with the Classic purple edge (no game
                        // context, so no console body to extrude).
                        edgeColors: ShareCardStyle.retroPal.extrudeEdgeColors(system: nil, skin: nil),
                        onClose: onClose)
            .task { await loadAndRender() }
    }

    @MainActor private func loadAndRender() async {
        // Most completed first, by points earned (games never loaded in-app
        // have no points yet and sort by unlocked count behind them).
        let sorted = records.sorted {
            let p0 = $0.pointsEarned ?? -1, p1 = $1.pointsEarned ?? -1
            if p0 != p1 { return p0 > p1 }
            if $0.unlocked != $1.unlocked { return $0.unlocked > $1.unlocked }
            return ($0.title ?? "") < ($1.title ?? "")
        }

        // Every game shows (the mosaic floor bounds the art fetch; one slot is
        // reserved for the "+N" tile past it — realistically never).
        let capacity = RABadgeGridSpec.capacity(in: RAOverviewCardView.gamesArea)
        let shownCount = sorted.count <= capacity ? sorted.count : capacity - 1
        let shown = Array(sorted.prefix(shownCount))

        // Concurrent box-art loads, sort order preserved.
        let arts: [UIImage?] = await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, record) in shown.enumerated() {
                group.addTask {
                    (index, await UIImage.loaded(from: record.boxArtURL.flatMap(URL.init(string:))))
                }
            }
            var out = [UIImage?](repeating: nil, count: shown.count)
            for await (index, image) in group { out[index] = image }
            return out
        }

        let lines = shown.enumerated().map { index, record in
            // RA set name first (it's an RA artifact); library title until the
            // set has been loaded once.
            RAOverviewGameLine(
                boxArt: arts[index],
                title: record.title
                    ?? RAGameIndex.shared.libraryTitle(forROMHash: record.romHash)
                    ?? "",
                unlocked: record.unlocked,
                total: record.total,
                consoleID: record.consoleID,
                points: record.pointsEarned)
        }
        let card = RAOverviewCardView(
            username: username,
            points: points,
            gamesCount: records.count,
            unlockedTotal: records.reduce(0) { $0 + $1.unlocked },
            games: lines,
            hiddenGames: max(0, records.count - lines.count),
            isPro: isPro)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        cardImage = renderer.uiImage
    }
}

#if DEBUG
/// Debug preview (Settings ▸ Debug): the overview card in its MOSAIC tier —
/// 30 games from generated placeholder art (no network), the first 4 fully
/// completed, to verify the tile grid and the gold "mastered" strokes.
struct RAOverviewCardDebugPreview: View {
    let onClose: () -> Void
    @State private var cardImage: UIImage?

    var body: some View {
        RAShareScaffold(cardImage: cardImage,
                        shareFilename: "retropal-debug-ra-overview",
                        cardType: "ra_overview",
                        edgeColors: ShareCardStyle.retroPal.extrudeEdgeColors(system: nil, skin: nil),
                        onClose: onClose)
            .onAppear(perform: render)
    }

    @MainActor private func render() {
        let games = (0..<30).map { i -> RAOverviewGameLine in
            let total = 30 + (i * 7) % 90
            let mastered = i < 4
            let unlocked = mastered ? total
                : max(1, Int(Double(total) * max(0.05, 0.8 - Double(i) * 0.03)))
            return RAOverviewGameLine(boxArt: Self.placeholderArt(i),
                                      title: "Game \(i + 1)",
                                      unlocked: unlocked, total: total,
                                      consoleID: UInt32([4, 5, 6][i % 3]),
                                      points: 800 - i * 25)
        }
        let card = RAOverviewCardView(
            username: "RetroPlayer",
            points: games.compactMap(\.points).reduce(0, +),
            gamesCount: games.count,
            unlockedTotal: games.reduce(0) { $0 + $1.unlocked },
            games: games,
            hiddenGames: 0,
            isPro: false)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        cardImage = renderer.uiImage
    }

    /// Hue-rotating two-tone squares standing in for box art.
    private static func placeholderArt(_ i: Int) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { ctx in
            let hue = CGFloat((i * 5) % 30) / 30
            UIColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
            UIColor(hue: hue, saturation: 0.7, brightness: 0.45, alpha: 1).setFill()
            ctx.fill(CGRect(x: 10, y: 10, width: 28, height: 28))
        }
    }
}
#endif
