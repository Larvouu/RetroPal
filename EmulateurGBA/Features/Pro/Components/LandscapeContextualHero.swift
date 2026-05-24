//
//  LandscapeContextualHero.swift
//  EmulateurGBA
//
//  Left column of the landscape Pro sheet for contextual (non-comparison)
//  sheets. Crown + glow + contextual headline + subtitle + optional
//  featured benefit card. Vertically centered via Spacers.
//
//  Takes pre-resolved strings (not a ProPromptContext) — the parent
//  orchestrator owns context-to-text resolution. Keeps this component
//  decoupled from the context enum and easy to preview in isolation.
//

import SwiftUI

struct LandscapeContextualHero: View {
    let headline: String
    let subtitle: String
    /// Optional featured benefit. Pass nil for contexts without a
    /// trigger-specific hero (currently: .sessionMilestone).
    let featuredIcon: String?
    let featuredText: String?

    var body: some View {
        ZStack {
            GlowCircle(size: 240)

            VStack(spacing: 14) {
                Spacer(minLength: 0)

                AnimatedCrown()

                Text(headline)
                    .font(.title3.bold())
                    .foregroundStyle(ProPalette.crownGradient)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                // Featured card anchors the pitch visually. Omitted when the
                // context has no single featured benefit (sessionMilestone).
                if let icon = featuredIcon, let text = featuredText {
                    MiniBenefitCard(icon: icon, text: text, style: .featured)
                        .padding(.top, 4)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
    }
}

#Preview("With featured") {
    ZStack {
        ProPalette.bgGradient.ignoresSafeArea()
        LandscapeContextualHero(
            headline: "You've played 30 minutes at 1.5× speed",
            subtitle: "Pro adds 0.25×, 2×, 3×, 4× — go slower or turbo.",
            featuredIcon: "gauge.high",
            featuredText: "All speeds — 0.25× to 4×"
        )
    }
}

#Preview("Without featured (sessionMilestone)") {
    ZStack {
        ProPalette.bgGradient.ignoresSafeArea()
        LandscapeContextualHero(
            headline: "You've played 60 minutes of retro games",
            subtitle: "Level up your experience with Pro.",
            featuredIcon: nil,
            featuredText: nil
        )
    }
}
