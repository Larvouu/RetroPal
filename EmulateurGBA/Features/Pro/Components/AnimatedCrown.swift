//
//  AnimatedCrown.swift
//  EmulateurGBA
//
//  Crown SF Symbol with a gold+purple pulsing shadow and a ghost-white
//  shimmer overlay. TimelineView-driven so the animation survives
//  orientation changes and parent view-identity swaps.
//

import SwiftUI

struct AnimatedCrown: View {
    var size: CGFloat = 44

    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = ProPalette.pulsePhase(at: ctx.date)
            ZStack {
                Image(systemName: "crown.fill")
                    .font(.system(size: size))
                    .foregroundStyle(ProPalette.crownGradient)
                    .shadow(color: ProPalette.gold.opacity(0.5),
                            radius: 16 + phase * 10)
                    .shadow(color: .purple.opacity(0.3),
                            radius: 24 + phase * 6)

                Image(systemName: "crown.fill")
                    .font(.system(size: size))
                    .foregroundStyle(.white.opacity(0.1 + phase * 0.15))
            }
        }
    }
}

#Preview {
    ZStack {
        ProPalette.bgGradient.ignoresSafeArea()
        VStack(spacing: 32) {
            AnimatedCrown()
            AnimatedCrown(size: 32)
            AnimatedCrown(size: 24)
        }
    }
}
