//
//  RetroStoryView.swift
//  EmulateurGBA
//
//  The Retro story page (2026-10-28), pushed from the library's story button,
//  where a small card in a sheet used to be. Its job: a player sees the whole
//  of what they have played here, and has a reason to stay (their history
//  lives here, kept on every device, `PlayHistory`); sharing is one action on
//  it, not its point.
//
//  Ordered by what a player remembers (the design review of 10-28):
//   1. The headline: the total, since when, games played of the library, the
//      sessions as a small line.
//   2. Most played: the top five games, a tap opening the game's page.
//   3. Your consoles: the consoles PLAYED only, never a grid of thirteen with
//      zeros, "6 of 13 tried"; a tap opens the console's page.
//   4. The timeline: first game, first on each console, hours crossed.
//   5. Your saves, then a row to RetroAchievements.
//
//  Upright one List in the chosen look (`uprightLook`); on its side the
//  RetroAchievements page's two columns (`RetroStoryLandscapeScaffold`), the
//  summary at the left and the cards at the right, stacked on an upright iPad.
//  Both draw the same rows.
//

import SwiftUI

struct RetroStoryView: View {
    @ObservedObject private var model = RetroStoryModel.shared
    @ObservedObject private var ra = RetroAchievements.shared
    @ObservedObject private var raIndex = RAGameIndex.shared
    @Environment(\.dismiss) private var dismiss

    /// A game's page, by its ROM hash, built by the library (its play and
    /// delete actions are the library's). Pushed from here, so it stacks on
    /// this page and Back returns to it.
    let gamePage: (String) -> AnyView
    /// The RetroAchievements login (a sheet, the library's); signed in, the
    /// RetroAchievements page is pushed from here.
    let onLoginRA: () -> Void
    /// The card being shared (the whole story, a game, a console), shown in
    /// the share sheet; the page owns it since 2026-10-28 phase 3.
    @State private var sharing: StoryCard?
    /// A screenshot of this page offers the story card once per visit, as the
    /// in-game screenshot offers its card.
    @State private var offeredOnScreenshot = false
    @State private var isVisible = false

    /// The console whose page is open (iOS 16: a flag and a value, not
    /// `navigationDestination(item:)`, which is iOS 17).
    @State private var console: String?
    @State private var showsConsole = false
    @State private var openedGame: String?
    @State private var showsGame = false
    @State private var showsRA = false
    @State private var showsYear = false
    /// The year the cover shows, taken when it opens (`yearButton`).
    @State private var openedYear: PlayStats.Year?
    /// A phone on its side, or an iPad window (see `LandscapeSurface`).
    @LandscapeSurface private var isLandscape

    var body: some View {
        Group {
            if isLandscape {
                landscape
            } else {
                list
                    // Held still while the year in review covers it.
                    .uprightLook(isActive: !showsYear)
                    // B goes back, as the system back button does.
                    .controllerBack { dismiss() }
            }
        }
        .navigationTitle(NSLocalizedString("story.title", comment: ""))
        .toolbar {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarTrailing) { shareButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { shareButton }
            }
        }
        .navigationDestination(isPresented: $showsConsole) {
            if let system = console, let stats = model.stats,
               let entry = stats.consoles.first(where: { $0.system == system }) {
                RetroStoryConsoleView(console: entry, gamePage: gamePage,
                                      onShare: { sharing = .console(entry) })
            }
        }
        .navigationDestination(isPresented: $showsGame) {
            if let openedGame { gamePage(openedGame) }
        }
        .navigationDestination(isPresented: $showsRA) {
            RetroAchievementsView()
        }
        .onAppear {
            isVisible = true
            model.recompute()
        }
        .onDisappear { isVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            // Only while this page is the one showing, once per visit, and
            // never over a card already open.
            guard isVisible, !offeredOnScreenshot, sharing == nil, model.stats?.hasData == true,
                  !showsConsole, !showsGame, !showsRA, !showsYear else { return }
            offeredOnScreenshot = true
            sharing = .overall
        }
        .fullScreenCover(isPresented: $showsYear) {
            // The year as it was when opened (`openedYear`), never the live
            // model: a recompute or a pull that took the year away while it was
            // open left a black cover whose own closing, asked mid-presentation
            // or under its share sheet, iOS 16 can drop, with no way out
            // (audit, 2026-10-30). A year that changes while open is the next
            // opening's.
            if let year = openedYear {
                YearInReviewView(year: year) { showsYear = false }
            }
        }
        .sheet(item: $sharing) { card in
            // The overall card reads the stats; the others carry their own.
            RetroStoryShareView(card: card, stats: model.stats) { sharing = nil }
        }
    }

    private var shareButton: some View {
        FocusableButton(action: { sharing = .overall }) {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel(NSLocalizedString("screenshot.share", comment: ""))
        .disabled(!(model.stats?.hasData ?? false))
    }

    @ViewBuilder
    private var list: some View {
        List {
            if let year = model.year {
                // The year in review leads the page from December 1 through
                // January (phase 4).
                Section {
                    yearButton(year)
                }
                .landscapeGlassRow()
            }
            if let stats = model.stats, stats.hasData {
                Section {
                    RetroStoryHeadline(stats: stats)
                }
                .landscapeGlassRow()

                // The most played, larger and in a section of its own; the
                // next four under it (his ask of 10-28).
                Section {
                    topGameButton(stats)
                } header: {
                    Text(NSLocalizedString("library.stats.topGames", comment: ""))
                }
                .landscapeGlassRow()
                if stats.games.count > 1 {
                    Section {
                        otherGameButtons(stats)
                    }
                    .landscapeGlassRow()
                }

                Section {
                    consoleButtons(stats)
                } header: {
                    Text(NSLocalizedString("story.consoles", comment: ""))
                } footer: {
                    Text(consolesTried(stats))
                        .monospacedDigit()
                }
                .landscapeGlassRow()

                Section {
                    RetroStoryActivity(stats: stats)
                } header: {
                    Text(NSLocalizedString("story.activity", comment: ""))
                }
                .landscapeGlassRow()

                if !stats.milestones.isEmpty {
                    Section {
                        ForEach(stats.milestones) { milestone in
                            RetroStoryMilestoneRow(milestone: milestone)
                        }
                    } header: {
                        Text(NSLocalizedString("story.timeline", comment: ""))
                    }
                    .landscapeGlassRow()
                }

                Section {
                    RetroStorySavesRow()
                    raButton
                } header: {
                    Text(NSLocalizedString("story.kept", comment: ""))
                } footer: {
                    Text(NSLocalizedString("story.kept.footer", comment: ""))
                }
                .landscapeGlassRow()
            } else if model.stats != nil {
                Section {
                    Text(NSLocalizedString("story.empty", comment: ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                .landscapeGlassRow()
            } else {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
                .landscapeGlassRow()
            }
        }
    }

    // MARK: On its side

    /// The RetroAchievements page's layout (`RetroStoryLandscapeScaffold`):
    /// the headline and the activity at the left, the games, the consoles,
    /// the timeline and what is kept at the right.
    private var landscape: some View {
        RetroStoryLandscapeScaffold(
            title: NSLocalizedString("story.title", comment: ""),
            backLabel: NSLocalizedString("tab.library", comment: ""),
            shareEnabled: model.stats?.hasData ?? false,
            isActive: !showsYear,
            onShare: { sharing = .overall },
            summary: {
                if let year = model.year {
                    RetroStoryLandscapeCard(title: nil) { yearButton(year) }
                }
                if let stats = model.stats, stats.hasData {
                    RetroStoryLandscapeCard(title: nil) { RetroStoryHeadline(stats: stats) }
                    RetroStoryLandscapeCard(title: NSLocalizedString("story.activity", comment: "")) {
                        RetroStoryActivity(stats: stats)
                    }
                } else if model.stats != nil {
                    RetroStoryLandscapeCard(title: nil) {
                        Text(NSLocalizedString("story.empty", comment: ""))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            },
            cards: {
                if let stats = model.stats, stats.hasData {
                    RetroStoryLandscapeCard(title: NSLocalizedString("library.stats.topGames", comment: "")) {
                        topGameButton(stats)
                        if stats.games.count > 1 {
                            RetroStoryDivider()
                            otherGameButtons(stats)
                        }
                    }
                    RetroStoryLandscapeCard(title: NSLocalizedString("story.consoles", comment: ""),
                                            footnote: consolesTried(stats)) {
                        consoleButtons(stats)
                    }
                    if !stats.milestones.isEmpty {
                        RetroStoryLandscapeCard(title: NSLocalizedString("story.timeline", comment: "")) {
                            ForEach(stats.milestones) { RetroStoryMilestoneRow(milestone: $0) }
                        }
                    }
                    RetroStoryLandscapeCard(title: NSLocalizedString("story.kept", comment: ""),
                                            footnote: NSLocalizedString("story.kept.footer", comment: "")) {
                        RetroStorySavesRow()
                        raButton
                    }
                }
            })
    }

    // MARK: Rows both layouts share

    private func yearButton(_ year: PlayStats.Year) -> some View {
        FocusableButton(shape: .cell, isDefault: true) {
            Haptics.tap()
            openedYear = year
            showsYear = true
        } label: {
            RetroStoryYearRow(year: year)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func topGameButton(_ stats: PlayStats) -> some View {
        if let top = stats.games.first {
            gameRow(top, maxSeconds: top.seconds, featured: true)
        }
    }

    /// The second to the fifth.
    @ViewBuilder
    private func otherGameButtons(_ stats: PlayStats) -> some View {
        ForEach(stats.games.dropFirst().prefix(4)) { game in
            gameRow(game, maxSeconds: stats.games.first?.seconds ?? 1)
        }
    }

    /// The consoles as a donut and its legend (2026-10-28; a list of rows
    /// until then); the legend opens each console's page.
    private func consoleButtons(_ stats: PlayStats) -> some View {
        RetroStoryConsoleDonut(stats: stats) { system in
            console = system
            showsConsole = true
        }
    }

    private func consolesTried(_ stats: PlayStats) -> String {
        "\(NSLocalizedString("story.consoles.tried", comment: "")) \(stats.consoles.count) / \(PlayStats.consoleCount)"
    }

    @ViewBuilder
    private var raButton: some View {
        if ra.isEnabled, raIndex.hasEligibleGame {
            FocusableButton(shape: .cell) {
                Haptics.tap()
                if ra.isLoggedIn { showsRA = true } else { onLoginRA() }
            } label: {
                RetroStoryRARow()
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func gameRow(_ game: PlayStats.GameStat, maxSeconds: Double, featured: Bool = false) -> some View {
        if game.inLibrary {
            FocusableButton(shape: .cell) {
                Haptics.tap()
                openedGame = game.romHash
                showsGame = true
            } label: {
                RetroStoryGameRow(game: game, maxSeconds: maxSeconds, showsChevron: true, featured: featured)
            }
            .buttonStyle(.plain)
            .contextMenu { shareGameItem(game) }
        } else {
            RetroStoryGameRow(game: game, maxSeconds: maxSeconds, showsChevron: false, featured: featured)
                .controllerFocusable(action: nil)
                .contextMenu { shareGameItem(game) }
        }
    }

    private func shareGameItem(_ game: PlayStats.GameStat) -> some View {
        Button {
            sharing = .game(game)
        } label: {
            Label(NSLocalizedString("story.share.game", comment: ""), systemImage: "square.and.arrow.up")
        }
    }
}

/// One console's page: its time, its games most played first, its first game.
/// Upright a List in the look; on its side the story's two columns, the
/// console at the left, its games at the right.
struct RetroStoryConsoleView: View {
    let console: PlayStats.ConsoleStat
    let gamePage: (String) -> AnyView
    /// Shares this console's card (the story page's sheet), from the top
    /// right as on the story page.
    let onShare: () -> Void
    @State private var openedGame: String?
    @State private var showsGame = false
    @LandscapeSurface private var isLandscape
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if isLandscape {
                RetroStoryLandscapeScaffold(
                    title: SystemColor.name(console.system),
                    backLabel: NSLocalizedString("story.title", comment: ""),
                    shareEnabled: true,
                    onShare: onShare,
                    summary: {
                        RetroStoryLandscapeCard(title: nil) { summaryRow }
                    },
                    cards: {
                        RetroStoryLandscapeCard(title: NSLocalizedString("library.stats.topGames", comment: "")) {
                            gameRow(0)
                            if console.games.count > 1 {
                                RetroStoryDivider()
                                ForEach(1..<console.games.count, id: \.self) { gameRow($0) }
                            }
                        }
                    })
            } else {
                List {
                    Section { summaryRow }
                        .landscapeGlassRow()
                    // The console's most played, larger and apart; the rest under.
                    Section {
                        gameRow(0)
                    } header: {
                        Text(NSLocalizedString("library.stats.topGames", comment: ""))
                    }
                    .landscapeGlassRow()
                    if console.games.count > 1 {
                        Section {
                            ForEach(1..<console.games.count, id: \.self) { gameRow($0) }
                        }
                        .landscapeGlassRow()
                    }
                }
                .uprightLook()
                .controllerBack { dismiss() }
            }
        }
        .navigationTitle(SystemColor.name(console.system))
        .toolbar {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarTrailing) { shareButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { shareButton }
            }
        }
        .navigationDestination(isPresented: $showsGame) {
            if let openedGame { gamePage(openedGame) }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 14) {
            ConsoleMark(systemType: console.system, width: 56, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(RetroStoryFormat.duration(console.seconds))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text("\(NSLocalizedString("library.stats.gamesPlayed", comment: "")) \(console.gamesPlayed.formatted())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let first = console.firstPlayed {
                    Text(String(format: NSLocalizedString("story.since", comment: ""),
                                RetroStoryFormat.date(first)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    /// The console's game at `index`, the first one featured.
    @ViewBuilder
    private func gameRow(_ index: Int) -> some View {
        if console.games.indices.contains(index) {
            let game = console.games[index]
            let maxSeconds = console.games.first?.seconds ?? 1
            if game.inLibrary {
                FocusableButton(shape: .cell) {
                    Haptics.tap()
                    openedGame = game.romHash
                    showsGame = true
                } label: {
                    RetroStoryGameRow(game: game, maxSeconds: maxSeconds, showsChevron: true,
                                      showsConsole: false, featured: index == 0)
                }
                .buttonStyle(.plain)
            } else {
                RetroStoryGameRow(game: game, maxSeconds: maxSeconds, showsChevron: false,
                                  showsConsole: false, featured: index == 0)
                    .controllerFocusable(action: nil)
            }
        }
    }

    private var shareButton: some View {
        FocusableButton(action: onShare) {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel(NSLocalizedString("screenshot.share", comment: ""))
    }
}
