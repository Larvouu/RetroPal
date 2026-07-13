//
//  SkinPreviewGallery.swift
//  EmulateurGBA
//
//  DEBUG-only gallery (Settings ▸ Debug ▸ Skin preview): for each console it shows portrait and
//  landscape, with the three skins (Nostalgia / Invisible / Retro Pal) side by side, rendered by
//  the REAL SkinPreviewView. The verification surface for the Retro Pal recolour — no game needed.
//

#if DEBUG
import SwiftUI

struct SkinPreviewGallery: View {
    private let portrait = CGSize(width: 440, height: 956)              // iPhone 16 Pro Max
    private let portraitInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    private let landscapeLeading: CGFloat = 59                          // Dynamic Island side

    private let systems: [(system: PresetSystem, name: String)] =
        [(.gba, "GBA"), (.gbc, "GB/GBC"), (.nds, "NDS")]
    private let skins = GameSkin.pickerOrder

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(systems, id: \.name) { entry in
                        ForEach([false, true], id: \.self) { landscape in
                            section(system: entry.system, name: entry.name,
                                    landscape: landscape, available: geo.size.width - 32)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Skin preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(system: PresetSystem, name: String,
                         landscape: Bool, available: CGFloat) -> some View {
        let dev = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
        let insets = landscape
            ? UIEdgeInsets(top: 0, left: landscapeLeading, bottom: 0, right: 0)
            : portraitInsets

        VStack(alignment: .leading, spacing: 8) {
            Text("\(name) · \(landscape ? "landscape" : "portrait")")
                .font(.caption).foregroundStyle(.secondary)

            if landscape {
                // Landscape phones are wide; stack them full-width so colours stay legible.
                VStack(spacing: 12) {
                    ForEach(skins, id: \.self) { skin in
                        labelled(skin) { tile(system, skin, landscape, dev, insets, width: available) }
                    }
                }
            } else {
                // Portrait: the three skins side by side.
                let spacing: CGFloat = 10
                let cardW = max(1, (available - spacing * 2) / 3)
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(skins, id: \.self) { skin in
                        labelled(skin) { tile(system, skin, landscape, dev, insets, width: cardW) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func labelled<Content: View>(_ skin: GameSkin,
                                         @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 4) {
            content()
            Text(skin.displayName).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func tile(_ system: PresetSystem, _ skin: GameSkin, _ landscape: Bool,
                      _ dev: CGSize, _ insets: UIEdgeInsets, width: CGFloat) -> some View {
        let scale = width / dev.width
        return SkinPreviewRepresentable(system: system, skin: skin, isLandscape: landscape,
                                        safeInsets: insets, gameImage: nil)
            .frame(width: dev.width, height: dev.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: width, height: dev.height * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.15)))
    }
}
#endif
