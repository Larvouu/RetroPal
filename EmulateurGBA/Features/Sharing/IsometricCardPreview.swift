//
//  IsometricCardPreview.swift
//  EmulateurGBA
//
//  Shared faux-3D presentation for the share-sheet card previews (stats /
//  screenshot / clip). A light isometric 3/4 tilt with a thin extruded edge and
//  a slow sway, so the card feels tactile and worth sharing. Presentation ONLY:
//  the exported/shared/saved asset is always the flat front-facing card.
//
//  SwiftUI's `rotation3DEffect` gives the perspective without a real 3D object
//  (which couldn't render to a shared image anyway). It wraps any face content
//  (a rendered Image, or the looping clip view) at any aspect ratio.
//

import SwiftUI

struct IsometricCardPreview<Face: View>: View {
    let reduceMotion: Bool
    /// Face aspect ratio, width / height (1 = square).
    var aspect: CGFloat = 1
    /// Optional cap on the card width. Default (nil) keeps the portrait sizing
    /// (min(screen width − 96, 300)). The landscape share layouts pass a value
    /// fitted to the available height so a non-square (e.g. 4:5 screenshot) card
    /// stays fully visible without scrolling.
    var maxWidth: CGFloat? = nil
    /// The faux-thickness (side edge) gradient. Defaults to the purple brand edge; the GB/GBC Pro
    /// card passes its own body colour so the extruded edge matches that card's background.
    var edgeColors: [Color] = [Color(red: 0.22, green: 0.12, blue: 0.34),
                               Color(red: 0.07, green: 0.04, blue: 0.13)]
    @ViewBuilder var face: () -> Face

    /// Animated Y-axis angle. Starts at 0 and sways symmetrically -9...9.
    @State private var yAngle: Double = 0

    private let corner: CGFloat = 14
    private let layers = 10
    /// Total faux thickness in points (kept mostly sideways = a side edge).
    private let depth: CGFloat = 3
    private var cardWidth: CGFloat { min(UIScreen.main.bounds.width - 96, maxWidth ?? 300) }
    private var cardHeight: CGFloat { cardWidth / max(aspect, 0.1) }

    /// Signed tilt fraction (-1...1). Places the thickness + grounding shadow on
    /// the edge tilting toward the viewer and scales them with the tilt, so they
    /// vanish at the flat (0°) crossing and flip side smoothly through it.
    private var tiltFrac: CGFloat { CGFloat(yAngle) / 9 }

    var body: some View {
        ZStack {
            // Faux thickness: a stack of rounded-rect edges behind the face,
            // offset mostly sideways so under the Y tilt they read as the card's
            // side/base edge rather than a drop shadow.
            ForEach(0..<layers, id: \.self) { i in
                let t = CGFloat(layers - i) / CGFloat(layers)   // 1 = deepest layer
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(LinearGradient(
                        colors: edgeColors,
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .offset(x: -tiltFrac * depth * t, y: depth * 0.45 * t)
            }
            face()
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1))
        }
        .frame(width: cardWidth, height: cardHeight)
        // Y tilt = the 3/4 turn (animated); a small fixed X tilt = isometric feel.
        .rotation3DEffect(.degrees(yAngle), axis: (x: 0, y: 1, z: 0),
                          anchor: .center, perspective: 0.5)
        .rotation3DEffect(.degrees(5), axis: (x: 1, y: 0, z: 0),
                          anchor: .center, perspective: 0.5)
        .shadow(color: .black.opacity(0.45), radius: 20, x: tiltFrac * 10, y: 16)
        .shadow(color: .purple.opacity(0.32), radius: 26)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .onAppear {
            guard !reduceMotion else { yAngle = 6; return }
            // Ease 0 -> 9 (a quarter), then sway 9 <-> -9 forever.
            withAnimation(.easeInOut(duration: 2.25)) { yAngle = 9 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.25) {
                withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                    yAngle = -9
                }
            }
        }
    }
}
