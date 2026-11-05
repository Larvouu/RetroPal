//
//  RetroAchievementsLandscapeView.swift
//  EmulateurGBA
//
//  The RetroAchievements profile page on its side, in the landscape library's
//  language (decided on device, 2026-09-04): the same dark moving ground, the same
//  margins, a top bar of our own, and the content as glass cards. Portrait
//  keeps its List and is untouched.
//
//  A LAYOUT, not a second page. `RetroAchievementsView` owns every sheet
//  (share, overview, the game's dashboard, about); it hands this view the
//  facts and one closure per action, and both layouts draw the same rows
//  (`RAProfileRows.swift`) and the same summary (`RAProfileSummary`).
//
//  Left: the account with the last three achievements (`RAProfileSummary`)
//  and the share. Right: one card per game with achievements, a tap opening
//  its own sheet (2026-10-28; the card used to open in place); then the
//  "not on RetroAchievements" card, by console, the 3DS as one row.
//

import SwiftUI

struct RetroAchievementsLandscapeView: View {
    let totalUnlocked: Int
    let totalAchievements: Int
    let games: [RAGameRecord]
    /// Sorted by the page: by console, then by name.
    let unsupported: [RALibraryEntry]
    /// The 3DS's one row, last, when the library holds a 3DS game.
    let showsN3DSRow: Bool
    /// The unsupported card's note, the 3DS sentence included when its row is.
    let unsupportedFooter: String
    let displayTitle: (RAGameRecord) -> String
    /// The library's game behind an unsupported entry, for its console and cover.
    let libraryGame: (RALibraryEntry) -> GameEntity?
    let onOpenGame: (RAGameRecord) -> Void
    let onShareUnlock: (RAUnlockLogEntry) -> Void
    let onShareOverview: () -> Void
    let onAbout: () -> Void

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
            FocusableButton {
                dismiss()
            } label: {
                LandscapeChrome.circle(systemName: "chevron.left")
            }
            .accessibilityLabel(NSLocalizedString("tab.library", comment: ""))
            Spacer(minLength: 8)
            ControllerStatusBadge(tint: .white)
            FocusableButton(action: onAbout) {
                LandscapeChrome.circle(systemName: "info")
            }
            .accessibilityLabel(Text(String(localized: "ra.about.title",
                                            defaultValue: "About RetroAchievements")))
        }
        .frame(height: 40)
    }

    /// The games, the empty note and the unsupported note, in order.
    private var gamesColumn: some View {
        VStack(spacing: 12) {
            ForEach(games, id: \.romHash) { record in
                gameCard(record)
            }
            if games.isEmpty {
                emptyCard
            }
            if !unsupported.isEmpty || showsN3DSRow {
                unsupportedCard
            }
        }
    }

    // MARK: - Left: the account

    private var profileCard: some View {
        LandscapeChrome.card(nil) {
            RAProfileSummary(totalUnlocked: totalUnlocked,
                             totalAchievements: totalAchievements,
                             onShareUnlock: onShareUnlock)
            RAActionsRow(shareDisabled: games.isEmpty,
                         onShare: onShareOverview)
                .padding(.top, 4)
        }
    }

    // MARK: - Right: the games

    private func gameCard(_ record: RAGameRecord) -> some View {
        LandscapeChrome.card(nil) {
            FocusableButton {
                onOpenGame(record)
            } label: {
                RAGameRowLabel(record: record, title: displayTitle(record))
            }
            .buttonStyle(.plain)
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
                RAUnsupportedGameRow(title: entry.title, game: libraryGame(entry))
            }
            if showsN3DSRow {
                RAUnsupportedN3DSRow()
            }
            Text(unsupportedFooter)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
