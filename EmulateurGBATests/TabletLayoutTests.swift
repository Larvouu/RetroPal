//
//  TabletLayoutTests.swift
//  EmulateurGBATests
//
//  The tablet geometry family (2026-09-05, the iPad build), and the promise
//  that came with it: no phone renders differently because it exists.
//
//  Two halves. The first pins the PHONE side: the family boundary, the old
//  scale clamp, and the two picture formulas a tablet branch would break first
//  if it ever leaked (the landscape 74 % width and the portrait 45 % height).
//  The second sweeps the three iPads of the plan (mini, 11-inch, 13-inch),
//  both orientations, every console, with the insets an iPad really has, and
//  asks the questions the phone sweeps ask plus the ones only a tablet raises:
//  the picture is at least half the window tall on its side, the row the
//  single-screen consoles stick under it really is under it, and the frame
//  does not move when the caller passes real insets instead of the zero ones
//  `ControlLayoutDefaults` recomputes with, which is the invariant the whole
//  tablet page rests on.
//
//  Written without a compiler in the room (2026-09-05). If a tablet sweep is
//  red on the first run, read the failing console and orientation before
//  touching a constant: the numbers in `EmulatorLayoutGeometry` are named for
//  exactly that review.
//

import Testing
import UIKit
@testable import EmulateurGBA

@Suite("Tablet layout family")
struct TabletLayoutTests {

    // MARK: - Devices

    /// The three iPads of the plan, portrait points. Insets are the same in both
    /// orientations on every iPad with a home indicator: a 24-point status bar
    /// and a 20-point indicator, no side inset.
    static let tablets: [(name: String, portrait: CGSize)] = [
        ("iPad mini", CGSize(width: 744, height: 1133)),
        ("iPad 11-inch", CGSize(width: 834, height: 1210)),
        ("iPad 13-inch", CGSize(width: 1032, height: 1376)),
    ]
    static let tabletInsets = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)

    static let phones: [(name: String, portrait: CGSize)] = [
        ("iPhone SE", CGSize(width: 375, height: 667)),
        ("iPhone 14 Pro", CGSize(width: 393, height: 852)),
        ("iPhone 16 Pro Max", CGSize(width: 440, height: 956)),
    ]

    static let systems: [PresetSystem] = [.gba, .gbc, .nds, .snes, .nes, .ps1]

    private func onItsSide(_ portrait: CGSize) -> CGSize {
        CGSize(width: portrait.height, height: portrait.width)
    }

    private func approx(_ a: CGFloat, _ b: CGFloat, tol: CGFloat = 0.5) -> Bool {
        abs(a - b) <= tol
    }

    // MARK: - The page, in view space

    /// Everything the emulator lays out for one console on one window: the
    /// picture, the controls container, and every button rect in VIEW space,
    /// the NDS-landscape gutter fit applied, both horizontal insets passed the
    /// way `EmulatorViewController.applyControlConstraints` passes them.
    private func page(system: PresetSystem, isLandscape: Bool, deviceSize: CGSize,
                      insets: UIEdgeInsets) -> (screen: CGRect, container: CGRect,
                                                rects: [ControlElement: CGRect]) {
        let k = EmulatorLayoutGeometry.deviceScale(for: deviceSize)
        let isNDS = (system == .nds)
        let screen = EmulatorLayoutGeometry.screenFrame(
            deviceSize: deviceSize, safeInsets: insets, hasTouchScreen: isNDS,
            isLandscape: isLandscape, gameAspect: EmulatorLayoutGeometryTests.displayAspect(system),
            system: system, controllerConnected: false, deviceScale: k)
        let container = EmulatorLayoutGeometry.controlsFrame(
            deviceSize: deviceSize, screenFrame: screen, hasTouchScreen: isNDS, isLandscape: isLandscape)
        let layout = ControlLayoutDefaults.defaultLayout(
            system: system, isLandscape: isLandscape, containerSize: container.size, scale: k,
            safeLeftInset: isLandscape ? insets.left : 0,
            safeRightInset: isLandscape ? insets.right : 0,
            family: LayoutFamily.of(deviceSize))
        var rects: [ControlElement: CGRect] = [:]
        for e in ControlElement.elements(for: system) {
            guard let bl = layout.buttons[e.rawValue], !bl.isHidden else { continue }
            let baseSize = EmulatorLayoutGeometry.buttonSize(e, system: system,
                                                             isLandscape: isLandscape, deviceScale: k)
            let adj = EmulatorLayoutGeometry.ndsLandscapeAdjusted(
                element: e, isNDS: isNDS, isLandscape: isLandscape,
                center: CGPoint(x: container.width * bl.centerX, y: container.height * bl.centerY),
                size: baseSize, container: container.size, layout: layout, deviceScale: k)
            rects[e] = CGRect(x: container.minX + adj.center.x - adj.size.width / 2,
                              y: container.minY + adj.center.y - adj.size.height / 2,
                              width: adj.size.width, height: adj.size.height)
        }
        return (screen, container, rects)
    }

    /// Every (tablet, orientation) of the sweep.
    private var tabletWindows: [(name: String, size: CGSize, isLandscape: Bool)] {
        Self.tablets.flatMap { t in
            [(t.name, t.portrait, false), (t.name, onItsSide(t.portrait), true)]
        }
    }

    // MARK: - The phone side

    @Test func everyWindowHasOneFamily() {
        for (name, portrait) in Self.phones {
            #expect(LayoutFamily.of(portrait) == .phone, "\(name) upright is a phone window")
            #expect(LayoutFamily.of(onItsSide(portrait)) == .phone, "\(name) on its side is a phone window")
        }
        for (name, portrait) in Self.tablets {
            #expect(LayoutFamily.of(portrait) == .tablet, "\(name) upright is a tablet window")
            #expect(LayoutFamily.of(onItsSide(portrait)) == .tablet, "\(name) on its side is a tablet window")
        }
        // The boundary itself, and a Stage Manager window just under it.
        #expect(LayoutFamily.of(CGSize(width: 600, height: 1000)) == .tablet, "600 on the short side is a tablet")
        #expect(LayoutFamily.of(CGSize(width: 599, height: 1000)) == .phone, "599 on the short side is a phone")
        #expect(LayoutFamily.of(CGSize(width: 1000, height: 599)) == .phone, "the short side decides, not the width")
    }

    /// The phone clamp, written out as it was before the tablet family existed.
    @Test func phoneScaleIsTheOldFormula() {
        for (name, portrait) in Self.phones {
            for size in [portrait, onItsSide(portrait)] {
                let raw = min(min(size.width, size.height) / 393, max(size.width, size.height) / 852)
                let old = min(max(raw, 0.7), 1.25)
                let now = EmulatorLayoutGeometry.deviceScale(for: size)
                #expect(approx(now, old, tol: 0.0001), "\(name) \(size): scale \(now) was \(old)")
            }
        }
    }

    /// The two phone picture formulas a leaked tablet branch would break first:
    /// on its side the GBA picture is 74 % of the room between the panels (the
    /// width it shares with the GB), and upright it is capped at 45 % of the
    /// window. Checked with real insets, since the tablet page reads them.
    @Test func phonePicturesKeepTheirFormulas() {
        let insets: [(String, UIEdgeInsets, UIEdgeInsets)] = [
            ("iPhone SE", UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0), .zero),
            ("iPhone 14 Pro", UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
             UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
            ("iPhone 16 Pro Max", UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
             UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
        ]
        for (index, phone) in Self.phones.enumerated() {
            let (name, pInsets, lInsets) = insets[index]
            let side = onItsSide(phone.portrait)
            let k = EmulatorLayoutGeometry.deviceScale(for: side)
            let landscape = EmulatorLayoutGeometry.screenFrame(
                deviceSize: side, safeInsets: lInsets, hasTouchScreen: false, isLandscape: true,
                gameAspect: 240.0 / 160.0, system: .gba, controllerConnected: false, deviceScale: k)
            let availW = side.width - 2 * EmulatorLayoutGeometry.gbcLandscapePanel * k
            let shared = (availW / (240.0 / 160.0)) * (160.0 / 144.0)
            #expect(approx(landscape.width, shared), "\(name) on its side: GBA width \(landscape.width) was \(shared)")

            let kp = EmulatorLayoutGeometry.deviceScale(for: phone.portrait)
            let portrait = EmulatorLayoutGeometry.screenFrame(
                deviceSize: phone.portrait, safeInsets: pInsets, hasTouchScreen: false, isLandscape: false,
                gameAspect: 240.0 / 160.0, system: .gba, controllerConnected: false, deviceScale: kp)
            let capped = min(phone.portrait.width / (240.0 / 160.0), phone.portrait.height * 0.45)
            #expect(approx(portrait.height, capped), "\(name) upright: GBA height \(portrait.height) was \(capped)")
        }
    }

    // MARK: - The tablet side

    @Test func tabletScaleRunsInItsOwnRange() {
        for (name, portrait) in Self.tablets {
            for size in [portrait, onItsSide(portrait)] {
                let k = EmulatorLayoutGeometry.deviceScale(for: size)
                #expect(k >= EmulatorLayoutGeometry.tabletMinDeviceScale - 0.0001,
                        "\(name): scale \(k) is under the tablet floor")
                #expect(k <= EmulatorLayoutGeometry.tabletMaxDeviceScale + 0.0001,
                        "\(name): scale \(k) is over the tablet ceiling")
                #expect(k > EmulatorLayoutGeometry.maxDeviceScale - 0.0001,
                        "\(name): a tablet is never drawn at the phone ceiling or under it")
            }
        }
    }

    /// The invariant the tablet page rests on: `ControlLayoutDefaults` recomputes
    /// the picture with ZERO insets to place the row against it, so the picture
    /// must not move with the insets on its side, and must not change size
    /// upright (upright it starts under the real top inset, which is the one
    /// difference allowed). The DS upright is the exception on every family:
    /// its cap has always read the insets, and `ndsPortrait` never recomputes
    /// the picture, so nothing there depends on the equality.
    @Test func tabletFramesDoNotMoveWithTheInsets() {
        for system in Self.systems {
            for window in tabletWindows where !(system == .nds && !window.isLandscape) {
                let real = page(system: system, isLandscape: window.isLandscape,
                                deviceSize: window.size, insets: Self.tabletInsets).screen
                let zero = page(system: system, isLandscape: window.isLandscape,
                                deviceSize: window.size, insets: .zero).screen
                if window.isLandscape {
                    #expect(approx(real.minX, zero.minX) && approx(real.minY, zero.minY)
                            && approx(real.width, zero.width) && approx(real.height, zero.height),
                            "\(system) \(window.name) on its side: \(real) moved from \(zero) with the insets")
                } else {
                    #expect(approx(real.width, zero.width) && approx(real.height, zero.height),
                            "\(system) \(window.name) upright: \(real.size) is not \(zero.size) with the insets")
                }
            }
        }
    }

    @Test func tabletControlsDoNotOverlap() {
        for system in Self.systems {
            for window in tabletWindows {
                let rects = page(system: system, isLandscape: window.isLandscape,
                                 deviceSize: window.size, insets: Self.tabletInsets).rects
                let elements = Array(rects.keys)
                for i in 0..<elements.count {
                    for j in (i + 1)..<elements.count {
                        let e1 = elements[i], e2 = elements[j]
                        let depth = ButtonShape.penetration(ButtonShape.of(e1, rects[e1]!),
                                                            ButtonShape.of(e2, rects[e2]!))
                        let orientation = window.isLandscape ? "on its side" : "upright"
                        #expect(depth < 0.5,
                                "\(system) \(window.name) \(orientation): \(e1.rawValue) overlaps \(e2.rawValue) by \(depth)pt")
                    }
                }
            }
        }
    }

    @Test func tabletControlsStayInsideTheWindow() {
        for system in Self.systems {
            for window in tabletWindows {
                let bounds = CGRect(origin: .zero, size: window.size).insetBy(dx: -0.5, dy: -0.5)
                let rects = page(system: system, isLandscape: window.isLandscape,
                                 deviceSize: window.size, insets: Self.tabletInsets).rects
                for (e, r) in rects {
                    let orientation = window.isLandscape ? "on its side" : "upright"
                    #expect(bounds.contains(r),
                            "\(system) \(window.name) \(orientation): \(e.rawValue) at \(r) leaves the window \(window.size)")
                }
            }
        }
    }

    /// On its side every control lives in a gutter or under the picture; the
    /// DS keeps its L/R bars in the gutters beside its two screens.
    @Test func tabletLandscapeControlsNeverCoverThePicture() {
        for system in Self.systems {
            for (name, portrait) in Self.tablets {
                let size = onItsSide(portrait)
                let laid = page(system: system, isLandscape: true, deviceSize: size, insets: Self.tabletInsets)
                let screens: [(String, CGRect)]
                if system == .nds {
                    let pair = EmulatorLayoutGeometry.ndsLandscapeScreenRects(controlsContainer: laid.container.size)
                    screens = [("left", pair.left.offsetBy(dx: laid.container.minX, dy: laid.container.minY)),
                               ("touch", pair.touch.offsetBy(dx: laid.container.minX, dy: laid.container.minY))]
                } else {
                    screens = [("picture", laid.screen)]
                }
                for (e, r) in laid.rects {
                    for (label, screen) in screens {
                        let inter = r.intersection(screen)
                        #expect(inter.isNull || inter.width < 0.5 || inter.height < 0.5,
                                "\(system) \(name) on its side: \(e.rawValue) covers the \(label) by \(inter)")
                    }
                }
            }
        }
    }

    /// The single-screen consoles that stick SELECT · MENU · START under the
    /// picture get a band for it on a tablet; this is what proves the band is
    /// where the row lands. The SNES places its utility row by its own rule and
    /// is covered by the overlap and picture sweeps above.
    @Test func tabletLandscapeRowSitsUnderThePicture() {
        for system in [PresetSystem.gba, .gbc, .nes, .ps1] {
            for (name, portrait) in Self.tablets {
                let size = onItsSide(portrait)
                let laid = page(system: system, isLandscape: true, deviceSize: size, insets: Self.tabletInsets)
                for e in [ControlElement.btnSelect, .btnMenu, .btnStart] {
                    guard let r = laid.rects[e] else {
                        Issue.record("\(system) \(name): \(e.rawValue) has no default position")
                        continue
                    }
                    #expect(r.minY >= laid.screen.maxY - 0.5,
                            "\(system) \(name) on its side: \(e.rawValue) top \(r.minY) is above the picture's bottom \(laid.screen.maxY)")
                    #expect(r.maxY <= size.height - EmulatorLayoutGeometry.tabletLandscapeBottomReserve + 0.5,
                            "\(system) \(name) on its side: \(e.rawValue) bottom \(r.maxY) is in the indicator band")
                }
            }
        }
    }

    /// The reason the tablet page exists: the picture fills at least half the
    /// window's height on its side, where the phone page gave the 13-inch a
    /// picture two fifths as tall as its window.
    @Test func tabletLandscapePictureFillsHalfTheHeight() {
        for system in Self.systems where system != .nds {
            for (name, portrait) in Self.tablets {
                let size = onItsSide(portrait)
                let screen = page(system: system, isLandscape: true, deviceSize: size, insets: Self.tabletInsets).screen
                #expect(screen.height >= size.height * 0.5,
                        "\(system) \(name) on its side: the picture is \(screen.height) of \(size.height)")
                #expect(screen.minY >= EmulatorLayoutGeometry.tabletLandscapeTopReserve - 0.5,
                        "\(system) \(name) on its side: the picture starts at \(screen.minY), under the status bar")
            }
        }
    }

    /// Upright, the band under the picture is at least the 14 Pro's own band for
    /// that console, scaled: the pad is that page scaled, anchored to both ends
    /// of its band, and a shorter band closes the anchors on each other (Clip
    /// sat 58 points into A on the first sweep, when the reserve was flat).
    @Test func tabletPortraitPictureLeavesTheReserve() {
        for system in Self.systems where system != .nds {
            for (name, portrait) in Self.tablets {
                let k = EmulatorLayoutGeometry.deviceScale(for: portrait)
                let laid = page(system: system, isLandscape: false, deviceSize: portrait, insets: Self.tabletInsets)
                let band = portrait.height - laid.screen.maxY
                let promised = EmulatorLayoutGeometry.referencePortraitControlsHeight(
                    gameAspect: EmulatorLayoutGeometryTests.displayAspect(system), system: system) * k
                #expect(band >= promised - 0.5,
                        "\(system) \(name) upright: \(band) points under the picture, \(promised) promised")
                #expect(laid.screen.width <= portrait.width + 0.5 && laid.screen.minX >= -0.5,
                        "\(system) \(name) upright: the picture \(laid.screen) leaves the window")
            }
        }
    }

    /// The DS upright on a tablet keeps the 14 Pro's whole band under its
    /// screens, scaled (2026-09-08): the reserve alone left it seven percent
    /// short and closed the D-pad on the SELECT · START row, and the dress's
    /// slot-2 well, which lives between the two, needs twelve reference
    /// points of room and had two. Three facts pinned: the band, that it
    /// does not move with the insets, and the room the well asks for
    /// (`drawSlot2Well`: the side is twice the room, drawn above 24
    /// reference points).
    @Test func tabletDSUprightBandIsThePhonesScaled() {
        let reference = EmulatorLayoutGeometry.referenceNDSPortraitControlsHeight
        for (name, portrait) in Self.tablets {
            let k = EmulatorLayoutGeometry.deviceScale(for: portrait)
            let laid = page(system: .nds, isLandscape: false, deviceSize: portrait, insets: Self.tabletInsets)
            let band = portrait.height - laid.screen.maxY
            #expect(approx(band, reference * k),
                    "\(name) upright DS: a band of \(band) under the screens, \(reference * k) promised")
            let zero = page(system: .nds, isLandscape: false, deviceSize: portrait, insets: .zero)
            #expect(approx(portrait.height - zero.screen.maxY, band),
                    "\(name) upright DS: the band moves with the insets")
            guard let dpad = laid.rects[.dpad], let select = laid.rects[.btnSelect],
                  let start = laid.rects[.btnStart] else {
                Issue.record("\(name) upright DS: the pad or the SELECT · START row is missing")
                continue
            }
            let room = min(select.minY, start.minY) - 8 * k - dpad.maxY
            #expect(room > 12 * k,
                    "\(name) upright DS: \(room) points between the D-pad and the row, the slot-2 well needs more than \(12 * k)")
        }
    }

    /// The DS on its side: two screens side by side in the band, neither
    /// overlapping the other, both inside the window.
    @Test func tabletDSScreensSitSideBySide() {
        for (name, portrait) in Self.tablets {
            let size = onItsSide(portrait)
            let laid = page(system: .nds, isLandscape: true, deviceSize: size, insets: Self.tabletInsets)
            let pair = EmulatorLayoutGeometry.ndsLandscapeScreenRects(controlsContainer: laid.container.size)
            let left = pair.left.offsetBy(dx: laid.container.minX, dy: laid.container.minY)
            let touch = pair.touch.offsetBy(dx: laid.container.minX, dy: laid.container.minY)
            #expect(left.maxX <= touch.minX + 0.5, "\(name): the DS screens overlap each other")
            #expect(left.minX >= -0.5 && touch.maxX <= size.width + 0.5, "\(name): a DS screen leaves the window")
            #expect(approx(left.width / left.height, 4.0 / 3.0, tol: 0.02), "\(name): the left DS screen is not 4:3")
            #expect(left.height >= size.height * 0.4, "\(name): the DS screens are \(left.height) of \(size.height)")
        }
    }
}
