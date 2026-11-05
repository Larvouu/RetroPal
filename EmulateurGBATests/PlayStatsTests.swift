//
//  PlayStatsTests.swift
//  EmulateurGBATests
//
//  The Retro story's history (2026-10-28): every device's file summed, the
//  library's title over the stored one, a deleted game keeping its hours and
//  its name, the past before the update counted in the total only, a sitting
//  past midnight split across its two days, the timeline rebuilt from what
//  was kept, and the iCloud rule (a device's own file always wins, the others
//  always come down). Run on the host first (Swift on Linux), same cases.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("Play stats")
struct PlayStatsTests {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }

    private func d(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Europe/Paris")!
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return f.date(from: s)!
    }

    @Test("A sitting past midnight counts on both days")
    func midnightSplit() {
        var slices: [(String, Int, Double)] = []
        PlayHistory.spread(from: d("2026-10-27T23:30:00"), to: d("2026-10-28T00:45:00"), calendar: cal) {
            slices.append(($0, $1, $2))
        }
        #expect(slices.count == 2)
        #expect(slices.first?.0 == "2026-10-27")
        #expect(slices.first?.2 == 1800)
        #expect(slices.last?.0 == "2026-10-28")
        #expect(slices.last?.1 == 0)
        #expect(slices.last?.2 == 2700)
    }

    private func twoDevices() -> (PlayHistoryFile, PlayHistoryFile, [PlayStats.LibraryGame]) {
        var a = PlayHistoryFile(deviceID: "A", recordingSince: d("2026-10-28T00:00:00"))
        a.games["h1"] = .init(title: "Old name", system: "gba", seconds: 3600, baselineSeconds: 36000,
                              firstPlayed: d("2026-10-28T10:00:00"), lastPlayed: d("2026-10-28T11:00:00"))
        a.games[PlayHistory.unknownGameKey] = .init(title: "", system: "", seconds: 0, baselineSeconds: 7200)
        a.days = ["2026-10-28": ["h1": 3600]]
        a.sessions = 1
        a.baselineSessions = 40
        a.longestSessionSeconds = 3600
        a.firstPlayed = d("2026-08-01T00:00:00")
        var b = PlayHistoryFile(deviceID: "B", recordingSince: d("2026-10-29T00:00:00"))
        b.games["h1"] = .init(title: "Pokemon B", system: "gba", seconds: 1800,
                              firstPlayed: d("2026-10-29T09:00:00"), lastPlayed: d("2026-10-29T09:30:00"))
        b.games["h2"] = .init(title: "Deleted Game", system: "nds", seconds: 600,
                              firstPlayed: d("2026-10-29T10:00:00"), lastPlayed: d("2026-10-29T10:10:00"))
        b.days = ["2026-10-29": ["h1": 1800, "h2": 600]]
        b.sessions = 2
        b.longestSessionSeconds = 1800
        let library = [
            PlayStats.LibraryGame(romHash: "h1", romFilePath: "p.gba", title: "Pokémon Émeraude",
                                  system: "gba", importedAt: d("2026-07-01T12:00:00")),
            PlayStats.LibraryGame(romHash: "h3", romFilePath: "never.md", title: "Never played",
                                  system: "md", importedAt: d("2026-09-01T12:00:00")),
        ]
        return (a, b, library)
    }

    @Test("Every device is summed; the library's title wins; a deleted game keeps its name")
    func sumAcrossDevices() {
        let (a, b, library) = twoDevices()
        let s = PlayStats.compute(files: [a, b], library: library, calendar: cal)
        #expect(s.totalSeconds == 3600 + 36000 + 7200 + 1800 + 600)
        #expect(s.games.count == 2)
        #expect(s.games.first?.title == "Pokémon Émeraude")
        #expect(s.games.first?.seconds == 41400)
        #expect(s.games.first?.inLibrary == true)
        #expect(s.games.last?.title == "Deleted Game")
        #expect(s.games.last?.inLibrary == false)
        #expect(s.consoles.map(\.system) == ["gba", "nds"])
        #expect(s.sessions == 43)
        #expect(s.longestSessionSeconds == 3600)
        #expect(s.playingSince == d("2026-07-01T12:00:00"))
        #expect(s.days["2026-10-29"] == 2400)
        #expect(s.libraryCount == 2)
        #expect(s.gamesPlayed == 2)
    }

    @Test("The timeline: first game, first on each console, hours crossed")
    func timeline() {
        let (a, b, library) = twoDevices()
        let s = PlayStats.compute(files: [a, b], library: library, calendar: cal)
        let tenHoursAtStart = s.milestones.contains {
            if case .hours(10) = $0.kind { return $0.date == d("2026-10-28T00:00:00") }
            return false
        }
        #expect(tenHoursAtStart)
        let firstGame = s.milestones.contains {
            if case .firstGame(let title, _, _) = $0.kind { return title == "Pokémon Émeraude" }
            return false
        }
        #expect(firstGame)
        // The past counted on the first recorded day: the game had 10 h then.
        let gameTenHours = s.milestones.contains {
            if case .gameHours(10, let title, _, _) = $0.kind {
                return title == "Pokémon Émeraude" && $0.date == d("2026-10-28T00:00:00")
            }
            return false
        }
        #expect(gameTenHours)
        let secondDevice = s.milestones.contains {
            if case .secondDevice = $0.kind { return $0.date == d("2026-10-29T00:00:00") }
            return false
        }
        #expect(secondDevice)
        #expect(zip(s.milestones, s.milestones.dropFirst()).allSatisfy { $0.date >= $1.date })

        var c = PlayHistoryFile(deviceID: "C", recordingSince: d("2026-10-01T00:00:00"))
        c.games["x"] = .init(title: "X", system: "snes", seconds: 3600, baselineSeconds: 34200,
                             firstPlayed: d("2026-10-05T10:00:00"))
        c.days = ["2026-10-05": ["x": 3600]]
        let s2 = PlayStats.compute(files: [c], library: [], calendar: cal)
        let onItsDay = s2.milestones.contains {
            if case .hours(10) = $0.kind { return cal.isDate($0.date, inSameDayAs: d("2026-10-05T12:00:00")) }
            return false
        }
        #expect(onItsDay)
        #expect(!PlayStats.compute(files: [], library: library, calendar: cal).hasData)
    }

    @Test("A history file survives its JSON round trip")
    func roundTrip() throws {
        let (a, _, _) = twoDevices()
        let data = try JSONEncoder.history.encode(a)
        let back = try JSONDecoder.history.decode(PlayHistoryFile.self, from: data)
        #expect(back == a)
    }

    @Test("iCloud: a device's own file always wins, the others always come down")
    func syncRule() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("PlayStatsTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let localA = base.appendingPathComponent("A")
        let localB = base.appendingPathComponent("B")
        let cloud = base.appendingPathComponent("cloud")
        try fm.createDirectory(at: localA, withIntermediateDirectories: true)
        try fm.createDirectory(at: localB, withIntermediateDirectories: true)
        func write(_ dir: URL, _ name: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func read(_ dir: URL, _ name: String) -> String? {
            try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        let present: (URL) -> Bool = { fm.fileExists(atPath: $0.path) }
        try write(localA, "A.json", "a1")
        try write(localB, "B.json", "b1")
        #expect(!PlayHistorySync.reconcile(cloudRoot: cloud, ownFileName: "A.json", localRoot: localA, materialize: present))
        #expect(PlayHistorySync.reconcile(cloudRoot: cloud, ownFileName: "B.json", localRoot: localB, materialize: present))
        #expect(read(localB, "A.json") == "a1")
        #expect(read(cloud, "B.json") == "b1")
        try write(localA, "A.json", "a2")
        PlayHistorySync.reconcile(cloudRoot: cloud, ownFileName: "A.json", localRoot: localA, materialize: present)
        try write(cloud, "A.json", "stale")
        PlayHistorySync.reconcile(cloudRoot: cloud, ownFileName: "A.json", localRoot: localA, materialize: present)
        #expect(read(localA, "A.json") == "a2")
        #expect(read(cloud, "A.json") == "a2")
        try fm.removeItem(at: localA)
        #expect(PlayHistorySync.reconcile(cloudRoot: cloud, ownFileName: "A.json", localRoot: localA, materialize: present))
        #expect(read(localA, "A.json") == "a2")
        #expect(!PlayHistorySync.reconcile(cloudRoot: cloud, ownFileName: "A.json", localRoot: localA, materialize: present))
    }

    @Test("Activity: the grid, days this month, best month, time of day")
    func activity() {
        var f = PlayHistoryFile(deviceID: "Z", recordingSince: d("2026-10-10T08:00:00"))
        f.games["g"] = .init(title: "G", system: "gba", seconds: 9000)
        f.days = ["2026-10-12": ["g": 3600], "2026-10-20": ["g": 1800], "2026-10-28": ["g": 30],
                  "2026-09-30": ["g": 99999]]
        var hours = Array(repeating: 0.0, count: 24)
        hours[23] = 4000
        hours[1] = 3000
        hours[20] = 5000
        f.hours = hours
        let s = PlayStats.compute(files: [f], library: [], calendar: cal)
        let grid = s.activity(weeks: 12, today: d("2026-10-28T12:00:00"), calendar: cal)
        #expect(grid.count == 12)
        #expect(grid.allSatisfy { $0.count == 7 })
        let days = grid.flatMap { $0 }
        #expect(days.first(where: { $0.key == "2026-10-09" })?.seconds == nil)
        #expect(days.first(where: { $0.key == "2026-10-10" })?.seconds == 0)
        #expect(days.first(where: { $0.key == "2026-10-12" })?.seconds == 3600)
        #expect(days.first(where: { $0.key == "2026-10-30" })?.seconds == nil)
        #expect(days.contains { $0.key == "2026-10-28" })
        #expect(s.daysPlayed(inMonthOf: d("2026-10-28T12:00:00"), calendar: cal) == 2)
        #expect(s.bestMonth(calendar: cal).map { cal.component(.month, from: $0.month) } == 9)
        #expect(s.favouriteTimeOfDay == .night)
    }

    // A year after the launch year: its dated days alone.
    @Test("The year in review: the year's days only, months, top game, best day, when it is offered")
    func yearInReview() throws {
        var f = PlayHistoryFile(deviceID: "Y", recordingSince: d("2027-10-29T08:00:00"))
        f.games["a"] = .init(title: "A", system: "gba", seconds: 9000, firstPlayed: d("2027-10-29T09:00:00"))
        f.games["b"] = .init(title: "B", system: "nds", seconds: 3600, firstPlayed: d("2026-05-01T09:00:00"))
        f.days = ["2027-10-30": ["a": 3600, "b": 1800], "2027-11-15": ["a": 5400],
                  "2027-12-01": ["b": 1800], "2025-12-31": ["a": 9999]]
        let library = [PlayStats.LibraryGame(romHash: "a", romFilePath: "a.gba", title: "Alpha",
                                             system: "gba", importedAt: nil)]
        let year = try #require(PlayStats.year(2027, files: [f], library: library, calendar: cal))
        #expect(year.totalSeconds == 3600 + 1800 + 5400 + 1800)
        #expect(year.months[9] == 5400)
        #expect(year.months[10] == 5400)
        #expect(year.months[11] == 1800)
        #expect(year.months[0] == 0)
        #expect(year.games.first?.title == "Alpha")
        #expect(year.games.first?.seconds == 9000)
        #expect(year.consoles.map(\.system) == ["gba", "nds"])
        #expect(year.daysPlayed == 3)
        #expect(year.newGames == 1)
        // Two days tie at 5400 s: the later one, every time.
        #expect(year.bestDay.map { cal.isDate($0.date, inSameDayAs: d("2027-11-15T12:00:00")) } == true)
        #expect(cal.isDate(year.recordedFrom, inSameDayAs: d("2027-10-29T12:00:00")))
        // A year with nothing recorded has no review. Not 2025: the stray
        // 2025-12-31 day above is there to stay out of 2027, and 2025 has it.
        #expect(PlayStats.year(2024, files: [f], library: library, calendar: cal) == nil)
        #expect(PlayStats.reviewYear(on: d("2026-12-05T10:00:00"), calendar: cal) == 2026)
        #expect(PlayStats.reviewYear(on: d("2027-01-06T22:00:00"), calendar: cal) == 2026)
        #expect(PlayStats.reviewYear(on: d("2027-01-07T08:00:00"), calendar: cal) == nil)
        #expect(PlayStats.reviewYear(on: d("2026-11-20T10:00:00"), calendar: cal) == nil)
    }

    /// A reinstall writes a file of its own on the same device (audit,
    /// 2026-10-29: under the old name it wrote over the history before it).
    /// Both files are summed, and they are one device, not two.
    @Test("A reinstall: its file and the earlier install's are summed, and are one device")
    func reinstallIsOneDevice() {
        var before = PlayHistoryFile(deviceID: "P", recordingSince: d("2026-10-01T00:00:00"))
        before.games["h1"] = .init(title: "Game", system: "gba", seconds: 7200)
        before.days = ["2026-10-02": ["h1": 7200]]
        var after = PlayHistoryFile(deviceID: "P", recordingSince: d("2026-10-20T00:00:00"))
        after.games["h1"] = .init(title: "Game", system: "gba", seconds: 1800)
        after.days = ["2026-10-21": ["h1": 1800]]
        let s = PlayStats.compute(files: [before, after], library: [], calendar: cal)
        #expect(s.totalSeconds == 9000)
        #expect(s.games.first?.seconds == 9000)
        #expect(!s.milestones.contains { $0.kind == .secondDevice })
    }

    /// A phone restored from another's backup made before the update imports
    /// that phone's past too: one source, counted once, in either order
    /// (audit, 2026-10-29). Two devices with their own pasts are both counted.
    @Test("The same past imported on two devices (a restored backup) counts once")
    func copiedBaselineCountsOnce() {
        let source = d("2026-10-20T21:00:00")
        func file(_ device: String, past: Double, played: Double, source: Date?) -> PlayHistoryFile {
            var f = PlayHistoryFile(deviceID: device, recordingSince: d("2026-10-28T00:00:00"))
            f.games["h"] = .init(title: "G", system: "gba", seconds: played, baselineSeconds: past)
            f.baselineSessions = 10
            f.baselineSource = source
            return f
        }
        // The restored phone's library may lack a game the first one had: the
        // import then drops an unnamed rest under a minute.
        let a = file("A", past: 36_000, played: 600, source: source)
        let b = file("B", past: 35_970, played: 300, source: source)
        for files in [[a, b], [b, a]] {
            let s = PlayStats.compute(files: PlayHistory.withoutCopiedBaselines(files), library: [], calendar: cal)
            #expect(s.totalSeconds == 36_900)
            #expect(s.sessions == 10)
        }
        // Two real phones that banked within the same second keep both pasts
        // (re-audit, 2026-10-29: the date is stored to the second).
        let sameSecond = file("D", past: 7_200, played: 0, source: source)
        let both2 = PlayStats.compute(files: PlayHistory.withoutCopiedBaselines([a, sameSecond]), library: [], calendar: cal)
        #expect(both2.totalSeconds == 43_800)
        let other = file("C", past: 7_200, played: 0, source: d("2026-09-01T12:00:00"))
        let both = PlayStats.compute(files: PlayHistory.withoutCopiedBaselines([a, other]), library: [], calendar: cal)
        #expect(both.totalSeconds == 43_800)
    }

    @Test("Badges: crossed day by day, sessions as recorded, one device has no device badge, old files decode")
    func badges() throws {
        var f = PlayHistoryFile(deviceID: "B1", recordingSince: d("2026-10-01T00:00:00"))
        for (i, system) in ["gba", "nds", "snes", "gb", "gb"].enumerated() {
            f.games["g\(i)"] = .init(title: "G\(i)", system: system, seconds: 3600)
        }
        f.days = ["2026-10-02": ["g0": 3600, "g1": 3600], "2026-10-05": ["g2": 3600, "g3": 3600, "g4": 3600]]
        f.sessionBadges = ["2": d("2026-10-05T22:00:00")]
        let s = PlayStats.compute(files: [f], library: [], calendar: cal)
        let threeConsoles = s.milestones.contains {
            if case .consoles(3) = $0.kind { return cal.isDate($0.date, inSameDayAs: d("2026-10-05T12:00:00")) }
            return false
        }
        #expect(threeConsoles)
        let fiveGames = s.milestones.contains {
            if case .gamesPlayed(5) = $0.kind { return cal.isDate($0.date, inSameDayAs: d("2026-10-05T12:00:00")) }
            return false
        }
        #expect(fiveGames)
        #expect(s.milestones.contains { $0.kind == .longSession(2) })
        #expect(!s.milestones.contains { $0.kind == .secondDevice })
        let oldFile = #"{"version":1,"deviceID":"X","recordingSince":"2026-10-28T00:00:00Z","games":{},"days":{},"sessions":0,"longestSessionSeconds":0,"baselineSessions":0,"hours":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}"#
        #expect((try? JSONDecoder.history.decode(PlayHistoryFile.self, from: Data(oldFile.utf8))) != nil)
        let minimal = #"{"deviceID":"X","recordingSince":"2026-10-28T00:00:00Z"}"#
        #expect((try? JSONDecoder.history.decode(PlayHistoryFile.self, from: Data(minimal.utf8))) != nil)
    }

    @Test("The year's player profile: the most telling one wins; two games at half each is not loyalty")
    func playerProfile() throws {
        func year(_ games: [String: String], days: [String: [String: Double]],
                  hours: [Double] = Array(repeating: 0, count: 24)) throws -> PlayStats.Year {
            var f = PlayHistoryFile(deviceID: "T", recordingSince: d("2026-11-01T00:00:00"))
            for (hash, system) in games { f.games[hash] = .init(title: hash, system: system) }
            f.days = days
            f.hours = hours
            return try #require(PlayStats.year(2026, files: [f], library: [], calendar: cal))
        }
        let now = d("2026-12-10T12:00:00")
        let loyal = try year(["a": "gba", "b": "nds"], days: ["2026-11-01": ["a": 7200, "b": 1000]])
        #expect(PlayStats.playerType(for: loyal, today: now, calendar: cal) == .loyal)
        let explorer = try year(["g0": "gba", "g1": "nds", "g2": "snes", "g3": "n64"],
                                days: ["2026-11-01": ["g0": 3000], "2026-11-02": ["g1": 3000],
                                       "2026-11-03": ["g2": 3000], "2026-11-04": ["g3": 3000]])
        #expect(PlayStats.playerType(for: explorer, today: now, calendar: cal) == .explorer)
        var night = Array(repeating: 0.0, count: 24)
        night[1] = 9000
        let owl = try year(["a": "gba", "b": "nds"], days: ["2026-11-01": ["a": 3000, "b": 3000]], hours: night)
        #expect(PlayStats.playerType(for: owl, today: now, calendar: cal) == .nightOwl)
        var regularDays: [String: [String: Double]] = [:]
        for day in 1...20 { regularDays[String(format: "2026-11-%02d", day)] = ["a": 600, "b": 600] }
        let regular = try year(["a": "gba", "b": "nds"], days: regularDays)
        #expect(PlayStats.playerType(for: regular, today: now, calendar: cal) == .regular)
        let fan = try year(["a": "gba", "b": "nds"], days: ["2026-11-01": ["a": 3000, "b": 3000]])
        #expect(PlayStats.playerType(for: fan, today: now, calendar: cal) == .enthusiast)
    }

    @Test("The consoles' donut: top four and the rest folded past five, every slice a visible arc, gaps")
    func donut() {
        func console(_ system: String, _ seconds: Double) -> PlayStats.ConsoleStat {
            .init(system: system, seconds: seconds, gamesPlayed: 1, games: [], firstPlayed: nil)
        }
        let consoles = [console("gba", 9000), console("nds", 3000), console("snes", 1000), console("n64", 500),
                        console("ps1", 200), console("gb", 50), console("md", 10)]
        let slices = PlayStats.donut(consoles)
        #expect(slices.count == 5)
        #expect(slices.last?.system == nil)
        #expect(abs((slices.last?.seconds ?? 0) - 260) < 0.01)
        #expect(slices.allSatisfy { $0.end - $0.start >= 4.0 / 360 - 1e-9 })
        #expect((slices.last?.end ?? 2) <= 1 + 1e-9)
        #expect(zip(slices, slices.dropFirst()).allSatisfy { $1.start > $0.end })
        #expect(abs(slices.map(\.share).reduce(0, +) - 1) < 1e-9)
        let single = PlayStats.donut([console("gba", 100)])
        #expect(single.count == 1)
        #expect(single.first?.start == 0)
        #expect(single.first?.end == 1)
        let two = PlayStats.donut([console("gba", 100_000), console("nds", 1)])
        #expect(((two.last?.end ?? 0) - (two.last?.start ?? 0)) * 360 >= 3.999)
        #expect(PlayStats.donut([]).isEmpty)
    }

    @Test("The launch year counts the play from before the days; a later year does not")
    func launchYear() throws {
        var f = PlayHistoryFile(deviceID: "L", recordingSince: d("2026-10-29T08:00:00"))
        f.games["a"] = .init(title: "A", system: "gba", seconds: 3600, baselineSeconds: 36000,
                             firstPlayed: d("2026-10-29T09:00:00"))
        f.games["b"] = .init(title: "B", system: "nds", seconds: 0, baselineSeconds: 7200)
        f.games[PlayHistory.unknownGameKey] = .init(title: "", system: "", seconds: 0, baselineSeconds: 1800)
        f.days = ["2026-10-30": ["a": 3600], "2027-01-03": ["a": 600]]
        let launch = try #require(PlayStats.year(PlayStats.launchYear, files: [f], library: [], calendar: cal))
        #expect(launch.totalSeconds == 3600 + 36000 + 7200 + 1800)
        #expect(launch.undatedSeconds == 36000 + 7200 + 1800)
        #expect(launch.games.map(\.romHash) == ["a", "b"])
        #expect(launch.games.first?.seconds == 39600)
        #expect(launch.consoles.map(\.system) == ["gba", "nds"])
        #expect(launch.newGames == 2)
        #expect(launch.months.reduce(0, +) == 3600)
        #expect(launch.daysPlayed == 1)
        let next = try #require(PlayStats.year(PlayStats.launchYear + 1, files: [f], library: [], calendar: cal))
        #expect(next.totalSeconds == 600)
        #expect(next.undatedSeconds == 0)
        #expect(next.games.count == 1)
    }

    @Test("Badge unlocks: silent the first time, a fresh one once, an old one from iCloud never")
    func badgeAnnouncements() {
        let now = Date()
        let old = PlayStats.Milestone(kind: .hours(10), date: now.addingTimeInterval(-90 * 86_400))
        let fresh = PlayStats.Milestone(kind: .gamesPlayed(5), date: now.addingTimeInterval(-3_600))
        let pulledOld = PlayStats.Milestone(kind: .consoles(3), date: now.addingTimeInterval(-5 * 86_400))
        var r = StoryBadgeAnnouncer.newlyEarned([old], seen: nil, now: now)
        #expect(r.fresh.isEmpty)
        #expect(r.seen == [old.id])
        r = StoryBadgeAnnouncer.newlyEarned([old, fresh], seen: r.seen, now: now)
        #expect(r.fresh.map(\.id) == [fresh.id])
        r = StoryBadgeAnnouncer.newlyEarned([old, fresh], seen: r.seen, now: now)
        #expect(r.fresh.isEmpty)
        r = StoryBadgeAnnouncer.newlyEarned([old, fresh, pulledOld], seen: r.seen, now: now)
        #expect(r.fresh.isEmpty)
        #expect(r.seen.contains(pulledOld.id))
        // Crossed at 23:00, banked at 00:15: dated at the midnight that began
        // its day, 24 h 15 earlier, and still announced (audit, 2026-10-29).
        let lastNight = PlayStats.Milestone(kind: .hours(50), date: now.addingTimeInterval(-(24 * 3_600 + 900)))
        r = StoryBadgeAnnouncer.newlyEarned([old, fresh, pulledOld, lastNight], seen: r.seen, now: now)
        #expect(r.fresh.map(\.id) == [lastNight.id])
        // The past's badges, whenever they first appear (a library empty on
        // the update day: the seen set was seeded without them): seen, never
        // announced (audit, 2026-10-29).
        let past = PlayStats.Milestone(kind: .hours(100), date: now, fromThePast: true)
        r = StoryBadgeAnnouncer.newlyEarned([old, fresh, pulledOld, lastNight, past], seen: r.seen, now: now)
        #expect(r.fresh.isEmpty)
        #expect(r.seen.contains(past.id))
    }

    @Test("Badges crossed by the totals from before the update are the past's; a day played is not")
    func pastBadgesAreMarked() {
        var f = PlayHistoryFile(deviceID: "PB", recordingSince: d("2026-10-28T00:00:00"))
        // 12 h from before the update, then 40 h played on one day after it.
        f.games["h1"] = .init(title: "Game", system: "gba", seconds: 40 * 3600, baselineSeconds: 12 * 3600,
                              firstPlayed: d("2026-08-01T10:00:00"), lastPlayed: d("2026-10-29T23:00:00"))
        f.days = ["2026-10-29": ["h1": 40 * 3600]]
        let s = PlayStats.compute(files: [f], library: [], calendar: cal)
        let ten = s.milestones.first { $0.kind == .hours(10) }
        let fifty = s.milestones.first { $0.kind == .hours(50) }
        #expect(ten?.fromThePast == true)
        #expect(fifty?.fromThePast == false)
        let first = s.milestones.first { milestone in
            if case .firstGame = milestone.kind { return true }
            return false
        }
        #expect(first?.fromThePast == true)
    }

    @Test("The year's start: the launch year from the first game played or imported, a later year from January 1")
    func yearStart() throws {
        var f = PlayHistoryFile(deviceID: "S", recordingSince: d("2026-10-28T08:00:00"))
        f.firstPlayed = d("2026-07-02T20:00:00")
        f.games["a"] = .init(title: "A", system: "gba", seconds: 600, baselineSeconds: 9000)
        f.days = ["2026-10-29": ["a": 600], "2027-02-01": ["a": 300]]
        let library = [PlayStats.LibraryGame(romHash: "a", romFilePath: "a.gba", title: "A", system: "gba",
                                             importedAt: d("2026-06-30T10:00:00"))]
        let launch = try #require(PlayStats.year(2026, files: [f], library: library, calendar: cal))
        #expect(launch.startedOn.map { cal.isDate($0, inSameDayAs: d("2026-06-30T12:00:00")) } == true)
        let next = try #require(PlayStats.year(2027, files: [f], library: library, calendar: cal))
        #expect(next.startedOn.map { cal.isDate($0, inSameDayAs: d("2027-01-01T12:00:00")) } == true)
    }
}
