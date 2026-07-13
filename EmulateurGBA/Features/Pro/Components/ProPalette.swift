//
//  ProPalette.swift
//  EmulateurGBA
//
//  Centralized color and gradient tokens for the "Neon Luxury" Pro visual
//  language. Single source of truth: every Pro component reads from here.
//  If the palette changes, one file.
//

import SwiftUI
import Foundation

enum ProPalette {
    // MARK: - Core colors

    static let gold = Color(red: 1.0, green: 0.84, blue: 0.35)
    static let goldDark = Color(red: 0.85, green: 0.65, blue: 0.15)
    static let ctaTextDark = Color(red: 0.15, green: 0.1, blue: 0.0)

    // MARK: - Gradients

    /// Crown icon fill + hero headline foreground.
    static let crownGradient = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.88, blue: 0.4),
            Color(red: 0.9, green: 0.7, blue: 0.2),
            Color(red: 1.0, green: 0.84, blue: 0.35)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Purple/blue accent for pending-state icons and secondary visual cues.
    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.55, green: 0.3, blue: 1.0),
            Color(red: 0.3, green: 0.5, blue: 1.0)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Gold pill background for the primary Lifetime CTA.
    static let ctaGradient = LinearGradient(
        colors: [
            Color(red: 0.85, green: 0.65, blue: 0.15),
            Color(red: 1.0, green: 0.84, blue: 0.35),
            Color(red: 0.85, green: 0.65, blue: 0.15)
        ],
        startPoint: .leading, endPoint: .trailing
    )

    /// Full-sheet background gradient. Near-black with purple undertone.
    static let bgGradient = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.06, blue: 0.16),
            Color(red: 0.04, green: 0.03, blue: 0.10)
        ],
        startPoint: .top, endPoint: .bottom
    )

    // MARK: - Shared animation driver

    /// Returns a 0..1 phase with a 2-second period, driven by wall-clock time.
    /// Used by AnimatedCrown (and any other pulsing Pro element)
    /// so they share the same beat without needing a shared @State driver.
    /// TimelineView(.animation) is the caller's responsibility.
    static func pulsePhase(at date: Date) -> CGFloat {
        CGFloat((sin(date.timeIntervalSinceReferenceDate * .pi) + 1) / 2)
    }
}
