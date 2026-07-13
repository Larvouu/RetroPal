//
//  Skeleton.swift
//  EmulateurGBA
//
//  Loading-skeleton primitives (the "empty skeleton" technique, like Instagram):
//  gray placeholder blocks with a soft highlight sweeping across, so a short
//  wait reads as content-about-to-appear rather than a blocking spinner.
//

import SwiftUI

/// A shimmering placeholder block. Use it in place of a real value while loading.
struct SkeletonBox: View {
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.12))
            .shimmering()
    }
}

private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if reduceMotion {
            content   // a static gray block, no sweep
        } else {
            content
                .overlay(
                    GeometryReader { geo in
                        let w = max(geo.size.width, 1)
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.28), .clear],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: w * 0.7)
                            .offset(x: phase * w * 1.7)
                    }
                    .mask(content)
                )
                .onAppear {
                    withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
    }
}

extension View {
    /// Sweeps a soft highlight across the view as a loading shimmer (respects
    /// Reduce Motion: a static block, no animation).
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}
