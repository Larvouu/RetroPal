//
//  GlowCircle.swift
//  EmulateurGBA
//
//  Pulsating radial gold+purple glow. Parent controls placement via
//  .offset / .frame / ZStack — this view just renders a centered pulse.
//

import SwiftUI

struct GlowCircle: View {
    var size: CGFloat

    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = ProPalette.pulsePhase(at: ctx.date)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            ProPalette.gold.opacity(0.25),
                            Color.purple.opacity(0.15),
                            Color.clear
                        ],
                        center: .center, startRadius: 5, endRadius: size / 2
                    )
                )
                .frame(width: size, height: size)
                .scaleEffect(1.0 + phase * 0.15)
                .opacity(0.6 + phase * 0.4)
        }
    }
}

#Preview {
    ZStack {
        ProPalette.bgGradient.ignoresSafeArea()
        GlowCircle(size: 280)
    }
}
