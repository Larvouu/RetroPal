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

    /// The upright page as described on 2026-09-27 and moved on 2026-10-09: L
    /// and R on the GBA's row, CLIP and MENU between them, the row's gaps equal;
    /// below it one block, full width, down to the bottom of the page, in four
    /// quarters (stick top left, a little low; A B Z top right; cross bottom
    /// left; C buttons bottom right); START at the bottom between the columns,
    /// its centre on the bottom of C DOWN; A, B and Z an equilateral triangle;
    /// and the four C triangles' outer points on one circle, the one the dress
    /// draws.
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

            for e in [ControlElement.btnL, .btnR] {
                #expect(near(centre(n64, e), centre(gba, e)), "\(label): \(e.rawValue) is off the GBA's row")
            }
            // L · CLIP · MENU · R: one row, the CLIP-MENU pair centred, CLIP first.
            let clip = centre(n64, .btnClip), menu = centre(n64, .btnMenu)
            let clipW = EmulatorLayoutGeometry.buttonSize(.btnClip, system: .n64, isLandscape: false,
                                                          deviceScale: k).width
            let menuW = EmulatorLayoutGeometry.buttonSize(.btnMenu, system: .n64, isLandscape: false,
                                                          deviceScale: k).width
            #expect(abs(clip.y - centre(n64, .btnL).y) < 0.01 && abs(menu.y - clip.y) < 0.01,
                    "\(label): CLIP and MENU are not on L and R's row")
            #expect(centre(n64, .btnL).x < clip.x && clip.x < menu.x && menu.x < centre(n64, .btnR).x,
                    "\(label): the row is not L CLIP MENU R")
            #expect(abs(((clip.x - clipW / 2) + (menu.x + menuW / 2)) / 2 - w / 2) < 0.01,
                    "\(label): the CLIP-MENU pair is not centred")
            // The row's three gaps equal (asked 2026-10-09).
            let lW = EmulatorLayoutGeometry.buttonSize(.btnL, system: .n64, isLandscape: false,
                                                       deviceScale: k).width
            let rowGaps = [(clip.x - clipW / 2) - (centre(n64, .btnL).x + lW / 2),
                           (menu.x - menuW / 2) - (clip.x + clipW / 2),
                           (centre(n64, .btnR).x - lW / 2) - (menu.x + menuW / 2)]
            #expect(rowGaps.allSatisfy { $0 > 0 } && abs(rowGaps[0] - rowGaps[1]) < 0.01
                    && abs(rowGaps[1] - rowGaps[2]) < 0.01, "\(label): the top row's gaps differ (\(rowGaps))")
            let lHeight = EmulatorLayoutGeometry.buttonSize(.btnL, system: .n64, isLandscape: false,
                                                            deviceScale: k).height
            let top = centre(n64, .btnL).y + lHeight / 2
            let upper = top + (h - top) / 4, lower = top + (h - top) * 3 / 4
            #expect(near(centre(n64, .stickLeft),
                         CGPoint(x: w / 4, y: upper + ControlLayoutDefaults.n64PortraitStickDrop * k)),
                    "\(label): stick")
            #expect(near(centre(n64, .dpad), CGPoint(x: w / 4, y: lower)), "\(label): cross")

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

            // START at the bottom, between the columns, its centre on the bottom
            // of C DOWN, unless that would hang it off the glass (the SE).
            let start = centre(n64, .btnStart)
            let startH = EmulatorLayoutGeometry.buttonSize(.btnStart, system: .n64, isLandscape: false,
                                                           deviceScale: k).height
            let cDownBottom = centre(n64, .btnCDown).y + c / 2
            let held = h - startH / 2 - ControlLayoutDefaults.n64StartEdge * k
            #expect(abs(start.x - w / 2) < 0.01, "\(label): START is not centred")
            #expect(abs(start.y - min(cDownBottom, held)) < 0.01, "\(label): START is off C DOWN's bottom")
            #expect(start.y + startH / 2 <= h + 0.01, "\(label): START leaves the glass")
            if cDownBottom <= held {
                #expect(abs(start.y - cDownBottom) < 0.01, "\(label): START moved though it had room")
            }
        }
    }

    /// The page on its side follows the same rule (asked 2026-09-27): the stick
    /// above the cross in the left gutter, A B Z above the C circle in the
    /// right one, each pair on one vertical line. Since 2026-10-09 CLIP ·
    /// START · MENU are one row centred under the picture, and the right
    /// gutter's two groups stack with equal gaps from R down to the home
    /// indicator. Upright, CLIP has left R's column for the top row.
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
            if isLandscape {
                #expect(abs(c(.btnMenu).y - c(.btnStart).y) < 0.01 && abs(c(.btnClip).y - c(.btnStart).y) < 0.01,
                        "\(label): CLIP, START and MENU are not one row")
                #expect(c(.btnClip).x < c(.btnStart).x && c(.btnStart).x < c(.btnMenu).x,
                        "\(label): the row is not CLIP START MENU")
                #expect(abs(c(.btnStart).x - screen.midX) < 0.5, "\(label): the row is not centred under the picture")
                #expect(c(.stickLeft).x < screen.minX && c(.btnA).x > screen.maxX,
                        "\(label): a column is not in its gutter")
                // The two groups, at the size they are drawn, with equal gaps
                // from R's bottom to the home indicator's reserve.
                let grow = ControlLayoutDefaults.n64LandscapeFaceScale
                let faceHalf = half(.btnA) * grow, cHalf = half(.btnCUp) * grow
                let facesTop = c(.btnB).y - faceHalf, facesBottom = c(.btnA).y + faceHalf
                let cTop = c(.btnCUp).y - cHalf, cBottom = c(.btnCDown).y + cHalf
                let rBottom = c(.btnR).y + half(.btnR)
                let floor = h - EmulatorLayoutGeometry.snesLandscapeIndicatorReserve
                let gaps = [facesTop - rBottom, cTop - facesBottom, floor - cBottom]
                #expect(gaps.allSatisfy { $0 > 0 }, "\(label): the right gutter's groups touch (\(gaps))")
                #expect(abs(gaps[0] - gaps[1]) < 0.01 && abs(gaps[1] - gaps[2]) < 0.01,
                        "\(label): the right gutter's gaps are not equal (\(gaps))")
            } else {
                #expect(abs(c(.btnClip).y - c(.btnMenu).y) < 0.01, "\(label): CLIP is not beside MENU")
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

    /// On an iPhone on its side the right gutter's groups are drawn larger and
    /// the stick smaller (asked 2026-10-09), and nowhere else: the tablet and
    /// upright pages, every preset, and every other console keep the table sizes.
    @Test func onlyThePhoneOnItsSideRescalesTheN64() {
        for e in [ControlElement.btnA, .btnB, .btnL2, .btnCUp, .btnCDown, .btnCLeft, .btnCRight] {
            #expect(ControlLayoutDefaults.n64PhoneScale(e, isLandscape: true, family: .phone, system: .n64)
                    == ControlLayoutDefaults.n64LandscapeFaceScale)
            #expect(ControlLayoutDefaults.n64PhoneScale(e, isLandscape: false, family: .phone, system: .n64) == 1)
            #expect(ControlLayoutDefaults.n64PhoneScale(e, isLandscape: true, family: .tablet, system: .n64) == 1)
            #expect(ControlLayoutDefaults.n64PhoneScale(e, isLandscape: true, family: .phone, system: .ps1) == 1)
        }
        #expect(ControlLayoutDefaults.n64PhoneScale(.stickLeft, isLandscape: true, family: .phone, system: .n64)
                == ControlLayoutDefaults.n64LandscapeStickScale)
        for e in [ControlElement.btnL, .btnR, .btnMenu, .btnClip, .btnStart, .dpad] {
            #expect(ControlLayoutDefaults.n64PhoneScale(e, isLandscape: true, family: .phone, system: .n64) == 1,
                    "\(e.rawValue) is rescaled")
        }
        #expect(ControlLayoutDefaults.n64LandscapeFaceScale > 1)
        #expect(ControlLayoutDefaults.n64LandscapeStickScale < 1)
    }

    /// On an iPhone on its side the stick's surround shrinks with the stick
    /// and the gate inside it does not (asked 2026-10-09): the gate keeps the
    /// size it had when the surround was full, and still fits inside it.
    @Test func onItsSideTheSurroundShrinksAndTheGateDoesNot() {
        let table: CGFloat = 80
        let drawn = table * ControlLayoutDefaults.n64LandscapeStickScale
        let surround = ControlLayoutDefaults.n64StickSurroundRadius(
            drawnStickWidth: drawn, isLandscape: true, family: .phone)
        let gate = ControlLayoutDefaults.n64StickGateRadius(
            drawnStickWidth: drawn, isLandscape: true, family: .phone)
        #expect(abs(surround - table * ControlLayoutDefaults.n64LandscapeSurroundScale) < 0.001)
        #expect(abs(gate - table * 0.78) < 0.001, "the gate changed size")
        #expect(gate < surround, "the gate is wider than its surround")
        // Upright and on a tablet nothing changes.
        #expect(ControlLayoutDefaults.n64StickSurroundRadius(drawnStickWidth: table, isLandscape: false,
                                                            family: .phone) == table)
        #expect(ControlLayoutDefaults.n64StickSurroundRadius(drawnStickWidth: table, isLandscape: true,
                                                            family: .tablet) == table)
    }

    /// On its side the stick's surround stays clear of the picture, with room
    /// for the frame the dress draws round it (asked 2026-10-09: they collided).
    @Test func onItsSideTheStickSurroundClearsThePicture() {
        let pages: [(String, CGSize, UIEdgeInsets)] = [
            ("SE", CGSize(width: 667, height: 375), .zero),
            ("13 mini", CGSize(width: 812, height: 375), UIEdgeInsets(top: 0, left: 50, bottom: 21, right: 50)),
            ("14 Pro", CGSize(width: 852, height: 393), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
            ("Pro Max", CGSize(width: 956, height: 440), UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
        ]
        for (label, device, insets) in pages {
            let k = EmulatorLayoutGeometry.deviceScale(for: device)
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: device, safeInsets: insets, hasTouchScreen: false, isLandscape: true,
                gameAspect: PresetLayoutResolver.displayAspect(.n64), system: .n64,
                controllerConnected: false, deviceScale: k)
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .n64, isLandscape: true, containerSize: device, scale: k,
                safeLeftInset: insets.left, safeRightInset: insets.right)
            guard let stick = layout.buttons[ControlElement.stickLeft.rawValue] else {
                Issue.record("\(label): no stick"); continue
            }
            let drawn = EmulatorLayoutGeometry.buttonSize(.stickLeft, system: .n64, isLandscape: true,
                                                          deviceScale: k).width
                * ControlLayoutDefaults.n64LandscapeStickScale
            let surround = ControlLayoutDefaults.n64StickSurroundRadius(
                drawnStickWidth: drawn, isLandscape: true, family: .phone)
            let right = stick.centerX * device.width + surround
            #expect(right < screen.minX - 2 * k, "\(label): the stick's surround reaches the picture (\(right) vs \(screen.minX))")
        }
    }

    /// The N64's hold-to-lock covers Z too (asked 2026-10-09), and the pause
    /// menu names it: the caption reads the letters off the same view.
    @MainActor
    @Test func holdToLockCoversZ() {
        let view = N64TouchControlsView()
        #expect(view.lockableMask & GBAInput.l2.rawValue != 0, "Z does not lock")
        #expect(view.lockableMask & GBAInput.a.rawValue != 0 && view.lockableMask & GBAInput.b.rawValue != 0)
        #expect(view.lockableMask & GBAInput.cUp.rawValue == 0, "a C button locks")
        #expect(view.lockableLetters == ["A", "B", "Z"])
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
