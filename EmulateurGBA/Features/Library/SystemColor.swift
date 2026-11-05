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
        // INTERIM neutral charcoal until the N64's palette is chosen: a console
        // badge colour follows the console's dress, which does not exist yet.
        case "n64":  return Color(red: 0.180, green: 0.180, blue: 0.192)   // #2E2E31
        // INTERIM, as the Nintendo 64's was: a navy of its own until the
        // Mega Drive's dress gives the badge its colour. The console's black
        // would vanish on the app's dark grounds, and red is the NES's.
        case "md":   return Color(red: 0.169, green: 0.227, blue: 0.333)   // #2B3A55
        // INTERIM too, until their dresses: the Master System's red (its
        // logo's, the badge needs one colour the app's dark grounds keep) is
        // darker than the NES's so the two badges cannot be read as one; the
        // Game Gear's is a slate of its own, the handheld's black being as
        // invisible on those grounds as the Mega Drive's.
        case "sms":  return Color(red: 0.612, green: 0.102, blue: 0.122)   // #9C1A1F
        case "gg":   return Color(red: 0.239, green: 0.278, blue: 0.333)   // #3D4755
        // INTERIM as well, until the PSP's dress: its black would vanish on the
        // app's dark grounds like the Mega Drive's, and the PlayStation's grey is
        // taken, so a blue of its own, lighter than the Mega Drive's navy.
        case "psp":  return Color(red: 0.122, green: 0.290, blue: 0.561)   // #1F4A8F
        // INTERIM, until the 3DS's dress: the original console's Aqua Blue,
        // darkened so the badge's white letters read on it (#0E7C9B), and kept
        // clear of the PSP's blue and the DS's.
        case "n3ds": return Color(red: 0.055, green: 0.486, blue: 0.608)   // #0E7C9B
        default: return Color(red: 0.463, green: 0.149, blue: 0.773) // GBA = app-logo purple #7626C5
        }
    }

    /// The console's colour in a chart (the Retro story's consoles donut,
    /// 2026-10-28). Each console keeps its own colour's hue (`color(_:)`),
    /// made vivid for the dark grounds (his ask: bright, not dull); the three
    /// greys of the badges, which have no hue, take their console's (the Game
    /// Boy's screen, the PlayStation's and the Nintendo 64's logos). Not the
    /// badges' colours themselves: greys and navies there vanish on the dark
    /// grounds and read as one. Thirteen vivid colours cannot all be told
    /// apart (checked with the data-viz validator: contrast >= 3:1 on every
    /// look, Classic's black included; the Game Boy family, the group most
    /// played together, separates; a few rarer pairs stay close), so the
    /// legend beside the ring says each console by its drawing and name.
    static func chartColor(_ systemType: String) -> Color {
        let hex: UInt32
        switch systemType {
        case "gba":  hex = 0xA968FF   // purple
        case "gb":   hex = 0xCCCD27   // olive-yellow, the DMG screen
        case "gbc":  hex = 0x00C55B   // green
        case "nds":  hex = 0xFA7C20   // orange
        case "snes": hex = 0xE369CC   // lilac-pink, its buttons
        case "nes":  hex = 0xF14445   // red
        case "ps1":  hex = 0xF7C243   // yellow, its logo
        case "n64":  hex = 0x00C7AE   // teal, its logo
        case "md":   hex = 0xB6AAFF   // lavender
        case "sms":  hex = 0xEE5E23   // orange-red
        case "gg":   hex = 0x0093D0   // cyan-blue
        case "psp":  hex = 0x3A74E3   // deep blue
        case "n3ds": hex = 0x17D0D8   // aqua
        default:     hex = 0xA968FF
        }
        return Color(red: Double((hex >> 16) & 0xFF) / 255,
                     green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }

    /// The folded rest of a chart: a neutral grey, never a hue.
    static let chartOther = Color(white: 0.45)

    /// The console's name for a menu or a caption. Proper names, unlocalized
    /// like the theme names. The canonical order is `LibraryView`'s.
    /// The asset name of a console's drawing (`console-<system>`).
    static func drawingAsset(_ systemType: String) -> String {
        "console-" + systemType
    }

    /// Whether that drawing exists. A console added before its drawing (the
    /// PSP, 2026-10-09) has none, and every place that draws one shows the
    /// lettered pill instead (`ConsoleMark`): never another console's machine,
    /// which is what borrowing the PlayStation's looked like on device.
    static func hasDrawing(_ systemType: String) -> Bool {
        UIImage(named: drawingAsset(systemType)) != nil
    }

    static func name(_ systemType: String) -> String {
        switch systemType {
        case "gb":   return "Game Boy"
        case "gbc":  return "Game Boy Color"
        case "nds":  return "Nintendo DS"
        case "snes": return "Super Nintendo"
        case "nes":  return "NES"
        case "ps1":  return "PlayStation"
        case "n64":  return "Nintendo 64"
        // The one console whose name is not the same word everywhere: the
        // name it was sold under differs by market (Genesis in the Americas),
        // so it is the one localized entry here.
        case "md":   return NSLocalizedString("console.name.md", comment: "The Mega Drive's name as sold in this market")
        // One word in every market, as Nintendo 64 is: Sega sold both under
        // these names everywhere (Japan's マスターシステム and ゲームギア are the
        // same names written in katakana, and the stores list them in Latin
        // letters), so they are not localized.
        case "sms":  return "Master System"
        case "gg":   return "Game Gear"
        // The name it was sold under everywhere, in Latin letters in Japan too.
        case "psp":  return "PSP"
        // One name everywhere, in Latin letters in Japan too (ニンテンドー3DS
        // is written with them on the box and in the stores).
        case "n3ds": return "Nintendo 3DS"
        default:     return "Game Boy Advance"
        }
    }

    /// The lettered tag's text: the stored system type in capitals, except
    /// where that is not the console's short name. "N3DS" reads as the New
    /// Nintendo 3DS, a different model; the console is "3DS".
    static func tag(_ systemType: String) -> String {
        systemType == "n3ds" ? "3DS" : systemType.uppercased()
    }
}

/// The small console tag of the library rows: the console's own drawing, the
/// one the rack's covers wear in their corner, bare, no pill, beside the
/// title (2026-09-07 in the looks; in every look since 2026-10-28, when the
/// Classic List and its lettered "GBA" tag went). Shared with the upright
/// hero. The lettered pill stands in only for a console with no drawing.
struct ConsoleTagBadge: View {
    let systemType: String

    var body: some View {
        if SystemColor.hasDrawing(systemType) {
            Image(SystemColor.drawingAsset(systemType))
                .resizable()
                .scaledToFit()
                .frame(height: 12)
                .accessibilityLabel(SystemColor.name(systemType))
        } else {
            ConsolePill(systemType: systemType)
        }
    }
}

/// The lettered console tag ("GBA" on the console's colour): the List's badge,
/// and the stand-in wherever a console's drawing does not exist yet.
struct ConsolePill: View {
    let systemType: String

    var body: some View {
        Text(SystemColor.tag(systemType))
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(SystemColor.color(systemType))
            .cornerRadius(4)
            .accessibilityLabel(SystemColor.name(systemType))
    }
}

/// A console's drawing at a given size, or its lettered pill when the drawing
/// does not exist yet (`SystemColor.hasDrawing`). The places that draw a
/// console from a stored system type use this, so a console added before its
/// art shows its own name, never a blank and never another machine.
struct ConsoleMark: View {
    let systemType: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if SystemColor.hasDrawing(systemType) {
            Image(SystemColor.drawingAsset(systemType))
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
        } else {
            ConsolePill(systemType: systemType)
                .frame(minWidth: width, minHeight: height)
        }
    }
}
