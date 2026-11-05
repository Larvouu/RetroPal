//
//  RASounds.swift
//  EmulateurGBA
//
//  The two RetroAchievements celebration sounds, self-synthesized square-wave
//  chiptunes (no third-party assets, so the public GPL snapshot stays
//  provenance-clean):
//    • ra-unlock.wav   — short ascending C-major arpeggio, full achievement
//    • ra-progress.wav — discreet two-note blip, measured-progress step
//  Both respect the in-game sound toggle: callers pass the effective state and
//  nothing plays while the game is muted. The progress blip is additionally
//  throttled so a burst of measured updates can't machine-gun it.
//

import AVFoundation

enum RASounds {
    private static let unlockPlayer = makePlayer(resource: "ra-unlock")
    private static let progressPlayer = makePlayer(resource: "ra-progress")
    private static var lastProgressPlay: Date = .distantPast
    private static let progressThrottle: TimeInterval = 0.8

    /// Loads both players and sets the session up once, off the main thread
    /// (his Xcode log of 10-30: activating the session on the main thread at
    /// every sound is the "can lead to UI unresponsiveness" warning, a round
    /// trip to the system's audio server). Called when the manager starts.
    static func prepare() {
        DispatchQueue.global(qos: .utility).async {
            _ = unlockPlayer
            _ = progressPlayer
            ensureSession()
        }
    }

    /// Full-achievement fanfare. `gameSoundOn` = the in-game sound toggle.
    static func playUnlock(gameSoundOn: Bool) {
        guard gameSoundOn, let player = unlockPlayer else { return }
        start(player)
    }

    /// Measured-progress blip (e.g. 5/151 -> 6/151). Throttled.
    static func playProgress(gameSoundOn: Bool) {
        guard gameSoundOn, let player = progressPlayer else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgressPlay) >= progressThrottle else { return }
        lastProgressPlay = now
        start(player)
    }

    /// Plays from the top. The session was set in `prepare` (and by the
    /// emulator when a game starts); it is set again only if the player could
    /// not start, the session having been taken away (a call, for one).
    private static func start(_ player: AVAudioPlayer) {
        player.currentTime = 0
        if !player.play() {
            ensureSession()
            player.play()
        }
    }

    /// The emulator configures the shared session (.ambient + mixWithOthers)
    /// when a game starts, but the debug previews can fire before any game ran
    /// this launch. Apply the SAME configuration (never a different category:
    /// RA sounds follow the app's audio philosophy, silent switch included)
    /// and make sure the session is active. Idempotent, but a round trip to
    /// the audio server: `prepare` runs it off the main thread.
    private static func ensureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: .mixWithOthers)
        try? session.setActive(true)
    }

    private static func makePlayer(resource: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "wav"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        return player
    }
}
