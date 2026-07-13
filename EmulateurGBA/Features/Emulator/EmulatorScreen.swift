//
//  EmulatorScreen.swift
//  EmulateurGBA
//
//  SwiftUI wrapper for the UIKit emulator view controller. Owns the share-card
//  presentation: the clip + screenshot cards are presented here as SwiftUI
//  `.sheet`s — the same mechanism as the stats card — so all three share cards
//  use ONE presentation path and behave identically (incl. full-screen + swipe-
//  to-dismiss in landscape, which a UIKit-presented sheet can't do).
//

import SwiftUI
import CoreGraphics

/// What the emulator wants to share. Built by `EmulatorViewController`, presented
/// by `EmulatorScreen`. `id` is fresh per request so re-sharing re-triggers `.sheet`.
struct EmulatorShareCard: Identifiable {
    let id = UUID()
    enum Content {
        case clip(ClipShareModel, frameAspect: CGFloat)
        // The source frame + info (not a pre-rendered image), so the share view can
        // re-render the card live when the user toggles the card style. `skin` is
        // the per-game style key + the game's dress for the "current skin" option.
        case screenshot(gameFrame: CGImage, name: String, playTime: TimeInterval,
                        system: PresetSystem, skin: ShareCardSkinContext)
    }
    let content: Content
    let hint: String?
}

/// Bridge between the UIKit `EmulatorViewController` and the SwiftUI `.sheet`.
final class EmulatorShareModel: ObservableObject {
    @Published var card: EmulatorShareCard?
    /// Resume hook, called after the card sheet is dismissed (close or swipe).
    /// Guarded inside the VC, so it no-ops when the game shouldn't resume.
    var onDismiss: (() -> Void)?
    /// Pause hook for sheets `EmulatorScreen` presents on its own (the RA
    /// unlock share card). Set by the VC: banks play time, pauses gameplay and
    /// arms `onDismiss` with the guarded resume — the same contract the
    /// screenshot/clip cards get inside their present methods. Safe to call
    /// when the game is already paused (it no-ops the pause, the resume stays
    /// correctly gated by the pause overlay).
    var pauseForCard: (() -> Void)?
}

struct EmulatorScreen: View {
    private let romURL: URL
    private let session: EmulatorSession
    private let loadSlot: Int?
    /// User-facing title (used for the screenshot share card).
    private let gameTitle: String?
    /// File size recorded at import, for the load-time ROM pre-flight check.
    private let expectedROMSize: Int64
    private let onQuit: (() -> Void)?

    @StateObject private var share = EmulatorShareModel()
    /// The unlock whose banner was tapped; drives the achievement share card.
    @State private var raShareUnlock: RAUnlock?

    // Explicit init so the call-site trailing closure binds unambiguously to
    // `onQuit` (the private `@StateObject share` is set from its own default and
    // is never injected from outside).
    init(romURL: URL, session: EmulatorSession, loadSlot: Int? = nil,
         gameTitle: String? = nil, expectedROMSize: Int64 = 0, onQuit: (() -> Void)? = nil) {
        self.romURL = romURL
        self.session = session
        self.loadSlot = loadSlot
        self.gameTitle = gameTitle
        self.expectedROMSize = expectedROMSize
        self.onQuit = onQuit
    }

    var body: some View {
        EmulatorScreenRepresentable(
            romURL: romURL, session: session, loadSlot: loadSlot, gameTitle: gameTitle,
            expectedROMSize: expectedROMSize, onQuit: onQuit, share: share)
        // Tapping the unlock banner opens that achievement's SHARE CARD (the
        // full dashboard lives in Game Details and the library profile). The
        // game pauses for the card and resumes on dismiss, like the other cards.
        .overlay(alignment: .top) { RAUnlockHUD(onTap: { unlock in
            share.pauseForCard?()
            raShareUnlock = unlock
        }) }
        // Measured-achievement progress pill (e.g. "42/151"), below the
        // unlock banner's band, never hit-testable.
        .overlay(alignment: .top) { RAProgressHUD() }
        // RA tracking-state notice (paused offline / resumed), leading side
        // of the same band.
        .overlay(alignment: .top) { RASessionNoticeHUD() }
        .sheet(item: $raShareUnlock, onDismiss: { share.onDismiss?() }) { unlock in
            RAShareView(achievement: unlock.asAchievementInfo(),
                        gameName: unlock.gameTitle,
                        boxArtURL: unlock.boxArtURL,
                        romFilename: romURL.lastPathComponent,
                        onClose: { raShareUnlock = nil })
        }
        .sheet(item: $share.card, onDismiss: { share.onDismiss?() }) { card in
            switch card.content {
            case let .clip(model, aspect):
                ClipShareView(model: model, frameAspect: aspect,
                              onClose: { share.card = nil }, hintText: card.hint)
            case let .screenshot(gameFrame, name, playTime, system, skin):
                ScreenshotShareView(gameFrame: gameFrame, name: name, playTime: playTime,
                                    system: system, skinContext: skin,
                                    onClose: { share.card = nil }, hintText: card.hint)
            }
        }
    }
}

private struct EmulatorScreenRepresentable: UIViewControllerRepresentable {
    let romURL: URL
    let session: EmulatorSession
    var loadSlot: Int?
    var gameTitle: String?
    var expectedROMSize: Int64 = 0
    var onQuit: (() -> Void)?
    let share: EmulatorShareModel

    func makeUIViewController(context: Context) -> EmulatorViewController {
        let vc = EmulatorViewController(romURL: romURL, session: session)
        vc.loadSlotOnStart = loadSlot
        vc.gameTitle = gameTitle
        vc.expectedROMSize = expectedROMSize
        vc.onQuit = onQuit
        vc.shareModel = share
        return vc
    }

    func updateUIViewController(_ uiViewController: EmulatorViewController, context: Context) {
    }
}
