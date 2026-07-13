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

    /// Per-control dressed face fill, or nil to keep the built-in Nostalgia colour. Retro Pal keeps
    /// its unified recolour (every GB/GBC face → gbcDark; NDS → ndsAccent; GBA untouched). A custom
    /// skin reads the matching slot: GB/GBC splits per control, GBA/NDS share one `buttons` colour.
    private func customFace(_ kind: DressKind, gbc: (GBCSkinPalette) -> UIColor) -> UIColor? {
        switch self {
        case .nostalgia:            return nil
        case .retroPal:             return RetroPalPalette.buttonFill(kind)
        case .custom(.gbc(let p)):  return gbc(p)
        case .custom(.gba(let p)):  return p.buttons
        case .custom(.nds(let p)):  return p.buttons
        }
    }
    /// The D-pad cross face (+ its under-discs).
    func dpadFace(_ kind: DressKind) -> UIColor? { customFace(kind) { $0.dpad } }
    /// The A/B button faces.
    func abFace(_ kind: DressKind) -> UIColor? { customFace(kind) { $0.abButtons } }
    /// The SELECT / START / MENU / CLIP button faces.
    func smallButtonFace(_ kind: DressKind) -> UIColor? { customFace(kind) { $0.smallButtons } }
    /// The L/R shoulder faces (GBA / NDS only; GB/GBC has no shoulders).
    func shoulderFace(_ kind: DressKind) -> UIColor? { customFace(kind) { _ in .clear } }
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
