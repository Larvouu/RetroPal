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
        default: return Color(red: 0.463, green: 0.149, blue: 0.773) // GBA = app-logo purple #7626C5
        }
    }
}
