//
//  Sega8BitTests.swift
//  EmulateurGBATests
//
//  The Master System and the Game Gear, added in 1.3.4 on MesenCE, the core
//  that already runs the Super Nintendo and the NES. What is here is what only
//  these two have: their extensions and parse, their pad (a cross, 1 and 2, and
//  one more button, PAUSE on the Master System and START on the Game Gear), the
//  names their controls print, where a physical pad's buttons land, their save
//  sizes and their cheat family.
//
//  The overlap, off-page and picture sweeps over every phone and tablet run in
//  EmulatorLayoutGeometryTests and TabletLayoutTests, which carry both consoles
//  in their console lists. The bridge itself (the picture's size, the sound,
//  the pad, save states, Game Genie and Pro Action Replay) was run on the host
//  against the real core on 2026-10-09, with Wonder Boy III (Master System) and
//  the same file read as a Game Gear game; the core has no Swift surface to
//  test here.
//

import Testing
import Foundation
import UIKit
@testable import EmulateurGBA

struct Sega8BitTests {

    // MARK: - Files

    @Test func eachExtensionNamesItsConsole() {
        #expect(ROMSystemType.from(fileExtension: "sms") == .sms)
        #expect(ROMSystemType.from(fileExtension: "SMS") == .sms)
        #expect(ROMSystemType.from(fileExtension: "gg") == .gg)
        // The same core reads these two, and the app does not carry them.
        #expect(ROMSystemType.from(fileExtension: "sg") == nil)
        #expect(ROMSystemType.from(fileExtension: "col") == nil)
        #expect(ROMSystemType.allFileExtensions.contains("sms"))
        #expect(ROMSystemType.allFileExtensions.contains("gg"))
    }

    /// No header is required: Japanese Master System cartridges, many Game Gear
    /// games and homebrew carry no "TMR SEGA", and the core runs them all. The
    /// extension decides and the bytes only have to be the core's minimum.
    @Test func aCartridgeWithoutTheSegaHeaderStillParses() {
        let bytes = Data((0..<0x8000).map { UInt8(($0 &* 13) & 0xFF) })
        let sms = GBAROMParser.parse(data: bytes, fileSize: Int64(bytes.count), systemHint: .sms)
        #expect(sms?.systemType == .sms)
        let gg = GBAROMParser.parse(data: bytes, fileSize: Int64(bytes.count), systemHint: .gg)
        #expect(gg?.systemType == .gg)
        // No title in the header: the importer names the game from its file.
        #expect(sms?.title == "Unknown Game")
    }

    /// The import gate, which every import path passes through (the picker,
    /// Files and AirDrop, a zip entry, replacing a game's file). It sniffs the
    /// other consoles by their bytes, and these two have none to sniff, so it
    /// refused every `.sms` and `.gg` until the extension was let decide (found
    /// on device, 2026-10-09: both games failed to import).
    @Test func theImportGateTakesBothExtensions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sega8BitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cartridge = Data((0..<0x8000).map { UInt8(($0 &* 13) & 0xFF) })
        for ext in ["sms", "gg"] {
            let url = dir.appendingPathComponent("Game.\(ext)")
            try cartridge.write(to: url)
            #expect(GBAROMParser.isValidROMFile(url: url), ".\(ext) is refused by the import gate")
            let tiny = dir.appendingPathComponent("Tiny.\(ext)")
            try Data(count: 0x80).write(to: tiny)
            #expect(!GBAROMParser.isValidROMFile(url: tiny), "a 128-byte .\(ext) passes the gate")
        }
    }

    @Test func aFileShorterThanTheCoresMinimumIsRefused() {
        let tiny = Data(repeating: 0, count: 0x80)
        #expect(!GBAROMParser.isValidSMSFile(data: tiny))
        #expect(GBAROMParser.isValidSMSFile(data: Data(repeating: 0, count: 0x100)))
    }

    // MARK: - The pad

    @Test func theElementSetIsThePadsOwn() {
        for system in [PresetSystem.sms, .gg] {
            let set = Set(ControlElement.elements(for: system))
            #expect(set == [.dpad, .btnA, .btnB, .btnStart, .btnMenu, .btnClip],
                    "\(system): \(set.map(\.rawValue).sorted())")
        }
    }

    /// The page each is laid out on, and SELECT, which neither has, out of the
    /// default layout on every phone and tablet, both ways up: the control view
    /// hides what a layout does not carry, so a SELECT here would be drawn.
    @Test func eachIsLaidOutOnItsPageWithoutSelect() {
        #expect(PresetSystem.sms.layoutPage == .nes)
        #expect(PresetSystem.gg.layoutPage == .gbc)
        let sizes = [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852),
                     CGSize(width: 744, height: 1133)]
        for system in [PresetSystem.sms, .gg] {
            for portrait in sizes {
                for isLandscape in [false, true] {
                    let size = isLandscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
                    let layout = ControlLayoutDefaults.defaultLayout(
                        system: system, isLandscape: isLandscape, containerSize: size,
                        scale: EmulatorLayoutGeometry.deviceScale(for: size),
                        family: LayoutFamily.of(size))
                    #expect(layout.buttons[ControlElement.btnSelect.rawValue] == nil,
                            "\(system) \(size): SELECT is in the layout")
                    #expect(layout.buttons[ControlElement.btnStart.rawValue] != nil,
                            "\(system) \(size): START is not in the layout")
                }
            }
        }
    }

    /// Each picture is its own shape, and matches the bridge's buffers
    /// (`SMSBufferWidth`/`GGBufferWidth` in MesenBridge.h): the Master System
    /// 256x192, the Game Gear 160x144.
    @Test func eachPictureIsItsOwnShape() {
        #expect(abs(PresetLayoutResolver.displayAspect(.sms) - 4.0 / 3.0) < 0.0001)
        #expect(abs(PresetLayoutResolver.displayAspect(.gg) - 160.0 / 144.0) < 0.0001)
    }

    /// 1 and 2 where a NES pad has B and A, and the extra button named for the
    /// console: PAUSE on the Master System, START on the Game Gear.
    @Test func eachControlPrintsThePadsMark() {
        for system in [PresetSystem.sms, .gg] {
            #expect(ControlElement.btnB.displayName(for: system) == "1")
            #expect(ControlElement.btnA.displayName(for: system) == "2")
            #expect(RemappableInput.b.displayName(for: system) == "1")
            #expect(RemappableInput.a.displayName(for: system) == "2")
            #expect(RemappableInput.available(on: system) == [.b, .a, .start])
        }
        #expect(ControlElement.btnStart.displayName(for: .sms) == "Pause")
        #expect(ControlElement.btnStart.displayName(for: .gg) == "Start")
        #expect(RemappableInput.start.displayName(for: .sms) == "PAUSE")
        #expect(RemappableInput.start.displayName(for: .gg) == "START")
    }

    /// The Master System has two controller ports; the Game Gear is a handheld.
    @Test func playersMatchThePorts() {
        #expect(PresetSystem.sms.playerCount == 2)
        #expect(PresetSystem.gg.playerCount == 1)
    }

    // MARK: - Dress

    /// Both are dressed, each in a dress of its own, and take custom skins
    /// since 2026-10-11 (a palette each, `SMSSkinPalette` / `GGSkinPalette`).
    @Test func bothAreDressedAndTakeCustomSkins() {
        for system in [PresetSystem.sms, .gg] {
            #expect(ConsoleSkinView.hasSkin(for: system))
            #expect(system.supportsCustomSkins)
        }
        // Each wears a dress of its own since 2026-10-10, not another console's:
        // their controls answer their own kind, and their Retro Pal look is a
        // light one (his call that day), whose controls take the look's colour.
        #expect(TouchControlsView.dressKind(for: .sms) == .sms)
        #expect(TouchControlsView.dressKind(for: .gg) == .gg)
        #expect(RetroPalPalette.buttonFill(.sms) == DressKind.smsLook(.retroPal).control)
        #expect(RetroPalPalette.buttonFill(.gg) == DressKind.ggLook(.retroPal).control)
        #expect(DressKind.smsLook(.retroPal).body.rpIsLight)
        #expect(DressKind.ggLook(.retroPal).body.rpIsLight)
        #expect(!DressKind.smsLook(.nostalgia).body.rpIsLight)
    }

    /// The Master System's 1 and 2 sit level, side by side and the same size,
    /// and their grey plates (`smsPlateScale`, a gap apart) never meet, on
    /// every phone and both ways up (its dress, 2026-10-10). On its side
    /// CLIP · MENU · PAUSE share one line under the picture, CLIP left of MENU.
    @Test func masterSystemButtonsSitLevelOnPlatesThatDoNotMeet() {
        let phones = [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852),
                      CGSize(width: 440, height: 956)]
        for phone in phones {
            for landscape in [false, true] {
                let size = landscape ? CGSize(width: phone.height, height: phone.width) : phone
                let k = EmulatorLayoutGeometry.deviceScale(for: size)
                let layout = ControlLayoutDefaults.defaultLayout(
                    system: .sms, isLandscape: landscape, containerSize: size, scale: k)
                guard let a = layout.buttons[ControlElement.btnA.rawValue],
                      let b = layout.buttons[ControlElement.btnB.rawValue] else {
                    Issue.record("1 or 2 missing"); continue
                }
                let one = EmulatorLayoutGeometry.buttonSize(.btnB, system: .sms,
                                                            isLandscape: landscape, deviceScale: k)
                let two = EmulatorLayoutGeometry.buttonSize(.btnA, system: .sms,
                                                            isLandscape: landscape, deviceScale: k)
                #expect(one == two, "\(size)")
                #expect(abs(a.centerY - b.centerY) < 0.0001, "\(size)")
                #expect(b.centerX < a.centerX, "1 on the left, \(size)")
                let plate = one.width * ControlLayoutDefaults.smsPlateScale
                #expect((a.centerX - b.centerX) * size.width >= plate, "plates meet, \(size)")
                if landscape, let clip = layout.buttons[ControlElement.btnClip.rawValue],
                   let menu = layout.buttons[ControlElement.btnMenu.rawValue],
                   let pause = layout.buttons[ControlElement.btnStart.rawValue] {
                    #expect(abs(clip.centerY - menu.centerY) < 0.0001, "\(size)")
                    #expect(abs(pause.centerY - menu.centerY) < 0.0001, "\(size)")
                    #expect(clip.centerX < menu.centerX && menu.centerX < pause.centerX, "\(size)")
                }
            }
        }
    }

    // MARK: - A physical pad

    private func mask(_ system: PresetSystem, _ apply: (inout ControllerInputSource) -> Void) -> UInt32 {
        var s = ControllerInputSource()
        apply(&s)
        return ControllerManager.buttonMask(from: s, mapping: nil, system: system)
    }

    /// With no mapping, a pad works as it does on the NES these two share a page
    /// with: the bottom face is 2 (the a bit), the right face 1 (the b bit), and
    /// Menu the console's PAUSE or START.
    @Test func aPadPressesOneTwoAndPauseAsOnTheNES() {
        for system in [PresetSystem.sms, .gg] {
            #expect(mask(system) { $0.faceA = true } == GBAInput.a.rawValue)
            #expect(mask(system) { $0.faceB = true } == GBAInput.b.rawValue)
            #expect(mask(system) { $0.menu = true } == GBAInput.start.rawValue)
        }
    }

    // MARK: - Saves

    /// The cartridge's RAM as MesenCE writes it (8, 16 or 32 KB) and other
    /// emulators do (32 KB, or 8 KB for nearly every game).
    @Test func savesOfEachSizeAreOfferedToBoth() {
        for size in [8192, 16384, 32768] {
            let consoles = BatterySaveImporter.consoles(acceptingSaveOf: Data(count: size))
            #expect(consoles.contains("sms") && consoles.contains("gg"), "\(size) bytes")
        }
    }

    // MARK: - Cheats

    /// Pro Action Replay is printed with a colon (00C0:0F05), which the field
    /// accepts and puts in when the eight digits are typed in one run.
    @Test func aProActionReplayCodeTakesItsColon() {
        for system in ["sms", "gg"] {
            #expect(CheatCodeFormatter.problem(in: "00C0:0F05", isNDS: false, system: system) == nil)
            #expect(CheatCodeFormatter.formatted("00C00F05", previous: "", isNDS: false,
                                                system: system) == "00C0:0F05")
            // The Game Genie's dashes are hex-legal and pass to the core.
            #expect(CheatCodeFormatter.problem(in: "00A-19F-E66", isNDS: false, system: system) == nil)
        }
    }

    // MARK: - Custom skins (2026-10-11)

    /// The palettes ARE the built-in looks: the values the dresses drew before
    /// the palettes existed, so neither approved look moved a hex.
    @Test func thePalettesAreTheBuiltInLooksUnchanged() {
        let sms = DressKind.smsLook(.nostalgia), smsRP = DressKind.smsLook(.retroPal)
        #expect(sms.body == UIColor(rpHex: 0x232325) && sms.surround == UIColor(rpHex: 0x111112))
        #expect(sms.plate == UIColor(rpHex: 0x6E6F73) && sms.control == UIColor(rpHex: 0x2B2B2D))
        #expect(sms.accent == UIColor(rpHex: 0xC4281E) && sms.onAccent == UIColor(rpHex: 0xF2F2F2))
        #expect(sms.shellInk == UIColor(rpHex: 0xF2F2F2))
        #expect(smsRP.body == UIColor(rpHex: 0xE4E4E6) && smsRP.surround == UIColor(rpHex: 0x1C1C1E))
        #expect(smsRP.plate == UIColor(rpHex: 0xB9BABF) && smsRP.control == UIColor(rpHex: 0x3A3A3E))
        #expect(smsRP.shellInk == UIColor(rpHex: 0x2B2B2D) && smsRP.accent == UIColor(rpHex: 0xC4281E))
        let gg = DressKind.ggLook(.nostalgia), ggRP = DressKind.ggLook(.retroPal)
        #expect(gg.body == UIColor(rpHex: 0x4D5763) && gg.surround == UIColor(rpHex: 0x10171A))
        #expect(gg.control == UIColor(rpHex: 0x2A343C) && gg.accent == UIColor(rpHex: 0x6993D7))
        #expect(gg.onAccent == UIColor(rpHex: 0xEDF2F4) && gg.shellInk == UIColor(rpHex: 0xEDF2F4))
        #expect(ggRP.body == UIColor(rpHex: 0xD9DCE0) && ggRP.surround == UIColor(rpHex: 0x2A3036))
        #expect(ggRP.control == UIColor(rpHex: 0x8A929B) && ggRP.shellInk == UIColor(rpHex: 0x2A3036))
        // The same tokens the rest of the app reads for Classic.
        #expect(sms.body == DressKind.smsBody && gg.body == DressKind.ggBody)
        #expect(gg.accent == DressKind.ggStart && gg.control == DressKind.ggButton)
        // The editor opens on Classic.
        #expect(SkinPalette.nostalgiaSeed(for: .sms) == .sms(.nostalgia))
        #expect(SkinPalette.nostalgiaSeed(for: .gg) == .gg(.nostalgia))
    }

    /// A custom skin reaches every piece: the look (shell, panel, plates, the
    /// accent, the print), and the controls through the variant's resolvers.
    @Test func aCustomSkinReachesEveryPiece() {
        var s = SMSSkinPalette.nostalgia
        s.bodyHex = 0x112233; s.surroundHex = 0x223344; s.plateHex = 0x334455
        s.accentHex = 0x445566; s.keysHex = 0x556677; s.onAccentHex = 0x667788; s.inkHex = 0x778899
        let sv = DressVariant.custom(.sms(s))
        let sl = DressKind.smsLook(sv)
        #expect(sl.body == s.body && sl.surround == s.surround && sl.plate == s.plate)
        #expect(sl.accent == s.accent && sl.control == s.keys && sl.onAccent == s.onAccent)
        #expect(sl.shellInk == s.ink)
        #expect(sv.abFace(.sms) == s.keys && sv.dpadFace(.sms) == s.keys && sv.smallButtonFace(.sms) == s.keys)
        #expect(sv.bodyColor(for: .sms) == s.body)

        var g = GGSkinPalette.nostalgia
        g.bodyHex = 0x101010; g.surroundHex = 0x202020; g.buttonsHex = 0x303030
        g.startHex = 0x404040; g.glyphsHex = 0x505050; g.inkHex = 0x606060
        let gv = DressVariant.custom(.gg(g))
        let gl = DressKind.ggLook(gv)
        #expect(gl.body == g.body && gl.surround == g.surround && gl.control == g.buttons)
        #expect(gl.accent == g.start && gl.onAccent == g.glyphs && gl.shellInk == g.ink)
        #expect(gv.abFace(.gg) == g.buttons && gv.dpadFace(.gg) == g.buttons)
        #expect(gv.bodyColor(for: .gg) == g.body)
        // The share card's cache tells two skins apart by every slot.
        var g2 = g; g2.glyphsHex = 0x515151
        #expect(gv.cacheKey != DressVariant.custom(.gg(g2)).cacheKey)
        var s2 = s; s2.plateHex = 0x334456
        #expect(sv.cacheKey != DressVariant.custom(.sms(s2)).cacheKey)
    }

    /// A skin survives the round trip a shared file makes, keeps its console,
    /// and a file claiming another console's palette is refused.
    @Test func aSkinRoundTripsAndKeepsItsConsole() throws {
        var s = SMSSkinPalette.retroPal; s.accentHex = 0x00AA00
        let decoded = try JSONDecoder().decode(SkinPalette.self, from: JSONEncoder().encode(SkinPalette.sms(s)))
        #expect(decoded == .sms(s))
        #expect(decoded.system == .sms)
        var g = GGSkinPalette.retroPal; g.startHex = 0xFF00FF
        let gd = try JSONDecoder().decode(SkinPalette.self, from: JSONEncoder().encode(SkinPalette.gg(g)))
        #expect(gd == .gg(g) && gd.system == .gg)
        #expect(SkinPalette.sms(.nostalgia).isWithinHexRange && SkinPalette.gg(.nostalgia).isWithinHexRange)
        var bad = GGSkinPalette.nostalgia; bad.inkHex = 0x1000000
        #expect(!SkinPalette.gg(bad).isWithinHexRange)
    }
}
