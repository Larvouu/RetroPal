//
//  EmulatorLayoutGeometry.swift
//  EmulateurGBA
//
//  Single source of truth for the device-relative layout of the in-game
//  screen(s) and the on-screen touch controls.
//
//  The whole in-game layout is expressed as the iPhone 14 Pro layout uniformly
//  scaled by a per-device factor (`deviceScale`). Controls and screen keep the
//  same proportions on every iPhone — smaller on an iPhone SE, larger on a Pro
//  Max — instead of overflowing or overlapping the way the previous hardcoded
//  points did on anything that was not a 14 Pro.
//
//  Reference device: iPhone 14 Pro (393 x 852 pt). At that size deviceScale == 1
//  and every value below is pixel-identical to the original hand-tuned constants,
//  so the device this layout was designed on is unaffected.
//
//  Consumers (all go through this type, none re-encode the numbers):
//   - TouchControlsView / NDSTouchControlsView  (default + custom button layout)
//   - ControlLayoutDefaults                     (normalized default positions)
//   - EmulatorViewController.layoutGameView      (game screen frame)
//   - ControlLayoutEditorViewController          (editor preview geometry)
//   - InGameLayoutPreview (DEBUG)                (Xcode canvas preview)
//

import UIKit

enum EmulatorLayoutGeometry {

    // MARK: - Device scale

    /// Short / long side of the reference device (iPhone 14 Pro), in points.
    static let referenceShortSide: CGFloat = 393
    static let referenceLongSide: CGFloat = 852

    /// Paranoid lower bound for the whole-layout scale. Does NOT engage on any
    /// current iPhone (the smallest, the SE at 375x667, lands at ~0.78). Comfort
    /// for touch targets is enforced separately, per button, by `minButtonDimension`.
    static let minDeviceScale: CGFloat = 0.7
    /// Upper bound for very large / future devices. Does NOT engage on any current
    /// iPhone (the Pro Max lands at ~1.12); it only guards against an iPad or a
    /// future jumbo device blowing the controls up absurdly.
    static let maxDeviceScale: CGFloat = 1.25

    /// Uniform scale for `deviceSize` relative to the iPhone 14 Pro.
    /// Orientation-independent: compares short side to short side and long to long,
    /// then takes the tighter ratio so the scaled layout always fits the device.
    static func deviceScale(for deviceSize: CGSize) -> CGFloat {
        let shortSide = min(deviceSize.width, deviceSize.height)
        let longSide = max(deviceSize.width, deviceSize.height)
        guard shortSide > 0, longSide > 0 else { return 1 }
        let raw = min(shortSide / referenceShortSide, longSide / referenceLongSide)
        return min(max(raw, minDeviceScale), maxDeviceScale)
    }

    // MARK: - Button sizing

    /// Comfortable minimum on-screen dimension for a button (Apple's 44pt target).
    /// Applied per axis, but never raises a button above its own reference size —
    /// so intentionally-thin buttons (the L/R bars, Start/Select) stay thin and the
    /// reference device stays pixel-identical. Set to 0 to disable the floor.
    static let minButtonDimension: CGFloat = 44

    /// Reference (iPhone 14 Pro) size for an element in the given context, before
    /// the device scale. The per-context base sizes live on `ControlElement`.
    static func referenceSize(_ element: ControlElement, isNDS: Bool, isLandscape: Bool) -> CGSize {
        if isNDS {
            return isLandscape ? element.defaultNDSLandscapeSize : element.defaultNDSPortraitSize
        } else {
            return isLandscape ? element.defaultLandscapeSize : element.defaultSize
        }
    }

    /// Elements the SNES sizes like a DS rather than like a Game Boy.
    ///
    /// The console's pad is the DS's shape — a D-pad and four face buttons in a
    /// diamond — so those five take the DS's measurements. Everything else keeps
    /// the Game Boy family's, which is why this is a SET of elements and not a
    /// per-console table: the difference really is element by element.
    ///
    /// The D-pad is in the set for PORTRAIT ONLY (2026-08-17). In landscape this console's pad
    /// is the GBA's, in position and in size, because that page is the GBA's page: one panel
    /// with a gutter each side, and the gutter is where a pad goes. `snesLandscapeUsesGBAPad`
    /// names the exception so the two places that must agree — this size table and the layout
    /// in `ControlLayoutDefaults.snes` — cannot answer differently.
    static let snesUsesNDSSizing: Set<ControlElement> = [.dpad, .btnA, .btnB, .btnX, .btnY]
    static let snesLandscapeUsesGBAPad = true

    /// Reference size, chosen per element for the console being laid out.
    ///
    /// The `isNDS:` overload above is kept exactly as it was and still answers
    /// for every console that shipped before 1.2.5, so their sizes cannot move
    /// through this change. Only the SNES asks a different question.
    static func referenceSize(_ element: ControlElement, system: PresetSystem,
                              isLandscape: Bool) -> CGSize {
        if system == .snes && snesUsesNDSSizing.contains(element) {
            let padIsGBAs = snesLandscapeUsesGBAPad && isLandscape && element == .dpad
            if !padIsGBAs {
                return referenceSize(element, isNDS: true, isLandscape: isLandscape)
            }
        }
        return referenceSize(element, isNDS: system == .nds, isLandscape: isLandscape)
    }

    /// Device-scaled size, chosen per element for the console being laid out.
    static func buttonSize(_ element: ControlElement, system: PresetSystem,
                           isLandscape: Bool, deviceScale: CGFloat) -> CGSize {
        let base = referenceSize(element, system: system, isLandscape: isLandscape)
        return CGSize(width: flooredDimension(base.width, scale: deviceScale),
                      height: flooredDimension(base.height, scale: deviceScale))
    }

    /// Device-scaled button size with the comfortable-minimum floor applied.
    /// At deviceScale == 1 this equals the reference size exactly.
    static func buttonSize(_ element: ControlElement, isNDS: Bool, isLandscape: Bool,
                           deviceScale: CGFloat) -> CGSize {
        let base = referenceSize(element, isNDS: isNDS, isLandscape: isLandscape)
        return CGSize(width: flooredDimension(base.width, scale: deviceScale),
                      height: flooredDimension(base.height, scale: deviceScale))
    }

    /// A single button dimension, device-scaled, never below `min(minButtonDimension, reference)`.
    private static func flooredDimension(_ reference: CGFloat, scale: CGFloat) -> CGFloat {
        max(reference * scale, Swift.min(minButtonDimension, reference))
    }

    // MARK: - Screen reserves (reference points — scaled by deviceScale at use)

    /// Bottom strip kept for the still-visible Menu button when a controller is
    /// connected and the on-screen pad is hidden.
    static let controllerMenuStrip: CGFloat = 72
    /// NDS portrait: minimum height reserved below the screens for the controls.
    static let ndsPortraitControlsReserve: CGFloat = 280
    /// GBA portrait: extra top padding below the safe area before the screen.
    /// GBA-only — GB/GBC have their own `gbcPortraitTopPadding`.
    static let gbaPortraitTopPadding: CGFloat = 42
    /// Fraction of the view height given to the game screen in GBA portrait.
    /// GBA-only — GB/GBC have their own `gbcPortraitScreenRatio`.
    static let gbaPortraitScreenRatio: CGFloat = 0.45
    /// Fraction of the view height given to the two screens in NDS landscape.
    static let ndsLandscapeScreenRatio: CGFloat = 0.60

    /// SNES landscape only: the gap above the picture, so the dress's inlaid panel has a top
    /// edge to draw, and the height reserved below it for the SELECT · MENU · START row (that
    /// row's gap, its height, and the panel's bottom margin). The device's bottom safe inset is
    /// added to the reserve at use, so the row clears the home indicator too.
    static let snesLandscapeTopMargin: CGFloat = 12
    static let snesLandscapeBottomReserve: CGFloat = 56
    /// The landscape home-indicator inset, counted into that reserve as a FLAT value rather
    /// than read from the device or scaled. Read from the device it would not be available
    /// where the layout needs it: `ControlLayoutDefaults.snes` recomputes this same screen
    /// frame with zero insets to place the row against it, and a picture whose height depended
    /// on an inset the layout does not have is a picture the row is positioned against wrongly.
    /// Flat rather than scaled because the indicator is 21pt on every phone that has one; the
    /// phones that do not are width-bound here and lose nothing to it.
    static let snesLandscapeIndicatorReserve: CGFloat = 21

    // MARK: - GB/GBC screen (decoupled from GBA)

    /// GB/GBC own their screen geometry so changes to the GBA screen never move them.
    /// These start equal to the GBA values above (zero visual change at introduction)
    /// and are tuned independently from here on. The shared 3:2 height shape below is
    /// the only constant GB/GBC keep in common with GBA, and GBA hardware aspect never
    /// changes, so it is not a coupling point.
    static let gbcLandscapePanel: CGFloat = 170
    static let gbcPortraitTopPadding: CGFloat = 42
    static let gbcPortraitScreenRatio: CGFloat = 0.45
    /// GB/GBC landscape: gap between the game-screen bottom and the SELECT·MENU·START row
    /// (and the same gap below the row to the dress surround's bottom). The row is stuck
    /// this far below the screen instead of floating centered in the strip below it.
    static let gbcLandscapeRowGap: CGFloat = 8

    /// Fixed shape used to derive the GB/GBC on-screen HEIGHT (the classic GBA 3:2
    /// footprint). Width then comes from the 160×144 display aspect. This is GB/GBC's
    /// own reference, independent of GBA's actual on-screen width, which they no longer track.
    static let gbcScreenHeightAspect: CGFloat = 240.0 / 160.0

    /// GB/GBC display aspect (160×144). The landscape on-screen WIDTH derives from this and
    /// is SHARED by GBA (so the two console dresses line up); each system keeps its own height.
    static let gbcDisplayAspect: CGFloat = 160.0 / 144.0

    // MARK: - Game screen frame

    /// Frame of the Metal view (the game screen, or the NDS side-by-side / stacked
    /// pair) for the given device + orientation + system. Matches the original
    /// EmulatorViewController.layoutGameView math exactly at deviceScale == 1.
    ///
    /// `gameAspect` is rendered width / rendered height (the DISPLAY aspect). For
    /// GBA pass 240/160; for GB/GBC pass 160/144; for NDS portrait pass the combined
    /// 256/384 texture aspect (the NDS-landscape branch fills the screen area edge-to-
    /// edge and ignores `gameAspect`). `system` selects the geometry family: GB/GBC use
    /// their own panel/ratio/padding + a fixed 3:2 height shape, fully decoupled from
    /// GBA, and `gameAspect` only sets their (narrower) width.
    static func screenFrame(deviceSize: CGSize, safeInsets: UIEdgeInsets,
                            hasTouchScreen: Bool, isLandscape: Bool,
                            gameAspect: CGFloat, system: PresetSystem,
                            controllerConnected: Bool,
                            deviceScale k: CGFloat) -> CGRect {
        let menuStrip = controllerMenuStrip * k
        // GB/GBC derive their on-screen HEIGHT from a fixed 3:2 shape (independent of
        // GBA's width); their width then comes from their own (narrower) display aspect.
        // Every other system uses its own aspect for both.
        let heightAspect: CGFloat = (system == .gbc) ? gbcScreenHeightAspect : gameAspect

        if isLandscape {
            if hasTouchScreen {
                // NDS landscape: screens fill the upper band, side by side.
                let screenAreaH = controllerConnected
                    ? deviceSize.height - menuStrip
                    : deviceSize.height * ndsLandscapeScreenRatio
                // With a controller the screens fill the width edge-to-edge, so on
                // notched devices the front-camera housing overlaps the screen on
                // the notch side. Inset by the horizontal safe area to clear it.
                // Without a controller the side gutters (the screens are height-
                // bound) already clear it, so the reference layout is untouched;
                // the insets are also 0 on non-notched devices like the SE.
                let leftInset = controllerConnected ? safeInsets.left : 0
                let rightInset = controllerConnected ? safeInsets.right : 0
                return CGRect(x: leftInset, y: 0,
                              width: deviceSize.width - leftInset - rightInset,
                              height: screenAreaH)
            } else {
                // GBA + GB/GBC landscape: game between two side control panels. They SHARE the
                // panel width AND the on-screen WIDTH (derived from the GB/GBC display shape),
                // so the two console dresses line up; each system then takes its own HEIGHT from
                // its aspect (GBA keeps 3:2, GB/GBC its 10:9). Both top-aligned.
                let panelWidth: CGFloat = controllerConnected ? 0 : gbcLandscapePanel * k
                let availW = deviceSize.width - panelWidth * 2
                // The SNES gives up a little height at BOTH ends, and only this console does.
                // Its dress frames the picture in an inlaid panel, and a picture flush with
                // y = 0 leaves that panel nowhere to be: the surround's top edge rendered off
                // the device and the game stood proud of its own frame. Below, the
                // SELECT · MENU · START row is stuck to the picture's bottom, so a taller
                // picture pushes the row into the home indicator. Reserving both ends here is
                // what lets the panel be a frame.
                // The SNES reserves at BOTH ends, the NES only at the bottom: both stick their
                // SELECT · MENU · START row under the picture, so both need room for it, and
                // only the SNES's dress needs a top edge to draw (the NES's panel grows from the
                // picture instead). Without the bottom reserve the row lands ON the game, which
                // is what the landscape sweep caught.
                let snesInset = (system == .snes && !controllerConnected)
                let nesInset = (system == .nes && !controllerConnected)
                let topInset = snesInset ? snesLandscapeTopMargin * k : 0
                let bottomReserve = (snesInset || nesInset)
                    ? snesLandscapeBottomReserve * k + snesLandscapeIndicatorReserve : 0
                let availH = deviceSize.height - topInset - bottomReserve
                let commonWidth = (availW / gbcScreenHeightAspect) * gbcDisplayAspect
                var fitW = commonWidth
                var fitH = fitW / gameAspect
                if fitH > availH { fitH = availH; fitW = fitH * gameAspect }
                let x = panelWidth + (availW - fitW) / 2
                // GBA is vertically centered; GB/GBC stays top-aligned; the SNES sits under
                // its own top margin.
                let y: CGFloat = (system == .gba) ? (availH - fitH) / 2 : topInset
                return CGRect(x: x, y: y, width: fitW, height: fitH)
            }
        } else {
            let availW = deviceSize.width
            let minControlsH: CGFloat = hasTouchScreen
                ? (controllerConnected ? menuStrip : ndsPortraitControlsReserve * k)
                : 0
            // GB/GBC portrait uses its own screen-height fraction + top padding, so
            // GBA portrait can be tuned without moving GB/GBC.
            let portraitRatio = (system == .gbc) ? gbcPortraitScreenRatio : gbaPortraitScreenRatio
            let maxH: CGFloat = hasTouchScreen
                ? deviceSize.height - safeInsets.top - safeInsets.bottom - minControlsH
                : deviceSize.height * portraitRatio
            var fitH = availW / heightAspect
            if fitH > maxH { fitH = maxH }
            var fitW = fitH * gameAspect
            var x = (availW - fitW) / 2
            let portraitPad = (system == .gbc) ? gbcPortraitTopPadding : gbaPortraitTopPadding
            let extraPadding: CGFloat = hasTouchScreen ? 0 : portraitPad * k
            var y = safeInsets.top + extraPadding
            // The NES fills the WIDTH, always, and grows upward to do it.
            //
            // The height cap above exists to protect the controls, and it protects them by
            // taking width away from the picture, which on a short phone left this console's
            // game floating in a band of body with a margin each side. So it takes back the
            // width and pays for it from the top of the page instead: same bottom edge, so the
            // controls container is untouched and the cap keeps the room it was defending, and
            // a taller picture above it. Every other console is unchanged, and so is the NES
            // wherever the cap never bound (a 14 Pro reaches full width on its own).
            if system == .nes, !hasTouchScreen, fitW < availW {
                let bottom = y + fitH
                fitW = availW
                fitH = fitW / gameAspect
                x = 0
                // Grow upward from the bottom edge the cap chose — but not off the page. On an
                // SE the full-width picture is taller than the room above that edge, and the
                // overflow is the TOP of the picture, which would simply not be drawn. Pinning
                // the top instead spends the difference downward, where it costs the controls
                // container a few points it can absorb, rather than costing the player pixels.
                y = max(0, bottom - fitH)
            }
            return CGRect(x: x, y: y, width: fitW, height: fitH)
        }
    }

    /// The controls container frame for a given device + screen frame: the area the
    /// normalized button positions are relative to. Mirrors
    /// EmulatorViewController.applyControlConstraints():
    ///  - GBA landscape: controls overlay the whole view.
    ///  - everything else: controls sit below the screen(s).
    static func controlsFrame(deviceSize: CGSize, screenFrame: CGRect,
                              hasTouchScreen: Bool, isLandscape: Bool) -> CGRect {
        let top: CGFloat = (isLandscape && !hasTouchScreen) ? 0 : screenFrame.maxY
        return CGRect(x: 0, y: top, width: deviceSize.width, height: deviceSize.height - top)
    }

    // MARK: - NDS landscape side bars (L / R)

    /// Aspect ratio of a single NDS screen (256 x 192 = 4:3).
    static let ndsScreenAspect: CGFloat = 256.0 / 192.0

    /// Smallest width a gutter-fitted L/R bar is allowed to shrink to, so it stays
    /// tappable even on the narrowest device.
    static let minSideBarWidth: CGFloat = 28

    /// Recovers the NDS-landscape screen band height from the controls container.
    /// The landscape frames carry no safe-area inset, so the controls always occupy
    /// the lower `1 - ndsLandscapeScreenRatio` of the device height — the band above
    /// is therefore exactly `containerH · ratio / (1 - ratio)`.
    private static func ndsLandscapeBandHeight(controlsContainer c: CGSize) -> CGFloat {
        let ratio = ndsLandscapeScreenRatio
        guard ratio > 0, ratio < 1, c.height > 0 else { return 0 }
        return c.height * ratio / (1 - ratio)
    }

    /// Width of the empty letterbox gutter on each side of the two side-by-side NDS
    /// screens in landscape. Each screen is aspect-fit (4:3) to half the view width
    /// and the pair is centred touching at the middle (see
    /// `EmulatorMetalView.rebuildNDSVertices`), so the empty space is split between
    /// the two outer edges. On a narrow device (iPhone SE) the pair is wide and the
    /// gutter thin (~34pt); on the 14 Pro the gutter is wide (~112pt).
    static func ndsLandscapeScreenGutter(controlsContainer c: CGSize) -> CGFloat {
        guard c.width > 0 else { return 0 }
        let band = ndsLandscapeBandHeight(controlsContainer: c)
        let pairWidth = Swift.min(c.width, 2 * band * ndsScreenAspect)
        return Swift.max(0, (c.width - pairWidth) / 2)
    }

    /// The two rendered NDS screen rects in landscape, expressed in the controls
    /// container's coordinate space: the screen band sits directly above the
    /// container, so its `y` runs from `-bandHeight` to `0`. `touch` is the right
    /// screen (the interactive one). Used to assert controls never cover a screen.
    static func ndsLandscapeScreenRects(controlsContainer c: CGSize) -> (left: CGRect, touch: CGRect) {
        let band = ndsLandscapeBandHeight(controlsContainer: c)
        let gutter = ndsLandscapeScreenGutter(controlsContainer: c)
        let screenW = Swift.max(0, c.width - 2 * gutter) / 2
        let left = CGRect(x: gutter, y: -band, width: screenW, height: band)
        let touch = CGRect(x: gutter + screenW, y: -band, width: screenW, height: band)
        return (left, touch)
    }

    /// Fits an NDS-landscape L/R bar into the gutter beside the screens when its
    /// default geometry would put it *on* a screen — the iPhone-SE bug where R lands
    /// on the touch screen. Returns the adjusted `(centerX, width)` in the container,
    /// or `nil` to keep the default. On wide-gutter devices (14 Pro) the default bar
    /// already clears the screens, so this returns `nil` and that device is untouched.
    /// `defaultCenterX` / `defaultWidth` are the resolved (device-scaled) values.
    static func ndsLandscapeSideBarFit(
        element: ControlElement, isNDS: Bool, isLandscape: Bool,
        defaultCenterX: CGFloat, defaultWidth: CGFloat, container: CGSize
    ) -> (centerX: CGFloat, width: CGFloat)? {
        guard isNDS, isLandscape, element == .btnL || element == .btnR else { return nil }
        let gutter = ndsLandscapeScreenGutter(controlsContainer: container)
        guard gutter > 0, gutter < container.width / 2 else { return nil }
        let edge: CGFloat = 2   // clearance from the device edge and the screen edge
        let width = Swift.min(defaultWidth, Swift.max(minSideBarWidth, gutter - 2 * edge))

        if element == .btnL {
            // Already clear of the left screen at its default geometry? Leave it.
            guard defaultCenterX + defaultWidth / 2 > gutter else { return nil }
            return (edge + width / 2, width)
        } else {
            let screenRight = container.width - gutter
            guard defaultCenterX - defaultWidth / 2 < screenRight else { return nil }
            return (container.width - edge - width / 2, width)
        }
    }

    /// The render-time NDS-landscape geometry fix that the layout's normalized
    /// positions can't apply itself, because it depends on the comfort-FLOORED sizes
    /// (computed here, not in `ControlLayoutDefaults`): keep the L/R bars in the
    /// screen-side gutter. Acts only when the default geometry would overlap, so
    /// devices that don't need it (the 14 Pro) get their input back unchanged. Single
    /// entry point for every consumer (`TouchControlsView`, editor, layout tests).
    /// (The Mic/Clip bottom-row lift was removed once Mic moved INTO that row; the
    /// `layout` / `deviceScale` params are kept for the call contract + future fixups.)
    static func ndsLandscapeAdjusted(
        element: ControlElement, isNDS: Bool, isLandscape: Bool,
        center: CGPoint, size: CGSize, container: CGSize,
        layout: OrientationLayout, deviceScale: CGFloat
    ) -> (center: CGPoint, size: CGSize) {
        guard isNDS, isLandscape else { return (center, size) }
        var center = center
        var size = size

        if let fit = ndsLandscapeSideBarFit(
            element: element, isNDS: true, isLandscape: true,
            defaultCenterX: center.x, defaultWidth: size.width, container: container) {
            center.x = fit.centerX
            size.width = fit.width
        }

        return (center, size)
    }
}
