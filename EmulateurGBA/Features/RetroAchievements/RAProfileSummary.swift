//
//  RAProfileSummary.swift
//  EmulateurGBA
//
//  The first block of the RetroAchievements page (2026-10-28): the account
//  line, the overall progress, and the last three achievements earned in
//  Retro Pal (tap one to open its share card). It was the RetroAchievements
//  card at the bottom of the Classic library; when Classic took the looks'
//  library that card had nowhere left to stand, and it replaced the page's
//  own header, which said the same first lines without the recents. The
//  page reaches it signed in only, so the card's invite state went with it,
//  and the about (i) is the page's bar's.
//
//  Ink comes from the environment (`.primary` / `.secondary`): the page sets
//  the dark scheme on the ground, so one block serves upright and on its
//  side, inside the List row or the landscape card that holds it.
//

import SwiftUI

struct RAProfileSummary: View {
    @ObservedObject private var ra = RetroAchievements.shared
    @ObservedObject private var raIndex = RAGameIndex.shared

    /// The totals of the games with achievements, as the page counts them.
    let totalUnlocked: Int
    let totalAchievements: Int
    let onShareUnlock: (RAUnlockLogEntry) -> Void

    private var recents: [RAUnlockLogEntry] { Array(raIndex.recentUnlocks.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            account
            if recents.isEmpty {
                Text(String(localized: "ra.library.noUnlocks",
                            defaultValue: "Your latest achievements will appear here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                recentsBlock
            }
        }
    }

    /// The RA mark, the account and its points, the overall progress.
    private var account: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image("RABrand")
                    .resizable().scaledToFit()
                    .frame(height: 16)
                    .accessibilityHidden(true)
                Text("RetroAchievements")
                    .font(.headline)
            }
            HStack {
                Text(ra.displayName ?? ra.username ?? "")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(ra.softcoreScore.formatted()) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if totalAchievements > 0 {
                ProgressView(value: Double(totalUnlocked), total: Double(totalAchievements))
                    .tint(.yellow)
                Text(String(format: String(localized: "ra.dashboard.summary",
                                           defaultValue: "%lld of %lld unlocked"),
                            totalUnlocked, totalAchievements))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recentsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "ra.library.recent", defaultValue: "Last unlocked"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(recents) { entry in
                FocusableButton { onShareUnlock(entry) } label: {
                    HStack(spacing: 10) {
                        AsyncImage(url: entry.badgeURL.flatMap(URL.init(string:))) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.15)
                        }
                        .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(entry.gameTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(entry.date.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
