//
//  BadgeGalleryView.swift
//  EmulateurGBA
//
//  DEBUG-only gallery of the share-card badge (now just the Pro crown), with how
//  it is unlocked. Reachable from Settings ▸ Debug ▸ Screenshot badges. The crown
//  is rendered by ScreenshotCardRenderer.proCrownBadgeImage — the exact same
//  drawing path as the share cards — so what you see here matches the real cards.
//

#if DEBUG
import SwiftUI

struct BadgeGalleryView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let image: UIImage
        let unlock: String
    }

    private var items: [Item] {
        [
            Item(image: ScreenshotCardRenderer.proCrownBadgeImage(side: 56),
                 unlock: "Retro Pal Pro enabled"),
        ]
    }

    var body: some View {
        List {
            Section {
                ForEach(items) { item in
                    HStack(spacing: 14) {
                        Image(uiImage: item.image)
                        Spacer()
                        Text(item.unlock)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    // Card-like dark backdrop so the translucent Pro glow reads
                    // the same way it does on the share card.
                    .listRowBackground(Color(red: 0.08, green: 0.05, blue: 0.14))
                }
            } footer: {
                Text("The Pro crown badge appears on the share cards and the Settings Pro row when Retro Pal Pro is enabled.")
            }
        }
        .navigationTitle("Screenshot badges")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
