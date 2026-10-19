//
//  PSPTests.swift
//  EmulateurGBATests
//
//  The PSP, added 2026-10-09 on PPSSPP's libretro port. What is here is what
//  only this console has: two of its three extensions are the PlayStation's
//  too, so the file decides the console (`PSPDiscProbe`, the core's own tests);
//  its pad is the PlayStation's without six controls, on the PlayStation's
//  page; its saves are a folder, not a battery file; its cheats are CWCheat
//  lines (2026-10-10).
//
//  The overlap, off-page and picture sweeps over every phone and tablet run in
//  EmulatorLayoutGeometryTests and TabletLayoutTests, which carry the PSP in
//  their console lists. The bridge (picture, sound, pad, states) was run on the
//  host against the real core with Monster Hunter Freedom Unite on 2026-10-09;
//  the core has no Swift surface to test here.
//

import Testing
import Foundation
import CoreData
import UIKit
@testable import EmulateurGBA

struct PSPTests {

    // MARK: - Images, built byte for byte

    /// An ISO 9660 image of `sectors` 2048-byte sectors whose primary volume
    /// descriptor (sector 16) names `systemID`, and whose root directory (at
    /// sector 18) holds one directory named `rootEntry` when given. Only what
    /// the probe reads is filled in; the rest of each sector is zero.
    private func makeISO(systemID: String, rootEntry: String? = nil, sectors: Int = 24) -> Data {
        var bytes = [UInt8](repeating: 0, count: sectors * 2048)
        let pvd = 16 * 2048
        bytes[pvd] = 1
        for (i, b) in Array("CD001".utf8).enumerated() { bytes[pvd + 1 + i] = b }
        var system = Array(systemID.utf8).prefix(32).map { $0 }
        system += [UInt8](repeating: 0x20, count: 32 - system.count)
        for (i, b) in system.enumerated() { bytes[pvd + 8 + i] = b }
        // The root directory record, 34 bytes at offset 156: its extent and length.
        let root = pvd + 156
        bytes[root] = 34
        let extent: UInt32 = 18, length: UInt32 = 2048
        for i in 0..<4 { bytes[root + 2 + i] = UInt8((extent >> (8 * UInt32(i))) & 0xFF) }
        for i in 0..<4 { bytes[root + 10 + i] = UInt8((length >> (8 * UInt32(i))) & 0xFF) }
        if let name = rootEntry {
            let dir = 18 * 2048
            let nameBytes = Array(name.utf8)
            let record = 33 + nameBytes.count + (nameBytes.count % 2 == 0 ? 1 : 0)
            bytes[dir] = UInt8(record)
            bytes[dir + 32] = UInt8(nameBytes.count)
            for (i, b) in nameBytes.enumerated() { bytes[dir + 33 + i] = b }
        }
        return Data(bytes)
    }

    /// A PBP (an EBOOT): its header, a PARAM.SFO whose CATEGORY is `category`,
    /// and a data section that begins with `psar`.
    private func makePBP(category: String, psar: String) -> Data {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        let key = Array("CATEGORY\0".utf8), value = Array((category + "\0").utf8)
        let keyTable: UInt32 = 20 + 16, dataTable: UInt32 = keyTable + UInt32(key.count) + 3
        var sfo: [UInt8] = Array("\0PSF".utf8) + le32(0x101) + le32(keyTable) + le32(dataTable) + le32(1)
        sfo += le16(0) + le16(0x204) + le32(UInt32(value.count)) + le32(4) + le32(0)
        sfo += key + [0, 0, 0] + value
        let sfoStart: UInt32 = 40, sfoEnd = sfoStart + UInt32(sfo.count)
        var offsets = [sfoStart] + [UInt32](repeating: sfoEnd, count: 7)
        offsets[7] = sfoEnd
        var bytes: [UInt8] = Array("\0PBP".utf8) + le32(0x10000)
        for o in offsets { bytes += le32(o) }
        return Data(bytes + sfo + Array(psar.utf8))
    }

    private func temp(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("psp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Which console a file is

    @Test func onlyCSOIsThePSPsByExtensionAlone() {
        #expect(ROMSystemType.from(fileExtension: "cso") == .psp)
        // Shared with the PlayStation: the extension says PlayStation, and only
        // the file can say otherwise (`resolve(url:)`).
        #expect(ROMSystemType.from(fileExtension: "iso") == .ps1)
        #expect(ROMSystemType.from(fileExtension: "pbp") == .ps1)
        #expect(ROMSystemType.allFileExtensions.contains("cso"))
        #expect(ROMSystemType.psp.isDiscBased)
    }

    @Test func anISOWhoseVolumeSaysPSPGameIsThePSPs() throws {
        let url = try temp("Game.iso", makeISO(systemID: "PSP GAME"))
        #expect(ROMSystemType.resolve(url: url) == .psp)
        let upper = try temp("GAME.ISO", makeISO(systemID: "PSP GAME"))
        #expect(ROMSystemType.resolve(url: upper) == .psp)
    }

    /// PPSSPP's fallback, which the probe follows: a volume with another system
    /// name that carries a PSP_GAME folder is a PSP game.
    @Test func anISOWithAPSPGameFolderIsThePSPs() throws {
        let url = try temp("Odd.iso", makeISO(systemID: "SOMETHING ELSE", rootEntry: "PSP_GAME"))
        #expect(ROMSystemType.resolve(url: url) == .psp)
    }

    @Test func aPlayStationISOStaysThePlayStations() throws {
        let ps1 = try temp("Disc.iso", makeISO(systemID: "PLAYSTATION"))
        #expect(ROMSystemType.resolve(url: ps1) == .ps1)
        // Neither "PSP GAME" nor a PSP_GAME folder: not a PSP game, so the
        // extension's answer stands.
        let other = try temp("Other.iso", makeISO(systemID: "SOMETHING ELSE", rootEntry: "DATA"))
        #expect(ROMSystemType.resolve(url: other) == .ps1)
        // A raw 2352-byte CD image has no volume at 0x8000.
        let raw = try temp("Raw.iso", Data([0x00] + [UInt8](repeating: 0xFF, count: 10) + [0x00]
                                             + [UInt8](repeating: 0, count: 40_000)))
        #expect(ROMSystemType.resolve(url: raw) == .ps1)
    }

    @Test func aPBPIsThePSPsUnlessItHoldsAPlayStationGame() throws {
        // A PlayStation game repacked for the PSP's store, either way PPSSPP
        // recognises one: its category, or its data section.
        #expect(ROMSystemType.resolve(url: try temp("A.pbp", makePBP(category: "ME", psar: "PSISOIMG0000"))) == .ps1)
        #expect(ROMSystemType.resolve(url: try temp("B.pbp", makePBP(category: "EG", psar: "PSISOIMG0000"))) == .ps1)
        #expect(ROMSystemType.resolve(url: try temp("C.pbp", makePBP(category: "EG", psar: "PSTITLEIMG00"))) == .ps1)
        // A PSP game sold on the store, and a PSP program.
        #expect(ROMSystemType.resolve(url: try temp("D.pbp", makePBP(category: "EG", psar: "NPUMDIMG"))) == .psp)
        #expect(ROMSystemType.resolve(url: try temp("E.pbp", makePBP(category: "MG", psar: "\0\0\0\0"))) == .psp)
        // Not a PBP at all: the extension's answer stands.
        #expect(ROMSystemType.resolve(url: try temp("F.pbp", Data("hello".utf8))) == .ps1)
    }

    /// A missing file is not a PSP game: the extension's answer stands, and the
    /// import then reports the file it cannot read.
    @Test func aFileThatCannotBeReadIsNotAPSPGame() {
        #expect(ROMSystemType.resolve(url: URL(fileURLWithPath: "/nonexistent/Game.iso")) == .ps1)
        #expect(ROMSystemType.resolve(url: URL(fileURLWithPath: "/nonexistent/Game.cso")) == .psp)
    }

    // MARK: - Import

    /// A PSP image goes through the disc path (a folder of its own, a bounded
    /// identity hash) and is filed under the PSP; a PlayStation image of the same
    /// extension, beside it in the same library, stays a PlayStation game.
    @Test func importsFileEachImageUnderItsOwnConsole() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        let psp = try temp("Test PSP Game \(UUID().uuidString.prefix(6)).iso", makeISO(systemID: "PSP GAME"))
        let ps1 = try temp("Test PS1 Disc \(UUID().uuidString.prefix(6)).iso", makeISO(systemID: "PLAYSTATION"))

        let pspID = try importer.importROM(from: psp, method: "picker")
        let ps1ID = try importer.importROM(from: ps1, method: "picker")
        let pspGame = try context.existingObject(with: pspID)
        let ps1Game = try context.existingObject(with: ps1ID)
        defer {
            for game in [pspGame, ps1Game] {
                if let path = game.value(forKey: "romFilePath") as? String,
                   let folder = DiscStorage.gameFolder(forROMAt: importer.romURL(for: path)) {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
        #expect(pspGame.value(forKey: "systemType") as? String == "psp")
        #expect(ps1Game.value(forKey: "systemType") as? String == "ps1")
        // Its own folder, as every disc game has.
        let path = try #require(pspGame.value(forKey: "romFilePath") as? String)
        #expect(path.contains("/") && path.hasSuffix(".iso"))
    }

    // MARK: - The pad

    @Test func theElementSetIsThePlayStationsWithoutSix() {
        let set = Set(ControlElement.elements(for: .psp))
        #expect(set == [.dpad, .btnA, .btnB, .btnX, .btnY, .btnL, .btnR,
                        .btnSelect, .btnStart, .btnMenu, .btnClip, .stickLeft],
                "\(set.map(\.rawValue).sorted())")
    }

    /// Laid out on the PlayStation's page against its own picture, without the
    /// six it lacks, on every phone and tablet, both ways up; and nothing it does
    /// not have, since the control view draws whatever a layout carries.
    @Test func itIsLaidOutOnThePlayStationsPageWithoutTheSix() {
        #expect(PresetSystem.psp.layoutPage == .ps1)
        let absent: [ControlElement] = [.btnL2, .btnR2, .stickRight, .btnL3, .btnR3, .btnMode]
        let sizes = [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852),
                     CGSize(width: 440, height: 956), CGSize(width: 744, height: 1133)]
        for portrait in sizes {
            for isLandscape in [false, true] {
                let size = isLandscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
                let layout = ControlLayoutDefaults.defaultLayout(
                    system: .psp, isLandscape: isLandscape, containerSize: size,
                    scale: EmulatorLayoutGeometry.deviceScale(for: size),
                    family: LayoutFamily.of(size))
                for element in absent {
                    #expect(layout.buttons[element.rawValue] == nil, "\(size): \(element.rawValue) is in the layout")
                }
                for element in ControlElement.elements(for: .psp) {
                    #expect(layout.buttons[element.rawValue] != nil, "\(size): \(element.rawValue) is missing")
                }
            }
        }
    }

    /// A phone on its side (2026-10-11): CLIP · SELECT · START · MENU are one
    /// row under the picture, in that order, centred on it, SELECT and START
    /// the pair around its middle. The iPad has its own page.
    @Test func onAPhoneOnItsSideTheFourShareOneRowUnderThePicture() {
        let phones = [CGSize(width: 667, height: 375), CGSize(width: 812, height: 375),
                      CGSize(width: 852, height: 393), CGSize(width: 956, height: 440)]
        for device in phones {
            let k = EmulatorLayoutGeometry.deviceScale(for: device)
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: device, safeInsets: .zero, hasTouchScreen: false,
                isLandscape: true, gameAspect: PresetLayoutResolver.displayAspect(.psp),
                system: .psp, controllerConnected: false, deviceScale: k)
            let container = EmulatorLayoutGeometry.controlsFrame(
                deviceSize: device, screenFrame: screen, hasTouchScreen: false,
                isLandscape: true).size
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .psp, isLandscape: true, containerSize: container, scale: k,
                family: LayoutFamily.of(device))
            func c(_ e: ControlElement) -> CGPoint {
                let b = layout.buttons[e.rawValue]
                return CGPoint(x: (b?.centerX ?? -1) * container.width,
                               y: (b?.centerY ?? -1) * container.height)
            }
            let label = "\(device)"
            let row = [ControlElement.btnClip, .btnSelect, .btnStart, .btnMenu].map(c)
            // Left to right in that order.
            #expect(zip(row, row.dropFirst()).allSatisfy { $0.x < $1.x }, "\(label)")
            // One line.
            #expect(row.allSatisfy { abs($0.y - row[0].y) < 0.5 }, "\(label)")
            // Under the picture, never on it.
            #expect(row[0].y > screen.maxY, "\(label)")
            // SELECT and START around the picture's middle, CLIP and MENU
            // the same distance out on either side.
            #expect(abs((row[1].x + row[2].x) / 2 - screen.midX) < 0.5, "\(label)")
            #expect(abs((row[1].x - row[0].x) - (row[3].x - row[2].x)) < 0.5, "\(label)")
        }
    }

    /// Upright on a phone (2026-10-12), the picture sits a triangle's height
    /// above the pad's block (less only where the top padding stops it), and
    /// the controls do not move: L, R, MENU and CLIP stay the band's height
    /// above the pad as before, because the band grew by exactly the lift.
    @Test func uprightThePictureRisesByTheTriangleAndNothingElseMoves() {
        let phones: [(CGSize, CGFloat)] = [(CGSize(width: 375, height: 667), 20), (CGSize(width: 393, height: 852), 59),
                                           (CGSize(width: 440, height: 956), 62)]
        for (device, top) in phones {
            let k = EmulatorLayoutGeometry.deviceScale(for: device)
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: device, safeInsets: UIEdgeInsets(top: top, left: 0, bottom: 34, right: 0),
                hasTouchScreen: false, isLandscape: false, gameAspect: PresetLayoutResolver.displayAspect(.psp),
                system: .psp, controllerConnected: false, deviceScale: k)
            let band = device.height - screen.maxY
            let block = EmulatorLayoutGeometry.pspPortraitControlsHeight(deviceScale: k)
            let triangle = EmulatorLayoutGeometry.buttonSize(.btnX, system: .psp, isLandscape: false, deviceScale: k).height
            let limit = top + EmulatorLayoutGeometry.gbaPortraitTopPadding * k
            // Raised by the triangle, or up to the top padding where that is less.
            #expect(abs((band - block) - triangle) < 0.5 || abs(screen.minY - limit) < 0.5,
                    "the picture did not rise by the triangle's height")
            #expect(screen.minY >= limit - 0.5, "the picture went above the top padding")
            // The shoulder row sits where it sat before: the top of the pad's block.
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .psp, isLandscape: false, containerSize: CGSize(width: device.width, height: band),
                scale: k, family: LayoutFamily.of(device))
            let lY = screen.maxY + (layout.buttons[ControlElement.btnL.rawValue]?.centerY ?? -1) * band
            let expected = device.height - block + ControlLayoutDefaults.pspPortraitShoulderTop * k
                + EmulatorLayoutGeometry.buttonSize(.btnL, system: .psp, isLandscape: false, deviceScale: k).height / 2
            #expect(abs(lY - expected) < 0.5, "L moved when the picture rose")
        }
    }

    /// On its side (2026-10-12) the picture is centred in the glass's height,
    /// or as low as leaves the row of four its height and a row gap above and
    /// below; never higher than it sat before.
    @Test func onItsSideThePictureIsCentredOrAsLowAsTheRowAllows() {
        let phones = [CGSize(width: 667, height: 375), CGSize(width: 852, height: 393), CGSize(width: 956, height: 440)]
        for device in phones {
            let k = EmulatorLayoutGeometry.deviceScale(for: device)
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: device, safeInsets: .zero, hasTouchScreen: false, isLandscape: true,
                gameAspect: PresetLayoutResolver.displayAspect(.psp), system: .psp,
                controllerConnected: false, deviceScale: k)
            let row = [ControlElement.btnSelect, .btnStart, .btnMenu, .btnClip]
                .map { EmulatorLayoutGeometry.buttonSize($0, system: .psp, isLandscape: true, deviceScale: k).height }.max() ?? 0
            let gap = ControlLayoutDefaults.pspRowGap * k
            let lowest = device.height - EmulatorLayoutGeometry.snesLandscapeIndicatorReserve - row - 2 * gap - screen.height
            let centred = (device.height - screen.height) / 2
            #expect(abs(screen.minY - min(centred, lowest)) < 0.5, "the picture is neither centred nor as low as the row allows")
        }
    }

    /// The PSP's own page (2026-10-10, second pass), on phones and tablets
    /// both ways up: the thumbs' resting line holds the nub and the diamond
    /// (what PSP games press most); the cross is directly above the nub; the
    /// PSP's own SELECT and START are a pair at the bottom; Retro Pal's MENU and
    /// CLIP are apart from them; L and R sit in their shoulders, the left on the
    /// left half, the right on the right; nothing enters a shoulder's recess.
    @Test func eachThumbRestsOnItsBusiestControl() {
        let phones = [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852),
                      CGSize(width: 440, height: 956)]
        let tablets = [CGSize(width: 744, height: 1133), CGSize(width: 1032, height: 1376)]
        for portrait in phones + tablets {
            for isLandscape in [false, true] {
                let device = isLandscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
                let k = EmulatorLayoutGeometry.deviceScale(for: device)
                let screen = EmulatorLayoutGeometry.screenFrame(
                    deviceSize: device, safeInsets: .zero, hasTouchScreen: false,
                    isLandscape: isLandscape, gameAspect: PresetLayoutResolver.displayAspect(.psp),
                    system: .psp, controllerConnected: false, deviceScale: k)
                let container = EmulatorLayoutGeometry.controlsFrame(
                    deviceSize: device, screenFrame: screen, hasTouchScreen: false,
                    isLandscape: isLandscape).size
                let layout = ControlLayoutDefaults.defaultLayout(
                    system: .psp, isLandscape: isLandscape, containerSize: container, scale: k,
                    family: LayoutFamily.of(device))
                func c(_ e: ControlElement) -> CGPoint {
                    let b = layout.buttons[e.rawValue]
                    return CGPoint(x: (b?.centerX ?? -1) * container.width,
                                   y: (b?.centerY ?? -1) * container.height)
                }
                let label = "\(device)"
                let diamond = CGPoint(x: (c(.btnY).x + c(.btnA).x) / 2, y: (c(.btnX).y + c(.btnB).y) / 2)
                // One thumb line: the nub level with the diamond's centre.
                #expect(abs(c(.stickLeft).y - diamond.y) < 0.5, "\(label)")
                // The cross above the nub, in its column.
                #expect(abs(c(.dpad).x - c(.stickLeft).x) < 0.5, "\(label)")
                #expect(c(.dpad).y < c(.stickLeft).y, "\(label)")
                // L on the left half, R on the right, both above the clusters.
                #expect(c(.btnL).x < container.width / 2 && c(.btnR).x > container.width / 2, "\(label)")
                #expect(c(.btnL).y < c(.dpad).y && c(.btnR).y < diamond.y, "\(label)")
                // SELECT and START a pair on one line, below the thumb line.
                #expect(abs(c(.btnSelect).y - c(.btnStart).y) < 0.5 && c(.btnSelect).x < c(.btnStart).x,
                        "\(label)")
                #expect(c(.btnSelect).y > diamond.y || isLandscape, "\(label)")
                // MENU and CLIP never between SELECT and START.
                for e in [ControlElement.btnMenu, .btnClip] {
                    let between = c(e).x > c(.btnSelect).x && c(e).x < c(.btnStart).x
                        && abs(c(e).y - c(.btnSelect).y) < 1
                    #expect(!between, "\(label) \(e.rawValue)")
                }
            }
        }
    }

    /// The cross is a step smaller than the PlayStation's, and on its side the
    /// four faces too, so the picture gets the width (2026-10-10).
    @Test func theCrossAndTheFacesGiveRoomToThePicture() {
        let pad = EmulatorLayoutGeometry.buttonSize(.dpad, system: .psp, isLandscape: false, deviceScale: 1)
        let ps1Pad = EmulatorLayoutGeometry.buttonSize(.dpad, system: .ps1, isLandscape: false, deviceScale: 1)
        #expect(pad.width < ps1Pad.width)
        let face = EmulatorLayoutGeometry.buttonSize(.btnA, system: .psp, isLandscape: true, deviceScale: 1)
        #expect(face.width >= 44, "the comfort floor")
        for size in [CGSize(width: 667, height: 375), CGSize(width: 852, height: 393),
                     CGSize(width: 956, height: 440)] {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            func frame(_ system: PresetSystem) -> CGRect {
                EmulatorLayoutGeometry.screenFrame(
                    deviceSize: size, safeInsets: .zero, hasTouchScreen: false, isLandscape: true,
                    gameAspect: PresetLayoutResolver.displayAspect(.psp), system: system,
                    controllerConnected: false, deviceScale: k)
            }
            #expect(frame(.psp).width > frame(.ps1).width, "\(size): the PSP's picture is wider than the PlayStation page gave it")
        }
    }

    /// The picture is the PSP's own, and matches the bridge's (`kPSPDisplayAspect`).
    @Test func thePictureIsThePSPsOwnShape() {
        #expect(abs(PresetLayoutResolver.displayAspect(.psp) - 480.0 / 272.0) < 0.0001)
    }

    /// The four symbols, in the PlayStation's places, through the same bits:
    /// what the pad draws on a face is what the core is told was pressed
    /// (PSPBridge's `kButtonMap`, the PlayStation's table bit for bit).
    @Test func eachControlPrintsThePlayStationsSymbol() {
        #expect(RemappableInput.a.displayName(for: .psp) == "◯")
        #expect(RemappableInput.b.displayName(for: .psp) == "✕")
        #expect(RemappableInput.x.displayName(for: .psp) == "△")
        #expect(RemappableInput.y.displayName(for: .psp) == "□")
        // One shoulder pair: no number.
        #expect(RemappableInput.l.displayName(for: .psp) == "L")
        #expect(RemappableInput.r.displayName(for: .psp) == "R")
        #expect(RemappableInput.available(on: .psp) == [.a, .b, .x, .y, .l, .r, .select, .start])
        #expect(ControlElement.stickLeft.displayName(for: .psp) == "Analog Stick")
    }

    /// The pause menu's hold-to-lock row names the four faces by this pad's
    /// symbols, on the PlayStation and on the PSP (they showed A, B, X and Y).
    @MainActor
    @Test func holdToLockNamesTheSymbols() {
        #expect(PS1TouchControlsView().lockableLetters == ["◯", "✕", "△", "□"])
        #expect(TouchControlsView.make(for: .psp).lockableLetters == ["◯", "✕", "△", "□"])
    }

    @Test func oneConsoleOnePlayer() {
        #expect(PresetSystem.psp.playerCount == 1)
    }

    private func mask(_ apply: (inout ControllerInputSource) -> Void) -> UInt32 {
        var s = ControllerInputSource()
        apply(&s)
        return ControllerManager.buttonMask(from: s, mapping: nil, system: .psp)
    }

    /// The nub reaches the core as analog, never also as the cross: PSP games
    /// read the two as different controls. Only the D-pad presses the cross.
    @Test func aPadsStickDoesNotPressTheCross() {
        #expect(mask { $0.up = true } == 0)
        #expect(mask { $0.padUp = true } == GBAInput.up.rawValue)
        #expect(mask { $0.faceA = true } == GBAInput.a.rawValue)
        #expect(mask { $0.faceB = true } == GBAInput.b.rawValue)
        // Not the PlayStation's: no L2, R2 or stick clicks on this pad.
        #expect(mask { $0.leftTrigger = true } & GBAInput.l2.rawValue == 0)
    }

    // MARK: - Dress, saves, the pause menu

    /// Dressed in its own looks (2026-10-10): the PlayStation's pad shapes,
    /// whose every shape is keyed on that dress kind, with the PSP's own
    /// colours and pieces in both looks, his palette given verbatim; a palette
    /// of its own since 2026-10-11 (`PSPSkinPalette`), custom skins and a
    /// console card.
    @Test func itWearsItsOwnLooksOnThePlayStationsShapes() {
        #expect(ConsoleSkinView.hasSkin(for: .psp))
        #expect(TouchControlsView.dressKind(for: .psp) == .ps1)
        #expect(ConsoleSkinView.pspVariant(.nostalgia) == .custom(.psp(.nostalgia)))
        #expect(ConsoleSkinView.pspVariant(.retroPal) == .custom(.psp(.retroPal)))
        #expect(ConsoleSkinView.pspVariant(.nostalgia).isPSP)
        #expect(ConsoleSkinView.pspVariant(.retroPal).isPSPGlass)
        #expect(!ConsoleSkinView.pspVariant(.nostalgia).isPSPGlass)
        // The PlayStation's own looks are not the PSP's.
        #expect(!DressVariant.retroPal.isPSP && !DressVariant.custom(.ps1(.nostalgia)).isPSP)
        // His values, unchanged by the move to a palette of its own: the
        // PlayStation view the shared dress code reads is what it read before.
        #expect(PS1SkinPalette.pspNostalgia == PS1SkinPalette(
            bodyHex: 0x2F2F2F, surroundHex: 0x000000, padHex: 0x2F2F2F, faceHex: 0x2F2F2F,
            printHex: 0xA7A7A7, diamondHex: 0x2F2F2F))
        #expect(PS1SkinPalette.pspRetroPal == PS1SkinPalette(
            bodyHex: 0xD4D4D4, surroundHex: 0x000000, padHex: 0xD4D4D4, faceHex: 0xD4D4D4,
            printHex: 0x6D7073, diamondHex: 0xD4D4D4))
        #expect(PSPSkinPalette.nostalgia.shouldersHex == 0xF3F3F3)
        #expect(PSPSkinPalette.nostalgia.stickHex == 0x1E1E1E)
        #expect(PSPSkinPalette.retroPal.stickHex == 0xAFB2B6)
        #expect(ConsoleSkinView.pspVariant(.nostalgia).ps1Palette == PS1SkinPalette.pspNostalgia)
        #expect(PresetSystem.psp.supportsCustomSkins)
        // Its console share card since 2026-10-11 (`GBCardLayout.psp`).
        #expect(ScreenshotCardRenderer.hasConsoleCard(.psp))
    }

    /// A custom PSP skin is a PSP: its own pieces stay (the glass or not, the
    /// grey marks, its L / R and nub colours), it survives a shared file's
    /// round trip with its console, and the editor opens on Nostalgia.
    @Test func aCustomPSPSkinKeepsThePSPsOwnPieces() throws {
        var p = PSPSkinPalette.nostalgia
        p.bodyHex = 0x8A1C1C; p.controlsHex = 0x222222; p.printHex = 0xEEEEEE
        p.shouldersHex = 0x0055AA; p.stickHex = 0x334455
        let v = DressVariant.custom(.psp(p))
        #expect(v.isPSP && !v.isPSPGlass)
        #expect(v.ps1Palette?.body == p.body && v.ps1Palette?.print == p.print)
        #expect(v.pspPalette?.shoulders == p.shoulders && v.pspPalette?.stick == p.stick)
        #expect(v.bodyColor(for: .psp) == p.body)
        // pspVariant leaves a custom PSP skin alone.
        #expect(ConsoleSkinView.pspVariant(v) == v)
        var glass = PSPSkinPalette.retroPal; glass.bodyHex = 0x88CCAA
        #expect(DressVariant.custom(.psp(glass)).isPSPGlass)
        let decoded = try JSONDecoder().decode(SkinPalette.self, from: JSONEncoder().encode(SkinPalette.psp(p)))
        #expect(decoded == .psp(p) && decoded.system == .psp)
        #expect(SkinPalette.nostalgiaSeed(for: .psp) == .psp(.nostalgia))
        var p2 = p; p2.stickHex = 0x334456
        #expect(v.cacheKey != DressVariant.custom(.psp(p2)).cacheKey)
    }

    /// A PSP game saves to a memory stick FOLDER of its own, outside the flat
    /// directory of battery files the iCloud mirror and the save importer read.
    @Test func itsSavesAreAFolderOutsideTheBatterySaves() {
        let stick = BatterySaveImporter.pspMemoryStickFolder(forRomBasename: "Some Game")
        #expect(stick.lastPathComponent == "Some Game")
        #expect(!stick.path.hasPrefix(BatterySaveImporter.batterySavesRoot.path))
        // No battery-file size is the PSP's: a `.sav` is never offered to it.
        #expect(BatterySaveImporter.saveSizes["psp"] == nil)
    }

    /// The UMDs of one game share one stick: disc 2 reads the save disc 1 wrote.
    @Test func theDiscsOfOneGameShareOneMemoryStick() {
        let one = BatterySaveImporter.pspMemoryStickFolder(forRomBasename: "Some Game (Japan) (Disc 1)")
        let two = BatterySaveImporter.pspMemoryStickFolder(forRomBasename: "Some Game (Japan) (Disc 2)")
        #expect(one == two, "the second disc of a PSP game does not see the first disc's saves")
        #expect(one != BatterySaveImporter.pspMemoryStickFolder(forRomBasename: "Other Game (Japan)"))
    }

    /// PPSSPP reads CSO versions 0 and 1 only: a version 2 file is not imported.
    @Test func aCSOOfAVersionThePSPCoreRefusesIsNotImported() {
        var head = Data("CISO".utf8) + Data([0x18, 0, 0, 0]) + Data(count: 8) + Data([0, 8, 0, 0]) + Data([2, 0, 0, 0])
        #expect(!GBAROMParser.isBootableDiscImage(head: head, fileExtension: "cso"), "a CSO v2 header passed the import gate")
        head[20] = 1
        #expect(GBAROMParser.isBootableDiscImage(head: head, fileExtension: "cso"), "a CSO v1 header was refused")
    }

    // MARK: - RetroAchievements

    /// A PSP game answers the PSP's RetroAchievements console (41) whatever its
    /// container, read from the FILE for the two extensions it shares with the
    /// PlayStation, which keeps answering the PlayStation (12) for its own.
    @Test func achievementsKnowThePSP() throws {
        let psp = try temp("Game.iso", makeISO(systemID: "PSP GAME"))
        #expect(RAClient.consoleId(forROMPath: psp.path) == 41)
        #expect(RAClient.consoleId(forROMPath: "/games/Game.cso") == 41)
        let ps1 = try temp("Disc.iso", makeISO(systemID: "PLAYSTATION"))
        #expect(RAClient.consoleId(forROMPath: ps1.path) == 12)
    }

    // MARK: - Cheats (CWCheat)

    /// The PSP's codes, as PSPBridge reads them: `_L 0xAAAAAAAA 0xVVVVVVVV`, the
    /// `_L` and the `0x` optional, a `_C` title line skipped, a code of several
    /// lines either on several lines or joined on one as code lists store it.
    @Test func cwCheatCodesPassTheShapeCheck() {
        let ok = [
            "_L 0x20123456 0x0000270F",
            "20123456 0000270F",
            "_C0 Max Money\n_L 0x20123456 0x0000270F\n_L 0x10000004 0x00000063",
            "_L 0xE0030980 0x000C055C _L 0x200C055C 0x00C31821",
            "_l 0x2000 0x1",
        ]
        for code in ok {
            #expect(CheatCodeFormatter.problem(in: code, isNDS: false, system: "psp") == nil, "\(code)")
        }
        #expect(CheatCodeFormatter.problem(in: "_L 0x20123456", isNDS: false, system: "psp") == .unpairedLine)
        #expect(CheatCodeFormatter.problem(in: "_L 0x123456789 0x1", isNDS: false, system: "psp") == .unpairedLine)
        #expect(CheatCodeFormatter.problem(in: "_L 0x2012345G 0x1", isNDS: false, system: "psp") == .invalidCharacter)
        #expect(CheatCodeFormatter.problem(in: "_M 0x20123456 0x1", isNDS: false, system: "psp") == .invalidCharacter)
        #expect(CheatCodeFormatter.problem(in: "_L 0x201234XX 0x1", isNDS: false, system: "psp") == .placeholderValue)
        #expect(CheatCodeFormatter.pspLines("_L 0x1 0x2 _L 0x3 0x4") == ["_L 0x1 0x2", "_L 0x3 0x4"])
    }

    /// libretro's PSP files join a code's lines with spaces; the browser lays
    /// them out one per line, and drops the null section headers, which as
    /// codes would write 0 to the first byte of the game's memory.
    @Test func browserCodesAreLaidOutAndHeadersDropped() {
        #expect(CheatLibrary.formatCode("_L 0xE0030980 0x000C055C _L 0x200C055C 0x00C31821")
                == "_L 0xE0030980 0x000C055C\n_L 0x200C055C 0x00C31821")
        let file = """
        cheats = "3"
        cheat0_desc = "____[>>>General Cheats<<<]____"
        cheat0_code = "_L 0x00000000 0x00000000"
        cheat1_desc = "Max Money"
        cheat1_code = "_L 0x20123456 0x0000270F"
        cheat2_desc = "Multi"
        cheat2_code = "_L 0x40417 0x02600002 _L 0x0001869F 0x00000000"
        """
        let cheats = CheatLibrary.parse(file)
        #expect(cheats.map(\.description) == ["Max Money", "Multi"])
        // A null line INSIDE a code is part of it (the data word of a multi-write).
        #expect(cheats.last?.code == "_L 0x40417 0x02600002\n_L 0x0001869F 0x00000000")
    }

    /// The cheat screen's hint, example and messages are the PSP's own in
    /// every language, and the browser index carries the PSP's files.
    @Test func cheatStringsAndIndex() {
        for key in ["cheats.hint.psp", "cheats.invalid.psp", "cheats.invalid.characters.psp",
                    "cheats.invalid.pairs.psp"] {
            #expect(NSLocalizedString(key, comment: "") != key, "\(key)")
        }
        #expect(!CheatIndex.shared.candidates(forTitle: "Monster Hunter Freedom Unite (USA) (PSP) (PSN)",
                                              system: "psp").isEmpty)
    }

    @Test func itsBadgeAndDrawingAreNamed() {
        #expect(SystemColor.name("psp") == "PSP")
        // Its own drawing (2026-10-10), never another machine's (the
        // PlayStation's, borrowed at first, read as wrong on device).
        #expect(SystemColor.drawingAsset("psp") == "console-psp")
        #expect(SystemColor.hasDrawing("psp"))
        #expect(SystemColor.hasDrawing("md"))
    }
}
