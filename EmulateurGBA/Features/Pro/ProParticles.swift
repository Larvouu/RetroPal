//
//  ProParticles.swift
//  EmulateurGBA
//
//  Shared "Pro surface" particle effect: very small, slow, mostly purple
//  dust drifting outward. Reused by the pause overlay's GradientBackgroundView
//  and by the Settings rows via the SwiftUI wrapper below.
//

import SwiftUI
import UIKit

/// Minimal UIView that runs the Pro-surface particle emitter. Non-clipping
/// so the particles can emanate past the view's bounds.
final class ParticleEmitterView: UIView {
    private let emitter = CAEmitterLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        isUserInteractionEnabled = false
        clipsToBounds = false
        layer.masksToBounds = false

        let sprite = ParticleEmitterView.particleSprite

        func cell(color: UIColor, birthRate: Float) -> CAEmitterCell {
            let c = CAEmitterCell()
            c.contents = sprite.cgImage
            c.birthRate = birthRate
            c.lifetime = 3.5
            c.lifetimeRange = 1.0
            c.velocity = 3.5                // very slow drift
            c.velocityRange = 1.5
            c.emissionRange = .pi * 2       // all directions → emanation pattern
            c.scale = 0.09                  // ~0.55pt with a 6pt sprite → dust
            c.scaleRange = 0.04
            c.alphaSpeed = -0.12             // gentle fade
            c.color = color.cgColor
            return c
        }

        // 90% purple / 10% gold.
        let gold = UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 0.45)
        let purple = UIColor(red: 0.55, green: 0.3, blue: 1.0, alpha: 0.45)

        emitter.emitterShape = .rectangle
        emitter.emitterMode = .volume
        emitter.renderMode = .unordered
        emitter.emitterCells = [
            cell(color: purple, birthRate: 2.25),
            cell(color: gold,   birthRate: 0.25)
        ]
        layer.addSublayer(emitter)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        emitter.emitterSize = bounds.size
    }

    /// Small circular sprite used by the emitter cells. Generated once and
    /// reused across all instances.
    private static let particleSprite: UIImage = {
        let size = CGSize(width: 6, height: 6)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor.white.cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }()
}

/// SwiftUI wrapper so Pro-gated List rows can host the same drift as the
/// pause overlay's Pro buttons.
struct ProParticlesView: UIViewRepresentable {
    func makeUIView(context: Context) -> ParticleEmitterView {
        return ParticleEmitterView()
    }

    func updateUIView(_ uiView: ParticleEmitterView, context: Context) {}
}
