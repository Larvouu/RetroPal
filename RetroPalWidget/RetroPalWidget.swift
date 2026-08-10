//
//  RetroPalWidget.swift
//  RetroPalWidget
//
//  Home-screen widget: the games you played most recently, as their box art.
//  A tap resumes one straight from its auto-save, which is exactly what the
//  "Continue" button in Game Details does.
//
//  The extension owns no data. It reads the snapshot the app publishes into
//  the App Group (see WidgetSharing, compiled into both targets) and never
//  opens Core Data or iCloud — widget timelines run in a very small memory
//  budget.
//

import WidgetKit
import SwiftUI
import UIKit

// MARK: - Timeline

struct RecentGamesEntry: TimelineEntry {
    let date: Date
    let games: [WidgetSharing.Game]
}

struct RecentGamesProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentGamesEntry {
        RecentGamesEntry(date: Date(), games: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentGamesEntry) -> Void) {
        completion(RecentGamesEntry(date: Date(), games: WidgetSharing.recentGames()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentGamesEntry>) -> Void) {
        let entry = RecentGamesEntry(date: Date(), games: WidgetSharing.recentGames())
        // The app reloads us explicitly whenever the library changes, so there
        // is nothing to schedule. `.never` keeps us out of the system's
        // refresh budget instead of re-rendering unchanged content on a timer.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - Pieces

/// The game's cover from the shared container. Screenshots keep their hard
/// pixels (nearest-neighbour) and box art is smoothed, the same distinction
/// the library makes.
struct CoverImage: View {
    let game: WidgetSharing.Game

    var body: some View {
        if let url = WidgetSharing.coverURL(for: game),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .interpolation(game.coverIsScreenshot ? .none : .medium)
        } else {
            ZStack {
                Color.white.opacity(0.06)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Nothing played yet, or the app has never run since the widget was added.
private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("widget.empty")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .widgetURL(WidgetSharing.openAppURL)
    }
}

/// Small: one game, its art edge to edge, title over a scrim so it stays
/// readable on bright covers.
private struct SmallGameView: View {
    let game: WidgetSharing.Game

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
            Text(game.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
        }
        .widgetURL(WidgetSharing.playURL(for: game))
        .retroWidgetBackground {
            ZStack {
                Color.black
                CoverImage(game: game)
                    .scaledToFill()
                LinearGradient(colors: [.clear, .black.opacity(0.8)],
                               startPoint: .center, endPoint: .bottom)
            }
        }
    }
}

/// Medium: up to four games as square tiles, each its own tap target.
private struct MediumGamesView: View {
    let games: [WidgetSharing.Game]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(games.prefix(4)) { game in
                Link(destination: WidgetSharing.playURL(for: game)) {
                    VStack(spacing: 5) {
                        // Square tile that clips whatever it is given: covers
                        // are portrait, screenshots landscape, and the row
                        // has to read as one shelf either way.
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { CoverImage(game: game).scaledToFill() }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(game.title)
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

// MARK: - Widget

struct RetroPalWidget: Widget {
    let kind = "RetroPalWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentGamesProvider()) { entry in
            RetroPalWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(LocalizedStringKey("widget.recent.name"))
        .description(LocalizedStringKey("widget.recent.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RetroPalWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentGamesEntry

    var body: some View {
        if entry.games.isEmpty {
            EmptyStateView().retroWidgetBackground { Color.black }
        } else if family == .systemMedium {
            MediumGamesView(games: entry.games)
        } else if let first = entry.games.first {
            SmallGameView(game: first)
        }
    }
}

// MARK: - iOS 16 / 17 background

extension View {
    /// iOS 17 requires widget backgrounds to go through `containerBackground`
    /// (and insets the content away from it, which is what we want for the
    /// title); iOS 16 has no such API and takes a plain background.
    @ViewBuilder
    func retroWidgetBackground<Background: View>(
        @ViewBuilder _ background: () -> Background
    ) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { background() }
        } else {
            self.background(background())
        }
    }
}
