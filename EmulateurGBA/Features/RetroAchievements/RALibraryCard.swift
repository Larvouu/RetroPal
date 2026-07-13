//
//  RALibraryCard.swift
//  EmulateurGBA
//
//  The compact RetroAchievements card at the bottom of the library, below the
//  stats card. Shown only while at least one imported game is RA-eligible
//  (it disappears with the last one). Two states:
//    • not connected → a short invite + Connect (the login sheet also offers
//      account creation) + the (i) explainer
//    • connected → account line, overall progress, and the last achievements
//      earned in Retro Pal (tap one to open its share card); tapping the rest
//      of the card opens the full profile page
//

import SwiftUI

struct RALibraryCard: View {
    @ObservedObject private var ra = RetroAchievements.shared
    @ObservedObject private var raIndex = RAGameIndex.shared

    let onConnect: () -> Void
    let onInfo: () -> Void
    let onOpenProfile: () -> Void
    let onShareUnlock: (RAUnlockLogEntry) -> Void

    private var eligibleRecords: [RAGameRecord] {
        raIndex.records.values.filter { $0.isEligible }
    }
    private var totalUnlocked: Int { eligibleRecords.reduce(0) { $0 + $1.unlocked } }
    private var totalAchievements: Int { eligibleRecords.reduce(0) { $0 + $1.total } }
    private var recents: [RAUnlockLogEntry] { Array(raIndex.recentUnlocks.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ra.isLoggedIn {
                connectedTop
                if recents.isEmpty {
                    Text(String(localized: "ra.library.noUnlocks",
                                defaultValue: "Your latest achievements will appear here."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    recentsBlock
                }
            } else {
                invite
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Header (both states)

    private func header(showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            Image("RABrand")
                .resizable().scaledToFit()
                .frame(height: 16)
                .accessibilityHidden(true)
            Text("RetroAchievements")
                .font(.headline)
            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "ra.about.title",
                                            defaultValue: "About RetroAchievements")))
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Connected

    /// Header + account + overall progress. This whole block navigates; the
    /// recents below keep their own per-row share taps.
    private var connectedTop: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(showsChevron: true)
            HStack {
                Text(ra.displayName ?? ra.username ?? "")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(ra.softcoreScore) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
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
        .contentShape(Rectangle())
        .onTapGesture { Haptics.tap(); onOpenProfile() }
    }

    private var recentsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "ra.library.recent", defaultValue: "Last unlocked"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(recents) { entry in
                Button { onShareUnlock(entry) } label: {
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
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Not connected

    private var invite: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(showsChevron: false)
            Text(String(localized: "ra.library.invite.caption",
                        defaultValue: "Your games have RetroAchievements sets. Connect a free account to earn achievements as you play."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onConnect) {
                Text(String(localized: "ra.connect", defaultValue: "Connect your account"))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
