//
//  N64ControlsTests.swift
//  EmulateurGBATests
//
//  The Nintendo 64's own controls, added in 1.3.3 on the invisible skin: the
//  buttons the pad has and nothing else, the bits the bridge reads them as, a
//  physical pad's built-in layout, and the C diamond's place on the page.
//
//  The overlap, off-page and picture sweeps over every phone and tablet run in
//  EmulatorLayoutGeometryTests and TabletLayoutTests, which carry `.n64` in
//  their console lists. What is here is what only this console has.
//

import Testing
import UIKit
@testable import EmulateurGBA

struct N64ControlsTests {

    // MARK: - The pad

    @Test func theElementSetIsThePadsOwn() {
        let set = Set(ControlElement.elements(for: .n64))
        for element in [ControlElement.dpad, .btnA, .btnB, .btnL, .btnR, .btnL2, .btnStart,
                        .btnMenu, .btnClip, .stickLeft,
                        .btnCUp, .btnCDown, .btnCLeft, .btnCRight] {
            #expect(set.contains(element), "\(element.rawValue) is on the Nintendo 64 pad")
        }
        for element in [ControlElement.btnSelect, .btnX, .btnY, .btnMic, .btnR2, .btnMode,
                        .stickRight, .btnL3, .btnR3] {
            #expect(!set.contains(element), "\(element.rawValue) is not on the Nintendo 64 pad")
        }
        #expect(ControlElement.btnL2.displayName(for: .n64) == "Z")
    }

    /// The C bits are `N64InputBits` in N64Bridge.h, which is what the bridge
    /// reads. Pinned by value here because the two cannot import each other's
    /// declaration; if either moves, this and the header move together.
    @Test func theCButtonsTravelOnTheBridgesBits() {
        #expect(GBAInput.cUp.rawValue == 0x10000)
        #expect(GBAInput.cDown.rawValue == 0x20000)
        #expect(GBAInput.cLeft.rawValue == 0x40000)
        #expect(GBAInput.cRight.rawValue == 0x80000)
        // Clear of every bit the other consoles use, Z (the PlayStation's L2) included.
        let others: UInt32 = 0xFFFF
        for bit in [GBAInput.cUp, .cDown, .cLeft, .cRight] {
            #expect(bit.rawValue & others == 0)
        }
    }

    // MARK: - A physical pad

    private func mask(_ apply: (inout ControllerInputSource) -> Void,
                      mapping: ControllerMapping? = nil) -> UInt32 {
        var s = ControllerInputSource()
        apply(&s)
        return ControllerManager.buttonMask(from: s, mapping: mapping, system: .n64)
    }

    /// The core's own RetroPad layout: bottom A, left B, top C up, right C
    /// down, bumpers L and R, left trigger Z, Menu START, and no SELECT.
    @Test func aPadPressesTheN64sButtonsWhereTheCoreHasThem() {
        #expect(mask { $0.faceA = true } == GBAInput.a.rawValue)
        #expect(mask { $0.faceX = true } == GBAInput.b.rawValue)
        #expect(mask { $0.faceY = true } == GBAInput.cUp.rawValue)
        #expect(mask { $0.faceB = true } == GBAInput.cDown.rawValue)
        #expect(mask { $0.shoulderL = true } == GBAInput.l.rawValue)
        #expect(mask { $0.shoulderR = true } == GBAInput.r.rawValue)
        #expect(mask { $0.leftTrigger = true } == GBAInput.l2.rawValue)
        #expect(mask { $0.menu = true } == GBAInput.start.rawValue)
        #expect(mask { $0.options = true; $0.hasOptions = true } == 0)
        #expect(mask { $0.leftStickClick = true } == 0)
    }

    /// The stick is the N64's own analog control, so a push of it must not
    /// also press the D-pad; the D-pad itself still does.
    @Test func theStickDoesNotPressTheDPad() {
        // A stick pushed up: the folded direction is set, the pad's own is not.
        #expect(mask { $0.up = true; $0.leftStickY = 1 } == 0)
        #expect(mask { $0.up = true; $0.padUp = true } == GBAInput.up.rawValue)
        #expect(mask { $0.left = true; $0.padLeft = true } == GBAInput.left.rawValue)
        // Every other console keeps the folded directions.
        var s = ControllerInputSource()
        s.up = true
        #expect(ControllerManager.buttonMask(from: s, system: .ps1) == GBAInput.up.rawValue)
    }

    /// A custom mapping starts from `defaults(for:)`, so that starting point
    /// has to press exactly what the built-in layout presses.
    @Test func theRemapStartingPointIsTheBuiltInLayout() {
        let defaults = ControllerMapping.defaults(for: .n64)
        for button in PhysicalButton.allCases {
            var s = ControllerInputSource()
            switch button {
            case .faceA: s.faceA = true
            case .faceB: s.faceB = true
            case .faceX: s.faceX = true
            case .faceY: s.faceY = true
            case .shoulderL: s.shoulderL = true
            case .shoulderR: s.shoulderR = true
            case .menu: s.menu = true
            case .options: s.options = true; s.hasOptions = true
            case .leftStickClick: s.leftStickClick = true
            case .leftTrigger: s.leftTrigger = true
            case .rightTrigger: s.rightTrigger = true
            case .rightStickClick: s.rightStickClick = true
            }
            #expect(ControllerManager.buttonMask(from: s, mapping: defaults, system: .n64)
                    == ControllerManager.buttonMask(from: s, system: .n64),
                    "\(button.rawValue): the remap's starting point differs from the built-in layout")
        }
        // Everything it binds is an input this console has.
        let available = Set(RemappableInput.available(on: .n64))
        for input in defaults.assignments.keys {
            #expect(available.contains(input), "\(input.rawValue) is not an N64 input")
        }
    }

    @Test func theRemapPagesOfferTheN64sInputs() {
        let inputs = RemappableInput.available(on: .n64)
        #expect(inputs.count == 10)
        #expect(!inputs.contains(.select) && !inputs.contains(.x) && !inputs.contains(.y))
        // Every one has a keyboard row too, through the shared raw values.
        #expect(KeyboardInput.buttons(on: .n64).count == inputs.count)
        #expect(RemappableInput.l2.displayName(for: .n64) == "Z")
        #expect(KeyboardInput.l2.displayName(for: .n64) == "Z")
        #expect(KeyboardInput.l2.displayName(for: .ps1) == "L2")
    }

    // MARK: - The page

    /// The C buttons sit where the PlayStation's right stick sat, as a diamond:
    /// C UP above C DOWN on one column, C LEFT and C RIGHT on the line between
    /// them, and no two of the four touching. On real pages, insets included,
    /// because the insets decide how tall the portrait container is.
    @Test func theCButtonsFormADiamondThatNeverTouchesItself() {
        let pages: [(String, CGSize, UIEdgeInsets, Bool)] = [
            ("SE portrait", CGSize(width: 375, height: 667), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0), false),
            ("SE landscape", CGSize(width: 667, height: 375), .zero, true),
            ("14 Pro portrait", CGSize(width: 393, height: 852), UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0), false),
            ("14 Pro landscape", CGSize(width: 852, height: 393), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59), true),
        ]
        for (label, device, insets, isLandscape) in pages {
            let k = EmulatorLayoutGeometry.deviceScale(for: device)
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: device, safeInsets: insets, hasTouchScreen: false, isLandscape: isLandscape,
                gameAspect: PresetLayoutResolver.displayAspect(.n64), system: .n64,
                controllerConnected: false, deviceScale: k)
            let container = EmulatorLayoutGeometry.controlsFrame(
                deviceSize: device, screenFrame: screen, hasTouchScreen: false,
                isLandscape: isLandscape).size
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .n64, isLandscape: isLandscape, containerSize: container, scale: k,
                safeLeftInset: isLandscape ? insets.left : 0,
                safeRightInset: isLandscape ? insets.right : 0)
            func centre(_ e: ControlElement) -> CGPoint? {
                guard let b = layout.buttons[e.rawValue] else { return nil }
                return CGPoint(x: b.centerX * container.width, y: b.centerY * container.height)
            }
            guard let up = centre(.btnCUp), let down = centre(.btnCDown),
                  let left = centre(.btnCLeft), let right = centre(.btnCRight) else {
                Issue.record("\(label): a C button was never placed")
                continue
            }
            #expect(abs(up.x - down.x) < 0.01 && up.y < down.y, "\(label): C up is not above C down")
            #expect(abs(left.y - right.y) < 0.01 && left.x < right.x, "\(label): C left and right are not a row")
            #expect(abs(left.y - (up.y + down.y) / 2) < 0.01, "\(label): the row is not between up and down")
            let d = EmulatorLayoutGeometry.buttonSize(.btnCUp, system: .n64, isLandscape: isLandscape,
                                                      deviceScale: k).width
            let points = [up, down, left, right]
            for i in points.indices {
                for j in points.indices where j > i {
                    let gap = hypot(points[i].x - points[j].x, points[i].y - points[j].y) - d
                    #expect(gap > 0.5, "\(label): two C buttons touch (gap \(gap))")
                }
            }
            // And nothing the pad lacks was placed.
            for e in [ControlElement.btnSelect, .btnX, .btnY, .btnMode, .btnR2,
                      .stickRight, .btnL3, .btnR3] {
                #expect(layout.buttons[e.rawValue] == nil, "\(label): \(e.rawValue) was placed")
            }
        }
    }

    /// Every control it shares with the PlayStation takes the PlayStation's
    /// size, except the four asked otherwise on 2026-09-27: Z is a round face
    /// the size of A, the cross is a fifth smaller (0.6 on its side), and upright L and R are the
    /// GBA's bars. The C buttons are their own size.
    @Test func sharedControlsTakeThePlayStationsSizesExceptTheFourAsked() {
        for isLandscape in [false, true] {
            for element in ControlElement.elements(for: .n64) {
                let n64 = EmulatorLayoutGeometry.referenceSize(element, system: .n64, isLandscape: isLandscape)
                let ps1 = EmulatorLayoutGeometry.referenceSize(element, system: .ps1, isLandscape: isLandscape)
                switch element {
                case _ where ControlElement.n64CButtons.contains(element):
                    #expect(n64 == CGSize(width: EmulatorLayoutGeometry.n64CButtonSize,
                                          height: EmulatorLayoutGeometry.n64CButtonSize))
                case .btnL2:
                    #expect(n64 == EmulatorLayoutGeometry.referenceSize(.btnA, system: .ps1,
                                                                        isLandscape: isLandscape))
                case .dpad:
                    let scale = isLandscape ? EmulatorLayoutGeometry.n64LandscapePadScale
                                            : EmulatorLayoutGeometry.n64PadScale
                    #expect(abs(n64.width - ps1.width * scale) < 0.001
                            && abs(n64.height - ps1.height * scale) < 0.001)
                case .btnL where !isLandscape, .btnR where !isLandscape:
                    #expect(n64 == EmulatorLayoutGeometry.referenceSize(element, system: .gba,
                                                                        isLandscape: false),
                            "\(element.rawValue): not the GBA's bar")
                default:
                    #expect(n64 == ps1, "\(element.rawValue): not the PlayStation's size")
                }
            }
        }
    }

    /// The upright page as described on 2026-09-27: L, MENU and R on the GBA's
    /// row; below it one block, full width, down to the bottom of the page, in
    /// four quarters (stick top left, A B Z top right, cross bottom left, C
    /// buttons bottom right) with START at its centre; A, B and Z an
    /// equilateral triangle; and the four C triangles' outer points on one
    /// circle, the one the dress draws.
    @Test func theUprightPageIsTheOneDescribed() {
        let pages: [(String, CGSize, UIEdgeInsets)] = [
            ("SE", CGSize(width: 375, height: 667), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)),
            ("14 Pro", CGSize(width: 393, height: 852), UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)),
            ("Pro Max", CGSize(width: 440, height: 956), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
        ]
        for (label, device, insets) in pages {
            let k = EmulatorLayoutGeometry.deviceScale(for: device)
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: device, safeInsets: insets, hasTouchScreen: false, isLandscape: false,
                gameAspect: PresetLayoutResolver.displayAspect(.n64), system: .n64,
                controllerConnected: false, deviceScale: k)
            let container = EmulatorLayoutGeometry.controlsFrame(
                deviceSize: device, screenFrame: screen, hasTouchScreen: false, isLandscape: false).size
            let w = container.width, h = container.height
            let n64 = ControlLayoutDefaults.defaultLayout(system: .n64, isLandscape: false,
                                                          containerSize: container, scale: k)
            let gba = ControlLayoutDefaults.defaultLayout(system: .gba, isLandscape: false,
                                                          containerSize: container, scale: k)
            func centre(_ layout: OrientationLayout, _ e: ControlElement) -> CGPoint {
                guard let b = layout.buttons[e.rawValue] else { return CGPoint(x: -999, y: -999) }
                return CGPoint(x: b.centerX * w, y: b.centerY * h)
            }
            func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.01 }

            for e in [ControlElement.btnL, .btnR, .btnMenu] {
                #expect(near(centre(n64, e), centre(gba, e)), "\(label): \(e.rawValue) is off the GBA's row")
            }
            let lHeight = EmulatorLayoutGeometry.buttonSize(.btnL, system: .n64, isLandscape: false,
                                                            deviceScale: k).height
            let top = centre(n64, .btnL).y + lHeight / 2
            let upper = top + (h - top) / 4, lower = top + (h - top) * 3 / 4
            #expect(near(centre(n64, .stickLeft), CGPoint(x: w / 4, y: upper)), "\(label): stick")
            #expect(near(centre(n64, .dpad), CGPoint(x: w / 4, y: lower)), "\(label): cross")
            #expect(near(centre(n64, .btnStart), CGPoint(x: w / 2, y: (top + h) / 2)), "\(label): START")

            let a = centre(n64, .btnA), b = centre(n64, .btnB), z = centre(n64, .btnL2)
            let side = ControlLayoutDefaults.n64FaceTriangleSide * k
            for (p, q) in [(a, b), (b, z), (z, a)] {
                #expect(abs(hypot(p.x - q.x, p.y - q.y) - side) < 0.01, "\(label): A B Z not equilateral")
            }
            #expect(near(CGPoint(x: (a.x + b.x + z.x) / 3, y: (a.y + b.y + z.y) / 3),
                         CGPoint(x: w * 3 / 4, y: upper)), "\(label): A B Z off its quarter's centre")
            #expect(b.x < a.x && z.x > a.x && b.y < a.y && z.y < a.y, "\(label): A B Z the wrong way round")

            let c = EmulatorLayoutGeometry.buttonSize(.btnCUp, system: .n64, isLandscape: false,
                                                      deviceScale: k).width
            let radius = ControlLayoutDefaults.n64CGeometry(buttonWidth: c, scale: k).circleRadius
            let apex = ControlLayoutDefaults.n64ArrowApexOffset(buttonWidth: c)
            let hub = CGPoint(x: w * 3 / 4, y: lower)
            for (e, dir) in [(ControlElement.btnCUp, CGPoint(x: 0, y: -1)), (.btnCDown, CGPoint(x: 0, y: 1)),
                             (.btnCLeft, CGPoint(x: -1, y: 0)), (.btnCRight, CGPoint(x: 1, y: 0))] {
                let p = centre(n64, e)
                let tip = CGPoint(x: p.x + dir.x * apex, y: p.y + dir.y * apex)
                #expect(abs(hypot(tip.x - hub.x, tip.y - hub.y) - radius) < 0.01,
                        "\(label): \(e.rawValue)'s point is off the C circle")
            }
        }
    }

    /// The page on its side follows the same rule (asked 2026-09-27): the stick
    /// above the cross in the left gutter, A B Z above the C circle in the
    /// right one, each pair on one vertical line; MENU and START one pair
    /// centred under the picture; and CLIP, both ways, under R and halfway
    /// between the bottom of A and the top of C UP.
    @Test func thePageOnItsSideIsTheSameRule() {
        let pages: [(String, CGSize, UIEdgeInsets, Bool)] = [
            ("SE on its side", CGSize(width: 667, height: 375), .zero, true),
            ("14 Pro on its side", CGSize(width: 852, height: 393), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59), true),
            ("SE upright", CGSize(width: 375, height: 667), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0), false),
            ("14 Pro upright", CGSize(width: 393, height: 852), UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0), false),
        ]
        for (label, device, insets, isLandscape) in pages {
            let k = EmulatorLayoutGeometry.deviceScale(for: device)
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: device, safeInsets: insets, hasTouchScreen: false, isLandscape: isLandscape,
                gameAspect: PresetLayoutResolver.displayAspect(.n64), system: .n64,
                controllerConnected: false, deviceScale: k)
            let container = EmulatorLayoutGeometry.controlsFrame(
                deviceSize: device, screenFrame: screen, hasTouchScreen: false, isLandscape: isLandscape)
            let w = container.width, h = container.height
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .n64, isLandscape: isLandscape, containerSize: container.size, scale: k,
                safeLeftInset: isLandscape ? insets.left : 0, safeRightInset: isLandscape ? insets.right : 0)
            func c(_ e: ControlElement) -> CGPoint {
                guard let b = layout.buttons[e.rawValue] else { return CGPoint(x: -999, y: -999) }
                return CGPoint(x: b.centerX * w, y: b.centerY * h)
            }
            func half(_ e: ControlElement) -> CGFloat {
                EmulatorLayoutGeometry.buttonSize(e, system: .n64, isLandscape: isLandscape,
                                                  deviceScale: k).height / 2
            }
            #expect(abs(c(.stickLeft).x - c(.dpad).x) < 0.01 && c(.stickLeft).y < c(.dpad).y,
                    "\(label): the stick is not above the cross")
            let faces = CGPoint(x: (c(.btnA).x + c(.btnB).x + c(.btnL2).x) / 3,
                                y: (c(.btnA).y + c(.btnB).y + c(.btnL2).y) / 3)
            #expect(abs(faces.x - c(.btnCUp).x) < 0.01 && faces.y < c(.btnCUp).y,
                    "\(label): A B Z are not above the C buttons")
            // The C buttons a square about one centre, so the dress draws their circle.
            let hub = CGPoint(x: c(.btnCUp).x, y: (c(.btnCUp).y + c(.btnCDown).y) / 2)
            #expect(abs((c(.btnCRight).x - c(.btnCLeft).x) / 2 - (c(.btnCDown).y - c(.btnCUp).y) / 2) < 0.01
                    && abs(c(.btnCLeft).y - hub.y) < 0.01, "\(label): the C buttons are not a square")
            #expect(abs(c(.btnClip).x - c(.btnR).x) < 0.01, "\(label): CLIP is not under R")
            let gapMid = ((c(.btnA).y + half(.btnA)) + (c(.btnCUp).y - half(.btnCUp))) / 2
            #expect(abs(c(.btnClip).y - gapMid) < 0.01, "\(label): CLIP is not halfway between A and C UP")
            if isLandscape {
                #expect(abs(c(.btnMenu).y - c(.btnStart).y) < 0.01, "\(label): MENU and START are not one row")
                let row = (c(.btnMenu).x - EmulatorLayoutGeometry.buttonSize(.btnMenu, system: .n64,
                              isLandscape: true, deviceScale: k).width / 2
                           + c(.btnStart).x + EmulatorLayoutGeometry.buttonSize(.btnStart, system: .n64,
                              isLandscape: true, deviceScale: k).width / 2) / 2
                #expect(abs(row - screen.midX) < 0.5, "\(label): MENU and START are not centred under the picture")
                #expect(c(.stickLeft).x < screen.minX && c(.btnA).x > screen.maxX,
                        "\(label): a column is not in its gutter")
            }
        }
    }

    /// On a tablet the page is built from the thumbs (asked 2026-09-27): the
    /// stick and A-B-Z lowest, the cross and the C buttons above them, L and R
    /// above those, each column held to its side, and nothing high on the page.
    @Test func onATabletEveryControlIsNearAThumb() {
        let windows: [(String, CGSize, Bool)] = [
            ("iPad mini upright", CGSize(width: 744, height: 1133), false),
            ("iPad 13 upright", CGSize(width: 1032, height: 1376), false),
            ("iPad mini on its side", CGSize(width: 1133, height: 744), true),
            ("iPad 13 on its side", CGSize(width: 1376, height: 1032), true),
        ]
        let insets = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
        for (label, device, isLandscape) in windows {
            #expect(LayoutFamily.of(device) == .tablet)
            let k = EmulatorLayoutGeometry.deviceScale(for: device)
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: device, safeInsets: insets, hasTouchScreen: false, isLandscape: isLandscape,
                gameAspect: PresetLayoutResolver.displayAspect(.n64), system: .n64,
                controllerConnected: false, deviceScale: k)
            let container = EmulatorLayoutGeometry.controlsFrame(
                deviceSize: device, screenFrame: screen, hasTouchScreen: false, isLandscape: isLandscape)
            let w = container.width, h = container.height
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .n64, isLandscape: isLandscape, containerSize: container.size, scale: k,
                family: .tablet)
            func c(_ e: ControlElement) -> CGPoint {
                guard let b = layout.buttons[e.rawValue] else { return CGPoint(x: -999, y: -999) }
                return CGPoint(x: b.centerX * w, y: container.minY + b.centerY * h)
            }
            #expect(c(.stickLeft).y > c(.dpad).y, "\(label): the stick is not under the cross")
            #expect(c(.btnA).y > c(.btnCDown).y, "\(label): A-B-Z are not under the C buttons")
            #expect(c(.btnL).y < c(.dpad).y && c(.btnR).y < c(.btnCUp).y, "\(label): L and R are not on top")
            #expect(c(.stickLeft).x < device.width / 2 && c(.btnA).x > device.width / 2)
            // The two thumbs' controls in the bottom third of the window.
            for e in [ControlElement.stickLeft, .btnA, .btnB, .btnL2] {
                #expect(c(e).y > device.height * 2 / 3, "\(label): \(e.rawValue) is out of the thumb's reach")
            }
        }
    }

    // MARK: - Presets

    @Test func aPresetForTheN64ResolvesToIt() throws {
        #expect(SystemApplicability(system: .n64).system == .n64)
        let encoded = try JSONEncoder().encode(SystemApplicability(system: .n64))
        #expect(try JSONDecoder().decode(SystemApplicability.self, from: encoded).system == .n64)
        // A preset saved before the flag existed still resolves where it did.
        let legacy = Data(#"{"gba":false,"gbc":false,"nds":false,"snes":false,"nes":false,"ps1":true}"#.utf8)
        #expect(try JSONDecoder().decode(SystemApplicability.self, from: legacy).system == .ps1)
    }

    // MARK: - The dress

    /// Dressed in game, on its share card, and open to custom skins.
    @MainActor
    @Test func itIsDressedInGameOnItsCardAndInCustomSkins() {
        #expect(ConsoleSkinView.hasSkin(for: .n64))
        #expect(ConsoleSkinView.hasDressedControls(for: .n64))
        #expect(TouchControlsView.dressKind(for: .n64) == .n64)
        #expect(PresetSystem.n64.supportsCustomSkins)
        #expect(ScreenshotCardRenderer.hasConsoleCard(.n64))
        #expect(SkinPalette.nostalgiaSeed(for: .n64) == .n64(.nostalgia))
    }

    /// A skin opened from Classic starts exactly where the Classic dress is:
    /// every slot is the dress's own value. Retro Pal changes the shell only.
    @Test func theSeedPaletteIsTheClassicDress() {
        let p = N64SkinPalette.nostalgia
        #expect(p.body == DressKind.n64Body && p.shoulders == DressKind.n64Trigger)
        #expect(p.menuButtons == DressKind.n64Trigger && p.dpad == DressKind.n64Trigger)
        #expect(p.stickSurround == DressKind.n64Trigger && p.stick == DressKind.n64Pad)
        #expect(p.dpadMarks == DressKind.n64PadInk && p.start == DressKind.n64Start)
        #expect(p.a == DressKind.n64A && p.b == DressKind.n64B)
        #expect(p.z == DressKind.n64C && p.c == DressKind.n64C)
        var retro = N64SkinPalette.retroPal
        #expect(retro.body == RetroPalPalette.n64Body)
        retro.bodyHex = p.bodyHex
        #expect(retro == p)
        #expect(DressVariant.nostalgia.n64 == .nostalgia && DressVariant.retroPal.n64 == .retroPal)
    }

    /// A custom skin keeps every slot apart through a save and a share, and the
    /// controls every console shares take their slot from it.
    @Test func aCustomSkinKeepsItsSlotsApart() throws {
        var p = N64SkinPalette.nostalgia
        p.aHex = 0x112233; p.bHex = 0x445566; p.menuButtonsHex = 0x778899; p.shouldersHex = 0xAABBCC
        p.dpadHex = 0x010203
        let decoded = try JSONDecoder().decode(SkinPalette.self,
                                               from: JSONEncoder().encode(SkinPalette.n64(p)))
        #expect(decoded == .n64(p))
        let variant = DressVariant.custom(.n64(p))
        #expect(variant.n64 == p)
        #expect(variant.smallButtonFace(.n64) == p.menuButtons)
        #expect(variant.shoulderFace(.n64) == p.shoulders)
        #expect(variant.dpadFace(.n64) == p.dpad)
        #expect(p.a != p.b && p.menuButtons != p.shoulders)
    }

    /// The card: every control inside the card and off the picture, none on
    /// another, and a column left for the game's name.
    @Test func theCardHoldsItsControlsClearOfThePictureAndEachOther() {
        let side: CGFloat = 1080
        let layout = GBCardLayout.n64(side: side, gameNativeSize: CGSize(width: 4, height: 3))
        let k = layout.deviceScale
        var rects: [ControlElement: CGRect] = [:]
        for e in ControlElement.elements(for: .n64) where e != .btnMenu && e != .btnClip {
            guard let b = layout.buttons[e.rawValue], !b.isHidden else {
                Issue.record("\(e.rawValue) is not on the card")
                continue
            }
            let s = EmulatorLayoutGeometry.buttonSize(e, system: .n64, isLandscape: false, deviceScale: k)
            rects[e] = CGRect(x: b.centerX * side - s.width / 2, y: b.centerY * side - s.height / 2,
                              width: s.width, height: s.height)
        }
        let card = CGRect(x: 0, y: 0, width: side, height: side)
        for (e, r) in rects {
            #expect(card.contains(r), "\(e.rawValue) leaves the card")
            let covered = r.intersection(layout.screen)
            #expect(covered.isNull || covered.width < 0.5 || covered.height < 0.5,
                    "\(e.rawValue) is on the picture")
        }
        let elements = Array(rects.keys)
        for i in elements.indices {
            for j in elements.indices where j > i {
                let depth = ButtonShape.penetration(ButtonShape.of(elements[i], rects[elements[i]]!, system: .n64),
                                                    ButtonShape.of(elements[j], rects[elements[j]]!, system: .n64))
                #expect(depth < 0.5, "\(elements[i].rawValue) overlaps \(elements[j].rawValue)")
            }
        }
        #expect((GBCardLayout.n64InfoColumnWidth(layout, side: side) ?? 0) > 300)
    }

    /// The Retro Pal N64 changes the shell and nothing else.
    @Test func retroPalLeavesEveryControlItsClassicColour() {
        #expect(RetroPalPalette.buttonFill(.n64) == nil)
        #expect(DressVariant.retroPal.abFace(.n64) == nil)
        #expect(DressVariant.retroPal.dpadFace(.n64) == nil)
        #expect(RetroPalPalette.n64Body != DressKind.n64Body)
    }
}
