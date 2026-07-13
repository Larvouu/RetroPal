//
//  EmulatorLayoutGeometryTests.swift
//  EmulateurGBATests
//
//  Locks the device-relative in-game layout:
//   - the reference device (iPhone 14 Pro) is pixel-identical to the original
//     hand-tuned layout (deviceScale == 1, sizes == element defaults, screen
//     frames == the original formulas) — i.e. ZERO regression on that device;
//   - the comfortable-minimum floor never inflates intentionally-thin buttons;
//   - on the smallest supported device (iPhone SE) the controls no longer
//     overlap — the bug this layout work fixes.
//

import Testing
import UIKit
@testable import EmulateurGBA

@Suite("EmulatorLayoutGeometry")
struct EmulatorLayoutGeometryTests {

    // iPhone 14 Pro (the reference) and iPhone SE 2nd/3rd gen, in points.
    static let proPortrait = CGSize(width: 393, height: 852)
    static let proLandscape = CGSize(width: 852, height: 393)
    static let sePortrait = CGSize(width: 375, height: 667)
    static let seLandscape = CGSize(width: 667, height: 375)

    private func approx(_ a: CGFloat, _ b: CGFloat, tol: CGFloat = 0.5) -> Bool {
        abs(a - b) <= tol
    }

    /// Native display aspect (width / height) per system, matching EmulatorSession.
    static func displayAspect(_ system: PresetSystem) -> CGFloat {
        switch system {
        case .gba: return 240.0 / 160.0
        case .gbc: return 160.0 / 144.0
        case .nds: return 256.0 / 384.0
        }
    }

    // MARK: - Device scale

    @Test func deviceScaleIsOneOnReferenceDevice() {
        #expect(approx(EmulatorLayoutGeometry.deviceScale(for: Self.proPortrait), 1, tol: 0.0001))
        #expect(approx(EmulatorLayoutGeometry.deviceScale(for: Self.proLandscape), 1, tol: 0.0001))
    }

    @Test func deviceScaleShrinksOnSmallerDevice() {
        let k = EmulatorLayoutGeometry.deviceScale(for: Self.sePortrait)
        #expect(k < 1)
        // The SE is height-bound vs the 14 Pro (667/852).
        #expect(approx(k, 667.0 / 852.0, tol: 0.01))
        // Same device in landscape resolves to the same scale (orientation-independent).
        #expect(approx(k, EmulatorLayoutGeometry.deviceScale(for: Self.seLandscape), tol: 0.0001))
    }

    @Test func deviceScaleClamps() {
        #expect(EmulatorLayoutGeometry.deviceScale(for: CGSize(width: 2000, height: 3000))
                == EmulatorLayoutGeometry.maxDeviceScale)
        #expect(EmulatorLayoutGeometry.deviceScale(for: CGSize(width: 100, height: 150))
                == EmulatorLayoutGeometry.minDeviceScale)
    }

    // MARK: - Button sizing

    @Test func buttonSizeAtReferenceEqualsElementDefaults() {
        for e in ControlElement.allCases {
            #expect(EmulatorLayoutGeometry.buttonSize(e, isNDS: false, isLandscape: false, deviceScale: 1) == e.defaultSize)
            #expect(EmulatorLayoutGeometry.buttonSize(e, isNDS: false, isLandscape: true, deviceScale: 1) == e.defaultLandscapeSize)
            #expect(EmulatorLayoutGeometry.buttonSize(e, isNDS: true, isLandscape: false, deviceScale: 1) == e.defaultNDSPortraitSize)
            #expect(EmulatorLayoutGeometry.buttonSize(e, isNDS: true, isLandscape: true, deviceScale: 1) == e.defaultNDSLandscapeSize)
        }
    }

    @Test func floorDoesNotInflateThinButtons() {
        // L is 110x38 in GBA landscape; the 44pt floor must NOT raise the 38 height.
        let l = EmulatorLayoutGeometry.buttonSize(.btnL, isNDS: false, isLandscape: true, deviceScale: 1)
        #expect(l.height == 38)
    }

    @Test func floorEngagesForSmallButtonsOnSmallDevice() {
        let k = EmulatorLayoutGeometry.deviceScale(for: Self.sePortrait) // ~0.783
        // A large face button scales down freely.
        let a = EmulatorLayoutGeometry.buttonSize(.btnA, isNDS: false, isLandscape: false, deviceScale: k)
        #expect(approx(a.width, 72.6 * k))
        // Menu (36 ref) would scale to ~28 but is floored to its own reference 36.
        let menu = EmulatorLayoutGeometry.buttonSize(.btnMenu, isNDS: true, isLandscape: false, deviceScale: k)
        #expect(menu.width == 36)
        #expect(menu.height == 36)
    }

    // MARK: - Screen frame (reference device == original formulas)

    @Test func screenFrameMatchesOriginalOnReferenceDevice() {
        let insets = UIEdgeInsets.zero

        // GBA portrait: maxH = h*0.45, y = top + 42, aspect 240/160.
        let gbaP = EmulatorLayoutGeometry.screenFrame(
            deviceSize: Self.proPortrait, safeInsets: insets, hasTouchScreen: false,
            isLandscape: false, gameAspect: 240.0 / 160.0, system: .gba, controllerConnected: false, deviceScale: 1)
        #expect(approx(gbaP.minX, 0) && approx(gbaP.minY, 42))
        #expect(approx(gbaP.width, 393) && approx(gbaP.height, 262))

        // GBA landscape shares the GB/GBC width (170pt panels) with GBA's own 3:2 height, and is
        // vertically centered: width = (512/1.5)·(160/144) ≈ 379.3 (= the GB/GBC width),
        // height = width/1.5 ≈ 252.8, x = 170 + (512−379.3)/2 ≈ 236.4, y = (393−252.8)/2 ≈ 70.1.
        let gbaL = EmulatorLayoutGeometry.screenFrame(
            deviceSize: Self.proLandscape, safeInsets: insets, hasTouchScreen: false,
            isLandscape: true, gameAspect: 240.0 / 160.0, system: .gba, controllerConnected: false, deviceScale: 1)
        #expect(approx(gbaL.minX, 236.4) && approx(gbaL.width, 379.3))
        #expect(approx(gbaL.height, 252.8) && approx(gbaL.minY, 70.1))

        // NDS portrait: 280pt controls reserve, aspect 256/384.
        let ndsP = EmulatorLayoutGeometry.screenFrame(
            deviceSize: Self.proPortrait, safeInsets: insets, hasTouchScreen: true,
            isLandscape: false, gameAspect: 256.0 / 384.0, system: .nds, controllerConnected: false, deviceScale: 1)
        #expect(approx(ndsP.minY, 0) && approx(ndsP.height, 572))
        #expect(approx(ndsP.width, 381.33) && approx(ndsP.minX, 5.83))

        // NDS landscape: screens fill 60% of the height, full width.
        let ndsL = EmulatorLayoutGeometry.screenFrame(
            deviceSize: Self.proLandscape, safeInsets: insets, hasTouchScreen: true,
            isLandscape: true, gameAspect: 256.0 / 384.0, system: .nds, controllerConnected: false, deviceScale: 1)
        #expect(approx(ndsL.minX, 0) && approx(ndsL.minY, 0))
        #expect(approx(ndsL.width, 852) && approx(ndsL.height, 235.8))
    }

    // MARK: - No control overlap on the smallest device (the bug under test)

    /// Rect of every default-laid-out button within its controls container, the
    /// same way `TouchControlsView.applyLayout` positions them: normalized center *
    /// container, device-scaled size, plus the NDS-landscape L/R gutter fit (so the
    /// test sees exactly what renders, not the pre-fit defaults).
    private func buttonRects(system: PresetSystem, isLandscape: Bool, deviceSize: CGSize,
                             safeLeftInset: CGFloat = 0) -> [ControlElement: CGRect] {
        let k = EmulatorLayoutGeometry.deviceScale(for: deviceSize)
        let isNDS = (system == .nds)
        let gameAspect = Self.displayAspect(system)
        let metal = EmulatorLayoutGeometry.screenFrame(
            deviceSize: deviceSize, safeInsets: .zero, hasTouchScreen: isNDS,
            isLandscape: isLandscape, gameAspect: gameAspect, system: system,
            controllerConnected: false, deviceScale: k)
        let container = EmulatorLayoutGeometry.controlsFrame(
            deviceSize: deviceSize, screenFrame: metal, hasTouchScreen: isNDS, isLandscape: isLandscape)
        let layout = ControlLayoutDefaults.defaultLayout(
            system: system, isLandscape: isLandscape, containerSize: container.size, scale: k,
            safeLeftInset: safeLeftInset)

        var rects: [ControlElement: CGRect] = [:]
        let elements = ControlElement.elements(for: system)
        for e in elements {
            guard let bl = layout.buttons[e.rawValue] else { continue }
            let baseSize = EmulatorLayoutGeometry.buttonSize(e, isNDS: isNDS, isLandscape: isLandscape, deviceScale: k)
            let adj = EmulatorLayoutGeometry.ndsLandscapeAdjusted(
                element: e, isNDS: isNDS, isLandscape: isLandscape,
                center: CGPoint(x: container.size.width * bl.centerX, y: container.size.height * bl.centerY),
                size: baseSize, container: container.size, layout: layout, deviceScale: k)
            rects[e] = CGRect(x: adj.center.x - adj.size.width / 2, y: adj.center.y - adj.size.height / 2,
                              width: adj.size.width, height: adj.size.height)
        }
        return rects
    }

    /// A button's real touch shape: the round face buttons (and Menu) are circles,
    /// everything else is its rectangle. Treating circles as their bounding squares
    /// reports phantom corner overlaps for the diamond-arranged A/B/X/Y — the false
    /// positives that made the old test "too strict and not reflect reality".
    private enum ButtonShape {
        case circle(center: CGPoint, radius: CGFloat)
        case rect(CGRect)
    }

    private func shape(_ e: ControlElement, _ r: CGRect) -> ButtonShape {
        switch e {
        case .btnA, .btnB, .btnX, .btnY, .btnMenu:
            return .circle(center: CGPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2)
        default:
            return .rect(r)
        }
    }

    /// Penetration depth between two shapes; > 0 means they actually overlap.
    private func penetration(_ a: ButtonShape, _ b: ButtonShape) -> CGFloat {
        func dist(_ p: CGPoint, _ q: CGPoint) -> CGFloat {
            let dx = Double(p.x - q.x), dy = Double(p.y - q.y)
            return CGFloat((dx * dx + dy * dy).squareRoot())
        }
        switch (a, b) {
        case let (.circle(c1, r1), .circle(c2, r2)):
            return (r1 + r2) - dist(c1, c2)
        case let (.circle(c, r), .rect(rect)), let (.rect(rect), .circle(c, r)):
            let nx = max(rect.minX, min(c.x, rect.maxX))
            let ny = max(rect.minY, min(c.y, rect.maxY))
            return r - dist(c, CGPoint(x: nx, y: ny))
        case let (.rect(r1), .rect(r2)):
            let inter = r1.intersection(r2)
            return inter.isNull ? -1 : min(inter.width, inter.height)
        }
    }

    @Test func controlsDoNotOverlapOniPhoneSE() {
        let configs: [(system: PresetSystem, landscape: Bool, size: CGSize)] = [
            (.gba, false, Self.sePortrait),
            (.gba, true, Self.seLandscape),
            (.gbc, false, Self.sePortrait),
            (.gbc, true, Self.seLandscape),
            (.nds, false, Self.sePortrait),
            (.nds, true, Self.seLandscape),
        ]

        for cfg in configs {
            let rects = buttonRects(system: cfg.system, isLandscape: cfg.landscape, deviceSize: cfg.size)
            let elements = Array(rects.keys)
            for i in 0..<elements.count {
                for j in (i + 1)..<elements.count {
                    let e1 = elements[i], e2 = elements[j]
                    let depth = penetration(shape(e1, rects[e1]!), shape(e2, rects[e2]!))
                    // After the NDS-landscape gutter fit, nothing overlaps on any
                    // device: the bottom row (SELECT·CLIP·START, ×k offsets) with Mic
                    // pulled to the bottom-right corner, plus the centered Menu line,
                    // are all spaced to clear on the SE by construction. GB/GBC reuse
                    // the GBA positions minus L/R, so they clear by construction too.
                    #expect(depth < 0.5,
                            "\(cfg.system) \(cfg.landscape ? "landscape" : "portrait"): \(e1.rawValue) overlaps \(e2.rawValue) by \(depth)pt")
                }
            }
        }
    }

    // MARK: - Controls never cover the NDS screens (the L/R-on-touch-screen bug)

    @Test func controlsDoNotCoverTheNDSScreensInLandscape() {
        let size = Self.seLandscape
        let k = EmulatorLayoutGeometry.deviceScale(for: size)
        let metal = EmulatorLayoutGeometry.screenFrame(
            deviceSize: size, safeInsets: .zero, hasTouchScreen: true, isLandscape: true,
            gameAspect: 256.0 / 384.0, system: .nds, controllerConnected: false, deviceScale: k)
        let container = EmulatorLayoutGeometry.controlsFrame(
            deviceSize: size, screenFrame: metal, hasTouchScreen: true, isLandscape: true)
        let screens = EmulatorLayoutGeometry.ndsLandscapeScreenRects(controlsContainer: container.size)
        let rects = buttonRects(system: .nds, isLandscape: true, deviceSize: size)

        // Both rect spaces share the controls-container origin: the screen band is
        // the area with negative y, where only the L/R bars reach.
        for (e, r) in rects {
            for (label, screen) in [("touch", screens.touch), ("top", screens.left)] {
                let inter = r.intersection(screen)
                #expect(inter.isNull || inter.width < 0.5 || inter.height < 0.5,
                        "NDS landscape: \(e.rawValue) covers the \(label) screen by \(inter)")
            }
        }
    }

    // MARK: - Clip button (the in-game share shortcut, a first-class control)

    /// The clip button must be positioned in every default layout (GBA/NDS x
    /// portrait/landscape). Its non-overlap on the iPhone SE is already covered by
    /// `controlsDoNotOverlapOniPhoneSE`, which iterates every element including it.
    @Test func clipButtonHasADefaultPositionInEveryLayout() {
        let container = CGSize(width: 393, height: 500)
        let configs: [(system: PresetSystem, landscape: Bool)] = [
            (.gba, false), (.gba, true), (.gbc, false), (.gbc, true), (.nds, false), (.nds, true),
        ]
        for cfg in configs {
            let layout = ControlLayoutDefaults.defaultLayout(
                system: cfg.system, isLandscape: cfg.landscape, containerSize: container, scale: 1)
            #expect(layout.buttons[ControlElement.btnClip.rawValue] != nil,
                    "\(cfg.system) \(cfg.landscape ? "landscape" : "portrait"): clip button missing from default layout")
        }
    }

    // MARK: - GB/GBC as a distinct system (separate screen + no shoulder buttons)

    /// GB/GBC screen geometry is self-contained — it has the correct 160×144 aspect,
    /// is horizontally centered, and is pinned to its current size on the reference
    /// device so a future GBA-screen change cannot silently move it (it no longer
    /// reads any GBA screen constant). Checked on the smallest and largest iPhones in
    /// both orientations, so the rule holds whether the screen is width- or height-bound.
    @Test func gbcScreenGeometryIsSelfContainedAndDecoupledFromGBA() {
        let gbcAspect: CGFloat = 160.0 / 144.0
        let cases: [(name: String, size: CGSize, landscape: Bool)] = [
            ("SE portrait", Self.sePortrait, false),
            ("SE landscape", Self.seLandscape, true),
            ("ProMax portrait", CGSize(width: 440, height: 956), false),
            ("ProMax landscape", CGSize(width: 956, height: 440), true),
        ]
        for c in cases {
            let k = EmulatorLayoutGeometry.deviceScale(for: c.size)
            let gbc = EmulatorLayoutGeometry.screenFrame(
                deviceSize: c.size, safeInsets: .zero, hasTouchScreen: false, isLandscape: c.landscape,
                gameAspect: Self.displayAspect(.gbc), system: .gbc, controllerConnected: false, deviceScale: k)
            #expect(approx(gbc.width, gbc.height * gbcAspect), "\(c.name): GBC width not height×(160/144)")
            #expect(approx(gbc.midX, c.size.width / 2), "\(c.name): GBC not horizontally centered")
            #expect(gbc.minX >= -0.5 && gbc.maxX <= c.size.width + 0.5, "\(c.name): GBC overflows the width")
        }

        // Regression lock for the current GB/GBC look on the 14 Pro reference device.
        // These values are independent of the GBA screen constants and must NOT move
        // when the GBA landscape/portrait geometry is retuned.
        let p = EmulatorLayoutGeometry.screenFrame(
            deviceSize: Self.proPortrait, safeInsets: .zero, hasTouchScreen: false, isLandscape: false,
            gameAspect: Self.displayAspect(.gbc), system: .gbc, controllerConnected: false, deviceScale: 1)
        #expect(approx(p.width, 291.1) && approx(p.height, 262))
        #expect(approx(p.minX, 50.9) && approx(p.minY, 42))

        let l = EmulatorLayoutGeometry.screenFrame(
            deviceSize: Self.proLandscape, safeInsets: .zero, hasTouchScreen: false, isLandscape: true,
            gameAspect: Self.displayAspect(.gbc), system: .gbc, controllerConnected: false, deviceScale: 1)
        #expect(approx(l.width, 379.3) && approx(l.height, 341.3))
        #expect(approx(l.minX, 236.4) && approx(l.minY, 0))
    }

    /// GB/GBC hardware has no L/R: the element set and the default layout omit them,
    /// while GBA keeps them. Everything else GBA has, GB/GBC keeps.
    @Test func gbcHasNoShoulderButtons() {
        #expect(!ControlElement.gbcElements.contains(.btnL))
        #expect(!ControlElement.gbcElements.contains(.btnR))
        #expect(ControlElement.gbaElements.contains(.btnL) && ControlElement.gbaElements.contains(.btnR))
        // GB/GBC = GBA minus exactly the two shoulder buttons.
        #expect(Set(ControlElement.gbcElements) == Set(ControlElement.gbaElements).subtracting([.btnL, .btnR]))

        let container = CGSize(width: 393, height: 500)
        for landscape in [false, true] {
            let gbc = ControlLayoutDefaults.defaultLayout(
                system: .gbc, isLandscape: landscape, containerSize: container, scale: 1)
            #expect(gbc.buttons[ControlElement.btnL.rawValue] == nil,
                    "GBC \(landscape ? "landscape" : "portrait"): L present in default layout")
            #expect(gbc.buttons[ControlElement.btnR.rawValue] == nil,
                    "GBC \(landscape ? "landscape" : "portrait"): R present in default layout")
            // The core face/system buttons are still there.
            for e in [ControlElement.dpad, .btnA, .btnB, .btnStart, .btnSelect, .btnMenu] {
                #expect(gbc.buttons[e.rawValue] != nil,
                        "GBC \(landscape ? "landscape" : "portrait"): \(e.rawValue) missing")
            }
        }
    }

    // MARK: - Landscape B button anchored to A's lower-left corner

    /// In landscape A and B are split around the bloc center: B's RIGHT edge meets A's LEFT
    /// edge, and B's top meets A's bottom (B parked off A's lower-left corner). GBA mirrors the
    /// GB/GBC landscape, so this holds identically for both (rendered rects on the 14 Pro).
    @Test func landscapeBButtonAnchorsToALowerLeftCorner() {
        for system in [PresetSystem.gba, .gbc] {
            let rects = buttonRects(system: system, isLandscape: true, deviceSize: Self.proLandscape)
            let a = rects[.btnA]!
            let b = rects[.btnB]!
            #expect(approx(b.maxX, a.minX), "\(system): B right edge \(b.maxX) != A left edge \(a.minX)")
            #expect(approx(b.minY, a.maxY), "\(system): B top \(b.minY) != A bottom \(a.maxY)")
        }
    }

    /// The landscape D-pad lives in the left side gutter and never overlays the game
    /// screen, on both GBA and GB/GBC. In landscape the controls container shares the
    /// device origin, so the D-pad's right edge can be compared to the screen's left.
    @Test func landscapeDpadDoesNotOverlayTheScreen() {
        let size = Self.proLandscape
        let k = EmulatorLayoutGeometry.deviceScale(for: size)
        for system in [PresetSystem.gba, .gbc] {
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: size, safeInsets: .zero, hasTouchScreen: false, isLandscape: true,
                gameAspect: Self.displayAspect(system), system: system, controllerConnected: false, deviceScale: k)
            let dpad = buttonRects(system: system, isLandscape: true, deviceSize: size)[.dpad]!
            #expect(dpad.maxX <= screen.minX + 0.5,
                    "\(system): D-pad right edge \(dpad.maxX) overlays screen left \(screen.minX)")
        }
    }

    /// In portrait the A/B pair is raised so the bloc's vertical center (the midpoint of A's
    /// and B's centers) aligns with the D-pad's center. GBA now mirrors the GB/GBC face-button
    /// positions, so this holds for BOTH systems.
    @Test func gbcPortraitABBlocIsVerticallyCenteredOnDpad() {
        for system in [PresetSystem.gbc, .gba] {
            let r = buttonRects(system: system, isLandscape: false, deviceSize: Self.proPortrait)
            let bloc = (r[.btnA]!.midY + r[.btnB]!.midY) / 2
            #expect(approx(bloc, r[.dpad]!.midY),
                    "\(system) portrait: A/B bloc center \(bloc) != D-pad center \(r[.dpad]!.midY)")
        }
    }

    /// GB/GBC landscape: the D-pad is centered in the left gutter, and A/B split around
    /// their current bloc center (B's right edge meets A's left edge on it), so both face
    /// buttons sit in the right gutter clear of the screen.
    @Test func gbcLandscapeDpadGutterCenteredAndABSplit() {
        let size = Self.proLandscape
        let k = EmulatorLayoutGeometry.deviceScale(for: size)
        let screen = EmulatorLayoutGeometry.screenFrame(
            deviceSize: size, safeInsets: .zero, hasTouchScreen: false, isLandscape: true,
            gameAspect: Self.displayAspect(.gbc), system: .gbc, controllerConnected: false, deviceScale: k)
        let rects = buttonRects(system: .gbc, isLandscape: true, deviceSize: size)
        let dpad = rects[.dpad]!, a = rects[.btnA]!, b = rects[.btnB]!

        // D-pad centered in the left gutter (device edge → screen left).
        // Centered against the dressed surround edge (screen.minX − dress frame), not the
        // raw screen, so the D-pad clears the GB/GBC dress. (deviceScale == 1 here.)
        let dressFrame: CGFloat = 14
        #expect(approx(dpad.midX, (screen.minX - dressFrame) / 2),
                "GBC landscape: D-pad center \(dpad.midX) != left-gutter center")

        // A and B meet at the split line; A sits to the right of B.
        #expect(approx(b.maxX, a.minX), "GBC landscape: B right \(b.maxX) != A left \(a.minX)")
        #expect(a.midX > b.midX, "GBC landscape: A should sit right of B")
        // (The split line equals the inherited A/B bloc center; GBA now mirrors GB/GBC, so it is
        // no longer an independent reference and that sub-check was removed.)

        // Both face buttons clear the game screen (they sit in the right gutter).
        #expect(b.minX >= screen.maxX - 0.5 && a.minX >= screen.maxX - 0.5,
                "GBC landscape: A/B should sit in the right gutter, clear of the screen")
    }

    /// With a Dynamic Island on the leading edge (landscape), the GB/GBC D-pad is
    /// centered in the SAFE gutter, so it clears the island AND the screen. With no
    /// island (inset 0) it falls back to the full-gutter center (covered above).
    @Test func gbcLandscapeDpadClearsTheDynamicIsland() {
        let size = Self.proLandscape
        let k = EmulatorLayoutGeometry.deviceScale(for: size)
        let island: CGFloat = 59   // leading safe-area inset on a 14/15/16 Pro-class device
        let screen = EmulatorLayoutGeometry.screenFrame(
            deviceSize: size, safeInsets: .zero, hasTouchScreen: false, isLandscape: true,
            gameAspect: Self.displayAspect(.gbc), system: .gbc, controllerConnected: false, deviceScale: k)
        let dpad = buttonRects(system: .gbc, isLandscape: true, deviceSize: size,
                               safeLeftInset: island)[.dpad]!

        // Centered in [island, screen.left], and fully inside that safe gutter.
        let dressFrame: CGFloat = 14   // matches the dress surround frame (deviceScale 1)
        #expect(approx(dpad.midX, (island + screen.minX - dressFrame) / 2),
                "GBC landscape: D-pad center \(dpad.midX) != safe-gutter center")
        #expect(dpad.minX >= island - 0.5, "GBC landscape: D-pad \(dpad.minX) under the island \(island)")
        #expect(dpad.maxX <= screen.minX + 0.5, "GBC landscape: D-pad \(dpad.maxX) overlaps screen \(screen.minX)")
    }

    /// GB/GBC landscape: the clip button sits in the top-right gutter — vertically centered
    /// between the top of the screen (y = 0) and the top of the A button, horizontally
    /// centered between the dress surround's right edge and the right edge of the screen —
    /// above A and clear of the game screen.
    @Test func gbcLandscapeClipInTopRightGutter() {
        let size = Self.proLandscape
        let k = EmulatorLayoutGeometry.deviceScale(for: size)   // 1 on the reference device
        let screen = EmulatorLayoutGeometry.screenFrame(
            deviceSize: size, safeInsets: .zero, hasTouchScreen: false, isLandscape: true,
            gameAspect: Self.displayAspect(.gbc), system: .gbc, controllerConnected: false, deviceScale: k)
        let rects = buttonRects(system: .gbc, isLandscape: true, deviceSize: size)
        let clip = rects[.btnClip]!, a = rects[.btnA]!

        let dressFrame: CGFloat = 14   // matches the dress surround frame (deviceScale 1)
        let surroundRight = screen.maxX + dressFrame

        // Horizontally centered between the surround's right edge and the screen's right edge.
        #expect(approx(clip.midX, (surroundRight + size.width) / 2),
                "GBC landscape: clip center \(clip.midX) != right-gutter center")
        // Vertically centered between the top of the screen (0) and the top of A.
        #expect(approx(clip.midY, a.minY / 2),
                "GBC landscape: clip center \(clip.midY) != midpoint of [0, A.top \(a.minY)]")
        // Sits above A and clear of the game screen (it lives in the right gutter).
        #expect(clip.maxY <= a.minY + 0.5, "GBC landscape: clip \(clip.maxY) should sit above A \(a.minY)")
        #expect(clip.minX >= screen.maxX - 0.5, "GBC landscape: clip \(clip.minX) should clear the screen \(screen.maxX)")
    }
}
