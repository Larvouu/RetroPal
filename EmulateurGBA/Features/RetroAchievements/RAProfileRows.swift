//
//  RAProfileRows.swift
//  EmulateurGBA
//
//  The rows of the RetroAchievements page, shared by its upright List and its
//  landscape cards (2026-10-28). Ink comes from the environment: the page is
//  dark on the ground either way up, so `.primary` is white there.
//
//  - A game with achievements is ONE tap to its own sheet (the per-game
//    dashboard, which keeps the achievements, their layout choice and the
//    per-game share). The page no longer opens a game in place.
//  - A game RetroAchievements does not cover shows its console's drawing and
//    its library cover, small; the 3DS, which RetroAchievements does not
//    cover at all, is one row of its own at the end instead of its games.
//

import SwiftUI

/// A game with achievements: its RA image, its title, the progress bar, and
/// under it "67 of 90 unlocked" on the left and the points on the right, as
/// the game's sheet says them. The points are known once the game's set has
/// been loaded in the app (played, or its sheet opened); until then the right
/// side stays empty rather than guessing (decided 2026-10-28).
struct RAGameRowLabel: View {
    let record: RAGameRecord
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: record.boxArtURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.gray.opacity(0.15)
                    Image(systemName: "trophy")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // The page lists only games whose set has achievements
                // (`total > 0`), so the bar always has a total.
                ProgressView(value: Double(record.unlocked), total: Double(max(record.total, 1)))
                    .tint(.yellow)
                    .scaleEffect(x: 1, y: 0.8, anchor: .center)
                HStack(spacing: 8) {
                    Text(String(format: String(localized: "ra.dashboard.summary",
                                               defaultValue: "%lld of %lld unlocked"),
                                record.unlocked, record.total))
                    Spacer(minLength: 8)
                    if let earned = record.pointsEarned, let total = record.pointsTotal, total > 0 {
                        Text("\(earned.formatted()) / \(total.formatted()) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// The console column and the cover column of the unsupported rows, so the
/// titles start at one edge whatever the row.
enum RAUnsupportedRowMetrics {
    static let consoleWidth: CGFloat = 26
    static let consoleHeight: CGFloat = 18
    static let coverSide: CGFloat = 30
}

/// A game RetroAchievements does not cover: its console's drawing, its cover
/// as the library shows it (the cover picked for it, else the library's
/// default, else the last quick-save's screenshot), small, then its name.
struct RAUnsupportedGameRow: View {
    let title: String
    /// The library's game, for its console and its cover; nil only if the
    /// index lists a game the library no longer holds.
    let game: GameEntity?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let system = game?.systemType {
                    ConsoleMark(systemType: system,
                                width: RAUnsupportedRowMetrics.consoleWidth,
                                height: RAUnsupportedRowMetrics.consoleHeight)
                } else {
                    Color.clear
                }
            }
            .frame(width: RAUnsupportedRowMetrics.consoleWidth)
            .accessibilityHidden(true)
            Group {
                if let game {
                    LibraryLandscapeTile(game: game, side: RAUnsupportedRowMetrics.coverSide,
                                         isSelected: false, saveTick: 0, showsConsoleTag: false)
                } else {
                    RoundedRectangle(cornerRadius: RAUnsupportedRowMetrics.coverSide * 0.11, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }
            }
            .frame(width: RAUnsupportedRowMetrics.coverSide, height: RAUnsupportedRowMetrics.coverSide)
            .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The 3DS's one row, last: RetroAchievements has no 3DS games at all, so the
/// player's 3DS games are not listed one by one; the drawing and "3DS games"
/// say it at once. Shown only when the library holds a 3DS game.
struct RAUnsupportedN3DSRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ConsoleMark(systemType: "n3ds",
                        width: RAUnsupportedRowMetrics.consoleWidth,
                        height: RAUnsupportedRowMetrics.consoleHeight)
                .frame(width: RAUnsupportedRowMetrics.consoleWidth)
                .accessibilityHidden(true)
            // The cover column stays empty so the label lines up with the
            // games' names above it.
            Color.clear
                .frame(width: RAUnsupportedRowMetrics.coverSide, height: RAUnsupportedRowMetrics.coverSide)
                .accessibilityHidden(true)
            Text(String(localized: "ra.profile.unsupported.n3ds", defaultValue: "3DS games"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
