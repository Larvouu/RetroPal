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

    static let systems: [PresetSystem] = PresetSystem.allCases

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
            deviceSize: deviceSize, screenFrame: screen, hasTouchScreen: isNDS, isLandscape: isLandscape,
            system: system)
        let layout = ControlLayoutDefaults.defaultLayout(
            system: system, isLandscape: isLandscape, containerSize: container.size, scale: k,
            safeLeftInset: isLandscape ? insets.left : 0,
            safeRightInset: isLandscape ? insets.right : 0,
            family: LayoutFamily.of(deviceSize), deviceSize: deviceSize)
        var rects: [ControlElement: CGRect] = [:]
        for e in ControlElement.elements(for: system) {
            guard let bl = layout.buttons[e.rawValue], !bl.isHidden else { continue }
            // The size DRAWN, as the controls apply it (`n64PhoneScale`): the four
            // consoles added in 1.3.4 draw smaller on a tablet (`tabletThumbScale`).
            let table = EmulatorLayoutGeometry.buttonSize(e, system: system,
                                                          isLandscape: isLandscape, deviceScale: k)
            let drawn = ControlLayoutDefaults.n64PhoneScale(e, isLandscape: isLandscape,
                                                            family: LayoutFamily.of(deviceSize), system: system)
            let baseSize = CGSize(width: table.width * drawn, height: table.height * drawn)
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
                        let depth = ButtonShape.penetration(ButtonShape.of(e1, rects[e1]!, system: system),
                                                            ButtonShape.of(e2, rects[e2]!, system: system))
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
                } else if system == .n3ds {
                    // Its two screens side by side in the band (`ctrSideBySide`).
                    let pair = EmulatorMetalView.ctrSideBySideRects(in: laid.screen.size)
                    screens = [("top", pair.top.offsetBy(dx: laid.screen.minX, dy: laid.screen.minY)),
                               ("touch", pair.bottom.offsetBy(dx: laid.screen.minX, dy: laid.screen.minY))]
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
    ///
    /// OR it already takes the whole width between the two panels, which is the
    /// other bound the page sets (`tabletLandscapeScreenFrame`): a picture wider
    /// than 4:3 meets the panels before it reaches half the height. The PSP's
    /// 480:272 is the first such console (2026-10-09): on the 13-inch it is 800
    /// wide, the PlayStation's width, and 453 tall. A picture that is neither
    /// half the height nor the whole width still fails, which is the case this
    /// test was written for.
    ///
    /// The DS and the 3DS are not on this page: on their side their screens
    /// fill a band across the top (`screensBandAboveControls`).
    @Test func tabletLandscapePictureFillsHalfTheHeight() {
        for system in Self.systems where system != .nds && system != .n3ds {
            for (name, portrait) in Self.tablets {
                let size = onItsSide(portrait)
                let screen = page(system: system, isLandscape: true, deviceSize: size, insets: Self.tabletInsets).screen
                let k = EmulatorLayoutGeometry.deviceScale(for: size)
                let room = size.width - 2 * EmulatorLayoutGeometry.tabletLandscapePanel * k
                #expect(screen.height >= size.height * 0.5 || screen.width >= room - 0.5,
                        "\(system) \(name) on its side: the picture is \(screen.height) of \(size.height), \(screen.width) wide of \(room)")
                #expect(screen.minY >= EmulatorLayoutGeometry.tabletLandscapeTopReserve - 0.5,
                        "\(system) \(name) on its side: the picture starts at \(screen.minY), under the status bar")
            }
        }
    }

    /// Upright, the band under the picture is at least the 14 Pro's own band for
    /// that console, scaled: the pad is that page scaled, anchored to both ends
    /// of its band, and a shorter band closes the anchors on each other (Clip
    /// sat 58 points into A on the first sweep, when the reserve was flat).
    /// The Mega Drive has a page of its own on a tablet (`mdTablet`, 2026-10-08)
    /// that packs its controls into a band it computes, so it is held to THAT
    /// band, which is what lets its picture take the window's width.
    @Test func tabletPortraitPictureLeavesTheReserve() {
        for system in Self.systems where system != .nds {
            for (name, portrait) in Self.tablets {
                let k = EmulatorLayoutGeometry.deviceScale(for: portrait)
                let laid = page(system: system, isLandscape: false, deviceSize: portrait, insets: Self.tabletInsets)
                let band = portrait.height - laid.screen.maxY
                // The PSP sits its picture just above the band its own page
                // needs (asked 2026-10-11: the picture lower), as the Mega Drive does.
                let promised: CGFloat
                switch system {
                case .md:  promised = EmulatorLayoutGeometry.mdTabletPortraitControlsHeight(deviceScale: k)
                case .psp: promised = EmulatorLayoutGeometry.pspTabletPortraitControlsHeight(deviceScale: k)
                // The 3DS's own upright page (2026-10-20), the 14 Pro's band
                // scaled, less what its picture grew by (2026-11-01: the top
                // screen down to where CLIP began, twice that for the picture).
                case .n3ds:
                    let base = EmulatorLayoutGeometry.n3dsPortraitControlsHeight(deviceScale: k)
                    let clip = EmulatorLayoutGeometry.buttonSize(.btnClip, system: .n3ds, isLandscape: false,
                                                                 deviceScale: k).height
                    let old = portrait.height - EmulatorLayoutGeometry.tabletLandscapeTopReserve
                        - EmulatorLayoutGeometry.n3dsPortraitTopPadding * k - base
                    promised = base - 2 * max(0, old / 12 - clip / 2)
                default:
                    // The consoles whose picture grew upright (2026-11-01)
                    // give back to it what the band no longer needs
                    // (`EmulatorLayoutGeometry.tabletUprightGrowth`).
                    let aspect = EmulatorLayoutGeometryTests.displayAspect(system)
                    promised = EmulatorLayoutGeometry.referencePortraitControlsHeight(
                        gameAspect: aspect, system: system.layoutPage) * k
                        - EmulatorLayoutGeometry.tabletUprightGrowth(deviceSize: portrait, gameAspect: aspect,
                                                                    system: system, deviceScale: k)
                }
                #expect(band >= promised - 0.5,
                        "\(system) \(name) upright: \(band) points under the picture, \(promised) promised")
                #expect(laid.screen.width <= portrait.width + 0.5 && laid.screen.minX >= -0.5,
                        "\(system) \(name) upright: the picture \(laid.screen) leaves the window")
            }
        }
    }

    /// The upright iPad, a larger picture (asked 2026-11-01): six consoles
    /// grow their picture into the band the thumb rule emptied, and the page
    /// moves only what hangs from the picture. Measured against the page laid
    /// out under the old picture: every control that stays is where it was on
    /// the glass, every one that hangs came down exactly as far as the picture
    /// grew, and the picture is wider than it was without leaving the window.
    @Test func theUprightTabletPictureGrowsAndOnlyItsRowFollows() {
        let growing: [PresetSystem] = [.gba, .gbc, .gg, .sms, .ps1, .n64]
        for system in growing {
            let hanging = EmulatorLayoutGeometry.tabletUprightHangingControls(system)
            let aspect = EmulatorLayoutGeometryTests.displayAspect(system)
            for (name, portrait) in Self.tablets {
                let k = EmulatorLayoutGeometry.deviceScale(for: portrait)
                let now = page(system: system, isLandscape: false, deviceSize: portrait, insets: Self.tabletInsets)
                let growth = EmulatorLayoutGeometry.tabletUprightGrowth(
                    deviceSize: portrait, gameAspect: aspect, system: system, deviceScale: k)
                #expect(growth > 0, "\(system) \(name): the picture did not grow")
                // The page as it was: the old picture, its container, its page.
                guard let old = EmulatorLayoutGeometry.tabletUprightPreviousFrame(
                    deviceSize: portrait, safeInsets: Self.tabletInsets, gameAspect: aspect,
                    system: system, deviceScale: k) else { Issue.record("no old frame"); continue }
                #expect(approx(now.screen.height, old.height + growth),
                        "\(system) \(name): the picture is \(now.screen.height), \(old.height + growth) expected")
                #expect(now.screen.width > old.width + 0.5 && now.screen.width <= portrait.width + 0.5,
                        "\(system) \(name): the picture \(now.screen) is not wider inside the window")
                #expect(approx(now.screen.minY, old.minY), "\(system) \(name): the picture's top moved")
                let oldContainer = CGRect(x: 0, y: old.maxY, width: portrait.width, height: portrait.height - old.maxY)
                let before = ControlLayoutDefaults.classicPageThenThumbs(
                    system: system, containerSize: oldContainer.size, scale: k, deviceSize: portrait)
                for (e, rect) in now.rects {
                    guard let b = before.buttons[e.rawValue] else { continue }
                    let wasY = oldContainer.minY + b.centerY * oldContainer.height
                    let drop = EmulatorLayoutGeometry.tabletUprightRowDrop(system) * k
                    let expected = hanging.contains(e) ? wasY + growth + drop : wasY
                    #expect(approx(rect.midY, expected, tol: 1),
                            "\(system) \(name): \(e.rawValue) at y \(rect.midY), \(expected) expected")
                    #expect(approx(rect.midX, b.centerX * oldContainer.width, tol: 1),
                            "\(system) \(name): \(e.rawValue) moved sideways")
                }
            }
        }
    }

    /// The PlayStation upright on an iPad: CLIP on the shoulder row, between
    /// the L pair and MENU (his call, 2026-11-01), clear of both.
    @Test func thePlayStationClipJoinsItsShoulderRowOnAnUprightTablet() {
        for (name, portrait) in Self.tablets {
            let laid = page(system: .ps1, isLandscape: false, deviceSize: portrait, insets: Self.tabletInsets)
            guard let clip = laid.rects[.btnClip], let menu = laid.rects[.btnMenu],
                  let l2 = laid.rects[.btnL2] else { Issue.record("\(name): missing a control"); continue }
            #expect(approx(clip.midY, menu.midY), "PlayStation \(name): CLIP is not on MENU's line")
            #expect(clip.minX > l2.maxX && clip.maxX < menu.minX,
                    "PlayStation \(name): CLIP \(clip) is not between L2 \(l2) and MENU \(menu)")
        }
    }

    /// The Mega Drive upright on a tablet: the picture takes the window's
    /// whole width (asked 2026-10-08; the shared rule left it 595 points wide
    /// on a 744-point mini), and its own band still fits under it.
    @Test func megaDriveTabletPictureTakesTheWidth() {
        for (name, portrait) in Self.tablets {
            let laid = page(system: .md, isLandscape: false, deviceSize: portrait, insets: Self.tabletInsets)
            #expect(approx(laid.screen.width, portrait.width),
                    "Mega Drive \(name) upright: the picture is \(laid.screen.width) of \(portrait.width)")
        }
    }

    /// The six-button pad's X Y Z are smaller than its A B C (close
    /// photographs, 2026-10-08), on every page.
    @Test func megaDriveUpperRowIsSmaller() {
        for isLandscape in [false, true] {
            let lower = EmulatorLayoutGeometry.buttonSize(.btnA, system: .md, isLandscape: isLandscape,
                                                          deviceScale: 1)
            for element in ControlElement.mdUpperRow {
                let upper = EmulatorLayoutGeometry.buttonSize(element, system: .md,
                                                              isLandscape: isLandscape, deviceScale: 1)
                #expect(upper.width < lower.width,
                        "\(element.rawValue) is \(upper.width), A B C are \(lower.width)")
            }
        }
    }

    /// The 3DS on an iPad follows the tablet rule of the 1.3.4 consoles
    /// (asked 2026-10-29: priority and reach by the thumbs): the circle pad and
    /// A B X Y low and against their edges, on one thumb line, the cross above
    /// the circle pad, the C-stick above the diamond; and the circle pad DRAWN
    /// at its thumb size on its side, not grown to the band, where it met the
    /// cross. Before: 220 points above the bottom of an iPad mini upright, the
    /// cross 213 points in from the edge on its side.
    @Test func the3DSThumbClustersSitLowAndAtTheEdges() {
        for window in tabletWindows {
            let laid = page(system: .n3ds, isLandscape: window.isLandscape, deviceSize: window.size,
                            insets: Self.tabletInsets)
            let label = "\(window.name) \(window.isLandscape ? "on its side" : "upright")"
            guard let circle = laid.rects[.stickLeft], let cross = laid.rects[.dpad],
                  let a = laid.rects[.btnA], let b = laid.rects[.btnB], let c = laid.rects[.stickRight]
            else {
                Issue.record("\(label): a 3DS thumb control has no default position")
                continue
            }
            let k = EmulatorLayoutGeometry.deviceScale(for: window.size)
            let reach = 80 * k
            #expect(window.size.height - circle.maxY <= reach, "\(label): the circle pad is \(window.size.height - circle.maxY) above the bottom")
            #expect(window.size.height - b.maxY <= reach, "\(label): the diamond is \(window.size.height - b.maxY) above the bottom")
            #expect(circle.minX <= reach, "\(label): the circle pad is \(circle.minX) in from the left edge")
            #expect(window.size.width - a.maxX <= reach, "\(label): the diamond is \(window.size.width - a.maxX) in from the right edge")
            #expect(cross.maxY <= circle.minY + 0.5, "\(label): the cross is not above the circle pad")
            #expect(c.maxY <= a.minY + 0.5, "\(label): the C-stick is not above the diamond")
            if window.isLandscape {
                let table = EmulatorLayoutGeometry.buttonSize(.stickLeft, system: .n3ds, isLandscape: true, deviceScale: k)
                let drawn = ControlLayoutDefaults.n3dsLandscapeDrawnSize(
                    .stickLeft, size: circle.size, deviceSize: window.size, scale: k,
                    safeLeftInset: 0, safeRightInset: 0, family: .tablet)
                #expect(drawn == circle.size, "\(label): the circle pad is drawn at \(drawn), placed at \(circle.size)")
                #expect(circle.width < table.width, "\(label): the circle pad is not at its thumb size")
            }
        }
    }

    /// The six consoles shipped before 1.3.3 on an iPad (asked 2026-10-30, the
    /// rule of the N64's, the PSP's and the 3DS's pages): the cross and the
    /// faces low and against their edges, both ways up, drawn at a thumb's
    /// span. Before: 165 to 354 points above the bottom. The DS on its side
    /// keeps its own tall L and R bars at the edges, so its cross and faces
    /// stand beside them rather than at the glass's edge. Nothing drawn over
    /// anything else, on the app's own path at the drawn sizes.
    @Test func theOlderConsolesPutTheirThumbsAtTheEdges() {
        let consoles: [PresetSystem] = [.gba, .gbc, .nes, .snes, .nds, .ps1]
        for system in consoles {
            for window in tabletWindows {
                let size = window.size, isLandscape = window.isLandscape
                let geometry = PresetLayoutResolver.defaultGeometry(system: system, isLandscape: isLandscape,
                                                                    viewSize: size, safeInsets: Self.tabletInsets)
                let k = EmulatorLayoutGeometry.deviceScale(for: size)
                var drawn: [ControlElement: CGRect] = [:]
                for (e, v) in geometry.buttons {
                    let f = ControlLayoutDefaults.n64PhoneScale(e, isLandscape: isLandscape, family: .tablet, system: system)
                    var s = CGSize(width: v.baseSize.width * f, height: v.baseSize.height * f)
                    var x = v.center.x
                    if system == .nds {
                        let row = ControlLayoutDefaults.ndsBottomRow(e, isLandscape: isLandscape, deviceScale: k)
                        if let z = row.size { s = z }
                        x += row.dx
                    }
                    drawn[e] = CGRect(x: x - s.width / 2, y: v.center.y - s.height / 2, width: s.width, height: s.height)
                }
                let label = "\(system.rawValue) \(window.name) \(isLandscape ? "on its side" : "upright")"
                let left = [ControlElement.dpad, .stickLeft].compactMap { drawn[$0] }
                let right = [ControlElement.btnA, .btnB, .btnX, .btnY, .stickRight].compactMap { drawn[$0] }
                guard !left.isEmpty, !right.isEmpty else {
                    Issue.record("\(label): no thumb controls")
                    continue
                }
                let reach = 40 * k
                let besideBars = system == .nds && isLandscape
                let leftBottom = size.height - left.map(\.maxY).max()!
                let rightBottom = size.height - right.map(\.maxY).max()!
                #expect(leftBottom <= reach, "\(label): the cross is \(leftBottom) above the bottom")
                #expect(rightBottom <= reach, "\(label): the faces are \(rightBottom) above the bottom")
                let leftEdge = left.map(\.minX).min()!, rightEdge = size.width - right.map(\.maxX).max()!
                let edgeReach = besideBars ? 140 * k : reach
                #expect(leftEdge <= edgeReach, "\(label): the cross is \(leftEdge) in from the left edge")
                #expect(rightEdge <= edgeReach, "\(label): the faces are \(rightEdge) in from the right edge")
                let together: Set<ControlElement> = [.btnA, .btnB, .btnX, .btnY]
                let pairs: Set<Set<ControlElement>> = [[.stickLeft, .btnL3], [.stickRight, .btnR3]]
                let all = Array(drawn)
                for i in all.indices {
                    #expect(all[i].value.minX >= -0.5 && all[i].value.maxX <= size.width + 0.5
                            && all[i].value.maxY <= size.height + 0.5,
                            "\(label): \(all[i].key.rawValue) is off the window")
                    for j in all.indices where j > i {
                        let a = all[i].key, b = all[j].key
                        if together.contains(a) && together.contains(b) { continue }
                        if pairs.contains([a, b]) { continue }
                        let o = all[i].value.intersection(all[j].value)
                        #expect(o.isNull || o.width <= 0.5 || o.height <= 0.5,
                                "\(label): \(a.rawValue) and \(b.rawValue) are drawn over each other")
                    }
                }
            }
        }
    }

    /// The iPhone never takes the tablet pass: on every phone, both ways up,
    /// each of the six consoles' default page is its own page exactly, and
    /// every control is drawn at its table size.
    @Test func theOlderConsolesAreUnchangedOnThePhone() {
        for (name, portrait) in Self.phones {
            for isLandscape in [false, true] {
                let size = isLandscape ? onItsSide(portrait) : portrait
                #expect(LayoutFamily.of(size) == .phone, "\(name) is not a phone window")
                let k = EmulatorLayoutGeometry.deviceScale(for: size)
                let container = CGSize(width: size.width, height: size.height / 2)
                for system in ControlLayoutDefaults.classicTabletSystems {
                    let page = ControlLayoutDefaults.defaultLayout(
                        system: system, isLandscape: isLandscape, containerSize: container, scale: k,
                        family: .phone, deviceSize: size)
                    let own = ControlLayoutDefaults.classicPage(
                        system: system, isLandscape: isLandscape, containerSize: container, scale: k,
                        safeLeftInset: 0, safeRightInset: 0, family: .phone, deviceSize: size)
                    #expect(page == own, "\(system.rawValue) on \(name): the phone page was changed")
                    for e in ControlElement.elements(for: system) {
                        #expect(ControlLayoutDefaults.n64PhoneScale(e, isLandscape: isLandscape, family: .phone,
                                                                    system: system) == 1,
                                "\(system.rawValue) \(e.rawValue) drawn at another size on \(name)")
                    }
                }
            }
        }
    }

    /// The 3DS in the iPad windows smaller than the screen (split view at a
    /// third, a half and two thirds of each iPad, Stage Manager from its
    /// smallest): no two controls drawn over each other, none off the window,
    /// none on the screens but the bars that belong beside them. A tablet
    /// window keeps a full iPad's control sizes (`tabletMinDeviceScale`), and
    /// in these ZL covered CLIP, ZR covered MENU, MIC ran into the circle pad
    /// and START into Y (audit, 2026-10-30). Measured on the app's own path
    /// (`PresetLayoutResolver.defaultGeometry`, which passes the window size)
    /// at the drawn sizes. The four faces form one diamond and are not
    /// compared with each other.
    @Test func the3DSFitsTheSmallerIPadWindows() {
        var windows: [CGSize] = []
        for (_, p) in Self.tablets + [("iPad Air 11", CGSize(width: 820, height: 1180)),
                                      ("iPad 11", CGSize(width: 834, height: 1194))] {
            windows.append(contentsOf: [1.0 / 3, 0.5, 2.0 / 3].map { CGSize(width: (p.height - 10) * $0, height: p.width) })
            windows.append(contentsOf: [1.0 / 3, 2.0 / 3].map { CGSize(width: (p.width - 10) * $0, height: p.height) })
            for w in stride(from: CGFloat(600), through: p.height, by: 60) {
                for ratio: CGFloat in [0.66, 0.8, 1.0, 1.25, 1.5] where w * ratio <= p.height {
                    windows.append(CGSize(width: w, height: w * ratio))
                }
            }
        }
        let faces: Set<ControlElement> = [.btnA, .btnB, .btnX, .btnY]
        let bars: Set<ControlElement> = [.btnL, .btnR, .btnL2, .btnR2]
        var checked = 0
        for size in windows where LayoutFamily.of(size) == .tablet {
            let isLandscape = size.width > size.height
            let geometry = PresetLayoutResolver.defaultGeometry(system: .n3ds, isLandscape: isLandscape,
                                                                viewSize: size, safeInsets: Self.tabletInsets)
            let k = EmulatorLayoutGeometry.deviceScale(for: size)
            var drawn: [(ControlElement, CGRect)] = []
            for (e, v) in geometry.buttons {
                let f = ControlLayoutDefaults.n64PhoneScale(e, isLandscape: isLandscape, family: .tablet, system: .n3ds)
                var s = CGSize(width: v.baseSize.width * f, height: v.baseSize.height * f)
                if isLandscape {
                    s = ControlLayoutDefaults.n3dsLandscapeDrawnSize(e, size: s, deviceSize: size, scale: k,
                                                                      safeLeftInset: 0, safeRightInset: 0, family: .tablet)
                }
                drawn.append((e, CGRect(x: v.center.x - s.width / 2, y: v.center.y - s.height / 2,
                                        width: s.width, height: s.height)))
            }
            let label = "\(Int(size.width))×\(Int(size.height))"
            for i in drawn.indices {
                let (e, r) = drawn[i]
                #expect(r.minX >= -0.5 && r.maxX <= size.width + 0.5 && r.maxY <= size.height + 0.5,
                        "\(label): \(e.rawValue) is off the window")
                for j in drawn.indices where j > i && !(faces.contains(e) && faces.contains(drawn[j].0)) {
                    let o = r.intersection(drawn[j].1)
                    #expect(o.isNull || o.width <= 0.5 || o.height <= 0.5,
                            "\(label): \(e.rawValue) and \(drawn[j].0.rawValue) are drawn over each other")
                }
                if !bars.contains(e) {
                    for (screen, frame) in geometry.screens {
                        let o = frame.intersection(r)
                        #expect(o.isNull || o.width <= 0.5 || o.height <= 0.5,
                                "\(label): \(e.rawValue) is on the \(screen.rawValue) screen")
                    }
                }
            }
            checked += 1
        }
        #expect(checked > 100, "only \(checked) tablet windows swept")
    }

    /// The DS upright on a tablet keeps the 14 Pro's whole band under its
    /// screens, scaled (2026-09-08): the reserve alone left it seven percent
    /// short and closed the D-pad on the SELECT · START row, and the dress's
    /// slot-2 well, which lives between the two, needs twelve reference
    /// points of room and had two. Three facts pinned: the band, that it
    /// does not move with the insets, and the room the well asks for
    /// (`drawSlot2Well`, drawn above 24 reference points; since 2026-10-30
    /// over the row, the cross having moved down onto its line).
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
            // Since 2026-10-30 the cross sits on the row's own line on a tablet
            // (`thumbsToTheEdges`), and the well takes the band over the row,
            // under the lowest control above it (`drawSlot2Well`): the room is
            // measured there. Its side is two thirds of the room, drawn above 24.
            let rowTop = min(select.minY, start.minY) - 8 * k
            let x = select.union(start).midX
            let above = laid.rects.values
                .filter { $0.maxY < rowTop && $0.maxX > x - 40 * k && $0.minX < x + 40 * k }
                .map(\.maxY).max() ?? laid.screen.maxY
            let room = dpad.maxY > rowTop ? rowTop - above - 8 * k : rowTop - dpad.maxY
            #expect(room > 36 * k,
                    "\(name) upright DS: \(room) points for the slot-2 well over the row, it needs more than \(36 * k)")
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
