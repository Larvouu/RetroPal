//
//  ReviewPromptView.swift
//  EmulateurGBA
//
//  "The Thank-You Card" — a warm-up card shown before
//  SKStoreReviewController to maximize positive ratings.
//  Reuses the neon aesthetic from ProUpgradeView.
//

import SwiftUI
import StoreKit

struct ReviewPromptView: View {
    var onRate: () -> Void
    var onDismiss: () -> Void

    @State private var glowPhase: CGFloat = 0
    @State private var starsVisible: Bool = false

    private let gold = Color(red: 1.0, green: 0.84, blue: 0.35)

    private let bgGradient = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.06, blue: 0.16),
            Color(red: 0.04, green: 0.03, blue: 0.10)
        ],
        startPoint: .top, endPoint: .bottom
    )

    private let ctaGradient = LinearGradient(
        colors: [
            Color(red: 0.85, green: 0.65, blue: 0.15),
            Color(red: 1.0, green: 0.84, blue: 0.35),
            Color(red: 0.85, green: 0.65, blue: 0.15)
        ],
        startPoint: .leading, endPoint: .trailing
    )

    var body: some View {
        ZStack {
            bgGradient.ignoresSafeArea()

            // Glow effect
            Circle()
                .fill(
                    RadialGradient(
                        colors: [gold.opacity(0.25), Color.purple.opacity(0.15), Color.clear],
                        center: .center, startRadius: 5, endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)
                .offset(y: -100)
                .scaleEffect(1.0 + glowPhase * 0.15)
                .opacity(0.6 + glowPhase * 0.4)

            VStack(spacing: 20) {
                Spacer(minLength: 24)

                // 5-star row, staggered fade-in
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { index in
                        Image(systemName: "star.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [gold, Color(red: 0.9, green: 0.7, blue: 0.2)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: gold.opacity(0.5), radius: 10)
                            .opacity(starsVisible ? 1 : 0)
                            .scaleEffect(starsVisible ? 1 : 0.6)
                            .animation(
                                .easeOut(duration: 0.3).delay(Double(index) * 0.1),
                                value: starsVisible
                            )
                    }
                }

                // Headline
                Text(NSLocalizedString("review.headline", comment: ""))
                    .font(.title3.bold())
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)

                // Body
                Text(NSLocalizedString("review.body", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)

                Spacer(minLength: 16)

                // CTA Button
                Button(action: onRate) {
                    Text(NSLocalizedString("review.cta", comment: ""))
                        .font(.headline.bold())
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(ctaGradient)
                        .cornerRadius(14)
                        .shadow(color: gold.opacity(0.4), radius: 8)
                }
                .padding(.horizontal, 36)

                // Dismiss
                Button(action: onDismiss) {
                    Text(NSLocalizedString("review.later", comment: ""))
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                glowPhase = 1.0
            }
            starsVisible = true
        }
    }
}
