//
//  RAAchievementsLandscapeView.swift
//  EmulateurGBA
//
//  One game's RetroAchievements dashboard on its side, in the landscape
//  library's language (decided on device, 2026-09-04): the dark moving ground, the
//  margins, a top bar of our own, glass cards. Portrait keeps its List and is
//  untouched. It is presented as a sheet, so the ground fills the sheet.
//
//  A LAYOUT, not a second page. `RAAchievementsView` still owns the display
//  load, the layout choice and every sheet (share, game share, badge detail,
//  about); it hands this view the facts and one closure per action.
//
//  Left: the box art in a ringed, glowing square, the exact RA set name, the
//  progress and the points, the share + layout row, and the pending-sync
//  note when there is one. Right: the achievements, in the chosen layout,
//  one card per set when the game has several (the same split portrait
//  makes), the unlocked ones first.
//

import SwiftUI

struct RAAchievementsLandscapeView: View {
    enum LoadState { case loading, loaded, failed }

    let loadState: LoadState
    let isOffline: Bool
    let pendingSync: Bool
    let gameTitle: String?
    let boxArtURL: URL?
    let achievements: [RAAchievementInfo]
    let subsets: [RASubsetInfo]
    @Binding var wallLayout: Bool
    let onRetry: () -> Void
    let onShareGame: () -> Void
    let onShare: (RAAchievementInfo) -> Void
    let onBadgeDetail: (RAAchievementInfo) -> Void
    let onAbout: () -> Void
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An iPad window: a wider header column, a capped wall.
    @TabletSurface private var isTablet
    @Environment(\.surfaceSafeAreaInsets) private var surfaceInsets
    /// Observed so a theme change repaints this surface.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    private var unlockedList: [RAAchievementInfo] {
        achievements.filter { $0.unlocked }.sorted { $0.rarity > $1.rarity }
    }
    private var lockedList: [RAAchievementInfo] { achievements.filter { !$0.unlocked } }
    private var isSplitBySet: Bool { subsets.count > 1 }
    private var earnedPoints: Int { unlockedList.reduce(0) { $0 + $1.points } }
    private var totalPoints: Int { achievements.reduce(0) { $0 + $1.points } }

    private func achievements(inSet subsetID: UInt32) -> [RAAchievementInfo] {
        let inSet = achievements.filter { $0.subsetID == subsetID }
        return inSet.filter(\.unlocked).sorted { $0.rarity > $1.rarity } + inSet.filter { !$0.unlocked }
    }

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
                    // Upright on an iPad the header stands above the wall in one
                    // scroll; on its side the two are columns.
                    Group {
                        if LandscapeChrome.isStacked(tablet: isTablet, size: size) {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 20) {
                                    headerColumn
                                    VStack(spacing: 12) {
                                        content
                                    }
                                }
                                .frame(maxWidth: 760)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 8)
                            }
                        } else if isTablet {
                            // An iPad on its side (decided on device, 2026-09-05): the
                            // header and the wall as one block, centred vertically
                            // when the block fits the window, scrolling when not.
                            ViewThatFits(in: .vertical) {
                                HStack(alignment: .top, spacing: 20) {
                                    headerColumn
                                        .frame(width: 320)
                                    VStack(spacing: 12) {
                                        content
                                    }
                                    .frame(maxWidth: 760)
                                }
                                .frame(maxHeight: .infinity, alignment: .center)
                                HStack(alignment: .top, spacing: 20) {
                                    ScrollView(.vertical, showsIndicators: false) {
                                        headerColumn
                                    }
                                    .frame(width: 320)
                                    ScrollView(.vertical, showsIndicators: false) {
                                        VStack(spacing: 12) {
                                            content
                                        }
                                        .padding(.bottom, 8)
                                    }
                                    .frame(maxWidth: 760)
                                }
                            }
                        } else {
                            HStack(alignment: .top, spacing: 20) {
                                ScrollView(.vertical, showsIndicators: false) {
                                    headerColumn
                                }
                                .frame(width: 260)
                                ScrollView(.vertical, showsIndicators: false) {
                                    VStack(spacing: 12) {
                                        content
                                    }
                                    .padding(.bottom, 8)
                                }
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
            Button(action: onAbout) {
                LandscapeChrome.circle(systemName: "info")
            }
            .accessibilityLabel(Text(String(localized: "ra.about.title",
                                            defaultValue: "About RetroAchievements")))
            Spacer(minLength: 8)
            Button(action: onDone) {
                Text(String(localized: "common.done", defaultValue: "Done"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(LandscapeChrome.glass(Capsule()))
            }
        }
        .frame(height: 40)
    }

    // MARK: - Left: the game and its progress

    private var headerColumn: some View {
        VStack(spacing: 12) {
            // Art and title only once LOADED: until then the client still
            // holds the last game it loaded, and the sheet showed that game's
            // art for the length of the fetch (audit, 2026-09-05). Portrait
            // never did, its hero art lives in the loaded state.
            Group {
                if loadState == .loaded {
                    AsyncImage(url: boxArtURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        artPlaceholder
                    }
                } else {
                    artPlaceholder
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(LibraryLandscapePalette.accentGradient, lineWidth: 3)
            )
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LibraryLandscapePalette.accentGradient)
                    .blur(radius: 22)
                    .opacity(0.55)
            )
            .accessibilityHidden(true)

            if loadState == .loading {
                VStack(spacing: 8) {
                    SkeletonBox(cornerRadius: 4).frame(width: 180, height: 16)
                    SkeletonBox(cornerRadius: 4).frame(width: 130, height: 12)
                    SkeletonBox(cornerRadius: 3).frame(maxWidth: .infinity).frame(height: 4)
                }
                .accessibilityHidden(true)
            } else {
                if loadState == .loaded, let gameTitle {
                    Text(gameTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 4) {
                    Text(String(format: String(localized: "ra.dashboard.summary",
                                               defaultValue: "%lld of %lld unlocked"),
                                unlockedList.count, achievements.count))
                    Text("\(earnedPoints.formatted()) / \(totalPoints.formatted()) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                if achievements.count > 0 {
                    ProgressView(value: Double(unlockedList.count), total: Double(achievements.count))
                        .tint(.yellow)
                }
                RAActionsRow(shareDisabled: unlockedList.isEmpty,
                             onShare: onShareGame,
                             wallLayout: $wallLayout)
                    .padding(.top, 4)
                if pendingSync {
                    Label(String(localized: "ra.dashboard.pendingSync",
                                 defaultValue: "Some unlocks are waiting to sync. They'll upload when you're back online."),
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private var artPlaceholder: some View {
        ZStack {
            Color.white.opacity(LandscapeChrome.cardFill)
            Image(systemName: "trophy")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    // MARK: - Right: the achievements

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            LandscapeChrome.card(nil) {
                if wallLayout {
                    RABadgeWallSkeleton()
                } else {
                    ForEach(0..<5, id: \.self) { _ in
                        RAAchievementSkeletonRow()
                    }
                }
            }
        case .failed:
            LandscapeChrome.card(nil) {
                RAOfflineRow(isOffline: isOffline, onRetry: onRetry)
            }
        case .loaded:
            if achievements.isEmpty {
                LandscapeChrome.card(nil) {
                    Text(String(localized: "ra.dashboard.empty",
                                defaultValue: "This game has no achievements, or none are loaded yet."))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if isSplitBySet {
                // One card per set, as portrait makes one section per set: a
                // bonus set is visibly a bonus set.
                ForEach(subsets, id: \.subsetID) { subset in
                    let inSet = achievements(inSet: subset.subsetID)
                    LandscapeChrome.card(nil) {
                        setHeader(subset)
                        if inSet.isEmpty {
                            Text(NSLocalizedString("ra.dashboard.set.empty", comment: ""))
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.78))
                        } else {
                            achievementBlock(inSet)
                        }
                    }
                }
            } else if wallLayout {
                LandscapeChrome.card(nil) {
                    achievementBlock(unlockedList + lockedList)
                    if !unlockedList.isEmpty {
                        Text(String(localized: "ra.dashboard.shareHint",
                                    defaultValue: "Tap an unlocked achievement to share it."))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            } else {
                if !unlockedList.isEmpty {
                    LandscapeChrome.card(String(localized: "ra.dashboard.unlocked", defaultValue: "Unlocked")) {
                        achievementBlock(unlockedList)
                        Text(String(localized: "ra.dashboard.shareHint",
                                    defaultValue: "Tap an unlocked achievement to share it."))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                if !lockedList.isEmpty {
                    LandscapeChrome.card(String(localized: "ra.dashboard.locked", defaultValue: "Remaining")) {
                        achievementBlock(lockedList)
                    }
                }
            }
        }
    }

    /// A list of achievements in the chosen layout: the badge wall, or the
    /// rows, an unlocked one tappable to share and a locked one to read.
    @ViewBuilder
    private func achievementBlock(_ list: [RAAchievementInfo]) -> some View {
        if wallLayout {
            RABadgeWall(achievements: list) { ach in
                if ach.unlocked { onShare(ach) } else { onBadgeDetail(ach) }
            }
        } else {
            ForEach(Array(list.enumerated()), id: \.offset) { index, ach in
                if index > 0 {
                    Divider().overlay(Color.white.opacity(LandscapeChrome.cardFill))
                }
                if ach.unlocked {
                    Button {
                        onShare(ach)
                    } label: {
                        RAAchievementRow(ach: ach)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    RAAchievementRow(ach: ach)
                }
            }
        }
    }

    /// A set's header: its badge, its name, and the count that belongs to it.
    private func setHeader(_ subset: RASubsetInfo) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if let badge = subset.badgeURL.flatMap(URL.init(string:)) {
                AsyncImage(url: badge) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(LandscapeChrome.cardFill)
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Text(subset.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text("\(subset.unlocked)/\(subset.total)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(subset.unlocked == subset.total && subset.total > 0
                                 ? Color.orange : Color.white.opacity(0.78))
        }
    }
}
