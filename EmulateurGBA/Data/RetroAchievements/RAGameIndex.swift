//
//  RAGameIndex.swift
//  EmulateurGBA
//
//  The on-device RetroAchievements library index: which imported games have an
//  RA set (eligibility, resolved WITHOUT credentials via rc_hash + the hash
//  endpoint), the signed-in user's per-game progress, and a local log of the
//  achievements earned in Retro Pal. This is what lets the Library and Game
//  Details surfaces show RA state without loading each game into rc_client.
//
//  Main-thread confined, like the RetroAchievements manager that feeds it: every
//  mutation comes from a main-thread callback, and SwiftUI observes @Published.
//  Persistence is two small JSON files in Application Support (device-local
//  cache, deliberately NOT in Documents and NOT synced).
//

import Foundation

/// One library game's cached RA identity + the signed-in user's progress on it.
/// Keyed by OUR import hash (GameEntity.romHash, a SHA256), which is stable for
/// the life of the game file. The RA-side rc_hash (MD5) is computed once and
/// kept so eligibility never has to re-hash the ROM.
struct RAGameRecord: Codable, Equatable {
    let romHash: String
    var raHash: String
    var consoleID: UInt32
    /// The RA game id. 0 = resolved, but this ROM has no RA set.
    var gameID: UInt32
    var title: String?
    var boxArtURL: String?
    var unlocked: Int
    var total: Int
    /// Points earned / available across the FULL merged set (all subsets), from
    /// an rc_client load. nil until the game has been loaded once in-app —
    /// the all-user-progress endpoint has no points and only covers the base
    /// set, so it can never fill these. Optionals so pre-existing index JSON
    /// keeps decoding.
    var pointsEarned: Int? = nil
    var pointsTotal: Int? = nil
    /// Last known measured progress of the still-locked measured achievements
    /// (e.g. "44/399" at 11%), snapshotted from the LIVE runtime during play.
    /// The server has no per-user measured-progress endpoint and a display
    /// load has no memory to evaluate, so without this snapshot the x/y
    /// bars could never show outside a live session. Merged per snapshot
    /// (new values win, unlocked drop out, absent ones survive — see
    /// mergeMeasuredProgress). Optional so pre-existing index JSON keeps
    /// decoding.
    var measured: [RAMeasuredEntry]? = nil
    var resolvedAt: Date
    var refreshedAt: Date?

    /// Identified on RA AND on a console Retro Pal can bridge (consoleID is
    /// OUR extension mapping — all 4 shipped consoles since the melonDS
    /// bridge; 0 = an unknown extension, or a stale pre-bridge NDS record
    /// awaiting re-resolution). A consoleID-0 record must read as ineligible
    /// everywhere (one once listed a game as BOTH covered and uncovered).
    var isEligible: Bool { gameID != 0 && consoleID != 0 }

    /// True once an rc_client load provided the merged-set truth: unlocked /
    /// total then cover ALL subsets and must not be overwritten by the
    /// base-set-only all-user-progress refresh.
    var countsFromLoad: Bool { pointsTotal != nil }
}

/// One still-locked measured achievement's progress, snapshotted from the live
/// runtime (see RAGameRecord.measured). Keyed by RA's stable achievement id.
struct RAMeasuredEntry: Codable, Equatable {
    let achievementID: UInt32
    /// rc_client's display string, e.g. "44/399".
    let progress: String
    /// 0-100.
    let percent: Double
}

/// One achievement earned in Retro Pal, logged locally as it unlocks. Feeds the
/// library "last unlocks" strip and the share cards. Deliberately LOCAL-ONLY:
/// the connect API has no profile-wide recents endpoint, and asking users to
/// paste a Web API key from the RA control panel is not a UX we want
/// (decision 2026-07-01).
struct RAUnlockLogEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let gameID: UInt32
    let gameTitle: String
    let title: String
    let detail: String
    let points: Int
    let rarity: Double
    let badgeURL: String?
    let boxArtURL: String?

    /// True for rc_client's server-synthesized warning entries ("Warning:
    /// Unknown Emulator", "Unsupported Game Version") persisted before the
    /// bridge filtered the unlock event (RAClient.mm now drops
    /// id >= 101000001 at the source). The log never stored the achievement
    /// ID, so legacy entries are matched by the fixed server titles plus
    /// their 0 points.
    var isSyntheticWarning: Bool {
        guard points == 0 else { return false }
        let lowered = title.lowercased()
        return lowered == "unsupported game version" || lowered == "warning: unknown emulator"
    }
}

/// One imported game as the library sees it: the user-facing title (edited or
/// import-derived, NEVER the RA set name, so list positions stay stable) and
/// whether its console is RA-capable here at all (all 4 shipped consoles are,
/// since the melonDS bridge; unknown extensions are not).
/// Ephemeral: rebuilt from the library at launch, before any game can load.
struct RALibraryEntry: Equatable {
    let romHash: String
    let filename: String
    let title: String
    let raSupportedConsole: Bool
}

final class RAGameIndex: ObservableObject {
    static let shared = RAGameIndex()

    /// All known records, keyed by romHash (GameEntity.romHash).
    @Published private(set) var records: [String: RAGameRecord] = [:]
    /// Achievements earned in Retro Pal, newest first (capped).
    @Published private(set) var recentUnlocks: [RAUnlockLogEntry] = []
    /// The current library, keyed by romHash (published so a rename or delete
    /// re-renders the RA surfaces that display library titles).
    @Published private(set) var libraryEntries: [String: RALibraryEntry] = [:]

    /// ROM filename -> romHash. Lets core-level events (which only know the
    /// ROM path) find their record.
    private var hashByFilename: [String: String] = [:]

    private static let unlockLogCap = 50
    /// A record that resolved to "no set" is re-checked after this long — RA
    /// sets get added to games over time, so "not available" is never final.
    static let noSetRecheckInterval: TimeInterval = 14 * 24 * 3600

    private let directory: URL
    private var indexFile: URL { directory.appendingPathComponent("index.json") }
    private var unlocksFile: URL { directory.appendingPathComponent("unlocks.json") }
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        directory = support.appendingPathComponent("RetroAchievements", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Lookups

    func record(forROMHash romHash: String) -> RAGameRecord? { records[romHash] }

    func record(forFilename filename: String) -> RAGameRecord? {
        hashByFilename[filename].flatMap { records[$0] }
    }

    func romHash(forFilename filename: String) -> String? { hashByFilename[filename] }

    func filename(forROMHash romHash: String) -> String? {
        hashByFilename.first(where: { $0.value == romHash })?.key
    }

    /// The library ROM filename behind an RA game id (unlock-log entries only
    /// store the id). nil when the game has since left the library — its share
    /// card then falls back to the Classic style.
    func filename(forGameID gameID: UInt32) -> String? {
        guard gameID != 0,
              let hash = records.first(where: { $0.value.gameID == gameID })?.key
        else { return nil }
        return filename(forROMHash: hash)
    }

    /// True when at least one known record is RA-eligible (drives the library
    /// section's visibility; disappears with the last eligible game).
    var hasEligibleGame: Bool { records.values.contains { $0.isEligible } }

    /// True when this romHash still needs (re-)resolving: never seen, or
    /// resolved to "no set" long enough ago to be worth re-checking.
    func needsResolution(romHash: String) -> Bool {
        guard let record = records[romHash] else { return true }
        // A record written while its console had no RA bridge here (consoleID
        // 0 — NDS games seen before the melonDS bridge landed) re-resolves
        // immediately so it can gain eligibility now that the bridge exists.
        if record.consoleID == 0 { return true }
        if record.isEligible { return false }
        return Date().timeIntervalSince(record.resolvedAt) > Self.noSetRecheckInterval
    }

    // MARK: - Mutations (main thread)

    /// Sync with the COMPLETE library and drop records for games that are no
    /// longer imported (the RA surfaces must disappear with the game). Only
    /// the library view calls this; single-game callers use merge(entry:) so
    /// they never prune the others.
    func syncLibrary(entries: [RALibraryEntry]) {
        let byHash = Dictionary(entries.map { ($0.romHash, $0) },
                                uniquingKeysWith: { first, _ in first })
        if libraryEntries != byHash { libraryEntries = byHash }
        hashByFilename = Dictionary(entries.map { ($0.filename, $0.romHash) },
                                    uniquingKeysWith: { first, _ in first })
        let before = records.count
        records = records.filter { byHash[$0.key] != nil }
        if records.count != before { scheduleSave() }
    }

    /// Add one game without touching anything else.
    func merge(entry: RALibraryEntry) {
        if libraryEntries[entry.romHash] != entry { libraryEntries[entry.romHash] = entry }
        hashByFilename[entry.filename] = entry.romHash
    }

    /// The user-facing title for a record's game (edited name first).
    func libraryTitle(forROMHash romHash: String) -> String? {
        libraryEntries[romHash]?.title
    }

    /// Store a fresh hash-endpoint resolution (gameID 0 = no set).
    func applyResolution(romHash: String, raHash: String, consoleID: UInt32, gameID: UInt32) {
        var record = records[romHash] ?? RAGameRecord(
            romHash: romHash, raHash: raHash, consoleID: consoleID, gameID: gameID,
            title: nil, boxArtURL: nil, unlocked: 0, total: 0,
            resolvedAt: Date(), refreshedAt: nil)
        record.raHash = raHash
        record.consoleID = consoleID
        record.gameID = gameID
        record.resolvedAt = Date()
        records[romHash] = record
        scheduleSave()
    }

    /// Apply one console's all-user-progress entries (matched by RA game id).
    /// The endpoint only knows the BASE set (subsets are separate ids it
    /// can't be matched to), so for load-enriched records its counts are a
    /// LOWER BOUND: they may only RAISE the stored unlock count (never touch
    /// the merged-set total, which would shrink back to e.g. FireRed's "61").
    /// That raise is what fills progress in ONE SHOT at every (re-)login —
    /// clearUserProgress zeroes the counts on logout — while a game load
    /// still recomputes the exact merged values.
    func applyProgress(entries: [(gameID: UInt32, unlocked: Int, total: Int)]) {
        guard !entries.isEmpty else { return }
        let byGameID = Dictionary(entries.map { ($0.gameID, $0) },
                                  uniquingKeysWith: { first, _ in first })
        var changed = false
        for (key, var record) in records where record.isEligible {
            guard let entry = byGameID[record.gameID] else { continue }
            if record.countsFromLoad {
                record.unlocked = max(record.unlocked, min(entry.unlocked, record.total))
            } else {
                record.unlocked = entry.unlocked
                record.total = entry.total
            }
            record.refreshedAt = Date()
            records[key] = record
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// Enrich a record from an rc_client game load (title, box art, live
    /// progress). Only called with a POSITIVE identification (gameID > 0):
    /// the load callback cannot distinguish "no set" from a network failure,
    /// so ineligibility is only ever written by the resolver path.
    func applyLoadedGame(romHash: String, consoleID: UInt32, gameID: UInt32,
                         title: String?, boxArtURL: String?, unlocked: Int, total: Int,
                         pointsEarned: Int, pointsTotal: Int) {
        // consoleID 0 = a console with no RA memory bridge here (unknown
        // extension): never record it as an RA game, whatever rc_client
        // identified.
        guard gameID != 0, consoleID != 0 else { return }
        var record = records[romHash] ?? RAGameRecord(
            romHash: romHash, raHash: "", consoleID: consoleID, gameID: gameID,
            title: nil, boxArtURL: nil, unlocked: 0, total: 0,
            resolvedAt: Date(), refreshedAt: nil)
        record.gameID = gameID
        record.consoleID = consoleID
        if let title { record.title = title }
        if let boxArtURL { record.boxArtURL = boxArtURL }
        record.unlocked = unlocked
        record.total = total
        record.pointsEarned = pointsEarned
        record.pointsTotal = pointsTotal
        record.refreshedAt = Date()
        records[romHash] = record
        scheduleSave()
    }

    func logUnlock(_ entry: RAUnlockLogEntry) {
        recentUnlocks.insert(entry, at: 0)
        if recentUnlocks.count > Self.unlockLogCap {
            recentUnlocks.removeLast(recentUnlocks.count - Self.unlockLogCap)
        }
        // The user just earned one more in the current game — reflect it in the
        // record immediately rather than waiting for the next server refresh.
        // Points too (drift self-heals: every load recomputes exactly).
        if let key = records.first(where: { $0.value.gameID == entry.gameID })?.key,
           var record = records[key] {
            record.unlocked = record.total > 0 ? min(record.unlocked + 1, record.total)
                                               : record.unlocked + 1
            if let earned = record.pointsEarned {
                record.pointsEarned = record.pointsTotal.map { min(earned + entry.points, $0) }
                    ?? earned + entry.points
            }
            records[key] = record
        }
        // An unlock is the one thing that must NEVER be lost: save NOW, not
        // on the debounce. The debounced path stays for cheap metadata, but an
        // unlock followed by quit + force-kill within the debounce window was
        // silently dropping log entries ("only the latest unlock ever shows").
        saveWorkItem?.cancel()
        saveNow()
    }

    /// Merge a live snapshot into a game's stored measured progress. MERGE,
    /// not replace: hit-count-based measured achievements (e.g. "die 100
    /// times") reset to zero on a fresh session unless a save state restores
    /// them, so they vanish from the new snapshot — a replace would wipe the
    /// real progress recorded earlier. New values win per achievement,
    /// unlocked ones are removed, everything else survives.
    func mergeMeasuredProgress(romHash: String, entries: [RAMeasuredEntry], unlockedIDs: Set<UInt32>) {
        guard var record = records[romHash] else { return }
        var byID = Dictionary((record.measured ?? []).map { ($0.achievementID, $0) },
                              uniquingKeysWith: { first, _ in first })
        for id in unlockedIDs { byID.removeValue(forKey: id) }
        for entry in entries { byID[entry.achievementID] = entry }
        // Deterministic order so the Equatable no-change guard is meaningful.
        let merged = byID.values.sorted { $0.achievementID < $1.achievementID }
        let newValue: [RAMeasuredEntry]? = merged.isEmpty ? nil : merged
        guard record.measured != newValue else { return }
        record.measured = newValue
        records[romHash] = record
        scheduleSave()
    }

    /// Last snapshotted measured progress for a game, keyed by achievement id.
    func measuredProgress(forROMHash romHash: String) -> [UInt32: RAMeasuredEntry] {
        guard let entries = records[romHash]?.measured else { return [:] }
        return Dictionary(entries.map { ($0.achievementID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// On sign-out: progress and the unlock log belong to the account; keep
    /// only the account-independent eligibility data.
    func clearUserProgress() {
        for (key, var record) in records {
            record.unlocked = 0
            // Points EARNED are user progress too; leaving them made the
            // record still read as load-enriched after a re-login, which
            // blocked the endpoint refresh and froze everything at 0 until
            // each game was manually reloaded. pointsTotal + total stay: they
            // are SET structure (account-independent, merged-set truth).
            record.pointsEarned = nil
            record.refreshedAt = nil
            // Measured snapshots are user progress too.
            record.measured = nil
            records[key] = record
        }
        recentUnlocks = []
        scheduleSave()
    }

    // MARK: - Persistence

    private struct IndexFile: Codable {
        var records: [String: RAGameRecord]
    }

    private func load() {
        if let data = try? Data(contentsOf: indexFile),
           let decoded = try? JSONDecoder().decode(IndexFile.self, from: data) {
            records = decoded.records
        }
        if let data = try? Data(contentsOf: unlocksFile),
           let decoded = try? JSONDecoder().decode([RAUnlockLogEntry].self, from: data) {
            // One-time cleanup: synthetic warning entries logged before the
            // bridge filtered the unlock event. Persist the purge so it
            // doesn't re-run forever.
            let cleaned = decoded.filter { !$0.isSyntheticWarning }
            recentUnlocks = cleaned
            if cleaned.count != decoded.count { scheduleSave() }
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func saveNow() {
        if let data = try? JSONEncoder().encode(IndexFile(records: records)) {
            try? data.write(to: indexFile, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(recentUnlocks) {
            try? data.write(to: unlocksFile, options: .atomic)
        }
    }
}
