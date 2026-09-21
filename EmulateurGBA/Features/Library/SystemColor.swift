//
//  SystemColor.swift
//  EmulateurGBA
//

import SwiftUI

/// Single source of truth for each console's color, shared by the library
/// system badges (the GBA/GB/GBC/NDS tags) and the stats console bars, so a
/// console's tag and its bar always match.
enum SystemColor {
    static func color(_ systemType: String?) -> Color {
        switch systemType {
        case "nds": return .blue
        case "gbc": return .green
        case "gb": return .gray
        // The two 1.2.5 consoles need their own colours rather than falling
        // through to GBA's purple, which is what `default` would have done and
        // would have made three consoles share one badge.
        case "snes": return Color(red: 0.408, green: 0.310, blue: 0.643)   // #685098, the SNES lilac
        case "nes":  return Color(red: 0.804, green: 0.129, blue: 0.161)   // #CD2129, the NES red stripe
        // The PlayStation's own grey, from the console rather than from the
        // logo: the four coloured symbols are the brand, but a single badge can
        // only be one colour and picking one of the four would name a button.
        case "ps1":  return Color(red: 0.451, green: 0.463, blue: 0.494)   // #737685
        default: return Color(red: 0.463, green: 0.149, blue: 0.773) // GBA = app-logo purple #7626C5
        }
    }

    /// The console's name for a menu or a caption. Proper names, unlocalized
    /// like the theme names. The canonical order is `LibraryView`'s.
    static func name(_ systemType: String) -> String {
        switch systemType {
        case "gb":   return "Game Boy"
        case "gbc":  return "Game Boy Color"
        case "nds":  return "Nintendo DS"
        case "snes": return "Super Nintendo"
        case "nes":  return "NES"
        case "ps1":  return "PlayStation"
        default:     return "Game Boy Advance"
        }
    }
}

/// The small console tag of the library rows: "GBA" on the console's colour
/// on the List, and in a look (2026-09-07) the console's own drawing, the
/// one the rack's covers wear in their corner, bare, no pill, at the same
/// place beside the title. Shared with the upright hero.
struct ConsoleTagBadge: View {
    let systemType: String
    /// The drawing instead of the lettered pill.
    var drawing: Bool = false

    var body: some View {
        if drawing {
            Image("console-\(systemType)")
                .resizable()
                .scaledToFit()
                .frame(height: 12)
                .accessibilityLabel(SystemColor.name(systemType))
        } else {
            Text(systemType.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(SystemColor.color(systemType))
                .cornerRadius(4)
        }
    }
}
