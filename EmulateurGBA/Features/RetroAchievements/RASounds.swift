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

    /// Full-achievement fanfare. `gameSoundOn` = the in-game sound toggle.
    static func playUnlock(gameSoundOn: Bool) {
        guard gameSoundOn, let player = unlockPlayer else { return }
        ensureSession()
        player.currentTime = 0
        player.play()
    }

    /// Measured-progress blip (e.g. 5/151 -> 6/151). Throttled.
    static func playProgress(gameSoundOn: Bool) {
        guard gameSoundOn, let player = progressPlayer else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgressPlay) >= progressThrottle else { return }
        lastProgressPlay = now
        ensureSession()
        player.currentTime = 0
        player.play()
    }

    /// The emulator configures the shared session (.ambient + mixWithOthers)
    /// when a game starts, but the debug previews can fire before any game ran
    /// this launch. Apply the SAME configuration (never a different category:
    /// RA sounds follow the app's audio philosophy, silent switch included)
    /// and make sure the session is active. Cheap and idempotent.
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
