//
//  ConsoleIconRow.swift
//  EmulateurGBA
//
//  The six supported consoles as small pixel-art icons with their names,
//  shown in the empty-library onboarding. The first four are ported 1:1 —
//  coordinates AND palette — from the website's ConsoleIcon.astro (the systems
//  strip on retropal.fr), so the onboarding and the site read as one family:
//  the grey DMG, the purple GBC, the indigo GBA with its shoulders, and the
//  cream DS clamshell, all with the DMG-green screens.
//
//  The Super Nintendo and the NES join them from `Store/components/console-*.svg`,
//  the same drawings the Appearance button wears, in the same coordinates. They
//  are the only two here that are not handhelds, so each is drawn as its machine
//  with its pad below it — which is also what keeps them from reading as one
//  more grey slab beside the DMG.
//

import SwiftUI

/// Two rows of three: GB · GBC · GBA, then NDS · NES · SNES. Columns take their
/// LABEL's natural width (equal-width columns truncated "GAME BOY ADVANCE"); the
/// spacers distribute what's left, and `fixedSize` makes truncation impossible —
/// every name renders whole, all at one size.
///
/// Two rows rather than one of six: at six columns the labels either wrap or
/// shrink, and the icon size is what makes these read as consoles at all.
struct ConsoleIconRow: View {
    var body: some View {
        VStack(spacing: 14) {
            row([.gb, .gbc, .gba])
            row([.nds, .nes, .snes])
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ consoles: [PixelConsole]) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(consoles.enumerated()), id: \.offset) { index, console in
                if index > 0 { Spacer(minLength: 8) }
                item(console)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func item(_ console: PixelConsole) -> some View {
        VStack(spacing: 5) {
            PixelConsoleIcon(console: console)
                .frame(height: 36)
            Text(console.label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

enum PixelConsole {
    case gb, gbc, gba, nds, nes, snes

    var label: String {
        switch self {
        case .gb:   return "Game Boy"
        case .gbc:  return "Game Boy Color"
        case .gba:  return "Game Boy Advance"
        case .nds:  return "Nintendo DS"
        case .nes:  return "NES"
        case .snes: return "Super Nintendo"
        }
    }

    /// The source SVG's viewBox (the drawing coordinates below live in it). The two
    /// desktop machines are their drawing's own bounding box, so they fill the same
    /// 36pt height as the handhelds instead of floating in a padded square.
    var viewBox: CGSize {
        switch self {
        case .gb, .gbc: return CGSize(width: 64, height: 80)
        case .gba:      return CGSize(width: 90, height: 64)
        case .nds:      return CGSize(width: 80, height: 80)
        case .snes:     return CGSize(width: 92, height: 64)
        case .nes:      return CGSize(width: 92, height: 60)
        }
    }
}

/// Canvas rendition of one website console icon, aspect-fitted + centered.
struct PixelConsoleIcon: View {
    let console: PixelConsole

    // The website palette, verbatim.
    private static let ink = Color(red: 0x1A / 255, green: 0x18 / 255, blue: 0x14 / 255)
    private static let screen = Color(red: 0x9B / 255, green: 0xBC / 255, blue: 0x0F / 255)
    private static let red = Color(red: 0xC8 / 255, green: 0x36 / 255, blue: 0x2D / 255)
    private static let gbBody = Color(red: 0xA8 / 255, green: 0xAE / 255, blue: 0xB8 / 255)
    private static let gbcBody = Color(red: 0x72 / 255, green: 0x33 / 255, blue: 0xD9 / 255)
    private static let gbaBody = Color(red: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255)
    private static let ndsBody = Color(red: 0xE8 / 255, green: 0xE2 / 255, blue: 0xD2 / 255)
    // The two machines, from their own SVGs. The Super Nintendo's accent band is the
    // Game Boy Color's purple on purpose, so the six read as one set.
    private static let snesBody = Color(red: 0xC9 / 255, green: 0xCB / 255, blue: 0xD4 / 255)
    private static let snesTop = Color(red: 0xDD / 255, green: 0xE0 / 255, blue: 0xE7 / 255)
    private static let nesBody = Color(red: 0xB9 / 255, green: 0xBC / 255, blue: 0xC6 / 255)
    private static let nesTop = Color(red: 0xD2 / 255, green: 0xD5 / 255, blue: 0xDC / 255)
    private static let nesFlap = Color(red: 0x3A / 255, green: 0x35 / 255, blue: 0x50 / 255)
    private static let nesWell = Color(red: 0x8A / 255, green: 0x8F / 255, blue: 0x9C / 255)
    // The Super Nintendo's four face buttons and both new pads' near-black are the
    // DRESS's own values (2026-08-17), not the website palette the four handhelds
    // above still follow. Within the app these two drawings have to agree with the
    // console the emulator paints around the running game, and with the same art
    // in the What's New sheet; the handhelds' palette is a website question and is
    // settled with the website.
    private static let faceBlue = Color(red: 0x29 / 255, green: 0x40 / 255, blue: 0x91 / 255)
    private static let faceGreen = Color(red: 0x36 / 255, green: 0x68 / 255, blue: 0x40 / 255)
    private static let faceRed = Color(red: 0xCF / 255, green: 0x35 / 255, blue: 0x2E / 255)
    private static let faceYellow = Color(red: 0xEF / 255, green: 0xC4 / 255, blue: 0x46 / 255)
    /// The pads' controls: cross, pills, printed marks. Distinct from `ink`, which
    /// outlines the drawing rather than describing the machine.
    private static let padInk = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x28 / 255)
    private static let snesPad = Color(red: 0xD7 / 255, green: 0xD3 / 255, blue: 0xCF / 255)

    var body: some View {
        Canvas { ctx, size in
            let vb = console.viewBox
            let s = min(size.width / vb.width, size.height / vb.height)
            let ox = (size.width - vb.width * s) / 2
            let oy = (size.height - vb.height * s) / 2

            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                ctx.fill(Path(CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)),
                         with: .color(color))
            }
            func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
                ctx.stroke(Path(CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)),
                           with: .color(Self.ink), lineWidth: 2 * s)
            }
            func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ color: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: ox + (cx - r) * s, y: oy + (cy - r) * s,
                                                width: r * 2 * s, height: r * 2 * s)),
                         with: .color(color))
            }

            switch console {
            case .gb:
                rect(8, 4, 48, 72, Self.gbBody); frame(8, 4, 48, 72)
                rect(14, 12, 36, 28, Self.ink)
                rect(17, 15, 30, 22, Self.screen)
                dot(20, 9, 1.2, Self.red)
                rect(14, 50, 10, 3, Self.ink); rect(17, 47, 4, 9, Self.ink)
                dot(42, 52, 3, Self.red); dot(50, 48, 3, Self.red)
                rect(24, 62, 6, 2, Self.ink); rect(34, 62, 6, 2, Self.ink)
                rect(44, 62, 2, 2, Self.ink); rect(48, 62, 2, 2, Self.ink)
                rect(44, 66, 2, 2, Self.ink); rect(48, 66, 2, 2, Self.ink)

            case .gbc:
                rect(8, 6, 48, 68, Self.gbcBody); frame(8, 6, 48, 68)
                rect(14, 14, 36, 30, Self.ink)
                rect(17, 17, 30, 24, Self.screen)
                dot(18, 11, 1.2, Self.screen)
                rect(14, 52, 10, 3, Self.ink); rect(17, 49, 4, 9, Self.ink)
                dot(44, 55, 3, Self.ink); dot(50, 52, 3, Self.ink)
                rect(26, 64, 5, 2, Self.ink); rect(35, 64, 5, 2, Self.ink)

            case .gba:
                rect(4, 10, 82, 44, Self.gbaBody); frame(4, 10, 82, 44)
                rect(6, 6, 14, 6, Self.gbaBody); frame(6, 6, 14, 6)
                rect(70, 6, 14, 6, Self.gbaBody); frame(70, 6, 14, 6)
                rect(24, 18, 42, 28, Self.ink)
                rect(27, 21, 36, 22, Self.screen)
                rect(10, 32, 9, 3, Self.ink); rect(13, 29, 3, 9, Self.ink)
                dot(72, 34, 3, Self.red); dot(80, 30, 3, Self.red)
                rect(36, 50, 6, 2, Self.ink); rect(48, 50, 6, 2, Self.ink)

            case .nds:
                rect(8, 6, 64, 34, Self.ndsBody); frame(8, 6, 64, 34)
                rect(22, 11, 36, 24, Self.ink)
                rect(24, 13, 32, 20, Self.screen)
                rect(8, 38, 64, 4, Self.ink)
                rect(8, 42, 64, 32, Self.ndsBody); frame(8, 42, 64, 32)
                rect(22, 46, 36, 22, Self.ink)
                rect(24, 48, 32, 18, Self.screen)
                rect(12, 56, 8, 2, Self.ink); rect(15, 53, 2, 8, Self.ink)
                dot(64.5, 53.5, 1.6, Self.ink); dot(68, 57, 1.6, Self.ink)
                dot(64.5, 60.5, 1.6, Self.ink); dot(61, 57, 1.6, Self.ink)
                rect(30, 71, 3, 1, Self.ink); rect(36, 71, 3, 1, Self.ink)

            case .snes:
                // Machine: low wide box, lighter moulded top, purple band, two ports.
                rect(0, 6, 92, 30, Self.snesBody); rect(0, 6, 92, 8, Self.snesTop)
                frame(0, 6, 92, 30)
                rect(28, 0, 40, 8, Self.snesBody); frame(28, 0, 40, 8)
                rect(33, 3, 30, 3, Self.ink)
                rect(6, 9, 7, 3, Self.ink); rect(16, 9, 7, 3, Self.ink)
                rect(0, 22, 92, 3, Self.gbcBody)
                rect(24, 28, 12, 5, Self.ink); rect(56, 28, 12, 5, Self.ink)
                dot(10, 30, 1.6, Self.red)
                // Pad: shoulders at the top edge, cross, the two pills, the diamond.
                rect(21, 39, 9, 3, Self.snesPad); frame(21, 39, 9, 3)
                rect(62, 39, 9, 3, Self.snesPad); frame(62, 39, 9, 3)
                rect(18, 42, 56, 22, Self.snesPad); frame(18, 42, 56, 22)
                rect(23, 51, 11, 4, Self.padInk); rect(26, 48, 5, 10, Self.padInk)
                rect(38, 52, 5, 2, Self.padInk); rect(45, 52, 5, 2, Self.padInk)
                dot(61.5, 48, 2.6, Self.faceBlue); dot(56.5, 53, 2.6, Self.faceGreen)
                dot(66.5, 53, 2.6, Self.faceRed); dot(61.5, 58, 2.6, Self.faceYellow)

            case .nes:
                // Machine: a flatter slab than the Super Nintendo's, red stripe, the
                // cartridge flap, power and reset stacked beside it.
                rect(0, 0, 92, 32, Self.nesBody); rect(0, 0, 92, 6, Self.nesTop)
                frame(0, 0, 92, 32)
                rect(0, 8, 92, 3, Self.red)
                rect(16, 15, 60, 14, Self.nesFlap); frame(16, 15, 60, 14)
                rect(22, 20, 48, 2, Self.ink)
                rect(4, 16, 7, 3, Self.ink); rect(4, 24, 7, 3, Self.ink)
                dot(7, 21, 1.6, Self.red)
                // Pad: square-cornered, which is the shape every other pad here
                // inherits from it.
                rect(20, 40, 52, 20, Self.nesTop); frame(20, 40, 52, 20)
                rect(25, 48, 11, 4, Self.padInk); rect(28, 45, 5, 10, Self.padInk)
                rect(40, 47, 12, 6, Self.nesWell)
                rect(41, 49, 4, 2, Self.padInk); rect(47, 49, 4, 2, Self.padInk)
                rect(56, 45, 11, 10, Self.nesWell)
                dot(59, 50, 2.2, Self.red); dot(64, 50, 2.2, Self.red)
            }
        }
    }
}
