//
//  ControllerPlayerRow.swift
//  EmulateurGBA
//
//  One connected controller in Settings' Players list: its player number, its
//  name and battery, and two arrows that move it up or down the order. Shown
//  only while two controllers or more are connected (a single controller is
//  always player 1 and has nothing to reorder).
//
//  Two identical pads carry the same name, so a name alone cannot say which
//  row is the pad in your hands: the row lights up for a moment whenever that
//  controller presses a button (`ControllerManager.padActivity`).
//

import SwiftUI

struct ControllerPlayerRow: View {
    let pad: ControllerManager.Pad
    /// 0-based player index, which is the pad's place in the order.
    let index: Int
    let playerCount: Int

    @State private var lit = false

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(index + 1)")
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: NSLocalizedString("controllers.player", comment: ""), index + 1))
                    .font(.subheadline.weight(.semibold))
                Text(pad.name ?? NSLocalizedString("guide.controller.genericName", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let level = pad.batteryLevel {
                    HStack(spacing: 6) {
                        BatteryGlyph(level: level, outline: .secondary, outlineOpacity: 1)
                        Text(ControllerStatusBadge.percentText(level))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            moveButton(systemImage: "chevron.up",
                       labelKey: "controllers.moveUp",
                       to: index - 1,
                       enabled: index > 0)
            moveButton(systemImage: "chevron.down",
                       labelKey: "controllers.moveDown",
                       to: index + 1,
                       enabled: index < playerCount - 1)
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(lit ? 0.22 : 0))
                .padding(.horizontal, -8)
        )
        .onReceive(ControllerManager.shared.padActivity) { id in
            guard id == pad.id else { return }
            withAnimation(.easeOut(duration: 0.12)) { lit = true }
            // A separate change, later: set in the same pass, the two values
            // would cancel out and nothing would light.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeIn(duration: 0.45)) { lit = false }
            }
        }
    }

    private func moveButton(systemImage: String, labelKey: String, to target: Int, enabled: Bool) -> some View {
        // Reachable with a controller too: player 1 can hand player 1 to
        // another pad without touching the screen.
        FocusableButton(shape: .capsule) {
            withAnimation(.easeInOut(duration: 0.2)) {
                ControllerManager.shared.movePad(pad.id, toPlayer: target)
            }
            Haptics.tap()
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        // Borderless, so each arrow is its own target inside the List row
        // instead of the whole row acting as one button.
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .accessibilityLabel(NSLocalizedString(labelKey, comment: ""))
    }
}
