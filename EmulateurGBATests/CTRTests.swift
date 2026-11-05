//
//  CTRTests.swift
//  EmulateurGBATests
//
//  The Nintendo 3DS, phase 1 (2026-10-19), on Azahar's libretro core. What is
//  here is what only this console has: the app reads a game's own header to
//  tell a decrypted game from an encrypted one (`CTRGameProbe`), because Retro
//  Pal ships no console keys and the core reads decrypted games only; an
//  encrypted game is refused at import, by name; the pad is laid out on the
//  PlayStation's page against the 3DS's own tall picture (both screens,
//  400x480): the cross, the circle pad, A B X Y, L R, ZL ZR; its touch screen
//  is a rectangle inside that picture.
//
//  The overlap, off-page and picture sweeps over every phone and tablet run in
//  EmulatorLayoutGeometryTests and TabletLayoutTests over `PresetSystem.allCases`.
//  The bridge (picture, sound, pad, touch, states) was run on the host against
//  the real core with Majora's Mask 3D on 2026-10-19 (Tools/3ds-bench); the
//  core has no Swift surface to test here.
//

import Testing
import Foundation
import CoreData
import UIKit
@testable import EmulateurGBA

struct CTRTests {

    // MARK: - Games, built byte for byte

    /// An NCCH header (0x200 bytes): "NCCH" at 0x100, and flags[7] at 0x18F
    /// with the no_crypto bit (2) set or not. Only what the probe reads.
    private func makeNCCH(decrypted: Bool, size: Int = 0x200, titleID: UInt64 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        for (i, b) in Array("NCCH".utf8).enumerated() { bytes[0x100 + i] = b }
        bytes[0x188 + 7] = decrypted ? 0x04 : 0x00
        for i in 0..<8 { bytes[0x118 + i] = UInt8((titleID >> (8 * UInt64(i))) & 0xFF) }
        return bytes
    }

    /// An NCSD image (a `.3ds` / `.cci`): "NCSD" at 0x100, and the partition
    /// table's first entry pointing at the game's NCCH `units` x 0x200 bytes in.
    private func makeNCSD(decrypted: Bool, units: UInt32 = 0x4000, titleID: UInt64 = 0) -> Data {
        let base = Int(units) * 0x200
        var bytes = [UInt8](repeating: 0, count: base + 0x200)
        for (i, b) in Array("NCSD".utf8).enumerated() { bytes[0x100 + i] = b }
        for i in 0..<4 { bytes[0x120 + i] = UInt8((units >> (8 * UInt32(i))) & 0xFF) }
        let ncch = makeNCCH(decrypted: decrypted, titleID: titleID)
        bytes.replaceSubrange(base..<(base + ncch.count), with: ncch)
        return Data(bytes)
    }

    private func temp(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func entries(_ context: NSManagedObjectContext) throws -> [NSManagedObject] {
        try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "GameEntity"))
    }

    private func removeImported(_ context: NSManagedObjectContext, _ importer: ROMImporter) {
        for entry in (try? entries(context)) ?? [] {
            guard let path = entry.value(forKey: "romFilePath") as? String else { continue }
            try? FileManager.default.removeItem(at: importer.romURL(for: path))
        }
    }

    // MARK: - Which console a file is

    @Test func theFourExtensionsAreThe3DSsAndNoOthers() {
        for ext in ["3ds", "cci", "cxi", "3dsx", "3DS"] {
            #expect(ROMSystemType.from(fileExtension: ext) == .n3ds, "\(ext)")
            #expect(ROMSystemType.allFileExtensions.contains(ext.lowercased()), "\(ext)")
        }
        // An installable package is not offered (`ctrFileExtensions`).
        #expect(ROMSystemType.from(fileExtension: "cia") == nil)
        #expect(!ROMSystemType.n3ds.isDiscBased)
        #expect(ROMSystemType.n3ds.hashesBounded)
    }

    // MARK: - The probe

    @Test func theProbeReadsTheGamesOwnNoCryptoFlag() throws {
        #expect(CTRGameProbeRead(try temp("A.3ds", makeNCSD(decrypted: true)).path) == CTRGameProbeDecrypted)
        #expect(CTRGameProbeRead(try temp("B.3ds", makeNCSD(decrypted: false)).path) == CTRGameProbeEncrypted)
        // The partition offset is read, not assumed: the same game further in.
        #expect(CTRGameProbeRead(try temp("C.cci", makeNCSD(decrypted: true, units: 0x10)).path)
                == CTRGameProbeDecrypted)
        // A bare NCCH (.cxi) at offset 0.
        #expect(CTRGameProbeRead(try temp("D.cxi", Data(makeNCCH(decrypted: true))).path) == CTRGameProbeDecrypted)
        #expect(CTRGameProbeRead(try temp("E.cxi", Data(makeNCCH(decrypted: false))).path) == CTRGameProbeEncrypted)
    }

    @Test func homebrewIsNeverEncryptedAndNoiseIsNoGame() throws {
        var homebrew = [UInt8](repeating: 0, count: 64)
        for (i, b) in Array("3DSX".utf8).enumerated() { homebrew[i] = b }
        #expect(CTRGameProbeRead(try temp("Hello.3dsx", Data(homebrew)).path) == CTRGameProbeDecrypted)
        #expect(CTRGameProbeRead(try temp("Noise.3ds", Data(repeating: 0x5A, count: 4096)).path) == CTRGameProbeNotCTR)
        // A table pointing past the end of the file: no game, never a crash.
        var short = [UInt8](makeNCSD(decrypted: true).prefix(0x200))
        short[0x120] = 0xFF
        #expect(CTRGameProbeRead(try temp("Short.3ds", Data(short)).path) == CTRGameProbeNotCTR)
        #expect(CTRGameProbeRead("/nonexistent/Game.3ds") == CTRGameProbeNotCTR)
    }

    // MARK: - Import

    @Test func anEncryptedGameIsRefusedByNameAndLeavesNothing() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImported(context, importer) }
        let url = try temp("Encrypted \(UUID().uuidString.prefix(6)).3ds", makeNCSD(decrypted: false))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            _ = try importer.importROM(from: url, method: "picker")
            Issue.record("an encrypted 3DS game was imported")
        } catch ROMImportError.ctrEncrypted {
        } catch {
            Issue.record("refused with \(error), not ctrEncrypted")
        }
        #expect(try entries(context).isEmpty)
        // Its own text, in every language (a missing key would show the KEY).
        #expect(ROMImportError.ctrEncrypted.errorDescription != "import.error.ctrEncrypted")
    }

    @Test func aDecryptedGameImportsAsA3DSCartridge() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImported(context, importer) }
        let name = "Test 3DS Game \(UUID().uuidString.prefix(6))"
        let url = try temp("\(name).3ds", makeNCSD(decrypted: true))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try importer.importROM(from: url, method: "picker")
        let game = try #require(try entries(context).first)
        #expect(game.value(forKey: "systemType") as? String == "n3ds")
        // A cartridge: one file, under its own name, never renamed.
        #expect(game.value(forKey: "romFilePath") as? String == "\(name).3ds")
    }

    @Test func aFileThatIsNo3DSGameIsRefusedAsAnyOther() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        defer { removeImported(context, importer) }
        let url = try temp("Noise \(UUID().uuidString.prefix(6)).3ds", Data(repeating: 0x5A, count: 8192))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            _ = try importer.importROM(from: url, method: "picker")
            Issue.record("noise named .3ds was imported")
        } catch ROMImportError.invalidROM {
        } catch {
            Issue.record("refused with \(error), not invalidROM")
        }
        #expect(try entries(context).isEmpty)
    }

    // MARK: - The pad and the picture

    @Test func itIsLaidOutOnThePlayStationsPageWithItsOwnPad() {
        #expect(PresetSystem.n3ds.layoutPage == .ps1)
        #expect(Set(ControlElement.elements(for: .n3ds))
                == [.dpad, .stickLeft, .stickRight, .btnA, .btnB, .btnX, .btnY, .btnL, .btnR, .btnL2, .btnR2,
                    .btnSelect, .btnStart, .btnMenu, .btnClip, .btnMic])
        #expect(abs(PresetLayoutResolver.displayAspect(.n3ds) - 400.0 / 480.0) < 0.0001)
        #expect(abs(PresetLayoutResolver.displayAspect(.n3ds)
                    - CGFloat(CTRPictureWidth) / CGFloat(CTRPictureHeight)) < 0.0001)
        #expect(PresetSystem.n3ds.playerCount == 1)
        #expect(ControllerManager.stickIsAnalogOnly(on: .n3ds))
    }

    /// On its side (asked 2026-10-20, the DS's model) the two screens fill a
    /// band across the top and every control sits under it, in the window's
    /// safe area and above the home indicator, on phones and iPads.
    /// Since his design of 2026-10-21 the shoulders stand BESIDE the screens, ZL
    /// and L left of the top one, ZR and R right of the bottom one: they are
    /// checked against the two screens, the rest are still under them. Sizes
    /// are the ones drawn (`ControlLayoutDefaults.n3dsLandscapeDrawnSize`), which
    /// the polished default geometry carries itself since 2026-10-27.
    @Test func onItsSideEveryControlSitsUnderTheScreens() {
        let windows: [(CGSize, UIEdgeInsets)] = [
            (CGSize(width: 667, height: 375), .zero),
            (CGSize(width: 852, height: 393), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
            (CGSize(width: 1133, height: 744), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
            (CGSize(width: 1376, height: 1032), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
        ]
        for (size, insets) in windows {
            let geometry = PresetLayoutResolver.defaultGeometry(
                system: .n3ds, isLandscape: true, viewSize: size, safeInsets: insets)
            // Its two screens are the layout's own components since 2026-10-27, placed in the
            // band (the picture frame) the controls start under.
            guard let top = geometry.screens[.top], let bottom = geometry.screens[.bottom] else {
                Issue.record("\(size): no screens"); continue
            }
            let band = CGRect(x: 0, y: 0, width: size.width, height: geometry.controlsFrame.minY)
            #expect(band.contains(top) && band.contains(bottom), "\(size): a screen leaves the band")
            let screens = [top, bottom]
            for element in ControlElement.elements(for: .n3ds) {
                guard let b = geometry.buttons[element] else {
                    Issue.record("\(size): \(element.rawValue) missing"); continue
                }
                let drawn = b.baseSize
                let r = CGRect(x: b.center.x - drawn.width / 2, y: b.center.y - drawn.height / 2,
                               width: drawn.width, height: drawn.height)
                if [.btnL, .btnL2, .btnR, .btnR2].contains(element) {
                    for screen in screens {
                        #expect(!r.insetBy(dx: 0.5, dy: 0.5).intersects(screen),
                                "\(size): \(element.rawValue) \(r) is on a screen \(screen)")
                    }
                } else {
                    #expect(r.minY >= band.maxY - 0.5, "\(size): \(element.rawValue) is on the screens")
                }
                #expect(r.minX >= insets.left - 0.5 && r.maxX <= size.width - insets.right + 0.5
                        && r.maxY <= size.height - insets.bottom + 0.5,
                        "\(size): \(element.rawValue) \(r) leaves the safe area")
            }
        }
    }

    /// The two screens side by side: one scale, touching, centred, the top
    /// screen left, the bottom (touch) screen right; the touch overlay is the
    /// right one.
    @MainActor @Test func onItsSideTheScreensStandSideBySide() {
        let band = CGRect(x: 0, y: 0, width: 852, height: 235.8)
        let pair = EmulatorMetalView.ctrSideBySideRects(in: band.size)
        #expect(abs(pair.top.height - pair.bottom.height) < 0.001)
        #expect(abs(pair.top.width / pair.top.height - 400.0 / 240.0) < 0.001)
        #expect(abs(pair.bottom.width / pair.bottom.height - 320.0 / 240.0) < 0.001)
        #expect(abs(pair.top.maxX - pair.bottom.minX) < 0.001)
        #expect(abs(pair.top.minX - (band.width - pair.bottom.maxX)) < 0.001)
        #expect(CTRTouchOverlay.frame(sideBySideIn: band) == pair.bottom)
    }

    /// The touch screen is the bottom screen's rectangle, scaled with the picture.
    @MainActor @Test func theTouchScreenIsTheBottomScreenInsideThePicture() {
        #expect(CTRBottomScreenRect == CGRect(x: 40, y: 240, width: 320, height: 240))
        let picture = CGRect(x: 100, y: 20, width: 200, height: 240)   // 400x480 at half size
        let frame = CTRTouchOverlay.frame(inPicture: picture)
        #expect(frame == CGRect(x: 120, y: 140, width: 160, height: 120))
    }

    /// The share card (his ask, 2026-10-21): the DS's separated card but for its own pieces. Each
    /// screen at the 3DS's ratio, at the DS card's screen height; ZL and ZR inward of L and R on the
    /// components row; the circle pad over the cross, A B X Y level with the circle pad and the
    /// C-stick under them; SELECT and START centred in the space under the lower screen; nothing on
    /// a screen or off the card; the lower screen the middle four fifths of the picture's lower half.
    @Test func theCardIsTheDSCardWithItsOwnPieces() {
        let S: CGFloat = 1080
        let layout = GBCardLayout.n3ds(side: S)
        let ds = GBCardLayout.nds(side: S, gameNativeSize: CGSize(width: 256.0 / 384.0, height: 1),
                                  separatedScreens: true)
        #expect(layout.ndsScreens.count == 2)
        let upper = layout.ndsScreens[0], lower = layout.ndsScreens[1]
        #expect(abs(upper.width / upper.height - 400.0 / 240.0) < 0.001)
        #expect(abs(lower.width / lower.height - 320.0 / 240.0) < 0.001)
        #expect(abs(upper.height - ds.ndsScreens[0].height) < 0.001, "the DS card's screen height")
        // The DS card's rule for the screens: each centred between the card's edge and its rail,
        // the rails around the components row as the DS's (bar height over 2 plus a quarter of
        // the row's spacer). The 3DS's row holds ZL and ZR too, so its spacer, and the rails with
        // it, are its own: the screens sit about 4 points nearer the middle than the DS's.
        let topRail = layout.ctrRowCenterY! - (layout.ctrBottomRailY! - layout.ctrRowCenterY!)
        #expect(abs(upper.midY - topRail / 2) < 0.001 && abs(lower.midY - (layout.ctrBottomRailY! + S) / 2) < 0.001,
                "each screen centred between the card's edge and its rail")
        #expect(abs(upper.midY - ds.ndsScreens[0].midY) < 6 && abs(lower.midY - ds.ndsScreens[1].midY) < 6,
                "near the DS card's screen centres")
        func c(_ e: ControlElement) -> CGPoint {
            let b = layout.buttons[e.rawValue]!
            return CGPoint(x: b.centerX * S, y: b.centerY * S)
        }
        #expect(c(.btnL2).x > c(.btnL).x && c(.btnR2).x < c(.btnR).x, "ZL and ZR inward of L and R")
        #expect(abs(c(.btnL2).y - c(.btnL).y) < 0.001 && abs(c(.btnR2).y - c(.btnR).y) < 0.001)
        #expect(c(.stickLeft).y < c(.dpad).y && abs(c(.stickLeft).x - c(.dpad).x) < 0.001, "the circle pad over the cross")
        let diamondY = (c(.btnX).y + c(.btnB).y) / 2
        #expect(abs(diamondY - c(.stickLeft).y) < 0.001, "A B X Y level with the circle pad")
        #expect(c(.stickRight).y > c(.btnB).y, "the C-stick under the faces")
        let k = layout.deviceScale
        #expect(abs(c(.btnSelect).y - (lower.maxY + S) / 2) < 0.001, "SELECT in the middle under the lower screen")
        #expect(abs(c(.btnStart).y - c(.btnSelect).y) < 0.001)
        #expect(abs((c(.btnSelect).x + c(.btnStart).x) / 2 - S / 2) < 0.001, "SELECT and START centred")
        #expect((layout.ctrPadSide ?? 0) < EmulatorLayoutGeometry.buttonSize(.dpad, system: .n3ds, isLandscape: false,
                                                                             deviceScale: k).width, "a smaller cross")
        let dsBar = CGSize(width: ControlElement.btnL.defaultNDSPortraitSize.width * k,
                           height: ControlElement.btnL.defaultNDSPortraitSize.height * k)
        for (key, b) in layout.buttons where b.centerY < 2 && !b.isHidden {
            guard let element = ControlElement(rawValue: key) else { continue }
            var size = EmulatorLayoutGeometry.buttonSize(element, system: .n3ds, isLandscape: false, deviceScale: k)
            if [ControlElement.btnL, .btnL2, .btnR, .btnR2].contains(element) { size = dsBar }
            if element == .dpad, let side = layout.ctrPadSide { size = CGSize(width: side, height: side) }
            let r = CGRect(x: b.centerX * S - size.width / 2, y: b.centerY * S - size.height / 2,
                           width: size.width, height: size.height)
            #expect(r.minX >= -0.5 && r.maxX <= S + 0.5 && r.minY >= -0.5 && r.maxY <= S + 0.5, "\(element) off the card")
            // Clear of the rounded corners (radius 48).
            let inCorner = (r.minX < 48 || r.maxX > S - 48) && (r.minY < 48 || r.maxY > S - 48)
            #expect(!inCorner, "\(element) in a corner of the card")
            for screen in [upper, lower] {
                #expect(!r.insetBy(dx: 0.5, dy: 0.5).intersects(screen), "\(element) on a screen")
            }
        }
        let crops = ScreenshotCardRenderer.n3dsScreenCrops(frameWidth: 400, frameHeight: 480)
        #expect(crops.top == CGRect(x: 0, y: 0, width: 400, height: 240))
        #expect(crops.bottom == CGRect(x: 40, y: 240, width: 320, height: 240))
    }

    /// The Classic card (his report, 2026-10-30): the two screens each at its
    /// own ratio inside the standard game rect, so the title under them sits
    /// where every console's Classic card has it, and their neon frames apart.
    /// The lower screen was about 1.39:1 and its frame overlapped the upper's.
    @Test func itsClassicCardKeepsEachScreensRatioInsideTheStandardRect() {
        let S: CGFloat = 1080, pad: CGFloat = 8
        let box = ScreenshotCardRenderer.standardGameScreenRect(side: S, gameNativeSize: CGSize(width: 400, height: 480))
        let ctr = ScreenshotCardRenderer.classicN3DSScreens(side: S, frameAspect: 400.0 / 480.0, bezelPadding: pad)
        #expect(abs(ctr.top.width / ctr.top.height - 400.0 / 240.0) < 0.001)
        #expect(abs(ctr.bottom.width / ctr.bottom.height - 320.0 / 240.0) < 0.001)
        #expect(abs(ctr.top.height - ctr.bottom.height) < 0.001)
        #expect(abs(ctr.top.midX - S / 2) < 0.001 && abs(ctr.bottom.midX - S / 2) < 0.001)
        #expect(ctr.top.minY >= box.minY - 0.001 && ctr.bottom.maxY <= box.maxY + 0.001)
        #expect(ctr.top.minX >= box.minX - 0.001 && ctr.top.maxX <= box.maxX + 0.001)
        let frames = (ctr.top.insetBy(dx: -pad, dy: -pad), ctr.bottom.insetBy(dx: -pad, dy: -pad))
        #expect(frames.1.minY - frames.0.maxY > 0, "the two frames overlap")
    }

    // MARK: - Its dress (2026-10-20, the DS's)

    /// The DS's dress in the 3DS's colours, as the PSP wears the PlayStation's:
    /// the controls take the DS's tokens, the variant carries its own palette,
    /// which the DS's code reads through `asNDS`. Custom skins come with it.
    /// No console card yet, no drawing yet.
    @MainActor @Test func itWearsTheDSsDressInItsOwnColours() throws {
        #expect(ConsoleSkinView.hasSkin(for: .n3ds))
        #expect(ConsoleSkinView.hasDressedControls(for: .n3ds))
        #expect(TouchControlsView.dressKind(for: .n3ds) == .nds)
        #expect(PresetSystem.n3ds.supportsCustomSkins)
        #expect(ConsoleSkinView.ctrVariant(.nostalgia) == .custom(.n3ds(.nostalgia)))
        #expect(ConsoleSkinView.ctrVariant(.retroPal) == .custom(.n3ds(.retroPal)))
        let mine = DressVariant.custom(.n3ds(.retroPal))
        #expect(ConsoleSkinView.ctrVariant(mine) == mine)
        #expect(mine.isCTR && mine.ndsPalette == N3DSSkinPalette.retroPal.asNDS)
        #expect(!DressVariant.custom(.nds(.nostalgia)).isCTR)
        #expect(SkinPalette.nostalgiaSeed(for: .n3ds) == .n3ds(.nostalgia))
        let decoded = try JSONDecoder().decode(SkinPalette.self,
                                               from: JSONEncoder().encode(SkinPalette.n3ds(.nostalgia)))
        #expect(decoded == .n3ds(.nostalgia) && decoded.system == .n3ds)
        #expect(ScreenshotCardRenderer.hasConsoleCard(.n3ds))
        #expect(PixelConsole(.n3ds) == .n3ds)
        #expect(PixelConsole.n3ds.label == "Nintendo 3DS")
        // Its own drawing (2026-10-20): the badges and pickers show it, not the pill.
        #expect(SystemColor.hasDrawing("n3ds"))
        #expect(SystemColor.name("n3ds") == "Nintendo 3DS")
        #expect(SystemColor.tag("n3ds") == "3DS")
    }

    /// The dress's two screens are the ones the game draws: upright the top
    /// one across the picture's upper half, the bottom one four fifths as wide
    /// under it; on its side the two quads side by side.
    @MainActor @Test func theDressRimsTheTwoScreensTheGameDraws() {
        let picture = CGRect(x: 0, y: 63, width: 393, height: 471.6)
        let upright = ConsoleSkinView.ctrScreens(in: picture, sideBySide: false)
        #expect(upright.count == 2)
        #expect(upright[0] == CGRect(x: 0, y: 63, width: 393, height: 235.8))
        #expect(abs(upright[1].width - 393 * 0.8) < 0.001 && abs(upright[1].midX - picture.midX) < 0.001)
        #expect(abs(upright[1].minY - upright[0].maxY) < 0.001 && abs(upright[1].maxY - picture.maxY) < 0.001)
        // The touch overlay covers the dress's bottom screen exactly.
        let overlay = CTRTouchOverlay.frame(inPicture: picture)
        #expect(abs(overlay.minX - upright[1].minX) < 0.001 && abs(overlay.width - upright[1].width) < 0.001)
        let band = CGRect(x: 0, y: 0, width: 852, height: 235.8)
        let side = ConsoleSkinView.ctrScreens(in: band, sideBySide: true)
        #expect(side[1] == CTRTouchOverlay.frame(sideBySideIn: band))
    }

    /// The cross is the 3DS's D-pad and only that, the stick its circle pad;
    /// ZL and ZR are a pad's triggers, by default and on reset alike.
    @Test func theCrossTheCirclePadAndTheZTriggers() {
        let available = RemappableInput.available(on: .n3ds)
        #expect(available.contains(.l2) && available.contains(.r2))
        #expect(RemappableInput.l2.displayName(for: .n3ds) == "ZL")
        #expect(RemappableInput.r2.displayName(for: .n3ds) == "ZR")
        #expect(ControlElement.btnL2.displayName(for: .n3ds) == "ZL")
        var s = ControllerInputSource()
        s.leftTrigger = true
        s.rightTrigger = true
        let mask = ControllerManager.buttonMask(from: s, system: .n3ds)
        #expect(mask & GBAInput.l2.rawValue != 0 && mask & GBAInput.r2.rawValue != 0)
        let reset = ControllerMapping.defaults(for: .n3ds).assignments
        #expect(reset[.l2] == .leftTrigger && reset[.r2] == .rightTrigger)
    }

    /// The PlayStation's control view, with the 3DS's own marks.
    @MainActor @Test func itsControlViewIsThePlayStationsWithItsOwnMarks() {
        let view = TouchControlsView.make(for: .n3ds)
        #expect(view is PS1TouchControlsView)
        #expect(view.lockableLetters == ["A", "B", "X", "Y"])
    }

    @Test func noBatterySaveFileAndNoAchievements() {
        #expect(BatterySaveImporter.saveSizes["n3ds"] == nil)
        #expect(RAClient.consoleId(forROMPath: "/nonexistent/Game.3ds") == 0)
    }

    // MARK: - Its save, a folder (CTRSaveData, 2026-10-20)

    @Test func theTitleIDIsReadFromTheGamesOwnHeader() throws {
        let id: UInt64 = 0x0004000000125600
        #expect(CTRSaveData.titleID(ofROMAt: try temp("MM.3ds", makeNCSD(decrypted: true, titleID: id))) == id)
        #expect(CTRSaveData.titleID(ofROMAt: try temp("MM.cxi", Data(makeNCCH(decrypted: true, titleID: id)))) == id)
        // Encrypted or not, the header is in the clear: the ID is still read.
        #expect(CTRSaveData.titleID(ofROMAt: try temp("E.3ds", makeNCSD(decrypted: false, titleID: id))) == id)
        var homebrew = [UInt8](repeating: 0, count: 64)
        for (i, b) in Array("3DSX".utf8).enumerated() { homebrew[i] = b }
        #expect(CTRSaveData.titleID(ofROMAt: try temp("H.3dsx", Data(homebrew))) == nil)
        #expect(CTRSaveData.titleID(ofROMAt: URL(fileURLWithPath: "/nonexistent/G.3ds")) == nil)
    }

    /// Azahar's own formula for extdata (GetExtSaveDataPath, which Open and
    /// FormatAsExtData use): UPPERCASE hex, unlike the save folder below.
    @Test func theExtdataFolderIsWhereTheCoreFilesIt() {
        let zeros = String(repeating: "0", count: 32)
        #expect(CTRSaveData.extdataFolder(extdataID: 0x00000B8D).path
            .hasSuffix("/3DS/Azahar/sdmc/Nintendo 3DS/\(zeros)/\(zeros)/extdata/00000000/00000B8D"))
        #expect(CTRSaveData.extdataFolder(extdataID: 0x1648).path.hasSuffix("/extdata/00000000/00001648"))
    }

    /// Azahar's own formula (archive_source_sd_savedata.cpp): the SD card's
    /// `Nintendo 3DS/<32 zeros>/<32 zeros>/title/<high>/<low>/data`, lowercase.
    @Test func theSaveFolderIsWhereTheCoreFilesIt() {
        let path = CTRSaveData.saveFolder(titleID: 0x0004000000125600).path
        let zeros = String(repeating: "0", count: 32)
        #expect(path.hasSuffix("/3DS/Azahar/sdmc/Nintendo 3DS/\(zeros)/\(zeros)/title/00040000/00125600/data"))
        #expect(CTRSaveData.saveFolder(titleID: 0x000400000ABCDE00).path.hasSuffix("/title/00040000/0abcde00/data"))
    }

    @Test func aSaveTravelsAsAZipAndComesBackWhole() throws {
        let id: UInt64 = 0x00040000_7E570000 | UInt64.random(in: 0...0xFFFF)
        let folder = CTRSaveData.saveFolder(titleID: id)
        defer {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
            let backups = BatterySaveImporter.backupsDir
            for name in (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
            where name.hasPrefix("CTRTest-") {
                try? FileManager.default.removeItem(at: backups.appendingPathComponent(name))
            }
        }
        #expect(!CTRSaveData.hasSave(titleID: id))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("00000001/sub"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 7, count: 0x40).write(to: folder.appendingPathComponent("00000001.metadata"))
        let save = Data((0..<70_000).map { UInt8($0 & 0xFF) })
        try save.write(to: folder.appendingPathComponent("00000001/sub/main"))
        #expect(CTRSaveData.hasSave(titleID: id))

        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("CTRTest-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        try CTRSaveData.exportSave(titleID: id, to: zip)

        // The game writes over its save; importing the export puts it back,
        // and the save it replaced is kept in the backups first.
        try Data(repeating: 1, count: 10).write(to: folder.appendingPathComponent("00000001/sub/main"))
        guard case .success(let pending) = CTRSaveData.prepare(zipURL: zip) else {
            Issue.record("the app's own export was refused")
            return
        }
        try CTRSaveData.apply(pending, titleID: id, romBasename: "CTRTest-game")
        #expect(try Data(contentsOf: folder.appendingPathComponent("00000001/sub/main")) == save)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: BatterySaveImporter.backupsDir.path)) ?? []
        #expect(backups.contains { $0.hasPrefix("CTRTest-game-") && $0.hasSuffix(".zip") })
        // No stray folder left beside the save.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path)
        #expect(siblings == ["data"])
    }

    /// A device that never read the game's file (another iPhone pulling the
    /// save from iCloud) still puts the extdata where the game looks for it:
    /// the zip names its ID (`CTRSaveData.extdataIDEntry`), and the device
    /// remembers it (audit, 2026-10-20: it was dropped, then pushed back
    /// without it).
    @Test func theExtdataTravelsWithItsIDToADeviceThatNeverReadTheGame() throws {
        let id: UInt64 = 0x00040000_7E580000 | UInt64.random(in: 0...0xFFFF)
        let extdataID: UInt64 = 0x00000B8D
        let folder = CTRSaveData.saveFolder(titleID: id)
        let extdata = CTRSaveData.extdataFolder(extdataID: extdataID)
        let key = "ctrExtdataIDs"
        let knownBefore = UserDefaults.standard.dictionary(forKey: key)
        defer {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: extdata)
            UserDefaults.standard.set(knownBefore, forKey: key)
            let backups = BatterySaveImporter.backupsDir
            for name in (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
            where name.hasPrefix("CTRTest-extdata-") {
                try? FileManager.default.removeItem(at: backups.appendingPathComponent(name))
            }
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("00000001"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 7, count: 0x40).write(to: folder.appendingPathComponent("00000001.metadata"))
        try FileManager.default.createDirectory(at: extdata.appendingPathComponent("user"),
                                                withIntermediateDirectories: true)
        let content = Data((0..<5_000).map { UInt8($0 & 0xFF) })
        try content.write(to: extdata.appendingPathComponent("user/progress"))
        CTRSaveData.rememberExtdataID(extdataID, forTitleID: id)

        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("CTRTest-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        try CTRSaveData.exportSave(titleID: id, to: zip)

        // The other device: no ID for this game, no extdata on disk.
        var known = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        known[String(id, radix: 16)] = nil
        UserDefaults.standard.set(known, forKey: key)
        try FileManager.default.removeItem(at: extdata)
        #expect(CTRSaveData.extdataID(forTitleID: id) == nil)

        guard case .success(let pending) = CTRSaveData.prepare(zipURL: zip) else {
            Issue.record("the app's own export was refused")
            return
        }
        #expect(pending.extdataID == extdataID)
        try CTRSaveData.apply(pending, titleID: id, romBasename: "CTRTest-extdata")
        #expect(try Data(contentsOf: extdata.appendingPathComponent("user/progress")) == content)
        #expect(CTRSaveData.extdataID(forTitleID: id) == extdataID)
        // The ID is the zip's, not a file of the save.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CTRSaveData.extdataIDEntry).path))
    }

    /// A save zipped one folder down (a `data` folder zipped whole) leaves
    /// nothing in tmp, whether it is applied or called off: only the inner
    /// folder was removed, its scratch parent stayed (audit, 2026-10-29).
    @Test func aSaveOneFolderDownLeavesNoScratchBehind() throws {
        let id: UInt64 = 0x00040000_7E570000 | UInt64.random(in: 0...0xFFFF)
        let folder = CTRSaveData.saveFolder(titleID: id)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctr-nested-\(UUID().uuidString)", isDirectory: true)
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("CTRTest-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: zip)
        }
        let inner = source.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: inner.appendingPathComponent("00000001"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 7, count: 0x40).write(to: inner.appendingPathComponent("00000001.metadata"))
        try Data(repeating: 3, count: 100).write(to: inner.appendingPathComponent("00000001/main"))
        try ZIPWriter.zipFolder(source, to: zip)

        guard case .success(let calledOff) = CTRSaveData.prepare(zipURL: zip) else {
            Issue.record("a save one folder down was refused")
            return
        }
        #expect(calledOff.contents.lastPathComponent == "data")
        #expect(calledOff.scratch != calledOff.contents)
        calledOff.discard()
        #expect(!FileManager.default.fileExists(atPath: calledOff.scratch.path),
                "a called-off import left its scratch folder in tmp")

        guard case .success(let pending) = CTRSaveData.prepare(zipURL: zip) else {
            Issue.record("a save one folder down was refused")
            return
        }
        try CTRSaveData.apply(pending, titleID: id, romBasename: "CTRTest-nested")
        #expect(try Data(contentsOf: folder.appendingPathComponent("00000001/main")) == Data(repeating: 3, count: 100))
        #expect(!FileManager.default.fileExists(atPath: pending.scratch.path),
                "an applied import left its scratch folder in tmp")
    }

    /// A game that wrote its extdata and no save yet: the backup zip has
    /// nothing to carry, so the extdata the import replaces is kept beside the
    /// backups instead of deleted with no copy (audit, 2026-10-30).
    @Test func extdataWithNoSaveIsKeptWhenReplaced() throws {
        let id: UInt64 = 0x00040000_7E590000 | UInt64.random(in: 0...0xFFFF)
        let extdataID: UInt64 = 0x00000B8E
        let folder = CTRSaveData.saveFolder(titleID: id)
        let extdata = CTRSaveData.extdataFolder(extdataID: extdataID)
        let key = "ctrExtdataIDs"
        let knownBefore = UserDefaults.standard.dictionary(forKey: key)
        let backups = BatterySaveImporter.backupsDir
        func ours() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])
                .filter { $0.hasPrefix("CTRTest-noSave-") }
        }
        defer {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: extdata)
            UserDefaults.standard.set(knownBefore, forKey: key)
            for name in ours() { try? FileManager.default.removeItem(at: backups.appendingPathComponent(name)) }
        }
        // The incoming save, with its extdata, made on "another device".
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("00000001"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 7, count: 0x40).write(to: folder.appendingPathComponent("00000001.metadata"))
        try FileManager.default.createDirectory(at: extdata.appendingPathComponent("user"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 2, count: 64).write(to: extdata.appendingPathComponent("user/progress"))
        CTRSaveData.rememberExtdataID(extdataID, forTitleID: id)
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("CTRTest-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        try CTRSaveData.exportSave(titleID: id, to: zip)

        // This device: extdata of its own, no save.
        try FileManager.default.removeItem(at: folder)
        let mine = Data(repeating: 9, count: 64)
        try mine.write(to: extdata.appendingPathComponent("user/progress"))
        #expect(!CTRSaveData.hasSave(titleID: id))

        guard case .success(let pending) = CTRSaveData.prepare(zipURL: zip) else {
            Issue.record("the app's own export was refused")
            return
        }
        try CTRSaveData.apply(pending, titleID: id, romBasename: "CTRTest-noSave")
        #expect(try Data(contentsOf: extdata.appendingPathComponent("user/progress")) == Data(repeating: 2, count: 64))
        let kept = try #require(ours().first { $0.hasPrefix("CTRTest-noSave-extdata-") },
                                "the replaced extdata was deleted with no copy")
        #expect(try Data(contentsOf: backups.appendingPathComponent(kept).appendingPathComponent("user/progress")) == mine)
    }

    /// A save folder zipped by the Mac's Finder, `__MACOSX` beside it, is
    /// read as the save it is, and the resource forks stay out of it.
    @Test func aFinderZipOfTheDataFolderIsASave() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctr-finder-\(UUID().uuidString)", isDirectory: true)
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("CTRTest-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: zip)
        }
        let inner = source.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: inner.appendingPathComponent("00000001"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 7, count: 0x40).write(to: inner.appendingPathComponent("00000001.metadata"))
        let forks = source.appendingPathComponent("__MACOSX/data", isDirectory: true)
        try FileManager.default.createDirectory(at: forks, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 82).write(to: forks.appendingPathComponent("._00000001.metadata"))
        try ZIPWriter.zipFolder(source, to: zip)

        guard case .success(let pending) = CTRSaveData.prepare(zipURL: zip) else {
            Issue.record("a Finder zip of the data folder was refused")
            return
        }
        defer { pending.discard() }
        #expect(pending.contents.lastPathComponent == "data")
    }

    /// Each iCloud pull of a 3DS save zipped the save it replaced into the
    /// backups, and nothing ever removed one (audit, 2026-10-29): a pull keeps
    /// the newest five (`keepBackups`), a player's own import keeps them all.
    /// Before the fix this pull would have left seven.
    @Test func iCloudPullBackupsAreCappedAtFive() throws {
        let id: UInt64 = 0x00040000_7E560000 | UInt64.random(in: 0...0xFFFF)
        let folder = CTRSaveData.saveFolder(titleID: id)
        let prefix = "3DS-CTRTest-cap-\(String(id, radix: 16))"
        let backups = BatterySaveImporter.backupsDir
        func ours() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])
                .filter { $0.hasPrefix(prefix + "-") && $0.hasSuffix(".zip") }
        }
        defer {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
            for name in ours() { try? FileManager.default.removeItem(at: backups.appendingPathComponent(name)) }
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("00000001"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 7, count: 0x40).write(to: folder.appendingPathComponent("00000001.metadata"))
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("CTRTest-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        try CTRSaveData.exportSave(titleID: id, to: zip)

        // Six earlier pulls' backups, named as `backUp` names them (by the
        // second, `yyyyMMdd-HHmmss`), in 2020: older than any real one. Made
        // here rather than by six pulls a second apart, which held a test
        // thread asleep for seconds.
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let earlier = (0..<6).map { "\(prefix)-20200101-00000\($0).zip" }
        for name in earlier { try Data([1]).write(to: backups.appendingPathComponent(name)) }
        try Data(repeating: 9, count: 64).write(to: folder.appendingPathComponent("00000001/main"))
        guard case .success(let pending) = CTRSaveData.prepare(zipURL: zip) else {
            Issue.record("the app's own export was refused")
            return
        }
        try CTRSaveData.apply(pending, titleID: id, romBasename: prefix,
                              keepBackups: BatterySaveImporter.stateLoadBackupsKept)
        let kept = Set(ours())
        #expect(kept.count == BatterySaveImporter.stateLoadBackupsKept,
                "\(kept.count) backups kept, not \(BatterySaveImporter.stateLoadBackupsKept)")
        // The newest kept: this pull's, and the four latest of the earlier.
        #expect(kept.isSuperset(of: earlier.suffix(BatterySaveImporter.stateLoadBackupsKept - 1)),
                "the newest earlier backups were not the ones kept")
        #expect(!kept.contains(earlier[0]) && !kept.contains(earlier[1]), "the oldest backups were kept")
    }

    @Test func aZipThatIsNoSaveIsRefusedAndOneThatEscapesIsRefused() throws {
        let junkDir = FileManager.default.temporaryDirectory.appendingPathComponent("ctr-junk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: junkDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: junkDir) }
        try Data("x".utf8).write(to: junkDir.appendingPathComponent("readme.txt"))
        let junk = junkDir.appendingPathComponent("../ctr-junk-\(UUID().uuidString).zip").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: junk) }
        try ZIPWriter.zipFolder(junkDir, to: junk)
        guard case .failure(.notASave) = CTRSaveData.prepare(zipURL: junk) else {
            Issue.record("a zip with no save metadata was accepted")
            return
        }
        // A name climbing out of the folder refuses the whole archive.
        let escapingURL = junkDir.appendingPathComponent("escape.zip")
        try Self.storedZip(name: "../x", contents: Data("x".utf8)).write(to: escapingURL)
        guard case .failure(.unreadable) = CTRSaveData.prepare(zipURL: escapingURL) else {
            Issue.record("a zip writing outside its folder was accepted")
            return
        }
    }

    /// One stored entry, by hand, for the escape test.
    private static func storedZip(name: String, contents: Data) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: UInt32) -> [UInt8] { u16(Int(v & 0xFFFF)) + u16(Int(v >> 16)) }
        let n = Array(name.utf8), crc = ZIPExtractor.crc32(contents), size = UInt32(contents.count)
        var out: [UInt8] = u32(0x04034b50) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0x21)
            + u32(crc) + u32(size) + u32(size) + u16(n.count) + u16(0) + n + Array(contents)
        let cd: [UInt8] = u32(0x02014b50) + u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0x21)
            + u32(crc) + u32(size) + u32(size) + u16(n.count) + u16(0) + u16(0) + u16(0) + u16(0)
            + u32(0) + u32(0) + n
        let cdOffset = UInt32(out.count)
        out += cd
        out += u32(0x06054b50) + u16(0) + u16(0) + u16(1) + u16(1) + u32(UInt32(cd.count)) + u32(cdOffset) + u16(0)
        return Data(out)
    }

    /// The rule both Game Details layouts read: a 3DS game with a title ID
    /// gets the import and export rows, a `.3dsx` and a PSP game do not.
    @Test func theRowsAreOfferedForA3DSGameWithATitleIDOnly() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let roms = try temp("MM.3ds", makeNCSD(decrypted: true, titleID: 0x0004000000125600))
            .deletingLastPathComponent()
        var homebrew = [UInt8](repeating: 0, count: 64)
        for (i, b) in Array("3DSX".utf8).enumerated() { homebrew[i] = b }
        try Data(homebrew).write(to: roms.appendingPathComponent("H.3dsx"))
        func game(_ file: String, _ system: String) -> GameEntity {
            let g = NSEntityDescription.insertNewObject(forEntityName: "GameEntity", into: context) as! GameEntity
            g.romFilePath = file
            g.systemType = system
            return g
        }
        #expect(GameDetailsView.offersSaveImportExport(game("MM.3ds", "n3ds"), romsDir: roms))
        #expect(!GameDetailsView.offersSaveImportExport(game("H.3dsx", "n3ds"), romsDir: roms))
        #expect(!GameDetailsView.offersSaveImportExport(game("X.iso", "psp"), romsDir: roms))
        #expect(GameDetailsView.offersSaveImportExport(game("X.gba", "gba"), romsDir: roms))
    }

    // MARK: - Cheats

    /// Gateway, the 3DS's format, is judged as the DS's is: eight and eight per
    /// line. A twelve-digit run is a half-typed line, not a code of another
    /// shape, so it is not split as the GBA's CodeBreaker would be.
    @Test func gatewayCodesAreCheckedPairByPair() {
        #expect(CheatCodeFormatter.problem(in: "0012A3F4 0000270F", isNDS: false, system: "n3ds") == nil)
        #expect(CheatCodeFormatter.problem(in: "D9000000 0FFFC000\nD4000000 00000001", isNDS: false,
                                           system: "n3ds") == nil)
        #expect(CheatCodeFormatter.problem(in: "0012A3F4 270F", isNDS: false, system: "n3ds") == .unpairedLine)
        #expect(CheatCodeFormatter.problem(in: "0012A3F4 0000XXXX", isNDS: false, system: "n3ds")
                == .placeholderValue)
        #expect(CheatCodeFormatter.formatted("0012A3F40000270F", previous: "", isNDS: false, system: "n3ds")
                == "0012A3F4 0000270F")
        #expect(CheatCodeFormatter.formatted("0012A3F4270F", previous: "", isNDS: false, system: "n3ds")
                == "0012A3F4270F")
    }
}
