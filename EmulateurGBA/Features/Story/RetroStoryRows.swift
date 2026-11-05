//
//  RetroStoryRows.swift
//  EmulateurGBA
//
//  The pieces of the Retro story page (2026-10-28). Ink from the environment:
//  the page is dark on the ground either way up, so `.primary` is white.
//

import SwiftUI

enum RetroStoryFormat {
    /// "41 h 12 min", "12 min": the page's durations. Hours as a number that
    /// grows (a player with 1,250 hours reads it), minutes only under 100 h.
    /// The three ways a duration is written, decided by its size.
    enum DurationStyle { case minutes, hoursMinutes, hours }

    /// How `seconds` is written by `duration(_:)`: a count-up keeps its final
    /// value's style the whole way, so it never jumps between forms.
    static func durationStyle(_ seconds: Double) -> DurationStyle {
        let totalMinutes = max(Int(seconds / 60), seconds > 0 ? 1 : 0)
        let hours = totalMinutes / 60, minutes = totalMinutes % 60
        if hours == 0 { return .minutes }
        return (hours >= 100 || minutes == 0) ? .hours : .hoursMinutes
    }

    /// `seconds` written in a given style (the count-up's frames).
    /// `seconds` written in a given style, every frame of a count-up the same
    /// width as its final value (his report of 10-29: "49 h 33 min" blinked
    /// on the game of the year). The leading part keeps the final value's
    /// digit count, padded with figure spaces (U+2007, exactly a monospaced
    /// digit wide, invisible), and the minutes after hours always two digits
    /// ("49 h 09 min"), so with monospaced digits the text never changes
    /// width. No thousands separator here: it would appear mid-count.
    static func duration(_ seconds: Double, style: DurationStyle, padTo finalSeconds: Double) -> String {
        let totalMinutes = max(Int(seconds / 60), 0)
        let finalMinutes = max(Int(finalSeconds / 60), 0)
        func padded(_ value: Int, to final: Int) -> String {
            let digits = String(final).count
            let text = String(value)
            return String(repeating: "\u{2007}", count: max(0, digits - text.count)) + text
        }
        switch style {
        case .minutes:
            return String(format: NSLocalizedString("story.duration.minutes", comment: ""),
                          padded(totalMinutes, to: finalMinutes))
        case .hours:
            return String(format: NSLocalizedString("story.duration.hours", comment: ""),
                          padded(totalMinutes / 60, to: finalMinutes / 60))
        case .hoursMinutes:
            return String(format: NSLocalizedString("story.duration.hoursMinutes", comment: ""),
                          padded(totalMinutes / 60, to: finalMinutes / 60),
                          String(format: "%02d", totalMinutes % 60))
        }
    }

    static func duration(_ seconds: Double) -> String {
        let totalMinutes = max(Int(seconds / 60), seconds > 0 ? 1 : 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return String(format: NSLocalizedString("story.duration.minutes", comment: ""), "\(minutes)")
        }
        if hours >= 100 || minutes == 0 {
            return String(format: NSLocalizedString("story.duration.hours", comment: ""), hours.formatted())
        }
        return String(format: NSLocalizedString("story.duration.hoursMinutes", comment: ""),
                      hours.formatted(), "\(minutes)")
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year())
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// The headline (reworked 2026-10-28 on his feedback): the total as one line
/// in plain white ("147 h played"), no label above it; then three equal cells
/// split by hairlines, as the old card set its numbers; the sessions as a
/// small line. When the player started is not a main number: it lives in the
/// timeline, as its first entry.
struct RetroStoryHeadline: View {
    let stats: PlayStats

    var body: some View {
        VStack(spacing: 16) {
            Text(String(format: NSLocalizedString("story.totalPlayed", comment: ""),
                        RetroStoryFormat.duration(stats.totalSeconds)))
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)

            // Four equal cells, two by two (his ask of 10-28: the sessions
            // a number like the others). Two a row leaves each label the half
            // of the panel, which holds the longest of the fifteen languages
            // on an SE; a row of four did not.
            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    cell(value: stats.gamesPlayed.formatted(),
                         label: NSLocalizedString("library.stats.gamesPlayed", comment: ""))
                    hairline
                    cell(value: stats.consoles.count.formatted(),
                         label: NSLocalizedString("story.consolesPlayed", comment: ""))
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 0) {
                    cell(value: stats.longestSessionSeconds >= 60
                            ? RetroStoryFormat.duration(stats.longestSessionSeconds) : "–",
                         label: NSLocalizedString("story.longestSession", comment: ""))
                    hairline
                    cell(value: stats.sessions.formatted(),
                         label: NSLocalizedString("library.stats.sessions", comment: ""))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, 2)
    }

    private func cell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A game: its cover, title, console, hours with a bar against the most
/// played, and when it was last played.
struct RetroStoryGameRow: View {
    let game: PlayStats.GameStat
    let maxSeconds: Double
    let showsChevron: Bool
    var showsConsole: Bool = true
    /// The most played game, drawn larger and set apart from the rest (his
    /// ask of 10-28): a big cover, the title on two lines, the hours large.
    var featured: Bool = false
    @FetchRequest private var match: FetchedResults<GameEntity>

    init(game: PlayStats.GameStat, maxSeconds: Double, showsChevron: Bool, showsConsole: Bool = true,
         featured: Bool = false) {
        self.game = game
        self.maxSeconds = maxSeconds
        self.showsChevron = showsChevron
        self.showsConsole = showsConsole
        self.featured = featured
        _match = FetchRequest(entity: GameEntity.entity(), sortDescriptors: [],
                              predicate: NSPredicate(format: "romHash == %@", game.romHash))
    }

    private var coverSide: CGFloat { featured ? 84 : 44 }

    var body: some View {
        if featured { featuredBody } else { regularBody }
    }

    /// The most played: the cover large, the console's drawing over the title
    /// (two lines), the hours in big type, the bar full width, the last play.
    private var featuredBody: some View {
        HStack(alignment: .top, spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                if showsConsole {
                    ConsoleTagBadge(systemType: game.system)
                }
                Text(game.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(RetroStoryFormat.duration(game.seconds))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                RetroStoryBar(fraction: 1, color: LibraryLandscapePalette.highlight)
                note
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// When it was last played, or that it left the library.
    @ViewBuilder
    private var note: some View {
        if !game.inLibrary {
            Text(NSLocalizedString("story.game.removed", comment: ""))
        } else if let last = game.lastPlayed {
            Text(RetroStoryFormat.relative(last))
        }
    }

    private var cover: some View {
        Group {
            if let entity = match.first {
                LibraryLandscapeTile(game: entity, side: coverSide, isSelected: false, saveTick: 0,
                                     showsConsoleTag: false)
            } else {
                // A game no longer in the library: its console stands in.
                ZStack {
                    RoundedRectangle(cornerRadius: coverSide * 0.11, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                    ConsoleMark(systemType: game.system, width: coverSide * 0.64, height: coverSide * 0.45)
                }
            }
        }
        .frame(width: coverSide, height: coverSide)
        .accessibilityHidden(true)
    }

    private var regularBody: some View {
        HStack(spacing: 12) {
            Group {
                if let entity = match.first {
                    LibraryLandscapeTile(game: entity, side: 44, isSelected: false, saveTick: 0,
                                         showsConsoleTag: false)
                } else {
                    // A game no longer in the library: its console stands in.
                    ZStack {
                        RoundedRectangle(cornerRadius: 44 * 0.11, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                        ConsoleMark(systemType: game.system, width: 28, height: 20)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(game.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if showsConsole {
                        ConsoleTagBadge(systemType: game.system)
                    }
                }
                RetroStoryBar(fraction: maxSeconds > 0 ? game.seconds / maxSeconds : 0,
                              color: LibraryLandscapePalette.highlight)
                // The duration keeps its width; the note at the right wraps
                // rather than cut ("Uit de bibliotheek verwijderd", "il y a
                // 3 semaines"): every language fits.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(RetroStoryFormat.duration(game.seconds))
                        .monospacedDigit()
                        .fixedSize()
                    Spacer(minLength: 8)
                    Group {
                        if !game.inLibrary {
                            Text(NSLocalizedString("story.game.removed", comment: ""))
                        } else if let last = game.lastPlayed {
                            Text(RetroStoryFormat.relative(last))
                        }
                    }
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// A bar of the given fraction on a faint track.
struct RetroStoryBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// The timeline's badges, in the Pro crown's metal (his ask of 10-28: every
/// badge one family with the crown), one symbol per family. Drawn once per
/// symbol and kept, since each is a bitmap render. The Debug gallery shows the
/// whole set from `all`.
enum StoryBadge: CaseIterable {
    case firstGame, hours, gameHours, gamesPlayed, consoles, longSession, secondDevice, anniversary

    init(_ kind: PlayStats.Milestone.Kind) {
        switch kind {
        case .firstGame: self = .firstGame
        case .hours: self = .hours
        case .gameHours: self = .gameHours
        case .gamesPlayed: self = .gamesPlayed
        case .consoles: self = .consoles
        case .longSession: self = .longSession
        case .secondDevice: self = .secondDevice
        case .anniversary: self = .anniversary
        }
    }

    var symbol: String {
        switch self {
        case .firstGame: return "flag.fill"
        case .hours: return "hourglass.circle.fill"
        case .gameHours: return "heart.fill"
        case .gamesPlayed: return "square.stack.fill"
        case .consoles: return "gamecontroller.fill"
        case .longSession: return "timer.circle.fill"
        case .secondDevice: return "ipad.and.iphone"
        case .anniversary: return "gift.fill"
        }
    }

    /// How it is earned, for the Debug gallery (not shown to players).
    var unlock: String {
        switch self {
        case .firstGame: return "Where the story starts: the first game played (or imported)"
        case .hours: return "Hours played in all: 10, 50, 100, 250, 500, 1000"
        case .gameHours: return "Hours on one game: 10, 25, 50, 100"
        case .gamesPlayed: return "Games played: 5, 10, 25, 50, 100"
        case .consoles: return "Consoles tried: 3, 5, 8, all 13"
        case .longSession: return "One sitting of 2 hours, then 4"
        case .secondDevice: return "The history followed the player to a second device (iCloud)"
        case .anniversary: return "Each year since the story began"
        }
    }

    /// The badge at `side` (the crown's own measure: the canvas adds 26 % a side).
    func image(side: CGFloat) -> UIImage {
        let key = "\(symbol)#\(side)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        let image = ScreenshotCardRenderer.metalBadgeImage(systemName: symbol, side: side)
        Self.cache.setObject(image, forKey: key)
        return image
    }

    private static let cache = NSCache<NSString, UIImage>()

    /// The badge's side against its picture's (`StoryBadgeIcon`): small in
    /// the corner of a game's cover, larger alone.
    static let onCoverScale: CGFloat = 0.42
    static let aloneScale: CGFloat = 0.65

    /// Draws every badge at the sizes a picture of `iconSide` uses, ahead
    /// (the unlock banner's, off the main thread): each is four bitmap
    /// passes, which a banner's first frame must not pay.
    static func prewarm(iconSide: CGFloat) {
        for badge in allCases {
            _ = badge.image(side: iconSide * onCoverScale)
            _ = badge.image(side: iconSide * aloneScale)
        }
    }

    /// What a badge says, the timeline's line and the banner's title.
    static func title(_ kind: PlayStats.Milestone.Kind) -> String {
        switch kind {
        case .firstGame(let game, _, _):
            return String(format: NSLocalizedString("story.milestone.firstGame", comment: ""), game)
        case .hours(let hours):
            return String(format: NSLocalizedString("story.milestone.hours", comment: ""), hours.formatted())
        case .gameHours(let hours, let game, _, _):
            return String(format: NSLocalizedString("story.milestone.gameHours", comment: ""), hours.formatted(), game)
        case .gamesPlayed(let count):
            return String(format: NSLocalizedString("story.milestone.gamesPlayed", comment: ""), count.formatted())
        case .consoles(let count):
            return count >= PlayStats.consoleCount
                ? NSLocalizedString("story.milestone.allConsoles", comment: "")
                : String(format: NSLocalizedString("story.milestone.consoles", comment: ""), count.formatted())
        case .longSession(let hours):
            return String(format: NSLocalizedString("story.milestone.longSession", comment: ""), hours.formatted())
        case .secondDevice:
            return NSLocalizedString("story.milestone.secondDevice", comment: "")
        case .anniversary(let years):
            return years == 1
                ? NSLocalizedString("story.milestone.anniversary1", comment: "")
                : String(format: NSLocalizedString("story.milestone.anniversary", comment: ""), years.formatted())
        }
    }
    /// The game a badge belongs to, by its ROM hash: the first game, and the
    /// hours on one game. nil for the badges of the whole story.
    static func romHash(of kind: PlayStats.Milestone.Kind) -> String? {
        switch kind {
        case .firstGame(_, _, let hash), .gameHours(_, _, _, let hash): return hash
        default: return nil
        }
    }
}

/// A badge's picture (2026-10-29, his ask): a game's badge is the game first,
/// its cover with the badge small in its bottom-right corner; any other badge
/// is the metal badge alone. The timeline, the unlock banner and the Debug
/// preview draw it. `cover` is used when given (the banner reads it ahead);
/// else the library's tile for the game, live.
struct StoryBadgeIcon: View {
    let kind: PlayStats.Milestone.Kind
    let side: CGFloat
    var cover: UIImage? = nil
    @FetchRequest private var match: FetchedResults<GameEntity>

    init(kind: PlayStats.Milestone.Kind, side: CGFloat, cover: UIImage? = nil) {
        self.kind = kind
        self.side = side
        self.cover = cover
        // An impossible hash when the badge has no game: the fetch matches nothing.
        _match = FetchRequest(entity: GameEntity.entity(), sortDescriptors: [],
                              predicate: NSPredicate(format: "romHash == %@", StoryBadge.romHash(of: kind) ?? "-"))
    }

    var body: some View {
        if StoryBadge.romHash(of: kind) != nil {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else if let game = match.first {
                        LibraryLandscapeTile(game: game, side: side, isSelected: false, saveTick: 0,
                                             showsConsoleTag: false)
                    } else {
                        RoundedRectangle(cornerRadius: side * 0.14, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.14, style: .continuous))
                // The badge, small, over the corner: its glow spills out a little.
                Image(uiImage: StoryBadge(kind).image(side: side * StoryBadge.onCoverScale))
                    .offset(x: side * 0.2, y: side * 0.2)
            }
            .frame(width: side, height: side)
        } else {
            Image(uiImage: StoryBadge(kind).image(side: side * StoryBadge.aloneScale))
                .frame(width: side, height: side)
        }
    }
}

/// One line of the timeline: its metal badge, what was earned, and when.
struct RetroStoryMilestoneRow: View {
    let milestone: PlayStats.Milestone

    var body: some View {
        HStack(spacing: 12) {
            StoryBadgeIcon(kind: milestone.kind, side: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(StoryBadge.title(milestone.kind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(RetroStoryFormat.date(milestone.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The saves the app keeps: save states and in-game saves on this device,
/// and whether they are copied to iCloud. Counted off the main thread.
struct RetroStorySavesRow: View {
    @ObservedObject private var sync = iCloudSaveSync.shared
    @State private var counts: (states: Int, battery: Int)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(LibraryLandscapePalette.highlight)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let counts {
                    Text("\(NSLocalizedString("story.saves.states", comment: "")) \(counts.states.formatted())")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                    Text("\(NSLocalizedString("story.saves.battery", comment: "")) \(counts.battery.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    SkeletonBox(cornerRadius: 4).frame(width: 140, height: 14)
                }
                Text(sync.syncEnabled
                     ? NSLocalizedString("story.saves.icloudOn", comment: "")
                     : NSLocalizedString("story.saves.icloudOff", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .task { counts = await Self.count() }
    }

    /// Manual save states (`*.state`, the auto-save slot and the cheat backup
    /// left out) and in-game saves (`*.sav`, `*.srm`, the 3DS's zips).
    static func count() async -> (states: Int, battery: Int) {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var states = 0
            if let walker = fm.enumerator(at: iCloudSaveSync.localSaveStatesRoot(), includingPropertiesForKeys: nil) {
                for case let url as URL in walker where url.pathExtension == "state" {
                    let name = url.lastPathComponent
                    if name == "slot0.state" || name == "pre_cheat_backup.state" { continue }
                    if url.path.contains("/_Conflicts/") { continue }
                    states += 1
                }
            }
            let batteryRoot = BatterySaveImporter.batterySavesRoot
            let flat = (try? fm.contentsOfDirectory(atPath: batteryRoot.path)) ?? []
            var battery = flat.filter { $0.hasSuffix(".sav") || $0.hasSuffix(".srm") }.count
            let ctr = (try? fm.contentsOfDirectory(atPath: batteryRoot.appendingPathComponent("3DS").path)) ?? []
            battery += ctr.filter { $0.hasSuffix(".zip") }.count
            return (states, battery)
        }.value
    }
}

/// RetroAchievements in one row: points, a door to its page.
struct RetroStoryRARow: View {
    @ObservedObject private var ra = RetroAchievements.shared

    var body: some View {
        HStack(spacing: 12) {
            Image("RABrand")
                .resizable().scaledToFit()
                .frame(width: 36, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("RetroAchievements")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(ra.isLoggedIn
                     ? "\(ra.softcoreScore.formatted()) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))"
                     : String(localized: "ra.connect", defaultValue: "Connect your account"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Activity (phase 2)

/// Twelve weeks of play as a grid, a column per week, a cell per day, its
/// colour as deep as the day's play. No streak, no count of days missed (the
/// design review of 10-28: people play emulators in bursts, and a broken
/// streak is guilt, which is a reason to leave). A day before the history
/// began is drawn apart, so it never reads as a day not played.
///
/// Laid out centred (his feedback of 10-28): the grid with the weekday
/// letters beside it, then the facts as equal centred cells, as in the
/// headline; the facts appear once there is something to say, and the note
/// on when the record began only while the grid is mostly empty.
struct RetroStoryActivity: View {
    let stats: PlayStats

    private let gap: CGFloat = 4
    private let maxSide: CGFloat = 20

    private var grid: [[PlayStats.ActivityDay]] { stats.activity() }
    private var maxSeconds: Double { grid.joined().compactMap(\.seconds).max() ?? 0 }
    /// Days of the grid before the record began.
    private var unrecordedDays: Int { grid.joined().filter { $0.seconds == nil }.count }

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geo in
                let columns = CGFloat(max(grid.count, 1))
                let labelWidth: CGFloat = 14
                let side = min(maxSide, (geo.size.width - labelWidth - gap * columns) / columns)
                HStack(alignment: .top, spacing: gap) {
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(weekdayLetter(row))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: labelWidth, height: side)
                        }
                    }
                    ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(week, id: \.key) { day in
                                cell(day, side: side)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 7 * maxSide + 6 * gap)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NSLocalizedString("story.activity", comment: ""))

            HStack(spacing: 0) {
                fact(value: stats.daysPlayed().formatted(),
                     label: NSLocalizedString("story.activity.daysThisMonth", comment: ""))
                if let best = stats.bestMonth() {
                    hairline
                    fact(value: best.month.formatted(.dateTime.month(.abbreviated)),
                         label: NSLocalizedString("story.activity.bestMonth", comment: ""))
                }
                if let time = stats.favouriteTimeOfDay {
                    hairline
                    VStack(spacing: 3) {
                        Image(systemName: Self.icon(time))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(LibraryLandscapePalette.highlight)
                            .frame(height: 24)
                        Text(Self.shortLabel(time))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            // While most of the grid predates the record, say why it is empty.
            if unrecordedDays > 7 * 4, let since = stats.recordingSince {
                Text(String(format: NSLocalizedString("story.activity.since", comment: ""),
                            RetroStoryFormat.date(since)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    /// The weekday initial for a row of the grid, starting the week where the
    /// user's calendar does.
    private func weekdayLetter(_ row: Int) -> String {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = (calendar.firstWeekday - 1 + row) % 7
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    @ViewBuilder
    private func cell(_ day: PlayStats.ActivityDay, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
        if let seconds = day.seconds {
            if seconds >= 60 {
                // Four steps, against the busiest day of the grid.
                let level = maxSeconds > 0 ? min(1, seconds / maxSeconds) : 0
                let step = level > 0.66 ? 1.0 : level > 0.33 ? 0.75 : level > 0.1 ? 0.55 : 0.4
                shape.fill(LibraryLandscapePalette.highlight.opacity(step))
                    .frame(width: side, height: side)
            } else {
                shape.fill(Color.primary.opacity(0.1))
                    .frame(width: side, height: side)
            }
        } else {
            shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                .frame(width: side, height: side)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, 2)
    }

    private func fact(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 24)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The cell's own words, a noun the third of the panel holds in every
    /// language ("Night owl"); the year slide says the whole sentence.
    static func shortLabel(_ time: PlayStats.TimeOfDay) -> String {
        switch time {
        case .morning: return NSLocalizedString("story.time.morning.short", comment: "")
        case .afternoon: return NSLocalizedString("story.time.afternoon.short", comment: "")
        case .evening: return NSLocalizedString("story.time.evening.short", comment: "")
        case .night: return NSLocalizedString("story.time.night.short", comment: "")
        }
    }

    static func label(_ time: PlayStats.TimeOfDay) -> String {
        switch time {
        case .morning: return NSLocalizedString("story.time.morning", comment: "")
        case .afternoon: return NSLocalizedString("story.time.afternoon", comment: "")
        case .evening: return NSLocalizedString("story.time.evening", comment: "")
        case .night: return NSLocalizedString("story.time.night", comment: "")
        }
    }

    static func icon(_ time: PlayStats.TimeOfDay) -> String {
        switch time {
        case .morning: return "sunrise.fill"
        case .afternoon: return "sun.max.fill"
        case .evening: return "sunset.fill"
        case .night: return "moon.stars.fill"
        }
    }
}

/// The year in review's door at the top of the page (December 1 to January 6).
struct RetroStoryYearRow: View {
    let year: PlayStats.Year

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LibraryLandscapePalette.accentGradient)
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: NSLocalizedString("story.year.cardTitle", comment: ""), "\(year.year)"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(NSLocalizedString("story.year.row", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// The year in review brought to the front of the library (his call of
/// 10-28): once per review year, above the hero, in the library's glass.
/// Opening it or closing it marks it seen; from then on the review waits on
/// the Retro story page, where it always is from December 1 to January 6.
enum YearSpotlight {
    private static let key = "story.yearSpotlight.seen"

    static func isSeen(_ year: Int) -> Bool {
        UserDefaults.standard.integer(forKey: key) >= year
    }

    static func markSeen(_ year: Int) {
        UserDefaults.standard.set(year, forKey: key)
    }

    #if DEBUG
    /// Settings ▸ Debug: brings the spotlight back, once it was opened or
    /// closed (the mark is otherwise for good, per year).
    static func debugReset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
    #endif
}

struct YearSpotlightCard: View {
    let year: PlayStats.Year
    let onOpen: () -> Void
    let onDismiss: () -> Void
    /// The slim form for a phone on its side, above the rack.
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous)
                    .fill(LibraryLandscapePalette.accentGradient)
                Image(systemName: "sparkles")
                    .font(.system(size: compact ? 15 : 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: compact ? 34 : 52, height: compact ? 34 : 52)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: NSLocalizedString("story.year.spotlight", comment: ""), "\(year.year)"))
                    .font(compact ? .subheadline.weight(.bold) : .headline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    Text(NSLocalizedString("story.year.row", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            FocusableButton(shape: .capsule, isDefault: true, action: onOpen) {
                Text(NSLocalizedString("story.year.open", comment: ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: compact ? 32 : 36)
                    .background(Capsule().fill(LibraryLandscapePalette.accentGradient))
            }
            FocusableButton(shape: .capsule, action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(LandscapeChrome.glass(Circle()))
            }
            .accessibilityLabel(NSLocalizedString("screenshot.dismiss", comment: ""))
        }
        .padding(compact ? 10 : 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(LandscapeChrome.cardFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(LandscapeChrome.cardStroke), lineWidth: 1)
                )
        )
    }
}

// MARK: - The consoles' donut

/// The consoles as a donut beside its legend (his ask of 10-28, after
/// TelemetryDeck's top-N breakdown): one colour per console (`chartColor`,
/// fixed per console, never by rank), the top four and the rest folded into
/// "Others" past five, every slice at least a visible arc, a gap between
/// slices (`PlayStats.donut`). The legend says each console by its drawing,
/// its name, its share and its hours, and is the way into its page, so no
/// slice is read by colour alone.
struct RetroStoryConsoleDonut: View {
    let stats: PlayStats
    /// Opens a console's page.
    let onOpen: (String) -> Void

    private var slices: [PlayStats.DonutSlice] { PlayStats.donut(stats.consoles) }
    private let ringWidth: CGFloat = 18
    /// "Others" opened: the consoles folded into it, listed under the legend,
    /// each its way into its page.
    @State private var showsOthers = false

    /// The consoles folded into "Others".
    private var folded: [PlayStats.ConsoleStat] {
        let shown = Set(slices.compactMap(\.system))
        return stats.consoles.filter { !shown.contains($0.system) }
    }

    /// Side by side where the legend keeps the width the longest name needs
    /// (on its side, an iPad); else the ring centred above a full-width legend
    /// (his report of 10-28: beside the ring on a phone, every name ended in
    /// "..."). `ViewThatFits` picks; the legend's names never truncate.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                ring.frame(width: 128, height: 128)
                legend.frame(minWidth: 230)
            }
            VStack(spacing: 14) {
                ring.frame(width: 140, height: 140)
                legend
            }
        }
        .padding(.vertical, 8)
    }

    private var legend: some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                    legendRow(slice)
                }
                if showsOthers {
                    ForEach(folded) { console in
                        FocusableButton(shape: .rounded(8)) {
                            Haptics.tap()
                            onOpen(console.system)
                        } label: {
                            HStack(spacing: 8) {
                                ConsoleMark(systemType: console.system, width: 22, height: 16)
                                    .frame(width: 22)
                                    .padding(.leading, 17)
                                Text(SystemColor.name(console.system))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text(RetroStoryFormat.duration(console.seconds))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: ringWidth)
            ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                Circle()
                    .trim(from: slice.start, to: slice.end)
                    .stroke(color(slice), style: StrokeStyle(lineWidth: ringWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(stats.consoles.count.formatted())
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(NSLocalizedString("story.consolesPlayed", comment: ""))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: 72)
            }
        }
        .padding(ringWidth / 2)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func legendRow(_ slice: PlayStats.DonutSlice) -> some View {
        let content = HStack(spacing: 8) {
            Circle().fill(color(slice)).frame(width: 9, height: 9)
            if let system = slice.system {
                ConsoleMark(systemType: system, width: 22, height: 16)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(slice.system.map { SystemColor.name($0) }
                     ?? NSLocalizedString("story.consoles.others", comment: ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    // Whole, on two lines if it must, never cut.
                    .fixedSize(horizontal: false, vertical: true)
                Text(RetroStoryFormat.duration(slice.seconds))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            Text(slice.share.formatted(.percent.precision(.fractionLength(0))))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Image(systemName: slice.system != nil ? "chevron.right" : (showsOthers ? "chevron.up" : "chevron.down"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        FocusableButton(shape: .rounded(8)) {
            Haptics.tap()
            if let system = slice.system {
                onOpen(system)
            } else {
                withAnimation(.easeOut(duration: 0.2)) { showsOthers.toggle() }
            }
        } label: { content }
        .buttonStyle(.plain)
    }

    private func color(_ slice: PlayStats.DonutSlice) -> Color {
        slice.system.map { SystemColor.chartColor($0) } ?? SystemColor.chartOther
    }
}
