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
//  With several controllers (1.3.3) the glyph is followed by one chip per
//  player, in player order: the player's number and that pad's battery
//  (decided 2026-09-27), a keyboard glyph for a keyboard player. One
//  controller keeps exactly the badge it always had, with no number.
//
//  IT NEVER BREAKS, whatever room its bar leaves it (device report,
//  2026-09-27: four chips overflowed a 14 Pro on its side, and two wrapped
//  "73" over "%" in the upright bar). It offers several forms, largest first,
//  and shows the first one that fits on one line: the percentages go first,
//  then the player numbers, then the batteries, and the controller glyph alone
//  is the last resort. Every text is kept on one line, so a form either fits
//  whole or is not chosen.
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

    /// What a form shows, largest first (see the file header).
    private enum Density {
        case full, noPercent, noNumbers, glyphOnly
    }

    var body: some View {
        if controllers.isConnected {
            ViewThatFits(in: .horizontal) {
                form(.full)
                form(.noPercent)
                form(.noNumbers)
                form(.glyphOnly)
            }
            .foregroundStyle(tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private func form(_ density: Density) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: compact ? 11 : 14, weight: .semibold))
                .opacity(inkOpacity)
            if density != .glyphOnly {
                if controllers.pads.count > 1 {
                    ForEach(Array(controllers.pads.enumerated()), id: \.element.id) { index, pad in
                        playerChip(number: index + 1, pad: pad, density: density)
                            .padding(.leading, index == 0 ? 0 : 4)
                    }
                } else if let level = controllers.batteryLevel {
                    battery(level, showsPercent: density == .full)
                }
            }
        }
        .fixedSize()
    }

    /// One player's number beside its pad's battery (a keyboard glyph for a
    /// keyboard player), as much of it as the form keeps.
    @ViewBuilder
    private func playerChip(number: Int, pad: ControllerManager.Pad, density: Density) -> some View {
        HStack(spacing: 4) {
            if density != .noNumbers {
                Text(verbatim: "\(number)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .opacity(inkOpacity)
            }
            if pad.kind == .keyboard {
                Image(systemName: "keyboard")
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .opacity(inkOpacity)
            } else if let level = pad.batteryLevel {
                battery(level, showsPercent: density == .full)
            } else if density == .noNumbers {
                // Nothing else to tell this player by: a small controller
                // glyph keeps the count of players readable.
                Image(systemName: "gamecontroller")
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                    .opacity(inkOpacity)
            }
        }
    }

    @ViewBuilder
    private func battery(_ level: Double, showsPercent: Bool) -> some View {
        BatteryGlyph(level: level, outline: tint, outlineOpacity: compact ? 0.9 : 0.8)
        if showsPercent {
            Text(Self.percentText(level))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var accessibilityText: String {
        let pads = controllers.pads
        guard pads.count > 1 else {
            var parts: [String] = []
            if let name = controllers.controllerName { parts.append(name) }
            if let level = controllers.batteryLevel { parts.append(Self.percentText(level)) }
            return parts.joined(separator: ", ")
        }
        return pads.enumerated().map { index, pad in
            var parts = [String(format: NSLocalizedString("controllers.player", comment: ""), index + 1)]
            if let name = pad.name { parts.append(name) }
            if let level = pad.batteryLevel { parts.append(Self.percentText(level)) }
            return parts.joined(separator: ", ")
        }.joined(separator: "; ")
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
