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
        default: return Color(red: 0.463, green: 0.149, blue: 0.773) // GBA = app-logo purple #7626C5
        }
    }
}
