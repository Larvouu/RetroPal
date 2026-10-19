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

/// PlayStation.
///
/// Four slots, like the NES, and for the same reason inverted: on this pad the
/// four face buttons are ONE grey plastic, so there are no per-letter slots.
/// What differs between them is the printed SYMBOL, and those four inks are
/// fixed hardware facts rather than user-choosable slots.
struct PS1SkinPalette: Equatable, Codable {
    var bodyHex: UInt32      // the console's shell
    var surroundHex: UInt32  // the panel around the screen
    var padHex: UInt32       // the cross, and the SELECT/START printing
    var faceHex: UInt32      // the four face buttons, which are one plastic
    /// Everything on this pad that is INK rather than plastic: the words on
    /// SELECT, START and the shoulders, and the MENU / CLIP glyphs. Added
    /// 2026-08-27. A word moulded into a plate still derives from its plate;
    /// this is for the printed things, which have every right to their own
    /// colour because printing is not moulding.
    var printHex: UInt32
    /// The plastic BEHIND the four face buttons. Their four symbols are
    /// deliberately absent from this struct and always will be: square, cross,
    /// circle and triangle are how a player identifies a button, so they are
    /// the one thing on this pad nobody gets to recolour.
    var diamondHex: UInt32

    var body: UIColor     { UIColor(rpHex: bodyHex) }
    var surround: UIColor { UIColor(rpHex: surroundHex) }
    var pad: UIColor      { UIColor(rpHex: padHex) }
    var face: UIColor     { UIColor(rpHex: faceHex) }
    var print: UIColor    { UIColor(rpHex: printHex) }
    var diamond: UIColor  { UIColor(rpHex: diamondHex) }

    var isWithinHexRange: Bool {
        [bodyHex, surroundHex, padHex, faceHex, printHex, diamondHex]
            .allSatisfy { $0 <= 0xFFFFFF }
    }

    /// Skins saved before the two slots existed decode with them absent, so
    /// they default rather than failing the whole skin. Without this, every
    /// custom PlayStation skin a user already made would stop loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bodyHex = try c.decode(UInt32.self, forKey: .bodyHex)
        surroundHex = try c.decode(UInt32.self, forKey: .surroundHex)
        padHex = try c.decode(UInt32.self, forKey: .padHex)
        faceHex = try c.decode(UInt32.self, forKey: .faceHex)
        // The old behaviour, expressed as data: print was a shade of its plate,
        // and the diamond's backing was the one control colour.
        printHex = try c.decodeIfPresent(UInt32.self, forKey: .printHex)
            ?? Self.mixedTowardWhite(padHex, 0.55)
        diamondHex = try c.decodeIfPresent(UInt32.self, forKey: .diamondHex) ?? padHex
    }

    /// The old print rule as integer arithmetic: each channel 55% of the way to
    /// white. Done on the hex rather than by round-tripping a `UIColor`,
    /// because a colour-space conversion in a decoder is a lot of machinery to
    /// reproduce a number that is three multiplications.
    private static func mixedTowardWhite(_ hex: UInt32, _ t: Double) -> UInt32 {
        var out: UInt32 = 0
        for shift in [16, 8, 0] {
            let channel = Double((hex >> UInt32(shift)) & 0xFF)
            let mixed = channel + (255.0 - channel) * t
            out |= UInt32(mixed.rounded()) << UInt32(shift)
        }
        return out
    }

    init(bodyHex: UInt32, surroundHex: UInt32, padHex: UInt32, faceHex: UInt32,
         printHex: UInt32, diamondHex: UInt32) {
        self.bodyHex = bodyHex
        self.surroundHex = surroundHex
        self.padHex = padHex
        self.faceHex = faceHex
        self.printHex = printHex
        self.diamondHex = diamondHex
    }

    /// Taken from `DressKind.ps1*`, so the dress and the palette describe one
    /// machine rather than two that happen to look similar.
    static let nostalgia = PS1SkinPalette(
        bodyHex: 0xBEBEBC, surroundHex: 0x000000, padHex: 0x404145, faceHex: 0x404145,
        printHex: 0x9B9BA0, diamondHex: 0x404145)

    /// The Retro Pal recolour. `pad` and `face` are the same value here for the
    /// same reason they are on the Nostalgia dress: this console has one control
    /// colour and four printed symbols, so a recolour that split them would be
    /// inventing a distinction the hardware does not have.
    static let retroPal = PS1SkinPalette(
        bodyHex: 0x1F1F1F, surroundHex: 0x000000, padHex: 0x727272, faceHex: 0x727272,
        printHex: 0xC0C0C0, diamondHex: 0x727272)

    /// The PSP's two looks in the PlayStation's slots, as the shared dress
    /// code reads them. Their own palette is `PSPSkinPalette` (2026-10-11).
    static var pspNostalgia: PS1SkinPalette { PSPSkinPalette.nostalgia.asPS1 }
    static var pspRetroPal: PS1SkinPalette { PSPSkinPalette.retroPal.asPS1 }
}

/// Nintendo 64 (2026-09-27).
///
/// THIRTEEN SLOTS, the most of any console, and on purpose: this pad's colours
/// are a set of separate plastics (a blue A, a green B, four yellow C buttons, a
/// red START, grey triggers), and the ask was that a skin can split what the
/// hardware split, A from B, MENU and CLIP from L and R. So every colour the
/// dress paints is its own slot. What is NOT a slot derives, as on every other
/// console: each word, letter and triangle set into a button is its button's
/// colour a shade darker, the grooves and the plaque follow the shell, and the
/// shoulders' shading is the shell darkened.
struct N64SkinPalette: Equatable, Codable {
    var bodyHex: UInt32           // the shell
    var shouldersHex: UInt32      // L and R
    var menuButtonsHex: UInt32    // the MENU and CLIP discs
    var menuIconsHex: UInt32      // the MENU and CLIP glyphs
    var dpadHex: UInt32           // the cross
    var dpadMarksHex: UInt32      // the four triangles set into the cross
    var stickHex: UInt32          // the stick
    var stickSurroundHex: UInt32  // the raised disc the stick stands in
    var aHex: UInt32
    var bHex: UInt32
    var zHex: UInt32
    var cHex: UInt32              // the four C buttons
    var startHex: UInt32

    var body: UIColor          { UIColor(rpHex: bodyHex) }
    var shoulders: UIColor     { UIColor(rpHex: shouldersHex) }
    var menuButtons: UIColor   { UIColor(rpHex: menuButtonsHex) }
    var menuIcons: UIColor     { UIColor(rpHex: menuIconsHex) }
    var dpad: UIColor          { UIColor(rpHex: dpadHex) }
    var dpadMarks: UIColor     { UIColor(rpHex: dpadMarksHex) }
    var stick: UIColor         { UIColor(rpHex: stickHex) }
    var stickSurround: UIColor { UIColor(rpHex: stickSurroundHex) }
    var a: UIColor             { UIColor(rpHex: aHex) }
    var b: UIColor             { UIColor(rpHex: bHex) }
    var z: UIColor             { UIColor(rpHex: zHex) }
    var c: UIColor             { UIColor(rpHex: cHex) }
    var start: UIColor         { UIColor(rpHex: startHex) }

    var isWithinHexRange: Bool {
        [bodyHex, shouldersHex, menuButtonsHex, menuIconsHex, dpadHex, dpadMarksHex, stickHex,
         stickSurroundHex, aHex, bHex, zHex, cHex, startHex].allSatisfy { $0 <= 0xFFFFFF }
    }

    /// The Classic dress, value for value (`DressKind.n64*`, revised 2026-09-27).
    /// `menuIconsHex` is the glyph the Classic dress derives from its disc
    /// (#8C8F9E darkened by 0.42, the rule for a light disc), so a skin opened
    /// from Classic starts exactly where the Classic dress is.
    static let nostalgia = N64SkinPalette(
        bodyHex: 0xC4C7CA, shouldersHex: 0x8C8F9E, menuButtonsHex: 0x8C8F9E,
        menuIconsHex: 0x51535C, dpadHex: 0x8C8F9E, dpadMarksHex: 0x5A5C66,
        stickHex: 0x787984, stickSurroundHex: 0x8C8F9E, aHex: 0x4070FF, bHex: 0x60C975,
        zHex: 0xFFCC4A, cHex: 0xFFCC4A, startHex: 0xDB0012)

    /// The Retro Pal recolour: the shell only.
    static let retroPal: N64SkinPalette = {
        var p = nostalgia
        p.bodyHex = 0x253E8B
        return p
    }()
}

/// The Mega Drive's dress, every colour it paints a slot, as on the Nintendo 64.
/// Both built-in palettes were given 2026-10-08, verbatim below.
///
/// The labels are the one thing the two looks do differently. Classic PRINTS
/// them, in one light ink on dark plastic (`labelsHex`). Retro Pal SETS each one
/// INTO its own button, the button's colour a shade darker, the Nintendo 64's
/// rule (`DressKind.n64Incised`), so there it is no colour of its own:
/// `incisedLabels` says which, and a custom skin starts from Classic's printed
/// ink, which it may recolour.
struct MDSkinPalette: Equatable, Codable {
    var bodyHex: UInt32          // the shell
    var padHex: UInt32           // the cross
    var abcHex: UInt32           // A, B and C
    var xyzHex: UInt32           // X, Y and Z
    var smallButtonsHex: UInt32  // MODE and START, MENU and CLIP
    var labelsHex: UInt32        // the printed letters, words and the MENU / CLIP glyphs
    var incisedLabels: Bool

    var body: UIColor         { UIColor(rpHex: bodyHex) }
    var pad: UIColor          { UIColor(rpHex: padHex) }
    var abc: UIColor          { UIColor(rpHex: abcHex) }
    var xyz: UIColor          { UIColor(rpHex: xyzHex) }
    var smallButtons: UIColor { UIColor(rpHex: smallButtonsHex) }
    var labels: UIColor       { UIColor(rpHex: labelsHex) }

    /// The mark on a control of colour `plate`: Classic's printed ink, or the
    /// plate itself a shade darker when the marks are set in.
    func label(on plate: UIColor) -> UIColor {
        incisedLabels ? DressKind.n64Incised(plate) : labels
    }

    var isWithinHexRange: Bool {
        [bodyHex, padHex, abcHex, xyzHex, smallButtonsHex, labelsHex].allSatisfy { $0 <= 0xFFFFFF }
    }

    /// Classic (given 2026-10-08): a #202125 shell, every control #2F2F2F, the
    /// letters, words and MENU / CLIP glyphs printed #C0C0CD.
    static let nostalgia = MDSkinPalette(bodyHex: 0x202125, padHex: 0x2F2F2F, abcHex: 0x2F2F2F,
                                         xyzHex: 0x2F2F2F, smallButtonsHex: 0x2F2F2F,
                                         labelsHex: 0xC0C0CD, incisedLabels: false)

    /// Retro Pal (given 2026-10-08): a #DCDCDA shell, A B C #933A53, X Y Z
    /// #929292, the cross #494949, MODE and START the shell's own colour, and
    /// every label set into its button. MENU and CLIP were not named; they
    /// take MODE and START's treatment, the shell with the glyph set in, as
    /// they share those two's colour on Classic.
    static let retroPal = MDSkinPalette(bodyHex: 0xDCDCDA, padHex: 0x494949, abcHex: 0x933A53,
                                        xyzHex: 0x929292, smallButtonsHex: 0xDCDCDA,
                                        labelsHex: 0xC0C0CD, incisedLabels: true)
}

/// The Master System's dress (2026-10-10), every colour it paints a slot,
/// as on the Mega Drive. Both built-in looks are the values the dress drew
/// before these palettes existed (`DressKind.smsLook`), so neither moves.
///
/// What is NOT a slot: the shading every piece derives from its own colour
/// (the faces a step lighter than the cross, which is one rubber on the pad),
/// and the black of the holes, seats and the PAUSE plate, which are holes in
/// the shell rather than a colour of it.
struct SMSSkinPalette: Equatable, Codable {
    var bodyHex: UInt32      // the shell
    var surroundHex: UInt32  // the panel round the picture
    var plateHex: UInt32     // the grey squares the cross and 1 and 2 sit on
    var accentHex: UInt32    // the red: the keyline round the cross, the bars, the line under the panel
    var keysHex: UInt32      // the rubber of the cross, 1, 2, PAUSE's rocker, MENU and CLIP
    var onAccentHex: UInt32  // printed on the red bars and on PAUSE, the arrowheads, the MENU / CLIP glyphs
    var inkHex: UInt32       // printed on the shell: CONTROL PAD, Retro Pal

    var body: UIColor     { UIColor(rpHex: bodyHex) }
    var surround: UIColor { UIColor(rpHex: surroundHex) }
    var plate: UIColor    { UIColor(rpHex: plateHex) }
    var accent: UIColor   { UIColor(rpHex: accentHex) }
    var keys: UIColor     { UIColor(rpHex: keysHex) }
    var onAccent: UIColor { UIColor(rpHex: onAccentHex) }
    var ink: UIColor      { UIColor(rpHex: inkHex) }

    var isWithinHexRange: Bool {
        [bodyHex, surroundHex, plateHex, accentHex, keysHex, onAccentHex, inkHex]
            .allSatisfy { $0 <= 0xFFFFFF }
    }

    /// Classic (sampled from the pad's photographs, agreed 2026-10-10).
    static let nostalgia = SMSSkinPalette(bodyHex: 0x232325, surroundHex: 0x111112, plateHex: 0x6E6F73,
                                          accentHex: 0xC4281E, keysHex: 0x2B2B2D, onAccentHex: 0xF2F2F2,
                                          inkHex: 0xF2F2F2)
    /// The light Retro Pal (2026-10-10, approved 10-11): the shell pale, the
    /// red kept, anything printed on the shell dark.
    static let retroPal = SMSSkinPalette(bodyHex: 0xE4E4E6, surroundHex: 0x1C1C1E, plateHex: 0xB9BABF,
                                         accentHex: 0xC4281E, keysHex: 0x3A3A3E, onAccentHex: 0xF2F2F2,
                                         inkHex: 0x2B2B2D)
}

/// The Game Gear's dress (given verbatim 2026-10-10), every colour it paints
/// a slot. Both built-in looks are the dress's own values (`DressKind.ggLook`).
///
/// What is NOT a slot: the three pills and the lamp beside the picture, which
/// are the console's printed marks (like the PlayStation's four symbols), and
/// the derived shading.
struct GGSkinPalette: Equatable, Codable {
    var bodyHex: UInt32      // the shell
    var surroundHex: UInt32  // the panel round the picture
    var buttonsHex: UInt32   // the cross, 1, 2, MENU and CLIP
    var startHex: UInt32     // START's disc
    var glyphsHex: UInt32    // the MENU / CLIP glyphs, and POWER on the panel
    var inkHex: UInt32       // printed on the shell: the 1 · 2 figure, START's word

    var body: UIColor     { UIColor(rpHex: bodyHex) }
    var surround: UIColor { UIColor(rpHex: surroundHex) }
    var buttons: UIColor  { UIColor(rpHex: buttonsHex) }
    var start: UIColor    { UIColor(rpHex: startHex) }
    var glyphs: UIColor   { UIColor(rpHex: glyphsHex) }
    var ink: UIColor      { UIColor(rpHex: inkHex) }

    var isWithinHexRange: Bool {
        [bodyHex, surroundHex, buttonsHex, startHex, glyphsHex, inkHex].allSatisfy { $0 <= 0xFFFFFF }
    }

    /// Classic (given verbatim 2026-10-10).
    static let nostalgia = GGSkinPalette(bodyHex: 0x4D5763, surroundHex: 0x10171A, buttonsHex: 0x2A343C,
                                         startHex: 0x6993D7, glyphsHex: 0xEDF2F4, inkHex: 0xEDF2F4)
    /// The light Retro Pal (2026-10-10, approved 10-11).
    static let retroPal = GGSkinPalette(bodyHex: 0xD9DCE0, surroundHex: 0x2A3036, buttonsHex: 0x8A929B,
                                        startHex: 0x6993D7, glyphsHex: 0xEDF2F4, inkHex: 0x2A3036)
}

/// The PSP's dress (2026-10-11), every colour it paints a slot. The PSP
/// wears the PlayStation's pad SHAPES, so the dress code reads it through
/// `asPS1` (its PlayStation view, field for field what the two built-in PSP
/// looks were until this palette); what is its own (L and R, the nub, the
/// glass) is read here. `DressVariant.isPSP` asks for THIS type, not for two
/// exact colour values, so a custom skin keeps every piece that is the PSP's.
///
/// What is NOT a slot: the four symbols' SHAPES, drawn in the marks' one grey
/// as on the PSP-1000 (`printHex`), and POWER's green, a light the shell
/// shows rather than a colour of it.
struct PSPSkinPalette: Equatable, Codable {
    var bodyHex: UInt32       // the shell, and the plastic of the cross, faces, SELECT and START
    var surroundHex: UInt32   // the panel round the picture
    var controlsHex: UInt32   // the cross, the four faces, MENU and CLIP
    var printHex: UInt32      // the marks: the symbols, the triangles in the arrows, the words
    var shouldersHex: UInt32  // L and R
    var stickHex: UInt32      // the nub
    /// The Retro Pal look: the faces, the arrows and L / R drawn as clear glass
    /// over the shell (their slots then carry the shell's colour, the glass is
    /// drawn over it). A look, not a colour, so a skin keeps the one it started from.
    var glass: Bool

    var body: UIColor      { UIColor(rpHex: bodyHex) }
    var surround: UIColor  { UIColor(rpHex: surroundHex) }
    var controls: UIColor  { UIColor(rpHex: controlsHex) }
    var print: UIColor     { UIColor(rpHex: printHex) }
    var shoulders: UIColor { UIColor(rpHex: shouldersHex) }
    var stick: UIColor     { UIColor(rpHex: stickHex) }

    var isWithinHexRange: Bool {
        [bodyHex, surroundHex, controlsHex, printHex, shouldersHex, stickHex].allSatisfy { $0 <= 0xFFFFFF }
    }

    /// The PlayStation palette the shared dress code reads: shell, panel, the
    /// one control plastic (cross, faces' backing), the print.
    var asPS1: PS1SkinPalette {
        PS1SkinPalette(bodyHex: bodyHex, surroundHex: surroundHex, padHex: controlsHex,
                       faceHex: controlsHex, printHex: printHex, diamondHex: controlsHex)
    }

    /// Nostalgia (given verbatim 2026-10-10): the piano-black shell and the
    /// controls #2F2F2F, glossy black on black as on the PSP-1000; the marks
    /// #A7A7A7; L and R the PSP-1000's silver #F3F3F3; the nub the shell's
    /// black #1E1E1E.
    static let nostalgia = PSPSkinPalette(bodyHex: 0x2F2F2F, surroundHex: 0x000000, controlsHex: 0x2F2F2F,
                                          printHex: 0xA7A7A7, shouldersHex: 0xF3F3F3, stickHex: 0x1E1E1E,
                                          glass: false)
    /// Retro Pal (given verbatim 2026-10-10): a light grey shell #D4D4D4, the
    /// marks #6D7073, the nub #AFB2B6; the faces, the arrows and L / R clear
    /// glass over the shell.
    static let retroPal = PSPSkinPalette(bodyHex: 0xD4D4D4, surroundHex: 0x000000, controlsHex: 0xD4D4D4,
                                         printHex: 0x6D7073, shouldersHex: 0xD4D4D4, stickHex: 0xAFB2B6,
                                         glass: true)
}

// MARK: - The console-tagged palette

enum SkinPalette: Equatable, Codable {
    case gbc(GBCSkinPalette)
    case gba(GBASkinPalette)
    case nds(NDSSkinPalette)
    case snes(SNESSkinPalette)
    case nes(NESSkinPalette)
    case ps1(PS1SkinPalette)
    case n64(N64SkinPalette)
    case md(MDSkinPalette)
    case sms(SMSSkinPalette)
    case gg(GGSkinPalette)
    case psp(PSPSkinPalette)

    /// The console this palette belongs to (must match the owning CustomSkin's system).
    var system: PresetSystem {
        switch self {
        case .gbc: return .gbc
        case .gba: return .gba
        case .nds: return .nds
        case .snes: return .snes
        case .nes: return .nes
        case .ps1: return .ps1
        case .n64: return .n64
        case .md: return .md
        case .sms: return .sms
        case .gg: return .gg
        case .psp: return .psp
        }
    }

    var isWithinHexRange: Bool {
        switch self {
        case .gbc(let p): return p.isWithinHexRange
        case .gba(let p): return p.isWithinHexRange
        case .nds(let p): return p.isWithinHexRange
        case .snes(let p): return p.isWithinHexRange
        case .nes(let p): return p.isWithinHexRange
        case .ps1(let p): return p.isWithinHexRange
        case .n64(let p): return p.isWithinHexRange
        case .md(let p): return p.isWithinHexRange
        case .sms(let p): return p.isWithinHexRange
        case .gg(let p): return p.isWithinHexRange
        case .psp(let p): return p.isWithinHexRange
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
        case .ps1: return .ps1(.nostalgia)
        case .n64: return .n64(.nostalgia)
        case .md: return .md(.nostalgia)
        case .sms: return .sms(.nostalgia)
        case .gg: return .gg(.nostalgia)
        case .psp: return .psp(.nostalgia)
        }
    }
}
