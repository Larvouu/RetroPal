//
//  ConsoleIconRow.swift
//  EmulateurGBA
//
//  The four supported consoles as small pixel-art icons with their names,
//  shown in the empty-library onboarding. Ported 1:1 — coordinates AND
//  palette — from the website's ConsoleIcon.astro (the systems strip on
//  retropal.fr), so the onboarding and the site read as one family: the
//  grey DMG, the purple GBC, the indigo GBA with its shoulders, and the
//  cream DS clamshell, all with the DMG-green screens.
//

import SwiftUI

/// One row: GB · GBC · GBA · NDS, icons above their labels. Columns take
/// their LABEL's natural width (equal-width columns truncated "GAME BOY
/// ADVANCE"); the spacers distribute what's left, and `fixedSize` makes
/// truncation impossible — every name renders whole, all at one size.
struct ConsoleIconRow: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            item(.gb)
            Spacer(minLength: 8)
            item(.gbc)
            Spacer(minLength: 8)
            item(.gba)
            Spacer(minLength: 8)
            item(.nds)
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
    case gb, gbc, gba, nds

    var label: String {
        switch self {
        case .gb:  return "Game Boy"
        case .gbc: return "Game Boy Color"
        case .gba: return "Game Boy Advance"
        case .nds: return "Nintendo DS"
        }
    }

    /// The source SVG's viewBox (the drawing coordinates below live in it).
    var viewBox: CGSize {
        switch self {
        case .gb, .gbc: return CGSize(width: 64, height: 80)
        case .gba:      return CGSize(width: 90, height: 64)
        case .nds:      return CGSize(width: 80, height: 80)
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
                dot(42, 48, 3, Self.red); dot(50, 52, 3, Self.red)
                rect(24, 62, 6, 2, Self.ink); rect(34, 62, 6, 2, Self.ink)
                rect(44, 62, 2, 2, Self.ink); rect(48, 62, 2, 2, Self.ink)
                rect(44, 66, 2, 2, Self.ink); rect(48, 66, 2, 2, Self.ink)

            case .gbc:
                rect(8, 6, 48, 68, Self.gbcBody); frame(8, 6, 48, 68)
                rect(14, 14, 36, 30, Self.ink)
                rect(17, 17, 30, 24, Self.screen)
                dot(18, 11, 1.2, Self.screen)
                rect(14, 52, 10, 3, Self.ink); rect(17, 49, 4, 9, Self.ink)
                dot(44, 52, 3, Self.ink); dot(50, 55, 3, Self.ink)
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
                rect(16, 11, 48, 24, Self.ink)
                rect(18, 13, 44, 20, Self.screen)
                rect(8, 38, 64, 4, Self.ink)
                rect(8, 42, 64, 32, Self.ndsBody); frame(8, 42, 64, 32)
                rect(22, 46, 36, 22, Self.ink)
                rect(24, 48, 32, 18, Self.screen)
                rect(12, 56, 7, 2, Self.ink); rect(14, 54, 3, 6, Self.ink)
                dot(62, 50, 1.6, Self.ink); dot(66, 54, 1.6, Self.ink)
                dot(62, 58, 1.6, Self.ink); dot(58, 54, 1.6, Self.ink)
                rect(30, 71, 3, 1, Self.ink); rect(36, 71, 3, 1, Self.ink)
            }
        }
    }
}
