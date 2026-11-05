//
//  RetroAchievementsView.swift
//  EmulateurGBA
//
//  The RetroAchievements profile page, pushed from the library's trophy: the
//  account with the last three achievements earned in Retro Pal, the share of
//  the whole profile, then every game with achievements and, below, the games
//  RetroAchievements does not cover.
//
//  Since 2026-10-28 a game is ONE tap to its own sheet (`RAAchievementsView`,
//  the per-game dashboard), which is where its achievements are listed, laid
//  out (rows or badge wall) and shared. The page used to open each game in
//  place and offered "Open the game page" inside it; with the achievements
//  off this page, its layout radio and its "tap an achievement" line went
//  too. The unsupported games are sorted by console, then by name, each with
//  its console's drawing and its library cover, small; the 3DS is ONE row of
//  its own at the end, since RetroAchievements has no 3DS games at all.
//

import SwiftUI

struct RetroAchievementsView: View {
    @ObservedObject private var ra = RetroAchievements.shared
    @ObservedObject private var raIndex = RAGameIndex.shared
    /// A phone on its side, or an iPad window (see `LandscapeSurface`).
    @LandscapeSurface private var isLandscape
    /// For B (`controllerBack`): back to the library.
    @Environment(\.dismiss) private var dismiss

    @State private var shareTarget: RAShareTarget?
    @State private var showAbout = false
    /// Drives the profile OVERVIEW share card (all games + totals).
    @State private var showOverviewShare = false
    /// Drives a game's full dashboard sheet, opened by a tap on its row.
    @State private var gameDashboard: GameDashboardTarget?
    /// The library, for each unsupported game's console and cover. The index
    /// knows a game by its hash and its file; the console and the cover are
    /// the library's.
    @FetchRequest(entity: GameEntity.entity(), sortDescriptors: [])
    private var libraryGames: FetchedResults<GameEntity>

    struct GameDashboardTarget: Identifiable {
        let id = UUID()
        let romURL: URL
    }

    private var romsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ROMs", isDirectory: true)
    }

    /// The user-facing name: the LIBRARY title (edited or import-derived), so
    /// a row never renames or moves when RA metadata arrives. The exact RA set
    /// name is shown in the game's dashboard instead.
    private func displayTitle(_ record: RAGameRecord) -> String {
        if let libraryTitle = raIndex.libraryTitle(forROMHash: record.romHash),
           !libraryTitle.isEmpty {
            return libraryTitle
        }
        return record.title ?? fallbackTitle(record)
    }

    /// Games that can actually EARN something: identified on RA AND their set
    /// has at least one achievement (RA also knows games with empty sets —
    /// those read as unsupported to a player, so they list below instead).
    /// Ranked by progress — points earned, descending (matching the overview
    /// share card), then unlocked count (so freshly-connected accounts rank
    /// sensibly before any game's first load fills its points in), then
    /// alphabetical by LIBRARY title.
    private var gamesWithAchievements: [RAGameRecord] {
        raIndex.records.values
            .filter { $0.isEligible && $0.total > 0 }
            .sorted {
                let p0 = $0.pointsEarned ?? 0, p1 = $1.pointsEarned ?? 0
                if p0 != p1 { return p0 > p1 }
                if $0.unlocked != $1.unlocked { return $0.unlocked > $1.unlocked }
                return displayTitle($0).localizedCaseInsensitiveCompare(displayTitle($1)) == .orderedAscending
            }
    }

    /// Games with nothing to earn: no RA set at all, or a set we have actually
    /// seen to be empty. Listed below the eligible ones so it's obvious which
    /// games can earn achievements.
    ///
    /// "We have actually seen" is the whole point of `countsFromLoad`. A record
    /// can be eligible — RA resolved its hash to a real game — while its totals
    /// are still zero, because the counts arrive either from playing it once or
    /// from the all-user-progress refresh, and neither is guaranteed to have
    /// happened yet. Treating that zero as "no achievements" states a fact we do
    /// not have, and it is wrong exactly when it is most visible: a famous game
    /// whose set anyone can look up. Reported on Super Mario World, whose hash
    /// resolves fine.
    private var unsupportedEntries: [RALibraryEntry] {
        // The library looked up once, and each entry's console once: the sort
        // asked `gamesByFilename` (a dictionary of the whole library) twice per
        // comparison, a hitch on a big library at every index publish (audit,
        // 2026-10-29).
        let byFilename = gamesByFilename
        return raIndex.libraryEntries.values
            .filter { entry in
                if !entry.raSupportedConsole { return true }
                if let record = raIndex.records[entry.romHash] {
                    if !record.isEligible { return true }
                    // Eligible: only an actual load can tell us the set is empty.
                    return record.hasKnownEmptySet
                }
                return false   // still resolving: not known to be unsupported
            }
            // The 3DS is one row of its own (`showsN3DSRow`), not its games.
            .map { entry -> (entry: RALibraryEntry, system: String?) in
                (entry, byFilename[entry.filename]?.systemType)
            }
            .filter { $0.system != "n3ds" }
            // By console, in the library's canonical order, then A-Z by the
            // name shown, one list (2026-10-28).
            .map { pair -> (entry: RALibraryEntry, rank: Int) in
                (pair.entry, Self.consoleOrder.firstIndex(of: pair.system ?? "") ?? Int.max)
            }
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                return a.entry.title.localizedStandardCompare(b.entry.title) == .orderedAscending
            }
            .map(\.entry)
    }

    /// The library's console order (`LibraryView`'s, which the sort menu uses).
    private static let consoleOrder = ["gba", "gb", "gbc", "nds", "snes", "nes", "ps1", "n64", "md",
                                       "sms", "gg", "psp", "n3ds"]

    /// The library's games by their file (`GameEntity.romFilePath`, the key
    /// the index's entries carry as `filename`).
    private var gamesByFilename: [String: GameEntity] {
        Dictionary(libraryGames.compactMap { game in game.romFilePath.map { ($0, game) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// RetroAchievements covers no 3DS game: one row says so for all of them,
    /// shown only when the library holds one (decided 2026-10-28).
    private var showsN3DSRow: Bool {
        libraryGames.contains { $0.systemType == "n3ds" }
    }

    /// The unsupported footer, which names the 3DS when that row is shown.
    /// One whole text per case, not a sentence appended: the join between two
    /// sentences is not a space in every language (Japanese, Chinese).
    private var unsupportedFooter: String {
        showsN3DSRow
            ? String(localized: "ra.profile.unsupported.footer.n3ds",
                     defaultValue: "These games have no achievements on RetroAchievements. Sometimes only the English version of a game is covered. RetroAchievements does not support any 3DS game.")
            : String(localized: "ra.profile.unsupported.footer",
                     defaultValue: "These games have no achievements on RetroAchievements. Sometimes only the English version of a game is covered.")
    }

    private var hasUnsupported: Bool { !unsupportedEntries.isEmpty || showsN3DSRow }

    private var totalUnlocked: Int { gamesWithAchievements.reduce(0) { $0 + $1.unlocked } }
    private var totalAchievements: Int { gamesWithAchievements.reduce(0) { $0 + $1.total } }

    var body: some View {
        Group {
            if isLandscape {
                landscapeBody
            } else {
                portraitList
                    .uprightLook()
            }
        }
        // Large title, mirroring the Library: the inline bar truncated
        // "RetroAchievements" on smaller widths.
        .navigationTitle("RetroAchievements")
        // Landscape draws its own bar (back, about) on the library's ground,
        // so the system bars are hidden there and only there.
        .toolbar(isLandscape ? .hidden : .visible, for: .navigationBar)
        .toolbar(isLandscape ? .hidden : .visible, for: .tabBar)
        .toolbar {
            // Only the (i) remains up here (share moved into the list); on
            // iOS 26 it shows RAW, without the Liquid Glass capsule.
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarTrailing) { aboutButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { aboutButton }
            }
        }
        .sheet(isPresented: $showAbout) { RAAboutSheet() }
        .sheet(item: $shareTarget) { target in
            RAShareView(achievement: target.achievement,
                        gameName: target.gameName,
                        boxArtURL: target.boxArtURL,
                        romFilename: target.romFilename,
                        onClose: { shareTarget = nil })
        }
        .sheet(isPresented: $showOverviewShare) {
            RAOverviewShareView(username: ra.displayName ?? ra.username ?? "",
                                points: ra.softcoreScore,
                                records: gamesWithAchievements,
                                onClose: { showOverviewShare = false })
        }
        // A sheet on a phone, the whole window on an iPad (`pagePresentation`).
        .pagePresentation(item: $gameDashboard) { target in
            // The game's full RA dashboard (it owns the per-game share).
            RAAchievementsView(romURL: target.romURL)
        }
        .onAppear { ra.refreshProgressIfNeeded() }
        // B goes back to the library, as the back button does.
        .controllerBack { dismiss() }
    }

    /// The landscape layout, fed with this page's facts and one closure per
    /// action; the sheets stay here, shared by both layouts.
    private var landscapeBody: some View {
        RetroAchievementsLandscapeView(
            totalUnlocked: totalUnlocked,
            totalAchievements: totalAchievements,
            games: gamesWithAchievements,
            unsupported: unsupportedEntries,
            showsN3DSRow: showsN3DSRow,
            unsupportedFooter: unsupportedFooter,
            displayTitle: { displayTitle($0) },
            libraryGame: { gamesByFilename[$0.filename] },
            onOpenGame: { openGame($0) },
            onShareUnlock: { shareUnlock($0) },
            onShareOverview: { showOverviewShare = true },
            onAbout: { showAbout = true })
    }

    private var portraitList: some View {
        List {
            // Share as the profile section's FOOTER: outside the section
            // card, straight on the view background. As a list ROW iOS 26
            // clipped its content to the card's big concentric corner, which
            // lopsided the share pill's left edge.
            Section {
                RAProfileSummary(totalUnlocked: totalUnlocked,
                                 totalAchievements: totalAchievements,
                                 onShareUnlock: { shareUnlock($0) })
                    .padding(.vertical, 2)
            } footer: {
                RAActionsRow(shareDisabled: gamesWithAchievements.isEmpty,
                             onShare: { showOverviewShare = true })
                    .padding(.top, 8)
            }
            .landscapeGlassRow()

            Section {
                ForEach(gamesWithAchievements, id: \.romHash) { record in
                    FocusableButton(shape: .cell) {
                        openGame(record)
                    } label: {
                        RAGameRowLabel(record: record, title: displayTitle(record))
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(String(localized: "ra.profile.games", defaultValue: "Games with achievements"))
            }
            .landscapeGlassRow()

            if hasUnsupported {
                Section {
                    ForEach(unsupportedEntries, id: \.romHash) { entry in
                        RAUnsupportedGameRow(title: entry.title, game: gamesByFilename[entry.filename])
                    }
                    if showsN3DSRow {
                        RAUnsupportedN3DSRow()
                    }
                } header: {
                    Text(String(localized: "ra.profile.unsupported",
                                defaultValue: "Not on RetroAchievements"))
                } footer: {
                    Text(unsupportedFooter)
                }
                .landscapeGlassRow()
            }
        }
    }

    private var aboutButton: some View {
        FocusableButton { showAbout = true } label: {
            Image(systemName: "info.circle")
        }
        .accessibilityLabel(Text(String(localized: "ra.about.title",
                                        defaultValue: "About RetroAchievements")))
    }

    // MARK: - Actions

    /// The game's own sheet, where its achievements are.
    private func openGame(_ record: RAGameRecord) {
        guard let filename = raIndex.filename(forROMHash: record.romHash) else { return }
        Haptics.tap()
        gameDashboard = GameDashboardTarget(romURL: romsDir.appendingPathComponent(filename))
    }

    /// One of the last achievements earned, to its share card.
    private func shareUnlock(_ entry: RAUnlockLogEntry) {
        shareTarget = RAShareTarget(
            achievement: entry.asAchievementInfo(),
            gameName: entry.gameTitle,
            boxArtURL: entry.boxArtURL.flatMap(URL.init(string:)),
            romFilename: raIndex.filename(forGameID: entry.gameID))
    }

    /// A record can predate its first RA title (progress refresh has counts but
    /// no metadata): fall back to the imported file's name.
    private func fallbackTitle(_ record: RAGameRecord) -> String {
        guard let filename = raIndex.filename(forROMHash: record.romHash) else { return "" }
        // The key is a path relative to the ROMs folder; a disc game's carries
        // its folder, which is not part of a title.
        return ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
