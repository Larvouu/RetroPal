//
//  MiniBenefitCard.swift
//  EmulateurGBA
//
//  Gold-bordered glass card representing a Pro benefit. Two sizes:
//  .featured (larger, for the trigger-specific hero card) and .mini
//  (smaller, for the grid of other benefits).
//

import SwiftUI

struct MiniBenefitCard: View {
    enum Style {
        case featured
        case mini
    }

    let icon: String   // SF Symbol name
    let text: String
    let style: Style

    init(icon: String, text: String, style: Style = .mini) {
        self.icon = icon
        self.text = text
        self.style = style
    }

    private var iconSize: CGFloat {
        style == .featured ? 18 : 14
    }

    private var textFont: Font {
        style == .featured ? .subheadline.bold() : .footnote.bold()
    }

    private var minHeight: CGFloat {
        style == .featured ? 44 : 36
    }

    private var horizontalPadding: CGFloat {
        style == .featured ? 20 : 12
    }

    private var verticalPadding: CGFloat {
        style == .featured ? 14 : 8
    }

    private var iconFrameWidth: CGFloat {
        style == .featured ? 24 : 20
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundStyle(ProPalette.crownGradient)
                .frame(width: iconFrameWidth)
            Text(text)
                .font(textFont)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.8)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: minHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(ProPalette.gold.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    ProPalette.gold.opacity(0.6),
                                    Color.purple.opacity(0.4)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: ProPalette.gold.opacity(style == .featured ? 0.15 : 0.08),
                radius: style == .featured ? 8 : 4)
    }
}

#Preview {
    ZStack {
        ProPalette.bgGradient.ignoresSafeArea()
        VStack(spacing: 12) {
            MiniBenefitCard(icon: "gauge.high", text: "All speeds — 0.25× to 4×", style: .featured)
                .padding(.horizontal, 20)

            HStack(spacing: 8) {
                MiniBenefitCard(icon: "tray.2", text: "5 save slots")
                MiniBenefitCard(icon: "backward.fill", text: "30s rewind")
            }
            HStack(spacing: 8) {
                MiniBenefitCard(icon: "command", text: "Cheat codes")
                MiniBenefitCard(icon: "hand.draw", text: "Custom controls")
            }
        }
        .padding()
    }
}
