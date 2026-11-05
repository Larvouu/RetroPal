//
//  BadgeGalleryView.swift
//  EmulateurGBA
//
//  DEBUG-only gallery of every badge, with how each is unlocked: the Pro crown
//  of the share cards, and since 2026-10-28 the Retro story timeline's badges
//  (`StoryBadge`), in the crown's metal. Reachable from Settings ▸ Debug ▸
//  Badges. Each is rendered by ScreenshotCardRenderer.metalBadgeImage, the
//  drawing path the cards and the timeline use, so what shows here is theirs.
//

#if DEBUG
import SwiftUI
import CoreData

struct BadgeGalleryView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let image: UIImage
        let unlock: String
    }

    private var proItems: [Item] {
        [
            Item(image: ScreenshotCardRenderer.proCrownBadgeImage(side: 56),
                 unlock: "Retro Pal Pro enabled"),
        ]
    }

    /// The timeline's badges, at the gallery's size and at the size the
    /// timeline draws them.
    private var storyItems: [(large: UIImage, small: UIImage, unlock: String)] {
        StoryBadge.allCases.map { badge in
            (badge.image(side: 56), badge.image(side: 26), badge.unlock)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(proItems) { item in
                    row(Image(uiImage: item.image), nil, item.unlock)
                }
            } header: {
                Text("Pro")
            } footer: {
                Text("The Pro crown badge appears on the share cards and the Settings Pro row when Retro Pal Pro is enabled.")
            }
            Section {
                ForEach(Array(storyItems.enumerated()), id: \.offset) { _, item in
                    row(Image(uiImage: item.large), Image(uiImage: item.small), item.unlock)
                }
            } header: {
                Text("Retro story timeline")
            } footer: {
                Text("Each badge at the gallery's size, then at the size the timeline draws it. Earned on the day its step is crossed, every device together.")
            }
        }
        .navigationTitle("Badges")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ large: Image, _ small: Image?, _ unlock: String) -> some View {
        HStack(spacing: 14) {
            large
            if let small { small }
            Spacer()
            Text(unlock)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        // Card-like dark backdrop so the translucent glow reads the same way
        // it does on the share card.
        .listRowBackground(Color(red: 0.08, green: 0.05, blue: 0.14))
    }
}
#endif

#if DEBUG
/// Settings ▸ Debug: fires a Retro story badge's unlock, banner and sound, as
/// if it had just been earned (2026-10-29, his ask), to review the render.
/// Pick the badge, its step, and a game for the badges that are a game's.
struct StoryBadgeUnlockPreview: View {
    @FetchRequest(entity: GameEntity.entity(),
                  sortDescriptors: [NSSortDescriptor(keyPath: \GameEntity.title, ascending: true)])
    private var games: FetchedResults<GameEntity>

    @State private var badge: StoryBadge = .gameHours
    @State private var step = 0
    @State private var gameHash = ""

    /// The steps a badge family has.
    private var steps: [Int] {
        switch badge {
        case .hours: return PlayStats.hourMilestones
        case .gameHours: return PlayStats.gameHourMilestones
        case .gamesPlayed: return PlayStats.gamesPlayedMilestones
        case .consoles: return PlayStats.consoleMilestones
        case .longSession: return PlayStats.sessionMilestones
        case .anniversary: return [1, 2, 3]
        case .firstGame, .secondDevice: return []
        }
    }

    private var isGameBadge: Bool { badge == .gameHours || badge == .firstGame }

    private var game: GameEntity? {
        games.first { $0.romHash == gameHash } ?? games.first
    }

    private var kind: PlayStats.Milestone.Kind {
        let value = steps.indices.contains(step) ? steps[step] : (steps.first ?? 1)
        let title = game?.title ?? "Pokémon"
        let system = game?.systemType ?? "gba"
        let hash = game?.romHash ?? "-"
        switch badge {
        case .firstGame: return .firstGame(title: title, system: system, romHash: hash)
        case .hours: return .hours(value)
        case .gameHours: return .gameHours(value, title: title, system: system, romHash: hash)
        case .gamesPlayed: return .gamesPlayed(value)
        case .consoles: return .consoles(value)
        case .longSession: return .longSession(value)
        case .secondDevice: return .secondDevice
        case .anniversary: return .anniversary(value)
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Badge", selection: $badge) {
                    ForEach(StoryBadge.allCases, id: \.self) { b in
                        Text(b.unlock).tag(b)
                    }
                }
                .onChange(of: badge) { _ in step = 0 }
                if !steps.isEmpty {
                    Picker("Step", selection: $step) {
                        ForEach(steps.indices, id: \.self) { i in Text("\(steps[i])").tag(i) }
                    }
                }
                if isGameBadge {
                    Picker("Game", selection: $gameHash) {
                        ForEach(games, id: \.self) { g in
                            Text(g.title ?? "").tag(g.romHash ?? "")
                        }
                    }
                }
            } footer: {
                Text("The banner shows at the top of this screen and the sound plays, as when the badge is earned for real (the in-game sound toggle does not apply to this preview).")
            }
            Section {
                HStack(spacing: 14) {
                    StoryBadgeIcon(kind: kind, side: 46)
                    Text(StoryBadge.title(kind))
                        .font(.subheadline.weight(.semibold))
                }
                .listRowBackground(Color(red: 0.08, green: 0.05, blue: 0.14))
                .environment(\.colorScheme, .dark)
                Button("Unlock it now") {
                    StoryBadgeAnnouncer.shared.announce(PlayStats.Milestone(kind: kind, date: Date()))
                }
            }
        }
        .navigationTitle("Badge unlock")
        .navigationBarTitleDisplayMode(.inline)
        // Its own banner host: a pushed page covers Settings' overlays.
        .overlay(alignment: .top) { StoryBadgeHUD() }
        .onAppear { if gameHash.isEmpty { gameHash = games.first?.romHash ?? "" } }
    }
}
#endif
