//
//  PresetLayoutResolver.swift
//  EmulateurGBA
//
//  Single source of truth for what a custom control preset looks like on a
//  given device: it turns a ControlPreset into absolute, view-space frames for
//  EVERY component — the game screen(s) AND the controls — each with its own
//  size, opacity, and visibility.
//
//  Both consumers render exclusively from this resolver, so the editor preview
//  and the in-game layout cannot drift apart:
//   - EmulatorViewController (screens via Metal, controls via TouchControlsView)
//   - ControlLayoutEditorViewController (the drag-and-drop preview)
//
//  Coordinate spaces. Components are stored normalized; the layout's `space`
//  tag says relative to what:
//   - space == 2 (full-view): everything is normalized to the whole view. The
//     only space new edits are saved in. Stored components render EXACTLY as
//     placed — no render-time fix-ups — which is what makes the editor
//     pixel-faithful to the game.
//   - space == 1 (legacy): buttons are normalized to the old controls
//     container (below the default screen; the full view in GBA/GBC
//     landscape), and there are no stored screens. These presets predate
//     movable screens. They are converted here at resolve time, INCLUDING the
//     legacy render-time NDS-landscape adjustments (L/R gutter fit), so a
//     preset made before this system renders byte-identically to how 1.0 shipped it.
//
//  Components the preset does not store fall back to the built-in default for
//  this device, computed live (with the default path's device fix-ups), so an
//  untouched component always matches the default layout — editing portrait
//  never changes landscape, per the product rule.
//

import UIKit

enum PresetLayoutResolver {

    // MARK: - Output types

    /// A resolved game screen: final view-space frame (uniform `scale` already
    /// applied to the default size, display aspect preserved). Screens can
    /// never be hidden — only buttons can.
    struct ResolvedScreen: Equatable {
        let frame: CGRect
        let opacity: CGFloat
    }

    /// A resolved control. `baseSize` is the device-scaled engine size — the
    /// view's bounds; `scale` is the user's per-component visual scale, applied
    /// as a transform (NOT baked into the bounds) so labels, borders, and
    /// corner radii scale together exactly like the in-game controls.
    struct ResolvedControl: Equatable {
        let center: CGPoint
        let baseSize: CGSize
        let scale: CGFloat
        let opacity: CGFloat
        let isHidden: Bool
    }

    /// The complete resolved scene for one orientation on one device.
    struct ResolvedScene {
        var screens: [ScreenComponent: ResolvedScreen]
        var buttons: [ControlElement: ResolvedControl]
        var useJoystick: Bool
    }

    // MARK: - Tunables

    /// Per-component opacity bounds (direct alpha). The historic editor range
    /// (0.05–0.6, rendered ×2) maps inside this.
    static let minOpacity: CGFloat = 0.1
    static let maxOpacity: CGFloat = 1.0
    /// Per-component visual scale bounds for controls.
    static let minControlScale: CGFloat = 0.5
    static let maxControlScale: CGFloat = 1.5
    /// Per-component scale bounds for screens (relative to the default screen
    /// size on this device).
    static let minScreenScale: CGFloat = 0.3
    static let maxScreenScale: CGFloat = 1.5
    /// Default control opacity for new components (the legacy default 0.25
    /// rendered through the old ×2 mapping).
    static let defaultControlOpacity: CGFloat = 0.5

    /// NDS portrait stacked split (matches EmulatorMetalView's defaults).
    static let ndsDefaultTopRatio: CGFloat = 0.495
    static let ndsGapRatio: CGFloat = 0.01

    // MARK: - Default-layout polish (parity with applyDefaultLayout's flags)

    /// The in-game DEFAULT path applies three render-time refinements on top of
    /// the raw engine geometry (TouchControlsView.applyDefaultLayout's
    /// wideSelectStart / wideShoulders / ndsBigSelectStart flags): GBA
    /// Select/Start 30% wider, NDS-portrait L/R 40% wider, NDS Select/Start at
    /// the GBA component size with the bottom-row reflow. They are replicated
    /// here so an untouched preset component lands EXACTLY on the default
    /// layout. The SIZE part also defines the v2 preset base size (applied
    /// symmetrically at the stored center, so materializing a component never
    /// jumps); the CENTER shifts encode default-position pinning and apply to
    /// fallbacks only. Legacy presets keep the raw sizes 1.0 rendered them with.
    static func polishedSize(_ size: CGSize, element: ControlElement,
                             system: PresetSystem, isLandscape: Bool,
                             deviceScale k: CGFloat) -> CGSize {
        var size = size
        switch system {
        case .gba where element == .btnSelect || element == .btnStart:
            size.width *= 1.3
        case .nds:
            if !isLandscape, element == .btnL || element == .btnR {
                size.width *= 1.4
            }
            if element == .btnSelect || element == .btnStart {
                let ref = isLandscape ? ControlElement.btnSelect.defaultLandscapeSize
                                      : ControlElement.btnSelect.defaultSize
                size = CGSize(width: ref.width * k, height: ref.height * k)
            }
        default:
            break
        }
        return size
    }

    /// The base (unscaled) size of a v2 preset component on this device: the
    /// engine size with the default-layout polish folded in.
    static func presetBaseSize(element: ControlElement, system: PresetSystem,
                               isLandscape: Bool, deviceScale k: CGFloat) -> CGSize {
        polishedSize(
            EmulatorLayoutGeometry.buttonSize(element, system: system,
                                              isLandscape: isLandscape, deviceScale: k),
            element: element, system: system, isLandscape: isLandscape, deviceScale: k)
    }

    /// The polish's center shift for a DEFAULT-positioned component (the wide
    /// variants grow away from / toward the screen center so an edge stays
    /// pinned; the NDS bottom row reflows to keep its gaps even). `rawSize` is
    /// the pre-polish size the shift fractions are defined against.
    private static func polishCenterShift(element: ControlElement, system: PresetSystem,
                                          isLandscape: Bool, rawSize: CGSize,
                                          deviceScale k: CGFloat) -> CGFloat {
        switch system {
        case .gba:
            let extra = rawSize.width * 0.3
            if element == .btnSelect { return -extra / 2 }
            if element == .btnStart { return extra / 2 }
            return 0
        case .nds:
            if !isLandscape, element == .btnL || element == .btnR {
                let extra = rawSize.width * 0.4
                return element == .btnL ? extra / 2 : -extra / 2
            }
            if isLandscape {
                switch element {
                case .btnSelect: return -6 * k
                case .btnStart: return -2 * k
                case .btnClip: return -4 * k
                default: return 0
                }
            } else {
                switch element {
                case .btnSelect: return -6 * k
                case .btnStart: return 6 * k
                case .btnClip: return -12 * k
                case .btnMic: return 12 * k
                default: return 0
                }
            }
        case .snes, .ps1, .gbc, .nes:
            // NOTHING, and the two that used to nudge here were wrong to.
            //
            // This function is not a place to improve a layout. It is the MIRROR of the
            // adjustments `TouchControlsView.applyLayout` makes at render time, so that a
            // preset seeded from the default sits exactly where the default draws, and the
            // editor shows the page the player was just looking at. The GBA's nudge is half
            // of a pair: `wideSelectStart` widens SELECT and START by 30% and the nudge
            // moves each of them out by half that, so the INNER edges stay put and only the
            // outer ones grow. That flag is `system == .gba` and nothing else.
            //
            // The Super Nintendo and the PlayStation took the nudge without the widening,
            // which is not the same adjustment at all: it is a plain 9.6pt spread each way
            // at the reference scale, applied by the resolver and not by the game. So on
            // those two consoles a fresh custom preset opened with SELECT and START 19pt
            // further apart than the built-in layout the player had been using, which is the
            // one thing seeding promises never to do. Shipped on the SNES in 1.2.5 and
            // inherited by the PlayStation; found 2026-08-27 by reading the two paths
            // against each other, and locked by `polishMirrorsTheGamesOwnAdjustments`.
            //
            // If those two consoles' SELECT and START should be wider, that is a change to
            // the GAME (the flag, and `polishedSize` beside it), and it moves a layout that
            // was verified on device. It is not this function's to make on its own.
            return 0
        }
    }

    // MARK: - Containment (nothing ever leaves the device screen)

    /// The largest scale that keeps a screen of `defaultSize` fully on the
    /// device — the slider/pinch ceiling, and the resolve-time cap for stored
    /// data (so an oversized save can never render wider than the iPhone).
    static func maxFittingScreenScale(defaultSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard defaultSize.width > 0, defaultSize.height > 0 else { return maxScreenScale }
        return min(maxScreenScale,
                   viewSize.width / defaultSize.width,
                   viewSize.height / defaultSize.height)
    }

    /// Clamps a component's center so its full frame (of `size`) stays inside
    /// the view — components slide along the edges instead of leaving the
    /// screen. Applied to every STORED component at resolve time (stored data
    /// may predate this rule or come from a different-shaped device); the
    /// built-in defaults are engine-verified and pass through untouched.
    static func clampedCenter(_ center: CGPoint, size: CGSize, viewSize: CGSize) -> CGPoint {
        let halfW = min(size.width, viewSize.width) / 2
        let halfH = min(size.height, viewSize.height) / 2
        return CGPoint(x: min(max(center.x, halfW), viewSize.width - halfW),
                       y: min(max(center.y, halfH), viewSize.height - halfH))
    }

    // MARK: - Controller layout

    /// Menu's floor while a controller is connected: it is the ONLY on-screen
    /// way back to the pause menu there, so it may be moved and resized but
    /// never shrunk below a comfortable tap target. Mirrors the engine's own
    /// `minButtonDimension` rather than inventing a second number.
    static let minControllerMenuDimension: CGFloat = EmulatorLayoutGeometry.minButtonDimension

    /// Resolves a controller layout into absolute view-space frames.
    ///
    /// Only the screens and Menu exist here. A pristine layout (nothing stored)
    /// resolves to exactly `defaultGeometry(controllerConnected: true)`, i.e.
    /// byte-for-byte what the app renders today — that identity is what the
    /// regression test locks, and it is why enabling the feature cannot affect
    /// anyone who never customises it.
    static func resolveController(layout: ControllerLayout, system: PresetSystem,
                                  isLandscape: Bool, viewSize: CGSize,
                                  safeInsets: UIEdgeInsets) -> ResolvedScene {
        let stored = layout.layout(isLandscape: isLandscape)
        let defaults = defaultGeometry(system: system, isLandscape: isLandscape,
                                       viewSize: viewSize, safeInsets: safeInsets,
                                       controllerConnected: true)

        var screens: [ScreenComponent: ResolvedScreen] = [:]
        for component in ScreenComponent.components(for: system) {
            guard let defaultRect = defaults.screens[component] else { continue }
            guard stored.space == OrientationLayout.fullViewSpace,
                  let s = stored.screens[component.rawValue] else {
                screens[component] = ResolvedScreen(frame: defaultRect, opacity: 1)
                continue
            }
            let scale = clamp(s.scale, minScreenScale,
                              maxFittingScreenScale(defaultSize: defaultRect.size,
                                                    viewSize: viewSize))
            let size = CGSize(width: defaultRect.width * scale,
                              height: defaultRect.height * scale)
            let center = clampedCenter(CGPoint(x: s.centerX * viewSize.width,
                                               y: s.centerY * viewSize.height),
                                       size: size, viewSize: viewSize)
            screens[component] = ResolvedScreen(frame: rect(center: center, size: size),
                                                opacity: clamp(s.opacity, minOpacity, maxOpacity))
        }

        // Menu only. Never hidden: `isHidden` is not even read here, so a value
        // arriving from hand-edited storage cannot lock the player out.
        var buttons: [ControlElement: ResolvedControl] = [:]
        let element = ControllerLayout.element
        if let def = defaults.buttons[element] {
            let baseSize = def.baseSize
            let stored2 = stored.buttons[element.rawValue]
            let rawScale = clamp(stored2?.scale ?? 1, minControlScale, maxControlScale)
            // Floor the RENDERED size, not the stored scale, so the guarantee
            // holds on every device rather than only on the reference one.
            //
            // The floor per axis is `min(44, thatAxis'\''s own base)`, mirroring the
            // engine's `buttonSize` semantics exactly. A flat 44 would INFLATE
            // Menu on NDS, whose reference size is a deliberate 36, and the
            // pristine layout would then stop matching what the app renders
            // today. In practice this means Menu can be enlarged and moved but
            // not shrunk below its default: it is the only on-screen way back
            // to the pause menu with a controller attached.
            let floorW = min(minControllerMenuDimension, baseSize.width)
            let floorH = min(minControllerMenuDimension, baseSize.height)
            let floorScale = max(floorW / max(baseSize.width, 1),
                                 floorH / max(baseSize.height, 1))
            let scale = max(rawScale, min(floorScale, maxControlScale))
            let rendered = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
            let center: CGPoint
            if let stored2, stored.space == OrientationLayout.fullViewSpace {
                center = clampedCenter(CGPoint(x: stored2.centerX * viewSize.width,
                                               y: stored2.centerY * viewSize.height),
                                       size: rendered, viewSize: viewSize)
            } else {
                center = def.center
            }
            buttons[element] = ResolvedControl(
                center: center, baseSize: baseSize, scale: scale,
                opacity: clamp(stored2?.opacity ?? 1, minOpacity, maxOpacity),
                isHidden: false)
        }
        return ResolvedScene(screens: screens, buttons: buttons, useJoystick: false)
    }

    /// Seeds a controller layout from the current default geometry, so the
    /// editor opens on exactly what the player already sees instead of on an
    /// arbitrary arrangement.
    ///
    /// EACH ORIENTATION BRINGS ITS OWN VIEWPORT, and that is the whole reason
    /// this takes four arguments instead of two. A stored layout is normalized
    /// against the viewport it was seeded in, and the two orientations do not
    /// share one: seeding both from whichever viewport happened to be on screen
    /// would write a landscape layout measured inside a portrait box, then
    /// denormalize it against the real landscape viewport on the first rotation
    /// and put the screen somewhere nobody chose. The insets differ per
    /// orientation too, so they are passed in pairs as well.
    static func seededControllerLayout(system: PresetSystem,
                                       portraitSize: CGSize, portraitInsets: UIEdgeInsets,
                                       landscapeSize: CGSize,
                                       landscapeInsets: UIEdgeInsets) -> ControllerLayout {
        func orientation(_ isLandscape: Bool) -> OrientationLayout {
            let viewSize = isLandscape ? landscapeSize : portraitSize
            let safeInsets = isLandscape ? landscapeInsets : portraitInsets
            let d = defaultGeometry(system: system, isLandscape: isLandscape,
                                    viewSize: viewSize, safeInsets: safeInsets,
                                    controllerConnected: true)
            var screens: [String: ScreenLayout] = [:]
            for c in ScreenComponent.components(for: system) {
                guard let r = d.screens[c] else { continue }
                screens[c.rawValue] = ScreenLayout(centerX: r.midX / viewSize.width,
                                                  centerY: r.midY / viewSize.height,
                                                  scale: 1, opacity: 1)
            }
            var buttons: [String: ButtonLayout] = [:]
            if let m = d.buttons[ControllerLayout.element] {
                buttons[ControllerLayout.element.rawValue] = ButtonLayout(
                    centerX: m.center.x / viewSize.width,
                    centerY: m.center.y / viewSize.height,
                    isHidden: false, scale: 1, opacity: 1)
            }
            return OrientationLayout(buttons: buttons, screens: screens,
                                     space: OrientationLayout.fullViewSpace)
        }
        return ControllerLayout(portrait: orientation(false), landscape: orientation(true))
    }

    // MARK: - Resolve

    /// Resolves the preset's layout for one orientation into absolute view-space
    /// frames for every screen and control of `system`.
    static func resolve(preset: ControlPreset, system: PresetSystem, isLandscape: Bool,
                        viewSize: CGSize, safeInsets: UIEdgeInsets) -> ResolvedScene {
        let layout = isLandscape ? preset.landscape : preset.portrait
        let k = EmulatorLayoutGeometry.deviceScale(for: viewSize)
        let isNDS = (system == .nds)
        let defaults = defaultGeometry(system: system, isLandscape: isLandscape,
                                       viewSize: viewSize, safeInsets: safeInsets)

        // Screens.
        var screens: [ScreenComponent: ResolvedScreen] = [:]
        for component in ScreenComponent.components(for: system) {
            guard let defaultRect = defaults.screens[component] else { continue }
            if layout.space == OrientationLayout.fullViewSpace,
               let stored = layout.screens[component.rawValue] {
                let scale = clamp(stored.scale, minScreenScale,
                                  maxFittingScreenScale(defaultSize: defaultRect.size,
                                                        viewSize: viewSize))
                let size = CGSize(width: defaultRect.width * scale,
                                  height: defaultRect.height * scale)
                let center = clampedCenter(
                    CGPoint(x: stored.centerX * viewSize.width,
                            y: stored.centerY * viewSize.height),
                    size: size, viewSize: viewSize)
                screens[component] = ResolvedScreen(
                    frame: rect(center: center, size: size),
                    opacity: clamp(stored.opacity, minOpacity, maxOpacity))
            } else {
                screens[component] = ResolvedScreen(frame: defaultRect, opacity: 1)
            }
        }

        // Controls.
        var buttons: [ControlElement: ResolvedControl] = [:]
        for element in ControlElement.elements(for: system) {
            let baseSize = EmulatorLayoutGeometry.buttonSize(
                element, system: system, isLandscape: isLandscape, deviceScale: k)

            if let stored = layout.buttons[element.rawValue] {
                let resolved: ResolvedControl
                let scale = clamp(stored.scale ?? preset.scale, minControlScale, maxControlScale)
                let opacity = clamp(stored.opacity ?? legacyAlpha(preset.opacity, element: element),
                                    minOpacity, maxOpacity)
                if layout.space == OrientationLayout.fullViewSpace {
                    // Stored in view space: rendered as placed, kept fully
                    // on-screen (the scaled frame slides along the edges). The
                    // base size carries the default-layout polish, symmetric
                    // at the stored center.
                    let polishedBase = presetBaseSize(element: element, system: system,
                                                      isLandscape: isLandscape, deviceScale: k)
                    let scaledSize = CGSize(width: polishedBase.width * scale,
                                            height: polishedBase.height * scale)
                    resolved = ResolvedControl(
                        center: clampedCenter(
                            CGPoint(x: stored.centerX * viewSize.width,
                                    y: stored.centerY * viewSize.height),
                            size: scaledSize, viewSize: viewSize),
                        baseSize: polishedBase,
                        scale: scale,
                        opacity: opacity,
                        isHidden: hidden(stored.isHidden, element: element))
                } else {
                    // Legacy controls-container space: convert, keeping the old
                    // render-time NDS-landscape fix-ups for exact 1.0 parity,
                    // then the same on-screen containment.
                    let containerCenter = CGPoint(
                        x: stored.centerX * defaults.controlsFrame.width,
                        y: stored.centerY * defaults.controlsFrame.height)
                    let adj = EmulatorLayoutGeometry.ndsLandscapeAdjusted(
                        element: element, isNDS: isNDS, isLandscape: isLandscape,
                        center: containerCenter, size: baseSize,
                        container: defaults.controlsFrame.size,
                        layout: layout, deviceScale: k)
                    let scaledSize = CGSize(width: adj.size.width * scale,
                                            height: adj.size.height * scale)
                    resolved = ResolvedControl(
                        center: clampedCenter(
                            CGPoint(x: defaults.controlsFrame.minX + adj.center.x,
                                    y: defaults.controlsFrame.minY + adj.center.y),
                            size: scaledSize, viewSize: viewSize),
                        baseSize: adj.size,
                        scale: scale,
                        opacity: opacity,
                        isHidden: hidden(stored.isHidden, element: element))
                }
                buttons[element] = resolved
            } else if let fallback = defaults.buttons[element] {
                // Untouched component: the built-in default for this device,
                // with the preset's legacy global opacity/scale (which are the
                // standard defaults on presets that never set them).
                buttons[element] = ResolvedControl(
                    center: fallback.center,
                    baseSize: fallback.baseSize,
                    scale: clamp(preset.scale, minControlScale, maxControlScale),
                    opacity: clamp(legacyAlpha(preset.opacity, element: element),
                                   minOpacity, maxOpacity),
                    isHidden: false)
            }
        }

        return ResolvedScene(screens: screens, buttons: buttons, useJoystick: preset.useJoystick)
    }

    // MARK: - Default geometry (shared by resolve fallbacks, seeding, and reset)

    /// The built-in default geometry for a system + orientation on this device:
    /// screen rect(s), the legacy controls container, and every control's
    /// default center/size in VIEW space (NDS-landscape device fix-ups applied).
    /// `polished` folds in the default-layout polish flags, making the result
    /// pixel-equal to the in-game default layout — what fallbacks and the
    /// editor want. `polished: false` is the RAW geometry the legacy (1.0)
    /// preset renderer used, kept for its exact-parity conversion.
    struct DefaultGeometry {
        let screens: [ScreenComponent: CGRect]
        let controlsFrame: CGRect
        let buttons: [ControlElement: (center: CGPoint, baseSize: CGSize)]
    }

    /// `controllerConnected` selects which geometry family to describe: the
    /// touch layout (screens leave room for the on-screen controls) or the
    /// controller layout (controls hide, screens fill the reclaimed space and
    /// only Menu remains, in its strip). Passed straight through to the engine
    /// rather than reimplemented, so the controller default cannot drift from
    /// what the game actually renders.
    static func defaultGeometry(system: PresetSystem, isLandscape: Bool,
                                viewSize: CGSize, safeInsets: UIEdgeInsets,
                                controllerConnected: Bool = false,
                                polished: Bool = true) -> DefaultGeometry {
        let k = EmulatorLayoutGeometry.deviceScale(for: viewSize)
        let isNDS = (system == .nds)
        let metalFrame = EmulatorLayoutGeometry.screenFrame(
            deviceSize: viewSize, safeInsets: safeInsets,
            hasTouchScreen: isNDS, isLandscape: isLandscape,
            gameAspect: displayAspect(system), system: system,
            controllerConnected: controllerConnected, deviceScale: k)
        let controlsFrame = EmulatorLayoutGeometry.controlsFrame(
            deviceSize: viewSize, screenFrame: metalFrame,
            hasTouchScreen: isNDS, isLandscape: isLandscape)

        var screens: [ScreenComponent: CGRect] = [:]
        if isNDS {
            let (top, bottom) = ndsDefaultScreenRects(in: metalFrame, isLandscape: isLandscape)
            screens[.top] = top
            screens[.bottom] = bottom
        } else {
            screens[.main] = metalFrame
        }

        let defaultLayout = ControlLayoutDefaults.defaultLayout(
            system: system, isLandscape: isLandscape,
            containerSize: controlsFrame.size, scale: k,
            safeLeftInset: safeInsets.left, safeRightInset: safeInsets.right,
            family: LayoutFamily.of(viewSize))

        var buttons: [ControlElement: (center: CGPoint, baseSize: CGSize)] = [:]
        for element in ControlElement.elements(for: system) {
            guard let bl = defaultLayout.buttons[element.rawValue] else { continue }
            let baseSize = EmulatorLayoutGeometry.buttonSize(
                element, system: system, isLandscape: isLandscape, deviceScale: k)
            let containerCenter = CGPoint(x: bl.centerX * controlsFrame.width,
                                          y: bl.centerY * controlsFrame.height)
            let adj = EmulatorLayoutGeometry.ndsLandscapeAdjusted(
                element: element, isNDS: isNDS, isLandscape: isLandscape,
                center: containerCenter, size: baseSize,
                container: controlsFrame.size, layout: defaultLayout, deviceScale: k)
            var center = CGPoint(x: controlsFrame.minX + adj.center.x,
                                 y: controlsFrame.minY + adj.center.y)
            var size = adj.size
            if polished {
                center.x += polishCenterShift(element: element, system: system,
                                              isLandscape: isLandscape, rawSize: size,
                                              deviceScale: k)
                size = polishedSize(size, element: element, system: system,
                                    isLandscape: isLandscape, deviceScale: k)
            }
            buttons[element] = (center, size)
        }

        return DefaultGeometry(screens: screens, controlsFrame: controlsFrame, buttons: buttons)
    }

    /// The two NDS screen sub-rects within the combined metal frame, in physical
    /// order (top, bottom) — rendered left/right in landscape. Mirrors the Metal
    /// view's default vertex split exactly (stacked 49.5/49.5 + 1% gap, or
    /// side-by-side aspect-fit pair touching at the middle).
    static func ndsDefaultScreenRects(in metalFrame: CGRect,
                                      isLandscape: Bool) -> (top: CGRect, bottom: CGRect) {
        let aspect = EmulatorLayoutGeometry.ndsScreenAspect
        if isLandscape {
            var w = metalFrame.width / 2.0
            var h = w / aspect
            if h > metalFrame.height { h = metalFrame.height; w = h * aspect }
            let y = metalFrame.minY + (metalFrame.height - h) / 2.0
            return (CGRect(x: metalFrame.midX - w, y: y, width: w, height: h),
                    CGRect(x: metalFrame.midX, y: y, width: w, height: h))
        } else {
            let topRatio = ndsDefaultTopRatio
            let botRatio = 1.0 - topRatio - ndsGapRatio
            let topBandH = metalFrame.height * topRatio
            let botBandH = metalFrame.height * botRatio
            let gapH = metalFrame.height * ndsGapRatio
            var topW = metalFrame.width
            var topH = topW / aspect
            if topH > topBandH { topH = topBandH; topW = topH * aspect }
            var botW = metalFrame.width
            var botH = botW / aspect
            if botH > botBandH { botH = botBandH; botW = botH * aspect }
            return (CGRect(x: metalFrame.midX - topW / 2, y: metalFrame.minY,
                           width: topW, height: topH),
                    CGRect(x: metalFrame.midX - botW / 2, y: metalFrame.minY + topBandH + gapH,
                           width: botW, height: botH))
        }
    }

    // MARK: - Legacy upgrade (editor entry point)

    /// Converts a legacy controls-container layout to full-view space ONCE, when
    /// the editor opens it: every stored button keeps its on-screen spot (same
    /// conversion as `resolve`), per-component scale/opacity are filled from the
    /// preset's legacy globals so the values survive independently, and the
    /// never-hideable Menu/Clip lose any stale hidden flag. Screens start empty
    /// (= the defaults) — the legacy model had no movable screens.
    /// Already-converted layouts pass through unchanged.
    static func upgradedToFullView(_ layout: OrientationLayout, preset: ControlPreset,
                                   system: PresetSystem, isLandscape: Bool,
                                   viewSize: CGSize, safeInsets: UIEdgeInsets) -> OrientationLayout {
        guard layout.space == OrientationLayout.legacySpace else { return layout }
        let k = EmulatorLayoutGeometry.deviceScale(for: viewSize)
        let isNDS = (system == .nds)
        let defaults = defaultGeometry(system: system, isLandscape: isLandscape,
                                       viewSize: viewSize, safeInsets: safeInsets)

        var upgraded = OrientationLayout(space: OrientationLayout.fullViewSpace)
        for element in ControlElement.elements(for: system) {
            guard let stored = layout.buttons[element.rawValue] else { continue }
            let baseSize = EmulatorLayoutGeometry.buttonSize(
                element, system: system, isLandscape: isLandscape, deviceScale: k)
            let containerCenter = CGPoint(
                x: stored.centerX * defaults.controlsFrame.width,
                y: stored.centerY * defaults.controlsFrame.height)
            let adj = EmulatorLayoutGeometry.ndsLandscapeAdjusted(
                element: element, isNDS: isNDS, isLandscape: isLandscape,
                center: containerCenter, size: baseSize,
                container: defaults.controlsFrame.size, layout: layout, deviceScale: k)
            // Containment under the v2 size rule (polished base × scale), so
            // the stored values are already clean and resolve idempotently.
            let scale = clamp(stored.scale ?? preset.scale, minControlScale, maxControlScale)
            let v2Base = presetBaseSize(element: element, system: system,
                                        isLandscape: isLandscape, deviceScale: k)
            let viewCenter = clampedCenter(
                CGPoint(x: defaults.controlsFrame.minX + adj.center.x,
                        y: defaults.controlsFrame.minY + adj.center.y),
                size: CGSize(width: v2Base.width * scale, height: v2Base.height * scale),
                viewSize: viewSize)
            upgraded.buttons[element.rawValue] = ButtonLayout(
                centerX: viewCenter.x / viewSize.width,
                centerY: viewCenter.y / viewSize.height,
                isHidden: hidden(stored.isHidden, element: element),
                scale: stored.scale ?? preset.scale,
                opacity: stored.opacity ?? legacyAlpha(preset.opacity, element: element))
        }
        return upgraded
    }

    // MARK: - Helpers

    /// Native display aspect (width / height) for the geometry engine, matching
    /// what EmulatorViewController derives from the session buffers.
    static func displayAspect(_ system: PresetSystem) -> CGFloat {
        switch system {
        case .gba: return 240.0 / 160.0
        case .gbc: return 160.0 / 144.0
        case .nds: return 256.0 / 384.0
        // Both match `MesenBridge.displayAspect`, which is where the reasoning lives: each
        // shows its OWN frame with square pixels rather than the 4:3 a television stretched it
        // to. If one moves, they both move, or the picture and the space reserved for it stop
        // agreeing.
        case .snes: return 8.0 / 7.0
        // 248 wide, not 256: the NES's leftmost 8 columns are cropped in the core (most games
        // blank them themselves, which drew a flat band down the left edge of the picture).
        case .nes: return 248.0 / 240.0
        // 4:3, and unlike the two above this is not our reading of what a
        // television did to a square-pixel frame: the core states it in
        // `retro_get_system_av_info`, and the console really did vary its pixel
        // aspect per video mode to hit that one shape. Matches
        // `PCSXBridge.displayAspect`, and if one moves they both move.
        case .ps1: return 4.0 / 3.0
        }
    }

    /// Menu and Clip are action triggers (pause / share), not game inputs: they
    /// can never be hidden by a preset.
    static func hidden(_ stored: Bool, element: ControlElement) -> Bool {
        (element == .btnMenu || element == .btnClip) ? false : stored
    }

    /// The historical preset-global opacity mapping (slider 0.05–0.6, rendered
    /// ×2, Menu floored at 0.5) — used when a component has no opacity of its
    /// own, so legacy presets keep their exact shipped look.
    static func legacyAlpha(_ presetOpacity: CGFloat, element: ControlElement) -> CGFloat {
        let effective = min(1.0, presetOpacity * 2.0)
        return element == .btnMenu ? max(0.5, effective) : effective
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }

    private static func rect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
               width: size.width, height: size.height)
    }
}
