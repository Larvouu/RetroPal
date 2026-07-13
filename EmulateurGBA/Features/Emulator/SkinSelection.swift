//
//  SkinSelection.swift
//  EmulateurGBA
//
//  What a game's `skin_<rom>` UserDefaults key stores: either one of the built-in skins
//  (Nostalgia / Retro Pal / Invisible) or a user CUSTOM skin referenced by id. It serialises to a
//  single string so it drops straight into the existing per-game slot:
//
//      "nostalgia" | "retroPal" | "invisible" | "custom:<uuid>"
//
//  The three legacy built-in raw values decode unchanged, so every game saved before custom skins
//  existed keeps its choice — fully backward compatible.
//

import Foundation

enum SkinSelection: Equatable {
    case builtin(GameSkin)
    case custom(UUID)

    /// The string written to the per-game `skin_<rom>` key.
    var serialized: String {
        switch self {
        case .builtin(let skin): return skin.rawValue
        case .custom(let id):    return "custom:\(id.uuidString)"
        }
    }

    /// Tolerant decode of the stored value. Unknown / nil → Nostalgia (matches `GameSkin.stored`).
    static func decode(_ raw: String?) -> SkinSelection {
        guard let raw else { return .builtin(.nostalgia) }
        if raw.hasPrefix("custom:"),
           let id = UUID(uuidString: String(raw.dropFirst("custom:".count))) {
            return .custom(id)
        }
        return .builtin(GameSkin.stored(raw))
    }

    /// Whether this selection shows the console dress (body + dressed controls). Custom skins
    /// always do; for built-ins it tracks `GameSkin.isDressed` (only Invisible is undressed).
    var isDressed: Bool {
        switch self {
        case .builtin(let skin): return skin.isDressed
        case .custom:            return true
        }
    }
}
