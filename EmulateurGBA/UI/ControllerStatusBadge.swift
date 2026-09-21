//
//  ControllerStatusBadge.swift
//  EmulateurGBA
//
//  "A controller is connected, and here is its battery": a small controller
//  glyph, a battery drawn as a battery with a green fill, and the percentage.
//  Nothing at all when no controller is connected, so it can sit in a bar
//  unconditionally. Shown in the library's top bar in both orientations
//  (decided on device, 2026-09-04). The percentage comes from `ControllerManager`,
//  which reads the pad's battery once a minute; a pad with no battery
//  reading shows the controller glyph alone.
//

import SwiftUI

struct ControllerStatusBadge: View {
    @ObservedObject private var controllers = ControllerManager.shared
    /// Colour of the glyph and the text; the battery fill stays green.
    var tint: Color = .primary
    /// The portrait bar's variant (decided on device, 2026-09-04): the controller glyph
    /// no taller than the battery, and the glyph and the battery's outline at
    /// 0.9 so they sit a step behind the bar's buttons. Landscape keeps the
    /// full-size, full-strength badge.
    var compact: Bool = false

    private var inkOpacity: Double { compact ? 0.9 : 1 }

    var body: some View {
        if controllers.isConnected {
            HStack(spacing: 6) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: compact ? 11 : 14, weight: .semibold))
                    .opacity(inkOpacity)
                if let level = controllers.batteryLevel {
                    BatteryGlyph(level: level, outline: tint, outlineOpacity: compact ? 0.9 : 0.8)
                    Text(Self.percentText(level))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let name = controllers.controllerName { parts.append(name) }
        if let level = controllers.batteryLevel { parts.append(Self.percentText(level)) }
        return parts.joined(separator: ", ")
    }

    /// "73 %" in French, "73%" in English: the locale's own percent style.
    static func percentText(_ level: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: min(max(level, 0), 1))) ?? ""
    }
}

/// A battery, 22 by 11 points: outline, a nub on the right, and a green fill
/// proportional to `level`.
struct BatteryGlyph: View {
    let level: Double
    var outline: Color = .primary
    var outlineOpacity: Double = 0.8

    private let width: CGFloat = 22
    private let height: CGFloat = 11

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(outline.opacity(outlineOpacity), lineWidth: 1.2)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.green)
                .frame(width: max(0, (width - 5) * CGFloat(min(max(level, 0), 1))))
                .padding(2.5)
        }
        .frame(width: width, height: height)
        .overlay(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(outline.opacity(outlineOpacity))
                .frame(width: 2, height: 5)
                .offset(x: 3)
        }
        .padding(.trailing, 3)
        .accessibilityHidden(true)
    }
}
