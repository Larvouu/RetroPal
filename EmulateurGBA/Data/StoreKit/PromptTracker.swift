//
//  PromptTracker.swift
//  EmulateurGBA
//
//  Tracks user engagement metrics and determines when to show
//  contextual Pro upgrade prompts. Respects anti-annoyance rules:
//  7-day cooldown, max 3 lifetime active prompts, never mid-game.
//

import Foundation

/// What triggered the Pro prompt. Determines the sheet's headline and featured benefit.
enum ProPromptContext: Equatable {
    case speedMoment(minutesAtFreeSpeed: Int) // earned: 30min+ at 1.5x, copy uses the stat
    case speedTapped                           // user tapped a locked speed without earning it — envy copy, no stat
    case saveSlotFull                          // earned: all free slots actually full
    case saveSlotTapped                        // user tapped a locked slot with free slots still empty — envy copy
    case sessionMilestone(totalMinutes: Int)
    case rewindLimit
    case cheatCodes(gameName: String)     // 4h trigger — shows "You reached 4h..."
    case cheatCodesTapped                  // user tapped locked button — no time mention
    case tappedLockedFeature
    case customizeControls                 // user tapped customize controls (Pro feature)
    case customSkins                       // user tapped Create skin / Edit, or imported one (creation is Pro)

    /// Stable, anonymous identifier for analytics (drops associated values, esp. gameName).
    var analyticsID: String {
        switch self {
        case .speedMoment: return "speedMoment"
        case .speedTapped: return "speedTapped"
        case .saveSlotFull: return "saveSlotFull"
        case .saveSlotTapped: return "saveSlotTapped"
        case .sessionMilestone: return "sessionMilestone"
        case .rewindLimit: return "rewindLimit"
        case .cheatCodes: return "cheatCodes"
        case .cheatCodesTapped: return "cheatCodesTapped"
        case .tappedLockedFeature: return "tappedLockedFeature"
        case .customizeControls: return "customizeControls"
        case .customSkins: return "customSkins"
        }
    }
}

final class PromptTracker {
    static let shared = PromptTracker()

    private let defaults: UserDefaults

    // Keys
    private let kTotalPlaySeconds = "pt_totalPlaySeconds"
    private let kSessionCount = "pt_sessionCount"
    private let kLastPromptDate = "pt_lastPromptDate"
    private let kLifetimePromptsShown = "pt_lifetimePromptsShown"
    private let kSpeedMomentShown = "pt_speedMomentShown"
    private let kSessionMilestoneShown = "pt_sessionMilestoneShown"

    /// `.shared` is the app-wide instance and uses `UserDefaults.standard`.
    /// The `defaults` parameter exists so unit tests can inject an isolated
    /// `UserDefaults(suiteName:)` and not touch real device state.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Tracking

    /// Call when a game session ends (quit to library or app background).
    func recordSessionEnd(playSeconds: TimeInterval) {
        let total = defaults.double(forKey: kTotalPlaySeconds) + playSeconds
        defaults.set(total, forKey: kTotalPlaySeconds)

        let sessions = defaults.integer(forKey: kSessionCount) + 1
        defaults.set(sessions, forKey: kSessionCount)
    }

    var totalPlaySeconds: TimeInterval {
        defaults.double(forKey: kTotalPlaySeconds)
    }

    var sessionCount: Int {
        defaults.integer(forKey: kSessionCount)
    }

    // MARK: - Anti-Annoyance

    /// Whether we can show any active prompt (respects cooldown + lifetime cap).
    var canShowActivePrompt: Bool {
        let lifetime = defaults.integer(forKey: kLifetimePromptsShown)
        guard lifetime < 3 else { return false }

        if let lastDate = defaults.object(forKey: kLastPromptDate) as? Date {
            let daysSince = Calendar.current.dateComponents([.day], from: lastDate, to: Date()).day ?? 0
            return daysSince >= 7
        }
        return true
    }

    /// Record that an active prompt was shown.
    func recordPromptShown() {
        defaults.set(Date(), forKey: kLastPromptDate)
        let count = defaults.integer(forKey: kLifetimePromptsShown) + 1
        defaults.set(count, forKey: kLifetimePromptsShown)
    }

    // MARK: - Trigger Checks

    /// Check if speed moment trigger should fire (30+ min at free speed).
    func shouldShowSpeedMoment(sessionPlaySeconds: TimeInterval) -> Bool {
        guard !defaults.bool(forKey: kSpeedMomentShown) else { return false }
        guard canShowActivePrompt else { return false }
        return sessionPlaySeconds >= 1800 // 30 minutes
    }

    func markSpeedMomentShown() {
        defaults.set(true, forKey: kSpeedMomentShown)
    }

    /// Check if session milestone trigger should fire (1+ hour total across all games).
    func shouldShowSessionMilestone() -> Bool {
        guard !defaults.bool(forKey: kSessionMilestoneShown) else { return false }
        guard canShowActivePrompt else { return false }
        return totalPlaySeconds >= 3600 // 1 hour
    }

    func markSessionMilestoneShown() {
        defaults.set(true, forKey: kSessionMilestoneShown)
    }

    /// Save slot full trigger fires when all free slots are used.
    /// No once-per-lifetime restriction (can show again after cooldown).
    func shouldShowSaveSlotFull() -> Bool {
        canShowActivePrompt
    }

    /// Rewind limit trigger fires after the free user has hit the 5s wall
    /// several times — not on the first tap, which feels too aggressive.
    /// No once-per-lifetime restriction beyond the global cooldown.
    private let kMaxRewindCount = "pt_maxRewindCount"
    private let maxRewindThreshold = 5

    /// Record a successful max-length rewind by a free user (5s wall hit).
    func recordMaxRewind() {
        let count = defaults.integer(forKey: kMaxRewindCount) + 1
        defaults.set(count, forKey: kMaxRewindCount)
    }

    var maxRewindCount: Int {
        defaults.integer(forKey: kMaxRewindCount)
    }

    func shouldShowRewindLimit() -> Bool {
        guard canShowActivePrompt else { return false }
        return maxRewindCount >= maxRewindThreshold
    }

    // MARK: - App Store Review Prompt

    /// Legacy gate: users who saw the old one-shot warm-up card have this
    /// flag set. We treat it as terminal (no more prompts) so the new
    /// two-shot flow below never re-prompts them.
    private let kReviewPromptShown = "reviewPromptShown"

    private let kReviewPromptRated = "reviewPromptRated"
    private let kReviewPromptDismissedCount = "reviewPromptDismissedCount"
    private let kReviewPromptLastShownDate = "reviewPromptLastShownDate"
    private let kSaveStateCreated = "pt_saveStateCreated"

    private let reviewPromptSecondsPrompt1: TimeInterval = 3600         // 1 hour cumulative (loyal-returner arm)
    private let reviewPromptSecondsFirstSessionDeep: TimeInterval = 7200 // 2 hours in session 1 (deep-first-timer arm)
    private let reviewPromptSecondsEngagedFirstTimer: TimeInterval = 900 // 15 min in session 1 + a manual save state
    private let reviewPromptSecondsPrompt2: TimeInterval = 10800         // 3 hours cumulative
    private let reviewPromptMinGapSeconds: TimeInterval = 24 * 3600
    private let reviewPromptMinSessionsForFirst = 2                       // >= 3rd session
    private let reviewPromptSecondsRAUnlock: TimeInterval = 900           // 15 min cumulative + a fresh RA unlock
    private let reviewPromptRAUnlockWindow: TimeInterval = 30 * 60        // "fresh" = within the last 30 min

    /// In-memory only, deliberately not persisted: a RetroAchievements unlock
    /// opens a short celebration window for the review ask. An app relaunch
    /// resets it, which is the conservative behavior we want.
    private var lastAchievementUnlockDate: Date?

    /// Call when a RetroAchievements achievement unlocks (any game).
    func recordAchievementUnlocked() {
        lastAchievementUnlockDate = Date()
    }

    /// Check if the App Store review warm-up card should appear.
    /// Thin Bool wrapper over `reviewPromptArm(currentSessionSeconds:)`.
    func shouldShowReviewPrompt(currentSessionSeconds: TimeInterval) -> Bool {
        reviewPromptArm(currentSessionSeconds: currentSessionSeconds) != nil
    }

    /// Which arm (if any) allows the review warm-up card right now. The
    /// returned identifier feeds the analytics `trigger` param so each arm's
    /// volume and conversion can be read separately.
    /// Prompt #1 fires via any of four paths:
    ///   - "loyal_returner": 3rd session or later AND ≥1h cumulative play
    ///   - "deep_first_timer": still in session 1 AND ≥2h in that session
    ///   - "engaged_first_timer": still in session 1 AND ≥15min AND has
    ///     created at least one manual save state. The save state is a
    ///     deliberate engagement signal that the bare time bar lacks, so
    ///     it lets us prompt a clearly-invested newcomer far earlier than
    ///     the 2h deep-first-timer bar (which almost no one reaches in one
    ///     sitting) without prompting drive-by users.
    ///   - "ra_unlock": a RetroAchievements unlock in the last 30 min AND
    ///     ≥15 min cumulative play. The unlock is the highest-emotion moment
    ///     the app has; the time bar keeps a 2-minute drive-by unlock from
    ///     prompting. The card still only appears at the pause overlay, never
    ///     over gameplay.
    /// Prompt #2 ("second_prompt") fires at ≥3h cumulative, 24h after prompt
    /// #1, only if prompt #1 was dismissed (not rated). Rating is terminal.
    func reviewPromptArm(currentSessionSeconds: TimeInterval) -> String? {
        // Legacy users who already saw the single-shot prompt: no more prompts.
        guard !defaults.bool(forKey: kReviewPromptShown) else { return nil }

        // Terminal: user already rated.
        guard !defaults.bool(forKey: kReviewPromptRated) else { return nil }

        let dismissedCount = defaults.integer(forKey: kReviewPromptDismissedCount)
        guard dismissedCount < 2 else { return nil }

        // 24h minimum between warm-up cards so a marathon session doesn't
        // trigger both prompts back-to-back.
        if let lastShown = defaults.object(forKey: kReviewPromptLastShownDate) as? Date,
           Date().timeIntervalSince(lastShown) < reviewPromptMinGapSeconds {
            return nil
        }

        let totalPlayed = totalPlaySeconds + currentSessionSeconds

        if dismissedCount == 0 {
            if let unlockDate = lastAchievementUnlockDate,
               Date().timeIntervalSince(unlockDate) <= reviewPromptRAUnlockWindow,
               totalPlayed >= reviewPromptSecondsRAUnlock {
                return "ra_unlock"
            }
            if sessionCount >= reviewPromptMinSessionsForFirst
                && totalPlayed >= reviewPromptSecondsPrompt1 {
                return "loyal_returner"
            }
            if sessionCount == 0
                && currentSessionSeconds >= reviewPromptSecondsFirstSessionDeep {
                return "deep_first_timer"
            }
            if sessionCount == 0
                && currentSessionSeconds >= reviewPromptSecondsEngagedFirstTimer
                && hasCreatedSaveState {
                return "engaged_first_timer"
            }
            return nil
        } else {
            return totalPlayed >= reviewPromptSecondsPrompt2 ? "second_prompt" : nil
        }
    }

    /// Call when the card is presented. Records the date and pessimistically
    /// increments the dismissed count so swipe-down / force-close still count.
    /// If the user taps Rate, call `recordReviewPromptRated()` afterwards —
    /// the rated flag short-circuits `shouldShowReviewPrompt` so the stale
    /// dismissed count doesn't matter.
    func recordReviewPromptPresented() {
        defaults.set(Date(), forKey: kReviewPromptLastShownDate)
        let count = defaults.integer(forKey: kReviewPromptDismissedCount) + 1
        defaults.set(count, forKey: kReviewPromptDismissedCount)
    }

    /// Call when the user taps "Rate 5 stars". Terminal — no more prompts.
    func recordReviewPromptRated() {
        defaults.set(true, forKey: kReviewPromptRated)
    }

    /// Record that the user created a manual save state. A deliberate save
    /// (not the silent auto-save on quit/background) is a strong
    /// first-session engagement signal, gating the engagedFirstTimer review
    /// arm. Idempotent: one save is enough, repeated calls are a no-op.
    func recordSaveStateCreated() {
        defaults.set(true, forKey: kSaveStateCreated)
    }

    /// Whether the user has created at least one manual save state.
    var hasCreatedSaveState: Bool {
        defaults.bool(forKey: kSaveStateCreated)
    }

    // MARK: - Per-Game Play Time

    private func perGameKey(_ romName: String) -> String {
        "pt_gameSeconds_\(romName)"
    }

    /// Record play time for a specific game.
    func recordGamePlayTime(romName: String, seconds: TimeInterval) {
        let key = perGameKey(romName)
        let total = defaults.double(forKey: key) + seconds
        defaults.set(total, forKey: key)
    }

    /// Total play time for a specific game.
    func gamePlayTime(romName: String) -> TimeInterval {
        defaults.double(forKey: perGameKey(romName))
    }

    /// Check if cheat code trigger should fire (4+ hours on one game).
    private let kCheatPromptShownPrefix = "pt_cheatShown_"

    func shouldShowCheatCodes(romName: String) -> Bool {
        let key = kCheatPromptShownPrefix + romName
        guard !defaults.bool(forKey: key) else { return false }
        guard canShowActivePrompt else { return false }
        return gamePlayTime(romName: romName) >= 14400 // 4 hours
    }

    func markCheatCodesShown(romName: String) {
        defaults.set(true, forKey: kCheatPromptShownPrefix + romName)
    }
}
