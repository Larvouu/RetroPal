//
//  RetroAchievementsLandscapeView.swift
//  EmulateurGBA
//
//  The RetroAchievements profile page on its side, in the landscape library's
//  language (decided on device, 2026-09-04): the same dark moving ground, the same
//  margins, a top bar of our own, and the content as glass cards. Portrait
//  keeps its List and is untouched.
//
//  A LAYOUT, not a second page. `RetroAchievementsView` still owns the
//  expansion state, the per-game loads, the layout choice and every sheet
//  (share, overview, dashboard, badge detail, about); it hands this view the
//  facts, one closure per action, and the expanded content of a game as a
//  view it builds itself, so the loading, offline and loaded shapes are the
//  ones portrait shows and were never written twice.
//
//  Left: the account (the RA mark, name, points, the total progress) and the
//  share + layout row. Right: one card per game with achievements, its header
//  the same row portrait uses (box art, title, progress) and its body the
//  expanded content when open; then the "not on RetroAchievements" card.
//

import SwiftUI

struct RetroAchievementsLandscapeView<ExpandedContent: View>: View {
    let username: String
    let points: Int
    let totalUnlocked: Int
    let totalAchievements: Int
    let games: [RAGameRecord]
    let unsupported: [RALibraryEntry]
    let expandedHash: String?
    @Binding var wallLayout: Bool
    let displayTitle: (RAGameRecord) -> String
    let onToggle: (RAGameRecord) -> Void
    let onShareOverview: () -> Void
    let onAbout: () -> Void
    /// The open game's body: skeleton, offline row, or the achievements in the
    /// chosen layout, built by the page.
    @ViewBuilder let expandedContent: (RAGameRecord) -> ExpandedContent

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An iPad window: a wider profile column, a capped column of games.
    @TabletSurface private var isTablet
    @Environment(\.surfaceSafeAreaInsets) private var surfaceInsets
    /// Observed so a theme change repaints this surface.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let insets = LandscapeChrome.insets(surfaceInsets)
            ZStack {
                LibraryLandscapeBackground(isPaused: reduceMotion, dimmed: true)

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 24)
                        .padding(.top, LandscapeChrome.barTopPadding(tablet: isTablet, insets: insets))
                    // Upright on an iPad the profile stands above the games in
                    // one scroll; on its side the two are columns.
                    Group {
                        if LandscapeChrome.isStacked(tablet: isTablet, size: size) {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 20) {
                                    profileCard
                                    gamesColumn
                                }
                                .frame(maxWidth: 720)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 8)
                            }
                        } else {
                            HStack(alignment: .top, spacing: 20) {
                                profileCard
                                    .frame(width: isTablet ? 340 : 280)
                                ScrollView(.vertical, showsIndicators: false) {
                                    gamesColumn
                                        .padding(.bottom, 8)
                                }
                                .frame(maxWidth: isTablet ? 720 : .infinity)
                            }
                        }
                    }
                    .padding(.leading, 24 + insets.left)
                    .padding(.trailing, 24 + insets.right)
                    .padding(.top, 16)
                    .padding(.bottom, 22)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                LandscapeChrome.circle(systemName: "chevron.left")
            }
            .accessibilityLabel(NSLocalizedString("tab.library", comment: ""))
            Spacer(minLength: 8)
            ControllerStatusBadge(tint: .white)
            Button(action: onAbout) {
                LandscapeChrome.circle(systemName: "info")
            }
            .accessibilityLabel(Text(String(localized: "ra.about.title",
                                            defaultValue: "About RetroAchievements")))
        }
        .frame(height: 40)
    }

    // MARK: - Left: the account

    /// The games, the empty note and the unsupported note, in order.
    private var gamesColumn: some View {
        VStack(spacing: 12) {
            ForEach(games, id: \.romHash) { record in
                gameCard(record)
            }
            if games.isEmpty {
                emptyCard
            }
            if !unsupported.isEmpty {
                unsupportedCard
            }
        }
    }

    private var profileCard: some View {
        LandscapeChrome.card(nil) {
            HStack(spacing: 10) {
                Image("RABrand")
                    .resizable().scaledToFit()
                    .frame(height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(username)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(points.formatted()) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            if totalAchievements > 0 {
                Text(String(format: String(localized: "ra.dashboard.summary",
                                           defaultValue: "%lld of %lld unlocked"),
                            totalUnlocked, totalAchievements))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                ProgressView(value: Double(totalUnlocked), total: Double(totalAchievements))
                    .tint(.yellow)
            }
            RAActionsRow(shareDisabled: games.isEmpty,
                         onShare: onShareOverview,
                         wallLayout: $wallLayout)
                .padding(.top, 4)
            Text(String(localized: "ra.dashboard.shareHint",
                        defaultValue: "Tap an unlocked achievement to share it."))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Right: the games

    private func gameCard(_ record: RAGameRecord) -> some View {
        let isOpen = expandedHash == record.romHash
        return LandscapeChrome.card(nil) {
            Button {
                onToggle(record)
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: record.boxArtURL.flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ZStack {
                            Color.white.opacity(LandscapeChrome.cardFill)
                            Image(systemName: "trophy")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayTitle(record))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if record.total > 0 {
                            ProgressView(value: Double(record.unlocked), total: Double(record.total))
                                .tint(.yellow)
                                .scaleEffect(x: 1, y: 0.8, anchor: .center)
                            Text(String(format: String(localized: "ra.dashboard.summary",
                                                       defaultValue: "%lld of %lld unlocked"),
                                        record.unlocked, record.total))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.78))
                        } else {
                            Text(String(localized: "ra.profile.expandHint",
                                        defaultValue: "Open to see its achievements"))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOpen ? .isSelected : [])

            if isOpen {
                Divider().overlay(Color.white.opacity(0.12))
                expandedContent(record)
            }
        }
    }

    private var emptyCard: some View {
        LandscapeChrome.card(String(localized: "ra.profile.games", defaultValue: "Games with achievements")) {
            Text(String(localized: "ra.dashboard.empty",
                        defaultValue: "This game has no achievements, or none are loaded yet."))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unsupportedCard: some View {
        LandscapeChrome.card(String(localized: "ra.profile.unsupported", defaultValue: "Not on RetroAchievements")) {
            ForEach(unsupported, id: \.romHash) { entry in
                Text(entry.title)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            Text(String(localized: "ra.profile.unsupported.footer",
                        defaultValue: "These games have no achievements on RetroAchievements. Sometimes only the English version of a game is covered."))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
