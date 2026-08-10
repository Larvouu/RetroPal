//
//  GBPalettes.swift
//  EmulateurGBA
//
//  The Game Boy (DMG) palette catalog behind the Appearance sheet's Screen tab.
//
//  A palette is 4 shades (lightest → darkest, 0xRRGGBB) applied uniformly to
//  the BG and both OBJ layers — uniform on purpose: mixed per-layer sets read
//  as glitches in games that assign layers unexpectedly, and uniform keeps the
//  preview recoloring exact. mGBA receives 12 slots (BG 4 / OBJ0 4 / OBJ1 4)
//  via EmulatorBridge.setGBPalette, live-applied through reloadConfigOption
//  ("gb.pal"), DMG-mode games only (CGB games carry their own colors).
//
//  Palette NAMES are proper nouns and stay unlocalized, like the skin names;
//  only the group titles are localized. Colors are plain RGB values (color
//  palettes carry no copyright); hardware-evoking sets use our own descriptive
//  names, never Nintendo marks.
//
//  The per-game choice is stored as `gbPalette_<romBasename>` (UserDefaults),
//  the same per-game pattern as the skin. Default = Classic Green, the
//  authentic DMG look (deliberately replacing mGBA's washed-grey default —
//  this is the feature's point; Pure Grey is one tap away).
//

import UIKit

struct GBPalette: Identifiable, Equatable {
    let id: String
    /// Display name — proper noun, shown as-is in every locale.
    let name: String
    /// 4 shades, lightest → darkest, 0xRRGGBB.
    let shades: [UInt32]

    /// The 12 mGBA slots: BG, OBJ0, OBJ1 — uniform (see header).
    var colors12: [UInt32] { shades + shades + shades }

    func shadeColor(_ index: Int) -> UIColor {
        let v = shades[index]
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

enum GBPalettes {

    static let defaultID = "classic-green"

    struct Group {
        /// Localization key for the section title.
        let titleKey: String
        let palettes: [GBPalette]
    }

    /// The catalog, grouped for the picker. Order within a group is the
    /// display order.
    static let groups: [Group] = [
        Group(titleKey: "palette.group.originals", palettes: [
            GBPalette(id: "classic-green", name: "Classic Green",
                      shades: [0x9BBC0F, 0x8BAC0F, 0x306230, 0x0F380F]),
            GBPalette(id: "pocket-grey", name: "Pocket Grey",
                      shades: [0xC4CFA1, 0x8B956D, 0x4D533C, 0x1F1F1F]),
            GBPalette(id: "backlight-teal", name: "Backlight Teal",
                      shades: [0x9FF4E5, 0x00B581, 0x006A4E, 0x00291C]),
            GBPalette(id: "pure-grey", name: "Pure Grey",
                      shades: [0xE8E8E8, 0xA0A0A0, 0x585858, 0x101010]),
        ]),
        Group(titleKey: "palette.group.console", palettes: [
            GBPalette(id: "chocolate", name: "Chocolate",
                      shades: [0xFFE4C2, 0xDCA456, 0xA9604C, 0x422936]),
            GBPalette(id: "sky", name: "Sky",
                      shades: [0xFFFFFF, 0x63A5FF, 0x0000FF, 0x000000]),
            GBPalette(id: "crimson", name: "Crimson",
                      shades: [0xFFFFFF, 0xFF8584, 0x943A3A, 0x000000]),
            GBPalette(id: "slate", name: "Slate",
                      shades: [0xFFFFFF, 0x8C8CDE, 0x52528C, 0x000000]),
            GBPalette(id: "rust", name: "Rust",
                      shades: [0xFFFFFF, 0xFFAD63, 0x833100, 0x000000]),
            GBPalette(id: "lemon", name: "Lemon",
                      shades: [0xFFFFFF, 0xFFFF00, 0x7B4A00, 0x000000]),
            GBPalette(id: "meadow", name: "Meadow",
                      shades: [0xFFFFFF, 0x7BFF31, 0x0063C5, 0x000000]),
            GBPalette(id: "inverted", name: "Inverted",
                      shades: [0x000000, 0x008484, 0xFFDE00, 0xFFFFFF]),
        ]),
        Group(titleKey: "palette.group.colors", palettes: [
            GBPalette(id: "retro-pal", name: "Retro Pal",
                      shades: [0xEFEAFF, 0xAF97F5, 0x7558EB, 0x1E1440]),
            GBPalette(id: "lavender", name: "Lavender",
                      shades: [0xF3EAFF, 0xC3A6E0, 0x7C5295, 0x2A1B3D]),
            GBPalette(id: "peach", name: "Peach",
                      shades: [0xFFF6E9, 0xFFBC97, 0xC56D53, 0x4A2325]),
            GBPalette(id: "ocean", name: "Ocean",
                      shades: [0xDDF5FF, 0x86C5DA, 0x3B6E8C, 0x102A3C]),
            GBPalette(id: "forest", name: "Forest",
                      shades: [0xE0F0C8, 0x86B04A, 0x3E6238, 0x11221A]),
            GBPalette(id: "rose", name: "Rose",
                      shades: [0xFFF0F0, 0xF098A8, 0xA05068, 0x38182C]),
            GBPalette(id: "midnight", name: "Midnight",
                      shades: [0xCED8F0, 0x7888B8, 0x3C4470, 0x101028]),
            GBPalette(id: "ember", name: "Ember",
                      shades: [0xFFF4D8, 0xF0A860, 0xB0483C, 0x301820]),
            GBPalette(id: "mint", name: "Mint",
                      shades: [0xE8FFF0, 0x88D8B0, 0x38907C, 0x103830]),
            GBPalette(id: "sepia", name: "Sepia",
                      shades: [0xF8ECD8, 0xC8A878, 0x806040, 0x302010]),
            GBPalette(id: "bubblegum", name: "Bubblegum",
                      shades: [0xFFF2F8, 0xFFA6D5, 0xD14985, 0x4A1030]),
            GBPalette(id: "arctic", name: "Arctic",
                      shades: [0xF8FCFF, 0xB8D8E8, 0x6890A8, 0x182838]),
        ]),
    ]

    static let all: [GBPalette] = groups.flatMap { $0.palettes }

    /// Look up by id; unknown ids (a removed palette after an update) fall back
    /// to the default rather than crashing or going colorless.
    static func palette(id: String) -> GBPalette {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID }!
    }

    /// Per-game persistence key, same basename derivation as skins and saves.
    static func storageKey(forRomBasename romName: String) -> String {
        "gbPalette_\(romName)"
    }

    static func storedID(forRomBasename romName: String) -> String {
        UserDefaults.standard.string(forKey: storageKey(forRomBasename: romName)) ?? defaultID
    }

    // MARK: - Preview recoloring

    /// Recolor a captured DMG game frame from `source`'s shades to `target`'s,
    /// for the picker's live preview cards. Every pixel maps to the NEAREST
    /// source shade (exact equality can't be used: mGBA rounds palette colors
    /// through RGB555, so rendered pixels are close to, not equal to, the
    /// 0xRRGGBB values). ~23k pixels at GB native size; runs once per card.
    static func recolor(_ image: CGImage, from source: GBPalette, to target: GBPalette) -> UIImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        let byteCount = h * bytesPerRow

        let src: [(r: Int, g: Int, b: Int)] = source.shades.map {
            (Int(($0 >> 16) & 0xFF), Int(($0 >> 8) & 0xFF), Int($0 & 0xFF))
        }
        let dst: [(r: UInt8, g: UInt8, b: UInt8)] = target.shades.map {
            (UInt8(($0 >> 16) & 0xFF), UInt8(($0 >> 8) & 0xFF), UInt8($0 & 0xFF))
        }

        // The whole CGContext lifetime stays inside the buffer scope (a Swift
        // array pointer must not outlive its withUnsafe... closure).
        var pixels = [UInt8](repeating: 0, count: byteCount)
        let out: CGImage? = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

            let p = base.assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i < byteCount {
                let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                var best = 0, bestDist = Int.max
                for (s, c) in src.enumerated() {
                    let dr = r - c.r, dg = g - c.g, db = b - c.b
                    let d = dr * dr + dg * dg + db * db
                    if d < bestDist { bestDist = d; best = s }
                }
                p[i] = dst[best].r
                p[i + 1] = dst[best].g
                p[i + 2] = dst[best].b
                i += 4
            }
            return ctx.makeImage()
        }
        return out.map { UIImage(cgImage: $0) }
    }
}
