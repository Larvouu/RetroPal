//
//  PlayHistory.swift
//  EmulateurGBA
//
//  The player's history, kept so it is never lost (2026-10-28, the Retro story
//  page). Until then the story read `PromptTracker`'s running totals in
//  UserDefaults: one device, no dates, gone with a new phone or a reinstall,
//  and a deleted game's hours vanished from every ranking. A player with a
//  hundred hours who changed phones found zero, which is the opposite of the
//  page's whole point.
//
//  THE MODEL, one file per DEVICE (per install of the app on it):
//  - Each install writes only its own file, `<install id>.json`, and names
//    its device inside it by an id kept in the Keychain as this-device-only,
//    so a backup restored onto a new phone does not carry it there; a
//    reinstall never writes over the file of the install before it
//    (`fileName`).
//  - The file holds what was played on that device: minutes per day per game
//    (`days`), each game's totals and identity (`games`), and its sessions.
//  - Every device's file is mirrored to iCloud (`PlayHistorySync`) and the
//    page reads the SUM of all of them. Nothing is ever merged INTO a file,
//    so nothing can be overwritten, and a device that comes back reads what
//    the others played meanwhile.
//
//  A game is keyed by its ROM hash (`GameEntity.romHash`): the same dump on two
//  devices is one game, and renaming or moving it changes nothing. Its title
//  and console are stored with its totals, so a game deleted from the library
//  keeps its hours, its place in the rankings and its name.
//
//  THE PAST: `PromptTracker` counted play time per game and in total before
//  this file existed, with no days. Its totals are imported ONCE into this
//  device's file as a baseline (`baseline` minutes per game, `baselineSessions`)
//  so nobody's hours drop at the update; what only the days can give (the
//  calendar, the year, the months) starts the day the update is installed, and
//  the page says so.
//

import Foundation

/// One device's history, as stored. Plain values, Codable, versioned.
struct PlayHistoryFile: Codable, Equatable {
    /// Bumped if the shape ever changes in a way old readers cannot skip.
    var version: Int = 1
    var deviceID: String
    /// What the player played on this device, game by game.
    var games: [String: Game] = [:]
    /// Seconds played per day ("yyyy-MM-dd", the device's calendar day) per
    /// game (ROM hash). The days the calendar, the months and the year read.
    var days: [String: [String: Double]] = [:]
    /// Sittings on this device since the update (a run of play separated by
    /// 30 minutes idle, `PromptTracker`'s rule), and the longest one.
    var sessions: Int = 0
    var longestSessionSeconds: Double = 0
    /// Sessions counted by `PromptTracker` before this file, imported once.
    var baselineSessions: Int = 0
    /// The day this file started recording days: what the calendar and the
    /// year can show begins here.
    var recordingSince: Date
    /// The earliest day the player is known to have played, on this device:
    /// `PromptTracker`'s first play day when it had one, else the day the file
    /// started. The page takes the earliest of every device's and the library's
    /// first import.
    var firstPlayed: Date?
    /// Seconds played per hour of the day (0-23), to tell a night owl.
    var hours: [Double] = Array(repeating: 0, count: 24)
    /// When a sitting first reached each length, in hours (2, 4): the one
    /// badge the days cannot date, since a sitting is not kept. Optional so
    /// files written before it decode.
    var sessionBadges: [String: Date]? = nil
    /// When the totals imported as the baseline were last added to
    /// (`PromptTracker.lastBankDate`): which snapshot of the past this file
    /// holds. A phone restored from another's backup carries that phone's
    /// totals and the same date to the second, and its baseline is then the
    /// same past, counted once (`PlayHistory.withoutCopiedBaselines`).
    /// Optional: absent from files written before it (audit, 2026-10-29).
    var baselineSource: Date? = nil
    /// The sitting in progress: when play was last banked and how long the
    /// sitting has run. Kept in the file, so a relaunch (iOS ending the app in
    /// the background mid-sitting) continues it instead of counting a new
    /// session and restarting the long-sitting clock (audit, 2026-10-29).
    /// Optional: absent from files written before it.
    var lastBank: Date? = nil
    var currentSessionSeconds: Double? = nil

    enum CodingKeys: String, CodingKey {
        case version, deviceID, games, days, sessions, longestSessionSeconds, baselineSessions,
             recordingSince, firstPlayed, hours, sessionBadges, baselineSource, lastBank, currentSessionSeconds
    }

    init(deviceID: String, recordingSince: Date) {
        self.deviceID = deviceID
        self.recordingSince = recordingSince
    }

    /// Every field but the id and the start may be missing (a file from an
    /// earlier build), and decodes to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        deviceID = try c.decode(String.self, forKey: .deviceID)
        games = try c.decodeIfPresent([String: Game].self, forKey: .games) ?? [:]
        days = try c.decodeIfPresent([String: [String: Double]].self, forKey: .days) ?? [:]
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        longestSessionSeconds = try c.decodeIfPresent(Double.self, forKey: .longestSessionSeconds) ?? 0
        baselineSessions = try c.decodeIfPresent(Int.self, forKey: .baselineSessions) ?? 0
        recordingSince = try c.decode(Date.self, forKey: .recordingSince)
        firstPlayed = try c.decodeIfPresent(Date.self, forKey: .firstPlayed)
        hours = try c.decodeIfPresent([Double].self, forKey: .hours) ?? Array(repeating: 0, count: 24)
        sessionBadges = try c.decodeIfPresent([String: Date].self, forKey: .sessionBadges)
        baselineSource = try c.decodeIfPresent(Date.self, forKey: .baselineSource)
        lastBank = try c.decodeIfPresent(Date.self, forKey: .lastBank)
        currentSessionSeconds = try c.decodeIfPresent(Double.self, forKey: .currentSessionSeconds)
    }

    struct Game: Codable, Equatable {
        /// The title when last played. The page shows the library's current
        /// title while the game is in the library, this one once it is gone.
        var title: String
        var system: String
        /// Seconds played on this device since the update.
        var seconds: Double = 0
        /// Seconds `PromptTracker` had for this game before the update.
        var baselineSeconds: Double = 0
        var firstPlayed: Date?
        var lastPlayed: Date?
        var totalSeconds: Double { seconds + baselineSeconds }
    }
}

/// This device's history: the one writer of its file.
final class PlayHistory {
    static let shared = PlayHistory()

    /// Posted on the main thread when this device's file or another device's
    /// changed (a sitting banked, a pull from iCloud).
    static let didChange = Notification.Name("playHistoryDidChange")

    private let lock = NSLock()
    private let directory: URL
    private let deviceID: String
    private var file: PlayHistoryFile
    private let sessionGapSeconds: TimeInterval = 30 * 60

    /// Local folder of every device's file, this one's included. Not under
    /// Documents: the Files app shows Documents, and this is not the player's
    /// to open or move.
    static var localRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PlayHistory", isDirectory: true)
    }

    /// Where the identity is kept: the Keychain (this device only) and this
    /// install's UserDefaults. A parameter so the rules above can be run
    /// against stand-ins (`PlayHistoryIdentityTests`); the app uses `.live`.
    struct Stores {
        var defaults: UserDefaults
        var lookup: (String) -> KeychainStore.Lookup
        var set: (String, String) -> Void

        static var live: Stores {
            Stores(defaults: .standard,
                   lookup: { KeychainStore.lookup($0) },
                   set: { value, account in KeychainStore.set(value, account: account, thisDeviceOnly: true) })
        }
    }

    private init() {
        // LAUNCHPROBE #if DEBUG
        // LAUNCHPROBE LaunchProbe.mark("PlayHistory.init start")
        // LAUNCHPROBE #endif
        directory = Self.localRoot
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // LAUNCHPROBE #if DEBUG
        // LAUNCHPROBE LaunchProbe.mark("PlayHistory.init folder ready, reading the Keychain")
        // LAUNCHPROBE #endif
        let device = Self.loadDeviceID()
        // LAUNCHPROBE #if DEBUG
        // LAUNCHPROBE LaunchProbe.mark("PlayHistory.init Keychain read (\(device.read ? "read" : "FAILED"))")
        // LAUNCHPROBE #endif
        deviceID = device.id
        fileName = Self.loadFileName(deviceID: device.id, deviceIDWasRead: device.read, directory: directory)
        // LAUNCHPROBE #if DEBUG
        // LAUNCHPROBE LaunchProbe.mark("PlayHistory.init file name \(fileName)")
        // LAUNCHPROBE #endif
        let url = directory.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url) {
            if var decoded = try? JSONDecoder.history.decode(PlayHistoryFile.self, from: data) {
                // This install's own file, written under a stand-in id while
                // the Keychain could not be read (`loadDeviceID`): it takes the
                // device's real id, so it is not counted as another device.
                if decoded.deviceID != deviceID { decoded.deviceID = deviceID }
                file = decoded
            } else {
                // Read but not understood: set aside, never written over. The
                // fresh file below took its name and replaced it, here and then
                // in iCloud (audit, 2026-10-29). Not `.json`, so neither read
                // nor synced; kept for a later build that can read it.
                let aside = url.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: url, to: aside)
                print("[PlayHistory] own file unreadable, set aside as \(aside.lastPathComponent)")
                file = PlayHistoryFile(deviceID: deviceID, recordingSince: Date())
            }
        } else {
            file = PlayHistoryFile(deviceID: deviceID, recordingSince: Date())
        }
        // LAUNCHPROBE #if DEBUG
        // LAUNCHPROBE LaunchProbe.mark("PlayHistory.init end")
        // LAUNCHPROBE #endif
    }

    /// This install's file: `<install id>.json`, the device inside it
    /// (`deviceID`). Never a name an earlier install wrote, and never one that
    /// moves: named after the device too, it changed when the Keychain, locked
    /// at the install's first launch, gave the real id later, and one phone
    /// wrote two files (audit, 2026-10-29). After a reinstall the Keychain still gives the
    /// device id, but this file starts empty: written under the old name it
    /// replaced the old history, here and then in iCloud (audit, 2026-10-29).
    /// Under its own name, the old file comes down from iCloud as one more
    /// file and is summed with it, never written. `PromptTracker`'s totals are
    /// gone with the reinstall too, so nothing is counted twice.
    let fileName: String

    static func loadFileName(deviceID: String, deviceIDWasRead: Bool, directory: URL,
                             stores: Stores = .live) -> String {
        let key = "playHistory.installID"
        // The device the install id was made on. UserDefaults come back from a
        // backup restored onto ANOTHER phone, and that phone must not write
        // this one's file: its Keychain gives another device id, so it makes
        // its own install. "" until the Keychain was first read.
        let stampKey = "playHistory.installDevice"
        if let install = stores.defaults.string(forKey: key) {
            let stamp = stores.defaults.string(forKey: stampKey) ?? ""
            if !deviceIDWasRead || stamp == deviceID {
                return "\(install).json"
            }
            if stamp.isEmpty {
                // Made while the Keychain could not be read: this device's.
                stores.defaults.set(deviceID, forKey: stampKey)
                return "\(install).json"
            }
            // Another phone's install, restored here: a new one below.
        } else {
            // A build that named the file after the device alone (1.3.5
            // before this fix, never shipped): that file is this install's
            // while it is here, since UserDefaults and Application Support go
            // together.
            let legacy = deviceID + ".json"
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(legacy).path) {
                return legacy
            }
        }
        let install = UUID().uuidString
        stores.defaults.set(install, forKey: key)
        stores.defaults.set(deviceIDWasRead ? deviceID : "", forKey: stampKey)
        return "\(install).json"
    }


    /// The id of this device, the first part of its files' names and their
    /// `deviceID`. In the Keychain, this device only: UserDefaults would come
    /// back from a backup onto a new phone, and two phones would then write
    /// one file. A reinstall on the same phone keeps it (the Keychain outlives
    /// the app), so its files are still known as this device's.
    ///
    /// A new id only when the Keychain says there is none. A read that FAILED
    /// (the phone locked since it started, a Keychain error) made a new one
    /// and wrote it over the real id, and this device's past files became
    /// "another device" (audit, 2026-10-29). Then the id this install last
    /// read is used, kept for exactly that; a restored backup carries it, but
    /// a restored phone's Keychain answers "none", never "failed".
    static func loadDeviceID(stores: Stores = .live) -> (id: String, read: Bool) {
        let account = "playHistory.deviceID"
        let cacheKey = "playHistory.deviceIDLastRead"
        switch stores.lookup(account) {
        case .found(let id):
            stores.defaults.set(id, forKey: cacheKey)
            return (id, true)
        case .failed:
            // Never read on this install yet (its first launch, in the
            // background before the phone's first unlock): one id kept for
            // the install, not one per launch, and the Keychain left alone.
            if let cached = stores.defaults.string(forKey: cacheKey) { return (cached, false) }
            let id = UUID().uuidString
            stores.defaults.set(id, forKey: cacheKey)
            return (id, false)
        case .notFound:
            let id = UUID().uuidString
            stores.set(id, account)
            let stored: String
            if case .found(let read) = stores.lookup(account) { stored = read } else { stored = id }
            stores.defaults.set(stored, forKey: cacheKey)
            return (stored, true)
        }
    }


    // MARK: - Recording

    /// One stretch of play banked on this game. Called where `PromptTracker`
    /// banks its own (quit, background, resign active), with the same seconds.
    func record(seconds: TimeInterval, romHash: String, title: String, system: String, at now: Date = Date()) {
        guard seconds > 0, !romHash.isEmpty else { return }
        lock.lock()
        let start = now.addingTimeInterval(-seconds)
        // Sessions: the same idle rule as PromptTracker's count.
        let idle = file.lastBank.map { max(0, start.timeIntervalSince($0)) } ?? .greatestFiniteMagnitude
        var currentSessionSeconds = file.currentSessionSeconds ?? 0
        if idle >= sessionGapSeconds {
            file.sessions += 1
            currentSessionSeconds = 0
        }
        currentSessionSeconds += seconds
        file.currentSessionSeconds = currentSessionSeconds
        file.longestSessionSeconds = max(file.longestSessionSeconds, currentSessionSeconds)
        for hours in PlayStats.sessionMilestones where currentSessionSeconds >= Double(hours) * 3600 {
            var badges = file.sessionBadges ?? [:]
            if badges[String(hours)] == nil {
                badges[String(hours)] = now
                file.sessionBadges = badges
            }
        }
        file.lastBank = now

        var game = file.games[romHash] ?? PlayHistoryFile.Game(title: title, system: system)
        if !title.isEmpty { game.title = title }
        game.system = system
        game.seconds += seconds
        game.firstPlayed = game.firstPlayed ?? start
        game.lastPlayed = now
        file.games[romHash] = game
        if file.firstPlayed == nil { file.firstPlayed = start }

        // The stretch split across the days and hours it covered, so a sitting
        // past midnight counts on both days. A banked stretch can include time
        // paused in the menu (it is banked at quit or background), so it is
        // placed as ending now: the totals are exact, the hour it lands on is
        // the best reading there is.
        Self.spread(from: start, to: now) { day, hour, part in
            self.file.days[day, default: [:]][romHash, default: 0] += part
            self.file.hours[hour] += part
        }
        let snapshot = file
        lock.unlock()
        write(snapshot)
    }

    /// Calls `body` with each (day, hour) slice of [start, end] and its seconds.
    static func spread(from start: Date, to end: Date, calendar: Calendar = .current,
                       _ body: (String, Int, Double) -> Void) {
        var cursor = start
        while cursor < end {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            let next = min(end, hourStart.addingTimeInterval(3600))
            let part = next.timeIntervalSince(cursor)
            if part > 0 {
                body(dayKey(cursor, calendar: calendar), calendar.component(.hour, from: cursor), part)
            }
            guard next > cursor else { break }
            cursor = next
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - The past, once

    /// The key of the one entry holding play from before the update on games
    /// the library no longer held then (their names were never kept, so they
    /// count in the total and nowhere else).
    static let unknownGameKey = "_before"

    /// Imports `PromptTracker`'s totals as this device's baseline, once: per
    /// game where the library still knows it (title, console), the rest of the
    /// old total as `unknownGameKey`, the session count, the first play day.
    /// Run with the library's games; waits for a library with games, so a
    /// phone whose library is not back yet does not import an empty past.
    func importBaselineIfNeeded(games: [(romHash: String, romName: String, title: String, system: String)],
                                tracker: PromptTracker = .shared) {
        let key = "playHistory.baselineImported"
        guard !UserDefaults.standard.bool(forKey: key), !games.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        lock.lock()
        var known: Double = 0
        for game in games where !game.romHash.isEmpty {
            let seconds = tracker.gamePlayTime(romName: game.romName)
            guard seconds > 0 else { continue }
            var entry = file.games[game.romHash] ?? PlayHistoryFile.Game(title: game.title, system: game.system)
            entry.baselineSeconds += seconds
            file.games[game.romHash] = entry
            known += seconds
        }
        // The old total also counted games deleted before the update; their
        // hours stay in the lifetime total, under no name.
        let rest = tracker.totalPlaySeconds - known
        if rest > 60 {
            var entry = file.games[Self.unknownGameKey] ?? PlayHistoryFile.Game(title: "", system: "")
            entry.baselineSeconds += rest
            file.games[Self.unknownGameKey] = entry
        }
        file.baselineSessions = tracker.sessionCount
        file.baselineSource = tracker.lastBankDate
        if let first = tracker.firstPlayDay {
            file.firstPlayed = min(file.firstPlayed ?? first, first)
        }
        let snapshot = file
        lock.unlock()
        write(snapshot)
    }

    // MARK: - Storage

    private func write(_ snapshot: PlayHistoryFile) {
        let url = directory.appendingPathComponent(fileName)
        if let data = try? JSONEncoder.history.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
        iCloudSaveSync.shared.syncNow()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    /// Every device's file on this device (its own and the pulled ones), the
    /// past counted once (`withoutCopiedBaselines`).
    static func loadAll(from root: URL = localRoot) -> [PlayHistoryFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return withoutCopiedBaselines(names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
            return try? JSONDecoder.history.decode(PlayHistoryFile.self, from: data)
        })
    }

    /// The same past imported on two devices counts once. A phone restored
    /// from another's backup made before the update carries that phone's
    /// `PromptTracker` totals, and each imported them as its baseline: the
    /// hours before the update counted twice, and a "second device" badge
    /// (audit, 2026-10-29). Files of DIFFERENT devices holding the same
    /// snapshot hold one past; the others' baselines read as zero. A phone
    /// that went on playing before it updated banked again, so its date moved
    /// and it is not a copy. Files of one device (a reinstall) never share a
    /// source: the reinstall's totals are gone.
    static func withoutCopiedBaselines(_ files: [PlayHistoryFile]) -> [PlayHistoryFile] {
        // A copy is the same SNAPSHOT: the same last-bank date (stored to the
        // second), the same session count, and the same total to within the
        // 60 seconds the import may drop as an unnamed rest. The date alone
        // let two phones that banked within one second zero one's real past
        // (re-audit, 2026-10-29). In each such group the file of the lowest
        // device id keeps its baseline: the same answer whatever the order.
        func baseline(_ f: PlayHistoryFile) -> Double { f.games.values.reduce(0) { $0 + $1.baselineSeconds } }
        var keepers: [String: PlayHistoryFile] = [:]
        for f in files.sorted(by: { $0.deviceID < $1.deviceID }) {
            guard let source = f.baselineSource else { continue }
            let key = "\(Int(source.timeIntervalSince1970))-\(f.baselineSessions)"
            if keepers[key] == nil { keepers[key] = f }
        }
        return files.map { f in
            guard let source = f.baselineSource,
                  let keeper = keepers["\(Int(source.timeIntervalSince1970))-\(f.baselineSessions)"],
                  keeper.deviceID != f.deviceID,
                  abs(baseline(keeper) - baseline(f)) <= 61 else { return f }
            var copy = f
            for (hash, game) in copy.games { var g = game; g.baselineSeconds = 0; copy.games[hash] = g }
            copy.baselineSessions = 0
            return copy
        }
    }

}

extension JSONEncoder {
    static var history: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var history: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
