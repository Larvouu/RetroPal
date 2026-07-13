//
//  PromptTrackerTests.swift
//  EmulateurGBATests
//
//  Covers the Week-5 engagedFirstTimer review-prompt arm and its
//  recordSaveStateCreated() gate, plus the 1.2.2 ra_unlock arm (a fresh
//  RetroAchievements unlock opens a 30-min celebration window). Each test
//  injects its own isolated UserDefaults(suiteName:) so nothing touches
//  real device state or leaks between tests.
//
//  The new arm: prompt #1 fires for a user still in their first session
//  (sessionCount == 0) who has played >= 15 min AND created at least one
//  manual save state. The save-state gate is what makes the 15-min bar
//  safe — it filters drive-by users from genuinely engaged newcomers.
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

    @Test
    func test_engagedFirstTimer_firesWhenAllConditionsMet() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSaveStateCreated()
        // First session (sessionCount == 0), exactly 15 min, save state made.
        #expect(pt.shouldShowReviewPrompt(currentSessionSeconds: fifteenMinutes) == true)
    }

    @Test
    func test_engagedFirstTimer_doesNotFireWithoutSaveState() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // 15 min in session 1 but no manual save state: the engaged arm is
        // gated off, and 15 min is far below the 2h deep-first-timer bar.
        #expect(pt.shouldShowReviewPrompt(currentSessionSeconds: fifteenMinutes) == false)
    }

    @Test
    func test_engagedFirstTimer_doesNotFireBelow15min() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSaveStateCreated()
        // One second short of the threshold.
        #expect(pt.shouldShowReviewPrompt(currentSessionSeconds: fifteenMinutes - 1) == false)
    }

    @Test
    func test_engagedFirstTimer_doesNotFireAfterFirstSession() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSaveStateCreated()
        // End the first session: sessionCount becomes 1, so the
        // first-session-only arms (engaged + deep) no longer apply, and the
        // loyal-returner arm needs 3rd session + 1h cumulative.
        pt.recordSessionEnd(playSeconds: fifteenMinutes)
        #expect(pt.shouldShowReviewPrompt(currentSessionSeconds: fifteenMinutes) == false)
    }

    @Test
    func test_engagedFirstTimer_doesNotRefireAfterShown() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSaveStateCreated()
        #expect(pt.shouldShowReviewPrompt(currentSessionSeconds: fifteenMinutes) == true)

        // Presenting the card bumps the dismissed count + stamps the date,
        // so the same conditions must not fire it again.
        pt.recordReviewPromptPresented()
        #expect(pt.shouldShowReviewPrompt(currentSessionSeconds: fifteenMinutes) == false)
    }

    @Test
    func test_reviewPrompt_respectsCooldownGap() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // A prompt was just shown, and the user has since crossed the 3h
        // cumulative bar that would otherwise qualify for prompt #2. The
        // 24h minimum gap must still suppress it.
        pt.recordReviewPromptPresented()
        pt.recordSessionEnd(playSeconds: 10800) // 3h cumulative
        #expect(pt.shouldShowReviewPrompt(currentSessionSeconds: 0) == false)
    }

    @Test
    func test_recordSaveStateCreated_idempotent() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        pt.recordSaveStateCreated()
        pt.recordSaveStateCreated() // second call must be a harmless no-op

        #expect(pt.hasCreatedSaveState == true)
        #expect(pt.shouldShowReviewPrompt(currentSessionSeconds: fifteenMinutes) == true)
    }

    // MARK: - ra_unlock arm (1.2.2)

    @Test
    func test_raUnlock_firesAt15minWithFreshUnlock() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // A fresh RA unlock + 15 min cumulative, NO save state: the engaged
        // arm is gated off, so only the ra_unlock arm can explain a fire.
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
    func test_raUnlock_takesAttributionPriorityOverOtherArms() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Conditions satisfy BOTH engaged_first_timer and ra_unlock; the
        // unlock is the moment that actually put the user in a rating mood,
        // so it must win the trigger attribution.
        pt.recordSaveStateCreated()
        pt.recordAchievementUnlocked()
        #expect(pt.reviewPromptArm(currentSessionSeconds: fifteenMinutes) == "ra_unlock")
    }

    @Test
    func test_raUnlock_worksBeyondTheFirstSession() {
        let (pt, defaults, suite) = makeTracker()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Unlike the two first-session arms, ra_unlock counts CUMULATIVE play:
        // a returning user (session 2, 10 min banked + 5 min live) qualifies.
        pt.recordSessionEnd(playSeconds: 600)
        pt.recordAchievementUnlocked()
        #expect(pt.reviewPromptArm(currentSessionSeconds: 300) == "ra_unlock")
    }
}
