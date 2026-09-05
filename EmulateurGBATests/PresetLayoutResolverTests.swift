//
//  PresetLayoutResolverTests.swift
//  EmulateurGBATests
//
//  Locks the preset resolution rules that make custom layouts WYSIWYG:
//   - legacy (controls-container space) presets resolve to the exact same
//     on-screen spots the shipped 1.0 renderer gave them, including the
//     NDS-landscape render-time fix-ups;
//   - an empty / untouched layout resolves to the built-in default geometry,
//     so editing one orientation never changes the other;
//   - full-view-space components render exactly as placed (no fix-ups);
//   - per-component scale/opacity override the preset's legacy globals;
//   - Menu and Clip can never be hidden;
//   - the one-time legacy upgrade preserves every position.
//

import Testing
import UIKit
@testable import EmulateurGBA

@Suite("PresetLayoutResolver")
struct PresetLayoutResolverTests {

    static let proPortrait = CGSize(width: 393, height: 852)
    static let proLandscape = CGSize(width: 852, height: 393)
    static let sePortrait = CGSize(width: 375, height: 667)
    static let seLandscape = CGSize(width: 667, height: 375)

    static let allConfigs: [(PresetSystem, Bool, CGSize)] = [
        (.gba, false, proPortrait), (.gba, true, proLandscape),
        (.gbc, false, proPortrait), (.gbc, true, proLandscape),
        (.nds, false, proPortrait), (.nds, true, proLandscape),
        (.nds, true, seLandscape),  // the gutter-fit device case
    ]

    private func approx(_ a: CGFloat, _ b: CGFloat, tol: CGFloat = 0.01) -> Bool {
        abs(a - b) <= tol
    }

    private func approx(_ a: CGPoint, _ b: CGPoint, tol: CGFloat = 0.01) -> Bool {
        approx(a.x, b.x, tol: tol) && approx(a.y, b.y, tol: tol)
    }

    private func emptyPreset(_ system: PresetSystem) -> ControlPreset {
        ControlPreset(name: "t", systems: SystemApplicability(system: system))
    }

    /// A legacy preset seeded the way the pre-component editor did: the default
    /// layout's normalized positions stored in controls-container space.
    private func legacySeededPreset(system: PresetSystem, isLandscape: Bool,
                                    viewSize: CGSize) -> ControlPreset {
        let defaults = PresetLayoutResolver.defaultGeometry(
            system: system, isLandscape: isLandscape, viewSize: viewSize, safeInsets: .zero)
        let k = EmulatorLayoutGeometry.deviceScale(for: viewSize)
        let container = defaults.controlsFrame
        let layout = OrientationLayout(
            buttons: ControlLayoutDefaults.defaultLayout(
                system: system, isLandscape: isLandscape,
                containerSize: container.size, scale: k, safeLeftInset: 0).buttons,
            space: OrientationLayout.legacySpace)
        var preset = emptyPreset(system)
        if isLandscape { preset.landscape = layout } else { preset.portrait = layout }
        return preset
    }

    // MARK: - Defaults / untouched components

    @Test func emptyPresetResolvesToDefaultGeometry() {
        for (system, isLandscape, viewSize) in Self.allConfigs {
            let scene = PresetLayoutResolver.resolve(
                preset: emptyPreset(system), system: system, isLandscape: isLandscape,
                viewSize: viewSize, safeInsets: .zero)
            let defaults = PresetLayoutResolver.defaultGeometry(
                system: system, isLandscape: isLandscape, viewSize: viewSize, safeInsets: .zero)

            for element in ControlElement.elements(for: system) {
                let resolved = try! #require(scene.buttons[element])
                let fallback = try! #require(defaults.buttons[element])
                #expect(approx(resolved.center, fallback.center),
                        "\(system) \(isLandscape ? "landscape" : "portrait") \(element)")
                #expect(resolved.baseSize == fallback.baseSize)
                #expect(resolved.scale == 1.0)
                #expect(!resolved.isHidden)
            }
            for component in ScreenComponent.components(for: system) {
                let screen = try! #require(scene.screens[component])
                #expect(screen.frame == defaults.screens[component])
                #expect(screen.opacity == 1.0)
            }
        }
    }

    @Test func untouchedOrientationStaysDefaultWhenTheOtherIsEdited() {
        var preset = emptyPreset(.nds)
        // Heavy portrait edit; landscape never touched.
        preset.portrait = OrientationLayout(
            buttons: [ControlElement.btnA.rawValue: ButtonLayout(centerX: 0.5, centerY: 0.5,
                                                                 isHidden: true, scale: 1.4, opacity: 0.2)],
            screens: [ScreenComponent.top.rawValue: ScreenLayout(centerX: 0.5, centerY: 0.25, scale: 0.5)],
            space: OrientationLayout.fullViewSpace)

        let scene = PresetLayoutResolver.resolve(
            preset: preset, system: .nds, isLandscape: true,
            viewSize: Self.proLandscape, safeInsets: .zero)
        let defaults = PresetLayoutResolver.defaultGeometry(
            system: .nds, isLandscape: true, viewSize: Self.proLandscape, safeInsets: .zero)

        for element in ControlElement.elements(for: .nds) {
            let resolved = try! #require(scene.buttons[element])
            let fallback = try! #require(defaults.buttons[element])
            #expect(approx(resolved.center, fallback.center))
            #expect(!resolved.isHidden)
        }
        #expect(scene.screens[.top]?.frame == defaults.screens[.top])
        #expect(scene.screens[.bottom]?.frame == defaults.screens[.bottom])
    }

    // MARK: - Legacy parity

    @Test func legacySeededPresetMatchesDefaultGeometryEverywhere() {
        // A pre-component preset that was seeded with the defaults must land on
        // the exact same view-space spots the 1.0 preset renderer gave them —
        // the RAW (unpolished) geometry. This locks the container→view
        // conversion end to end, including the NDS-landscape gutter fit on the SE.
        for (system, isLandscape, viewSize) in Self.allConfigs {
            let preset = legacySeededPreset(system: system, isLandscape: isLandscape, viewSize: viewSize)
            let scene = PresetLayoutResolver.resolve(
                preset: preset, system: system, isLandscape: isLandscape,
                viewSize: viewSize, safeInsets: .zero)
            let defaults = PresetLayoutResolver.defaultGeometry(
                system: system, isLandscape: isLandscape, viewSize: viewSize,
                safeInsets: .zero, polished: false)

            for element in ControlElement.elements(for: system) {
                let resolved = try! #require(scene.buttons[element])
                let fallback = try! #require(defaults.buttons[element])
                #expect(approx(resolved.center, fallback.center),
                        "\(system) \(isLandscape ? "landscape" : "portrait") \(element)")
                #expect(resolved.baseSize == fallback.baseSize)
            }
        }
    }

    @Test func legacyOpacityAndScaleGlobalsStillApply() {
        var preset = legacySeededPreset(system: .gba, isLandscape: false, viewSize: Self.proPortrait)
        preset.opacity = 0.3
        preset.scale = 1.2
        let scene = PresetLayoutResolver.resolve(
            preset: preset, system: .gba, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)

        let a = try! #require(scene.buttons[.btnA])
        #expect(approx(a.opacity, 0.6))   // legacy ×2 mapping
        #expect(approx(a.scale, 1.2))
        let menu = try! #require(scene.buttons[.btnMenu])
        #expect(approx(menu.opacity, 0.6))

        // Low legacy opacity: Menu keeps its 0.5 floor, others the ×2 value.
        preset.opacity = 0.1
        let dim = PresetLayoutResolver.resolve(
            preset: preset, system: .gba, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        #expect(approx(try! #require(dim.buttons[.btnA]).opacity, 0.2))
        #expect(approx(try! #require(dim.buttons[.btnMenu]).opacity, 0.5))
    }

    // MARK: - Full-view space

    @Test func fullViewComponentsRenderExactlyAsPlaced() {
        // Park the NDS-landscape L bar dead-center — on a legacy preset the
        // gutter fit would move it; in full-view space it must stay put.
        var preset = emptyPreset(.nds)
        preset.landscape = OrientationLayout(
            buttons: [ControlElement.btnL.rawValue: ButtonLayout(centerX: 0.5, centerY: 0.5)],
            space: OrientationLayout.fullViewSpace)
        let scene = PresetLayoutResolver.resolve(
            preset: preset, system: .nds, isLandscape: true,
            viewSize: Self.seLandscape, safeInsets: .zero)
        let l = try! #require(scene.buttons[.btnL])
        #expect(approx(l.center, CGPoint(x: Self.seLandscape.width / 2,
                                         y: Self.seLandscape.height / 2)))
        #expect(l.baseSize == EmulatorLayoutGeometry.buttonSize(
            .btnL, isNDS: true, isLandscape: true,
            deviceScale: EmulatorLayoutGeometry.deviceScale(for: Self.seLandscape)))
    }

    @Test func perComponentScaleAndOpacityOverrideTheGlobals() {
        var preset = emptyPreset(.gba)
        preset.opacity = 0.25
        preset.scale = 1.0
        preset.portrait = OrientationLayout(
            buttons: [
                ControlElement.btnA.rawValue: ButtonLayout(centerX: 0.5, centerY: 0.5,
                                                           scale: 1.4, opacity: 0.9),
                ControlElement.btnB.rawValue: ButtonLayout(centerX: 0.3, centerY: 0.5),
            ],
            space: OrientationLayout.fullViewSpace)
        let scene = PresetLayoutResolver.resolve(
            preset: preset, system: .gba, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        let a = try! #require(scene.buttons[.btnA])
        #expect(approx(a.scale, 1.4))
        #expect(approx(a.opacity, 0.9))
        // No per-component values → the preset's legacy globals.
        let b = try! #require(scene.buttons[.btnB])
        #expect(approx(b.scale, 1.0))
        #expect(approx(b.opacity, 0.5))
    }

    @Test func storedScreenScalesAroundItsCenterPreservingAspect() {
        var preset = emptyPreset(.gba)
        preset.portrait = OrientationLayout(
            screens: [ScreenComponent.main.rawValue:
                        ScreenLayout(centerX: 0.5, centerY: 0.3, scale: 0.8, opacity: 0.7)],
            space: OrientationLayout.fullViewSpace)
        let scene = PresetLayoutResolver.resolve(
            preset: preset, system: .gba, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        let defaults = PresetLayoutResolver.defaultGeometry(
            system: .gba, isLandscape: false, viewSize: Self.proPortrait, safeInsets: .zero)
        let screen = try! #require(scene.screens[.main])
        let defaultRect = try! #require(defaults.screens[.main])
        #expect(approx(screen.frame.width, defaultRect.width * 0.8))
        #expect(approx(screen.frame.height, defaultRect.height * 0.8))
        #expect(approx(screen.frame.width / screen.frame.height,
                       defaultRect.width / defaultRect.height))
        #expect(approx(screen.frame.midX, Self.proPortrait.width * 0.5))
        #expect(approx(screen.frame.midY, Self.proPortrait.height * 0.3))
        #expect(approx(screen.opacity, 0.7))
    }

    // MARK: - Default-layout polish parity

    @Test func untouchedComponentsCarryTheDefaultLayoutPolish() {
        // The in-game default layout applies the wideSelectStart /
        // wideShoulders / ndsBigSelectStart refinements; an untouched preset
        // component must render with the same polished sizes, or a virgin
        // preset would visibly differ from the default layout.
        let k: CGFloat = 1   // 14 Pro

        // GBA: Select/Start 30% wider than the raw engine size.
        let gba = PresetLayoutResolver.resolve(
            preset: emptyPreset(.gba), system: .gba, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        let rawSelect = EmulatorLayoutGeometry.buttonSize(
            .btnSelect, isNDS: false, isLandscape: false, deviceScale: k)
        #expect(approx(try! #require(gba.buttons[.btnSelect]).baseSize.width,
                       rawSelect.width * 1.3))

        // NDS portrait: L/R 40% wider; Select/Start at the GBA component size.
        let nds = PresetLayoutResolver.resolve(
            preset: emptyPreset(.nds), system: .nds, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        let rawL = EmulatorLayoutGeometry.buttonSize(
            .btnL, isNDS: true, isLandscape: false, deviceScale: k)
        #expect(approx(try! #require(nds.buttons[.btnL]).baseSize.width, rawL.width * 1.4))
        #expect(try! #require(nds.buttons[.btnSelect]).baseSize
                == ControlElement.btnSelect.defaultSize)

        // GB/GBC: no polish flags; raw engine sizes.
        let gbc = PresetLayoutResolver.resolve(
            preset: emptyPreset(.gbc), system: .gbc, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        #expect(try! #require(gbc.buttons[.btnSelect]).baseSize
                == EmulatorLayoutGeometry.buttonSize(.btnSelect, isNDS: false,
                                                     isLandscape: false, deviceScale: k))
    }

    /// THE POLISH IS A MIRROR, NOT AN OPINION, AND ONE CONSOLE'S WAS NEITHER.
    ///
    /// `TouchControlsView.applyLayout` makes three render-time adjustments to the default
    /// layout, each behind a flag it computes from the system: `wideSelectStart`
    /// (`system == .gba`), `wideShoulders` (`isNDS && !isLandscape`) and `ndsBigSelectStart`
    /// (`isNDS`). `PresetLayoutResolver.defaultGeometry(polished:)` exists to reproduce
    /// exactly those and nothing else, because a new preset is SEEDED from that geometry and
    /// an untouched component resolves to it. Anything the resolver polishes and the game
    /// does not is a control that jumps the moment a player opens the editor.
    ///
    /// Which is what happened: the Super Nintendo, and then the PlayStation copying it, took
    /// the GBA's centre nudge WITHOUT its widening. The nudge is the second half of the
    /// widening — it keeps the inner edges still while the outer ones grow — so on its own it
    /// is a plain spread, and a fresh preset on either console opened with SELECT and START
    /// 19pt further apart than the built-in layout the player had been using. Shipped on the
    /// SNES in 1.2.5, found 2026-08-27.
    ///
    /// So this asserts the RULE, not the symptom: where the game's flags are all false,
    /// polishing is the identity; where they are not, it touches only the elements they name.
    @Test func polishMirrorsTheGamesOwnAdjustments() {
        let devices: [(String, CGSize, Bool)] = [
            ("14 Pro portrait", Self.proPortrait, false),
            ("14 Pro landscape", Self.proLandscape, true),
            ("SE portrait", Self.sePortrait, false),
            ("SE landscape", Self.seLandscape, true),
        ]
        for (label, size, isLandscape) in devices {
            func geometry(_ system: PresetSystem, polished: Bool)
                -> PresetLayoutResolver.DefaultGeometry {
                PresetLayoutResolver.defaultGeometry(
                    system: system, isLandscape: isLandscape, viewSize: size,
                    safeInsets: .zero, controllerConnected: false, polished: polished)
            }
            func differing(_ system: PresetSystem) -> Set<ControlElement> {
                let plain = geometry(system, polished: false)
                let polished = geometry(system, polished: true)
                var moved: Set<ControlElement> = []
                for (element, p) in polished.buttons {
                    guard let q = plain.buttons[element] else {
                        Issue.record("\(label) \(system): \(element.rawValue) is missing unpolished")
                        continue
                    }
                    if !approx(p.center, q.center)
                        || !approx(p.baseSize.width, q.baseSize.width)
                        || !approx(p.baseSize.height, q.baseSize.height) {
                        moved.insert(element)
                    }
                }
                return moved
            }

            // The game sets no flag for these four, so the resolver may not either.
            for system in [PresetSystem.gbc, .nes, .snes, .ps1] {
                let moved = differing(system)
                #expect(moved.isEmpty,
                        Comment(rawValue: "\(label) \(system): the resolver polishes "
                                          + "\(moved.map(\.rawValue).sorted()) and the game does "
                                          + "not, so a seeded preset would move them"))
            }
            // And the two that do adjust touch exactly what their flags name.
            #expect(differing(.gba) == [.btnSelect, .btnStart],
                    "\(label) gba: wideSelectStart covers SELECT and START, nothing else")
            let dsExpected: Set<ControlElement> = isLandscape
                ? [.btnSelect, .btnStart, .btnClip]
                : [.btnL, .btnR, .btnSelect, .btnStart, .btnClip, .btnMic]
            #expect(differing(.nds) == dsExpected,
                    "\(label) nds: the DS's own adjustments moved a control they do not name")
        }
    }

    @Test func materializingAFallbackComponentDoesNotMoveIt() {
        // Storing an untouched component at its resolved center (what the
        // editor does on first touch) must produce the exact same rectangle:
        // the polish shift is already in the fallback center, and the v2 base
        // size grows symmetrically around it.
        let defaults = PresetLayoutResolver.resolve(
            preset: emptyPreset(.gba), system: .gba, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        let fallback = try! #require(defaults.buttons[.btnSelect])

        var preset = emptyPreset(.gba)
        preset.portrait = OrientationLayout(
            buttons: [ControlElement.btnSelect.rawValue: ButtonLayout(
                centerX: fallback.center.x / Self.proPortrait.width,
                centerY: fallback.center.y / Self.proPortrait.height,
                scale: fallback.scale, opacity: fallback.opacity)],
            space: OrientationLayout.fullViewSpace)
        let scene = PresetLayoutResolver.resolve(
            preset: preset, system: .gba, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        let stored = try! #require(scene.buttons[.btnSelect])
        #expect(approx(stored.center, fallback.center))
        #expect(stored.baseSize == fallback.baseSize)
    }

    // MARK: - Containment (nothing ever leaves the device screen)

    @Test func storedComponentsNeverLeaveTheScreen() {
        // Corner-parked, oversized components: the resolver must cap the
        // screen's scale to the device and slide every frame back inside.
        var preset = emptyPreset(.gba)
        preset.portrait = OrientationLayout(
            buttons: [
                ControlElement.dpad.rawValue: ButtonLayout(centerX: 0.0, centerY: 1.0, scale: 1.5),
                ControlElement.btnA.rawValue: ButtonLayout(centerX: 1.0, centerY: 0.0),
            ],
            screens: [ScreenComponent.main.rawValue:
                        ScreenLayout(centerX: 0.05, centerY: 0.05, scale: 1.5)],
            space: OrientationLayout.fullViewSpace)
        let scene = PresetLayoutResolver.resolve(
            preset: preset, system: .gba, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        let bounds = CGRect(origin: .zero, size: Self.proPortrait).insetBy(dx: -0.01, dy: -0.01)

        // The GBA screen's default is nearly full width: 1.5x must be capped.
        let screen = try! #require(scene.screens[.main])
        #expect(bounds.contains(screen.frame))

        for (element, rc) in scene.buttons {
            let w = rc.baseSize.width * rc.scale
            let h = rc.baseSize.height * rc.scale
            let frame = CGRect(x: rc.center.x - w / 2, y: rc.center.y - h / 2, width: w, height: h)
            #expect(bounds.contains(frame), "\(element)")
        }
    }

    // MARK: - Menu / Clip protection

    @Test func menuAndClipCanNeverBeHidden() {
        var preset = emptyPreset(.gba)
        preset.portrait = OrientationLayout(
            buttons: [
                ControlElement.btnMenu.rawValue: ButtonLayout(centerX: 0.5, centerY: 0.1, isHidden: true),
                ControlElement.btnClip.rawValue: ButtonLayout(centerX: 0.9, centerY: 0.1, isHidden: true),
                ControlElement.btnA.rawValue: ButtonLayout(centerX: 0.8, centerY: 0.6, isHidden: true),
            ],
            space: OrientationLayout.fullViewSpace)
        let scene = PresetLayoutResolver.resolve(
            preset: preset, system: .gba, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        #expect(!(try! #require(scene.buttons[.btnMenu]).isHidden))
        #expect(!(try! #require(scene.buttons[.btnClip]).isHidden))
        #expect(try! #require(scene.buttons[.btnA]).isHidden)
    }

    // MARK: - Legacy upgrade

    @Test func upgradePreservesEveryPositionAndFillsComponentValues() {
        for (system, isLandscape, viewSize) in Self.allConfigs {
            var preset = legacySeededPreset(system: system, isLandscape: isLandscape, viewSize: viewSize)
            preset.opacity = 0.4
            preset.scale = 0.9
            let legacyScene = PresetLayoutResolver.resolve(
                preset: preset, system: system, isLandscape: isLandscape,
                viewSize: viewSize, safeInsets: .zero)

            let legacyLayout = isLandscape ? preset.landscape : preset.portrait
            let upgraded = PresetLayoutResolver.upgradedToFullView(
                legacyLayout, preset: preset, system: system, isLandscape: isLandscape,
                viewSize: viewSize, safeInsets: .zero)
            #expect(upgraded.space == OrientationLayout.fullViewSpace)

            var upgradedPreset = preset
            if isLandscape { upgradedPreset.landscape = upgraded }
            else { upgradedPreset.portrait = upgraded }
            let upgradedScene = PresetLayoutResolver.resolve(
                preset: upgradedPreset, system: system, isLandscape: isLandscape,
                viewSize: viewSize, safeInsets: .zero)

            for element in ControlElement.elements(for: system) {
                let before = try! #require(legacyScene.buttons[element])
                let after = try! #require(upgradedScene.buttons[element])
                // 2pt tolerance: on gutter-fit devices (SE landscape L/R) the
                // legacy render width differs from the v2 base width, so the
                // on-screen containment may slide the upgraded center by ~1pt.
                // Anything beyond that is a real conversion bug.
                #expect(approx(before.center, after.center, tol: 2.0),
                        "\(system) \(isLandscape ? "landscape" : "portrait") \(element)")
                #expect(approx(before.scale, after.scale))
                #expect(approx(before.opacity, after.opacity))
                #expect(before.isHidden == after.isHidden)
                // The upgrade writes explicit per-component values, detaching
                // the component from the legacy globals.
                let stored = try! #require(upgraded.buttons[element.rawValue])
                #expect(stored.scale != nil && stored.opacity != nil)
            }
        }
    }

    @Test func upgradeClearsHiddenFlagOnMenuAndClip() {
        var preset = emptyPreset(.gba)
        preset.portrait = OrientationLayout(
            buttons: [ControlElement.btnClip.rawValue:
                        ButtonLayout(centerX: 0.9, centerY: 0.2, isHidden: true)],
            space: OrientationLayout.legacySpace)
        let upgraded = PresetLayoutResolver.upgradedToFullView(
            preset.portrait, preset: preset, system: .gba, isLandscape: false,
            viewSize: Self.proPortrait, safeInsets: .zero)
        #expect(upgraded.buttons[ControlElement.btnClip.rawValue]?.isHidden == false)
    }

    // MARK: - Decode compatibility

    @Test func presetSavedBeforeComponentsStillDecodesAsLegacy() throws {
        // A 1.0-era OrientationLayout JSON: buttons + the removed NDS screen
        // sizes, no `space`/`screens` keys. Must decode as a legacy-space
        // layout with the stored buttons intact.
        let json = """
        {"buttons": {"btnA": {"centerX": 0.8, "centerY": 0.6, "isHidden": false}},
         "ndsTopScreenSize": "large", "ndsBottomScreenSize": "small"}
        """
        let layout = try JSONDecoder().decode(OrientationLayout.self, from: Data(json.utf8))
        #expect(layout.space == OrientationLayout.legacySpace)
        #expect(layout.screens.isEmpty)
        let a = try #require(layout.buttons[ControlElement.btnA.rawValue])
        #expect(approx(a.centerX, 0.8))
        #expect(a.scale == nil && a.opacity == nil)
    }

    // MARK: - NDS default screen rects

    @Test func ndsDefaultScreenRectsMatchTheEngineGutters() {
        // Landscape: the resolver's side-by-side pair must agree with the
        // geometry engine's screen rects (the ones the gutter-fit math uses).
        for viewSize in [Self.proLandscape, Self.seLandscape] {
            let defaults = PresetLayoutResolver.defaultGeometry(
                system: .nds, isLandscape: true, viewSize: viewSize, safeInsets: .zero)
            let container = defaults.controlsFrame
            let engine = EmulatorLayoutGeometry.ndsLandscapeScreenRects(
                controlsContainer: container.size)
            // Engine rects are in controls-container space; shift to view space.
            let top = try! #require(defaults.screens[.top])
            let bottom = try! #require(defaults.screens[.bottom])
            #expect(approx(top.minX, engine.left.minX + container.minX, tol: 0.5))
            #expect(approx(top.width, engine.left.width, tol: 0.5))
            #expect(approx(bottom.minX, engine.touch.minX + container.minX, tol: 0.5))
            #expect(approx(bottom.maxY, engine.touch.maxY + container.minY, tol: 0.5))
        }
    }
}
