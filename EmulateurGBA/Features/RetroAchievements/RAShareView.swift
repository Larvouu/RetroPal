//
//  RAShareView.swift
//  EmulateurGBA
//
//  Presents the shareable RetroAchievements card for one earned achievement,
//  harmonized with the screenshot / clip cards: loads the badge + box art
//  (from rc_client URLs), renders the console-dress card via
//  RAAchievementCardRenderer, and hands it to the shared RAShareScaffold with
//  the per-game CardStylePicker (current skin / Nostalgia / Classic — the
//  SAME per-game choice the screenshot + clip cards share). `romFilename`
//  resolves the game's console + stored skin; nil (game no longer in the
//  library, or an RA-unsupported console) falls back to the Classic card
//  with no picker.
//

import SwiftUI

struct RAShareView: View {
    let achievement: RAAchievementInfo
    /// The OFFICIAL RA set name (never the library rename).
    let gameName: String
    let boxArtURL: URL?
    let onClose: () -> Void

    /// The game's console (nil = Classic-only card, no style picker).
    private let system: PresetSystem?
    /// Per-game style key + current dress, resolved from `romFilename`.
    private let skinContext: ShareCardSkinContext

    @AppStorage("isPro") private var isPro = false
    @AppStorage private var styleChoice: String
    @State private var badge: UIImage?
    @State private var boxArt: UIImage?
    @State private var imagesLoaded = false
    @State private var cardImage: UIImage?

    init(achievement: RAAchievementInfo, gameName: String, boxArtURL: URL?,
         romFilename: String? = nil, onClose: @escaping () -> Void) {
        self.achievement = achievement
        self.gameName = gameName
        self.boxArtURL = boxArtURL
        self.onClose = onClose
        // Every console gets its console-skin styles (NDS composes the
        // dual-screen pair); an unknown game falls back to the Classic card.
        if let romFilename,
           let sys = PresetSystem.forRomFilename(romFilename) {
            self.system = sys
            self.skinContext = .forRom(romName: (romFilename as NSString).deletingPathExtension,
                                       system: sys)
        } else {
            self.system = nil
            self.skinContext = .none
        }
        _styleChoice = AppStorage(wrappedValue: "", skinContext.styleKey)
    }

    /// Classic when the game is unknown; otherwise the per-game choice with the
    /// screenshot card's defaults (current skin when dressed, else Nostalgia).
    private var effectiveStyle: ShareCardStyle {
        guard system != nil else { return .retroPal }
        return ShareCardStyle.effective(choice: styleChoice, skinAvailable: skinContext.skin != nil)
    }

    /// The faux-thickness edge colours for the 3/4 preview tilt (shared with the
    /// screenshot card): the console's body plastic for the dress styles, the
    /// purple brand edge for Classic.
    private var cardEdgeColors: [Color] {
        effectiveStyle.extrudeEdgeColors(system: system, skin: skinContext.skin)
    }

    var body: some View {
        RAShareScaffold(cardImage: cardImage,
                        shareFilename: "retropal-achievement",
                        cardType: "achievement",
                        edgeColors: cardEdgeColors,
                        onClose: onClose) {
            if let system {
                CardStylePicker(styleKey: skinContext.styleKey,
                                skinOption: skinContext.skin.map {
                                    ($0.name, $0.variant.bodyColor(for: system))
                                })
            }
        }
        .task { await loadAndRender() }
        // Re-render when the style changes (picker toggled, images already loaded).
        .onChange(of: effectiveStyle) { _ in renderCard() }
    }

    @MainActor private func loadAndRender() async {
        guard !imagesLoaded else { return }
        badge = await UIImage.loaded(from: achievement.badgeURL.flatMap(URL.init(string:)))
        boxArt = await UIImage.loaded(from: boxArtURL)
        imagesLoaded = true
        renderCard()
    }

    @MainActor private func renderCard() {
        guard imagesLoaded else { return }
        let content = RAAchievementCardRenderer.Content(
            badge: badge, boxArt: boxArt,
            title: achievement.title, detail: achievement.detail,
            points: achievement.points, rarity: achievement.rarity,
            gameName: gameName, isPro: isPro)
        cardImage = RAAchievementCardRenderer.render(content: content,
                                                     style: effectiveStyle,
                                                     system: system,
                                                     skinVariant: skinContext.skin?.variant)
    }
}

extension UIImage {
    /// Fetch an image for card rendering (AsyncImage can't render into an
    /// ImageRenderer snapshot). nil on any failure — cards degrade gracefully.
    static func loaded(from url: URL?) async -> UIImage? {
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}
