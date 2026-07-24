//
//  PromptTrackerTests.swift
//  EmulateurGBATests
//
//  Covers the two-path review ask (1.2.3 restructure):
//
//  - CARD path (`reviewPromptArm`): the visible warm-up card, ra_unlock
//    only (a fresh RetroAchievements unlock opens a 30-min celebration
//    window, gated by >=15 min cumulative play). Rating terminal, two
//    dismissals terminal, 24h gap.
//
//  - DIRECT path (`directReviewRequestTrigger`): bare SKStoreReviewController
//    requests on the quit path (loyal_returner / deep_first_timer /
//    engaged_first_timer). Deliberately NO terminal states — Apple's display
//    quota is the limiter; the only local throttle is the 24h gap SHARED
//    with the card.
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
    /// test starts from a clean slate (sessionCount 0, no prompts shown,
    /// no save state recorded).
    private func makeTracker() -> (PromptTracker, UserDefaults, String) {
        let suite = "PromptTrackerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PromptTracker(defaults: defaults), defaults, suite)
    }

    private let fifteenMinutes: TimeInterval = 900
    private let oneHour: TimeInterval = 3600

    // MARK: - Direct path: engaged_first_timer

    @Test
    func test_engagedFirstTimer_firesWhenAllConditionsMet() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSaveStateCreated()
        // First session (sessionCount == 0), exactly 15 min, save state made.
        #expect(pt.directReviewRequestTrigger(currentSessionSeconds: fifteenMinutes) == "engaged_first_timer")
    }

    @Test
    func test_engagedFirstTimer_doesNotFireWithoutSaveState() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // 15 min in session 1 but no manual save state: the engaged arm is
        // gated off, and 15 min is far below the 2h deep-first-timer bar.
        #expect(pt.directReviewRequestTrigger(currentSessionSeconds: fifteenMinutes) == nil)
    }

    @Test
    func test_engagedFirstTimer_doesNotFireBelow15min() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSaveStateCreated()
        // One second short of the threshold.
        #expect(pt.directReviewRequestTrigger(currentSessionSeconds: fifteenMinutes - 1) == nil)
    }

    @Test
    func test_engagedFirstTimer_doesNotFireAfterFirstSession() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSaveStateCreated()
        // End the first session: sessionCount becomes 1, so the
        // first-session-only triggers (engaged + deep) no longer apply, and
        // loyal_returner needs 3rd session + 1h cumulative.
        pt.recordSessionEnd(playSeconds: fifteenMinutes)
        #expect(pt.directReviewRequestTrigger(currentSessionSeconds: fifteenMinutes) == nil)
    }

    // MARK: - Direct path: loyal_returner

    @Test
    func test_loyalReturner_firesOnThirdSessionWithOneHourBanked() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Two completed sessions -> this is the 3rd. 1h cumulative reached
        // counting the live session's minutes.
        pt.recordSessionEnd(playSeconds: 1800)
        pt.recordSessionEnd(playSeconds: 1500)
        #expect(pt.directReviewRequestTrigger(currentSessionSeconds: 300) == "loyal_returner")
    }

    @Test
    func test_loyalReturner_needsThirdSession() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // 1h+ banked but only one completed session: not yet a returner.
        pt.recordSessionEnd(playSeconds: oneHour)
        #expect(pt.directReviewRequestTrigger(currentSessionSeconds: fifteenMinutes) == nil)
    }

    // MARK: - Direct path: no terminal states (the 1.2.3 philosophy)

    @Test
    func test_directPath_keepsFiringAfterRated() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // The card's rated flag is terminal for the CARD only. The direct
        // request stays armed: it is silent once Apple's quota is spent, so
        // there is nothing to protect the user from.
        pt.recordReviewPromptRated()
        pt.recordSessionEnd(playSeconds: 1800)
        pt.recordSessionEnd(playSeconds: 1800)
        #expect(pt.directReviewRequestTrigger(currentSessionSeconds: 300) == "loyal_returner")
    }

    @Test
    func test_directPath_respectsSharedDailyGap() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSessionEnd(playSeconds: 1800)
        pt.recordSessionEnd(playSeconds: 1800)
        // A direct request just fired: the 24h gap suppresses the next one.
        pt.recordDirectReviewRequested()
        #expect(pt.directReviewRequestTrigger(currentSessionSeconds: 300) == nil)
    }

    @Test
    func test_cardPresentation_blocksDirectPathForADay() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSessionEnd(playSeconds: 1800)
        pt.recordSessionEnd(playSeconds: 1800)
        // The ra_unlock CARD was shown today: the shared gap must silence
        // the direct ask too — never two review asks in one day.
        pt.recordReviewPromptPresented()
        #expect(pt.directReviewRequestTrigger(currentSessionSeconds: 300) == nil)
    }

    // MARK: - Save state gate

    @Test
    func test_recordSaveStateCreated_idempotent() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSaveStateCreated()
        pt.recordSaveStateCreated() // second call must be a harmless no-op

        #expect(pt.hasCreatedSaveState == true)
        #expect(pt.directReviewRequestTrigger(currentSessionSeconds: fifteenMinutes) == "engaged_first_timer")
    }

    // MARK: - Card path: ra_unlock only

    @Test
    func test_raUnlock_firesAt15minWithFreshUnlock() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // A fresh RA unlock + 15 min cumulative: the celebration card fires.
        pt.recordAchievementUnlocked()
        #expect(pt.reviewPromptArm(currentSessionSeconds: fifteenMinutes) == "ra_unlock")
    }

    @Test
    func test_raUnlock_doesNotFireBelow15min() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // The time bar keeps a 2-minute drive-by unlock from prompting.
        pt.recordAchievementUnlocked()
        #expect(pt.reviewPromptArm(currentSessionSeconds: fifteenMinutes - 1) == nil)
    }

    @Test
    func test_card_isRaUnlockOnly() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Conditions that used to fire the card's engaged_first_timer arm
        // (15 min + save state, no unlock) must now leave the card silent:
        // those users are served by the direct quit-path request instead.
        pt.recordSaveStateCreated()
        #expect(pt.reviewPromptArm(currentSessionSeconds: fifteenMinutes) == nil)
    }

    @Test
    func test_raUnlock_worksBeyondTheFirstSession() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // ra_unlock counts CUMULATIVE play: a returning user (session 2,
        // 10 min banked + 5 min live) qualifies.
        pt.recordSessionEnd(playSeconds: 600)
        pt.recordAchievementUnlocked()
        #expect(pt.reviewPromptArm(currentSessionSeconds: 300) == "ra_unlock")
    }

    @Test
    func test_card_ratedIsTerminal() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordReviewPromptRated()
        pt.recordAchievementUnlocked()
        #expect(pt.reviewPromptArm(currentSessionSeconds: fifteenMinutes) == nil)
    }

    @Test
    func test_card_twoDismissalsAreTerminal() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Two presentations without a Rate tap = two pessimistic dismissals.
        // Backdate the shared ask stamp past the 24h gap so the only thing
        // left blocking the card is the dismissal count — the terminal rule
        // this test pins.
        pt.recordReviewPromptPresented()
        pt.recordReviewPromptPresented()
        defaults.set(Date(timeIntervalSinceNow: -172_800), forKey: "reviewPromptLastShownDate")
        pt.recordAchievementUnlocked()
        #expect(pt.reviewPromptArm(currentSessionSeconds: fifteenMinutes) == nil)
    }
}
