//
//  GameSkin.swift
//  EmulateurGBA
//
//  The per-game on-screen "skin" the player picks in the in-game menu (Skin button).
//  The CHOICE is stored per game; the dressed look within `.nostalgia` / `.retroPal`
//  follows that game's console (GB/GBC, GBA, NDS) via the existing ConsoleSkinView +
//  TouchControlsView.setDressed path. Persisted in UserDefaults under `skin_<romName>`,
//  matching the other per-game prefs (speed / orientation / hold-to-lock).
//
//  Default = .nostalgia: the dressed console look every supported system has shown by
//  default since the console-dress shipped, so existing games keep their current look.
//
//  Constraint (see EmulatorViewController.effectiveSkin): when a custom control preset
//  is active for a console, that whole console is restricted to .invisible, because the
//  console-body decorations are positioned around the DEFAULT button frames and can't
//  track a custom layout.
//

import Foundation

enum GameSkin: String, CaseIterable {
    /// The console dress (body + dressed controls) — the current default look.
    case nostalgia
    /// No dress: the translucent controls / hitboxes only, for an "invisible emulator".
    case invisible
    /// The Retro Pal house look: the console dress worn in the brand palette, unique
    /// per console (RetroPalPalette: GBC gold #FFDF60 body, GBA near-black #050505, NDS
    /// slate #595A76), applied via DressVariant.retroPal -> RetroPalPalette.
    case retroPal

    /// Fixed, brand-style display names — intentionally NOT localized (per the product
    /// decision). "Retro Pal" is the brand; "Nostalgia"/"Invisible" are kept as labels.
    var displayName: String {
        switch self {
        case .nostalgia: return "Nostalgia"
        case .invisible: return "Invisible"
        case .retroPal:  return "Retro Pal"
        }
    }

    /// Whether this skin shows the console dress (body + dressed controls). Only
    /// `.invisible` is undressed.
    var isDressed: Bool { self != .invisible }

    /// The order shown in the picker + the debug gallery (the two dressed skins together,
    /// Invisible last).
    static let pickerOrder: [GameSkin] = [.nostalgia, .retroPal, .invisible]

    /// Tolerant decode for the stored value, defaulting to `.nostalgia`.
    static func stored(_ raw: String?) -> GameSkin {
        GameSkin(rawValue: raw ?? "") ?? .nostalgia
    }
}
