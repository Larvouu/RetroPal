//
//  CardStylePicker.swift
//  EmulateurGBA
//
//  The card-style picker shared by the screenshot + clip cards. Available to
//  everyone (not Pro-gated). Two or three radio dots styled like the card itself:
//  when the game is dressed in Retro Pal or a custom skin, that skin leads (its
//  dot filled with the skin's body colour, its name as the label) and is the
//  default; Nostalgia (warm gold→purple edge mirroring its card) and Classic
//  (solid brand purple) follow. Tapping writes the PER-GAME `styleKey`; each share
//  view observes that key (via its own effectiveStyle) and re-renders its card.
//  Labels: the skin option shows the skin's own name; the built-ins are localized
//  (card.style.nostalgia / card.style.classic — ".retroPal" is shown as "Classic").
//

import SwiftUI

struct CardStylePicker: View {
    /// The per-game (or legacy global) UserDefaults key holding the choice.
    private let styleKey: String
    /// The game's current skin, when it is Retro Pal / custom: option label + the
    /// dot's fill colour (the skin's body). nil = only Nostalgia / Classic.
    private let skinOption: (name: String, color: UIColor)?
    @AppStorage private var styleChoice: String

    init(styleKey: String = ShareCardStyle.choiceKey,
         skinOption: (name: String, color: UIColor)? = nil) {
        self.styleKey = styleKey
        self.skinOption = skinOption
        _styleChoice = AppStorage(wrappedValue: "", styleKey)
    }

    private var effective: ShareCardStyle {
        ShareCardStyle.effective(choice: styleChoice, skinAvailable: skinOption != nil)
    }

    var body: some View {
        HStack(spacing: skinOption != nil ? 20 : 28) {
            if let skinOption {
                option(.skin, skinOption.name)
            }
            option(.nostalgia, NSLocalizedString("card.style.nostalgia", value: "Nostalgia", comment: "Share card style option"))
            option(.retroPal, NSLocalizedString("card.style.classic", value: "Classic", comment: "Share card style option"))
        }
        .padding(.top, 6)
    }

    private func option(_ style: ShareCardStyle, _ title: String) -> some View {
        let selected = effective == style
        return HStack(spacing: 7) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                    .opacity(selected ? 1 : 0)
                dot(style)
                    .frame(width: 15, height: 15)
            }
            .frame(width: 26, height: 26)
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.6))
        }
        .contentShape(Rectangle())
        .onTapGesture { styleChoice = style.rawValue }
        .animation(.easeInOut(duration: 0.15), value: selected)
    }

    /// The filled style dot: the skin option wears the skin's body colour (with a
    /// faint ring so a dark body stays visible on the dark sheet); Nostalgia and
    /// Classic keep the card purple, plus the gold→purple edge ring on Nostalgia
    /// (mirroring that card's gold edge).
    @ViewBuilder
    private func dot(_ style: ShareCardStyle) -> some View {
        let purple = Color(red: 0.45, green: 0.2, blue: 0.85)
        let gold = Color(red: 1.0, green: 0.84, blue: 0.35)
        if style == .skin, let skinOption {
            Circle()
                .fill(Color(skinOption.color))
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                }
        } else {
            Circle()
                .fill(purple)
                .overlay {
                    if style == .nostalgia {
                        Circle().strokeBorder(
                            LinearGradient(colors: [gold, purple],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 2.5)
                    }
                }
        }
    }
}
