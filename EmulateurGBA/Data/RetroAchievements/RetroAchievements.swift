//
//  RetroAchievements.swift
//  EmulateurGBA
//
//  The app-facing RetroAchievements manager: a single shared service that owns
//  the rc_client wrapper (RAClient), holds the published login + session state
//  the UI binds to, and bridges the emulator frame loop into rc_client.
//
//  Branch 1 scope: softcore only, GB/GBC/GBA, FREE (no Pro gate). Login
//  persistence (Keychain) + the Settings login UI land in Phase 3; the in-game
//  unlock HUD + save-state progress in Phase 4. Until a user logs in, every
//  surface here is inert.
//

import Foundation
import Network
import SwiftUI
import UIKit
import os

/// One earned achievement, surfaced to the in-game HUD. Carries the full share
/// context (rarity, game, box art) so tapping the banner can open the
/// achievement share card directly.
struct RAUnlock: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let badgeURL: URL?
    let points: Int
    let rarity: Double
    let gameTitle: String
    let boxArtURL: URL?
}

/// The user's progress on the currently loaded game (nil when none / unidentified).
struct RAGameProgress: Equatable {
    let title: String
    let unlocked: Int
    let total: Int
}

/// A measured (multi-step) achievement that just progressed, e.g. catching one
/// more of the 151. Drives the small transient in-game progress pill.
struct RAProgressIndicator: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let badgeURL: URL?
    let progress: String   // rc_client's formatted value, e.g. "2/151"
    let percent: Double    // 0...100
}

/// A transient in-game notice about the LIVE session's tracking state: RA
/// could not load the game's set (offline launch), or the automatic retry
/// just brought tracking back. Never silent — the player must know when a
/// session is not earning (non-negotiable).
struct RASessionNotice: Identifiable, Equatable {
    let id = UUID()
    /// false = tracking paused (load failed); true = tracking (re)active.
    let resumed: Bool
}

final class RetroAchievements: NSObject, ObservableObject {
    static let shared = RetroAchievements()

    // MARK: Published state (UI binds to these; all mutated on the main thread)
    @Published private(set) var isLoggedIn = false
    @Published private(set) var username: String?
    @Published private(set) var displayName: String?
    @Published private(set) var softcoreScore: Int = 0
    /// The most recent unlock, for the in-game celebration HUD. Set on unlock,
    /// cleared by the HUD once shown.
    @Published var lastUnlock: RAUnlock?
    /// Progress on the game currently loaded in the active session.
    @Published private(set) var currentGame: RAGameProgress?
    /// The measured achievement currently progressing, for the in-game pill.
    /// Set on rc_client's indicator show/update, cleared on its hide (the HUD
    /// also self-clears as a pause-safety net).
    @Published var progressIndicator: RAProgressIndicator?
    /// True when an unlock is queued for retry (offline). Nothing is lost; it
    /// syncs on reconnect. Surfaced as a "pending sync" hint in the dashboard.
    @Published private(set) var pendingSync = false
    /// The in-game tracking-state notice (paused offline / resumed). Set on a
    /// live load failure and on the successful automatic retry; cleared by the
    /// HUD after display and on endSession.
    @Published var sessionNotice: RASessionNotice?
    /// Live connectivity (NWPathMonitor). RA surfaces use it to fail fast into
    /// an explicit offline state instead of loading into the void.
    @Published private(set) var isOnline = true

    /// The loaded game's achievements for the dashboard (empty if none).
    func achievements() -> [RAAchievementInfo] { client.currentGameAchievements() }

    /// Box-art URL for the loaded game (for the share card), from rc_client.
    func currentGameBoxArtURL() -> URL? { client.currentGameBoxArtURL().flatMap(URL.init(string:)) }

    static let enabledKey = "raEnabled"
    /// User master toggle. RA still does nothing until the user also logs in;
    /// disabling tears down any live session. Published so Settings reacts.
    @Published var isEnabled: Bool = (UserDefaults.standard.object(forKey: RetroAchievements.enabledKey) as? Bool ?? true) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { endSession() }
        }
    }

    private let client: RAClient
    private weak var activeSession: EmulatorSession?
    /// The live session's ROM path, kept so the reconnect path can retry the
    /// rc_client load mid-session (a failed load used to stay dead until the
    /// game was relaunched).
    private var activeSessionROMPath: String?
    /// The live session attempted a load that failed (or could not start,
    /// login pending) — the successful retry then shows the "resumed" notice.
    private var liveSessionLoadFailed = false
    /// The silent token login failed on TRANSPORT (offline launch); retried on
    /// every connectivity restoration. The token is only ever deleted when the
    /// server actually rejects it.
    private var pendingSessionRestore = false
    private let pathMonitor = NWPathMonitor()
    private var displayLoadCompletion: ((Bool) -> Void)?
    /// Bounds a display load so a dead/slow connection cannot spin forever;
    /// cancelled the moment the load callback arrives.
    private var displayLoadTimeout: DispatchWorkItem?
    private static let displayLoadTimeoutSeconds: TimeInterval = 12
    /// Filename of the ROM currently loaded in rc_client (live session OR a
    /// Game Details display load), so load/unlock events can find their
    /// RAGameIndex record.
    private var currentROMFilename: String?

    // MARK: Library index plumbing
    /// romHashes queued for hash-endpoint resolution, processed one at a time.
    private var resolutionQueue: [(romHash: String, path: String)] = []
    private var resolutionInFlight = false
    private var lastProgressRefreshAt: Date?
    private static let progressRefreshInterval: TimeInterval = 5 * 60

    private static let keychainUsername = "ra_username"
    private static let keychainToken = "ra_token"

    /// The in-game sound toggle, as the celebration sounds see it: the live
    /// session state while playing, else the persisted preference (same key
    /// the emulator restores on launch). RA sounds NEVER play while the game
    /// is muted.
    private var isGameSoundOn: Bool {
        if let session = activeSession { return !session.isAudioMuted }
        return !UserDefaults.standard.bool(forKey: "audioMuted")
    }

    private override init() {
        client = RAClient(userAgentProductClause: Self.userAgentProductClause())
        super.init()
        client.delegate = self
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                // Back online: catch up on anything the offline window blocked
                // — including re-arming a session whose silent login or game
                // load failed offline (the subway case: launch underground,
                // resume earning the moment connectivity returns).
                if online {
                    self.retrySessionRestoreIfNeeded()
                    self.retryLiveSessionLoadIfNeeded()
                    self.resolveNextIfIdle()
                    self.refreshProgressIfNeeded()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.retropal.ra.path"))
        restoreSessionIfPossible()
    }

    // MARK: - Login

    func login(username: String, password: String,
               completion: @escaping (Bool, String?) -> Void) {
        client.login(withUsername: username, password: password) { [weak self] success, token, error, _ in
            if success, let token {
                // Persist the TOKEN only (never the password) for silent re-login.
                KeychainStore.set(username, account: Self.keychainUsername)
                KeychainStore.set(token, account: Self.keychainToken)
                Analytics.signal("ra_login")    // anonymous funnel: a fresh sign-in
                Analytics.signal("ra_active")   // this user uses RA (adoption %)
                self?.refreshProgressIfNeeded(force: true)
            }
            self?.refreshUser()
            completion(success, error)
        }
    }

    /// Silently restore a session from the stored token on launch. No-op if no
    /// token is stored or RA is disabled. A TRANSPORT failure (offline launch)
    /// keeps the token and retries on every connectivity restoration — only a
    /// server rejection deletes it (one subway launch used to silently sign
    /// the user out of RA for good).
    private func restoreSessionIfPossible() {
        guard isEnabled,
              let username = KeychainStore.get(Self.keychainUsername),
              let token = KeychainStore.get(Self.keychainToken) else {
            refreshUser()
            return
        }
        pendingSessionRestore = false
        client.login(withUsername: username, token: token) { [weak self] success, _, _, rejected in
            guard let self else { return }
            if success {
                // Returning RA user this session — counts toward the adoption %
                // (unique users on ra_active / all users). Anonymous, no identity.
                Analytics.signal("ra_active")
                self.refreshProgressIfNeeded(force: true)
                // A game may already be running (launched while the login was
                // still failing) — arm its tracking now.
                DispatchQueue.main.async { self.retryLiveSessionLoadIfNeeded() }
            } else if rejected {
                // The SERVER refused the token (expired / revoked) — clear it
                // so we stop retrying.
                KeychainStore.remove(Self.keychainToken)
            } else {
                // Transport failure: keep the token, retry when back online.
                self.pendingSessionRestore = true
            }
            self.refreshUser()
        }
    }

    /// Re-attempt the silent token login after connectivity returned (the
    /// launch-time attempt failed on transport).
    private func retrySessionRestoreIfNeeded() {
        guard pendingSessionRestore, !client.isLoggedIn else { return }
        Self.debugLog("[RA] reconnect: retrying the silent session restore")
        restoreSessionIfPossible()
    }

    /// Load the LIVE session's game into rc_client if it isn't (the launch-time
    /// load failed offline, or login completed after the game started). Called
    /// on connectivity restoration and after a late silent login.
    private func retryLiveSessionLoadIfNeeded() {
        guard isEnabled, client.isLoggedIn,
              activeSession != nil, let path = activeSessionROMPath,
              !client.isGameLoaded, !client.isLoadInFlight else { return }
        Self.debugLog("[RA] reconnect: retrying the live session's game load")
        client.loadGame(atPath: path)
    }

    func logout() {
        client.logout()
        endSession()
        KeychainStore.remove(Self.keychainUsername)
        KeychainStore.remove(Self.keychainToken)
        // Progress + the unlock log belong to the account; eligibility stays.
        RAGameIndex.shared.clearUserProgress()
        lastProgressRefreshAt = nil
        refreshUser()
    }

    // MARK: - Library index (eligibility + per-game progress, no game loaded)

    /// One imported game, as the library surfaces see it. `title` is the
    /// user-facing name (edited or import-derived), which RA surfaces display
    /// so list positions never shift when RA metadata arrives.
    struct LibraryGame {
        let romHash: String
        let filename: String
        let path: String
        let title: String
    }

    private func libraryEntry(for game: LibraryGame) -> RALibraryEntry {
        RALibraryEntry(romHash: game.romHash,
                       filename: game.filename,
                       title: game.title,
                       raSupportedConsole: RAClient.consoleId(forROMPath: game.path) != 0)
    }

    /// Called by the library with the COMPLETE set of imported games. Syncs the
    /// index (records for deleted games disappear), queues credential-free
    /// eligibility resolution for unknown games, and refreshes the signed-in
    /// user's per-game progress (throttled). Cheap to call repeatedly.
    func syncLibraryGames(_ games: [LibraryGame]) {
        guard isEnabled else { return }
        RAGameIndex.shared.syncLibrary(entries: games.map(libraryEntry(for:)))
        enqueueResolution(for: games)
        refreshProgressIfNeeded()
    }

    /// Called by single-game surfaces (Game Details) to make sure ONE game's
    /// eligibility is known. Never prunes the index.
    func noteGame(_ game: LibraryGame) {
        guard isEnabled else { return }
        RAGameIndex.shared.merge(entry: libraryEntry(for: game))
        enqueueResolution(for: [game])
        refreshProgressIfNeeded()
    }

    private func enqueueResolution(for games: [LibraryGame]) {
        let index = RAGameIndex.shared
        let pending = games.filter { game in
            index.needsResolution(romHash: game.romHash)
                && RAClient.consoleId(forROMPath: game.path) != 0
                && !resolutionQueue.contains { $0.romHash == game.romHash }
        }
        resolutionQueue.append(contentsOf: pending.map { ($0.romHash, $0.path) })
        resolveNextIfIdle()
    }

    /// Resolve queued games one at a time: rc_hash on a background queue (file
    /// I/O + MD5), then the credential-free hash endpoint. A transport failure
    /// drops the entry without writing a record, so it retries on the next
    /// noteLibraryGames pass.
    private func resolveNextIfIdle() {
        guard !resolutionInFlight, let next = resolutionQueue.first else { return }
        resolutionInFlight = true
        resolutionQueue.removeFirst()
        let consoleID = RAClient.consoleId(forROMPath: next.path)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let raHash = RAClient.hashForROM(atPath: next.path)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let raHash else {
                    // Unreadable / unsupported: record as "no set" so we don't
                    // re-hash a broken file every library pass.
                    RAGameIndex.shared.applyResolution(romHash: next.romHash, raHash: "",
                                                       consoleID: consoleID, gameID: 0)
                    self.resolutionInFlight = false
                    self.resolveNextIfIdle()
                    return
                }
                self.client.resolveHash(raHash) { success, gameId in
                    if success {
                        RAGameIndex.shared.applyResolution(romHash: next.romHash, raHash: raHash,
                                                           consoleID: consoleID, gameID: gameId)
                    }
                    self.resolutionInFlight = false
                    self.resolveNextIfIdle()
                }
            }
        }
    }

    /// Pull the signed-in user's unlocked/total counts for every console that
    /// has at least one eligible game in the library. Throttled; pass
    /// force=true right after a fresh login.
    func refreshProgressIfNeeded(force: Bool = false) {
        guard isEnabled, client.isLoggedIn else { return }
        if !force, let last = lastProgressRefreshAt,
           Date().timeIntervalSince(last) < Self.progressRefreshInterval { return }
        let consoles = Set(RAGameIndex.shared.records.values
            .filter { $0.isEligible }
            .map { $0.consoleID })
        guard !consoles.isEmpty else { return }
        lastProgressRefreshAt = Date()
        for console in consoles {
            client.fetchAllProgress(forConsole: console) { success, entries in
                guard success else { return }
                RAGameIndex.shared.applyProgress(entries: entries.map {
                    (gameID: $0.gameId, unlocked: $0.numUnlocked, total: $0.numAchievements)
                })
            }
        }
    }

    /// Push a @Published mutation onto the main run loop. Always async so it can
    /// never fire "within a view update" (a session starts during the emulator's
    /// makeUIViewController pass) or from a background thread (rc_client server
    /// callbacks). Keeps SwiftUI happy without changing observable behaviour.
    private func publishOnMain(_ apply: @escaping () -> Void) {
        DispatchQueue.main.async(execute: apply)
    }

    private func refreshUser() {
        publishOnMain {
            // Only assign when the value actually changed: a plain @Published
            // fires objectWillChange on every assignment, and a spurious re-render
            // of the Settings section right as the login sheet presents was
            // dismissing it on first open.
            let loggedIn = self.client.isLoggedIn
            let name = self.client.username
            let display = self.client.displayName
            let score = self.client.softcoreScore
            if self.isLoggedIn != loggedIn { self.isLoggedIn = loggedIn }
            if self.username != name { self.username = name }
            if self.displayName != display { self.displayName = display }
            if self.softcoreScore != score { self.softcoreScore = score }
        }
    }

    // MARK: - Game session

    /// Begin an RA session for a freshly loaded ROM. No-op unless enabled + logged
    /// in. Safe to call repeatedly; any prior game is unloaded first.
    private static let log = Logger(subsystem: "com.retropal", category: "RA")

    /// Debug-only [RA] trace: bring-up logging, silent in release builds (the
    /// ROM paths it prints have no place in a shipping Console stream).
    private static func debugLog(_ message: String) {
        #if DEBUG
        log.notice("\(message, privacy: .public)")
        #endif
    }

    func startSession(_ session: EmulatorSession, romPath: String) {
        Self.debugLog("[RA] startSession enabled=\(isEnabled) loggedIn=\(client.isLoggedIn) path=\(romPath)")
        guard isEnabled else { return }
        endSession()
        // Consoles without an RA memory bridge here never load into rc_client:
        // identification could still match an RA set and pollute the index
        // with games that cannot earn anything. (All 4 shipped consoles are
        // bridged — mGBA for GBA/GB/GBC, melonDS main-RAM + DTCM for NDS —
        // so this only guards unknown extensions.)
        guard RAClient.consoleId(forROMPath: romPath) != 0 else { return }
        // Wire the session even before login succeeds: an offline launch
        // (failed silent login) then heals mid-game the moment connectivity
        // returns — doFrame no-ops until a game is actually loaded.
        activeSession = session
        activeSessionROMPath = romPath
        currentROMFilename = (romPath as NSString).lastPathComponent
        client.setMemoryReader { [weak session] address, buffer, length in
            guard let session else { return 0 }
            return session.readMemory(at: address, into: buffer, length: length)
        }
        // Drive rc_client once per emulated frame, on the emulation thread.
        session.onFrameAdvance = { [weak self] in self?.client.doFrame() }
        if client.isLoggedIn {
            client.loadGame(atPath: romPath)
        } else if KeychainStore.get(Self.keychainToken) != nil {
            // Credentials exist but the silent login hasn't landed (offline
            // launch): tracking is paused, say so — never silently.
            noteLiveTrackingPaused()
        }
    }

    /// Publish the "achievements paused" in-game notice — only when this game
    /// is KNOWN to have achievements (an eligible record with a set), so games
    /// without RA never nag. Marks the session for the "resumed" notice once
    /// the automatic retry lands.
    private func noteLiveTrackingPaused() {
        guard let filename = currentROMFilename,
              let romHash = RAGameIndex.shared.romHash(forFilename: filename),
              let record = RAGameIndex.shared.record(forROMHash: romHash),
              record.isEligible, record.total > 0 else { return }
        liveSessionLoadFailed = true
        publishOnMain { self.sessionNotice = RASessionNotice(resumed: false) }
    }

    /// Load a game's set for DISPLAY only (no live memory bridge), so the Game
    /// Details screen and the library profile can show its achievements without
    /// the game running. `completion(success)` fires on the main thread:
    /// immediately with `false` when RA is off / not logged in / offline, when
    /// the load fails, or when the timeout elapses (dead or very slow
    /// connection) — never spins forever. Safe when not actively playing.
    func loadAchievementsForDisplay(romURL: URL, completion: @escaping (Bool) -> Void) {
        guard isEnabled, client.isLoggedIn, isOnline,
              RAClient.consoleId(forROMPath: romURL.path) != 0 else {
            publishOnMain { completion(false) }
            return
        }
        endSession()  // also settles any display load already in flight
        currentROMFilename = romURL.lastPathComponent
        displayLoadCompletion = completion
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.displayLoadCompletion else { return }
            self.displayLoadCompletion = nil
            pending(false)
        }
        displayLoadTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayLoadTimeoutSeconds,
                                      execute: timeout)
        client.loadGame(atPath: romURL.path)
    }

    func endSession() {
        activeSession?.onFrameAdvance = nil
        activeSession = nil
        activeSessionROMPath = nil
        liveSessionLoadFailed = false
        currentROMFilename = nil
        client.setMemoryReader(nil)
        client.unloadGame()
        publishOnMain { self.sessionNotice = nil }
        // A display load still waiting must not outlive the game it was for.
        displayLoadTimeout?.cancel()
        displayLoadTimeout = nil
        if let pending = displayLoadCompletion {
            displayLoadCompletion = nil
            publishOnMain { pending(false) }
        }
        publishOnMain { self.currentGame = nil }
    }

    // MARK: - Save-state progress (wired into save/load in Phase 4)

    func serializeProgress() -> Data? { client.serializeProgress() }
    func deserializeProgress(_ data: Data) { client.deserializeProgress(data) }

    #if DEBUG
    /// Fire a sample unlock so the HUD can be experimented with (look, animation,
    /// Dynamic Island clearance) without earning a real achievement. DEBUG only.
    func debugSimulateUnlock() {
        let samples: [(String, String, Int)] = [
            ("First Steps", "Take your first steps into the world.", 5),
            ("Rival Defeated", "Win your very first battle against your rival.", 10),
            ("Boulder Badge", "Earn your first Gym Badge.", 25),
            ("Seasoned Trainer", "Register 30 species in your Pokédex.", 50),
        ]
        let pick = samples.randomElement() ?? samples[0]
        publishOnMain {
            self.lastUnlock = RAUnlock(title: pick.0, detail: pick.1, badgeURL: nil,
                                       points: pick.2, rarity: 12.5,
                                       gameTitle: "Sample Game", boxArtURL: nil)
            // Preview tool: bypass the in-game sound gate on purpose — the
            // persisted audioMuted key is often true (fast-forward auto-mute
            // persists it), which would make this button silently "broken".
            // REAL unlocks keep the gate.
            RASounds.playUnlock(gameSoundOn: true)
        }
    }

    /// A stepping measured-progress simulation: each tap advances the same
    /// sample achievement by one (5/151 -> 6/151 -> ...), exactly like
    /// catching one more Pokémon, so the pill + sound can be experienced
    /// end to end. DEBUG only.
    private var debugProgressStep = 5
    func debugSimulateProgress() {
        let total = 151
        debugProgressStep = debugProgressStep >= total ? 5 : debugProgressStep + 1
        let step = debugProgressStep
        publishOnMain {
            self.progressIndicator = RAProgressIndicator(
                title: "Pokédex Master", badgeURL: nil,
                progress: "\(step)/\(total)",
                percent: Double(step) / Double(total) * 100)
            // Preview tool: bypasses the in-game sound gate (see simulate-unlock).
            RASounds.playProgress(gameSoundOn: true)
        }
    }
    #endif

    // MARK: - User-Agent (STABLE — load-bearing for the eventual hardcore listing)

    private static func userAgentProductClause() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let os = UIDevice.current.systemVersion
        return "RetroPal/\(version) (iOS \(os); \(deviceModelIdentifier()))"
    }

    private static func deviceModelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let id = mirror.children.reduce(into: "") { acc, element in
            if let value = element.value as? Int8, value != 0 {
                acc.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
        return id.isEmpty ? "iPhone" : id
    }
}

// MARK: - RAClientDelegate

extension RetroAchievements: RAClientDelegate {
    func raClient(_ client: RAClient,
                  didUnlockAchievementTitle title: String,
                  description: String,
                  badgeURL: String?,
                  points: Int,
                  rarity: Double) {
        let unlock = RAUnlock(title: title,
                              detail: description,
                              badgeURL: badgeURL.flatMap(URL.init(string:)),
                              points: points,
                              rarity: rarity,
                              gameTitle: currentGame?.title ?? "",
                              boxArtURL: client.currentGameBoxArtURL().flatMap(URL.init(string:)))
        let logEntry = RAUnlockLogEntry(id: UUID(), date: Date(),
                                        gameID: client.currentGameID(),
                                        gameTitle: currentGame?.title ?? "",
                                        title: title, detail: description,
                                        points: points, rarity: rarity,
                                        badgeURL: badgeURL,
                                        boxArtURL: client.currentGameBoxArtURL())
        let soundOn = isGameSoundOn
        publishOnMain {
            self.lastUnlock = unlock
            RAGameIndex.shared.logUnlock(logEntry)
            RASounds.playUnlock(gameSoundOn: soundOn)
            // Opens the celebration window for the review prompt's ra_unlock
            // arm (the card itself still only shows at the pause overlay).
            PromptTracker.shared.recordAchievementUnlocked()
        }
        // Anonymous adoption signal: no title, no game, no identity — just a count.
        Analytics.signal("ra_unlock")
        // Reflect the new softcore score.
        refreshUser()
    }

    func raClient(_ client: RAClient,
                  didLoadGameTitle gameTitle: String?,
                  unlocked: Int,
                  total: Int,
                  pointsEarned: Int,
                  pointsTotal: Int) {
        let progress = (gameTitle != nil && total > 0)
            ? RAGameProgress(title: gameTitle!, unlocked: unlocked, total: total)
            : nil
        // Enrich the library index from the live load: rc_client identification
        // is a positive eligibility signal, and its title / box art / progress
        // are fresher than any cached server refresh. gameID 0 is ignored (the
        // load callback cannot tell "no set" from a network failure).
        let gameID = client.currentGameID()
        let boxArt = client.currentGameBoxArtURL()
        let filename = currentROMFilename
        publishOnMain {
            self.currentGame = progress
            // Live-session tracking notices (never silent): a failed load for
            // a game KNOWN to have achievements pauses tracking; the
            // successful automatic retry announces the resume.
            if self.activeSession != nil {
                if gameTitle == nil {
                    self.noteLiveTrackingPaused()
                } else if self.liveSessionLoadFailed {
                    self.liveSessionLoadFailed = false
                    self.sessionNotice = RASessionNotice(resumed: true)
                }
            }
            if gameID != 0, let filename,
               let romHash = RAGameIndex.shared.romHash(forFilename: filename) {
                RAGameIndex.shared.applyLoadedGame(
                    romHash: romHash,
                    consoleID: RAClient.consoleId(forROMPath: filename),
                    gameID: gameID,
                    title: gameTitle, boxArtURL: boxArt,
                    unlocked: unlocked, total: total,
                    pointsEarned: pointsEarned, pointsTotal: pointsTotal)
            }
        }
        displayLoadTimeout?.cancel()
        displayLoadTimeout = nil
        if let completion = displayLoadCompletion {
            displayLoadCompletion = nil
            let success = (gameTitle != nil)
            publishOnMain { completion(success) }
        }
    }

    func raClient(_ client: RAClient,
                  didUpdateProgressIndicatorTitle title: String,
                  badgeURL: String?,
                  progress: String,
                  percent: Double) {
        let indicator = RAProgressIndicator(title: title,
                                            badgeURL: badgeURL.flatMap(URL.init(string:)),
                                            progress: progress,
                                            percent: percent)
        let soundOn = isGameSoundOn
        publishOnMain {
            self.progressIndicator = indicator
            RASounds.playProgress(gameSoundOn: soundOn)
        }
    }

    func raClientDidHideProgressIndicator(_ client: RAClient) {
        publishOnMain { self.progressIndicator = nil }
    }

    func raClientDidChangeUser(_ client: RAClient) {
        refreshUser()
    }

    func raClientDidChangeConnectivity(_ client: RAClient) {
        publishOnMain { self.pendingSync = client.hasPendingSync }
    }
}
