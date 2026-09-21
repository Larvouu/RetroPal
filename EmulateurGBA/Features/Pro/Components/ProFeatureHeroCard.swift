//
//  ProFeatureHeroCard.swift
//  EmulateurGBA
//
//  The shared hero for every contextual Pro sheet: a neon-luxury card (bezel,
//  dark gradient, subtle gold-glow drift) whose core is a concrete Free → Pro
//  "before → after" for the triggered benefit — the element that actually sells
//  (loss-aversion + anchoring at the moment of friction). Motion is a ONE-TIME
//  settle on appear (no perpetual sway, so it never competes with the CTA);
//  only the gold glow drifts gently after. Respects Reduce Motion.
//

import SwiftUI

struct ProFeatureHeroCard: View {
    let reduceMotion: Bool
    /// Landscape variant: tighter spacing / paddings / fonts so the card and the
    /// headline beneath it both fit a half-height column without scrolling.
    var compact: Bool = false
    let icon: String
    let title: String
    /// Free-tier value. `nil` = a binary unlock (a lock is shown on the Free
    /// side instead of a value).
    let freeLabel: String?
    /// Pro-tier value (e.g. "0,25×–4×", "5", "30s", "3 préréglages", or "✓").
    let proLabel: String

    @State private var settled = false
    @State private var glowShift = false

    private let gold = ProPalette.gold
    private let purple = Color(red: 0.55, green: 0.3, blue: 1.0)

    var body: some View {
        VStack(spacing: compact ? 12 : 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 18 : 22, weight: .semibold))
                    .foregroundStyle(ProPalette.crownGradient)
                Text(title)
                    .font((compact ? Font.headline : Font.title3).weight(.bold))
                    .foregroundStyle(ProPalette.crownGradient)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                // Free side
                VStack(spacing: 3) {
                    Text(NSLocalizedString("pro.compare.header.free", comment: ""))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    if let freeLabel {
                        Text(freeLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                            .lineLimit(2).minimumScaleFactor(0.7)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))

                // Pro side
                VStack(spacing: 3) {
                    Text(NSLocalizedString("pro.compare.header.pro", comment: ""))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ProPalette.crownGradient)
                    // Two lines, not one: "5 emplacements de sauvegarde" (fr) is
                    // 2.3x the English and "Alle Geschwindigkeiten" (de) 2.2x,
                    // more than a 0.7 scale factor can absorb on one line.
                    Text(proLabel)
                        .font((compact ? Font.headline : Font.title3).weight(.bold))
                        .foregroundStyle(ProPalette.crownGradient)
                        .multilineTextAlignment(.center)
                        .lineLimit(2).minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.vertical, compact ? 16 : 18)
        .padding(.horizontal, compact ? 20 : 24)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [gold.opacity(0.85), purple.opacity(0.85)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.5))
        .shadow(color: purple.opacity(0.4), radius: 16, y: 6)
        // One-time settle entrance (no perpetual sway).
        .rotation3DEffect(.degrees(settled ? 0 : 9), axis: (x: 0, y: 1, z: 0),
                          anchor: .center, perspective: 0.6)
        .scaleEffect(settled ? 1 : 0.96)
        .opacity(settled ? 1 : 0)
        .onAppear {
            if reduceMotion {
                settled = true
            } else {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { settled = true }
                withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) { glowShift = true }
            }
        }
    }

    /// Tinted glass over the ground since 2026-09-07 (the sheet sits on the
    /// library's moving ground); the gold glow rides on top as before.
    private var cardBackground: some View {
        ZStack {
            Color.white.opacity(LandscapeChrome.cardFill)
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.08, blue: 0.22).opacity(0.55),
                         Color(red: 0.05, green: 0.03, blue: 0.11).opacity(0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [gold.opacity(0.18), .clear],
                center: glowShift ? UnitPoint(x: 0.8, y: 0.2) : UnitPoint(x: 0.2, y: 0.15),
                startRadius: 4, endRadius: 220)
        }
    }
}
