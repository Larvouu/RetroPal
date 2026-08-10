//
//  RetroPalConfigurableWidgets.swift
//  RetroPalWidget
//
//  The two widgets the user configures: one game, or four. Both are iOS 17+
//  (see RetroPalWidgetIntents for why) and both reuse the recents widget's
//  CoverImage and background helper so all three look like one family.
//
//  Configuration lives in the widget, not in the app, because it has to be
//  per-instance: two small widgets on the Home Screen must be able to show
//  two different games, which a setting inside the app could never do.
//

import WidgetKit
import SwiftUI

// MARK: - One game

@available(iOS 17.0, *)
struct SelectedGameEntry: TimelineEntry {
    let date: Date
    /// nil while the widget has not been configured yet, or when the chosen
    /// game has since been deleted from the library.
    let game: WidgetSharing.Game?
    let slot: Int?
}

@available(iOS 17.0, *)
struct SelectedGameProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SelectedGameEntry {
        SelectedGameEntry(date: Date(), game: WidgetSharing.recentGames().first, slot: nil)
    }

    func snapshot(for configuration: SelectGameIntent, in context: Context) async -> SelectedGameEntry {
        resolve(configuration)
    }

    func timeline(for configuration: SelectGameIntent, in context: Context) async -> Timeline<SelectedGameEntry> {
        // As with the recents widget: the app reloads us on every library
        // change, so there is nothing worth scheduling.
        Timeline(entries: [resolve(configuration)], policy: .never)
    }

    private func resolve(_ configuration: SelectGameIntent) -> SelectedGameEntry {
        guard let id = configuration.game?.id,
              let game = WidgetSharing.game(withID: id) else {
            return SelectedGameEntry(date: Date(), game: nil, slot: nil)
        }
        return SelectedGameEntry(date: Date(), game: game,
                                 slot: configuration.slot.resolved(for: game))
    }
}

@available(iOS 17.0, *)
struct RetroPalGameWidget: Widget {
    let kind = "RetroPalGameWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: SelectGameIntent.self,
                               provider: SelectedGameProvider()) { entry in
            SelectedGameView(entry: entry)
        }
        .configurationDisplayName(LocalizedStringKey("widget.oneGame.name"))
        .description(LocalizedStringKey("widget.oneGame.description"))
        .supportedFamilies([.systemSmall])
    }
}

@available(iOS 17.0, *)
private struct SelectedGameView: View {
    let entry: SelectedGameEntry

    var body: some View {
        if let game = entry.game {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                Text(game.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
            }
            .widgetURL(WidgetSharing.playURL(romFilePath: game.romFilePath, slot: entry.slot))
            .retroWidgetBackground {
                ZStack {
                    Color.black
                    CoverImage(game: game).scaledToFill()
                    LinearGradient(colors: [.clear, .black.opacity(0.8)],
                                   startPoint: .center, endPoint: .bottom)
                }
            }
        } else {
            UnconfiguredView().retroWidgetBackground { Color.black }
        }
    }
}

// MARK: - Four games

@available(iOS 17.0, *)
struct SelectedGamesEntry: TimelineEntry {
    let date: Date
    /// Only the rows the user actually filled in, each with its resolved slot.
    let games: [(game: WidgetSharing.Game, slot: Int?)]
}

@available(iOS 17.0, *)
struct SelectedGamesProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SelectedGamesEntry {
        SelectedGamesEntry(date: Date(),
                           games: WidgetSharing.recentGames().prefix(4).map { ($0, $0.resumeSlot) })
    }

    func snapshot(for configuration: SelectGamesIntent, in context: Context) async -> SelectedGamesEntry {
        resolve(configuration)
    }

    func timeline(for configuration: SelectGamesIntent, in context: Context) async -> Timeline<SelectedGamesEntry> {
        Timeline(entries: [resolve(configuration)], policy: .never)
    }

    private func resolve(_ configuration: SelectGamesIntent) -> SelectedGamesEntry {
        let resolved = configuration.pairs.compactMap { pair -> (WidgetSharing.Game, Int?)? in
            // A game deleted from the library since it was configured simply
            // drops out, the same fail-soft the rest of the app uses.
            guard let game = WidgetSharing.game(withID: pair.entity.id) else { return nil }
            return (game, pair.slot.resolved(for: game))
        }
        return SelectedGamesEntry(date: Date(), games: resolved)
    }
}

@available(iOS 17.0, *)
struct RetroPalGamesWidget: Widget {
    let kind = "RetroPalGamesWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: SelectGamesIntent.self,
                               provider: SelectedGamesProvider()) { entry in
            SelectedGamesView(entry: entry)
        }
        .configurationDisplayName(LocalizedStringKey("widget.fourGames.name"))
        .description(LocalizedStringKey("widget.fourGames.description"))
        .supportedFamilies([.systemMedium])
    }
}

@available(iOS 17.0, *)
private struct SelectedGamesView: View {
    let entry: SelectedGamesEntry

    var body: some View {
        if entry.games.isEmpty {
            UnconfiguredView().retroWidgetBackground { Color.black }
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(entry.games, id: \.game.id) { item in
                    Link(destination: WidgetSharing.playURL(romFilePath: item.game.romFilePath,
                                                            slot: item.slot)) {
                        VStack(spacing: 5) {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { CoverImage(game: item.game).scaledToFill() }
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(item.game.title)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .retroWidgetBackground { Color.black }
        }
    }
}

// MARK: - Shared empty state

/// Added but not set up yet: says what to do rather than showing a blank box.
@available(iOS 17.0, *)
private struct UnconfiguredView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.tap")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("widget.unconfigured")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .widgetURL(WidgetSharing.openAppURL)
    }
}
