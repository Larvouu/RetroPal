//
//  SessionLiveness.swift
//  EmulateurGBA
//
//  "The previous session ended unexpectedly", detected without a crash
//  reporter (2026-10-10).
//
//  HOW IT WORKS. While the app is on screen, a small marker in UserDefaults
//  says what it is doing: a phase from a closed set (`TelemetryPhase`) and,
//  when a game is open, its console. Every way an app is left on purpose
//  passes through "inactive" first (the Home gesture, opening the app
//  switcher, a lock, a call), and resigning active CLEARS the marker; so does
//  entering the background and terminating. Cleared on RESIGN, not only on
//  background, because a swipe-away in the app switcher kills an app that is
//  inactive and was never backgrounded, and that is the player's choice, not
//  a fault. So a marker still there at the next launch means the process
//  died while active: a crash, a memory kill, the watchdog. The launch then
//  sends `unexpected_exit {phase, system}` once and clears it.
//
//  What it cannot see, stated rather than hidden: a death while NOT active
//  (the background auto-save, a suspended app, a system alert on top) leaves
//  no marker, by design, since iOS ends suspended apps all the time and that
//  is not a fault. iOS's own daily exit counts cover that side
//  (`ExitMetricsReporter`). A phone that loses power with the app open (an
//  empty battery, a forced restart) is NOT reported: the marker carries the
//  phone's start-up time and a restart since is read as a power event
//  (2026-10-10). A debug session stopped from Xcode still reads as an
//  unexpected end (debug builds only, which send Test signals).
//
//  Nothing in the marker identifies a game: a phase word and a console word,
//  both from closed sets, re-validated when read back.
//

import Foundation
import UIKit

final class SessionLiveness {

    static let shared = SessionLiveness(defaults: .standard)

    /// What the marker holds.
    struct Record: Equatable {
        let phase: TelemetryPhase
        let system: String?

        /// Signal parameters. The console only when it is one the app has.
        var parameters: [String: String] {
            var p = ["phase": phase.rawValue]
            if let system { p["system"] = system }
            return p
        }
    }

    static let markerKey = "telemetry.liveSession"

    private let defaults: UserDefaults
    private let lock = NSLock()

    // Live state. Guarded by `lock`: imports and saves report from background
    // queues. `foreground` = launching, returning to the foreground, or
    // active; false from the moment the app resigns active.
    private var foreground = false
    private var hasBecomeActive = false
    private var gameSystem: String?
    private var activity: TelemetryPhase?
    /// Which game `gameSystem` belongs to: a quit's save and shutdown finish
    /// on a queue, possibly after the next game has started, and must not end
    /// that one.
    private var generation = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Launch

    /// Read and clear what the previous process left. Non-nil means it ended
    /// while active, without resigning active first.
    func consumePreviousRecord() -> Record? {
        lock.lock(); defer { lock.unlock() }
        let stored = defaults.dictionary(forKey: Self.markerKey) as? [String: String]
        defaults.removeObject(forKey: Self.markerKey)
        // The phone lost power, not the app: nothing to report.
        if let stored, Self.phoneRestarted(since: stored) { return nil }
        return stored.flatMap(Self.decode)
    }

    /// Start following the app's foreground state. Called once, at launch.
    ///
    /// Armed only by the app coming to the foreground or becoming active,
    /// never at process start: iOS may PREWARM the process (run it up to its
    /// initialisation without showing it) and then discard it, and a scene
    /// app's state during `didFinishLaunching` does not say whether it will be
    /// shown. The cost is that a crash before the first scene comes on screen
    /// is not seen.
    func startObserving() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let events: [(Notification.Name, (SessionLiveness) -> Void)] = [
            (UIApplication.willEnterForegroundNotification, { $0.appWillEnterForeground() }),
            (UIApplication.didBecomeActiveNotification, { $0.appDidBecomeActive() }),
            (UIApplication.willResignActiveNotification, { $0.appDidEnterBackground() }),
            (UIApplication.didEnterBackgroundNotification, { $0.appDidEnterBackground() }),
            (UIApplication.willTerminateNotification, { $0.appDidEnterBackground() }),
        ]
        for (name, handle) in events {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let self { handle(self) }
            })
        }
    }

    private var observers: [NSObjectProtocol] = []

    // MARK: - App state (internal for the tests)

    func appDidBecomeActive() {
        update { $0.foreground = true; $0.hasBecomeActive = true }
    }

    func appWillEnterForeground() {
        update { $0.foreground = true }
    }

    /// Resigning active, entering the background, or terminating: the app
    /// is being left on purpose, so nothing is armed.
    func appDidEnterBackground() {
        update { $0.foreground = false }
    }

    // MARK: - What the app is doing

    /// A game's core is about to load it. `system` is the console's raw value.
    /// Returns the token `gameEnded(generation:)` takes.
    @discardableResult
    func gameWillStart(system: String?) -> Int {
        var token = 0
        update {
            self.generation += 1
            token = self.generation
            $0.gameSystem = system ?? "unknown"
            $0.activity = .startingGame
        }
        return token
    }

    /// The console of the game on screen, nil outside a game. Read by the Pro
    /// signals (`Analytics.signal`), so the console a Pro sheet or feature was
    /// met on is known without every call site having to pass it.
    var currentGameSystem: String? {
        lock.lock(); defer { lock.unlock() }
        return gameSystem
    }

    /// An operation with its own phase begins (saving, loading, quitting,
    /// importing).
    func begin(_ phase: TelemetryPhase) {
        update { $0.activity = phase }
    }

    /// The operation ends. Only clears its own phase, so an end that arrives
    /// after another operation began does not erase that one.
    func end(_ phase: TelemetryPhase) {
        update { if $0.activity == phase { $0.activity = nil } }
    }

    /// The game is over: quit completed, or it never started. Ignored when
    /// another game has started since `generation` was handed out.
    func gameEnded(generation token: Int) {
        update {
            guard self.generation == token else { return }
            $0.gameSystem = nil
            $0.activity = nil
        }
    }

    /// The game screen is gone (the library's cover dismissed). A quit in
    /// progress keeps its phase until its own save and shutdown finish
    /// (`gameEnded`); any other way out (a game replaced by one opened from
    /// Files or a widget) ends the game here.
    func gameScreenDidClose() {
        update {
            if $0.activity != .quittingGame { $0.gameSystem = nil; $0.activity = nil }
        }
    }

    // MARK: - The marker

    /// What the marker says right now; nil when nothing is armed.
    var currentRecord: Record? {
        lock.lock(); defer { lock.unlock() }
        return record()
    }

    private func record() -> Record? {
        guard foreground else { return nil }
        let phase: TelemetryPhase
        if let activity {
            phase = activity
        } else if gameSystem != nil {
            phase = .playing
        } else {
            phase = hasBecomeActive ? .browsing : .appLaunch
        }
        return Record(phase: phase, system: gameSystem)
    }

    private struct State {
        var foreground: Bool
        var hasBecomeActive: Bool
        var gameSystem: String?
        var activity: TelemetryPhase?
    }

    /// The one way the state changes: under the lock (which `change` runs
    /// inside, so it may read `generation`), and the marker rewritten only
    /// when what it says changed.
    private func update(_ change: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var state = State(foreground: foreground, hasBecomeActive: hasBecomeActive,
                          gameSystem: gameSystem, activity: activity)
        let before = record()
        change(&state)
        foreground = state.foreground
        hasBecomeActive = state.hasBecomeActive
        gameSystem = state.gameSystem
        activity = state.activity
        let after = record()
        guard after != before else { return }
        if let after {
            defaults.set(Self.encode(after), forKey: Self.markerKey)
        } else {
            defaults.removeObject(forKey: Self.markerKey)
        }
    }

    // MARK: - Encoding

    static func encode(_ record: Record, bootTime: TimeInterval = SessionLiveness.bootTime()) -> [String: String] {
        var d = ["phase": record.phase.rawValue]
        if let system = record.system { d["system"] = system }
        d["boot"] = String(Int(bootTime))
        return d
    }

    /// When the phone last started up, in seconds since 1970, to the second:
    /// now minus the time it has been up. A phone that loses power with the
    /// app on screen (an empty battery, a forced restart) leaves the marker
    /// armed exactly as a crash does; it also comes back with a new start-up
    /// time, and that is how the two are told apart (asked 2026-10-10: a phone
    /// switched off mid-game is not an app fault). A gap of a few seconds
    /// between two readings of the same start-up is rounding, not a restart.
    ///
    /// The clock must count the time the phone SLEEPS. `systemUptime` does not
    /// (it is the awake time), so a phone locked between a crash and the next
    /// launch read as a new start-up and the crash was never reported (audit
    /// 2026-10-12). `CLOCK_MONOTONIC_RAW` on Darwin keeps counting through sleep
    /// (the `mach_continuous_time` clock; the man page says so).
    static func bootTime() -> TimeInterval {
        let sinceStartUp = TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        return Date().timeIntervalSince1970 - sinceStartUp
    }
    static let bootTolerance: TimeInterval = 10

    /// Whether the phone restarted between the marker being written and now.
    static func phoneRestarted(since d: [String: String], now: TimeInterval = SessionLiveness.bootTime()) -> Bool {
        guard let raw = d["boot"], let then = TimeInterval(raw) else { return false }
        return abs(now - then) > bootTolerance
    }

    /// Re-validated on the way back: a phase outside the closed set is no
    /// record, and a console that is not one of the app's is "unknown".
    static func decode(_ d: [String: String]) -> Record? {
        guard let raw = d["phase"], let phase = TelemetryPhase(rawValue: raw) else { return nil }
        let system = d["system"].map { ROMSystemType(rawValue: $0) != nil ? $0 : "unknown" }
        return Record(phase: phase, system: system)
    }
}
