//
//  ConsoleIconRow.swift
//  EmulateurGBA
//
//  Every supported console as a small pixel-art icon with its name, shown in
//  the empty-library onboarding. The first four are ported 1:1 —
//  coordinates AND palette — from the website's ConsoleIcon.astro (the systems
//  strip on retropal.fr), so the onboarding and the site read as one family:
//  the grey DMG, the purple GBC, the indigo GBA with its shoulders, and the
//  cream DS clamshell, all with the DMG-green screens.
//
//  The Super Nintendo, the NES, the PlayStation and the Nintendo 64 join them
//  from the `console-snes` / `console-nes` / `console-ps1` / `console-n64`
//  imagesets, the same drawings the Appearance button wears, in the same
//  coordinates. They are the only four here that are not handhelds, so each is
//  drawn as its machine with its pad below it, which is also what keeps them
//  from reading as one more grey slab beside the DMG. The PlayStation and the
//  Nintendo 64 go further and are drawn from ABOVE, because their fronts are
//  plain boxes and their tops (the disc lid, the cartridge) are what a player
//  recognises.
//

import SwiftUI

/// Every console the app runs, each drawing over its name, on a frieze of two
/// lines that slides past as one block (`ConsoleStrip`). Names render whole at
/// one size (`fixedSize`): the strip scrolls, so no label is ever squeezed.
struct ConsoleIconRow: View {
    /// Every console the app runs, in the order the rows used to read.
    static let all: [PixelConsole] = [.gb, .gbc, .gba, .nds, .nes, .snes, .ps1, .n64, .md, .sms, .gg, .psp]

    /// The handhelds and the two Nintendo home machines on top, the
    /// PlayStation, the Nintendo 64, the three Segas and the PSP below.
    static let lines: [[PixelConsole]] = [Array(all.prefix(6)), Array(all.dropFirst(6))]

    /// Every drawing is this tall, whatever its shape.
    static let iconHeight: CGFloat = 36

    /// False while the page is not the one on screen (another tab): the strip
    /// then stops redrawing.
    var isActive: Bool = true

    var body: some View {
        // TWO LINES THAT SCROLL AS ONE BLOCK, since 2026-10-09 (asked the
        // same day): one line showed four or five consoles at a time; two show
        // twice as many and still leave the whole welcome, the legal note
        // included, on the first screen.
        ConsoleStrip(lines: Self.lines, isActive: isActive, item: { item($0) })
    }

    fileprivate func item(_ console: PixelConsole) -> some View {
        VStack(spacing: 5) {
            // A size of its own, never the one the strip proposes: the strip
            // is `fixedSize`, which proposes no width at all, and a Canvas
            // offered none falls back to a default of its own, every drawing
            // was squeezed into it and the widest (the NES) came out smallest.
            // Width from the drawing's own box, so each is 36 points tall.
            PixelConsoleIcon(console: console)
                .frame(width: Self.iconHeight * console.viewBox.width / console.viewBox.height,
                       height: Self.iconHeight)
            Text(console.label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// The consoles on lines that slide slowly to the left and come round again,
/// the way a frieze does. Each line is its consoles with the SAME gap after
/// every one, the last included, repeated side by side; its position is
/// computed from the clock (time x speed, wrapped by that line's own length),
/// so the strip is full from the first frame, never stops and never shows a
/// seam, and both lines, moving at one speed, read as one block.
///
/// Why a timeline and not a repeating Core Animation offset (the first two
/// versions, 2026-10-09): that animation could only start once each copy had
/// measured itself, so the strip arrived empty and filled in, and stretching
/// the lines to one width to share one animation made their gaps differ (seen
/// on device). A position read off the clock has no such state. The cost is a
/// redraw of this strip each frame, on the welcome page only: no game can be
/// running while the library is empty (a timeline behind a running game is
/// what made 1.3.1 stutter), and it stops while another tab is shown.
///
/// With Reduce Motion it stands still and scrolls by hand. VoiceOver reads it as
/// one element naming every console, rather than each one, several times.
private struct ConsoleStrip<Item: View>: View {
    let lines: [[PixelConsole]]
    let isActive: Bool
    let item: (PixelConsole) -> Item

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Each line's length (its consoles and their gaps), measured once laid out.
    @State private var lengths: [Int: CGFloat] = [:]
    @State private var visibleWidth: CGFloat = 0
    /// When the motion starts: reset as the first line is measured, so the
    /// strip shows its first consoles in place before it begins to move.
    @State private var start = Date()

    /// Points a second: slow enough to read every name as it passes.
    private static var speed: CGFloat { 22 }
    /// The room after every console, on both lines.
    private static var gap: CGFloat { 22 }
    private static var lineGap: CGFloat { 12 }

    var body: some View {
        Group {
            if reduceMotion {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Self.lineGap) {
                        ForEach(lines.indices, id: \.self) { index in segment(index) }
                    }
                }
                // As tall as the two lines, not as tall as it is offered.
                .fixedSize(horizontal: false, vertical: true)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { context in
                    let elapsed = CGFloat(max(0, context.date.timeIntervalSince(start)))
                    VStack(alignment: .leading, spacing: Self.lineGap) {
                        ForEach(lines.indices, id: \.self) { index in
                            line(index, elapsed: elapsed)
                        }
                    }
                    // As wide as the page offers and no wider, the copies
                    // running off its right edge; as tall as the two lines.
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { visibleWidth = g.size.width }
                        .onChange(of: g.size.width) { width in visibleWidth = width }
                })
                .clipped()
            }
        }
        // Soft edges, so a console arrives and leaves rather than being cut.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                     .init(color: .black, location: 0.08),
                                     .init(color: .black, location: 0.92),
                                     .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lines.joined().map(\.label).joined(separator: ", "))
    }

    /// A line in motion: enough copies of its segment that it is still full
    /// when the first copy has slid out (three before it is measured, which
    /// covers an iPad's column), shifted by the distance travelled modulo its
    /// length.
    private func line(_ index: Int, elapsed: CGFloat) -> some View {
        let length = lengths[index] ?? 0
        let copies = length > 0 ? max(3, Int((visibleWidth / length).rounded(.up)) + 1) : 3
        let shift = length > 0 ? (elapsed * Self.speed).truncatingRemainder(dividingBy: length) : 0
        return HStack(spacing: 0) {
            segment(index).background(lengthReader(index))
            ForEach(1..<copies, id: \.self) { _ in segment(index) }
        }
        .fixedSize()
        .offset(x: -shift)
    }

    /// One line's consoles, each followed by the same gap.
    private func segment(_ index: Int) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(lines[index], id: \.self) { console in
                item(console)
                Color.clear.frame(width: Self.gap, height: 1)
            }
        }
        .fixedSize()
    }

    private func lengthReader(_ index: Int) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { record(index, g.size.width) }
                .onChange(of: g.size.width) { width in record(index, width) }
        }
    }

    private func record(_ index: Int, _ length: CGFloat) {
        guard length > 0 else { return }
        if index == 0 && lengths[0] == nil { start = Date() }
        lengths[index] = length
    }
}

enum PixelConsole {
    case gb, gbc, gba, nds, nes, snes, ps1, n64, md, sms, gg, psp

    /// The drawing for a LAYOUT family. GB and GBC share one layout and one
    /// `PresetSystem`, so that family wears the Game Boy Color's machine: it is
    /// the one of the two whose own colour tells it apart from the Game Boy
    /// Advance beside it.
    ///
    /// nil for a console whose drawing does not exist yet: `PresetConsoleIcon`
    /// then keeps the icon's room empty rather than borrowing another machine.
    init?(_ system: PresetSystem) {
        switch system {
        case .gba:  self = .gba
        case .gbc:  self = .gbc
        case .nds:  self = .nds
        case .snes: self = .snes
        case .nes:  self = .nes
        case .ps1:  self = .ps1
        case .n64:  self = .n64
        case .md:   self = .md
        case .sms:  self = .sms
        case .gg:   self = .gg
        case .psp:  self = .psp
        }
    }

    var label: String {
        switch self {
        case .gb:   return "Game Boy"
        case .gbc:  return "Game Boy Color"
        case .gba:  return "Game Boy Advance"
        case .nds:  return "Nintendo DS"
        case .nes:  return "NES"
        case .snes: return "Super Nintendo"
        case .ps1:  return "PlayStation"
        case .n64:  return "Nintendo 64"
        // The one name that differs by market (Genesis in the Americas).
        case .md:   return SystemColor.name("md")
        case .sms:  return SystemColor.name("sms")
        case .gg:   return SystemColor.name("gg")
        case .psp:  return SystemColor.name("psp")
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
        // Taller than the other two machines because this one carries a pad
        // whose GRIPS hang below the body every other pad here ends at.
        case .ps1:      return CGSize(width: 92, height: 70)
        // The same height, for the same reason: its pad's prongs hang low.
        case .n64:      return CGSize(width: 92, height: 70)
        // The Nintendo 64's box, which its drawing was made in.
        case .md:       return CGSize(width: 92, height: 70)
        // The Master System in the same box as the other two Segas' set; the
        // Game Gear, a landscape handheld, in the Game Boy Advance's.
        case .sms:      return CGSize(width: 92, height: 70)
        case .gg:       return CGSize(width: 90, height: 64)
        // The PSP, the set's third landscape handheld, in the same box.
        case .psp:      return CGSize(width: 90, height: 64)
        }
    }
}

/// A layout family's drawing, for the settings lists that choose a console.
/// Empty for a console with no drawing yet (see `PixelConsole.init(_:)`); the
/// caller's frame keeps the rows aligned either way.
struct PresetConsoleIcon: View {
    let system: PresetSystem

    var body: some View {
        if let console = PixelConsole(system) {
            PixelConsoleIcon(console: console)
        } else {
            Color.clear
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
    // The PlayStation is the set's only WARM grey, and that is doing work: the
    // other two machines are cool greys, and a third cool grey beside them would
    // read as a variant of them at 36pt. Sony's plastic really was warmer, so
    // the difference is true as well as useful. `psBody` is also the pad, since
    // the DualShock is moulded from the console's own plastic.
    private static let psBody = Color(red: 0xC4 / 255, green: 0xC0 / 255, blue: 0xB6 / 255)
    private static let psTop = Color(red: 0xD9 / 255, green: 0xD5 / 255, blue: 0xCB / 255)
    private static let psLid = Color(red: 0xB0 / 255, green: 0xAC / 255, blue: 0xA1 / 255)
    // The four marks are PRINTED on one grey plastic, which is the opposite of
    // the Super Nintendo's four coloured plastics above. Values are the dress's
    // own (`DressKind.ps1Triangle` and friends), so this drawing and the pad the
    // app paints around the running game cannot drift apart.
    private static let psTriangle = Color(red: 0x47 / 255, green: 0xBD / 255, blue: 0x98 / 255)
    private static let psCircle = Color(red: 0xE2 / 255, green: 0x4F / 255, blue: 0x65 / 255)
    private static let psCross = Color(red: 0x67 / 255, green: 0x92 / 255, blue: 0xD9 / 255)
    private static let psSquare = Color(red: 0xE0 / 255, green: 0x79 / 255, blue: 0xAF / 255)
    // The Nintendo 64: the set's only DARK machine, a lifted charcoal so it
    // keeps its shape on a dark page, and its pad in the dress's own colours
    // (`DressKind.n64Body` and the buttons, 2026-09-27), so this drawing and
    // the console painted around the running game agree.
    private static let n64Body = Color(red: 0x5C / 255, green: 0x5E / 255, blue: 0x66 / 255)
    private static let n64Top = Color(red: 0x6C / 255, green: 0x6E / 255, blue: 0x76 / 255)
    private static let n64Band = Color(red: 0x45 / 255, green: 0x47 / 255, blue: 0x4E / 255)
    private static let n64Grey = Color(red: 0x8C / 255, green: 0x8F / 255, blue: 0x9E / 255)
    private static let n64Lamp = Color(red: 0xD9 / 255, green: 0x41 / 255, blue: 0x2B / 255)
    private static let n64Pad = Color(red: 0xC4 / 255, green: 0xC7 / 255, blue: 0xCA / 255)
    private static let n64Cross = Color(red: 0x5A / 255, green: 0x5C / 255, blue: 0x66 / 255)
    private static let n64Stick = Color(red: 0x78 / 255, green: 0x79 / 255, blue: 0x84 / 255)
    private static let n64Start = Color(red: 0xDB / 255, green: 0x00 / 255, blue: 0x12 / 255)
    private static let n64A = Color(red: 0x40 / 255, green: 0x70 / 255, blue: 0xFF / 255)
    private static let n64B = Color(red: 0x60 / 255, green: 0xC9 / 255, blue: 0x75 / 255)
    private static let n64C = Color(red: 0xFF / 255, green: 0xCC / 255, blue: 0x4A / 255)
    // The Mega Drive, from `console-md.svg`: a lifted charcoal machine and pad,
    // its controls the dress's control plastic, lifted the same way.
    private static let mdBody = Color(red: 0x44 / 255, green: 0x46 / 255, blue: 0x4D / 255)
    private static let mdTop = Color(red: 0x52 / 255, green: 0x54 / 255, blue: 0x5B / 255)
    private static let mdDeck = Color(red: 0x56 / 255, green: 0x58 / 255, blue: 0x5F / 255)
    private static let mdDark = Color(red: 0x2A / 255, green: 0x2B / 255, blue: 0x30 / 255)
    // The Master System and the Game Gear, from `console-sms.svg` and
    // `console-gg.svg`: the same lifted charcoals as the Mega Drive, the red of
    // the Master System's trim on both machines' buttons, and the Game Gear's
    // lit colour screen.
    private static let smsBody = Color(red: 0x3E / 255, green: 0x40 / 255, blue: 0x47 / 255)
    private static let smsTop = Color(red: 0x4C / 255, green: 0x4E / 255, blue: 0x56 / 255)
    private static let segaRed = Color(red: 0xD9 / 255, green: 0x41 / 255, blue: 0x2B / 255)
    // The Game Gear's and the PSP's screens, drawn switched off: a neutral dark
    // glass a step lighter than the bezel ink (2026-10-10; the lit sky and
    // ground read as a game's picture rather than the machine).
    // The Game Gear, in its dress's colours (`DressKind.gg*`, 2026-10-11).
    private static let ggBody = Color(red: 0x4D / 255, green: 0x57 / 255, blue: 0x63 / 255)
    private static let ggTop = Color(red: 0x5C / 255, green: 0x66 / 255, blue: 0x72 / 255)
    private static let ggSurround = Color(red: 0x10 / 255, green: 0x17 / 255, blue: 0x1A / 255)
    private static let ggButton = Color(red: 0x2A / 255, green: 0x34 / 255, blue: 0x3C / 255)
    private static let ggCross = Color(red: 0x56 / 255, green: 0x61 / 255, blue: 0x6B / 255)
    private static let ggStart = Color(red: 0x69 / 255, green: 0x93 / 255, blue: 0xD7 / 255)
    private static let ggPillRed = Color(red: 0xD9 / 255, green: 0x57 / 255, blue: 0x4E / 255)
    private static let ggPillGreen = Color(red: 0x60 / 255, green: 0xAF / 255, blue: 0xAA / 255)
    private static let ggPillBlue = Color(red: 0x44 / 255, green: 0x74 / 255, blue: 0xBD / 255)
    private static let screenOff = Color(red: 0x2B / 255, green: 0x2D / 255, blue: 0x33 / 255)
    // The PSP, from `console-psp.svg`: the Game Gear's charcoals and dark screen,
    // its shoulder tabs a step lighter, its four buttons the PlayStation's.
    private static let pspTab = Color(red: 0x5A / 255, green: 0x5C / 255, blue: 0x63 / 255)

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
            /// A closed outline, filled then stroked. The PlayStation's pad needs
            /// it and nothing else here does: built from rectangles, that pad's
            /// body draws a bottom edge straight across the tops of its grips and
            /// the whole thing reads as a bar standing on legs. One outline has no
            /// inside edges to draw.
            func poly(_ points: [(CGFloat, CGFloat)], _ color: Color, bevel: Bool = false) {
                var path = Path()
                for (index, p) in points.enumerated() {
                    let q = CGPoint(x: ox + p.0 * s, y: oy + p.1 * s)
                    if index == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
                path.closeSubpath()
                ctx.fill(path, with: .color(color))
                // Bevelled where a shape meets itself at a sharp angle (the
                // Master System's lid), so the join cannot spike past it.
                ctx.stroke(path, with: .color(Self.ink),
                           style: StrokeStyle(lineWidth: 2 * s, lineJoin: bevel ? .bevel : .miter))
            }
            /// A rounded body, filled, its lit top band cut to the same outline,
            /// then stroked. The Game Gear's, whose ends are round.
            func roundedBody(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat,
                             _ color: Color, band: CGFloat, _ bandColor: Color) {
                let outline = Path(roundedRect: CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s),
                                   cornerRadius: radius * s)
                ctx.fill(outline, with: .color(color))
                var top = ctx
                top.clip(to: outline)
                top.fill(Path(CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: band * s)),
                         with: .color(bandColor))
                ctx.stroke(outline, with: .color(Self.ink), lineWidth: 2 * s)
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

            case .ps1:
                // Machine, SEEN FROM ABOVE, with its front edge as a darker band.
                // Every other console here is a front view, and a PlayStation's
                // front is a grey box: the third grey box in the set, beside the
                // Super Nintendo and the NES, and at 36pt nobody would tell them
                // apart. The disc lid is the one unmistakable thing about this
                // machine and it is on top, so the top is what this draws. A pure
                // top view would show no controller ports, and two ports is the
                // other half of what makes a PlayStation read as one, so the front
                // edge comes along.
                rect(4, 2, 84, 24, Self.psBody); rect(4, 2, 84, 6, Self.psTop)
                rect(4, 26, 84, 6, Self.psLid); frame(4, 26, 84, 6)
                frame(4, 2, 84, 30)
                // The lid: ring, face, spindle. Three filled circles rather than
                // one stroked circle, because Canvas has no stroked-ellipse
                // primitive and the SVG is drawn the same way for that reason.
                dot(28, 15, 9.5, Self.ink)
                dot(28, 15, 8, Self.psLid)
                dot(28, 15, 2, Self.ink)
                rect(56, 10, 24, 9, Self.psLid); frame(56, 10, 24, 9)
                // Ports light on the dark band. As ink they merged with the band's
                // own outline and read as bites taken out of it.
                rect(30, 28, 10, 2.5, Self.psTop); rect(46, 28, 10, 2.5, Self.psTop)
                dot(11, 29, 1.5, Self.red)
                // THE 1994 PAD, not the DualShock: no sticks. It is the one that
                // came in the box with the machine above it, and the pair should
                // be the pair a player remembers. The app's on-screen controls
                // are a DualShock, because that is what the games need; this is
                // an icon of a console, and the console shipped with this.
                //
                // ITS SIZE IS MEASURED. A PlayStation is 270mm wide and its pad
                // is 155mm: 57%. Drawn at 90% of the machine the pad read as a
                // second appliance rather than the thing you hold, and no
                // adjustment of its outline fixes a proportion. 52 units against
                // the machine's 84 is 62%, the same compression the NES and
                // Super Nintendo icons already apply; the pad's own 52 by 32 is
                // the real one's 155 by 95, both 1.63.
                //
                // ONE OUTLINE, and it has to be: the body's top stroke would cut
                // across the shoulder reliefs and its bottom stroke across the
                // grips, and the pad would read as a bar with tabs behind it
                // standing on legs. The reliefs span the controls they sit above,
                // L1/L2 over the cross and R1/R2 over the four marks, so the top
                // edge describes the pad's two halves rather than decorating its
                // corners. The body's bottom edge dips THREE units between the
                // grips, the midpoint of two versions wrong in opposite ways: at
                // six the pad had a bulge its hardware does not have, and dead
                // level the grips read as two legs hanging off a bar rather than
                // as part of the same moulding. The grips taper as they splay.
                // Symmetric about x 46 to the unit.
                poly([(24, 36), (40, 36), (40, 39), (52, 39), (52, 36), (68, 36),
                      (68, 55), (72, 68), (62, 68), (54, 58), (38, 58), (30, 68),
                      (20, 68), (24, 55)],
                     Self.psBody)
                // Each block shares its RELIEF's centre line, x 32 and x 60, not
                // merely sits near it: L1/L2 are over the cross and R1/R2 over
                // the four marks on the real pad, and the top edge only reads as
                // saying so if what is underneath lines up with it. Both gave up
                // a little size to do that and still clear the body's edges.
                // Vertically both are on the body's own centre line, y 47: with
                // no sticks there is nothing in the lower half to balance
                // against, so the controls sit in the middle of the shape.
                rect(27.5, 45.5, 9, 3, Self.padInk); rect(30.5, 42.5, 3, 9, Self.padInk)
                rect(40.5, 46, 4, 2, Self.padInk); rect(47.5, 46, 4, 2, Self.padInk)
                dot(60, 43.8, 2.1, Self.psTriangle); dot(63.2, 47, 2.1, Self.psCircle)
                dot(60, 50.2, 2.1, Self.psCross); dot(56.8, 47, 2.1, Self.psSquare)

            case .n64:
                // Machine, SEEN FROM ABOVE like the PlayStation: its front is a
                // dark box, and what reads as a Nintendo 64 is on top, the
                // cartridge standing in its slot between the two sliders. The
                // front band carries the four ports, the other half of the
                // recognition. Coordinates are `console-n64.svg`'s.
                rect(8, 2, 76, 22, Self.n64Body); rect(8, 2, 76, 5, Self.n64Top)
                rect(8, 24, 76, 6, Self.n64Band); frame(8, 24, 76, 6)
                frame(8, 2, 76, 28)
                rect(30, 7, 32, 14, Self.n64Top); frame(30, 7, 32, 14)
                rect(35, 10, 22, 7, Self.n64Grey); frame(35, 10, 22, 7)
                rect(17, 12, 7, 3, Self.n64Grey); rect(68, 12, 7, 3, Self.n64Grey)
                rect(28, 26, 6, 2, Self.n64Grey); rect(38, 26, 6, 2, Self.n64Grey)
                rect(48, 26, 6, 2, Self.n64Grey); rect(58, 26, 6, 2, Self.n64Grey)
                dot(14, 27, 1.4, Self.n64Lamp)
                // THE TRIDENT, one outline for the PlayStation pad's reason:
                // prongs built from rectangles would draw the body's bottom edge
                // across the top of each. The MIDDLE prong reaches further down
                // than the outer two, which splay, and the top edge rises in a tab
                // across the middle 30% of the body. Symmetric about x 46.
                poly([(22, 36), (38, 36), (38, 34), (54, 34), (54, 36), (70, 36),
                      (74, 40), (74, 56), (72, 65), (63, 65), (60, 54), (53, 54),
                      (52, 69), (40, 69), (39, 54), (32, 54), (29, 65), (20, 65),
                      (18, 56), (18, 40)],
                     Self.n64Pad)
                rect(22.5, 43.75, 7, 2.5, Self.n64Cross); rect(24.75, 41.5, 2.5, 7, Self.n64Cross)
                // START level with the cross's centre; the stick on the line where
                // the body ends and the prongs begin.
                dot(46, 45, 1.6, Self.n64Start)
                dot(46, 54, 3.4, Self.ink); dot(46, 54, 2.6, Self.n64Stick)
                dot(66, 39.7, 1.3, Self.n64C); dot(66, 45.3, 1.3, Self.n64C)
                dot(63.2, 42.5, 1.3, Self.n64C); dot(68.8, 42.5, 1.3, Self.n64C)
                dot(57, 46, 2, Self.n64B); dot(61, 49, 2.2, Self.n64A)

            case .md:
                // Machine, SEEN FROM ABOVE like the PlayStation and the Nintendo
                // 64: the round raised deck with the cartridge slot across it,
                // power and reset either side, the volume slider and the lamp.
                // Coordinates are `console-md.svg`'s; a stroked circle there is
                // an ink disc one unit larger here with its fill one unit smaller.
                rect(8, 2, 76, 28, Self.mdBody); rect(8, 2, 76, 5, Self.mdTop)
                frame(8, 2, 76, 28)
                dot(46, 16, 12, Self.ink); dot(46, 16, 10, Self.mdDeck)
                rect(36, 13, 20, 6, Self.mdDark); frame(36, 13, 20, 6)
                rect(15, 9, 8, 3, Self.n64Grey); rect(69, 9, 6, 3, Self.n64Grey)
                rect(66, 22, 10, 2, Self.n64Grey)
                dot(14, 23, 1.4, Self.n64Lamp)
                // The six-button pad, one outline: the body and its two grips.
                poly([(20, 37), (72, 37), (76, 41), (76, 54), (71, 63), (57, 63),
                      (53, 59), (39, 59), (35, 63), (21, 63), (16, 54), (16, 41)],
                     Self.mdDeck)
                rect(23.5, 47.75, 9, 2.5, Self.mdDark); rect(26.75, 44.5, 2.5, 9, Self.mdDark)
                rect(43, 41, 6, 2, Self.mdDark)
                // A B C below, X Y Z above, each row rising to the right.
                dot(57, 53, 2, Self.mdDark); dot(62.5, 51.5, 2, Self.mdDark)
                dot(68, 50, 2, Self.mdDark)
                dot(57, 47, 1.5, Self.mdDark); dot(62.5, 45.5, 1.5, Self.mdDark)
                dot(68, 44, 1.5, Self.mdDark)

            case .sms:
                // Machine FROM THE FRONT, like the NES and the Super Nintendo:
                // the wedge whose top falls toward the player, the slot on the
                // raised back, two ribs, the red trim along the lower edge with
                // the lamp in it. Coordinates are `console-sms.svg`'s.
                poly([(8, 30), (8, 14), (22, 6), (70, 6), (84, 14), (84, 30)], Self.smsBody)
                poly([(8, 14), (22, 6), (70, 6), (84, 14)], Self.smsTop, bevel: true)
                rect(34, 8, 24, 3, Self.ink)
                rect(12, 17, 68, 1.5, Self.mdDark); rect(12, 20.5, 68, 1.5, Self.mdDark)
                rect(9, 24, 74, 4, Self.segaRed)
                rect(14, 25, 6, 2, Self.n64Grey)
                // Its pad: a plain rectangle, the cross, 1 and 2.
                rect(24, 38, 44, 22, Self.mdDeck); frame(24, 38, 44, 22)
                rect(29, 47.75, 9, 2.5, Self.mdDark); rect(32.25, 44.5, 2.5, 9, Self.mdDark)
                dot(55.5, 49, 2.6, Self.segaRed); dot(62.5, 49, 2.6, Self.segaRed)

            case .gg:
                // A landscape handheld with both ends rounded, in its dress's
                // colours (2026-10-11): the grey shell, the black surround with
                // its three pills, the screen dark (switched off), the cross a
                // dark disc with the cross on it, 1 and 2 dark, START blue.
                // Coordinates are `console-gg.svg`'s.
                roundedBody(3, 10, 84, 44, radius: 16, Self.ggBody, band: 8, Self.ggTop)
                rect(22, 15, 46, 34, Self.ggSurround)
                rect(29, 19, 32, 26, Self.screenOff)
                dot(24, 20, 1.1, Self.ggPillRed); dot(25.5, 22, 1.1, Self.ggPillGreen)
                dot(27, 24, 1.1, Self.ggPillBlue)
                dot(13, 32, 6, Self.ggButton)
                rect(8.5, 30.75, 9, 2.5, Self.ggCross); rect(11.75, 27.5, 2.5, 9, Self.ggCross)
                dot(74, 21.5, 1.6, Self.ggStart)
                dot(72, 35, 2.6, Self.ggButton); dot(79.5, 31, 2.6, Self.ggButton)
            case .psp:
                // Long with rounded ends, the shoulder tabs outlined behind its top
                // edge as the Game Boy Advance's are, the wide screen, the cross
                // over the nub on the left (the nub an ink ring round a light cap,
                // the Nintendo 64's stick), the four symbols in a diamond on the
                // right, SELECT and START below them. Redrawn 2026-10-10 to sit
                // with the set. Coordinates are `console-psp.svg`'s.
                rect(12, 10, 12, 6, Self.pspTab); frame(12, 10, 12, 6)
                rect(66, 10, 12, 6, Self.pspTab); frame(66, 10, 12, 6)
                roundedBody(2, 14, 86, 38, radius: 14, Self.mdBody, band: 6, Self.mdTop)
                rect(24, 20, 42, 26, Self.ink)
                rect(26, 22, 38, 22, Self.screenOff)
                rect(8, 26.5, 10, 3, Self.ink); rect(11.5, 23, 3, 10, Self.ink)
                dot(13, 41, 3.4, Self.ink); dot(13, 41, 2.6, Self.n64Grey)
                dot(77, 24, 1.9, Self.psTriangle); dot(81, 28, 1.9, Self.psCircle)
                dot(77, 32, 1.9, Self.psCross); dot(73, 28, 1.9, Self.psSquare)
                rect(71, 40, 5, 2, Self.ink); rect(78, 40, 5, 2, Self.ink)
            }
        }
    }
}
