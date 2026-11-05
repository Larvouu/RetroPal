//
//  PlayStats.swift
//  EmulateurGBA
//
//  What the Retro story page shows, computed from every device's history
//  (`PlayHistoryFile`, one per device, summed) and the library as it is now
//  (2026-10-28). A pure value: no storage, no UI, so it is tested with plain
//  values.
//
//  Ranked by what a player remembers (the design review of 10-28): the total
//  and how long they have been playing first, then their games, then their
//  consoles (only the ones played, never a grid of thirteen with zeros), then
//  the milestones of their timeline, then the days.
//

import Foundation

struct PlayStats: Equatable {

    /// A game as the library knows it now; the history keys games by hash.
    struct LibraryGame: Equatable {
        let romHash: String
        let romFilePath: String?
        let title: String
        let system: String
        let importedAt: Date?
    }

    struct GameStat: Equatable, Identifiable {
        let romHash: String
        /// The library's title while the game is there, the last one played
        /// once it is gone.
        let title: String
        let system: String
        let seconds: Double
        let firstPlayed: Date?
        let lastPlayed: Date?
        /// Still in the library (a tap opens its page).
        let inLibrary: Bool
        var id: String { romHash }
    }

    struct ConsoleStat: Equatable, Identifiable {
        let system: String
        let seconds: Double
        /// Games of this console with play time.
        let gamesPlayed: Int
        /// The console's games, most played first.
        let games: [GameStat]
        let firstPlayed: Date?
        var id: String { system }
    }

    /// A line of the timeline: what happened and when.
    /// A badge of the timeline, and the day it was earned (2026-10-28; the
    /// "first game on a console" entries were dropped on his feedback).
    struct Milestone: Equatable, Identifiable {
        enum Kind: Equatable {
            /// Where the story starts: the first game played (or imported,
            /// for the days before play was recorded).
            case firstGame(title: String, system: String, romHash: String)
            /// Hours played in all: 10, 50, 100, 250, 500, 1000.
            case hours(Int)
            /// One game played this many hours: 10, 25, 50, 100.
            case gameHours(Int, title: String, system: String, romHash: String)
            /// Games played: 5, 10, 25, 50, 100.
            case gamesPlayed(Int)
            /// Consoles tried: 3, 5, 8, and all thirteen.
            case consoles(Int)
            /// One sitting this long, in hours: 2, then 4.
            case longSession(Int)
            /// Playing on a second device, the history following.
            case secondDevice
            /// Years since the story began: 1, 2, 3...
            case anniversary(Int)
        }
        let kind: Kind
        let date: Date
        /// Earned before this history existed: crossed by the totals imported
        /// from before the update (`PlayHistory.importBaselineIfNeeded`), or a
        /// first game dated before the recording began. Shown as earned, never
        /// announced as news (`StoryBadgeAnnouncer`), whenever the import ran:
        /// with a library empty on the update day, the seen set was seeded
        /// empty and the past's badges fired once games came back (audit,
        /// 2026-10-29).
        var fromThePast = false
        var id: String {
            switch kind {
            case .firstGame: return "first"
            case .hours(let h): return "hours-\(h)"
            // By the game's hash: a rename never makes an old badge new.
            case .gameHours(let h, _, _, let hash): return "game-\(h)-\(hash)"
            case .gamesPlayed(let n): return "games-\(n)"
            case .consoles(let n): return "consoles-\(n)"
            case .longSession(let h): return "session-\(h)"
            case .secondDevice: return "device-2"
            case .anniversary(let y): return "year-\(y)"
            }
        }
    }

    // MARK: Headline

    /// Every second played, every device, before the update included.
    let totalSeconds: Double
    /// The earliest known start: first play on any device, or the first
    /// game imported, whichever is earlier.
    let playingSince: Date?
    let gamesPlayed: Int
    let libraryCount: Int
    /// Sittings, every device (the small line).
    let sessions: Int
    let longestSessionSeconds: Double

    // MARK: Games and consoles

    /// Most played first. Includes games no longer in the library.
    let games: [GameStat]
    /// Played consoles only, most played first.
    let consoles: [ConsoleStat]
    /// How many consoles exist (the "6 of 13").
    static let consoleCount = 13

    // MARK: Timeline and days

    let milestones: [Milestone]
    /// Seconds per day key ("yyyy-MM-dd"), every device summed.
    let days: [String: Double]
    /// The earliest day any device recorded days from: the calendar, the
    /// months and the year start here.
    let recordingSince: Date?
    /// Seconds per hour of the day, every device summed.
    let hours: [Double]

    /// Worth a page: something has been played.
    var hasData: Bool { totalSeconds >= 60 }

    static let hourMilestones = [10, 50, 100, 250, 500, 1000]
    static let gameHourMilestones = [10, 25, 50, 100]
    static let gamesPlayedMilestones = [5, 10, 25, 50, 100]
    static let consoleMilestones = [3, 5, 8, consoleCount]
    static let sessionMilestones = [2, 4]

    // MARK: - Compute

    static func compute(files: [PlayHistoryFile], library: [LibraryGame],
                        calendar: Calendar = .current) -> PlayStats {
        let libraryByHash = Dictionary(library.map { ($0.romHash, $0) }, uniquingKeysWith: { a, _ in a })

        // Games: summed over devices.
        struct Acc { var title = ""; var system = ""; var seconds = 0.0; var first: Date?; var last: Date?; var lastSeen: Date? }
        var acc: [String: Acc] = [:]
        var days: [String: Double] = [:]
        var hours = Array(repeating: 0.0, count: 24)
        var sessions = 0
        var longest = 0.0
        var recordingSince: Date?
        var firstPlayed: Date?
        for file in files {
            for (hash, game) in file.games {
                var a = acc[hash] ?? Acc()
                // The title of the device that played it last.
                if let last = game.lastPlayed, last >= (a.lastSeen ?? .distantPast) || a.title.isEmpty {
                    a.title = game.title; a.lastSeen = last
                } else if a.title.isEmpty {
                    a.title = game.title
                }
                if a.system.isEmpty { a.system = game.system }
                a.seconds += game.totalSeconds
                a.first = minDate(a.first, game.firstPlayed)
                a.last = maxDate(a.last, game.lastPlayed)
                acc[hash] = a
            }
            for (day, perGame) in file.days {
                days[day, default: 0] += perGame.values.reduce(0, +)
            }
            for (i, s) in file.hours.enumerated() where i < 24 { hours[i] += s }
            sessions += file.sessions + file.baselineSessions
            longest = max(longest, file.longestSessionSeconds)
            recordingSince = minDate(recordingSince, file.recordingSince)
            firstPlayed = minDate(firstPlayed, file.firstPlayed)
        }

        let total = acc.values.reduce(0) { $0 + $1.seconds }
        let games: [GameStat] = acc
            .filter { $0.key != PlayHistory.unknownGameKey && $0.value.seconds > 0 }
            .map { hash, a in
                let lib = libraryByHash[hash]
                return GameStat(romHash: hash,
                                title: lib?.title.isEmpty == false ? lib!.title : a.title,
                                system: lib?.system ?? a.system,
                                seconds: a.seconds,
                                firstPlayed: a.first,
                                lastPlayed: a.last,
                                inLibrary: lib != nil)
            }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds
                      : $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let consoles: [ConsoleStat] = Dictionary(grouping: games, by: \.system)
            .map { system, list in
                ConsoleStat(system: system,
                            seconds: list.reduce(0) { $0 + $1.seconds },
                            gamesPlayed: list.count,
                            games: list,
                            firstPlayed: list.compactMap(\.firstPlayed).min())
            }
            .sorted { $0.seconds > $1.seconds }

        let firstImport = library.compactMap(\.importedAt).min()
        let since = minDate(firstPlayed, firstImport)

        return PlayStats(totalSeconds: total,
                         playingSince: since,
                         gamesPlayed: games.count,
                         libraryCount: library.count,
                         sessions: sessions,
                         longestSessionSeconds: longest,
                         games: games,
                         consoles: consoles,
                         milestones: milestones(files: files, games: games, library: library,
                                                totalSeconds: total, recordingSince: recordingSince,
                                                playingSince: since, calendar: calendar),
                         days: days,
                         recordingSince: recordingSince,
                         hours: hours)
    }

    /// The timeline, newest first: where the story started, then every badge
    /// on the day it was earned.
    ///
    /// The days are replayed in order, every device together, and each badge
    /// family is dated the day its next threshold is crossed. What had been
    /// played before the days began (the baseline, a game's hours from before
    /// the update) counts as already there on the first recorded day: a
    /// threshold it had crossed is dated that day, and of those only the
    /// highest of each family is kept, so the timeline does not open with a
    /// pile of badges on one date.
    static func milestones(files: [PlayHistoryFile], games: [GameStat], library: [LibraryGame],
                           totalSeconds: Double, recordingSince: Date?, playingSince: Date?,
                           calendar: Calendar) -> [Milestone] {
        var result: [Milestone] = []
        let libraryByHash = Dictionary(library.map { ($0.romHash, $0) }, uniquingKeysWith: { a, _ in a })
        let gameByHash = Dictionary(games.map { ($0.romHash, $0) }, uniquingKeysWith: { a, _ in a })

        // Where it started: the first game played, else imported.
        let starts = games.compactMap { game -> (GameStat, Date)? in
            minDate(game.firstPlayed, libraryByHash[game.romHash]?.importedAt).map { (game, $0) }
        }.sorted { $0.1 < $1.1 }
        if let (game, date) = starts.first {
            result.append(Milestone(kind: .firstGame(title: game.title, system: game.system, romHash: game.romHash),
                                    date: date, fromThePast: recordingSince.map { date < $0 } ?? false))
        }

        // Before the days: each game's seconds not in any day, and the total.
        var perGameDays: [String: [String: Double]] = [:]   // day -> game -> seconds
        var recordedPerGame: [String: Double] = [:]
        for file in files {
            for (day, list) in file.days {
                for (hash, seconds) in list {
                    perGameDays[day, default: [:]][hash, default: 0] += seconds
                    recordedPerGame[hash, default: 0] += seconds
                }
            }
        }
        var gameSeconds: [String: Double] = [:]
        for game in games {
            gameSeconds[game.romHash] = max(0, game.seconds - (recordedPerGame[game.romHash] ?? 0))
        }
        let recordedTotal = recordedPerGame.values.reduce(0, +)
        var total = max(0, totalSeconds - recordedTotal)

        func played() -> [String] { gameSeconds.filter { $0.value >= 60 }.map(\.key) }
        func consoleCount() -> Int { Set(played().compactMap { gameByHash[$0]?.system }).count }

        var pendingHours = hourMilestones
        var pendingGames = gamesPlayedMilestones
        var pendingConsoles = consoleMilestones
        var pendingGameHours: [String: [Int]] = Dictionary(uniqueKeysWithValues: games.map { ($0.romHash, gameHourMilestones) })

        /// Crosses what the current counts have reached, dated `date`;
        /// `highestOnly` keeps one badge per family (the past, on day one),
        /// and marks them `fromThePast`.
        func cross(on date: Date, highestOnly: Bool) {
            func take(_ pending: inout [Int], reached: Double, make: (Int) -> Milestone.Kind) {
                let crossed = pending.filter { Double($0) <= reached }
                guard !crossed.isEmpty else { return }
                pending.removeAll { crossed.contains($0) }
                for value in (highestOnly ? [crossed.last!] : crossed) {
                    result.append(Milestone(kind: make(value), date: date, fromThePast: highestOnly))
                }
            }
            take(&pendingHours, reached: total / 3600) { .hours($0) }
            take(&pendingGames, reached: Double(played().count)) { .gamesPlayed($0) }
            take(&pendingConsoles, reached: Double(consoleCount())) { .consoles($0) }
            for (hash, seconds) in gameSeconds {
                guard var pending = pendingGameHours[hash], let game = gameByHash[hash] else { continue }
                take(&pending, reached: seconds / 3600) {
                    .gameHours($0, title: game.title, system: game.system, romHash: hash)
                }
                pendingGameHours[hash] = pending
            }
        }

        if let since = recordingSince {
            cross(on: since, highestOnly: true)
        }
        for day in perGameDays.keys.sorted() {
            for (hash, seconds) in perGameDays[day] ?? [:] {
                gameSeconds[hash, default: 0] += seconds
                total += seconds
            }
            if let date = dayDate(day, calendar: calendar) {
                cross(on: date, highestOnly: false)
            }
        }

        // Long sittings, as each device recorded them (the earliest wins).
        for hours in sessionMilestones {
            let dates = files.compactMap { $0.sessionBadges?[String(hours)] }
            if let first = dates.min() {
                result.append(Milestone(kind: .longSession(hours), date: first))
            }
        }

        // A second device: the day the second device's history began. By
        // device, not by file: a reinstall writes a file of its own on the same
        // device (`PlayHistory`), which is not a second device.
        let starts2 = Dictionary(grouping: files.filter { !$0.games.isEmpty }, by: \.deviceID)
            .values.compactMap { $0.map(\.recordingSince).min() }.sorted()
        if starts2.count >= 2 {
            result.append(Milestone(kind: .secondDevice, date: starts2[1]))
        }

        // Anniversaries of the story's start.
        if let since = playingSince {
            var year = 1
            while let date = calendar.date(byAdding: .year, value: year, to: since), date <= Date() {
                result.append(Milestone(kind: .anniversary(year), date: date))
                year += 1
            }
        }
        return result.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
    }

    // MARK: - The consoles' donut (2026-10-28)

    /// One slice of the consoles' donut: a console, or "the others" folded.
    struct DonutSlice: Equatable {
        /// The console, nil for the folded rest.
        let system: String?
        let seconds: Double
        /// Its share of the total, 0...1.
        let share: Double
        /// Where its arc starts and ends, in turns (0...1), the minimum arc
        /// and the gaps already taken in.
        let start: Double
        let end: Double
    }

    /// The donut's slices, the way TelemetryDeck's top-N breakdown keeps a
    /// small item readable: the `maxSlices - 1` most played consoles, the rest
    /// folded into one "others" slice when there are more than `maxSlices`;
    /// every slice at least `minTurn` of the circle (a 1 % console stays a
    /// visible arc; the larger slices give up the difference in proportion);
    /// a `gapTurn` between slices.
    static func donut(_ consoles: [ConsoleStat], maxSlices: Int = 5,
                      minTurn: Double = 4.0 / 360, gapTurn: Double = 1.5 / 360) -> [DonutSlice] {
        let total = consoles.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return [] }
        var parts: [(String?, Double)] = consoles.map { ($0.system, $0.seconds) }
        if parts.count > maxSlices {
            let kept = parts.prefix(maxSlices - 1)
            let rest = parts.dropFirst(maxSlices - 1).reduce(0) { $0 + $1.1 }
            parts = Array(kept) + [(nil, rest)]
        }
        let n = parts.count
        // One console: the whole ring, no gap.
        if n == 1 { return [DonutSlice(system: parts[0].0, seconds: total, share: 1, start: 0, end: 1)] }
        let available = 1 - gapTurn * Double(n)
        let shares = parts.map { $0.1 / total }
        // Raise the small ones to the minimum, take it from the others in
        // proportion to how much they exceed it.
        var turns = shares.map { $0 * available }
        let minimum = min(minTurn, available / Double(n))
        let deficit = turns.reduce(0) { $0 + max(0, minimum - $1) }
        let surplus = turns.reduce(0) { $0 + max(0, $1 - minimum) }
        if deficit > 0, surplus > 0 {
            turns = turns.map { t in
                t < minimum ? minimum : t - (t - minimum) / surplus * deficit
            }
        }
        var result: [DonutSlice] = []
        var cursor = 0.0
        for (i, part) in parts.enumerated() {
            let start = cursor + gapTurn / 2
            let end = start + turns[i]
            result.append(DonutSlice(system: part.0, seconds: part.1, share: shares[i], start: start, end: end))
            cursor = end + gapTurn / 2
        }
        return result
    }

    // MARK: - Activity (phase 2)

    /// The calendar's weeks: `weeks` columns of seven days ending with the
    /// week of `today`, each day its key and seconds (nil before the history
    /// began, so the grid shows "not recorded" rather than "not played").
    struct ActivityDay: Equatable {
        let key: String
        let date: Date
        let seconds: Double?
    }

    func activity(weeks: Int = 12, today: Date = Date(), calendar: Calendar = .current) -> [[ActivityDay]] {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart) else { return [] }
        let recordingDay = recordingSince.map { calendar.startOfDay(for: $0) }
        let todayStart = calendar.startOfDay(for: today)
        return (0..<weeks).map { w in
            (0..<7).compactMap { d in
                guard let date = calendar.date(byAdding: .day, value: w * 7 + d, to: first) else { return nil }
                let key = PlayHistory.dayKey(date, calendar: calendar)
                let recorded = recordingDay.map { date >= $0 } ?? false
                let future = date > todayStart
                return ActivityDay(key: key, date: date,
                                   seconds: recorded && !future ? (days[key] ?? 0) : nil)
            }
        }
    }

    /// Days with play in the month of `date`.
    func daysPlayed(inMonthOf date: Date = Date(), calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        let prefix = String(format: "%04d-%02d-", c.year ?? 0, c.month ?? 0)
        return days.filter { $0.key.hasPrefix(prefix) && $0.value >= 60 }.count
    }

    /// The month with the most play since the days began: its first day and
    /// its seconds; nil before a month has any.
    func bestMonth(calendar: Calendar = .current) -> (month: Date, seconds: Double)? {
        var perMonth: [String: Double] = [:]
        for (key, seconds) in days { perMonth[String(key.prefix(7)), default: 0] += seconds }
        guard let best = perMonth.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              best.value >= 60,
              let date = PlayStats.dayDate(best.key + "-01", calendar: calendar) else { return nil }
        return (date, best.value)
    }

    /// When the player plays most, from the hours of the day: the band of
    /// the day with the most play, once there are at least two hours of it.
    enum TimeOfDay: Equatable { case morning, afternoon, evening, night }

    var favouriteTimeOfDay: TimeOfDay? {
        let total = hours.reduce(0, +)
        guard total >= 2 * 3600 else { return nil }
        func sum(_ range: [Int]) -> Double { range.reduce(0) { $0 + (hours.indices.contains($1) ? hours[$1] : 0) } }
        let bands: [(TimeOfDay, Double)] = [
            (.morning, sum(Array(5..<12))),
            (.afternoon, sum(Array(12..<18))),
            (.evening, sum(Array(18..<23))),
            (.night, sum([23, 0, 1, 2, 3, 4])),
        ]
        return bands.max { $0.1 < $1.1 }?.0
    }

    // MARK: - The year in review (phase 4)

    /// One calendar year, from the days alone (the only record dated by day,
    /// so a year begins no earlier than the history did; `recordedFrom` says
    /// from when).
    struct Year {
        let year: Int
        let totalSeconds: Double
        let daysPlayed: Int
        /// Seconds per month, January first, twelve values.
        let months: [Double]
        let games: [GameStat]
        let consoles: [ConsoleStat]
        /// Games played for the first time this year.
        let newGames: Int
        /// The day with the most play.
        let bestDay: (date: Date, seconds: Double)?
        let favouriteTimeOfDay: TimeOfDay?
        /// The first day of the year with a record (the history's start when
        /// it began during the year).
        let recordedFrom: Date
        /// When the year's story starts: in the launch year the earliest of the
        /// first play and the first game imported (the whole story is that
        /// year's), else the first recorded day of the year. What the intro
        /// says (his report of 10-29: "recorded since 28 October" was wrong
        /// once the launch year counted everything).
        let startedOn: Date?
        /// Of the total, the seconds with no date: the launch year's play from
        /// before the days were recorded (`launchYear`), in the total, the
        /// games and the consoles, never in a month or a day. 0 any other year.
        let undatedSeconds: Double
    }

    /// The year Retro Pal launched (1.0 live 2026-06-25). Every second played
    /// before the history began (1.3.5) was played that year, so its review
    /// counts that undated play too; every later year reads its dated days
    /// alone, so nothing from before can be counted twice or in the wrong
    /// year (his rule, 2026-10-29). A constant, never read from the device: a
    /// player updating late (in 2027) still has their undated hours in 2026.
    static let launchYear = 2026

    /// The year `year` from every device's days. nil when nothing was played
    /// that year.
    static func year(_ year: Int, files: [PlayHistoryFile], library: [LibraryGame],
                     calendar: Calendar = .current) -> Year? {
        let prefix = String(format: "%04d-", year)
        let libraryByHash = Dictionary(library.map { ($0.romHash, $0) }, uniquingKeysWith: { a, _ in a })
        var perGame: [String: Double] = [:]
        var perDay: [String: Double] = [:]
        var months = Array(repeating: 0.0, count: 12)
        var titles: [String: (title: String, system: String)] = [:]
        var firstPlayedEver: [String: Date] = [:]
        var recordedFrom: Date?
        var undated = 0.0
        let isLaunchYear = year == launchYear
        var firstPlayedAny: Date?
        for file in files {
            for (hash, game) in file.games {
                if titles[hash] == nil { titles[hash] = (game.title, game.system) }
                if let first = game.firstPlayed {
                    firstPlayedEver[hash] = min(firstPlayedEver[hash] ?? first, first)
                }
                // The launch year: the play from before the days, undated.
                // The unnamed rest (`unknownGameKey`) counts in the total
                // only, never as a game or a console.
                if isLaunchYear, game.baselineSeconds > 0 {
                    undated += game.baselineSeconds
                    if hash != PlayHistory.unknownGameKey {
                        perGame[hash, default: 0] += game.baselineSeconds
                    }
                }
            }
            for (day, games) in file.days where day.hasPrefix(prefix) {
                let month = Int(day.dropFirst(5).prefix(2)) ?? 1
                for (hash, seconds) in games {
                    perGame[hash, default: 0] += seconds
                    perDay[day, default: 0] += seconds
                    if (1...12).contains(month) { months[month - 1] += seconds }
                }
            }
            if calendar.component(.year, from: file.recordingSince) <= year {
                recordedFrom = min(recordedFrom ?? file.recordingSince, file.recordingSince)
            }
            if let first = file.firstPlayed {
                firstPlayedAny = min(firstPlayedAny ?? first, first)
            }
        }
        let unnamed = isLaunchYear
            ? files.reduce(0) { $0 + ($1.games[PlayHistory.unknownGameKey]?.baselineSeconds ?? 0) } : 0
        let total = perGame.values.reduce(0, +) + unnamed
        guard total >= 60 else { return nil }

        let games: [GameStat] = perGame.compactMap { hash, seconds in
            guard seconds > 0 else { return nil }
            let lib = libraryByHash[hash]
            let stored = titles[hash]
            return GameStat(romHash: hash,
                            title: lib?.title.isEmpty == false ? lib!.title : (stored?.title ?? ""),
                            system: lib?.system ?? stored?.system ?? "gba",
                            seconds: seconds, firstPlayed: firstPlayedEver[hash], lastPlayed: nil,
                            inLibrary: lib != nil)
        }
        .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds
                  : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let consoles: [ConsoleStat] = Dictionary(grouping: games, by: \.system).map { system, list in
            ConsoleStat(system: system, seconds: list.reduce(0) { $0 + $1.seconds },
                        gamesPlayed: list.count, games: list, firstPlayed: nil)
        }
        .sorted { $0.seconds > $1.seconds }

        // In the launch year every game played was new (the app did not exist
        // before); after it, a game first played that year.
        let newGames = isLaunchYear ? games.count : games.filter { game in
            firstPlayedEver[game.romHash].map { calendar.component(.year, from: $0) == year } ?? false
        }.count
        // A tie goes to the later day, the fresher memory, the same every time.
        let best = perDay.max { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
        let bestDay = best.flatMap { entry in dayDate(entry.key, calendar: calendar).map { ($0, entry.value) } }

        // The hours of the day are kept for all time, not by year: the
        // favourite time is read from them, the same for every year.
        var hours = Array(repeating: 0.0, count: 24)
        for file in files { for (i, s) in file.hours.enumerated() where i < 24 { hours[i] += s } }
        let time = PlayStats(totalSeconds: total, playingSince: nil, gamesPlayed: 0, libraryCount: 0,
                             sessions: 0, longestSessionSeconds: 0, games: [], consoles: [],
                             milestones: [], days: [:], recordingSince: nil, hours: hours).favouriteTimeOfDay

        let jan1 = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
        // The launch year starts where the story does: the first play, the
        // first import, or the first recorded day, whichever is earliest, and
        // never before the year itself.
        let startedOn: Date?
        if isLaunchYear {
            let firstImport = library.compactMap(\.importedAt).min()
            let candidates = [firstPlayedAny, firstImport, recordedFrom].compactMap { $0 }
            startedOn = candidates.min().map { max(jan1, $0) }
        } else {
            startedOn = perDay.isEmpty ? nil : max(jan1, recordedFrom ?? jan1)
        }
        return Year(year: year, totalSeconds: total,
                    daysPlayed: perDay.values.filter { $0 >= 60 }.count,
                    months: months, games: games, consoles: consoles, newGames: newGames,
                    bestDay: bestDay, favouriteTimeOfDay: time,
                    recordedFrom: max(jan1, recordedFrom ?? jan1),
                    startedOn: startedOn,
                    undatedSeconds: undated)
    }

    /// The player's profile for a year, the review's identity slide (2026-10-28,
    /// after Spotify's listening personality): the first that fits, in this
    /// order, so the most telling one wins.
    enum PlayerType: String, CaseIterable {
        /// One game took more than half the year's play (two games at
        /// exactly half each is not loyalty to one).
        case loyal
        /// Four consoles or more, or six games started that year.
        case explorer
        /// Plays most at night.
        case nightOwl
        /// Played on at least 40 % of the days recorded (two weeks at least).
        case regular
        /// Everyone else.
        case enthusiast
    }

    static func playerType(for year: Year, today: Date = Date(), calendar: Calendar = .current) -> PlayerType {
        if let top = year.games.first, year.totalSeconds > 0, top.seconds / year.totalSeconds > 0.5 {
            return .loyal
        }
        if year.consoles.count >= 4 || year.newGames >= 6 { return .explorer }
        if year.favouriteTimeOfDay == .night { return .nightOwl }
        let yearEnd = calendar.date(from: DateComponents(year: year.year, month: 12, day: 31)) ?? today
        let end = min(today, yearEnd)
        let from = calendar.startOfDay(for: year.recordedFrom)
        let recorded = (calendar.dateComponents([.day], from: from, to: calendar.startOfDay(for: end)).day ?? 0) + 1
        if recorded >= 14, Double(year.daysPlayed) / Double(recorded) >= 0.4 { return .regular }
        return .enthusiast
    }

    /// The year in review is offered from December 1 through January 6
    /// (2026-10-28, mirroring Spotify Wrapped's window, his ask: it launches
    /// in the first days of December, every year since 2018 between
    /// November 29 and December 6, and leaves the app in early January). It
    /// lands when year reviews are everywhere and covers the holidays, when
    /// there is time to play and to share. No cut-off: it is computed live,
    /// so December's play counts.
    static func reviewYear(on date: Date = Date(), calendar: Calendar = .current) -> Int? {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }
        if month == 12 { return year }
        if month == 1, day <= 6 { return year - 1 }
        return nil
    }

    static func dayDate(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func minDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (x?, y?): return min(x, y)
        default: return a ?? b
        }
    }

    private static func maxDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        default: return a ?? b
        }
    }
}
