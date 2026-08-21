//
//  RAAchievementsView.swift
//  EmulateurGBA
//
//  The RetroAchievements dashboard for one game: the user's progress on the
//  set, plus every achievement with its badge, points, lock state and any
//  measured progress. Sourced entirely from rc_client (no Web API key).
//  Presented from Game Details; the sheet opens INSTANTLY and owns its own
//  display load — skeleton rows while fetching, an explicit offline / retry
//  state on failure (nothing loads forever). The header deliberately shows
//  the exact RA set name (the library keeps the user's edited title).
//

import SwiftUI

/// The earned achievement chosen for sharing (Identifiable so it drives a sheet).
struct RAShareTarget: Identifiable {
    let id = UUID()
    let achievement: RAAchievementInfo
    let gameName: String
    let boxArtURL: URL?
    /// The library ROM filename, resolving the card's console + per-game skin
    /// (nil = Classic card only).
    let romFilename: String?
}

struct RAAchievementsView: View {
    /// The ROM whose set to display-load. nil = show whatever rc_client
    /// already holds (no fetch).
    var romURL: URL?

    @ObservedObject private var ra = RetroAchievements.shared
    @Environment(\.dismiss) private var dismiss
    @State private var achievements: [RAAchievementInfo] = []
    /// The game's sets, EMPTY for the ordinary single-set game. Non-empty is
    /// the only thing that makes the per-set block appear, so a game without
    /// subsets renders byte-for-byte the dashboard it always rendered.
    @State private var subsets: [RASubsetInfo] = []
    @State private var shareTarget: RAShareTarget?
    @State private var showAbout = false
    /// Drives the per-game progress share card (everything unlocked here).
    @State private var showGameShare = false
    /// Rows or badge wall, user-switchable from the toolbar (persisted;
    /// independent from the library profile's own choice).
    @AppStorage("raLayout.dashboard") private var wallLayout = false
    /// A locked badge tapped in the wall whose full text to show.
    @State private var badgeDetail: BadgeDetail?

    struct BadgeDetail: Identifiable {
        let id = UUID()
        let ach: RAAchievementInfo
    }

    private enum LoadState { case loading, loaded, failed }
    @State private var loadState: LoadState = .loading

    // Earned list sorted from the most-achieved (highest % of players) down to
    // the rarest, per the dashboard design.
    private var unlockedList: [RAAchievementInfo] {
        achievements.filter { $0.unlocked }.sorted { $0.rarity > $1.rarity }
    }
    private var lockedList: [RAAchievementInfo] { achievements.filter { !$0.unlocked } }

    /// The dashboard renders one block per set instead of one flat list when
    /// the game HAS several sets. `subsets` is empty for an ordinary game, so
    /// this is false almost everywhere and nothing changes there.
    private var isSplitBySet: Bool { subsets.count > 1 }

    /// The achievements belonging to one set. Matched on rc_client's own
    /// `subset_id`, which it stamps on every bucket while building the list, so
    /// this cannot disagree with the set headers above it.
    private func achievements(inSet subsetID: UInt32) -> [RAAchievementInfo] {
        achievements.filter { $0.subsetID == subsetID }
    }

    private var earnedPoints: Int { unlockedList.reduce(0) { $0 + $1.points } }
    private var totalPoints: Int { achievements.reduce(0) { $0 + $1.points } }
    private var unlockedCount: Int { unlockedList.count }

    var body: some View {
        NavigationStack {
            List {
                switch loadState {
                case .loading:
                    skeletonContent
                case .failed:
                    Section {
                        RAOfflineRow(isOffline: !ra.isOnline, onRetry: load)
                    }
                case .loaded:
                    loadedContent
                }
            }
            .navigationTitle(String(localized: "ra.dashboard.title", defaultValue: "Achievements"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Only the (i) remains up here (share + layout moved under the
                // header); on iOS 26 it shows RAW, without the glass capsule.
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) { aboutButton }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { aboutButton }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showAbout) { RAAboutSheet() }
            .sheet(isPresented: $showGameShare) {
                RAGameShareView(gameName: ra.currentGame?.title ?? "",
                                boxArtURL: ra.currentGameBoxArtURL(),
                                achievements: achievements,
                                romFilename: romURL?.lastPathComponent,
                                onClose: { showGameShare = false })
            }
            .onAppear { load() }
            .sheet(item: $shareTarget) { target in
                RAShareView(achievement: target.achievement,
                            gameName: target.gameName,
                            boxArtURL: target.boxArtURL,
                            romFilename: target.romFilename,
                            onClose: { shareTarget = nil })
            }
            .sheet(item: $badgeDetail) { detail in
                RABadgeDetailSheet(ach: detail.ach)
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

    /// Kick (or retry) the display load for `romURL`. Without a romURL, show
    /// what rc_client already holds.
    private func load() {
        guard let romURL else {
            achievements = ra.achievements()
            subsets = ra.subsets()
            loadState = .loaded
            return
        }
        loadState = .loading
        ra.loadAchievementsForDisplay(romURL: romURL) { success in
            let list = ra.achievements()
            achievements = list
            subsets = ra.subsets()
            loadState = (success || !list.isEmpty) ? .loaded : .failed
        }
    }

    // MARK: - States

    /// The dashboard's shape while fetching: the hero-art square + centered
    /// header bars, then a handful of skeleton achievement rows (Instagram-feed
    /// style, no spinner).
    @ViewBuilder
    private var skeletonContent: some View {
        Group {
            SkeletonBox(cornerRadius: 20)
                .frame(width: 108, height: 108)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            VStack(spacing: 8) {
                SkeletonBox(cornerRadius: 4).frame(width: 180, height: 16)
                SkeletonBox(cornerRadius: 4).frame(width: 130, height: 12)
                SkeletonBox(cornerRadius: 3).frame(maxWidth: .infinity).frame(height: 4)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        Section {
            ForEach(0..<5, id: \.self) { _ in
                RAAchievementSkeletonRow()
            }
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if ra.pendingSync {
            Label(String(localized: "ra.dashboard.pendingSync",
                         defaultValue: "Some unlocks are waiting to sync. They'll upload when you're back online."),
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        // The hero box art and the centered set header sit straight on the
        // sheet background (no grouped cell); the share / layout row rides the
        // section's FOOTER — as a list ROW iOS 26 clipped its content to the
        // card's big concentric corner, which lopsided the share pill's left
        // edge (same fix as the profile page).
        Section {
            Group {
                heroArt
                headerInfo
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } footer: {
            RAActionsRow(shareDisabled: unlockedList.isEmpty,
                         onShare: { showGameShare = true },
                         wallLayout: $wallLayout)
                .padding(.top, 4)
        }

        if wallLayout {
            // Compact badge wall: unlocked first (rarest last), then locked.
            // Tap unlocked = share card, tap locked = full-text detail sheet.
            // One grid per set when the game has several, so a bonus set is
            // visibly a bonus set rather than 30 more badges in the same wall.
            if isSplitBySet {
                ForEach(subsets, id: \.subsetID) { subset in
                    let inSet = achievements(inSet: subset.subsetID)
                    Section {
                        if inSet.isEmpty {
                            emptySetRow
                        } else {
                            RABadgeWall(achievements: inSet.filter(\.unlocked).sorted { $0.rarity > $1.rarity }
                                        + inSet.filter { !$0.unlocked }) { ach in
                                if ach.unlocked {
                                    shareTarget = RAShareTarget(achievement: ach,
                                                                gameName: ra.currentGame?.title ?? "",
                                                                boxArtURL: ra.currentGameBoxArtURL(),
                                                                romFilename: romURL?.lastPathComponent)
                                } else {
                                    badgeDetail = BadgeDetail(ach: ach)
                                }
                            }
                        }
                    } header: {
                        setHeader(subset)
                    }
                }
            } else {
            Section {
                RABadgeWall(achievements: unlockedList + lockedList) { ach in
                    if ach.unlocked {
                        shareTarget = RAShareTarget(achievement: ach,
                                                    gameName: ra.currentGame?.title ?? "",
                                                    boxArtURL: ra.currentGameBoxArtURL(),
                                                    romFilename: romURL?.lastPathComponent)
                    } else {
                        badgeDetail = BadgeDetail(ach: ach)
                    }
                }
            } footer: {
                if achievements.isEmpty {
                    Text(String(localized: "ra.dashboard.empty",
                                defaultValue: "This game has no achievements, or none are loaded yet."))
                } else if !unlockedList.isEmpty {
                    Text(String(localized: "ra.dashboard.shareHint",
                                defaultValue: "Tap an unlocked achievement to share it."))
                }
            }
            }
        } else if isSplitBySet {
            // One list per set, earned first inside each, same order the flat
            // list uses so the reading habit carries over.
            ForEach(subsets, id: \.subsetID) { subset in
                let inSet = achievements(inSet: subset.subsetID)
                Section {
                    if inSet.isEmpty {
                        emptySetRow
                    }
                    ForEach(Array((inSet.filter(\.unlocked).sorted { $0.rarity > $1.rarity }
                                   + inSet.filter { !$0.unlocked }).enumerated()), id: \.offset) { _, ach in
                        if ach.unlocked {
                            Button {
                                shareTarget = RAShareTarget(achievement: ach,
                                                            gameName: ra.currentGame?.title ?? "",
                                                            boxArtURL: ra.currentGameBoxArtURL(),
                                                            romFilename: romURL?.lastPathComponent)
                            } label: {
                                RAAchievementRow(ach: ach)
                            }
                            .buttonStyle(.plain)
                        } else {
                            RAAchievementRow(ach: ach)
                        }
                    }
                } header: {
                    setHeader(subset)
                }
            }
        } else {
            // Earned achievements first, so the player sees what they've done
            // without scrolling past the locked ones.
            if !unlockedList.isEmpty {
                Section {
                    ForEach(Array(unlockedList.enumerated()), id: \.offset) { _, ach in
                        Button {
                            shareTarget = RAShareTarget(achievement: ach,
                                                        gameName: ra.currentGame?.title ?? "",
                                                        boxArtURL: ra.currentGameBoxArtURL(),
                                                        romFilename: romURL?.lastPathComponent)
                        } label: {
                            RAAchievementRow(ach: ach)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(String(localized: "ra.dashboard.unlocked", defaultValue: "Unlocked"))
                } footer: {
                    Text(String(localized: "ra.dashboard.shareHint",
                                defaultValue: "Tap an unlocked achievement to share it."))
                }
            }

            Section {
                ForEach(Array(lockedList.enumerated()), id: \.offset) { _, ach in
                    RAAchievementRow(ach: ach)
                }
            } header: {
                if !lockedList.isEmpty {
                    Text(String(localized: "ra.dashboard.locked", defaultValue: "Remaining"))
                }
            } footer: {
                if achievements.isEmpty {
                    Text(String(localized: "ra.dashboard.empty",
                                defaultValue: "This game has no achievements, or none are loaded yet."))
                }
            }
        }
    }

    /// A set's header: its name, and the count that belongs to IT alone.
    ///
    /// That number is deliberately not the one at the top of the sheet. The
    /// headline total merges every set, because that is what the player earns
    /// from and what `af0c185` had to make all our surfaces agree on. These
    /// per-set numbers are what retroachievements.org shows, because the site
    /// does not let a bonus set dilute main completion. Both are correct, and
    /// showing each at its own altitude is what lets them coexist without
    /// changing anything we persist.
    /// Shown when a set IS attached but contributed nothing to the list.
    ///
    /// It used to be dropped silently, which is the worst of the options: the
    /// set simply was not there and nothing said why. A set with no rows is
    /// information, and hiding it is exactly the silent failure the project
    /// forbids elsewhere.
    private var emptySetRow: some View {
        Text(NSLocalizedString("ra.dashboard.set.empty", comment: ""))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func setHeader(_ subset: RASubsetInfo) -> some View {
        HStack(alignment: .center, spacing: 8) {
            // Each set has its own badge on retroachievements.org, and it is
            // the fastest way to tell a challenge run from a bonus set without
            // reading either title.
            if let badge = subset.badgeURL.flatMap(URL.init(string:)) {
                AsyncImage(url: badge) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(subset.title)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text("\(subset.unlocked)/\(subset.total)")
                .monospacedDigit()
                .foregroundStyle(subset.unlocked == subset.total && subset.total > 0
                                 ? Color.orange : Color.secondary)
        }
    }

    /// The game's box art as the sheet's hero: big, standalone, centered.
    private var heroArt: some View {
        AsyncImage(url: ra.currentGameBoxArtURL()) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.gray.opacity(0.15)
                Image(systemName: "trophy")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 108, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    /// RA set name + progress, centered under the hero art. Deliberately shows
    /// the EXACT RA set name (the library keeps the user's edited title).
    private var headerInfo: some View {
        VStack(spacing: 6) {
            if let game = ra.currentGame {
                Text(game.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Text(String(format: String(localized: "ra.dashboard.summary",
                                           defaultValue: "%lld of %lld unlocked"),
                            unlockedCount, achievements.count))
                Text("\(earnedPoints) / \(totalPoints) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if achievements.count > 0 {
                ProgressView(value: Double(unlockedCount), total: Double(achievements.count))
                    .tint(.yellow)
                    // Keep the bar's ends out of the row's corner-mask zone
                    // (this is the section's last row; see the footer note).
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }

}
