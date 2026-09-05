//
//  RetroPalPalette.swift
//  EmulateurGBA
//
//  The "Retro Pal" skin recolour. The skin mirrors the Nostalgia console dress shape-for-shape
//  but recolours specific elements per console (a hand-tuned draft). Everything here is consulted
//  ONLY when the dress variant is `.retroPal`; elements the draft marks "untouched" are simply
//  not overridden, so they keep their Nostalgia colour at the call site. Nostalgia is therefore
//  byte-identical to before.
//

import UIKit
import CoreImage

/// Which palette a dressed control / console body wears. `.nostalgia` = the original look
/// (unchanged); `.retroPal` = the recolour below; `.custom` = a user-created `SkinPalette`
/// (see SkinPalette / CustomSkin). Equatable so the dress views' `didSet` redraw guards work —
/// auto-synthesised since `SkinPalette` is Equatable.
enum DressVariant: Equatable { case nostalgia, retroPal, custom(SkinPalette) }

extension DressVariant {
    /// The per-console custom palette when `.custom`, else nil (built-in path untouched). Each
    /// console's views read its own struct (GB/GBC splits its controls; GBA/NDS unify them).
    var gbcPalette: GBCSkinPalette? { if case .custom(.gbc(let p)) = self { return p }; return nil }
    var gbaPalette: GBASkinPalette? { if case .custom(.gba(let p)) = self { return p }; return nil }
    var ndsPalette: NDSSkinPalette? { if case .custom(.nds(let p)) = self { return p }; return nil }
    var snesPalette: SNESSkinPalette? { if case .custom(.snes(let p)) = self { return p }; return nil }
    var nesPalette: NESSkinPalette? { if case .custom(.nes(let p)) = self { return p }; return nil }
    var ps1Palette: PS1SkinPalette? { if case .custom(.ps1(let p)) = self { return p }; return nil }

    /// Per-control dressed face fill, or nil to keep the built-in Nostalgia colour. Retro Pal keeps
    /// its unified recolour (every GB/GBC face → gbcDark; NDS → ndsAccent; GBA untouched). A custom
    /// skin reads the matching slot: GB/GBC splits per control, GBA/NDS share one `buttons` colour.
    private func customFace(_ kind: DressKind, gbc: (GBCSkinPalette) -> UIColor,
                            snes: (SNESSkinPalette) -> UIColor = { $0.pad },
                            nes: (NESSkinPalette) -> UIColor = { $0.face },
                            ps1: (PS1SkinPalette) -> UIColor = { $0.pad }) -> UIColor? {
        switch self {
        case .nostalgia:            return nil
        //Retro Pal answers PER CONTROL on the NES by feeding its own values through the very
        //closures a custom skin uses. `buttonFill` gives one colour per console, which is right
        //for the three that have one and wrong here: it would paint A and B with the pad.
        case .retroPal where kind == .nes: return nes(NESSkinPalette.retroPal)
        case .retroPal:             return RetroPalPalette.buttonFill(kind)
        case .custom(.gbc(let p)):  return gbc(p)
        case .custom(.gba(let p)):  return p.buttons
        case .custom(.nds(let p)):  return p.buttons
        //The SNES answers with its PAD colour, which is what everything reaching this
        //asks about on that console: the cross, the SELECT/START pills, MENU, CLIP and
        //the shoulders. Its four faces never come through here — they are per button,
        //set in `SNESTouchControlsView`, and `ActionButton.dressFace` outranks this.
        case .custom(.snes(let p)): return snes(p)
        //The NES answers with its FACE colour, because the only thing that reaches this on that
        //console is A and B. Its cross and pills ask `dpadFace` / `smallButtonFace`, which take
        //the pad slot through the closures below.
        case .custom(.nes(let p)): return nes(p)
        //The PlayStation answers like the Super Nintendo and for the same reason: its four
        //faces are one plastic with four printed inks, set per button in
        //`PS1TouchControlsView`, and `ActionButton.dressFace` outranks this. So everything
        //that actually reaches here is the cross, the pills, MENU, CLIP and the four
        //shoulders, which on that pad really are one colour.
        case .custom(.ps1(let p)): return ps1(p)
        }
    }
    /// The D-pad cross face (+ its under-discs).
    func dpadFace(_ kind: DressKind) -> UIColor? {
        customFace(kind, gbc: { $0.dpad }, nes: { $0.pad })
    }
    /// The face buttons. On the PlayStation this is the plastic BEHIND the four
    /// symbols and takes its own slot: a pad whose diamond matches its cross is
    /// one look, not the only one. The four symbols themselves never come from
    /// a palette. Square, cross, circle and triangle are how a player
    /// identifies a button, so they stay fixed on every skin, always.
    func abFace(_ kind: DressKind) -> UIColor? {
        customFace(kind, gbc: { $0.abButtons }, ps1: { $0.diamond })
    }
    /// The SELECT / START / MENU / CLIP button faces.
    func smallButtonFace(_ kind: DressKind) -> UIColor? {
        customFace(kind, gbc: { $0.smallButtons }, nes: { $0.pad })
    }
    /// The L/R shoulder faces (GB/GBC has none). The SNES's are the BODY colour with dark
    /// letters, exactly like the real pad, which is why this one asks for a different slot than
    /// every other control on that console.
    func shoulderFace(_ kind: DressKind) -> UIColor? {
        customFace(kind, gbc: { _ in .clear }, snes: { $0.body })
    }
}

enum RetroPalPalette {
    // GB / GBC
    static let gbcBody     = UIColor(rpHex: 0xFFDF60)   // fond
    static let gbcSurround = UIColor(rpHex: 0x070910)   // screen surround
    static let gbcCreuse   = UIColor(rpHex: 0xE2C553)   // creusé (engraved) areas
    static let gbcStripe   = UIColor(rpHex: 0xFFDF60)   // both "DOT MATRIX" stripe lines
    static let gbcDark     = UIColor(rpHex: 0x070910)   // D-pad, A/B, SELECT/START/MENU/CLIP

    // GBA
    static let gbaBody     = UIColor(rpHex: 0x050505)   // fond
    static let gbaSurround = UIColor(rpHex: 0x2C2E2D)   // screen surround
    static let gbaCreuse   = UIColor(rpHex: 0x191A19)   // creusé: between surround and body

    // SNES. SPECIFIED 2026-08-17, replacing the provisional pair: the body and the surround are
    // the GBA's own Retro Pal values, so the two consoles read as one brand, and the four faces
    // collapse to TWO — X/Y light, A/B deep — instead of the Nostalgia dress's four. That is the
    // one place a Retro Pal recolour touches a face colour: the GBA's buttons are untouched
    // because it has no face colour to speak of, while here the four colours would fight a
    // two-tone shell.
    static let snesBody     = gbaBody                    // fond, the GBA's
    static let snesSurround = gbaSurround                // screen surround, the GBA's
    static let snesCreuse   = gbaCreuse                  // carved seats, the GBA's
    static let snesXY       = UIColor(rpHex: 0xC3C3EE)   // X and Y faces
    static let snesAB       = UIColor(rpHex: 0x3D3392)   // A and B faces

    // NES. Same construction as the SNES's above: the GBA's shell so the two read as one brand,
    // and ONE face colour because this console has one. The light lilac is the SNES's X/Y, which
    // is the pair that reads on a near-black body; the deep one would disappear into it.
    //
    // ONE colour for every control, 2026-08-18. The cross, the two pills, the printed SELECT and
    // START, the MENU/CLIP discs and the A and B faces are all `nesFace`, so this dress reads as
    // one light layer on a near-black shell instead of a light pair on deep-indigo everything
    // else. The indigo stays as the INK that goes on top of it (the MENU and CLIP glyphs), where
    // it has a light ground to sit on.
    static let nesBody     = gbaBody                     // fond, the GBA's
    static let nesSurround = gbaSurround                 // screen panel, the GBA's
    static let nesCreuse   = gbaCreuse                   // carved seats, the GBA's
    static let nesFace     = UIColor(rpHex: 0xC3C3EE)    // every control, and the band
    static let nesInk      = UIColor(rpHex: 0x3D3392)    // MENU / CLIP glyphs, on the above

    // PlayStation. Two values do the whole console, because one dark tone does
    // every control on this pad: there are no per-button slots to recolour.
    static let ps1Body     = UIColor(rpHex: 0x1F1F1F)    // fond
    static let ps1Surround = UIColor(rpHex: 0x000000)    // screen panel: black, as on the Nostalgia dress
    static let ps1Face     = UIColor(rpHex: 0x727272)    // every control

    // NDS
    static let ndsBody     = UIColor(rpHex: 0x595A76)   // fond
    static let ndsAccent   = UIColor(rpHex: 0xEBEBEB)   // button fill: D-pad, A/B/X/Y, L/R, joystick (= the SELECT tiny button)
    static let ndsInk      = UIColor(rpHex: 0x777777)   // grey ink: A/B/X/Y + L/R labels, D-pad arm lines, menu/clip icons (= the MIC outer line)

    /// Builds the Retro Pal brand mark monochrome-tinted to `color` (the per-console SELECT/START
    /// label colour), preserving detail — same CIColorMonochrome treatment the dresses use, so the
    /// brand icon's average colour matches the wordmark.
    private static let ciContext = CIContext(options: nil)
    static func brandIcon(tinted color: UIColor) -> UIImage? {
        guard let base = UIImage(named: "RetroPalBrand"), let ci = CIImage(image: base) else {
            return UIImage(named: "RetroPalBrand")
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        guard let f = CIFilter(name: "CIColorMonochrome", parameters: [
            kCIInputImageKey: ci, "inputColor": CIColor(red: r, green: g, blue: b),
            "inputIntensity": 1.0,
        ]), let out = f.outputImage,
            let cg = ciContext.createCGImage(out, from: out.extent) else {
            return UIImage(named: "RetroPalBrand")
        }
        return UIImage(cgImage: cg)
    }

    /// The dressed-button fill for `kind` under Retro Pal, or nil if untouched (keep the
    /// Nostalgia fill). Shared by the D-pad, A/B and (GB/GBC) small buttons.
    static func buttonFill(_ kind: DressKind) -> UIColor? {
        switch kind {
        case .gbc: return gbcDark
        case .nds: return ndsAccent
        case .gba: return nil          // GBA buttons untouched
        //Everything on the SNES that is NOT a face button: the cross, the SELECT/START pills,
        //MENU, CLIP and the shoulders. The body is the GBA's near-black under Retro Pal, so the
        //Nostalgia dress's near-black pad would disappear into it; these take the GBA's own
        //light button colour, which is what "the GBA's Retro Pal" looks like. The four FACES do
        //not come through here: they are per button, set in SNESTouchControlsView, and
        //`ActionButton.dressFace` outranks this.
        case .snes: return DressKind.gbaButton
        //Unreachable for the NES: `customFace` answers that console through
        //`NESSkinPalette.retroPal` before it ever gets here, because this function gives ONE
        //colour per console and the NES needed a per-control answer. Kept exhaustive (and
        //correct: since the 08-18 unification every control on it wears the face colour) rather
        //than fatalError-ing on a case the compiler can still reach.
        case .nes: return RetroPalPalette.nesFace
        // Same shape of answer as the SNES: everything that is NOT a face
        // button takes the GBA's light button colour, because the Retro Pal
        // body is near-black and this pad's own warm grey would sink into it.
        // The four faces do not come through here either: PS1TouchControlsView
        // sets `dressFace` per button and that outranks this.
        case .ps1: return DressKind.gbaButton
        }
    }

    /// A 3-stop vertical body gradient (lighter top, base, darker bottom) derived from a flat
    /// `fond`, matching how the dresses build their body.
    static func bodyGradient(_ base: UIColor) -> (top: UIColor, mid: UIColor, bottom: UIColor) {
        (base.rpMixed(with: .white, 0.07), base, base.rpMixed(with: .black, 0.12))
    }
}

extension UIColor {
    /// 0xRRGGBB convenience (named `rpHex` to avoid clashing with any future hex initialiser).
    convenience init(rpHex: UInt32) {
        self.init(red: CGFloat((rpHex >> 16) & 0xFF) / 255,
                  green: CGFloat((rpHex >> 8) & 0xFF) / 255,
                  blue: CGFloat(rpHex & 0xFF) / 255, alpha: 1)
    }

    /// This colour mixed toward `other` by `t` (0…1). Used to derive pressed/edge tones from a
    /// single Retro Pal fill so the buttons keep their press feedback.
    func rpMixed(with other: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t,
                       blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }

    /// Slightly darker (pressed) / darker still (edge), derived from a fill.
    var rpPressed: UIColor { rpMixed(with: .black, 0.18) }
    var rpEdge: UIColor    { rpMixed(with: .black, 0.30) }

    /// Whether this colour is light enough that a mark drawn ON it should be dark. Perceived
    /// luminance, the same weights `rpContrastingMark` uses. Exists because a derivation that is
    /// right on a pale shell inverts on a near-black one: "the body, darkened" is a legible
    /// printed word on the Super Nintendo's grey and an invisible one on Retro Pal's black.
    var rpIsLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.5
    }

    /// A high-contrast, SAME-HUE tint for a mark drawn ON this colour — a dark shade of the hue on
    /// a light background, a light shade on a dark one — so it stays clearly legible yet harmonious
    /// (pale purple → dark purple; white → near-black; near-black → near-white). Used for the
    /// auto-coloured brand mark, which is not a user slot.
    var rpContrastingMark: UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a2: CGFloat = 0
        getRed(&r, green: &g, blue: &bl, alpha: &a2)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * bl
        return luminance > 0.5
            ? UIColor(hue: h, saturation: min(1, s + 0.15), brightness: 0.16, alpha: 1)  // dark, saturated
            : UIColor(hue: h, saturation: s * 0.55, brightness: 0.95, alpha: 1)          // light, soft
    }
}
