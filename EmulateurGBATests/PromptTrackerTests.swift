//
//  PromptTrackerTests.swift
//  EmulateurGBATests
//
//  Covers the ONE-path review ask (1.2.5 restructure):
//
//  - A bare SKStoreReviewController request on the quit path, gated by
//    `directReviewRequestTrigger`. Three triggers, evaluated best-moment
//    first: ra_unlock (an achievement this run + an engaged sitting),
//    return_day (first played on an earlier day + an engaged sitting), and
//    game_30min (30 min on the game just put down, all time).
//  - Deliberately NO terminal states and no lifetime cap: Apple's display
//    quota is the limiter. The only local throttle is the 24h gap.
//  - The warm-up card is gone, and with it every dismissal-counting rule.
//
//  Also covers the session-counting fix: sessions are separated by IDLE
//  time, so banking play on a backgrounding no longer invents a session.
//
//  Each test injects its own isolated UserDefaults(suiteName:) so nothing
//  touches real device state or leaks between tests.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("PromptTracker", .serialized)
struct PromptTrackerTests {

    /// Fresh, empty UserDefaults backed by a unique suite name so every
    /// test starts from a clean slate.
    private func makeTracker() -> (PromptTracker, UserDefaults, String) {
        let suite = "PromptTrackerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PromptTracker(defaults: defaults), defaults, suite)
    }

    private let tenMinutes: TimeInterval = 600
    private let thirtyMinutes: TimeInterval = 1800
    private let game = "Pokemon Emerald (Europe)"

    // MARK: - game_30min, the baseline trigger

    @Test
    func test_game30min_firesAtThirtyMinutesOnThatGame() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: thirtyMinutes) == "game_30min")
    }

    @Test
    func test_game30min_doesNotFireBelowThirtyMinutes() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: thirtyMinutes - 1) == nil)
    }

    /// The bar is CUMULATIVE on the game, so two sittings add up. This is the
    /// difference from the old app-wide hour: it counts the game you stayed
    /// with, not minutes summed across games you abandoned.
    @Test
    func test_game30min_accumulatesAcrossSittings() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordGamePlayTime(romName: game, seconds: 20 * 60)
        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: 9 * 60) == nil)
        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: 10 * 60) == "game_30min")
    }

    /// Time on OTHER games must not qualify this one. A dabbler with five
    /// abandoned games is exactly who the old app-wide bar asked and this one
    /// does not.
    @Test
    func test_game30min_isPerGame_notAppWide() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordGamePlayTime(romName: "Another Game", seconds: 2 * 3600)
        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: 5 * 60) == nil)
    }

    // MARK: - return_day

    @Test
    func test_returnDay_firesOnALaterDayWithAnEngagedSitting() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // First play, two days ago.
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 3600)
        defaults.set(Calendar.current.startOfDay(for: twoDaysAgo), forKey: "pt_firstPlayDay")

        #expect(pt.isReturningDay == true)
        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: tenMinutes) == "return_day")
    }

    /// Coming back for two minutes is not a satisfaction signal.
    @Test
    func test_returnDay_needsAnEngagedSitting() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 3600)
        defaults.set(Calendar.current.startOfDay(for: twoDaysAgo), forKey: "pt_firstPlayDay")

        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: tenMinutes - 1) == nil)
    }

    @Test
    func test_returnDay_doesNotFireOnTheFirstDay() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSessionEnd(playSeconds: tenMinutes)   // stamps today as the first play day
        #expect(pt.isReturningDay == false)
        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: tenMinutes) == nil)
    }

    // MARK: - ra_unlock, and trigger precedence

    @Test
    func test_raUnlock_firesAndOutranksTheOtherTriggers() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Both other triggers would also qualify here.
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 3600)
        defaults.set(Calendar.current.startOfDay(for: twoDaysAgo), forKey: "pt_firstPlayDay")
        pt.recordAchievementUnlocked()

        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: thirtyMinutes) == "ra_unlock")
    }

    @Test
    func test_raUnlock_needsAnEngagedSitting() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordAchievementUnlocked()
        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: tenMinutes - 1) == nil)
    }

    /// One unlock must not keep qualifying every later quit.
    @Test
    func test_raUnlock_isConsumedByTheAsk() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordAchievementUnlocked()
        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: tenMinutes) == "ra_unlock")
        pt.recordDirectReviewRequested()

        // Clear the 24h gap to isolate the flag from the throttle.
        defaults.set(Date().addingTimeInterval(-25 * 3600), forKey: "reviewPromptLastShownDate")
        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: tenMinutes) == nil)
    }

    @Test
    func test_returnDay_outranksGame30min() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 3600)
        defaults.set(Calendar.current.startOfDay(for: twoDaysAgo), forKey: "pt_firstPlayDay")
        pt.recordGamePlayTime(romName: game, seconds: 2 * 3600)

        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: tenMinutes) == "return_day")
    }

    // MARK: - The 24h gap, and the absence of terminal states

    @Test
    func test_gap_suppressesASecondAskWithin24h() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: thirtyMinutes) == "game_30min")
        pt.recordDirectReviewRequested()
        #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: thirtyMinutes) == nil)
    }

    /// The design choice most likely to be "tidied up" by a future reader:
    /// there is NO lifetime cap and NO terminal state. Apple's display quota
    /// is the limiter, a suppressed request costs nothing, and this is the
    /// shape the most-rated emulator on the store uses. Locked by a test.
    @Test
    func test_noLifetimeCap_theAskKeepsQualifyingForever() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        for _ in 0..<20 {
            #expect(pt.directReviewRequestTrigger(romName: game, currentSessionSeconds: thirtyMinutes) == "game_30min")
            pt.recordDirectReviewRequested()
            defaults.set(Date().addingTimeInterval(-25 * 3600), forKey: "reviewPromptLastShownDate")
        }
    }

    // MARK: - Session counting: idle time, not banking events

    /// The 1.2.5 fix. Banking play on a backgrounding, then resuming a minute
    /// later, is ONE session. Before the fix this counted two, which inflated
    /// a user-visible stat and silently disabled both first-session triggers.
    @Test
    func test_sessionCount_backgroundingMidSittingIsOneSession() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSessionEnd(playSeconds: 10 * 60)   // first banking: session 1
        #expect(pt.sessionCount == 1)

        // A notification pulled down: banked again almost immediately.
        pt.recordSessionEnd(playSeconds: 30)
        #expect(pt.sessionCount == 1)
    }

    @Test
    func test_sessionCount_countsASessionAfterAnIdleGap() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSessionEnd(playSeconds: 10 * 60)
        #expect(pt.sessionCount == 1)

        // Pretend the last banking was 40 minutes ago and nothing was played
        // since: that is a real gap, so the next banking opens session 2.
        defaults.set(Date().addingTimeInterval(-40 * 60), forKey: "pt_lastPlayBankDate")
        pt.recordSessionEnd(playSeconds: 5 * 60)
        #expect(pt.sessionCount == 2)
    }

    /// Long CONTINUOUS play must not be split into sessions just because the
    /// wall-clock gap between bankings exceeds the idle threshold — the gap
    /// has to discount the time that was spent playing.
    @Test
    func test_sessionCount_longContinuousPlayIsOneSession() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSessionEnd(playSeconds: 10 * 60)
        #expect(pt.sessionCount == 1)

        // Banked 90 minutes later, but 90 minutes of it was play.
        defaults.set(Date().addingTimeInterval(-90 * 60), forKey: "pt_lastPlayBankDate")
        pt.recordSessionEnd(playSeconds: 90 * 60)
        #expect(pt.sessionCount == 1)
    }

    @Test
    func test_firstPlayDay_isStampedOnceAndDrivesIsReturningDay() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSessionEnd(playSeconds: 60)
        let stamped = defaults.object(forKey: "pt_firstPlayDay") as? Date
        #expect(stamped != nil)
        #expect(pt.isReturningDay == false)

        pt.recordSessionEnd(playSeconds: 60)
        #expect((defaults.object(forKey: "pt_firstPlayDay") as? Date) == stamped)
    }

    // MARK: - Save-state signal (retained, no longer a review gate)

    @Test
    func test_recordSaveStateCreated_idempotent() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(pt.hasCreatedSaveState == false)
        pt.recordSaveStateCreated()
        pt.recordSaveStateCreated() // second call must be a harmless no-op
        #expect(pt.hasCreatedSaveState == true)
    }
}
