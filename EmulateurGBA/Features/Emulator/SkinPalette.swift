//
//  SkinPalette.swift
//  EmulateurGBA
//
//  The user-editable colour set of a CUSTOM skin. A custom skin mirrors a console's Nostalgia dress
//  shape-for-shape (like the Retro Pal recolour) but exposes one slot per distinct Nostalgia colour,
//  so a player can reproduce Nostalgia exactly or diverge freely. Each console has its OWN slot set
//  (the consoles share little: GB/GBC splits its button colours, GBA/NDS unify them), so the palette
//  is an enum of three per-console structs. The brand mark is never a slot — its icon + wordmark are
//  auto-derived from the body to a contrasting same-hue tint (see UIColor.rpContrastingMark).
//
//  Stored as 0xRRGGBB so the structs are trivially Codable + Equatable — the latter matters because
//  the dress views guard redraws with `didSet { if variant != oldValue }`, and `DressVariant` carries
//  a `SkinPalette` in its `.custom` case. Six hex digits round-trip cleanly through the editor fields.
//

import UIKit

// MARK: - GB / GBC (11 slots — Nostalgia varies the controls, so they split)

struct GBCSkinPalette: Equatable, Codable {
    var bodyHex: UInt32           // body gradient + recessed seats (derived) + brand capsule
    var surroundHex: UInt32       // screen surround panel
    var dpadHex: UInt32           // D-pad cross face + dark under-discs
    var abButtonsHex: UInt32      // A/B faces
    var abLettersHex: UInt32      // A/B letters
    var smallButtonsHex: UInt32   // SELECT/START/MENU/CLIP faces
    var menuIconsHex: UInt32      // gear/film icons
    var labelsHex: UInt32         // printed SELECT/START labels
    var stripeHex: UInt32         // DOT MATRIX stripe lines
    var printedTextHex: UInt32    // BATTERY + DOT MATRIX printed text
    var ledHex: UInt32            // battery LED

    var body: UIColor         { UIColor(rpHex: bodyHex) }
    var surround: UIColor      { UIColor(rpHex: surroundHex) }
    var dpad: UIColor          { UIColor(rpHex: dpadHex) }
    var abButtons: UIColor     { UIColor(rpHex: abButtonsHex) }
    var abLetters: UIColor     { UIColor(rpHex: abLettersHex) }
    var smallButtons: UIColor  { UIColor(rpHex: smallButtonsHex) }
    var menuIcons: UIColor     { UIColor(rpHex: menuIconsHex) }
    var labels: UIColor        { UIColor(rpHex: labelsHex) }
    var stripe: UIColor        { UIColor(rpHex: stripeHex) }
    var printedText: UIColor   { UIColor(rpHex: printedTextHex) }
    var led: UIColor           { UIColor(rpHex: ledHex) }

    var isWithinHexRange: Bool {
        [bodyHex, surroundHex, dpadHex, abButtonsHex, abLettersHex, smallButtonsHex,
         menuIconsHex, labelsHex, stripeHex, printedTextHex, ledHex].allSatisfy { $0 <= 0xFFFFFF }
    }

    /// GB/GBC Nostalgia, slot for slot (exact hex from ConsoleSkinView + TouchControlsView).
    static let nostalgia = GBCSkinPalette(
        bodyHex: 0xC0BDBC, surroundHex: 0x6D6D6D, dpadHex: 0x29292B, abButtonsHex: 0x8C2054,
        abLettersHex: 0xFFFFFF, smallButtonsHex: 0x4D4D4F, menuIconsHex: 0xD9D9D9,
        labelsHex: 0x1B1973, stripeHex: 0x8C1F53, printedTextHex: 0xEFEEE6, ledHex: 0xD4282D)
}

// MARK: - GBA (5 slots — Nostalgia unifies the button faces)

struct GBASkinPalette: Equatable, Codable {
    var bodyHex: UInt32         // body gradient + recessed seats (derived) + brand capsule
    var surroundHex: UInt32     // screen bezel + under-discs + the black L/MENU/R framing lines
    var buttonsHex: UInt32      // D-pad, A/B, L/R, SELECT/START faces + SELECT/START + POWER labels
    var lettersHex: UInt32      // A/B engraved letters + L/R labels + button edges
    var menuButtonsHex: UInt32  // the MENU/CLIP button background (circle)
    var menuIconsHex: UInt32    // the MENU/CLIP icon glyphs
    var ledHex: UInt32          // POWER LED

    var body: UIColor        { UIColor(rpHex: bodyHex) }
    var surround: UIColor    { UIColor(rpHex: surroundHex) }
    var buttons: UIColor     { UIColor(rpHex: buttonsHex) }
    var letters: UIColor     { UIColor(rpHex: lettersHex) }
    var menuButtons: UIColor { UIColor(rpHex: menuButtonsHex) }
    var menuIcons: UIColor   { UIColor(rpHex: menuIconsHex) }
    var led: UIColor         { UIColor(rpHex: ledHex) }

    var isWithinHexRange: Bool {
        [bodyHex, surroundHex, buttonsHex, lettersHex, menuButtonsHex, menuIconsHex, ledHex]
            .allSatisfy { $0 <= 0xFFFFFF }
    }

    /// GBA Nostalgia, slot for slot (#7558EB body, #0E0E10 bezel, #C4BFCF buttons + MENU/CLIP bg,
    /// #8F8A99 letters, #0E0E10 MENU/CLIP icons, #38D14F power LED).
    static let nostalgia = GBASkinPalette(
        bodyHex: 0x7558EB, surroundHex: 0x0E0E10, buttonsHex: 0xC4BFCF, lettersHex: 0x8F8A99,
        menuButtonsHex: 0xC4BFCF, menuIconsHex: 0x0E0E10, ledHex: 0x38D14F)
}

// MARK: - NDS (4 slots — Nostalgia is near-monochrome)

struct NDSSkinPalette: Equatable, Codable {
    var bodyHex: UInt32     // body + ALL recessed seats + dress structure (screen outlines, speaker/
                            // MIC/light grooves, under-discs) — those derive from body with contrast
    var buttonsHex: UInt32  // every button face + SELECT/START + MIC labels (at rest) + menu/clip circle
    var lettersHex: UInt32  // button letters (A/B/X/Y/L/R) + D-pad arm lines
    var iconsHex: UInt32    // the MENU/CLIP icon glyphs
    var ledHex: UInt32      // the green "light"

    var body: UIColor     { UIColor(rpHex: bodyHex) }
    var buttons: UIColor  { UIColor(rpHex: buttonsHex) }
    var letters: UIColor  { UIColor(rpHex: lettersHex) }
    var icons: UIColor    { UIColor(rpHex: iconsHex) }
    var led: UIColor      { UIColor(rpHex: ledHex) }

    var isWithinHexRange: Bool {
        [bodyHex, buttonsHex, lettersHex, iconsHex, ledHex].allSatisfy { $0 <= 0xFFFFFF }
    }

    /// NDS Nostalgia, slot for slot (#C4C4C4 body, #EBEBEB buttons, #777777 letters + icons,
    /// #38D14F light). The dress structure derives from body (≈ #777777 at the Nostalgia body).
    static let nostalgia = NDSSkinPalette(
        bodyHex: 0xC4C4C4, buttonsHex: 0xEBEBEB, lettersHex: 0x777777, iconsHex: 0x777777, ledHex: 0x38D14F)
}

// MARK: - SNES (7 slots — one per colour the dress does not derive)

/// The Super Nintendo's four face buttons are four different colours, which is the whole point of
/// the console, so a custom skin that could not set them separately could not reproduce Nostalgia.
/// Everything the dress DERIVES stays derived and is deliberately not a slot: each letter is its
/// own button's colour darkened by half, the carved seats are the body darkened, the printed
/// SELECT/START words are the body moved away from itself, and the MENU/CLIP glyph follows its own
/// button (the surround on a light one, the body on a dark one). Seven slots, no LED: this console
/// has no lamp on the page.
struct SNESSkinPalette: Equatable, Codable {
    var bodyHex: UInt32      // body gradient + shoulders + carved seats (derived) + brand capsule
    var surroundHex: UInt32  // screen panel AND the ring the four faces sit in
    var padHex: UInt32       // D-pad cross, SELECT/START pills, MENU/CLIP backgrounds
    var faceAHex: UInt32     // A
    var faceBHex: UInt32     // B
    var faceXHex: UInt32     // X
    var faceYHex: UInt32     // Y

    var body: UIColor     { UIColor(rpHex: bodyHex) }
    var surround: UIColor { UIColor(rpHex: surroundHex) }
    var pad: UIColor      { UIColor(rpHex: padHex) }
    var faceA: UIColor    { UIColor(rpHex: faceAHex) }
    var faceB: UIColor    { UIColor(rpHex: faceBHex) }
    var faceX: UIColor    { UIColor(rpHex: faceXHex) }
    var faceY: UIColor    { UIColor(rpHex: faceYHex) }

    var isWithinHexRange: Bool {
        [bodyHex, surroundHex, padHex, faceAHex, faceBHex, faceXHex, faceYHex]
            .allSatisfy { $0 <= 0xFFFFFF }
    }

    /// SNES Nostalgia, slot for slot (the spec of 2026-08-12, with B's 08-13 yellow).
    static let nostalgia = SNESSkinPalette(
        bodyHex: 0xD7D3CF, surroundHex: 0x6D6D6D, padHex: 0x262628,
        faceAHex: 0xCF352E, faceBHex: 0xEFC446, faceXHex: 0x294091, faceYHex: 0x366840)
}

// MARK: - NES (4 slots — one face colour, so fewer than the Super Nintendo needs)

/// The NES has ONE face colour for A and B, which is the whole reason it needs four slots where
/// the Super Nintendo needs seven. `face` paints both buttons AND the red band across the shell,
/// deliberately: on the real machine they are the same red, and a skin that could separate them
/// could also produce a pad whose band belongs to another console.
///
/// Everything the dress derives stays derived: the letters (the face colour darkened by half,
/// engraved), the two sunken WELLS (the body darkened by a third, so they always read as a
/// shadow of the shell), the carved seats, and the printed SELECT/START words.
struct NESSkinPalette: Equatable, Codable {
    var bodyHex: UInt32      // shell gradient + the wells and seats (derived) + brand capsule
    var surroundHex: UInt32  // the inlaid panel around the screen
    var padHex: UInt32       // cross, SELECT/START pills, MENU/CLIP backgrounds
    var faceHex: UInt32      // A and B, and the band across the shell

    var body: UIColor     { UIColor(rpHex: bodyHex) }
    var surround: UIColor { UIColor(rpHex: surroundHex) }
    var pad: UIColor      { UIColor(rpHex: padHex) }
    var face: UIColor     { UIColor(rpHex: faceHex) }

    var isWithinHexRange: Bool {
        [bodyHex, surroundHex, padHex, faceHex].allSatisfy { $0 <= 0xFFFFFF }
    }

    /// NES Nostalgia, slot for slot, from the spec of 2026-08-18.
    ///
    /// Note which way round this console is: the SHELL is near-black and the screen surround is
    /// the light one, the opposite of every other dress here. Two derivations invert with it (the
    /// printed words and the seats), and the fifth colour, the light grey the wells and the
    /// cross's outline share, is `DressKind.nesWell` rather than a slot: it is the same tone in
    /// three places and a skin that could split them could also lose the outline that is the only
    /// thing separating a near-black cross from a near-black shell.
    static let nostalgia = NESSkinPalette(
        bodyHex: 0x191A1C, surroundHex: 0xCDCCD1, padHex: 0x0A0A0A, faceHex: 0x852621)

    /// NES Retro Pal. Not a user palette: it exists so the recolour can answer PER CONTROL
    /// through the same slots a custom skin uses, instead of the one-colour-per-console answer
    /// `RetroPalPalette.buttonFill` gives, which would have painted the faces with the pad.
    ///
    /// Pad and face are the SAME colour since 2026-08-18: on this shell the whole control layer
    /// reads as one light thing, and the deep indigo that used to be the pad became the ink the
    /// MENU and CLIP glyphs are drawn in (`RetroPalPalette.nesInk`). The two slots stay separate
    /// because a CUSTOM skin can still split them.
    static let retroPal = NESSkinPalette(
        bodyHex: 0x050505, surroundHex: 0x2C2E2D, padHex: 0xC3C3EE, faceHex: 0xC3C3EE)
}

// MARK: - The console-tagged palette

enum SkinPalette: Equatable, Codable {
    case gbc(GBCSkinPalette)
    case gba(GBASkinPalette)
    case nds(NDSSkinPalette)
    case snes(SNESSkinPalette)
    case nes(NESSkinPalette)

    /// The console this palette belongs to (must match the owning CustomSkin's system).
    var system: PresetSystem {
        switch self {
        case .gbc: return .gbc
        case .gba: return .gba
        case .nds: return .nds
        case .snes: return .snes
        case .nes: return .nes
        }
    }

    var isWithinHexRange: Bool {
        switch self {
        case .gbc(let p): return p.isWithinHexRange
        case .gba(let p): return p.isWithinHexRange
        case .nds(let p): return p.isWithinHexRange
        case .snes(let p): return p.isWithinHexRange
        case .nes(let p): return p.isWithinHexRange
        }
    }

    /// The Nostalgia look for `system`, the canvas a freshly opened editor starts from.
    static func nostalgiaSeed(for system: PresetSystem) -> SkinPalette {
        switch system {
        case .gbc: return .gbc(.nostalgia)
        case .gba: return .gba(.nostalgia)
        case .nds: return .nds(.nostalgia)
        case .snes: return .snes(.nostalgia)
        case .nes: return .nes(.nostalgia)
        }
    }
}
