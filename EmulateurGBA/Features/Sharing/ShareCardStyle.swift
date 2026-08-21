//
//  ShareCardStyle.swift
//  EmulateurGBA
//
//  The visual style of the shareable cards. Stats card: always `.retroPal` (Classic).
//  Screenshot + clip cards: a PER-GAME choice (`choiceKey(forRom:)`) between the
//  console-dress looks and the classic neon card, mirroring the in-game skins:
//  `.nostalgia` (the Nostalgia console dress), `.skin` (the game's CURRENT skin —
//  offered only when that skin is Retro Pal or a user custom skin, and the default
//  then), and `.retroPal` ("Classic", the neon brand card). The choice is available
//  to EVERYONE, free or Pro — the Pro crown badge on the card is decoupled from the
//  style (it follows real Pro ownership, any style).
//

import UIKit
import SwiftUI

enum ShareCardStyle: String {
    case nostalgia
    case retroPal
    /// Mirror the game's in-game skin (Retro Pal or a custom palette). Only
    /// meaningful with a game context; resolves to `.nostalgia` without one.
    case skin

    /// Legacy global UserDefaults key — kept for surfaces with no game context
    /// (the Debug card previews). Real gameplay shares use the per-game key.
    static let choiceKey = "shareCardStyleChoice"

    /// The per-game UserDefaults key holding the user's EXPLICIT card-style choice
    /// for this game. Empty / absent = the default below applies.
    static func choiceKey(forRom romName: String) -> String {
        "shareCardStyleChoice_\(romName)"
    }

    /// The style actually used to render and share a card. `skinAvailable` = the
    /// game is currently dressed in Retro Pal or a custom skin: that skin is then
    /// both an offered option AND the default; without it the default is Nostalgia
    /// (and a stored `.skin` choice gracefully falls back to Nostalgia, e.g. after
    /// the custom skin was deleted or the game switched to Invisible).
    static func effective(choice: String, skinAvailable: Bool = false) -> ShareCardStyle {
        guard let chosen = ShareCardStyle(rawValue: choice) else {
            return skinAvailable ? .skin : .nostalgia
        }
        if chosen == .skin && !skinAvailable { return .nostalgia }
        return chosen
    }

    /// The IsometricCardPreview extruded-edge colours for a card rendered at this
    /// style, shared by the screenshot + RA share views: the console's body plastic
    /// for the dress styles (the per-console Nostalgia pairs, or the current skin's
    /// body), the purple brand edge for Classic / no game context.
    func extrudeEdgeColors(system: PresetSystem?,
                           skin: (variant: DressVariant, name: String)?) -> [Color] {
        if let system {
            if self == .skin, let skin {
                return skin.variant.cardExtrudeColors(for: system)
            }
            if self == .nostalgia {
                switch system {
                case .gbc:
                    return [Color(red: 0.66, green: 0.65, blue: 0.64), Color(red: 0.50, green: 0.49, blue: 0.48)]
                case .gba:
                    // The GBA main body purple (#7558EB), so the extruded 3D edge reads as the console body.
                    return [Color(red: 0.510, green: 0.410, blue: 0.950), Color(red: 0.380, green: 0.270, blue: 0.800)]
                case .nds:
                    // The NDS main body grey (#C4C4C4), so the extruded 3D edge reads as the console body.
                    return [Color(red: 0.820, green: 0.820, blue: 0.820), Color(red: 0.680, green: 0.680, blue: 0.680)]
                case .snes:
                    // The Super Nintendo's warm grey shell (#D7D3CF).
                    return [Color(red: 0.843, green: 0.827, blue: 0.812), Color(red: 0.700, green: 0.685, blue: 0.672)]
                case .nes:
                    // The NES's light grey shell (#D2D5DC).
                    return [Color(red: 0.824, green: 0.835, blue: 0.863), Color(red: 0.690, green: 0.700, blue: 0.727)]
                }
            }
        }
        return [Color(red: 0.22, green: 0.12, blue: 0.34), Color(red: 0.07, green: 0.04, blue: 0.13)]
    }
}

/// The game-specific skin context the screenshot + clip cards carry: the per-game
/// style key, plus the game's dress (+ its display name, used as the option label)
/// when that dress is Retro Pal or a custom skin — nil otherwise, where the cards
/// only offer Nostalgia / Classic.
struct ShareCardSkinContext {
    let styleKey: String
    let skin: (variant: DressVariant, name: String)?
    /// The game's EFFECTIVE display filter (Pro-gated), so the screenshot +
    /// clip cards bake exactly what the screen shows. `.none` without a game
    /// context.
    var filter: VideoFilter = .none

    /// No game context (Debug previews): the legacy global key, no skin option.
    static let none = ShareCardSkinContext(styleKey: ShareCardStyle.choiceKey, skin: nil)

    /// Rebuild a game's skin context OUTSIDE the emulator (the RA share surfaces),
    /// decoding the stored per-game skin exactly like `EmulatorViewController` does:
    /// the `skin_<rom>` key, the custom-skin lookup (a deleted palette falls back to
    /// no skin option), and an active control preset forcing the dress to Invisible.
    /// `romName` = the ROM filename without its extension.
    static func forRom(romName: String, system: PresetSystem) -> ShareCardSkinContext {
        let key = ShareCardStyle.choiceKey(forRom: romName)
        let filter = VideoFilter.effective(forRomBasename: romName)
        guard ControlLayoutStore.shared.activePreset(system: system) == nil else {
            return ShareCardSkinContext(styleKey: key, skin: nil, filter: filter)
        }
        switch SkinSelection.decode(UserDefaults.standard.string(forKey: "skin_\(romName)")) {
        case .builtin(.retroPal):
            return ShareCardSkinContext(styleKey: key, skin: (.retroPal, GameSkin.retroPal.displayName),
                                        filter: filter)
        case .custom(let id):
            guard let skin = CustomSkinStore.shared.skin(id: id, system: system) else {
                return ShareCardSkinContext(styleKey: key, skin: nil, filter: filter)
            }
            return ShareCardSkinContext(styleKey: key, skin: (.custom(skin.palette), skin.name),
                                        filter: filter)
        default:
            return ShareCardSkinContext(styleKey: key, skin: nil, filter: filter)
        }
    }
}

extension PresetSystem {
    /// The console for a ROM filename, by extension (the same mapping the emulator
    /// derives from its ROM type). nil for an unknown extension.
    static func forRomFilename(_ filename: String) -> PresetSystem? {
        switch (filename as NSString).pathExtension.lowercased() {
        case "gb", "gbc": return .gbc
        case "gba":       return .gba
        case "nds":        return .nds
        case "sfc", "smc": return .snes
        case "nes":        return .nes
        default:           return nil
        }
    }
}

extension UIColor {
    /// Perceived luminance (0…1) — the renderers use it to pick dark vs light info
    /// ink over a dress body (same weights as `rpContrastingMark`).
    var rpLuminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

// MARK: - Share-card colours derived from a dress variant

extension DressVariant {
    /// The console body ("fond") colour of this dress on `system` — what the share
    /// cards use to represent the skin (picker dot, 3/4-tilt extrude).
    func bodyColor(for system: PresetSystem) -> UIColor {
        switch self {
        case .nostalgia:
            switch system {
            case .gbc: return GBCSkinPalette.nostalgia.body
            case .gba: return GBASkinPalette.nostalgia.body
            case .nds: return NDSSkinPalette.nostalgia.body
            case .snes: return SNESSkinPalette.nostalgia.body
            case .nes: return NESSkinPalette.nostalgia.body
            }
        case .retroPal:
            switch system {
            case .gbc: return RetroPalPalette.gbcBody
            case .gba: return RetroPalPalette.gbaBody
            case .nds: return RetroPalPalette.ndsBody
            case .snes: return RetroPalPalette.snesBody
            case .nes: return RetroPalPalette.nesBody
            }
        case .custom(.gbc(let p)): return p.body
        case .custom(.gba(let p)): return p.body
        case .custom(.nds(let p)): return p.body
        case .custom(.snes(let p)): return p.body
        case .custom(.nes(let p)): return p.body
        }
    }

    /// The card's surrounding 3pt edge colour, following the dress exactly like the
    /// Nostalgia cards do: GB/GBC + GBA use the screen-surround colour; NDS uses its
    /// structure ink — #777777 for both built-ins (the Retro Pal draft leaves the
    /// NDS ink untouched), body −39% luma for a custom body (NintendoDSSkin.ink).
    func cardEdgeColor(for system: PresetSystem) -> UIColor {
        switch system {
        case .nes:
            switch self {
            case .nostalgia:           return NESSkinPalette.nostalgia.surround
            case .retroPal:            return RetroPalPalette.nesSurround
            case .custom(.nes(let p)): return p.surround
            case .custom:              return NESSkinPalette.nostalgia.surround
            }
        case .snes:
            switch self {
            case .nostalgia:            return SNESSkinPalette.nostalgia.surround
            case .retroPal:             return RetroPalPalette.snesSurround
            case .custom(.snes(let p)): return p.surround
            case .custom:               return SNESSkinPalette.nostalgia.surround
            }
        case .gbc:
            switch self {
            case .nostalgia:           return GBCSkinPalette.nostalgia.surround
            case .retroPal:            return RetroPalPalette.gbcSurround
            case .custom(.gbc(let p)): return p.surround
            case .custom:              return GBCSkinPalette.nostalgia.surround
            }
        case .gba:
            switch self {
            case .nostalgia:           return GBASkinPalette.nostalgia.surround
            case .retroPal:            return RetroPalPalette.gbaSurround
            case .custom(.gba(let p)): return p.surround
            case .custom:              return GBASkinPalette.nostalgia.surround
            }
        case .nds:
            switch self {
            case .nostalgia, .retroPal: return UIColor(rpHex: 0x777777)
            case .custom(.nds(let p)):  return p.body.rpMixed(with: .black, 0.39)
            case .custom:               return UIColor(rpHex: 0x777777)
            }
        }
    }

    /// The two-tone faux-thickness extrude colours for the 3/4 card-preview tilt,
    /// derived from the body like the dress's own gradient (lighter top, darker
    /// bottom) so the edge reads as that console's plastic.
    func cardExtrudeColors(for system: PresetSystem) -> [Color] {
        let g = RetroPalPalette.bodyGradient(bodyColor(for: system))
        return [Color(g.top), Color(g.bottom)]
    }

    /// Stable identity for the rendered-console cache (a custom palette is keyed by
    /// its colour values, so editing a skin never serves a stale snapshot).
    var cacheKey: String {
        func hexes(_ values: [UInt32]) -> String {
            values.map { String($0, radix: 16) }.joined(separator: "-")
        }
        switch self {
        case .nostalgia: return "nostalgia"
        case .retroPal:  return "retroPal"
        case .custom(.gbc(let p)):
            return "custom-" + hexes([p.bodyHex, p.surroundHex, p.dpadHex, p.abButtonsHex,
                                      p.abLettersHex, p.smallButtonsHex, p.menuIconsHex,
                                      p.labelsHex, p.stripeHex, p.printedTextHex, p.ledHex])
        case .custom(.gba(let p)):
            return "custom-" + hexes([p.bodyHex, p.surroundHex, p.buttonsHex, p.lettersHex,
                                      p.menuButtonsHex, p.menuIconsHex, p.ledHex])
        case .custom(.nds(let p)):
            return "custom-" + hexes([p.bodyHex, p.buttonsHex, p.lettersHex, p.iconsHex, p.ledHex])
        case .custom(.snes(let p)):
            return "custom-snes-" + hexes([p.bodyHex, p.surroundHex, p.padHex,
                                           p.faceAHex, p.faceBHex, p.faceXHex, p.faceYHex])
        case .custom(.nes(let p)):
            return "custom-nes-" + hexes([p.bodyHex, p.surroundHex, p.padHex, p.faceHex])
        }
    }
}
