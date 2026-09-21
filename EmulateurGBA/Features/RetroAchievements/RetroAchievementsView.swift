//
//  RetroAchievementsView.swift
//  EmulateurGBA
//
//  The RetroAchievements profile page, pushed from the library's RA card: the
//  signed-in account at the top, then every eligible imported game as a
//  collapsible row (box art, progress, points) in the spirit of the games list
//  on a retroachievements.org profile, rendered in Retro Pal's native UI.
//  Expanding a game display-loads its set through rc_client (one at a time, no
//  running game needed); already-expanded data stays cached for the visit.
//
//  NOTE: rc_client can only hold ONE loaded game, so expansion loads lazily
//  and the fetched lists are kept in local view state. Safe alongside gameplay:
//  the library is unreachable while a game runs (fullScreenCover).
//

import SwiftUI

struct RetroAchievementsView: View {
    @ObservedObject private var ra = RetroAchievements.shared
    @ObservedObject private var raIndex = RAGameIndex.shared
    /// A phone on its side, or an iPad window (see `LandscapeSurface`).
    @LandscapeSurface private var isLandscape

    /// Rows or badge wall for the expanded games, user-switchable from the
    /// toolbar (persisted; independent from the dashboard's own choice).
    @AppStorage("raLayout.profile") private var wallLayout = true
    @State private var expandedHash: String?
    /// Achievement lists fetched this visit, keyed by romHash.
    @State private var loadedAchievements: [String: [RAAchievementInfo]] = [:]
    @State private var loadingHash: String?
    /// Games whose fetch failed (offline / timeout); their expanded content
    /// shows the offline row with a retry instead of loading forever.
    @State private var failedHashes: Set<String> = []
    @State private var shareTarget: RAShareTarget?
    @State private var showAbout = false
    /// Drives the profile OVERVIEW share card (all games + totals).
    @State private var showOverviewShare = false
    /// Drives a game's full dashboard sheet from its expanded row.
    @State private var gameDashboard: GameDashboardTarget?
    /// A badge tapped in the compact wall whose details to show (locked ones;
    /// unlocked badges go straight to their share card).
    @State private var badgeDetail: BadgeDetail?

    struct GameDashboardTarget: Identifiable {
        let id = UUID()
        let romURL: URL
    }

    struct BadgeDetail: Identifiable {
        let id = UUID()
        let ach: RAAchievementInfo
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
        raIndex.libraryEntries.values
            .filter { entry in
                if !entry.raSupportedConsole { return true }
                if let record = raIndex.records[entry.romHash] {
                    if !record.isEligible { return true }
                    // Eligible: only an actual load can tell us the set is empty.
                    return record.hasKnownEmptySet
                }
                return false   // still resolving: not known to be unsupported
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

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
            // Only the (i) remains up here (share + layout moved into the
            // list); on iOS 26 it shows RAW, without the Liquid Glass capsule.
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
        .sheet(item: $badgeDetail) { detail in
            RABadgeDetailSheet(ach: detail.ach)
        }
        .onAppear { ra.refreshProgressIfNeeded() }
    }

    /// The landscape layout, fed with this page's facts and one closure per
    /// action; the open game's body is built here so both layouts show the
    /// same loading, offline and loaded shapes.
    private var landscapeBody: some View {
        RetroAchievementsLandscapeView(
            username: ra.displayName ?? ra.username ?? "",
            points: ra.softcoreScore,
            totalUnlocked: totalUnlocked,
            totalAchievements: totalAchievements,
            games: gamesWithAchievements,
            unsupported: unsupportedEntries,
            expandedHash: expandedHash,
            wallLayout: $wallLayout,
            displayTitle: { displayTitle($0) },
            onToggle: { record in
                if expandedHash == record.romHash { expandedHash = nil } else { expand(record) }
            },
            onShareOverview: { showOverviewShare = true },
            onAbout: { showAbout = true },
            expandedContent: { record in expandedBody(record) })
    }

    private var portraitList: some View {
        List {
            // Share + layout choice as the profile section's FOOTER: outside
            // the section card, straight on the view background. As a list ROW
            // iOS 26 clipped its content to the card's big concentric corner,
            // which lopsided the share pill's left edge.
            Section {
                profileHeader
            } footer: {
                RAActionsRow(shareDisabled: gamesWithAchievements.isEmpty,
                             onShare: { showOverviewShare = true },
                             wallLayout: $wallLayout)
                    .padding(.top, 8)
            }
            .landscapeGlassRow()

            Section {
                ForEach(gamesWithAchievements, id: \.romHash) { record in
                    gameGroup(record)
                }
            } header: {
                Text(String(localized: "ra.profile.games", defaultValue: "Games with achievements"))
            } footer: {
                Text(String(localized: "ra.dashboard.shareHint",
                            defaultValue: "Tap an unlocked achievement to share it."))
            }
            .landscapeGlassRow()

            if !unsupportedEntries.isEmpty {
                Section {
                    ForEach(unsupportedEntries, id: \.romHash) { entry in
                        Text(entry.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "ra.profile.unsupported",
                                defaultValue: "Not on RetroAchievements"))
                } footer: {
                    Text(String(localized: "ra.profile.unsupported.footer",
                                defaultValue: "These games have no achievements on RetroAchievements. Sometimes only the English version of a game is covered."))
                }
                .landscapeGlassRow()
            }
        }
    }

    private var aboutButton: some View {
        Button { showAbout = true } label: {
            Image(systemName: "info.circle")
        }
        .accessibilityLabel(Text(String(localized: "ra.about.title",
                                        defaultValue: "About RetroAchievements")))
    }

    // MARK: - Profile header

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image("RABrand")
                    .resizable().scaledToFit()
                    .frame(height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ra.displayName ?? ra.username ?? "")
                        .font(.headline)
                    Text("\(ra.softcoreScore.formatted()) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            if totalAchievements > 0 {
                Text(String(format: String(localized: "ra.dashboard.summary",
                                           defaultValue: "%lld of %lld unlocked"),
                            totalUnlocked, totalAchievements))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(totalUnlocked), total: Double(totalAchievements))
                    .tint(.yellow)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Game rows

    @ViewBuilder
    private func gameGroup(_ record: RAGameRecord) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedHash == record.romHash },
            set: { expanding in
                if expanding {
                    expand(record)
                } else if expandedHash == record.romHash {
                    expandedHash = nil
                }
            }
        )) {
            expandedBody(record)
        } label: {
            gameRowLabel(record)
        }
    }

    /// What an open game shows, in both layouts: the loading placeholder in
    /// the chosen layout's shape, the offline row with its retry, or the
    /// achievements.
    @ViewBuilder
    private func expandedBody(_ record: RAGameRecord) -> some View {
        if loadingHash == record.romHash {
            if wallLayout {
                RABadgeWallSkeleton()
            } else {
                ForEach(0..<3, id: \.self) { _ in
                    RAAchievementSkeletonRow()
                }
            }
        } else if failedHashes.contains(record.romHash) {
            RAOfflineRow(isOffline: !ra.isOnline, onRetry: { expand(record) })
        } else if let achievements = loadedAchievements[record.romHash] {
            if achievements.isEmpty {
                Text(String(localized: "ra.dashboard.empty",
                            defaultValue: "This game has no achievements, or none are loaded yet."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                achievementRows(achievements, record: record)
            }
        }
    }

    /// The expanded content, in the user's chosen layout: the compact badge
    /// wall (retroachievements.org-style, RABadgeWall) or the full rows. In
    /// both, tapping an unlocked achievement opens its share card and a locked
    /// one keeps its full text reachable (rows show it inline; the wall opens
    /// a small detail sheet). Unlocked first (rarest last within unlocked,
    /// like the dashboard). An "Open the game page" row leads to the full
    /// dashboard sheet (which owns the per-game share).
    @ViewBuilder
    private func achievementRows(_ achievements: [RAAchievementInfo], record: RAGameRecord) -> some View {
        let unlocked = achievements.filter { $0.unlocked }.sorted { $0.rarity > $1.rarity }
        let locked = achievements.filter { !$0.unlocked }
        if let filename = raIndex.filename(forROMHash: record.romHash) {
            Button {
                gameDashboard = GameDashboardTarget(romURL: romsDir.appendingPathComponent(filename))
            } label: {
                HStack {
                    Label(String(localized: "ra.profile.openGame", defaultValue: "Open the game page"),
                          systemImage: "trophy")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if wallLayout {
            RABadgeWall(achievements: unlocked + locked) { ach in
                if ach.unlocked {
                    shareTarget = RAShareTarget(
                        achievement: ach,
                        gameName: record.title ?? "",
                        boxArtURL: record.boxArtURL.flatMap(URL.init(string:)),
                        romFilename: raIndex.filename(forROMHash: record.romHash))
                } else {
                    badgeDetail = BadgeDetail(ach: ach)
                }
            }
        } else {
            ForEach(Array((unlocked + locked).enumerated()), id: \.offset) { _, ach in
                if ach.unlocked {
                    Button {
                        shareTarget = RAShareTarget(
                            achievement: ach,
                            gameName: record.title ?? "",
                            boxArtURL: record.boxArtURL.flatMap(URL.init(string:)),
                            romFilename: raIndex.filename(forROMHash: record.romHash))
                    } label: {
                        RAAchievementRow(ach: ach)
                    }
                    .buttonStyle(.plain)
                } else {
                    RAAchievementRow(ach: ach)
                }
            }
        }
    }

    private func gameRowLabel(_ record: RAGameRecord) -> some View {
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
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle(record))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if record.total > 0 {
                    ProgressView(value: Double(record.unlocked), total: Double(record.total))
                        .tint(.yellow)
                        .scaleEffect(x: 1, y: 0.8, anchor: .center)
                    Text(String(format: String(localized: "ra.dashboard.summary",
                                               defaultValue: "%lld of %lld unlocked"),
                                record.unlocked, record.total))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "ra.profile.expandHint",
                                defaultValue: "Open to see its achievements"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// A record can predate its first RA title (progress refresh has counts but
    /// no metadata): fall back to the imported file's name.
    private func fallbackTitle(_ record: RAGameRecord) -> String {
        guard let filename = raIndex.filename(forROMHash: record.romHash) else { return "" }
        // The key is a path relative to the ROMs folder; a disc game's carries
        // its folder, which is not part of a title.
        return ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func expand(_ record: RAGameRecord) {
        expandedHash = record.romHash
        guard loadedAchievements[record.romHash] == nil,
              let filename = raIndex.filename(forROMHash: record.romHash) else { return }
        failedHashes.remove(record.romHash)
        loadingHash = record.romHash
        ra.loadAchievementsForDisplay(romURL: romsDir.appendingPathComponent(filename)) { success in
            if success {
                loadedAchievements[record.romHash] = ra.achievements()
            } else {
                failedHashes.insert(record.romHash)
            }
            // Expanding another game cancels this load (its completion fires
            // false); only clear the loading state if it is still ours.
            if loadingHash == record.romHash { loadingHash = nil }
        }
    }
}
