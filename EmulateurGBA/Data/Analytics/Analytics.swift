//
//  Analytics.swift
//  EmulateurGBA
//
//  Single chokepoint for all analytics. Enforces the anonymity allowlist in
//  ONE place. Never call TelemetryDeck directly anywhere else.
//

import Foundation
import TelemetryDeck

enum Analytics {
    private static let appID = "BF941250-2F6C-4AD6-9CD4-7914BAAE4558"
    private static var started = false

    /// Call once at launch.
    static func start() {
        initializeIfNeeded()
        signal("appLaunched")                     // DAU / retention baseline
        // The previous process died while the app was on screen (a crash, a
        // memory kill, the watchdog): what it was doing, once. Read before the
        // new session arms its own marker (`SessionLiveness`).
        if let previous = SessionLiveness.shared.consumePreviousRecord() {
            signal("unexpected_exit", previous.parameters)
        }
        SessionLiveness.shared.startObserving()
        ExitMetricsReporter.shared.start()        // iOS's daily exit counts
    }

    private static func initializeIfNeeded() {
        guard !started else { return }
        TelemetryDeck.initialize(config: TelemetryDeck.Config(appID: appID))
        started = true
    }

    /// The ONLY way to send a signal. Anonymity allowlist enforced here.
    static func signal(_ name: String, _ params: [String: String] = [:]) {
        initializeIfNeeded()
        TelemetryDeck.signal(name, parameters: sanitized(withGameSystem(name, params)))
    }

    /// The signals that also carry the console of the game on screen (asked
    /// 2026-10-10: conversion per console). Added here, at the one chokepoint,
    /// so no call site can forget it; a call that names its console itself
    /// (a preset edited for a chosen console in Settings) keeps its own.
    /// Outside a game nothing is added: the sheet was not met on a console.
    /// Adding a parameter forks no series (the signal set stays as it is).
    static let signalsWithGameSystem: Set<String> = ["pro_sheet_shown", "pro_feature_used", "pro_purchased"]

    static func withGameSystem(_ name: String, _ params: [String: String],
                               current: String? = SessionLiveness.shared.currentGameSystem) -> [String: String] {
        guard signalsWithGameSystem.contains(name), params["system"] == nil, let current else { return params }
        var out = params
        out["system"] = current
        return out
    }

    /// Send at most ONCE per app launch for a given name and parameter set.
    ///
    /// Why this exists (2026-08-27, at 100k+ monthly events). Six signals
    /// answer exactly one question: "does this user use the feature". That
    /// needs one event per user, not one per action, and `rewind_used` alone
    /// fired dozens of times in a session. Deduplicating keeps every insight
    /// the dashboards are built on and removes the volume that bought nothing.
    ///
    /// The key is built from the SANITIZED parameters, so a value the
    /// anonymity gate drops cannot make two identical signals look distinct
    /// and defeat the whole thing.
    ///
    /// Locked because signals are sent from background threads (box art,
    /// imports), and a Set mutated from two of them is a data race.
    static func signalOnce(_ name: String, _ params: [String: String] = [:]) {
        let clean = sanitized(params)
        let key = ([name] + clean.keys.sorted().map { "\($0)=\(clean[$0]!)" })
            .joined(separator: "|")
        dedupeLock.lock()
        let isNew = sentThisLaunch.insert(key).inserted
        dedupeLock.unlock()
        guard isNew else { return }
        signal(name, params)
    }

    private static let dedupeLock = NSLock()
    private static var sentThisLaunch: Set<String> = []

    /// Anonymity gate: a hard allowlist. Anything not listed is dropped, so a
    /// game title / filename / free text can never leak even if passed by mistake.
    /// When new events are added, add their param keys here on purpose.
    ///
    /// The error keys (2026-10-10) are gated on their VALUE too: `reason`,
    /// `phase` and `count` pass only with a word from their closed sets
    /// (`ErrorTelemetry`), so not even an error message can travel through
    /// them. Internal, not private, so the tests can hold it to that.
    static func sanitized(_ params: [String: String]) -> [String: String] {
        var clean = params.filter { allowedKeys.contains($0.key) }
        for (key, values) in closedValueKeys {
            if let value = clean[key], !values.contains(value) { clean[key] = nil }
        }
        return clean
    }

    private static let allowedKeys: Set<String> = [
        "result", "errorType", "system", "method",   // rom_import
        "kind",                                       // save_failure / permission_denied
        "trigger", "productType",                     // pro funnel
        "cardType", "completed", "skinVariant",       // share
        "variant", "action", "speed", "enabled",      // second-wave adoption/quality
        "feature",                                     // pro_feature_used ranking
        "minutes",                                     // play_session depth bucket
        "reason", "phase", "count"                     // error categories (closed values below)
    ]

    /// Keys whose VALUE must also come from a closed set.
    private static let closedValueKeys: [String: Set<String>] = [
        "reason": ErrorTelemetry.allReasonValues,
        "phase": ErrorTelemetry.allPhaseValues,
        "count": ErrorTelemetry.allCountValues
    ]
}
