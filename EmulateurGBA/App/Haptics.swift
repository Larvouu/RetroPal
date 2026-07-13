//
//  Haptics.swift
//  EmulateurGBA
//

import UIKit

/// Lightweight app-chrome haptics for a more premium feel on navigation and
/// primary actions.
///
/// Intentionally NOT gated on the in-game "Retour haptique" setting
/// (Settings ▸ Contrôles): that toggle governs the on-screen GAME buttons,
/// whereas these are UI/chrome taps that are always on. Don't add the
/// `hapticsEnabled` check here.
enum Haptics {
    private static let impact = UIImpactFeedbackGenerator(style: .light)

    /// A light impact, matching the subtle feel of a system Toggle flip (e.g. the
    /// D-pad/Joystick switch in Settings). Used for tab changes and primary
    /// navigation / launch taps.
    static func tap() {
        impact.impactOccurred()
        impact.prepare()  // keep it warm so the next tap is low-latency
    }
}
