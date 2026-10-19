//
//  NewConsoleControlsAuditTests.swift
//  EmulateurGBATests
//
//  The controls audit of the four 1.3.4 consoles (Mega Drive, Master System,
//  Game Gear, PSP), 2026-10-10: touch controls, customisation and controllers.
//  Each test locks a defect found by the audit or a row that had no lock:
//
//  - the layout editor named the PSP's (and the PlayStation's) four faces
//    A, B, X and Y; the game draws their symbols;
//  - the PSP's on-glass shoulders printed L1 and R1 (the PlayStation's), and
//    its keyboard rows said A, B, X and Y;
//  - the remap footer told N64 and PSP players the stick drives the cross,
//    which it does not there;
//  - with a controller on an iPad held upright, MENU (the one control left)
//    sat on the grown picture on the PSP (13-inch) and the NES (all three);
//  - a preset seeded from each new page lands exactly on it, and saving it
//    moves nothing, with real safe-area insets;
//  - no default mapping binds a button the console lacks, and each console's
//    pad reaches every input its remap screen lists.
//
//  The real-inset overlap sweeps of the four default pages already live in
//  EmulatorLayoutGeometryTests and TabletLayoutTests.
//

import Testing
import UIKit
@testable import EmulateurGBA

struct NewConsoleControlsAuditTests {

    static let newConsoles: [PresetSystem] = [.md, .sms, .gg, .psp]

    /// Phones and iPads with the safe areas they really have, both ways up
    /// (portrait, landscape). The zero-inset sweeps miss what these catch.
    static let devices: [(name: String, portrait: CGSize, portraitInsets: UIEdgeInsets,
                          landscapeInsets: UIEdgeInsets)] = [
        ("iPhone SE", CGSize(width: 375, height: 667), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0), .zero),
        ("iPhone 13 mini", CGSize(width: 375, height: 812), UIEdgeInsets(top: 50, left: 0, bottom: 34, right: 0),
         UIEdgeInsets(top: 0, left: 50, bottom: 21, right: 50)),
        ("iPhone 14 Pro", CGSize(width: 393, height: 852), UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
         UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
        ("iPhone 16 Pro Max", CGSize(width: 440, height: 956), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
         UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
        ("iPad mini", CGSize(width: 744, height: 1133), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
         UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
        ("iPad 11-inch", CGSize(width: 834, height: 1210), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
         UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
        ("iPad 13-inch", CGSize(width: 1032, height: 1376), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
         UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
    ]

    static var windows: [(label: String, size: CGSize, insets: UIEdgeInsets, isLandscape: Bool)] {
        devices.flatMap { d in
            [("\(d.name) upright", d.portrait, d.portraitInsets, false),
             ("\(d.name) on its side", CGSize(width: d.portrait.height, height: d.portrait.width),
              d.landscapeInsets, true)]
        }
    }

    // MARK: - Names: editor, glass, remap, keyboard

    /// The editor names each face by the mark the game draws on it: the four
    /// symbols on both PlayStation pads, the same glyphs as the remap screen.
    @Test func theEditorNamesThePlayStationFamilysFacesBySymbol() {
        for system in [PresetSystem.ps1, .psp] {
            for (element, input) in [(ControlElement.btnA, RemappableInput.a), (.btnB, .b),
                                     (.btnX, .x), (.btnY, .y)] {
                #expect(element.displayName(for: system) == input.displayName(for: system),
                        "\(system) \(element.rawValue): the editor and the remap screen disagree")
            }
        }
        #expect(ControlElement.btnA.displayName(for: .psp) == "◯")
        #expect(ControlElement.btnB.displayName(for: .psp) == "✕")
        #expect(ControlElement.btnX.displayName(for: .psp) == "△")
        #expect(ControlElement.btnY.displayName(for: .psp) == "□")
        // One shoulder pair on the PSP: no number. The PlayStation's keep theirs.
        #expect(ControlElement.btnL.displayName(for: .psp) == "L")
        #expect(ControlElement.btnR.displayName(for: .psp) == "R")
        #expect(ControlElement.btnL.displayName(for: .ps1) == "L1")
        // The letter consoles are untouched.
        #expect(ControlElement.btnA.displayName(for: .snes) == "A")
        #expect(ControlElement.btnX.displayName(for: .nds) == "X")
    }

    /// Every element each new console's editor offers has a name of its own
    /// for that console, and the four sets carry nothing the pad lacks.
    @Test func eachEditorShowsThePadsOwnNames() {
        let expected: [PresetSystem: [ControlElement: String]] = [
            .md: [.btnY: "A", .btnA: "B", .btnB: "C", .btnL: "X", .btnX: "Y", .btnR: "Z",
                  .btnSelect: "Mode", .btnStart: "Start"],
            .sms: [.btnB: "1", .btnA: "2", .btnStart: "Pause"],
            .gg: [.btnB: "1", .btnA: "2", .btnStart: "Start"],
            .psp: [.btnA: "◯", .btnB: "✕", .btnX: "△", .btnY: "□", .btnL: "L", .btnR: "R",
                   .btnSelect: "Select", .btnStart: "Start", .stickLeft: "Analog Stick"],
        ]
        for (system, names) in expected {
            for (element, name) in names {
                #expect(ControlElement.elements(for: system).contains(element),
                        "\(system): \(element.rawValue) is not in its editor")
                #expect(element.displayName(for: system) == name,
                        "\(system) \(element.rawValue): \(element.displayName(for: system)), expected \(name)")
            }
        }
    }

    /// The labels drawn on the glass, read from the views: the PSP prints L
    /// and R (it showed the PlayStation's L1 and R1), the PlayStation keeps them.
    @MainActor
    @Test func thePSPsShouldersPrintLAndR() {
        func titles(_ system: PresetSystem, _ element: ControlElement) -> [String] {
            let controls = TouchControlsView.make(for: system)
            guard let view = controls.allButtonViews().first(where: { $0.0 == element })?.1 else { return [] }
            return labels(in: view)
        }
        #expect(titles(.psp, .btnL).contains("L"), "\(titles(.psp, .btnL))")
        #expect(titles(.psp, .btnR).contains("R"), "\(titles(.psp, .btnR))")
        #expect(!titles(.psp, .btnL).contains("L1"))
        #expect(titles(.ps1, .btnL).contains("L1"), "\(titles(.ps1, .btnL))")
        #expect(titles(.ps1, .btnR).contains("R1"), "\(titles(.ps1, .btnR))")
    }

    @MainActor
    private func labels(in view: UIView) -> [String] {
        var out: [String] = []
        if let l = view as? UILabel, let t = l.text { out.append(t) }
        if let b = view as? UIButton, let t = b.titleLabel?.text { out.append(t) }
        for sub in view.subviews { out += labels(in: sub) }
        return out
    }

    /// The keyboard page's rows read the pad page's marks on the four new
    /// consoles (the PSP's said A, B, X and Y), and are spoken by word.
    @Test func keyboardRowsReadThePadsMarks() {
        for system in Self.newConsoles {
            for input in KeyboardInput.buttons(on: system) {
                let pad = RemappableInput(rawValue: input.rawValue)
                #expect(pad != nil, "\(system) \(input.rawValue): no pad input")
                #expect(input.displayName(for: system) == pad?.displayName(for: system),
                        "\(system) \(input.rawValue): keyboard row \(input.displayName(for: system))")
                #expect(input.accessibleName(for: system) == pad?.accessibleName(for: system),
                        "\(system) \(input.rawValue): spoken \(input.accessibleName(for: system))")
            }
        }
        #expect(KeyboardInput.a.displayName(for: .psp) == "◯")
        #expect(KeyboardInput.a.accessibleName(for: .psp) == "Circle")
        // Directions keep their localized word everywhere.
        #expect(KeyboardInput.up.displayName(for: .psp) == KeyboardInput.up.displayName)
        // The consoles outside the rule keep their generic row labels.
        #expect(KeyboardInput.a.displayName(for: .gba) == "A")
    }

    /// The remap footer says what the stick does: on the N64 and the PSP it is
    /// the analog stick alone (`buttonMask` never folds it into the cross).
    @Test func theRemapFooterFollowsTheStickRule() {
        for system in PresetSystem.allCases {
            var s = ControllerInputSource()
            s.up = true
            let folds = ControllerManager.buttonMask(from: s, system: system) & GBAInput.up.rawValue != 0
            #expect(ControllerManager.stickIsAnalogOnly(on: system) == !folds,
                    "\(system): the footer's rule and the mask disagree")
        }
        #expect(ControllerManager.stickIsAnalogOnly(on: .psp))
        #expect(!ControllerManager.stickIsAnalogOnly(on: .md))
        #expect(!ControllerManager.stickIsAnalogOnly(on: .sms))
        #expect(!ControllerManager.stickIsAnalogOnly(on: .gg))
    }

    // MARK: - Presets and the editor

    /// A preset created for each new console opens on exactly the default page
    /// (same element set, same centres and sizes), and saving every component
    /// where it stands moves nothing: with real insets, on phones and iPads.
    @Test func aSeededPresetLandsOnTheDefaultPageAndSavingMovesNothing() {
        for system in Self.newConsoles {
            for w in Self.windows {
                let label = "\(system) \(w.label)"
                let preset = ControlPreset(name: "audit", systems: SystemApplicability(system: system))
                let scene = PresetLayoutResolver.resolve(preset: preset, system: system,
                                                         isLandscape: w.isLandscape,
                                                         viewSize: w.size, safeInsets: w.insets)
                let defaults = PresetLayoutResolver.defaultGeometry(
                    system: system, isLandscape: w.isLandscape, viewSize: w.size, safeInsets: w.insets)
                #expect(Set(scene.buttons.keys) == Set(ControlElement.elements(for: system)),
                        "\(label): \(scene.buttons.keys.map(\.rawValue).sorted())")
                for (element, control) in scene.buttons {
                    guard let d = defaults.buttons[element] else {
                        Issue.record("\(label): \(element.rawValue) has no default")
                        continue
                    }
                    #expect(hypot(control.center.x - d.center.x, control.center.y - d.center.y) < 0.5,
                            "\(label) \(element.rawValue): seeded \(control.center), default \(d.center)")
                }
                // Materialise every component at its spot, as the editor saves it.
                var layout = OrientationLayout()
                for (element, c) in scene.buttons {
                    layout.buttons[element.rawValue] = ButtonLayout(
                        centerX: c.center.x / w.size.width, centerY: c.center.y / w.size.height,
                        scale: 1, opacity: 0.5)
                }
                for (component, s) in scene.screens {
                    layout.screens[component.rawValue] = ScreenLayout(
                        centerX: s.frame.midX / w.size.width, centerY: s.frame.midY / w.size.height)
                }
                var saved = preset
                if w.isLandscape { saved.landscape = layout } else { saved.portrait = layout }
                let again = PresetLayoutResolver.resolve(preset: saved, system: system,
                                                         isLandscape: w.isLandscape,
                                                         viewSize: w.size, safeInsets: w.insets)
                for (element, c) in again.buttons {
                    guard let before = scene.buttons[element] else { continue }
                    #expect(hypot(c.center.x - before.center.x, c.center.y - before.center.y) < 0.5
                            && abs(c.baseSize.width - before.baseSize.width) < 0.5,
                            "\(label) \(element.rawValue): saving moved it")
                }
            }
        }
    }

    // MARK: - Controller-connected screen layout

    /// With a controller, MENU (the one control left) is never on the picture,
    /// never off the glass, and upright never under the home indicator, on any
    /// one-picture console, phones and iPads, real insets.
    @Test func controllerMenuStaysOffThePictureEverywhere() {
        for system in PresetSystem.allCases where system != .nds {
            for w in Self.windows {
                let label = "\(system) \(w.label)"
                let scene = PresetLayoutResolver.resolveController(
                    layout: ControllerLayout(), system: system, isLandscape: w.isLandscape,
                    viewSize: w.size, safeInsets: w.insets)
                guard let menu = scene.buttons[.btnMenu], let picture = scene.screens[.main]?.frame else {
                    Issue.record("\(label): no MENU or no picture")
                    continue
                }
                let rect = CGRect(x: menu.center.x - menu.baseSize.width / 2,
                                  y: menu.center.y - menu.baseSize.height / 2,
                                  width: menu.baseSize.width, height: menu.baseSize.height)
                let cover = rect.intersection(picture)
                #expect(cover.isNull || cover.width < 0.5 || cover.height < 0.5,
                        "\(label): MENU \(rect) covers the picture \(picture)")
                #expect(CGRect(origin: .zero, size: w.size).insetBy(dx: -0.5, dy: -0.5).contains(rect),
                        "\(label): MENU \(rect) leaves the glass")
                if !w.isLandscape, w.insets.bottom > 0 {
                    #expect(rect.maxY <= w.size.height - w.insets.bottom + 0.5,
                            "\(label): MENU \(rect) is under the home indicator")
                }
            }
        }
    }

    /// The upright rule moves MENU only when it sat on the picture, straight
    /// down to just under it; a clear MENU is left exactly where it is.
    @Test func controllerPortraitMenuRule() {
        let size = CGSize(width: 44, height: 44)
        let clear = CGPoint(x: 200, y: 700)
        #expect(EmulatorLayoutGeometry.controllerPortraitMenuCenter(
            current: clear, menuSize: size, pictureBottom: 600, containerHeight: 900,
            deviceScale: 1) == clear)
        let moved = EmulatorLayoutGeometry.controllerPortraitMenuCenter(
            current: CGPoint(x: 200, y: 590), menuSize: size, pictureBottom: 600,
            containerHeight: 900, deviceScale: 1)
        #expect(moved.x == 200)
        #expect(abs(moved.y - (600 + 8 + 22)) < 0.001)
        // Kept inside the container when the picture leaves no room below.
        let pinned = EmulatorLayoutGeometry.controllerPortraitMenuCenter(
            current: CGPoint(x: 200, y: 880), menuSize: size, pictureBottom: 895,
            containerHeight: 900, deviceScale: 1)
        #expect(abs(pinned.y - (900 - 8 - 22)) < 0.001)
    }

    /// The editor's controller layout starts from what the game shows: the
    /// seeded layout resolves to the pristine one on every window.
    @Test func aSeededControllerLayoutIsThePristineOne() {
        for system in Self.newConsoles {
            for d in Self.devices {
                let landscape = CGSize(width: d.portrait.height, height: d.portrait.width)
                let seeded = PresetLayoutResolver.seededControllerLayout(
                    system: system, portraitSize: d.portrait, portraitInsets: d.portraitInsets,
                    landscapeSize: landscape, landscapeInsets: d.landscapeInsets)
                for (size, insets, isLandscape) in [(d.portrait, d.portraitInsets, false),
                                                    (landscape, d.landscapeInsets, true)] {
                    let a = PresetLayoutResolver.resolveController(
                        layout: seeded, system: system, isLandscape: isLandscape,
                        viewSize: size, safeInsets: insets)
                    let b = PresetLayoutResolver.resolveController(
                        layout: ControllerLayout(), system: system, isLandscape: isLandscape,
                        viewSize: size, safeInsets: insets)
                    let ma = a.buttons[.btnMenu]?.center ?? .zero, mb = b.buttons[.btnMenu]?.center ?? .zero
                    #expect(hypot(ma.x - mb.x, ma.y - mb.y) < 0.5,
                            "\(system) \(d.name) \(isLandscape ? "landscape" : "portrait"): MENU \(ma) vs \(mb)")
                    let sa = a.screens[.main]?.frame ?? .null, sb = b.screens[.main]?.frame ?? .null
                    #expect(abs(sa.midX - sb.midX) < 0.5 && abs(sa.midY - sb.midY) < 0.5,
                            "\(system) \(d.name): picture \(sa) vs \(sb)")
                }
            }
        }
    }

    // MARK: - Controllers

    /// No default mapping binds a console input the console lacks, and every
    /// input the remap screen lists for the four has a default button.
    @Test func defaultMappingsBindExactlyThePadsInputs() {
        for system in PresetSystem.allCases {
            let available = Set(RemappableInput.available(on: system))
            let bound = Set(ControllerMapping.defaults(for: system).assignments.keys)
            #expect(bound.isSubset(of: available),
                    "\(system): binds \(bound.subtracting(available).map(\.rawValue).sorted())")
        }
        for system in Self.newConsoles {
            let available = Set(RemappableInput.available(on: system))
            let bound = Set(ControllerMapping.defaults(for: system).assignments.keys)
            #expect(bound == available,
                    "\(system): no default for \(available.subtracting(bound).map(\.rawValue).sorted())")
        }
    }

    /// The reset target presses what the built-in layout presses, button by
    /// button, on the four: a reset in the remap screen changes nothing a
    /// player already knows. (The built-in layout also gives SELECT to L3 on a
    /// pad without Options, which an explicit mapping does not carry.)
    @Test func theResetMappingIsTheBuiltInLayout() {
        let buttons: [WritableKeyPath<ControllerInputSource, Bool>] = [
            \.faceA, \.faceB, \.faceX, \.faceY, \.shoulderL, \.shoulderR, \.menu, \.options,
        ]
        for system in Self.newConsoles {
            let defaults = ControllerMapping.defaults(for: system)
            for button in buttons {
                var s = ControllerInputSource()
                s[keyPath: button] = true
                s.hasOptions = true
                let builtIn = ControllerManager.buttonMask(from: s, system: system)
                let mapped = ControllerManager.buttonMask(from: s, mapping: defaults, system: system)
                // Only the bits this console has: the built-in layout is one
                // table for every pad-shaped console and sends bits a console
                // without the button ignores (X, Y, L, R, SELECT on the
                // Master System), which a mapping has no row for.
                let has = RemappableInput.available(on: system).reduce(UInt32(0)) { $0 | $1.gbaInput.rawValue }
                #expect(builtIn & has == mapped,
                        "\(system) \(button): built-in \(builtIn), reset mapping \(mapped)")
            }
        }
    }

    /// Players: two pads on the Mega Drive and the Master System, one on the
    /// Game Gear and the PSP; the two-port bridges feed port 2.
    @Test func playersFollowThePorts() {
        #expect(PresetSystem.md.playerCount == 2)
        #expect(PresetSystem.sms.playerCount == 2)
        #expect(PresetSystem.gg.playerCount == 1)
        #expect(PresetSystem.psp.playerCount == 1)
        let selector = #selector(EmulatorBridge.setKeys(_:player:))
        #expect(BlastEmBridge.instancesRespond(to: selector))
        #expect(MesenBridge.instancesRespond(to: selector))
    }

    /// The Mega Drive's whole six-button pad is reachable from a controller
    /// with no mapping: A B C, X Y Z, START and MODE each from one button.
    @Test func theMegaDrivesSixButtonsAreAllReachable() {
        let buttons: [WritableKeyPath<ControllerInputSource, Bool>] = [
            \.faceA, \.faceB, \.faceX, \.faceY, \.shoulderL, \.shoulderR, \.menu, \.options,
        ]
        var reached: UInt32 = 0
        for button in buttons {
            var s = ControllerInputSource()
            s[keyPath: button] = true
            s.hasOptions = true
            reached |= ControllerManager.buttonMask(from: s, system: .md)
        }
        for input in RemappableInput.available(on: .md) {
            #expect(reached & input.gbaInput.rawValue != 0, "\(input.displayName(for: .md)) is unreachable")
        }
    }
}
