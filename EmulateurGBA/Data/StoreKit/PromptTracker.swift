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
    case videoFilters                      // user tapped a display filter in the Appearance sheet (Pro)
    case externalDisplay                   // user tapped the external-display row in Settings (Pro)

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
        case .videoFilters: return "videoFilters"
        case .externalDisplay: return "externalDisplay"
        }
    }
}

final class PromptTracker {
    static let shared = PromptTracker()

    private let defaults: UserDefaults

    // Keys
    private let kTotalPlaySeconds = "pt_totalPlaySeconds"
    private let kSessionCount = "pt_sessionCount"
    private let kLastPlayBankDate = "pt_lastPlayBankDate"
    private let kFirstPlayDay = "pt_firstPlayDay"

    /// Idle time that separates two sessions. 30 minutes is the usual analytics
    /// convention and it comfortably absorbs a phone call or a look at Maps.
    private let sessionGapSeconds: TimeInterval = 30 * 60
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

    /// Call whenever play time is banked: quit to library, app background, or
    /// resign-active (a call, Control Center, an app switch). So this fires
    /// MANY times inside one sitting, which is why the session count below is
    /// not simply incremented here.
    ///
    /// A SESSION is a run of play, not a banking event. Until 1.2.5 this method
    /// bumped `kSessionCount` on every call, so a single evening of play with
    /// three notifications counted as four sessions. That inflated a
    /// user-visible number (the Retro Story card shows it) and, worse, it
    /// silently disabled both first-session review triggers, which asked for
    /// `sessionCount == 0` — a state that ended at the user's first
    /// notification. Sessions are now separated by IDLE time: elapsed time
    /// since the last banking, minus the play time being banked, is the gap
    /// where the user was not playing.
    ///
    /// Historical counts stay as they are. They are inflated for existing
    /// users and rewriting them would make a stat on their share card drop
    /// overnight, which reads as lost data; the inflation simply stops here.
    func recordSessionEnd(playSeconds: TimeInterval) {
        let now = Date()
        let total = defaults.double(forKey: kTotalPlaySeconds) + playSeconds
        defaults.set(total, forKey: kTotalPlaySeconds)

        let idleSeconds: TimeInterval
        if let lastBank = defaults.object(forKey: kLastPlayBankDate) as? Date {
            idleSeconds = max(0, now.timeIntervalSince(lastBank) - playSeconds)
        } else {
            idleSeconds = .greatestFiniteMagnitude   // first ever banking = session 1
        }
        if idleSeconds >= sessionGapSeconds {
            defaults.set(defaults.integer(forKey: kSessionCount) + 1, forKey: kSessionCount)
        }
        defaults.set(now, forKey: kLastPlayBankDate)

        if defaults.object(forKey: kFirstPlayDay) == nil {
            defaults.set(Calendar.current.startOfDay(for: now), forKey: kFirstPlayDay)
        }
    }

    /// Whether the user first played on an EARLIER calendar day than today,
    /// i.e. they left and came back. The strongest satisfaction signal the app
    /// can read without asking anyone anything, and the reason it gates a
    /// review trigger: month-one retention is ~62%, so returning is a real
    /// choice rather than the default.
    var isReturningDay: Bool {
        guard let firstDay = defaults.object(forKey: kFirstPlayDay) as? Date else { return false }
        return !Calendar.current.isDate(firstDay, inSameDayAs: Date())
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

    /// ONE path since 1.2.5: a bare `SKStoreReviewController` request fired on
    /// the quit-to-library path. No warm-up card, no terminal states, no
    /// dismissal counting. The request is silent once Apple's per-user display
    /// quota (3 displays / 365 days) is spent or the user turned in-app rating
    /// asks off system-wide, so a repeated ask costs nothing and Apple is the
    /// limiter. That shape is deliberate and it is the shape the most-rated
    /// emulator on the App Store uses; it was adopted in 1.2.3 from reading
    /// their (AGPL) source, a provenance that was never written down and had
    /// to be rediscovered on 2026-08-11. Recorded here so it is not
    /// re-litigated: **do not add spacing, lifetime caps or a warm-up card.**
    ///
    /// What 1.2.5 changed is not the cadence but WHO qualifies:
    ///
    ///  - Until 1.2.5 the bar was an hour of play summed across every game,
    ///    plus a session count that was broken (see `recordSessionEnd`). That
    ///    counts a user who bounced off five games as readily as one who stuck
    ///    with a single game, and it left `loyal_returner` as the only trigger
    ///    that ever fired in the field.
    ///  - Now the bar is per-GAME, and the reference implementation's: 30
    ///    minutes on the game you just put down. It fires sooner for a focused
    ///    player and never for a dabbler, which is a better-aimed filter rather
    ///    than a looser one — their average rating matches ours at half our old
    ///    time bar.
    ///
    /// Triggers are evaluated best-moment-first, so the reported one is the
    /// best that applied. There is deliberately NO holding back of a mediocre
    /// moment waiting for a better one: a third of users never return, and
    /// holding would mean never asking them. The better moments simply tend to
    /// arrive earlier on their own.

    private let kReviewPromptLastShownDate = "reviewPromptLastShownDate"
    private let kSaveStateCreated = "pt_saveStateCreated"

    /// 30 minutes on the game just played. Matches the reference implementation.
    private let reviewPromptGameSeconds: TimeInterval = 30 * 60
    /// Minimum play in the current sitting for the two quality triggers, so a
    /// drive-by unlock or a two-minute look-in never asks.
    private let reviewPromptEngagedSessionSeconds: TimeInterval = 10 * 60
    /// One ask per 24h, of any kind.
    private let reviewPromptMinGapSeconds: TimeInterval = 24 * 3600

    /// In-memory only, deliberately not persisted: whether a RetroAchievements
    /// achievement unlocked during this run of the app. An app relaunch resets
    /// it, which is the conservative behavior we want, and it is cleared once
    /// an ask actually fires so one unlock cannot qualify forever.
    private var achievementUnlockedThisRun = false

    /// Call when a RetroAchievements achievement unlocks (any game).
    func recordAchievementUnlocked() {
        achievementUnlockedThisRun = true
    }

    /// Which trigger (if any) allows a direct system review request on the quit
    /// path right now, best moment first. The returned identifier feeds the
    /// analytics `trigger` param; `review_prompt_shown` means "requested" —
    /// whether Apple actually displayed it is invisible to the app.
    ///
    ///   - "ra_unlock":  an achievement unlocked this run, and ≥10 min played
    ///                   in this sitting. The highest-emotion moment we can see.
    ///   - "return_day": the user first played on an earlier day and has put
    ///                   ≥10 min in today. Coming back is the clearest
    ///                   satisfaction signal available for free.
    ///   - "game_30min": ≥30 min on THIS game, all time, including the sitting
    ///                   about to end. The baseline, and the one that carries
    ///                   the volume.
    ///
    /// Call `recordDirectReviewRequested()` when the request is fired.
    func directReviewRequestTrigger(romName: String, currentSessionSeconds: TimeInterval) -> String? {
        guard reviewAskGapElapsed else { return nil }

        let engagedSitting = currentSessionSeconds >= reviewPromptEngagedSessionSeconds
        if achievementUnlockedThisRun && engagedSitting { return "ra_unlock" }
        if isReturningDay && engagedSitting { return "return_day" }
        if gamePlayTime(romName: romName) + currentSessionSeconds >= reviewPromptGameSeconds {
            return "game_30min"
        }
        return nil
    }

    /// 24h minimum between review asks, so a marathon day never produces
    /// back-to-back asks.
    private var reviewAskGapElapsed: Bool {
        guard let lastShown = defaults.object(forKey: kReviewPromptLastShownDate) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastShown) >= reviewPromptMinGapSeconds
    }

    /// Call when a direct system review request fires on the quit path. Stamps
    /// the 24h gap and consumes the achievement flag, so a single unlock cannot
    /// keep qualifying on later quits.
    func recordDirectReviewRequested() {
        defaults.set(Date(), forKey: kReviewPromptLastShownDate)
        achievementUnlockedThisRun = false
    }

    /// Record that the user created a manual save state. A deliberate save
    /// (not the silent auto-save on quit/background) is a strong engagement
    /// signal. It gated the retired `engagedFirstTimer` review arm and is kept
    /// as a read-only signal: the save path is the most sensitive code in the
    /// app and is not worth touching to delete four lines.
    /// Idempotent: one save is enough, repeated calls are a no-op.
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
