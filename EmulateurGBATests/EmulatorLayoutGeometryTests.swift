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

/// A button's real touch shape: the round face buttons (and Menu) are circles, everything else
/// is its rectangle. Treating circles as their bounding squares reports phantom corner overlaps
/// for the diamond-arranged A/B/X/Y — the false positives that made the old test "too strict and
/// not reflect reality". At file scope so both suites below measure overlap the same way.
enum ButtonShape {
    case circle(center: CGPoint, radius: CGFloat)
    case rect(CGRect)

    static func of(_ e: ControlElement, _ r: CGRect) -> ButtonShape {
        switch e {
        case .btnA, .btnB, .btnX, .btnY, .btnMenu:
            return .circle(center: CGPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2)
        default:
            return .rect(r)
        }
    }

    /// Penetration depth between two shapes; > 0 means they actually overlap.
    static func penetration(_ a: ButtonShape, _ b: ButtonShape) -> CGFloat {
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
}

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
        case .snes: return 8.0 / 7.0
        case .nes: return 248.0 / 240.0
        case .ps1: return 4.0 / 3.0
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
        // A jumbo PHONE window (short side under the tablet threshold) clamps at the phone
        // ceiling; a jumbo TABLET window clamps at the tablet family's own (2026-09-05).
        #expect(EmulatorLayoutGeometry.deviceScale(for: CGSize(width: 599, height: 3000))
                == EmulatorLayoutGeometry.maxDeviceScale)
        #expect(EmulatorLayoutGeometry.deviceScale(for: CGSize(width: 2000, height: 3000))
                == EmulatorLayoutGeometry.tabletMaxDeviceScale)
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
            let baseSize = EmulatorLayoutGeometry.buttonSize(e, system: system, isLandscape: isLandscape, deviceScale: k)
            let adj = EmulatorLayoutGeometry.ndsLandscapeAdjusted(
                element: e, isNDS: isNDS, isLandscape: isLandscape,
                center: CGPoint(x: container.size.width * bl.centerX, y: container.size.height * bl.centerY),
                size: baseSize, container: container.size, layout: layout, deviceScale: k)
            rects[e] = CGRect(x: adj.center.x - adj.size.width / 2, y: adj.center.y - adj.size.height / 2,
                              width: adj.size.width, height: adj.size.height)
        }
        return rects
    }

    @Test func controlsDoNotOverlapOniPhoneSE() {
        // Every console on every iPhone size, both orientations. It was the SE
        // alone when the SE was the only device that had produced an overlap;
        // the SNES arrives with a four-button diamond where there were two
        // buttons, so the question is now worth asking everywhere. The smallest
        // device is still the one that fails first, which is why it stays named
        // in the test's title.
        let sizes: [(String, CGSize, CGSize)] = [
            ("iPhone SE", Self.sePortrait, Self.seLandscape),
            ("iPhone 14 Pro", Self.proPortrait, Self.proLandscape),
            ("iPhone 16 Pro Max", CGSize(width: 440, height: 956), CGSize(width: 956, height: 440)),
        ]
        var configs: [(system: PresetSystem, landscape: Bool, size: CGSize)] = []
        for system in [PresetSystem.gba, .gbc, .nds, .snes, .nes] {
            for (_, portrait, landscape) in sizes {
                configs.append((system, false, portrait))
                configs.append((system, true, landscape))
            }
        }

        for cfg in configs {
            let rects = buttonRects(system: cfg.system, isLandscape: cfg.landscape, deviceSize: cfg.size)
            let elements = Array(rects.keys)
            for i in 0..<elements.count {
                for j in (i + 1)..<elements.count {
                    let e1 = elements[i], e2 = elements[j]
                    let depth = ButtonShape.penetration(ButtonShape.of(e1, rects[e1]!),
                                                        ButtonShape.of(e2, rects[e2]!))
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

    // MARK: - Controller layout (1.2.5)

    /// The zero-regression lock for the controller-connected layout feature.
    ///
    /// A pristine `ControllerLayout` (nothing customised) must resolve to
    /// EXACTLY the geometry the app renders today with a controller attached,
    /// on every supported device, for every system and both orientations. If
    /// this passes, shipping the feature cannot change anything for a player
    /// who never opens it — which is the entire safety argument.
    @Test func pristineControllerLayoutMatchesTodaysGeometry() {
        let devices: [(String, CGSize, Bool)] = [
            ("14 Pro portrait", Self.proPortrait, false),
            ("14 Pro landscape", Self.proLandscape, true),
            ("SE portrait", Self.sePortrait, false),
            ("SE landscape", Self.seLandscape, true),
            ("Pro Max portrait", CGSize(width: 440, height: 956), false),
            ("Pro Max landscape", CGSize(width: 956, height: 440), true),
        ]
        let pristine = ControllerLayout()

        for (label, size, isLandscape) in devices {
            for system in [PresetSystem.gba, .gbc, .nds, .snes, .nes, .ps1] {
                let expected = EmulatorLayoutGeometry.screenFrame(
                    deviceSize: size, safeInsets: .zero,
                    hasTouchScreen: system == .nds, isLandscape: isLandscape,
                    gameAspect: Self.displayAspect(system), system: system,
                    controllerConnected: true,
                    deviceScale: EmulatorLayoutGeometry.deviceScale(for: size))

                let scene = PresetLayoutResolver.resolveController(
                    layout: pristine, system: system, isLandscape: isLandscape,
                    viewSize: size, safeInsets: .zero)

                if system == .nds {
                    let (top, bottom) = PresetLayoutResolver.ndsDefaultScreenRects(
                        in: expected, isLandscape: isLandscape)
                    #expect(scene.screens[.top]?.frame == top,
                            "\(label) \(system): top screen drifted from today's geometry")
                    #expect(scene.screens[.bottom]?.frame == bottom,
                            "\(label) \(system): bottom screen drifted from today's geometry")
                } else {
                    #expect(scene.screens[.main]?.frame == expected,
                            "\(label) \(system): screen drifted from today's geometry")
                }

                // Menu is the only control, always present, never hidden, and
                // rendered at EXACTLY its default size. Asserting the size is
                // what catches a floor that inflates a deliberately small Menu
                // (NDS's reference is 36, not 44) and thereby silently changes
                // the default layout.
                let menu = scene.buttons[.btnMenu]
                #expect(menu != nil, "\(label) \(system): Menu missing from the controller scene")
                #expect(menu?.isHidden == false, "\(label) \(system): Menu must never be hidden")
                #expect(scene.buttons.count == 1,
                        "\(label) \(system): controller scene should carry Menu only")
                if let menu {
                    #expect(approx(menu.scale, 1, tol: 0.0001),
                            "\(label) \(system): pristine Menu scale \(menu.scale) != 1")
                    let expectedMenu = EmulatorLayoutGeometry.buttonSize(
                        .btnMenu, isNDS: system == .nds, isLandscape: isLandscape,
                        deviceScale: EmulatorLayoutGeometry.deviceScale(for: size))
                    #expect(approx(menu.baseSize.width, expectedMenu.width)
                            && approx(menu.baseSize.height, expectedMenu.height),
                            "\(label) \(system): Menu size \(menu.baseSize) != engine \(expectedMenu)")
                }
            }
        }
    }

    /// Menu may be shrunk by the user, but never below a comfortable tap target:
    /// with a controller attached it is the only on-screen way back to the pause
    /// menu, so an over-shrunk Menu would strand the player.
    @Test func controllerMenuNeverShrinksBelowTheTapFloor() {
        var layout = ControllerLayout()
        for isLandscape in [false, true] {
            var o = OrientationLayout(space: OrientationLayout.fullViewSpace)
            o.buttons[ControlElement.btnMenu.rawValue] = ButtonLayout(
                centerX: 0.5, centerY: 0.5, isHidden: true, scale: 0.05, opacity: 1)
            layout.setLayout(o, isLandscape: isLandscape)
        }

        for (size, isLandscape) in [(Self.proPortrait, false), (Self.sePortrait, false),
                                    (Self.proLandscape, true), (Self.seLandscape, true)] {
            for system in [PresetSystem.gba, .gbc, .nds, .snes, .nes, .ps1] {
                let scene = PresetLayoutResolver.resolveController(
                    layout: layout, system: system, isLandscape: isLandscape,
                    viewSize: size, safeInsets: .zero)
                guard let menu = scene.buttons[.btnMenu] else {
                    Issue.record("Menu missing"); continue
                }
                #expect(menu.isHidden == false,
                        "a stored isHidden must never lock the player out")
                let w = menu.baseSize.width * menu.scale
                let h = menu.baseSize.height * menu.scale
                // Floor per axis is min(44, that axis's own base), matching the
                // engine, so an intentionally small Menu is not inflated.
                let floorW = min(PresetLayoutResolver.minControllerMenuDimension, menu.baseSize.width)
                let floorH = min(PresetLayoutResolver.minControllerMenuDimension, menu.baseSize.height)
                #expect(w >= floorW - 0.5, "\(system) menu width \(w) below its floor \(floorW)")
                #expect(h >= floorH - 0.5, "\(system) menu height \(h) below its floor \(floorH)")
            }
        }
    }

    /// Seeding must be the identity: opening the editor puts the player on
    /// exactly what they already see, so "customise" never starts by moving
    /// something.
    @Test func seededControllerLayoutResolvesToTheDefault() {
        // Each case names BOTH viewports, because seeding does: the landscape half
        // of a seed measured in a portrait box would resolve to a different place
        // on the first rotation, which is exactly what the four-argument signature
        // now makes impossible to express.
        let cases: [(size: CGSize, isLandscape: Bool, portrait: CGSize, landscape: CGSize)] = [
            (Self.proPortrait, false, Self.proPortrait, Self.proLandscape),
            (Self.seLandscape, true, Self.sePortrait, Self.seLandscape),
        ]
        for (size, isLandscape, portrait, landscape) in cases {
            for system in [PresetSystem.gba, .gbc, .nds, .snes, .nes, .ps1] {
                let seeded = PresetLayoutResolver.seededControllerLayout(
                    system: system,
                    portraitSize: portrait, portraitInsets: .zero,
                    landscapeSize: landscape, landscapeInsets: .zero)
                let fromSeed = PresetLayoutResolver.resolveController(
                    layout: seeded, system: system, isLandscape: isLandscape,
                    viewSize: size, safeInsets: .zero)
                let fromPristine = PresetLayoutResolver.resolveController(
                    layout: ControllerLayout(), system: system, isLandscape: isLandscape,
                    viewSize: size, safeInsets: .zero)

                for component in ScreenComponent.components(for: system) {
                    let a = fromSeed.screens[component]?.frame ?? .zero
                    let b = fromPristine.screens[component]?.frame ?? .zero
                    #expect(approx(a.midX, b.midX) && approx(a.midY, b.midY)
                            && approx(a.width, b.width) && approx(a.height, b.height),
                            "\(system) \(component): seeded screen \(a) != default \(b)")
                }
                let a = fromSeed.buttons[.btnMenu]!.center
                let b = fromPristine.buttons[.btnMenu]!.center
                #expect(approx(a.x, b.x) && approx(a.y, b.y),
                        "\(system): seeded Menu \(a) != default \(b)")
            }
        }
    }
}


// MARK: - The 1.2.5 consoles

/// The SNES and NES layouts are compositions rather than new geometry: the SNES is
/// the GBA layout with a four-button diamond in place of its two face buttons, and
/// the NES is the Game Boy layout unchanged. These tests hold that shape, and hold
/// the promise that adding them moved nothing for the consoles already shipped.
struct SNESAndNESLayoutTests {

    private static let devices: [(String, CGSize, Bool)] = [
        ("14 Pro portrait", CGSize(width: 393, height: 852), false),
        ("14 Pro landscape", CGSize(width: 852, height: 393), true),
        ("SE portrait", CGSize(width: 375, height: 667), false),
        ("SE landscape", CGSize(width: 667, height: 375), true),
        ("Pro Max portrait", CGSize(width: 440, height: 956), false),
        ("Pro Max landscape", CGSize(width: 956, height: 440), true),
    ]

    private func container(_ size: CGSize, _ isLandscape: Bool, _ system: PresetSystem) -> CGSize {
        let k = EmulatorLayoutGeometry.deviceScale(for: size)
        let frame = EmulatorLayoutGeometry.screenFrame(
            deviceSize: size, safeInsets: .zero, hasTouchScreen: false,
            isLandscape: isLandscape, gameAspect: EmulatorLayoutGeometryTests.displayAspect(system), system: system,
            controllerConnected: false, deviceScale: k)
        return EmulatorLayoutGeometry.controlsFrame(
            deviceSize: size, screenFrame: frame,
            hasTouchScreen: false, isLandscape: isLandscape).size
    }

    /// The NES pad IS the Game Boy pad, so its layout must be the Game Boy's — except where this
    /// console's own picture makes that impossible, and those exceptions are named here.
    ///
    /// It pairs that layout with a TALLER screen (31:30 against the Game Boy's squarer shape), so
    /// its controls container is shorter than the layout was tuned for. Three controls therefore
    /// move and only three: MENU and CLIP, and in landscape the SELECT · MENU · START row.
    /// Everything else must still be value for value, or it is a copy that drifted rather than a
    /// decision.
    ///
    /// NEITHER MOVE IS A CLAMP ANY MORE, and that is what this test used to get wrong. Both are
    /// outright placements into a band, so either can land BELOW where the Game Boy put it, and
    /// on a 14 Pro and a Pro Max MENU does. It was written against the two clamps that placement
    /// replaced on 2026-08-17, kept asserting that a clamp only ever lifts, and has failed on
    /// those two devices ever since -- through the 1.2.5 submission. What each band is measured
    /// against is asserted where the band is: `theNESUtilityRowSitsBetweenThePanelAndTheFaceWell`
    /// for portrait, with the real safe-area insets that band depends on, and the landscape strip
    /// below. Here we hold what both moves share -- only these three controls move, none of them
    /// sideways, and MENU and CLIP land on ONE line.
    @Test func nesLayoutIsTheGameBoyLayout() {
        for (label, size, isLandscape) in Self.devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .nes)
            let nes = ControlLayoutDefaults.defaultLayout(
                system: .nes, isLandscape: isLandscape, containerSize: c, scale: k)
            let gbc = ControlLayoutDefaults.defaultLayout(
                system: .gbc, isLandscape: isLandscape, containerSize: c, scale: k)
            let row = [ControlElement.btnSelect.rawValue, ControlElement.btnMenu.rawValue,
                       ControlElement.btnStart.rawValue]
            let mayMove: Set<String> = isLandscape
                ? Set(row)
                : [ControlElement.btnClip.rawValue, ControlElement.btnMenu.rawValue]
            for (key, value) in gbc.buttons where !mayMove.contains(key) {
                #expect(nes.buttons[key] == value,
                        "\(label): the NES layout drifted from the Game Boy's at \(key)")
            }
            // Neither the clamps nor the re-stick touch x.
            for key in mayMove {
                guard let n = nes.buttons[key], let g = gbc.buttons[key] else { continue }
                #expect(abs(n.centerX - g.centerX) < 0.0001,
                        "\(label): \(key) moved sideways, which nothing here does")
            }
            if isLandscape {
                // One row, centred between the bottom of the picture and the top of the home
                // indicator (the same flat reserve the screen frame counts).
                let screen = EmulatorLayoutGeometry.screenFrame(
                    deviceSize: c, safeInsets: .zero, hasTouchScreen: false, isLandscape: true,
                    gameAspect: EmulatorLayoutGeometryTests.displayAspect(.nes), system: .nes,
                    controllerConnected: false, deviceScale: k)
                let want = (screen.maxY + c.height
                            - EmulatorLayoutGeometry.snesLandscapeIndicatorReserve) / 2 / c.height
                for key in row {
                    guard let n = nes.buttons[key] else { continue }
                    #expect(abs(n.centerY - want) < 0.0001,
                            "\(label): \(key) is not centred in the strip under the picture")
                }
            } else {
                // MENU and CLIP share one line: they are placed together, centred in the band
                // the dress leaves between the screen panel and the A/B well. WHERE that line
                // falls is `theNESUtilityRowSitsBetweenThePanelAndTheFaceWell`'s business,
                // because the band moves with the safe-area insets and this sweep passes none.
                guard let menu = nes.buttons[ControlElement.btnMenu.rawValue],
                      let clip = nes.buttons[ControlElement.btnClip.rawValue] else { continue }
                #expect(abs(menu.centerY - clip.centerY) < 0.0001,
                        "\(label): MENU and CLIP are not on one line")
            }
        }
    }

    /// Four face buttons around a centre: A on the right, Y on the left, X above B.
    ///
    /// ONLY the ordering is asserted here, and on both pages. It is the promise that a
    /// mirrored pad would break, and mirroring is invisible in code and obvious in the hand.
    ///
    /// The exact geometry is deliberately NOT here, because it differs per page and neither
    /// page is a symmetric diamond any more. Portrait was one until the two pairs stepped apart
    /// so the dress's capsules would stop overlapping, which moved X and B off a shared column
    /// by 7pt; landscape never was, since the DS's own four are a staggered 2×2. What each page
    /// really promises is that the arrangement is still the DS's, and `snesPadIsTheDSPad` is
    /// where that is measured.
    @Test func snesFaceButtonsFormADiamond() {
        for (label, size, isLandscape) in Self.devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .snes)
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .snes, isLandscape: isLandscape, containerSize: c, scale: k)

            guard let a = layout.buttons[ControlElement.btnA.rawValue],
                  let b = layout.buttons[ControlElement.btnB.rawValue],
                  let x = layout.buttons[ControlElement.btnX.rawValue],
                  let y = layout.buttons[ControlElement.btnY.rawValue] else {
                Issue.record("\(label): the SNES layout is missing a face button")
                return
            }
            #expect(a.centerX > x.centerX, "\(label): A must sit right of the X/B column")
            #expect(y.centerX < x.centerX, "\(label): Y must sit left of the X/B column")
            #expect(x.centerY < b.centerY, "\(label): X must sit above B")
        }
    }

    /// The pad comes from the DS: same D-pad, same four faces, same sizes on both pages.
    ///
    /// In PORTRAIT it is the DS's positions outright, because the page is the same shape:
    /// screen at the top, everything below it for the controls.
    ///
    /// LANDSCAPE is a different page — one panel in the middle, a gutter each side, and the
    /// controls drawn OVER it — while the DS's landscape positions assume its own (screens
    /// above, controls below, full width). Taken literally they put the D-pad 22pt into the
    /// picture with X and Y on top of it. So what carries over there is the ARRANGEMENT and
    /// not the coordinates: the four faces move into the right gutter as ONE block, which is
    /// why each of them must carry the same shift and none may change line, and the D-pad is
    /// centred in the left gutter, which is the Game Boy's rule on this page.
    // MARK: - PlayStation

    /// THE PLAYSTATION PORTRAIT PAGE IS SYMMETRIC ABOUT ITS TWO THUMB BLOCKS.
    ///
    /// This REPLACES an older claim, that the page was the Super Nintendo's with
    /// three exceptions. It still starts there — `ps1()` composes from `snes()` —
    /// but it no longer ends there: the cross rises to stand on its up key, the
    /// diamond slides right to mirror the cross's margin, and the shoulder row,
    /// the sticks and the bottom row are all placed from those two. Asserting
    /// identical coordinates had stopped describing anything, so what is locked
    /// here instead is the symmetry those moves exist to produce.
    ///
    /// Landscape is unchanged and keeps the only claim that was ever true of it:
    /// every shared control is still on the page, wherever its gutter put it.
    @Test func ps1PortraitMirrorsItsTwoThumbBlocks() {
        for (label, size, isLandscape) in Self.devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .ps1)
            let ps1 = ControlLayoutDefaults.defaultLayout(
                system: .ps1, isLandscape: isLandscape, containerSize: c, scale: k)

            for element in ControlElement.snesElements {
                #expect(ps1.buttons[element.rawValue] != nil,
                        "\(label): \(element.rawValue) was lost")
            }
            #expect(ps1.buttons[ControlElement.btnL2.rawValue] != nil,
                    "\(label): L2 was never placed")
            #expect(ps1.buttons[ControlElement.btnR2.rawValue] != nil,
                    "\(label): R2 was never placed")
            guard !isLandscape else { continue }

            func rect(_ element: ControlElement) -> CGRect? {
                guard let b = ps1.buttons[element.rawValue] else { return nil }
                let s = EmulatorLayoutGeometry.buttonSize(element, system: .ps1,
                                                         isLandscape: false, deviceScale: k)
                return CGRect(x: b.centerX * c.width - s.width / 2,
                              y: b.centerY * c.height - s.height / 2,
                              width: s.width, height: s.height)
            }
            guard let pad = rect(.dpad) else {
                Issue.record("\(label): the cross was never placed"); continue
            }
            let faces = [ControlElement.btnA, .btnB, .btnX, .btnY].compactMap { rect($0) }
            guard faces.count == 4,
                  let left = faces.map(\.minX).min(), let right = faces.map(\.maxX).max(),
                  let top = faces.map(\.minY).min(), let low = faces.map(\.maxY).max() else {
                Issue.record("\(label): the diamond was never placed"); continue
            }

            // 1. EQUAL MARGINS. The cross's distance from the left edge is the
            //    diamond's from the right. This is the move that had never been
            //    made: the two blocks arrive from different consoles and sat 12
            //    and 24 points from their own edges.
            #expect(abs(pad.minX - (c.width - right)) < 0.5,
                    Comment(rawValue: "\(label): the two thumb blocks no longer mirror each "
                                      + "other (cross \(pad.minX) from the left, diamond "
                                      + "\(c.width - right) from the right)"))

            // 2. ONE CENTRE LINE. The diamond's middle is the cross's middle.
            #expect(abs(pad.midY - (top + low) / 2) < 0.5,
                    "\(label): the diamond left the cross's centre line")

            // 3. THE CROSS STANDS ON ITS UP KEY. Its centre is where the middle
            //    of the up key reads, which is what a thumb aims at — the middle
            //    of the bounding box is a hole on this pad. Checked against the
            //    inherited placement, so this fails if the rise is dropped OR if
            //    it stops being derived from the shape the cross draws.
            let snes = ControlLayoutDefaults.defaultLayout(
                system: .snes, isLandscape: false, containerSize: c, scale: k)
            if let inherited = snes.buttons[ControlElement.dpad.rawValue] {
                let rise = CrossDPadView.ps1UpKeyMiddle * pad.height
                #expect(abs(pad.midY - (inherited.centerY * c.height - rise)) < 0.5,
                        "\(label): the cross is not standing on its up key")
            }

            // 4. THE STICKS SIT UNDER THEIR OWN BLOCK, stepped inward by half an
            //    arrow. Outward, or square under the centre, are both wrong and
            //    both easy to reach by editing one sign.
            let arrowHalf = pad.width * CrossDPadView.ps1ArmRatioShared / 2
            if let l = rect(.stickLeft), let r = rect(.stickRight) {
                #expect(abs(l.midX - (pad.midX + arrowHalf)) < 0.5,
                        "\(label): the left stick is not half an arrow inboard of the cross")
                #expect(abs(r.midX - ((left + right) / 2 - arrowHalf)) < 0.5,
                        "\(label): the right stick is not half an arrow inboard of the diamond")
                #expect(l.minY > max(pad.maxY, low) - 0.5,
                        "\(label): the sticks are not under the two blocks")
                #expect(abs(l.midY - r.midY) < 0.5,
                        "\(label): the two sticks left their shared line")
            }

            // 5. THE BOTTOM ROW IS ONE LINE — of MARKS, not of hitboxes.
            //
            //    SELECT and START hold a shape AND a word under it, centred as
            //    one block, so their shape rides above their hitbox's middle;
            //    CLIP's disc sits dead centre in its own. Lining up the three
            //    HITBOXES therefore leaves the three marks visibly staggered,
            //    which is what this used to assert. The two drop by their own
            //    rise instead, and what is level is what a player sees.
            //
            //    The direction also matters and is easy to reverse: CLIP takes
            //    the row SELECT and START arrive on, not the other way round.
            if let clip = rect(.btnClip), let sel = rect(.btnSelect), let st = rect(.btnStart) {
                let selRise = SmallButton.PS1Shape.shapeRise(.ps1Rect, sel)
                let stRise = SmallButton.PS1Shape.shapeRise(.ps1Triangle, st)
                #expect(abs((sel.midY - selRise) - clip.midY) < 0.5,
                        "\(label): SELECT's mark is not level with CLIP's")
                #expect(abs((st.midY - stRise) - clip.midY) < 0.5,
                        "\(label): START's mark is not level with CLIP's")
            }

            // 6. ANALOG IS BETWEEN THE STICKS, which is where the pad prints it.
            if let mode = rect(.btnMode), let l = rect(.stickLeft), let r = rect(.stickRight) {
                #expect(mode.minX > l.maxX - 0.5 && mode.maxX < r.minX + 0.5,
                        "\(label): ANALOG is not between the two sticks")
                // On the sticks' TOP edge, not their centre line: level with
                // where they begin it reads as the label over the pair rather
                // than as a third control in a row of three.
                #expect(abs(mode.midY - l.minY) < 0.5,
                        "\(label): ANALOG left the sticks' top edge")
                // And the half of it that reaches above that edge must still
                // clear the cross, which claims its whole frame past a small
                // deadzone. This is what the blocks-to-sticks gap is sized for.
                #expect(mode.minY > pad.maxY - 0.5,
                        "\(label): ANALOG reaches back up into the cross's hitbox")
            }

            // 7. THE SHOULDER ROW HOLDS ITS TOP EDGE while the bars thin. The
            //    edge that faces the picture is the one that must not move.
            if let l1 = rect(.btnL), let inherited = snes.buttons[ControlElement.btnL.rawValue] {
                let inheritedH = EmulatorLayoutGeometry.buttonSize(
                    .btnL, system: .snes, isLandscape: false, deviceScale: k).height
                #expect(abs(l1.minY - (inherited.centerY * c.height - inheritedH / 2)) < 0.5,
                        "\(label): the shoulder row left the top edge it inherited")
            }
        }
    }

    /// NOTHING ON THE PLAYSTATION PAGE MAY SIT ON ANYTHING ELSE.
    ///
    /// This is the test the console shipped its first build without, and the
    /// build was unusable because of it: the two sticks landed exactly on
    /// SELECT · ANALOG · START on every device, so the row could not be reached
    /// at all. Placing each control against ONE anchor and clamping only against
    /// the bottom edge is what allowed it. A page is not a set of anchors, it is
    /// an area, and the only honest check is the area one.
    ///
    /// REAL SAFE-AREA INSETS, not the zeros the rest of this suite passes.
    /// The insets decide where the picture ends, the picture's bottom edge is the
    /// top of the portrait controls container, and a zero inset hands the page
    /// about 60pt it does not have. Every collision here lives in those 60pt.
    ///
    /// The four faces are exempt from each other and only from each other: they
    /// are drawn as an overlapping diamond by design and hit-tested as circles,
    /// which is the arrangement `roundHitbox` exists for.
    @Test func ps1LaysNothingOnTopOfAnythingElse() {
        // top / left / right insets, per orientation, from the real devices.
        let devices: [(String, CGSize, Bool, UIEdgeInsets)] = [
            ("SE portrait", CGSize(width: 375, height: 667), false,
             UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)),
            ("SE landscape", CGSize(width: 667, height: 375), true, .zero),
            ("13 mini portrait", CGSize(width: 375, height: 812), false,
             UIEdgeInsets(top: 50, left: 0, bottom: 34, right: 0)),
            ("13 mini landscape", CGSize(width: 812, height: 375), true,
             UIEdgeInsets(top: 0, left: 50, bottom: 21, right: 50)),
            ("14 portrait", CGSize(width: 390, height: 844), false,
             UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)),
            ("14 landscape", CGSize(width: 844, height: 390), true,
             UIEdgeInsets(top: 0, left: 47, bottom: 21, right: 47)),
            ("14 Pro portrait", CGSize(width: 393, height: 852), false,
             UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)),
            ("14 Pro landscape", CGSize(width: 852, height: 393), true,
             UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
            ("Pro Max portrait", CGSize(width: 440, height: 956), false,
             UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)),
            ("Pro Max landscape", CGSize(width: 956, height: 440), true,
             UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
        ]
        let diamond: Set<ControlElement> = [.btnA, .btnB, .btnX, .btnY]

        for (label, device, isLandscape, insets) in devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: device)
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: device, safeInsets: insets, hasTouchScreen: false,
                isLandscape: isLandscape,
                gameAspect: EmulatorLayoutGeometryTests.displayAspect(.ps1), system: .ps1,
                controllerConnected: false, deviceScale: k)
            let container = EmulatorLayoutGeometry.controlsFrame(
                deviceSize: device, screenFrame: screen,
                hasTouchScreen: false, isLandscape: isLandscape).size
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .ps1, isLandscape: isLandscape, containerSize: container, scale: k,
                safeLeftInset: isLandscape ? insets.left : 0,
                safeRightInset: isLandscape ? insets.right : 0)

            var placed: [(ControlElement, CGRect)] = []
            for element in ControlElement.elements(for: .ps1) {
                guard let b = layout.buttons[element.rawValue] else {
                    Issue.record("\(label): \(element.rawValue) was never placed")
                    continue
                }
                // A DELIBERATELY hidden control is not a failure and must not be
                // measured: the shortest portrait page cannot hold the stick
                // clicks anywhere near their sticks, and hiding them is the
                // answer that beats drawing one on top of the stick it belongs
                // to. It still has to have been PLACED, which the guard above
                // insists on, so a hidden control is a decision and not a
                // control that fell out of the layout.
                guard !b.isHidden else { continue }
                let s = EmulatorLayoutGeometry.buttonSize(element, system: .ps1,
                                                          isLandscape: isLandscape, deviceScale: k)
                let rect = CGRect(x: b.centerX * container.width - s.width / 2,
                                  y: b.centerY * container.height - s.height / 2,
                                  width: s.width, height: s.height)
                // A control off the page is the same failure as one underneath
                // another: it cannot be pressed. The tolerance is a rounding
                // one, not a licence to hang over the edge.
                #expect(rect.minX >= -0.5 && rect.minY >= -0.5
                        && rect.maxX <= container.width + 0.5
                        && rect.maxY <= container.height + 0.5,
                        "\(label): \(element.rawValue) hangs off the page at \(rect)")
                placed.append((element, rect))
            }

            // CLIP is anchored to two CONTROLS, not to the page: R3's column and
            // SELECT's line. It held the bottom-left corner for two rounds, then
            // crossed to make room for the brand mark; anchoring it to controls
            // is what stops it drifting back into a corner nobody meant it to
            // take. Its clearance of the right edge is checked by the off-page
            // assertion above, which every control goes through.
            if !isLandscape, let clip = placed.first(where: { $0.0 == .btnClip })?.1,
               let r3 = placed.first(where: { $0.0 == .btnR3 })?.1 {
                #expect(abs(clip.midX - r3.midX) < 0.5 || clip.maxX > container.width - 20,
                        "\(label): CLIP left R3's column without being pushed off the edge")
            }

            for i in placed.indices {
                for j in placed.indices where j > i {
                    let (a, ra) = placed[i]
                    let (b, rb) = placed[j]
                    if diamond.contains(a) && diamond.contains(b) { continue }
                    #expect(!ra.insetBy(dx: 0.01, dy: 0.01).intersects(rb),
                            "\(label): \(a.rawValue) sits on \(b.rawValue) (\(ra) / \(rb))")
                }
            }
        }
    }

    /// LANDSCAPE IS LAID OUT AGAINST THIS CONSOLE'S OWN PICTURE.
    ///
    /// The bug this locks: the PlayStation borrows the Super Nintendo's whole layout, and that
    /// layout used to compute its gutters from a hardcoded 8:7 picture. A 4:3 one is a different
    /// shape, so every gutter, band and edge the buttons are placed against moves.
    ///
    /// It asserts the CONSEQUENCES rather than the picture's own width, which an earlier version
    /// did and which proved nothing: the landscape fit is width-first, so both shapes take the
    /// same width wherever neither is height-bound, and the two pictures differ in HEIGHT there.
    @Test func ps1LandscapeIsLaidOutAgainstItsOwnPicture() {
        for (label, size, isLandscape) in Self.devices where isLandscape {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .ps1)
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: size, safeInsets: .zero, hasTouchScreen: false,
                isLandscape: true, gameAspect: 4.0 / 3.0, system: .ps1,
                controllerConnected: false, deviceScale: k)
            let snesScreen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: size, safeInsets: .zero, hasTouchScreen: false,
                isLandscape: true, gameAspect: 8.0 / 7.0, system: .snes,
                controllerConnected: false, deviceScale: k)
            #expect(abs(screen.height - snesScreen.height) > 1,
                    "\(label): the two pictures are the same shape, so this test proves nothing")

            let layout = ControlLayoutDefaults.defaultLayout(
                system: .ps1, isLandscape: true, containerSize: c, scale: k)
            func rect(_ e: ControlElement) -> CGRect? {
                guard let b = layout.buttons[e.rawValue] else { return nil }
                let s = EmulatorLayoutGeometry.buttonSize(e, system: .ps1,
                                                          isLandscape: true, deviceScale: k)
                return CGRect(x: b.centerX * c.width - s.width / 2,
                              y: b.centerY * c.height - s.height / 2,
                              width: s.width, height: s.height)
            }
            // The face diamond lives in the right-hand gutter and the cross in the left. Both
            // must clear THIS picture, or the buttons are drawn over the game.
            for element in [ControlElement.btnA, .btnB, .btnX, .btnY] {
                guard let b = rect(element) else { continue }
                #expect(b.minX >= screen.maxX - 1,
                        Comment(rawValue: "\(label): \(element.rawValue) overlaps the picture by "
                                          + "\(screen.maxX - b.minX)pt"))
            }
            if let pad = rect(.dpad) {
                #expect(pad.maxX <= screen.minX + 1,
                        Comment(rawValue: "\(label): the cross overlaps the picture by "
                                          + "\(pad.maxX - screen.minX)pt"))
            }
            // And the row sits in the band under the picture's own surround, which is the other
            // measurement that would be wrong if this page had been laid out against an 8:7 one.
            let surroundBottom = screen.maxY + ControlLayoutDefaults.ps1LandscapeSkirt * k
            for element in [ControlElement.btnSelect, .btnMenu, .btnStart] {
                guard let b = rect(element) else { continue }
                #expect(b.minY >= surroundBottom - 0.5,
                        "\(label): \(element.rawValue) sits on the picture's surround")
                #expect(b.maxY <= c.height + 0.5, "\(label): \(element.rawValue) runs off the page")
            }
        }
    }

    /// ANALOG BELONGS TO THE STICKS, not to the SELECT · START row.
    ///
    /// This REPLACES its first placement. It sat between SELECT and START, spreading that pair
    /// to make room, which is where the pad prints the WORD but not what the switch does: it
    /// switches the two sticks, so it labels them. In portrait it takes the page's centre on
    /// the sticks' top edge — level with where they begin, so it reads as the label over the
    /// pair rather than as a third control in a row of three — and SELECT and START went back
    /// to the columns the Game Boy layout gave them. In landscape there is no band to share, so
    /// it hugs the picture's outer edge under its own gutter's bars, opposite CLIP.
    @Test func ps1AnalogLabelsTheSticksRatherThanJoiningTheRow() {
        for (label, size, isLandscape) in Self.devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .ps1)
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .ps1, isLandscape: isLandscape, containerSize: c, scale: k)
            func rect(_ e: ControlElement) -> CGRect? {
                guard let b = layout.buttons[e.rawValue] else { return nil }
                let s = EmulatorLayoutGeometry.buttonSize(e, system: .ps1,
                                                          isLandscape: isLandscape, deviceScale: k)
                return CGRect(x: b.centerX * c.width - s.width / 2,
                              y: b.centerY * c.height - s.height / 2,
                              width: s.width, height: s.height)
            }
            guard let mode = rect(.btnMode), let left = rect(.stickLeft),
                  let right = rect(.stickRight) else {
                Issue.record("\(label): ANALOG or a stick is missing")
                continue
            }

            if isLandscape {
                let screen = EmulatorLayoutGeometry.screenFrame(
                    deviceSize: size, safeInsets: .zero, hasTouchScreen: false,
                    isLandscape: true, gameAspect: EmulatorLayoutGeometryTests.displayAspect(.ps1),
                    system: .ps1, controllerConnected: false, deviceScale: k)
                #expect(mode.maxX <= screen.minX + 0.5,
                        "\(label): ANALOG should hug the picture from the LEFT, not cover it")
                if let clip = rect(.btnClip) {
                    #expect(clip.minX >= screen.maxX - 0.5,
                            "\(label): CLIP should hug the picture from the right")
                    #expect(abs(clip.midY - mode.midY) < 0.5,
                            "\(label): the two page controls should share one line")
                }
                if let l = rect(.btnL) {
                    #expect(mode.minY > l.maxY, "\(label): ANALOG should sit under its gutter's bars")
                }
            } else {
                // The page's centre, between the two sticks and touching neither.
                #expect(abs(mode.midX - c.width / 2) < 0.5,
                        "\(label): ANALOG should take the page's centre line")
                #expect(mode.minX - left.maxX > 0.5 && right.minX - mode.maxX > 0.5,
                        Comment(rawValue: "\(label): ANALOG runs into a stick "
                                          + "(left \(mode.minX - left.maxX)pt, "
                                          + "right \(right.minX - mode.maxX)pt)"))
                // On their TOP edge, which is the whole reason it reads as their label.
                #expect(abs(mode.midY - left.minY) < 0.5 && abs(mode.midY - right.minY) < 0.5,
                        "\(label): ANALOG left the line the sticks begin on")
                // And the pair it used to spread is back in the Game Boy's columns.
                let gb = ControlLayoutDefaults.defaultLayout(
                    system: .gbc, isLandscape: false, containerSize: c, scale: k)
                for element in [ControlElement.btnSelect, .btnStart] {
                    guard let ps1 = layout.buttons[element.rawValue],
                          let boy = gb.buttons[element.rawValue] else { continue }
                    #expect(abs(ps1.centerX - boy.centerX) < 0.0001,
                            "\(label): \(element.rawValue) never went back to its own column")
                }
            }
        }
    }

    /// FOUR SHOULDERS, TWO TO A HAND, AND NEVER STACKED.
    ///
    /// This REPLACES the stacked-pairs arrangement an earlier round drew. Stacking cost a
    /// portrait row's depth and a landscape gutter's, both of which this page needs for the
    /// controls under them, so each pair now sits side by side on the line its single bar
    /// already held. The two pages reach that differently and the difference is the point:
    ///  - PORTRAIT is ONE LINE OF FIVE, L1 · L2 · MENU · R1 · R2, each pair centred on the
    ///    cluster its fingers serve and MENU on the page. Three fixed points, so the row is
    ///    paid for in WIDTH (`ps1PortraitShoulderWidth`) rather than in position.
    ///  - LANDSCAPE puts a pair in each gutter, growing INWARD from the edge the outer bar
    ///    already hugged: a pair is more than twice its own bar wide, so spreading it about
    ///    that bar's centre would put half of it off the side of the phone.
    @Test func ps1ShouldersSitFourAcrossAndNeverTouch() {
        for (label, size, isLandscape) in Self.devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .ps1)
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .ps1, isLandscape: isLandscape, containerSize: c, scale: k)

            func rect(_ e: ControlElement) -> CGRect? {
                guard let b = layout.buttons[e.rawValue] else { return nil }
                let s = EmulatorLayoutGeometry.buttonSize(e, system: .ps1,
                                                          isLandscape: isLandscape, deviceScale: k)
                return CGRect(x: b.centerX * c.width - s.width / 2,
                              y: b.centerY * c.height - s.height / 2,
                              width: s.width, height: s.height)
            }
            guard let l = rect(.btnL), let l2 = rect(.btnL2),
                  let r = rect(.btnR), let r2 = rect(.btnR2) else {
                Issue.record("\(label): a shoulder is missing")
                continue
            }

            // A PAIR IS ONE CONTROL: one line, one size, and a real gap between the two bars.
            for (first, second) in [(l, l2), (r, r2)] {
                #expect(abs(first.midY - second.midY) < 0.5,
                        "\(label): a shoulder pair left its own line")
                #expect(abs(first.height - second.height) < 0.01
                        && abs(first.width - second.width) < 0.01,
                        "\(label): the two bars of one pair are different sizes")
                let gap = max(first.minX, second.minX) - min(first.maxX, second.maxX)
                #expect(gap > 0.5,
                        Comment(rawValue: "\(label): the pair's two bars touch or overlap "
                                          + "(gap \(gap)pt)"))
            }

            if isLandscape {
                // Each pair in its own gutter, and the second bar is the INBOARD one.
                #expect(l2.minX > l.minX, "\(label): L2 should sit inboard of L1")
                #expect(r2.maxX < r.maxX, "\(label): R2 should sit inboard of R1")
                #expect(l2.maxX < r2.minX, "\(label): the two pairs met in the middle")
            } else {
                guard let menu = rect(.btnMenu) else {
                    Issue.record("\(label): MENU is missing")
                    continue
                }
                // ONE LINE OF FIVE, in order, with MENU between the pairs and nothing touching.
                let row = [l, l2, menu, r, r2]
                for bar in row {
                    #expect(abs(bar.midY - l.midY) < 0.5, "\(label): the row of five is not one line")
                }
                for (a, b) in zip(row, row.dropFirst()) {
                    #expect(b.minX - a.maxX > 0.5,
                            Comment(rawValue: "\(label): the row of five collides "
                                              + "(gap \(b.minX - a.maxX)pt)"))
                }
                // Each pair is centred on the cluster its fingers serve, and MENU on the page.
                // That is what forces the bar's width, so it is the rule worth holding.
                if let pad = rect(.dpad) {
                    #expect(abs((l.midX + l2.midX) / 2 - pad.midX) < 0.5,
                            "\(label): the L pair left the cross's centre line")
                }
                let faces = [ControlElement.btnA, .btnB, .btnX, .btnY].compactMap(rect)
                if let left = faces.map(\.minX).min(), let right = faces.map(\.maxX).max() {
                    #expect(abs((r.midX + r2.midX) / 2 - (left + right) / 2) < 0.5,
                            "\(label): the R pair left the diamond's centre line")
                }
                #expect(abs(menu.midX - c.width / 2) < 0.5, "\(label): MENU left the page's centre")
            }
        }
    }

    @Test func ps1SecondShouldersStayOnScreen() {
        // The one thing stacking can break: a second row pushed off the bottom,
        // or onto the picture. Checked on the SE, which is the tightest page.
        for (label, size, isLandscape) in Self.devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .ps1)
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .ps1, isLandscape: isLandscape, containerSize: c, scale: k)
            for element in [ControlElement.btnL2, .btnR2] {
                guard let b = layout.buttons[element.rawValue] else { continue }
                let s = EmulatorLayoutGeometry.buttonSize(element, system: .ps1,
                                                          isLandscape: isLandscape, deviceScale: k)
                let top = b.centerY * c.height - s.height / 2
                let bottom = b.centerY * c.height + s.height / 2
                let left = b.centerX * c.width - s.width / 2
                let right = b.centerX * c.width + s.width / 2
                #expect(top >= 0, "\(label): \(element.rawValue) is off the top by \(-top)pt")
                #expect(bottom <= c.height,
                        "\(label): \(element.rawValue) is off the bottom by \(bottom - c.height)pt")
                #expect(left >= 0, "\(label): \(element.rawValue) is off the left by \(-left)pt")
                #expect(right <= c.width,
                        "\(label): \(element.rawValue) is off the right by \(right - c.width)pt")
            }
        }
    }

    /// The PlayStation's size table: the DS's pad, at this console's own scales.
    ///
    /// This REPLACES an older claim, that the PlayStation measured exactly like the Super
    /// Nintendo. It started there — both take the DS's five pad elements — and stopped being
    /// true when this page had to carry thirteen controls: the faces came in to `ps1PortraitFaceScale`
    /// so they sit inside the cross printed on their plateau, the sticks to `ps1PortraitStickScale`,
    /// and the four shoulders took a width of their own in BOTH orientations because four bars
    /// do not fit where two did. Asserting the old equality stopped describing anything, so what
    /// is locked here is each scale against the thing it derives from, plus the half of the old
    /// test that still matters: the Super Nintendo's own answers must not have moved.
    @Test func ps1SizesAreTheDSPadAtThisConsolesOwnScales() {
        // PORTRAIT.
        for element in [ControlElement.btnA, .btnB, .btnX, .btnY] {
            let ds = EmulatorLayoutGeometry.referenceSize(element, isNDS: true, isLandscape: false)
            let ps1 = EmulatorLayoutGeometry.referenceSize(element, system: .ps1, isLandscape: false)
            #expect(ps1.width == ds.width * EmulatorLayoutGeometry.ps1PortraitFaceScale
                    && ps1.height == ds.height * EmulatorLayoutGeometry.ps1PortraitFaceScale,
                    Comment(rawValue: "\(element.rawValue): a portrait face is the DS's, "
                                      + "scaled inside its printed mark"))
        }
        #expect(EmulatorLayoutGeometry.referenceSize(.dpad, system: .ps1, isLandscape: false)
                == EmulatorLayoutGeometry.referenceSize(.dpad, isNDS: true, isLandscape: false),
                "the cross is the DS's pad outright, unscaled")
        for element in [ControlElement.stickLeft, .stickRight] {
            let base = EmulatorLayoutGeometry.referenceSize(element, isNDS: false, isLandscape: false)
            let ps1 = EmulatorLayoutGeometry.referenceSize(element, system: .ps1, isLandscape: false)
            #expect(ps1.width == base.width * EmulatorLayoutGeometry.ps1PortraitStickScale,
                    "\(element.rawValue): a portrait stick gives up its outer ring")
        }

        // THE FOUR SHOULDERS ARE ONE BAR, in each orientation, and that is what makes the
        // arithmetic in `ControlLayoutDefaults.ps1` correct: portrait steps a pair about its
        // cluster's centre by half a bar, landscape grows a pair inward from one bar's edge.
        // Both read the FIRST bar's size for both members. (btnL2/btnR2 had no entry in the
        // landscape table and fell through to the portrait one, so a pair rendered 38 tall
        // beside 35.2 — this is the expectation that would have caught it.)
        for isLandscape in [false, true] {
            let bar = EmulatorLayoutGeometry.referenceSize(.btnL, system: .ps1, isLandscape: isLandscape)
            for element in EmulatorLayoutGeometry.ps1Shoulders {
                #expect(EmulatorLayoutGeometry.referenceSize(element, system: .ps1, isLandscape: isLandscape)
                        == bar,
                        Comment(rawValue: "\(element.rawValue): the four shoulders are one bar "
                                          + "(landscape: \(isLandscape))"))
            }
            let width = isLandscape
                ? EmulatorLayoutGeometry.ps1LandscapeShoulderWidth
                : EmulatorLayoutGeometry.ps1PortraitShoulderWidth
            #expect(bar.width == width, "the shoulder bar takes this console's own width")
        }
        let portraitBar = EmulatorLayoutGeometry.referenceSize(.btnL, system: .ps1, isLandscape: false)
        let inherited = EmulatorLayoutGeometry.referenceSize(.btnL, isNDS: false, isLandscape: false)
        #expect(portraitBar.height
                == inherited.height * EmulatorLayoutGeometry.ps1PortraitShoulderHeightScale,
                "the portrait bar keeps its share of the inherited depth")

        // AND THE SUPER NINTENDO IS UNAFFECTED. Its rule is the one that existed before the
        // PlayStation joined the table: the DS's measurements for the five pad elements, its
        // own for everything else, and the landscape D-pad excepted because that page is the
        // GBA's. Written out rather than compared against the PlayStation, since the two
        // consoles no longer agree and comparing them proved nothing about either.
        for isLandscape in [false, true] {
            for element in ControlElement.snesElements {
                let usesDS = EmulatorLayoutGeometry.snesUsesNDSSizing.contains(element)
                    && !(isLandscape && element == .dpad
                         && EmulatorLayoutGeometry.snesLandscapeUsesGBAPad)
                let expected = EmulatorLayoutGeometry.referenceSize(
                    element, isNDS: usesDS, isLandscape: isLandscape)
                #expect(EmulatorLayoutGeometry.referenceSize(element, system: .snes,
                                                             isLandscape: isLandscape) == expected,
                        Comment(rawValue: "\(element.rawValue): the Super Nintendo's size moved "
                                          + "(landscape: \(isLandscape))"))
            }
        }
    }

    @Test func snesPadIsTheDSPad() {
        for (label, size, isLandscape) in Self.devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .snes)
            let snes = ControlLayoutDefaults.defaultLayout(
                system: .snes, isLandscape: isLandscape, containerSize: c, scale: k)
            let ds = ControlLayoutDefaults.defaultLayout(
                system: .nds, isLandscape: isLandscape, containerSize: c, scale: k)

            // The D-pad is the DS's in portrait and the GBA's in landscape, so it is the four
            // faces that are the DS's on both pages.
            let faces: [ControlElement] = [.btnA, .btnB, .btnX, .btnY]
            for element in faces {
                #expect(EmulatorLayoutGeometry.referenceSize(element, system: .snes, isLandscape: isLandscape)
                        == EmulatorLayoutGeometry.referenceSize(element, isNDS: true, isLandscape: isLandscape),
                        "\(label): \(element.rawValue) should be sized like the DS")
            }
            if !isLandscape {
                // The D-pad is the DS's outright.
                #expect(snes.buttons[ControlElement.dpad.rawValue] == ds.buttons[ControlElement.dpad.rawValue],
                        "\(label): the D-pad should sit where the DS puts it")
                #expect(EmulatorLayoutGeometry.referenceSize(.dpad, system: .snes, isLandscape: false)
                        == EmulatorLayoutGeometry.referenceSize(.dpad, isNDS: true, isLandscape: false),
                        "\(label): the D-pad should be sized like the DS in portrait")
                // The four faces are the DS's SHAPE, not the DS's coordinates: each pair keeps
                // the vector the DS puts between its own two buttons, and the two pairs then
                // step apart along the perpendicular they share so the dress's capsules clear
                // each other. That step is measured by `theTwoFacePairsClearEachOther`; what
                // matters here is that it moved the pairs and did not deform them.
                for (first, second) in [(ControlElement.btnX, ControlElement.btnY),
                                        (ControlElement.btnB, ControlElement.btnA)] {
                    guard let f = snes.buttons[first.rawValue], let sc = snes.buttons[second.rawValue],
                          let df = ds.buttons[first.rawValue], let dsc = ds.buttons[second.rawValue] else { continue }
                    #expect(abs((sc.centerX - f.centerX) - (dsc.centerX - df.centerX)) < 0.0001,
                            "\(label): \(first.rawValue)->\(second.rawValue) lost the DS's horizontal offset")
                    #expect(abs((sc.centerY - f.centerY) - (dsc.centerY - df.centerY)) < 0.0001,
                            "\(label): \(first.rawValue)->\(second.rawValue) lost the DS's vertical offset")
                }
            }
            guard isLandscape else { continue }

            // The four faces: one block, so one shift for all of them and no change of line.
            guard let snesA = snes.buttons[ControlElement.btnA.rawValue],
                  let dsA = ds.buttons[ControlElement.btnA.rawValue] else {
                Issue.record("\(label): the SNES landscape layout is missing A")
                continue
            }
            // ONE translation, in both axes: right into the gutter, and down onto the pad's
            // line (the pad here is the GBA's, which sits below the mid-line the DS's faces are
            // centred on). Every face must carry both shifts identically, which is what makes it
            // a moved block rather than four buttons that happen to have been nudged.
            let shiftX = snesA.centerX - dsA.centerX
            let shiftY = snesA.centerY - dsA.centerY
            #expect(shiftX > 0, "\(label): the four faces should move right, into the gutter")
            #expect(shiftY > 0, "\(label): the four faces should move down, onto the pad's line")
            for element in [ControlElement.btnA, .btnB, .btnX, .btnY] {
                guard let s = snes.buttons[element.rawValue],
                      let d = ds.buttons[element.rawValue] else { continue }
                #expect(abs((s.centerX - d.centerX) - shiftX) < 0.0001,
                        "\(label): \(element.rawValue) did not move sideways with the rest of the block")
                #expect(abs((s.centerY - d.centerY) - shiftY) < 0.0001,
                        "\(label): \(element.rawValue) did not move down with the rest of the block")
            }

            // The D-pad in landscape is the GBA's outright, position and size: this page is the
            // GBA's page, and taking the DS's pad onto it is what put the pad in the picture.
            let gba = ControlLayoutDefaults.defaultLayout(
                system: .gba, isLandscape: true, containerSize: c, scale: k)
            #expect(snes.buttons[ControlElement.dpad.rawValue] == gba.buttons[ControlElement.dpad.rawValue],
                    "\(label): the D-pad should sit where the GBA puts it")
            #expect(EmulatorLayoutGeometry.referenceSize(.dpad, system: .snes, isLandscape: true)
                    == EmulatorLayoutGeometry.referenceSize(.dpad, isNDS: false, isLandscape: true),
                    "\(label): the D-pad should be sized like the GBA's")
        }
    }

    /// The four face buttons sit on the D-pad's line in portrait.
    ///
    /// Both come from the DS, whose pad and whose diamond centre are the same `h/2 − 6`, so this
    /// held by coincidence before it was anchored. The two pairs then step apart along their
    /// shared perpendicular, equal and opposite, which is why that step cannot move the line: if
    /// this test ever fails it is because the steps stopped being symmetric, or because the pad
    /// and the faces stopped coming from the same console.
    @Test func theFaceBlocSharesThePadsLine() {
        for (label, size, isLandscape) in Self.devices where !isLandscape {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, false, .snes)
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .snes, isLandscape: false, containerSize: c, scale: k)
            let ys = [ControlElement.btnA, .btnB, .btnX, .btnY]
                .compactMap { layout.buttons[$0.rawValue]?.centerY }
            guard let pad = layout.buttons[ControlElement.dpad.rawValue],
                  let lo = ys.min(), let hi = ys.max() else {
                Issue.record("\(label): the SNES portrait layout is missing the pad or a face")
                continue
            }
            #expect(abs((lo + hi) / 2 - pad.centerY) * c.height < 0.5,
                    "\(label): the face bloc is off the D-pad's line")
        }
    }

    /// The two face PAIRS clear each other, which is what the dress's two capsules need: taken
    /// straight from the DS their centre lines are 70.7pt apart and each capsule is 75.8pt
    /// thick, so they crossed. The step is measured here in the same terms — the distance
    /// between the two pair-lines, along the perpendicular they share.
    @Test func theTwoFacePairsClearEachOther() {
        for (label, size, isLandscape) in Self.devices where !isLandscape {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, false, .snes)
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .snes, isLandscape: false, containerSize: c, scale: k)
            func point(_ e: ControlElement) -> CGPoint? {
                guard let b = layout.buttons[e.rawValue] else { return nil }
                return CGPoint(x: b.centerX * c.width, y: b.centerY * c.height)
            }
            guard let x = point(.btnX), let a = point(.btnA) else {
                Issue.record("\(label): the SNES portrait layout is missing a face")
                continue
            }
            // Both pairs lie along the same diagonal, so one point from each is enough: the gap
            // is the separation of their lines projected on the perpendicular (1, 1)/√2.
            let separation = abs((a.x - x.x) + (a.y - x.y)) / CGFloat(2).squareRoot()
            let thickness = EmulatorLayoutGeometry.buttonSize(
                .btnA, system: .snes, isLandscape: false, deviceScale: k).width
                + 2 * 6 * k   // SuperNintendoSkin.capsulePad, doubled: each capsule's own
            #expect(separation > thickness,
                    "\(label): the two face capsules overlap by \(thickness - separation)pt")
        }
    }

    /// The four face buttons must clear the Dynamic Island in BOTH landscape rotations.
    ///
    /// They live in the right gutter, and the island is on that side in one of the two. The
    /// layout centres the block in the SAFE gutter rather than the raw one, and the picture
    /// gives up enough width for the safe gutter to hold it: on a 14 Pro the block is 181.6pt
    /// and the safe gutter 185.3pt, which is the whole margin this test exists to keep.
    @Test func theFaceButtonsClearTheIslandInEitherRotation() {
        let devices: [(String, CGSize, CGFloat)] = [
            ("iPhone 14 Pro", CGSize(width: 852, height: 393), 59),
            ("iPhone 16 Pro Max", CGSize(width: 956, height: 440), 62),
        ]
        for (name, size, island) in devices {
            for islandOnTheRight in [false, true] {
                let k = EmulatorLayoutGeometry.deviceScale(for: size)
                let c = container(size, true, .snes)
                let layout = ControlLayoutDefaults.defaultLayout(
                    system: .snes, isLandscape: true, containerSize: c, scale: k,
                    safeLeftInset: islandOnTheRight ? 0 : island,
                    safeRightInset: islandOnTheRight ? island : 0)
                let safeRight = size.width - (islandOnTheRight ? island : 0)
                for element in [ControlElement.btnA, .btnB, .btnX, .btnY] {
                    guard let b = layout.buttons[element.rawValue] else { continue }
                    let w = EmulatorLayoutGeometry.buttonSize(
                        element, system: .snes, isLandscape: true, deviceScale: k).width
                    let side = islandOnTheRight ? "island right" : "island left"
                    #expect(b.centerX * c.width + w / 2 <= safeRight + 0.5,
                            "\(name) \(side): \(element.rawValue) runs under the island")
                }
            }
        }
    }

    /// SELECT and START come from the Game Boy instead: its size on both pages, and its
    /// position wherever this console's page allows it.
    ///
    /// Portrait is the Game Boy's spot outright. In landscape the pair keeps the Game Boy's
    /// columns but not its line: SELECT, MENU and START arrive from two different consoles,
    /// each stuck to ITS console's screen bottom, so left alone they render as a staggered
    /// row. They belong on one line under THIS console's screen, and
    /// `theSNESBottomRowIsOneLine` is where that line is held.
    @Test func snesSelectAndStartAreTheGameBoysPair() {
        for (label, size, isLandscape) in Self.devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .snes)
            let snes = ControlLayoutDefaults.defaultLayout(
                system: .snes, isLandscape: isLandscape, containerSize: c, scale: k)
            let gb = ControlLayoutDefaults.defaultLayout(
                system: .gbc, isLandscape: isLandscape, containerSize: c, scale: k)
            for element in [ControlElement.btnSelect, .btnStart] {
                #expect(EmulatorLayoutGeometry.referenceSize(element, system: .snes, isLandscape: isLandscape)
                        == EmulatorLayoutGeometry.referenceSize(element, isNDS: false, isLandscape: isLandscape),
                        "\(label): \(element.rawValue) should keep the Game Boy's size")
                guard let s = snes.buttons[element.rawValue],
                      let g = gb.buttons[element.rawValue] else {
                    Issue.record("\(label): the SNES layout is missing \(element.rawValue)")
                    continue
                }
                if isLandscape {
                    #expect(abs(s.centerX - g.centerX) < 0.0001,
                            "\(label): \(element.rawValue) should keep the Game Boy's column")
                } else {
                    #expect(s == g, "\(label): \(element.rawValue) should sit where the Game Boy puts it")
                }
            }
        }
    }

    /// Sizing is per element now, so the promise that matters most is the one
    /// about everyone else: no console that shipped before 1.2.5 may move.
    @Test func perElementSizingDidNotMoveTheShippedConsoles() {
        for system in [PresetSystem.gba, .gbc, .nds] {
            for isLandscape in [false, true] {
                for element in ControlElement.elements(for: system) {
                    #expect(EmulatorLayoutGeometry.referenceSize(element, system: system, isLandscape: isLandscape)
                            == EmulatorLayoutGeometry.referenceSize(element, isNDS: system == .nds, isLandscape: isLandscape),
                            "\(system) \(element.rawValue) moved")
                }
            }
        }
    }

    /// The SNES inherits everything that is not a face button, so a change to the
    /// GBA defaults carries over instead of being duplicated and forgotten.
    ///
    /// Two of them bend on this console, each with its own test and its own reason: MENU
    /// keeps the GBA's column but joins the bottom row in landscape
    /// (`theSNESBottomRowIsOneLine`), and CLIP leaves the GBA's spot entirely
    /// (`snesClipLeavesTheGBAsSpotBecauseItCollides`).
    @Test func snesInheritsTheGBAsOtherControls() {
        for (label, size, isLandscape) in Self.devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .snes)
            let snes = ControlLayoutDefaults.defaultLayout(
                system: .snes, isLandscape: isLandscape, containerSize: c, scale: k)
            let gba = ControlLayoutDefaults.defaultLayout(
                system: .gba, isLandscape: isLandscape, containerSize: c, scale: k)
            // The shoulders, and in landscape the D-pad too: the GBA's, since it is the only
            // other console here with shoulders and the same single-screen page.
            let inherited: [ControlElement] = isLandscape ? [.btnL, .btnR, .dpad] : [.btnL, .btnR]
            for element in inherited {
                #expect(snes.buttons[element.rawValue] == gba.buttons[element.rawValue],
                        "\(label): \(element.rawValue) should be the GBA's")
            }
            guard let menu = snes.buttons[ControlElement.btnMenu.rawValue],
                  let gbaMenu = gba.buttons[ControlElement.btnMenu.rawValue] else {
                Issue.record("\(label): the SNES layout is missing MENU")
                continue
            }
            if isLandscape {
                #expect(abs(menu.centerX - gbaMenu.centerX) < 0.0001,
                        "\(label): MENU should keep the GBA's column")
            } else {
                #expect(menu == gbaMenu, "\(label): MENU should be the GBA's")
            }
        }
    }

    /// CLIP is the one control that leaves the GBA's spot, and it leaves it on both pages
    /// for the same reason: on this console that spot is already taken.
    ///
    /// PORTRAIT — the GBA parks Clip just under A, which on that console is a lone face
    /// button with empty case above it. Here A is the right vertex of a diamond and X sits
    /// in exactly that case: measured on the real page, safe-area insets included, the
    /// inherited spot lands 8pt inside X on a 14 Pro and 16pt on an SE. So Clip joins the
    /// bottom row instead, on SELECT and START's line and in A's column, which is where the
    /// DS puts its own.
    ///
    /// LANDSCAPE — the right gutter belongs to the four face buttons, so Clip crosses to under
    /// L, mirroring the GBA's under-R spot on the other side. The gap below L is a clear one;
    /// its exact value is taste, the clearance is the promise.
    ///
    /// `newConsolesDoNotOverlapWithRealSafeAreas` is what proves the collision is gone. This
    /// is what holds the spot it moved to.
    @Test func snesClipLeavesTheGBAsSpotBecauseItCollides() {
        for (label, size, isLandscape) in Self.devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, isLandscape, .snes)
            let snes = ControlLayoutDefaults.defaultLayout(
                system: .snes, isLandscape: isLandscape, containerSize: c, scale: k)
            guard let clip = snes.buttons[ControlElement.btnClip.rawValue] else {
                Issue.record("\(label): the SNES layout is missing CLIP")
                continue
            }
            if isLandscape {
                // CLIP crossed to the RIGHT gutter (2026-08-17), which is what freed the left one
                // for the Retro Pal plaque. It sits in R's column, centred in the band between the
                // shoulder row and the top of the pad — the same line the dress gives the plaque.
                guard let r = snes.buttons[ControlElement.btnR.rawValue],
                      let l = snes.buttons[ControlElement.btnL.rawValue],
                      let pad = snes.buttons[ControlElement.dpad.rawValue] else { continue }
                #expect(abs(clip.centerX - r.centerX) < 0.0001, "\(label): CLIP should sit in R's column")
                func height(_ e: ControlElement) -> CGFloat {
                    EmulatorLayoutGeometry.buttonSize(e, system: .snes, isLandscape: true,
                                                      deviceScale: k).height
                }
                let shoulderBottom = max(l.centerY * c.height + height(.btnL) / 2,
                                         r.centerY * c.height + height(.btnR) / 2)
                let padTop = pad.centerY * c.height - height(.dpad) / 2
                let expected = DressKind.snesLandscapeUtilityCenterY(
                    shoulderBottom: shoulderBottom, padTop: padTop)
                #expect(abs(clip.centerY * c.height - expected) < 0.5,
                        "\(label): CLIP should take the plaque's line")
                // The band has to actually hold it, or "centred" is drawn half over a shoulder.
                let clipHalf = height(.btnClip) / 2
                #expect(expected - clipHalf > shoulderBottom,
                        "\(label): CLIP runs into the shoulder row")
                #expect(expected + clipHalf < padTop, "\(label): CLIP runs into the pad")
            } else {
                guard let a = snes.buttons[ControlElement.btnA.rawValue],
                      let select = snes.buttons[ControlElement.btnSelect.rawValue] else { continue }
                #expect(abs(clip.centerX - a.centerX) < 0.0001, "\(label): CLIP should sit in A's column")
                #expect(abs(clip.centerY - select.centerY) < 0.0001, "\(label): CLIP should sit on SELECT's line")
            }
        }
    }

    /// Every laid-out button rect for a console on a device, with that device's real safe-area
    /// insets — the geometry that actually renders, since the insets decide where the screen
    /// starts and therefore how tall the controls container is.
    private func realRects(system: PresetSystem, isLandscape: Bool,
                           deviceSize: CGSize, insets: UIEdgeInsets) -> [ControlElement: CGRect] {
        let k = EmulatorLayoutGeometry.deviceScale(for: deviceSize)
        let screen = EmulatorLayoutGeometry.screenFrame(
            deviceSize: deviceSize, safeInsets: insets, hasTouchScreen: false,
            isLandscape: isLandscape, gameAspect: EmulatorLayoutGeometryTests.displayAspect(system), system: system,
            controllerConnected: false, deviceScale: k)
        let container = EmulatorLayoutGeometry.controlsFrame(
            deviceSize: deviceSize, screenFrame: screen, hasTouchScreen: false, isLandscape: isLandscape)
        // BOTH horizontal insets, exactly as `EmulatorViewController.applyControlConstraints`
        // passes them. The trailing one is not decoration: the SNES centres its face-button
        // diamond in the SAFE right gutter, so leaving it at zero measured a page the app
        // never renders — and it is the rotation where the gutter is tightest, which is the
        // only rotation worth testing. The device rows below carry an inset on both sides at
        // once, which no single rotation does; that is the worst case of the two on purpose.
        let layout = ControlLayoutDefaults.defaultLayout(
            system: system, isLandscape: isLandscape, containerSize: container.size, scale: k,
            safeLeftInset: isLandscape ? insets.left : 0,
            safeRightInset: isLandscape ? insets.right : 0)
        var rects: [ControlElement: CGRect] = [:]
        for e in ControlElement.elements(for: system) {
            guard let bl = layout.buttons[e.rawValue], !bl.isHidden else { continue }
            let s = EmulatorLayoutGeometry.buttonSize(e, system: system,
                                                      isLandscape: isLandscape, deviceScale: k)
            rects[e] = CGRect(x: container.minX + bl.centerX * container.width - s.width / 2,
                              y: container.minY + bl.centerY * container.height - s.height / 2,
                              width: s.width, height: s.height)
        }
        return rects
    }

    /// The same overlap sweep as `controlsDoNotOverlapOniPhoneSE`, but with the devices' REAL
    /// safe-area insets rather than zero.
    ///
    /// This test exists because zero insets hid a real bug. In portrait the screen starts below
    /// the safe area, so the controls container is 59pt shorter on a 14 Pro than the zero-inset
    /// sweep believes — and buttons anchored to the container's top and bottom close on each
    /// other by exactly that much. The SNES's Clip landed 8pt inside X on a 14 Pro and 16pt on
    /// an SE, and the NES's landed 4pt inside A on the SE, while the old sweep reported both
    /// pages clean. Both are fixed in `ControlLayoutDefaults`; this is what holds them fixed.
    ///
    /// Scoped to the consoles added SINCE the engine was device-verified: the three that shipped
    /// before are verified on real hardware, and widening a passing sweep to them is a separate
    /// decision. The PlayStation joined on 2026-08-27 and belongs here more than either of the
    /// other two -- it is the fullest page the app draws, thirteen controls against six, and the
    /// only overlap check it had was the zero-inset one, which is the exact blind spot this test
    /// exists for. The page was modelled on all three devices with these insets before it was
    /// added here.
    @Test func newConsolesDoNotOverlapWithRealSafeAreas() {
        // (device, portrait size, portrait insets, landscape size, landscape insets)
        let devices: [(String, CGSize, UIEdgeInsets, CGSize, UIEdgeInsets)] = [
            ("iPhone SE", CGSize(width: 375, height: 667), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0),
             CGSize(width: 667, height: 375), .zero),
            ("iPhone 14 Pro", CGSize(width: 393, height: 852), UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
             CGSize(width: 852, height: 393), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
            ("iPhone 16 Pro Max", CGSize(width: 440, height: 956), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
             CGSize(width: 956, height: 440), UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
        ]
        for system in [PresetSystem.snes, .nes, .ps1] {
            for (name, portrait, pInsets, landscape, lInsets) in devices {
                for (size, insets, isLandscape) in [(portrait, pInsets, false), (landscape, lInsets, true)] {
                    let rects = realRects(system: system, isLandscape: isLandscape,
                                          deviceSize: size, insets: insets)
                    let elements = Array(rects.keys)
                    for i in 0..<elements.count {
                        for j in (i + 1)..<elements.count {
                            let e1 = elements[i], e2 = elements[j]
                            let depth = ButtonShape.penetration(ButtonShape.of(e1, rects[e1]!),
                                                                ButtonShape.of(e2, rects[e2]!))
                            let page = isLandscape ? "landscape" : "portrait"
                            #expect(depth < 0.5,
                                    "\(system) \(name) \(page): \(e1.rawValue) overlaps \(e2.rawValue) by \(depth)pt")
                        }
                    }
                }
            }
        }
    }

    /// Landscape is the page where the controls are drawn OVER the game: the screen is a panel
    /// in the middle with a gutter each side, and every control has to live in a gutter or below.
    /// The SNES inherits its pad from the DS, whose landscape page is a different shape entirely
    /// (screens above, controls below, full width) — taken literally, those positions put the
    /// D-pad and the X/Y buttons on top of the picture. This is what holds the correction.
    @Test func landscapeControlsNeverCoverTheGame() {
        let devices: [(String, CGSize, UIEdgeInsets)] = [
            ("iPhone SE", CGSize(width: 667, height: 375), .zero),
            ("iPhone 14 Pro", CGSize(width: 852, height: 393),
             UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
            ("iPhone 16 Pro Max", CGSize(width: 956, height: 440),
             UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
        ]
        for system in [PresetSystem.snes, .nes, .ps1] {
            for (name, size, insets) in devices {
                let k = EmulatorLayoutGeometry.deviceScale(for: size)
                let screen = EmulatorLayoutGeometry.screenFrame(
                    deviceSize: size, safeInsets: insets, hasTouchScreen: false, isLandscape: true,
                    gameAspect: EmulatorLayoutGeometryTests.displayAspect(system), system: system, controllerConnected: false, deviceScale: k)
                for (element, rect) in realRects(system: system, isLandscape: true,
                                                 deviceSize: size, insets: insets) {
                    let covered = rect.intersection(screen)
                    #expect(covered.isNull || covered.width < 0.5 || covered.height < 0.5,
                            "\(system) \(name): \(element.rawValue) covers the game by \(covered)")
                }
            }
        }
    }

    /// SELECT, MENU and START arrive from two different consoles, each stuck to ITS console's
    /// screen bottom. On the SNES that is two different lines 18pt apart, which renders as a
    /// staggered row. They belong on one line, under this console's screen.
    @Test func theSNESBottomRowIsOneLine() {
        let devices: [(String, CGSize, UIEdgeInsets)] = [
            ("iPhone SE", CGSize(width: 667, height: 375), .zero),
            ("iPhone 14 Pro", CGSize(width: 852, height: 393),
             UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
            ("iPhone 16 Pro Max", CGSize(width: 956, height: 440),
             UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
        ]
        for (name, size, insets) in devices {
            let rects = realRects(system: .snes, isLandscape: true, deviceSize: size, insets: insets)
            guard let select = rects[.btnSelect], let menu = rects[.btnMenu],
                  let start = rects[.btnStart] else {
                Issue.record("\(name): the SNES landscape row is missing a button")
                continue
            }
            #expect(abs(select.midY - menu.midY) < 0.5, "\(name): MENU is off SELECT's line")
            #expect(abs(select.midY - start.midY) < 0.5, "\(name): START is off SELECT's line")
        }
    }

    /// The NES picture is its OWN frame with square pixels (248x240 once the PPU's blankable
    /// left columns are cropped), like the Super Nintendo's,
    /// and that is taller than the 4:3 it used to claim. Taller picture means a shorter controls
    /// container, and this console's layout is the Game Boy's, which was tuned against a squarer
    /// screen: the clamp in `ControlLayoutDefaults.nes` is what absorbs it. This measures the
    /// consequence rather than the constant — the container must still be tall enough to hold the
    /// pad, which is the thing that stops fitting first.
    @Test func theNESPictureLeavesRoomForItsPad() {
        for (label, size, isLandscape) in Self.devices where !isLandscape {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let c = container(size, false, .nes)
            let layout = ControlLayoutDefaults.defaultLayout(
                system: .nes, isLandscape: false, containerSize: c, scale: k)
            guard let pad = layout.buttons[ControlElement.dpad.rawValue] else {
                Issue.record("\(label): the NES layout is missing its pad")
                continue
            }
            let padH = EmulatorLayoutGeometry.buttonSize(
                .dpad, system: .nes, isLandscape: false, deviceScale: k).height
            #expect(pad.centerY * c.height - padH / 2 > 0,
                    "\(label): the NES pad starts above its own container")
            #expect(pad.centerY * c.height + padH / 2 < c.height,
                    "\(label): the NES pad runs past the bottom of the page")
        }
    }

    /// NES portrait: MENU and CLIP share one line, centred in the band the dress leaves between
    /// the screen panel's lower edge and the sunken well around A and B.
    ///
    /// Measured with REAL safe-area insets, because the band's own position depends on how tall
    /// the controls container is and the insets are what decide that (see
    /// `newConsolesDoNotOverlapWithRealSafeAreas` for the bug that taught us to).
    ///
    /// It asserts the rule rather than a number: both bounds come from `DressKind`, which is also
    /// where the dress reads them, so a change to the skirt or the well's padding moves the dress
    /// and this expectation together and the test still means what it says.
    @Test func theNESUtilityRowSitsBetweenThePanelAndTheFaceWell() {
        let devices: [(String, CGSize, UIEdgeInsets)] = [
            ("iPhone SE", CGSize(width: 375, height: 667),
             UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)),
            ("iPhone 14 Pro", CGSize(width: 393, height: 852),
             UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)),
            ("iPhone 16 Pro Max", CGSize(width: 440, height: 956),
             UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
        ]
        for (name, size, insets) in devices {
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            let rects = realRects(system: .nes, isLandscape: false, deviceSize: size, insets: insets)
            guard let menu = rects[.btnMenu], let clip = rects[.btnClip],
                  let a = rects[.btnA], let b = rects[.btnB] else {
                Issue.record("\(name): the NES portrait layout is missing a button")
                continue
            }
            #expect(abs(menu.midY - clip.midY) < 0.5, "\(name): MENU and CLIP are off one line")

            // The band. `realRects` is in DEVICE coordinates, and the controls container starts at
            // the picture's bottom edge, so the panel's lower edge is that edge plus the skirt.
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: size, safeInsets: insets, hasTouchScreen: false, isLandscape: false,
                gameAspect: EmulatorLayoutGeometryTests.displayAspect(.nes), system: .nes,
                controllerConnected: false, deviceScale: k)
            let panelBottom = screen.maxY + DressKind.nesPanelSkirt * k
            let wellTop = DressKind.nesFaceWellTop(a: a, b: b, scale: k)
            #expect(wellTop > panelBottom, "\(name): the NES portrait band has no height at all")

            let expected = (panelBottom + wellTop) / 2
            #expect(abs(menu.midY - expected) < 0.5, "\(name): the row is not centred in the band")
            for (label, rect) in [("MENU", menu), ("CLIP", clip)] {
                #expect(rect.minY > panelBottom,
                        "\(name): \(label) runs up onto the screen panel")
                #expect(rect.maxY < wellTop,
                        "\(name): \(label) runs down into the A/B well")
            }
        }
    }

    /// The element sets, which decide what renders at all.
    @Test func elementSetsMatchTheHardware() {
        #expect(!ControlElement.elements(for: .snes).contains(.btnMic))
        #expect(ControlElement.elements(for: .snes).contains(.btnX))
        #expect(ControlElement.elements(for: .snes).contains(.btnL))
        #expect(ControlElement.elements(for: .nes) == ControlElement.gbcElements)
        #expect(!ControlElement.elements(for: .nes).contains(.btnL))
    }

    /// A preset saved before these consoles existed carries neither flag, and must
    /// still resolve to the console it was made for.
    @Test func olderPresetsKeepResolvingWhereTheyDid() throws {
        let legacy = Data(#"{"gba":false,"gbc":true,"nds":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SystemApplicability.self, from: legacy)
        #expect(decoded.system == .gbc)
        #expect(SystemApplicability(system: .snes).system == .snes)
        #expect(SystemApplicability(system: .nes).system == .nes)
    }
}
