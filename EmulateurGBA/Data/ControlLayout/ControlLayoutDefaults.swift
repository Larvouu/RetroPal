//
//  ControlLayoutDefaults.swift
//  EmulateurGBA
//
//  Generates the default OrientationLayouts (normalized button positions) for the
//  in-game controls. Used to lay out the built-in default, to seed new presets,
//  and to fill in missing buttons when loading cross-system presets.
//
//  Every position is the iPhone 14 Pro layout scaled by `scale` (the device scale
//  from EmulatorLayoutGeometry): absolute lengths (edge margins, half-sizes, gaps)
//  are multiplied by `scale`, while container references (w, h, w/2) are not. At
//  scale == 1 the output is pixel-identical to the original hand-tuned constants.
//

import CoreGraphics

enum ControlLayoutDefaults {

    // MARK: - GBA Portrait

    /// Default GBA portrait layout, normalized to the container, scaled for the device.
    static func gbaPortrait(containerSize: CGSize, scale k: CGFloat) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        // GBA portrait mirrors the GB/GBC face-button positions (D-pad / A / B / SELECT /
        // MENU / START / Clip), then re-adds the L/R shoulders (GBA-only). So the two dresses
        // share the same control layout; only L/R differ.
        var layout = gbcPortrait(containerSize: containerSize, scale: k)
        // L/R: top edge at +36; centerY uses the (thinner) L/R half-height so they keep hugging
        // the top. Menu joins them on the SAME center line → a row of 3 (L · MENU · R).
        let lHalf = ControlElement.btnL.defaultSize.height / 2
        let rowY = (36 + lHalf) * k / h
        layout.buttons[ControlElement.btnL.rawValue] = ButtonLayout(
            centerX: (16 + 45) * k / w, centerY: rowY)
        layout.buttons[ControlElement.btnR.rawValue] = ButtonLayout(
            centerX: (w - (16 + 45) * k) / w, centerY: rowY)
        layout.buttons[ControlElement.btnMenu.rawValue] = ButtonLayout(centerX: 0.5, centerY: rowY)
        // Clip: centered on A horizontally, lowered a few points from the inherited spot.
        if let a = layout.buttons[ControlElement.btnA.rawValue] {
            let inheritedClipY = layout.buttons[ControlElement.btnClip.rawValue]?.centerY ?? (126 * k / h)
            layout.buttons[ControlElement.btnClip.rawValue] =
                ButtonLayout(centerX: a.centerX, centerY: inheritedClipY + 8 * k / h)
        }
        return layout
    }

    // MARK: - Base landscape (shared by GBA + GB/GBC)

    /// The shared landscape base, normalized to the container, scaled for the device. `panel`
    /// is the side-panel width the game is inset by. GB/GBC builds on this (drops L/R,
    /// repositions); GBA builds on the GB/GBC result (re-adds L/R) — see gbaLandscape.
    static func baseLandscape(containerSize: CGSize, scale k: CGFloat,
                              panel: CGFloat) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        let dpadH = ControlElement.dpad.defaultLandscapeSize.width / 2
        let aH = ControlElement.btnA.defaultLandscapeSize.width / 2
        let bH = ControlElement.btnB.defaultLandscapeSize.width / 2

        var buttons: [String: ButtonLayout] = [:]
        // dpad: parked in the left gutter so it never overlays the game screen — its
        // right edge sits on the gutter/screen boundary (`panel`). The screen's left
        // edge is always ≥ panel·k (GBA touches the gutter; GB/GBC is inset further),
        // so this clears both. centerY unchanged.
        buttons[ControlElement.dpad.rawValue] = ButtonLayout(
            centerX: (panel - dpadH) * k / w, centerY: (h / 2 + 39 * k) / h)
        // btnA: trailing -95, centerY +9
        buttons[ControlElement.btnA.rawValue] = ButtonLayout(
            centerX: (w - (95 + aH) * k) / w, centerY: (h / 2 + 9 * k) / h)
        // btnB: anchored to A's lower-left corner (testing) — B's center sits on A's
        // extreme left edge (A.centerX − aH = w − (95 + 2·aH)·k), and B's top sits on
        // A's bottom (A.centerY + aH), so B.centerY = that + bH = h/2 + (9 + aH + bH)·k.
        buttons[ControlElement.btnB.rawValue] = ButtonLayout(
            centerX: (w - (95 + 2 * aH) * k) / w, centerY: (h / 2 + (9 + aH + bH) * k) / h)
        // btnL: leading +25, top +20, 110x38 → center at (25 + 55, 20 + 19)
        buttons[ControlElement.btnL.rawValue] = ButtonLayout(
            centerX: (25 + 55) * k / w, centerY: (20 + 19) * k / h)
        // btnR: trailing -25, top +20
        buttons[ControlElement.btnR.rawValue] = ButtonLayout(
            centerX: (w - (25 + 55) * k) / w, centerY: (20 + 19) * k / h)
        // Bottom row UNDER the top-aligned game: SELECT · MENU · START. Offsets are
        // FIXED (±93), not ×k — the buttons floor to 44pt wide on small devices, so a
        // scaled offset would let them overlap. Select and Start keep their proven ±93
        // spots; Menu sits dead-center (0.5), precisely between them — the prime slot for
        // the most-used button. Clip is NOT in this row (it tucks under R, below); the
        // shared rowY keeps the three aligned.
        //
        // rowY is centered VERTICALLY in the free strip between the game's bottom and
        // the screen bottom, not pinned to the bottom edge — on devices where the game
        // is much shorter than the screen (iPhone SE) the bottom-pin left a big empty
        // gap above the row. The game is top-aligned (y=0) and width-bound on iPhones,
        // so its bottom = (w − 2·panel·k)/aspect, using the SAME panel width the screen
        // frame used for this system (GBA vs GB/GBC may differ); the 3:2 height shape is
        // shared by both. On 14 Pro / Pro Max the strip is small, so this barely moves
        // from the previous bottom-pin.
        let gameW = w - panel * k * 2
        let gameBottom = min(gameW / (240.0 / 160.0), h)
        let rowY = ((gameBottom + h) / 2) / h
        buttons[ControlElement.btnSelect.rawValue] = ButtonLayout(
            centerX: (w / 2 - 93) / w, centerY: rowY)
        buttons[ControlElement.btnMenu.rawValue] = ButtonLayout(
            centerX: 0.5, centerY: rowY)
        buttons[ControlElement.btnStart.rawValue] = ButtonLayout(
            centerX: (w / 2 + 93) / w, centerY: rowY)
        // btnClip: tucked BELOW the R bar in the top-right corner, out of the bottom
        // action row so it reads as the lesser action and never crowds Menu. Right edge
        // aligned to R's right edge (R center w−80k, half 55k → right edge w−25k; Clip
        // floors to 44, half 22 → center w−25k−22). Below R by the Menu↔Start gap
        // (93 − Start-half 28 − Menu-half 22 = 43): centerY = R-center(39k) + R-half(19k)
        // + 43k + Clip-half(19k) = 120k. Reference geometry ×k.
        buttons[ControlElement.btnClip.rawValue] = ButtonLayout(
            centerX: (w - 25 * k - 22) / w, centerY: 120 * k / h)

        return OrientationLayout(buttons: buttons)
    }

    // MARK: - GB/GBC Portrait

    /// Default GB/GBC portrait layout. Mirrors GBA portrait, but with no L/R shoulder
    /// buttons and with the A/B pair raised so the bloc's vertical center aligns with the
    /// D-pad's center (GB/GBC has no shoulder row, so the face buttons read better
    /// balanced against the pad).
    static func gbcPortrait(containerSize: CGSize, scale k: CGFloat) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        let dpadH = ControlElement.dpad.defaultSize.width / 2
        let aH = ControlElement.btnA.defaultSize.width / 2
        let bH = ControlElement.btnB.defaultSize.width / 2
        let dpadBottomOffset: CGFloat = 130   // the D-pad's bottom edge, measured from the bottom

        var buttons: [String: ButtonLayout] = [:]
        // dpad: leading +20, bottom -140 (same as GBA portrait).
        buttons[ControlElement.dpad.rawValue] = ButtonLayout(
            centerX: (20 + dpadH) * k / w, centerY: (h - (dpadBottomOffset + dpadH) * k) / h)

        // A (upper-right) / B (lower-left): keep the GBA diagonal (same X, same A↔B
        // vertical gap) but recentre the pair on the D-pad's centerY. dpad center from
        // bottom = 130 + dpadH; A↔B center gap = (170 + aH) − (120 + bH).
        let dpadCenter = 130 + dpadH
        let abGap = (170 + aH) - (120 + bH)
        buttons[ControlElement.btnA.rawValue] = ButtonLayout(
            centerX: (w - (30 + aH) * k) / w, centerY: (h - (dpadCenter + abGap / 2) * k) / h)
        buttons[ControlElement.btnB.rawValue] = ButtonLayout(
            centerX: (w - (100 + bH) * k) / w, centerY: (h - (dpadCenter - abGap / 2) * k) / h)

        // btnStart / btnSelect: bottom-center pair, raised by half the gap between the D-pad's
        // bottom edge and the row's top edge (GBA portrait keeps its lower spot). 39 = the gap
        // from the screen bottom to the row's bottom edge.
        let rowBottomOffset: CGFloat = 39
        let selectH = ControlElement.btnSelect.defaultSize.height
        let rowTopOffset = rowBottomOffset + selectH
        let rowCenterOffset = rowBottomOffset + selectH / 2 + (dpadBottomOffset - rowTopOffset) / 2
        buttons[ControlElement.btnStart.rawValue] = ButtonLayout(
            centerX: (w / 2 + 38 * k) / w, centerY: (h - rowCenterOffset * k) / h)
        buttons[ControlElement.btnSelect.rawValue] = ButtonLayout(
            centerX: (w / 2 - 38 * k) / w, centerY: (h - rowCenterOffset * k) / h)
        // btnMenu (top-center): dropped a touch lower than the GBA spot so it clears the
        // GB/GBC dress surround's bottom extension (~38pt below the screen) instead of
        // tucking under it. btnClip stays top-right.
        buttons[ControlElement.btnMenu.rawValue] = ButtonLayout(
            centerX: 0.5, centerY: (48 + 22) * k / h)
        buttons[ControlElement.btnClip.rawValue] = ButtonLayout(
            centerX: (w - 16 * k - 22) / w, centerY: 126 * k / h)

        return OrientationLayout(buttons: buttons)
    }

    // MARK: - GB/GBC Landscape

    /// Default GB/GBC landscape layout. Builds on GBA landscape (own panel), drops L/R,
    /// then repositions the face controls for the GB/GBC dress:
    ///  - the D-pad is centered horizontally in the SAFE left gutter (leading safe-area
    ///    edge → screen), so it clears the Dynamic Island on 14+ devices;
    ///  - A and B split around their current bloc's horizontal center — B's right edge and
    ///    A's left edge both land on it — so the pair sits in the right gutter.
    /// Vertical positions are untouched. `safeLeftInset` is the leading safe-area inset
    /// (0 on phones without an island, ~59pt when the island is on the leading edge).
    static func gbcLandscape(containerSize: CGSize, scale k: CGFloat,
                             safeLeftInset: CGFloat) -> OrientationLayout {
        var layout = baseLandscape(containerSize: containerSize, scale: k,
                                   panel: EmulatorLayoutGeometry.gbcLandscapePanel)
        layout.buttons[ControlElement.btnL.rawValue] = nil
        layout.buttons[ControlElement.btnR.rawValue] = nil

        let w = containerSize.width
        guard w > 0, containerSize.height > 0 else { return layout }

        // D-pad → horizontal center of the SAFE left gutter (safe-area left → screen left).
        // In landscape the controls container fills the view, so containerSize is the
        // device size and the screen's left edge comes straight from the geometry engine
        // (same source as the game). Centering in [safeLeftInset, screen.minX] keeps the
        // pad clear of the Dynamic Island; with no island (inset 0) it's the full-gutter
        // center, unchanged.
        let screen = EmulatorLayoutGeometry.screenFrame(
            deviceSize: containerSize, safeInsets: .zero, hasTouchScreen: false, isLandscape: true,
            gameAspect: 160.0 / 144.0, system: .gbc, controllerConnected: false, deviceScale: k)
        // The GB/GBC dress draws a thin surround frame (~14pt) to the LEFT of the screen,
        // so center the D-pad against that VISIBLE edge (not the raw screen), with equal
        // clearance from the front-camera safe-area inset. (Matches the landscape frame
        // in ConsoleSkinView; harmless when undressed — the pad just sits a hair left.)
        let dressFrame = 14 * k
        let gutterCenter = (safeLeftInset + (screen.minX - dressFrame)) / 2
        if let dpad = layout.buttons[ControlElement.dpad.rawValue] {
            layout.buttons[ControlElement.dpad.rawValue] = ButtonLayout(
                centerX: gutterCenter / w, centerY: dpad.centerY, isHidden: dpad.isHidden)
        }

        // A/B → split around the CURRENT bloc's horizontal center (B right edge and A left
        // edge both land on it). Read the inherited A/B so the center reflects wherever
        // they currently sit; only X changes.
        let aH = ControlElement.btnA.defaultLandscapeSize.width / 2
        let bH = ControlElement.btnB.defaultLandscapeSize.width / 2
        if let a = layout.buttons[ControlElement.btnA.rawValue],
           let b = layout.buttons[ControlElement.btnB.rawValue] {
            let aCx = a.centerX * w
            let bCx = b.centerX * w
            let blocLeft = min(aCx - aH * k, bCx - bH * k)
            let blocRight = max(aCx + aH * k, bCx + bH * k)
            let center = (blocLeft + blocRight) / 2
            layout.buttons[ControlElement.btnB.rawValue] = ButtonLayout(
                centerX: (center - bH * k) / w, centerY: b.centerY, isHidden: b.isHidden)
            layout.buttons[ControlElement.btnA.rawValue] = ButtonLayout(
                centerX: (center + aH * k) / w, centerY: a.centerY, isHidden: a.isHidden)
        }

        // SELECT·MENU·START row: stick it a fixed gap below the screen bottom (the iPhone-14
        // look) instead of GBA's centered-in-the-strip rowY, so it doesn't float low on
        // devices with a tall strip below the screen. Real hitbox; landscape only; X kept.
        let rowH = EmulatorLayoutGeometry.buttonSize(.btnStart, isNDS: false,
                                                     isLandscape: true, deviceScale: k).height
        let rowCenterY = (screen.maxY + EmulatorLayoutGeometry.gbcLandscapeRowGap * k + rowH / 2)
            / containerSize.height
        for e in [ControlElement.btnSelect, .btnMenu, .btnStart] {
            if let b = layout.buttons[e.rawValue] {
                layout.buttons[e.rawValue] = ButtonLayout(centerX: b.centerX, centerY: rowCenterY,
                                                          isHidden: b.isHidden)
            }
        }

        // btnClip → top-right gutter (GB/GBC landscape only). Vertically centered between
        // the TOP of the screen (y = 0) and the TOP of the A button; horizontally centered
        // between the end of the dress surround (screen right + dress frame) and the right
        // edge of the iPhone screen. Real hitbox; both X and Y change. Clip sits above A and
        // right of the surround, so it never crowds the face buttons or covers the screen.
        if let clip = layout.buttons[ControlElement.btnClip.rawValue] {
            let surroundRight = screen.maxX + dressFrame
            let aSize = EmulatorLayoutGeometry.buttonSize(.btnA, isNDS: false,
                                                          isLandscape: true, deviceScale: k)
            let aTop = (layout.buttons[ControlElement.btnA.rawValue]?.centerY ?? 0.5)
                * containerSize.height - aSize.height / 2
            layout.buttons[ControlElement.btnClip.rawValue] = ButtonLayout(
                centerX: ((surroundRight + w) / 2) / w,
                centerY: (aTop / 2) / containerSize.height,
                isHidden: clip.isHidden)
        }

        return layout
    }

    // MARK: - GBA Landscape

    /// GBA landscape mirrors the GB/GBC face-button positions (D-pad gutter-centered, A/B in the
    /// right gutter, SELECT·MENU·START stuck below the screen), then re-adds the GBA-kept controls
    /// (L/R shoulders + the below-R Clip) and re-sticks the SELECT·MENU·START row to the GBA
    /// screen's bottom (the GBA screen shares GB/GBC's width but keeps its own 3:2 height, so it
    /// is shorter).
    static func gbaLandscape(containerSize: CGSize, scale k: CGFloat,
                             safeLeftInset: CGFloat) -> OrientationLayout {
        var layout = gbcLandscape(containerSize: containerSize, scale: k, safeLeftInset: safeLeftInset)
        let w = containerSize.width, h = containerSize.height
        guard w > 0, h > 0 else { return layout }

        // Re-add the GBA-kept controls from the shared base: L/R (GBA-only) and Clip (GBA keeps
        // its own below-R spot; GB/GBC's top-right-gutter clip would collide with R here).
        let base = baseLandscape(containerSize: containerSize, scale: k,
                                 panel: EmulatorLayoutGeometry.gbcLandscapePanel)
        for e in [ControlElement.btnL, .btnR, .btnClip] {
            layout.buttons[e.rawValue] = base.buttons[e.rawValue]
        }

        // Re-stick SELECT·MENU·START to the GBA screen's bottom (gbcLandscape stuck them to the
        // taller GB/GBC screen). Same gap below the screen as GB/GBC.
        let gbaScreen = EmulatorLayoutGeometry.screenFrame(
            deviceSize: containerSize, safeInsets: .zero, hasTouchScreen: false, isLandscape: true,
            gameAspect: 240.0 / 160.0, system: .gba, controllerConnected: false, deviceScale: k)
        let rowH = EmulatorLayoutGeometry.buttonSize(.btnStart, isNDS: false,
                                                     isLandscape: true, deviceScale: k).height
        let rowCenterY = (gbaScreen.maxY + EmulatorLayoutGeometry.gbcLandscapeRowGap * k + rowH / 2) / h
        for e in [ControlElement.btnSelect, .btnMenu, .btnStart] {
            if let b = layout.buttons[e.rawValue] {
                layout.buttons[e.rawValue] = ButtonLayout(centerX: b.centerX, centerY: rowCenterY,
                                                          isHidden: b.isHidden)
            }
        }

        // Clip: nudge left so A's right edge meets Clip's left edge (A.maxX == clip.minX).
        if let a = layout.buttons[ControlElement.btnA.rawValue],
           let clip = layout.buttons[ControlElement.btnClip.rawValue] {
            let aHalf = ControlElement.btnA.defaultLandscapeSize.width / 2
            let clipHalf = ControlElement.btnClip.defaultLandscapeSize.width / 2
            let aMaxX = a.centerX * w + aHalf * k
            layout.buttons[ControlElement.btnClip.rawValue] =
                ButtonLayout(centerX: (aMaxX + clipHalf * k) / w, centerY: clip.centerY, isHidden: clip.isHidden)
        }
        return layout
    }

    // MARK: - NDS Portrait

    /// Default NDS portrait layout, normalized to the container, scaled for the device.
    static func ndsPortrait(containerSize: CGSize, scale k: CGFloat) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        let diamondR: CGFloat = 50 * k

        let dpadH = ControlElement.dpad.defaultNDSPortraitSize.width / 2
        let aH = ControlElement.btnA.defaultNDSPortraitSize.width / 2

        // btnA: trailing -24, centerY -6. X/Y/B sit on the diamond around A.
        let aCenterX = w - (24 + aH) * k
        let aCenterY = h / 2 - 6 * k
        let startCenterX = w / 2 + 32 * k
        let micCenterX = startCenterX + (26 + 12 + 26) * k

        var buttons: [String: ButtonLayout] = [:]
        buttons[ControlElement.dpad.rawValue] = ButtonLayout(
            centerX: (12 + dpadH) * k / w, centerY: (h / 2 - 6 * k) / h)
        buttons[ControlElement.btnA.rawValue] = ButtonLayout(
            centerX: aCenterX / w, centerY: aCenterY / h)
        buttons[ControlElement.btnX.rawValue] = ButtonLayout(
            centerX: (aCenterX - diamondR) / w, centerY: (aCenterY - diamondR) / h)
        buttons[ControlElement.btnY.rawValue] = ButtonLayout(
            centerX: (aCenterX - diamondR * 2) / w, centerY: aCenterY / h)
        buttons[ControlElement.btnB.rawValue] = ButtonLayout(
            centerX: (aCenterX - diamondR) / w, centerY: (aCenterY + diamondR) / h)
        // btnL: leading +16, top +8, 70x36 → center at (16 + 35, 8 + 18)
        buttons[ControlElement.btnL.rawValue] = ButtonLayout(
            centerX: (16 + 35) * k / w, centerY: (8 + 18) * k / h)
        // btnR: trailing -16, top +8
        buttons[ControlElement.btnR.rawValue] = ButtonLayout(
            centerX: (w - (16 + 35) * k) / w, centerY: (8 + 18) * k / h)
        // btnSelect: centerX -32, bottom -20, 52x36
        buttons[ControlElement.btnSelect.rawValue] = ButtonLayout(
            centerX: (w / 2 - 32 * k) / w, centerY: (h - (20 + 18) * k) / h)
        // btnStart: centerX +32, bottom -20
        buttons[ControlElement.btnStart.rawValue] = ButtonLayout(
            centerX: startCenterX / w, centerY: (h - (20 + 18) * k) / h)
        // btnMenu: centerX, top +8, 36x36
        buttons[ControlElement.btnMenu.rawValue] = ButtonLayout(
            centerX: 0.5, centerY: (8 + 18) * k / h)
        // btnMic: right of Start
        buttons[ControlElement.btnMic.rawValue] = ButtonLayout(
            centerX: micCenterX / w, centerY: (h - (20 + 18) * k) / h)
        // btnClip: left of Select, mirroring Mic on the right. All four bottom-row
        // gaps are equal at 64k: clip -96, Select -32, Start +32, Mic +96.
        buttons[ControlElement.btnClip.rawValue] = ButtonLayout(
            centerX: (w / 2 - 96 * k) / w, centerY: (h - (20 + 18) * k) / h)

        return OrientationLayout(buttons: buttons)
    }

    // MARK: - NDS Landscape

    /// Default NDS landscape layout, normalized to the container, scaled for the device.
    static func ndsLandscape(containerSize: CGSize, scale k: CGFloat) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        let faceH = ControlElement.btnA.defaultNDSLandscapeSize.width / 2
        let dpadH = ControlElement.dpad.defaultNDSLandscapeSize.width / 2

        // btnA: trailing -140, centerY -(vGap/2). X/Y on the left, B/Y a row below.
        let aCenterX = w - (140 + faceH) * k
        let aCenterY = h / 2 - (2 + faceH) * k                 // vGap/2 = 2
        // btnX: btnX.trailing = btnA.leading - (hGap + 24); hGap = 4
        let xCenterX = aCenterX - (faceH + (4 + 24) + faceH) * k
        // btnB: aCenterX - rowOffset, lower row. rowOffset = 26
        let bCenterX = aCenterX - 26 * k
        let bCenterY = h / 2 + (2 + faceH) * k
        let yCenterX = bCenterX - (faceH + (4 + 24) + faceH) * k
        var buttons: [String: ButtonLayout] = [:]
        buttons[ControlElement.dpad.rawValue] = ButtonLayout(
            centerX: (110 + dpadH) * k / w, centerY: (h / 2 - 4 * k) / h)
        buttons[ControlElement.btnA.rawValue] = ButtonLayout(
            centerX: aCenterX / w, centerY: aCenterY / h)
        buttons[ControlElement.btnX.rawValue] = ButtonLayout(
            centerX: xCenterX / w, centerY: aCenterY / h)
        buttons[ControlElement.btnB.rawValue] = ButtonLayout(
            centerX: bCenterX / w, centerY: bCenterY / h)
        buttons[ControlElement.btnY.rawValue] = ButtonLayout(
            centerX: yCenterX / w, centerY: bCenterY / h)
        // btnL/R extend above the controls area (negative normalized Y is valid).
        // leading +65, center at (65 + 20, -50)
        buttons[ControlElement.btnL.rawValue] = ButtonLayout(
            centerX: (65 + 20) * k / w, centerY: -50 * k / h)
        buttons[ControlElement.btnR.rawValue] = ButtonLayout(
            centerX: (w - (65 + 20) * k) / w, centerY: -50 * k / h)
        // Bottom row, centered: SELECT · CLIP · START. Clip takes the centered slot
        // between Select and Start (the spot Mic used to hold). Select/Start keep their
        // ±66k spots — ×k so they shrink toward center on the iPhone SE and stay clear
        // of the face buttons (a FIXED offset would push START under the Y button there).
        // ±66 gives ~14pt gaps to the 36-wide Clip on the 14 Pro.
        let bottomRowY = (h - (24 + 18) * k) / h
        buttons[ControlElement.btnSelect.rawValue] = ButtonLayout(
            centerX: (w / 2 - 66 * k) / w, centerY: bottomRowY)
        buttons[ControlElement.btnClip.rawValue] = ButtonLayout(
            centerX: 0.5, centerY: bottomRowY)
        buttons[ControlElement.btnStart.rawValue] = ButtonLayout(
            centerX: (w / 2 + 66 * k) / w, centerY: bottomRowY)
        // Mic moves to the bottom-right corner, out of the thumb path: its right edge
        // lines up under the R bar's right edge (R center w−85k, half 20k → right edge
        // w−65k; Mic half 26k → center w−91k) and its bottom edge matches the
        // Select/Start row (same bottomRowY, both 36 tall).
        buttons[ControlElement.btnMic.rawValue] = ButtonLayout(
            centerX: (w - 91 * k) / w, centerY: bottomRowY)
        // Second line just below the screens: MENU alone, horizontally centered. Clip
        // used to share this line; with Clip moved to the bottom row, Menu recenters to
        // 0.5 — the prime, most-reachable spot for the most-used button. centerY sits
        // the row ~10pt below the screens (the container top), using the rendered
        // half-height 18 so it lands the same on every device.
        let topLineY = (10 + 18) / h
        buttons[ControlElement.btnMenu.rawValue] = ButtonLayout(
            centerX: 0.5, centerY: topLineY)

        return OrientationLayout(buttons: buttons)
    }

    // MARK: - Helpers

    /// Returns the appropriate default layout for the given system + orientation.
    /// GB/GBC reuses the GBA button positions but with the L/R shoulder buttons
    /// removed (GB/GBC hardware has none), so those views stay hidden in-game.
    /// `safeLeftInset` is the leading safe-area inset (only GB/GBC landscape uses it,
    /// to keep the D-pad clear of the Dynamic Island); 0 elsewhere has no effect.
    static func defaultLayout(system: PresetSystem, isLandscape: Bool,
                              containerSize: CGSize, scale: CGFloat,
                              safeLeftInset: CGFloat = 0,
                              safeRightInset: CGFloat = 0) -> OrientationLayout {
        switch system {
        case .nds:
            return isLandscape ? ndsLandscape(containerSize: containerSize, scale: scale)
                               : ndsPortrait(containerSize: containerSize, scale: scale)
        case .gba:
            return isLandscape ? gbaLandscape(containerSize: containerSize, scale: scale,
                                              safeLeftInset: safeLeftInset)
                               : gbaPortrait(containerSize: containerSize, scale: scale)
        case .gbc:
            // GB/GBC has its own layout in both orientations (no L/R by construction).
            return isLandscape ? gbcLandscape(containerSize: containerSize, scale: scale,
                                              safeLeftInset: safeLeftInset)
                               : gbcPortrait(containerSize: containerSize, scale: scale)
        case .snes:
            return snes(containerSize: containerSize, scale: scale,
                        isLandscape: isLandscape, safeLeftInset: safeLeftInset,
                        safeRightInset: safeRightInset)
        case .nes:
            return nes(containerSize: containerSize, scale: scale,
                       isLandscape: isLandscape, safeLeftInset: safeLeftInset)
        case .ps1:
            return ps1(containerSize: containerSize, scale: scale,
                       isLandscape: isLandscape, safeLeftInset: safeLeftInset,
                       safeRightInset: safeRightInset)
        }
    }

    // MARK: - PlayStation

    /// The skirt of body the dress keeps around the picture, in reference points.
    ///
    /// HALF IN LANDSCAPE: that page gives the picture almost the whole height,
    /// and the skirt that reads as an inlaid frame in portrait reads as a border
    /// eating the page there. Read by `PlayStationSkin.drawScreenPanel`, which
    /// draws it, and by the landscape layout, which places the SELECT · MENU ·
    /// START row below it — the row sits under what a player SEES, and what they
    /// see is the frame rather than the picture inside it.
    static let ps1PortraitSkirt: CGFloat = 14
    static let ps1LandscapeSkirt: CGFloat = 7

    /// How far each face sits from the diamond's centre, as a fraction of its own
    /// width. The portrait page's own proportion (50 against a 63.8 face), reused
    /// so landscape rebuilds the SAME lozenge rather than a second one that
    /// happens to look similar.
    static let diamondStep: CGFloat = 50.0 / 63.8

    /// The gap inside a shoulder PAIR, in reference points.
    ///
    /// TWO VALUES, and the wide one belongs to the SHARE CARD alone. Both
    /// playing pages keep the tight pair: portrait's row is pinned at three
    /// points and already paid for in width (at 24 the R pair closes to 1.6
    /// points of MENU on a 14 Pro), and landscape's was right as it was. The
    /// card is a portrait of the machine rather than a page to play on, and
    /// there the pair reads better with air between its two bars.
    static let shoulderPairGap: CGFloat = 6
    static let shoulderPairGapCard: CGFloat = 24

    /// How far CLIP sits from the two page edges it is cornered against in
    /// portrait, in reference points. It was the sticks' own page margin while a
    /// stick shared that corner and every point of clearance counted; the sticks
    /// have since moved under their blocks, so it is a real margin now.
    static let clipCornerMargin: CGFloat = 16

    /// How far a stick's raised boss shows PAST the stick, as a fraction of the
    /// stick's own diameter. It is the visible RING that is sized here, not the
    /// boss: scaling the whole boss scales the stick's footprint with it, which
    /// turns a collar into a saucer.
    static let ps1StickBossRing: CGFloat = 0.15
    /// The boss's full diameter against its stick's.
    static var ps1StickBossSpan: CGFloat { 1 + ps1StickBossRing * 2 }

    /// A raised plateau's diameter against the cluster it grounds.
    ///
    /// What the portrait page's own rule works out to on the reference device
    /// (218.9 around a 159.5 cross), carried to landscape and to the share card
    /// so the same console does not wear three different proportions. It lives
    /// here rather than in the skin because the CARD lays itself out around
    /// these two circles, and a layout that guessed at their size would be a
    /// second copy of a number the dress already owns.
    static let ps1PlateauScale: CGFloat = 1.37

    /// The gap between a stick and its click button, in reference points. One
    /// number for both orientations: the pairing reads the same either way.
    static let stickClickGap: CGFloat = 6

    /// How far a stick sits from the page edge it is anchored to, in reference
    /// points. The sticks are the only controls on any page placed from the
    /// bottom edge rather than from a neighbour, because they are the last thing
    /// to be fitted and the edge is the one measurement that cannot move.
    static let stickPageMargin: CGFloat = 8

    /// Clearance a stick keeps from whatever sits above it, in reference points.
    /// It is larger than the shoulder stack's gap on purpose: a stick is dragged
    /// rather than tapped, so a thumb crossing its rim is normal use.
    static let stickClearance: CGFloat = 10

    /// The PlayStation page: the Super Nintendo's, carrying five more controls.
    ///
    /// A second shoulder each side, the ANALOG switch, and two sticks. Those five
    /// do not fit by being dropped into the gaps, because the page was already
    /// full at six controls a side. Making room is most of what this function
    /// does, and the two orientations have to make it in different places,
    /// because they are different pages: portrait has a tall band under the
    /// picture and no gutters, landscape has two gutters and almost no band.
    ///
    /// Every position below is DERIVED from what `snes()` placed, never written
    /// as a coordinate. So the cross, the diamond and the utility row stay
    /// exactly where the other six consoles put them, and a control moves only
    /// when it genuinely does not fit, only as far as it must, and only on the
    /// devices where that is true.
    static func ps1(containerSize: CGSize, scale k: CGFloat, isLandscape: Bool,
                    safeLeftInset: CGFloat, safeRightInset: CGFloat = 0) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        var layout = snes(containerSize: containerSize, scale: k, isLandscape: isLandscape,
                          safeLeftInset: safeLeftInset, safeRightInset: safeRightInset,
                          system: .ps1)

        // Everything below works in POINTS and converts once on the way back out.
        // The layout stores fractions of the container, and doing collision
        // arithmetic in fractions is how a page ends up with the right numbers in
        // the wrong units.
        func size(_ element: ControlElement) -> CGSize {
            EmulatorLayoutGeometry.buttonSize(element, system: .ps1, isLandscape: isLandscape,
                                              deviceScale: k)
        }
        func frame(_ element: ControlElement) -> CGRect? {
            guard let b = layout.buttons[element.rawValue] else { return nil }
            let s = size(element)
            return CGRect(x: b.centerX * w - s.width / 2, y: b.centerY * h - s.height / 2,
                          width: s.width, height: s.height)
        }
        func setCentre(_ element: ControlElement, x: CGFloat, y: CGFloat) {
            let hidden = layout.buttons[element.rawValue]?.isHidden ?? false
            layout.buttons[element.rawValue] = ButtonLayout(centerX: x / w, centerY: y / h,
                                                            isHidden: hidden)
        }
        /// Half the raised ring the dress draws around a stick.
        func ps1BossHalf(_ stick: CGRect) -> CGFloat {
            max(stick.width, stick.height) * ps1StickBossSpan / 2
        }
        func moveUp(_ elements: [ControlElement], by dy: CGFloat) {
            guard dy > 0 else { return }
            for element in elements {
                guard let b = layout.buttons[element.rawValue] else { continue }
                layout.buttons[element.rawValue] = ButtonLayout(
                    centerX: b.centerX, centerY: b.centerY - dy / h, isHidden: b.isHidden)
            }
        }

        let faces: [ControlElement] = [.btnA, .btnB, .btnX, .btnY]
        let stick = size(.stickLeft)

        if isLandscape {
            // The picture is CENTRED on this page (see `screenFrame`), so it
            // leaves an equal band at each end and two wide gutters. Everything
            // below is placed against one of those three: the lower band takes
            // the row, and each gutter takes one thumb's worth of controls.
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: containerSize, safeInsets: .zero, hasTouchScreen: false,
                isLandscape: true, gameAspect: PresetLayoutResolver.displayAspect(.ps1),
                system: .ps1, controllerConnected: false, deviceScale: k)
            // The dress's own skirt, so nothing is placed against the picture
            // when what a player sees is the frame around it.
            let surroundBottom = screen.maxY + ps1LandscapeSkirt * k

            // TWO BARS TO A GUTTER, side by side on the line the first one
            // already holds. Stacked, they ate a gutter's depth that the cross
            // and the diamond need; across, the gutter has the width to spare.
            // Each pair grows INWARD from the edge its single bar already hugged,
            // rather than spreading about that bar's centre: a pair is more than
            // twice as wide as the bar it replaces, so centred on it, half of it
            // would be off the side of the phone. The outer bar keeps the outer
            // edge, and its partner takes the room toward the picture.
            for (first, second, towardCentre) in
                [(ControlElement.btnL, ControlElement.btnL2, CGFloat(1)),
                 (.btnR, .btnR2, CGFloat(-1))] {
                guard let anchor = frame(first) else { continue }
                let bar = size(first).width
                let outerEdge = towardCentre > 0 ? anchor.minX : anchor.maxX
                let outerCentre = outerEdge + towardCentre * bar / 2
                setCentre(first, x: outerCentre, y: anchor.midY)
                setCentre(second, x: outerCentre + towardCentre * (bar + shoulderPairGap * k),
                          y: anchor.midY)
            }

            // THE DIAMOND BECOMES A DIAMOND. It arrives from the DS's landscape
            // page, where the four sit in a square-ish cluster; this pad wears
            // the same lozenge in both orientations, so the PORTRAIT arrangement
            // is rebuilt here around the right gutter's centre. `diamondStep` is
            // the portrait proportion, not a second number: 50 against a 63.8
            // face is what that page uses.
            let faceSize = size(.btnA).width
            let step = faceSize * diamondStep
            let gutterR = (screen.maxX + w) / 2
            let blocY = screen.midY
            for (element, dx, dy) in [(ControlElement.btnA, step, CGFloat(0)),
                                      (.btnY, -step, 0),
                                      (.btnX, CGFloat(0), -step),
                                      (.btnB, 0, step)] {
                setCentre(element, x: gutterR + dx, y: blocY + dy)
            }

            // THE CROSS takes the mirror of that in the left gutter, so the two
            // thumbs sit at the same height and the same distance in.
            setCentre(.dpad, x: w - gutterR, y: blocY)

            // SELECT · MENU · START, centred in the band under the picture.
            //
            // Measured from the SURROUND rather than the picture: the skirt is
            // what a player sees the row sitting below. MENU keeps the middle
            // here, unlike portrait, because in landscape this row is the only
            // thing in the band and the middle is the one slot that reads as
            // belonging to the page rather than to a hand.
            let rowY = (surroundBottom + h) / 2
            let row: [ControlElement] = [.btnSelect, .btnMenu, .btnStart]
            let gap = 10 * k
            let rowWidth = row.reduce(CGFloat(0)) { $0 + size($1).width }
                + gap * CGFloat(row.count - 1)
            var x = w / 2 - rowWidth / 2
            for element in row {
                let width = size(element).width
                setCentre(element, x: x + width / 2, y: rowY)
                x += width + gap
            }

            // CLIP AND ANALOG hug the picture, one each side, on the line under
            // their own gutter's bars. They are the two controls on this page
            // that belong to nobody's thumb: one is ours and one is a mode
            // switch, so they take the strip beside the screen that no thumb
            // reaches across.
            let hug = 10 * k
            for (element, onRight) in [(ControlElement.btnClip, true),
                                       (.btnMode, false)] {
                let size0 = size(element)
                let barBottom = (frame(onRight ? .btnR : .btnL)?.maxY ?? 0)
                let y = barBottom + stickClearance * k + size0.height / 2
                let x = onRight
                    ? screen.maxX + hug + size0.width / 2
                    : screen.minX - hug - size0.width / 2
                setCentre(element, x: x, y: y)
            }

            // THE STICKS take the bottom of each gutter, where the thumbs rest.
            let stickY = h - stickPageMargin * k - stick.height / 2
            // The right stick takes X's LEFT EDGE as its centre line, not the
            // diamond's middle. The diamond is not symmetric about the thumb
            // that works it -- X is its top vertex and the stick sits below and
            // inboard of the whole bloc, which is where a DualShock puts it.
            if let x = frame(.btnX) {
                setCentre(.stickRight, x: x.minX, y: stickY)
                // AND THE LEFT ONE MIRRORS IT ACROSS THE PICTURE. It sat under
                // the cross's own centre line, which put it noticeably further
                // out than its partner once the right one moved inboard to X's
                // edge. Measured as a distance FROM THE PICTURE rather than as a
                // position, so the two stay a pair on every device.
                let inset = x.minX - screen.maxX
                setCentre(.stickLeft, x: screen.minX - inset, y: stickY)
            }

            // L3 and R3 go OUTBOARD of their stick, on its line: the gutter
            // above a stick is the pad or the diamond, while the strip between a
            // stick and the page edge is empty and is where the thumb already is.
            // From the BOSS's edge, as in portrait: the raised ring is what a
            // player reads as the stick's extent.
            let clickGap = stickClickGap * k
            let click = size(.btnL3)
            if let stick = frame(.stickLeft) {
                setCentre(.btnL3,
                          x: max(stick.midX - ps1BossHalf(stick) - clickGap - click.width / 2,
                                 click.width / 2 + 4 * k),
                          y: stick.midY)
            }
            if let stick = frame(.stickRight) {
                setCentre(.btnR3,
                          x: min(stick.midX + ps1BossHalf(stick) + clickGap + click.width / 2,
                                 w - click.width / 2 - 4 * k),
                          y: stick.midY)
            }
        } else {
            // THE CROSS RISES until its centre is where its UP KEY reads.
            //
            // A cross is aimed at the direction under the thumb, not at the
            // middle of the square it is drawn in, and on this pad the four keys
            // are separate mouldings with a hole between them, so the middle of
            // the square is literally nothing. `ps1UpKeyMiddle` comes from the
            // shape the cross draws, so the two cannot drift apart.
            let padSize = size(.dpad)
            let rise = CrossDPadView.ps1UpKeyMiddle * padSize.height
            moveUp([ControlElement.dpad] + faces, by: rise)

            // THE DIAMOND SLIDES RIGHT until its margin mirrors the cross's.
            //
            // The two blocks are the page's two thumbs and they arrive from
            // different consoles, so nothing had been making them symmetric: the
            // cross sat 12pt from its edge and the diamond 24 from its. Measured
            // from the placed frames rather than from the numbers that produced
            // them, because both are floored on small devices.
            if let pad = frame(.dpad) {
                let placed = faces.compactMap { frame($0) }
                if let right = placed.map(\.maxX).max() {
                    let shift = (w - pad.minX) - right
                    for element in faces {
                        guard let b = layout.buttons[element.rawValue] else { continue }
                        layout.buttons[element.rawValue] = ButtonLayout(
                            centerX: b.centerX + shift / w, centerY: b.centerY,
                            isHidden: b.isHidden)
                    }
                }
            }

            // ONE LINE OF FIVE: L1 · L2 · MENU · R1 · R2.
            //
            // Each pair sits over the cluster its fingers serve: the L pair on
            // the cross's centre line, the R pair on the diamond's, MENU on the
            // page's. Those are three fixed points, so the row is paid for in
            // WIDTH rather than in position — `ps1PortraitShoulderWidth`, 55
            // against the 90 every other console's pair takes.
            //
            // The bars are also SHALLOWER than the row they inherit, and the row
            // holds its TOP edge rather than its centre while they shrink: the
            // top edge is the one that faces the picture, and a row that thinned
            // about its middle would have opened a gap under the screen instead
            // of at the bottom of the page, where this console needs it.
            //
            // The two gaps either side of MENU came out EQUAL once the diamond
            // moved (about 25pt each on a 14 Pro). They were not, and this note
            // used to say they could not be: MENU is centred on the page, and the
            // cross and the diamond were not symmetric about it. The rise-and-
            // mirror pass above made them symmetric, so the row centres for free.
            // Nothing here enforces it -- it is a consequence of the two blocks,
            // and it is `ps1ShouldersSitFourAcrossAndNeverTouch` that would notice
            // if a future move to either block reopened the gap.
            if let rowY = layout.buttons[ControlElement.btnL.rawValue]?.centerY,
               let pad = frame(.dpad) {
                // The height the inherited row was laid out with, so the top edge
                // is recovered rather than re-stated as a literal.
                let inherited = EmulatorLayoutGeometry.buttonSize(
                    .btnL, system: .snes, isLandscape: false, deviceScale: k).height
                let rowCentre = rowY * h - (inherited - size(.btnL).height) / 2
                let step = (size(.btnL).width + shoulderPairGap * k) / 2
                let bloc = faces.compactMap { frame($0) }
                let diamondX = bloc.isEmpty
                    ? w / 2
                    : ((bloc.map(\.minX).min() ?? 0) + (bloc.map(\.maxX).max() ?? 0)) / 2
                for (element, x) in [(ControlElement.btnL, pad.midX - step),
                                     (.btnL2, pad.midX + step),
                                     (.btnR, diamondX - step),
                                     (.btnR2, diamondX + step)] {
                    setCentre(element, x: x, y: rowCentre)
                }
                setCentre(.btnMenu, x: w / 2, y: rowCentre)
            }

            // THE STICKS go UNDER the two blocks, which is where the hardware
            // puts them.
            //
            // They could not before: the cross sat low enough that the band under
            // it covered SELECT and START, so the sticks were exiled to the lanes
            // either side. The cross rising is what opened this band, and it is
            // the reason the two moves belong in one pass.
            //
            // Stepped INWARD from their block by half an arrow's width, so each
            // stick sits under the inner half of the cluster it serves rather
            // than square under its centre. That is the DualShock's own offset.
            let arrowHalf = padSize.width * CrossDPadView.ps1ArmRatioShared / 2
            let blocks = ([ControlElement.dpad] + faces).compactMap { frame($0)?.maxY }
            // The band under the blocks has to clear the STICK and also the half
            // of ANALOG that sits above the stick's top edge, because that is
            // where ANALOG is centred (below). Without the second term ANALOG
            // reaches back up into the cross's hitbox: only by a point, but the
            // cross claims its whole frame past a small deadzone, so a point
            // there is a real diagonal firing under the mode switch.
            let modeLift = size(.btnMode).height / 2 + stickClickGap * k
            let blockGap = max(stickClearance * k, modeLift)
            let stickY = (blocks.max() ?? 0) + blockGap + stick.height / 2
            let placedFaces = faces.compactMap { frame($0) }
            let diamondX = placedFaces.isEmpty
                ? w / 2
                : ((placedFaces.map(\.minX).min() ?? 0) + (placedFaces.map(\.maxX).max() ?? 0)) / 2
            if let pad = frame(.dpad) {
                setCentre(.stickLeft, x: pad.midX + arrowHalf, y: stickY)
            }
            setCentre(.stickRight, x: diamondX - arrowHalf, y: stickY)

            // L3 and R3 go OUTBOARD of their own stick, on its line — the same
            // rule landscape already uses, and now available here because the
            // sticks have left the page edges. It replaces hiding them on short
            // phones: the band above a stick was never 40pt on an SE, but the
            // margin beside one is, so on that device these two become visible
            // for the first time.
            // MEASURED FROM THE BOSS, not from the stick. The stick wears a
            // raised ring the dress draws around it, and a gap taken from the
            // cap put the click button inside that ring: the space a player
            // sees is the space to the RING's edge, so that is what is set.
            let click = size(.btnL3)
            if let s = frame(.stickLeft) {
                setCentre(.btnL3, x: s.midX - ps1BossHalf(s) - stickClickGap * k - click.width / 2,
                          y: s.midY)
            }
            if let s = frame(.stickRight) {
                setCentre(.btnR3, x: s.midX + ps1BossHalf(s) + stickClickGap * k + click.width / 2,
                          y: s.midY)
            }

            // ANALOG between the two sticks, which is where the pad prints it and
            // what it is for: it switches the very controls either side of it.
            // It used to sit between SELECT and START, spreading that pair to
            // make room; that spread went with it, so those two are back in the
            // columns the Game Boy layout gave them.
            //
            // On the sticks' TOP rather than their centre line. Centred between
            // them it read as a third control in a row of three; level with
            // where they begin, it reads as the label over the pair, which is
            // what it is.
            setCentre(.btnMode, x: w / 2, y: stickY - stick.height / 2)

            // CLIP CROSSES TO THE BOTTOM RIGHT: R3's column, on the row SELECT
            // and START arrive on.
            //
            // Both anchors are controls rather than page edges. It sits at the
            // outboard end of its row and on the side away from the cross, so
            // the hand that is steering never passes over it, and the corner it
            // leaves is where the brand mark goes.
            // SELECT, START and CLIP are ONE LINE, and the line is centred in
            // the band the sticks leave under them: that band is the only empty
            // space left on this page, and a row floating above its middle was
            // the last thing here still sitting where an inherited layout had
            // put it rather than where this page's own furniture allows.
            let clip = size(.btnClip)
            let stickBottom = frame(.stickLeft).map { $0.maxY } ?? (h / 2)
            let markLine = (stickBottom + h) / 2
            setCentre(.btnClip,
                      x: min(frame(.btnR3)?.midX ?? (w - clipCornerMargin * k - clip.width / 2),
                             w - clipCornerMargin * k - clip.width / 2),
                      y: markLine)

            // AND SELECT AND START DROP, so that what a player SEES lines up.
            //
            // Their hitbox holds a shape AND a word under it, centred as one
            // block, so the shape itself rides above the hitbox's middle by half
            // the gap and the word. CLIP's disc has no word and sits dead centre.
            // Matching the two hitboxes therefore leaves the three marks visibly
            // staggered; matching the MARKS means dropping these two by exactly
            // that rise. `PS1Shape.shapeRise` is the same call the button draws
            // its block from, so the two cannot disagree about the number.
            for element in [ControlElement.btnSelect, .btnStart] {
                guard let f = frame(element),
                      let style = SmallButton.PS1Shape.style(for: element) else { continue }
                setCentre(element, x: f.midX,
                          y: markLine + SmallButton.PS1Shape.shapeRise(style, f))
            }
        }

        return layout
    }

    // MARK: - SNES

    /// How far each face PAIR steps away from the other along the perpendicular to their shared
    /// diagonal, in reference points, so the dress's two capsules stop overlapping. See the
    /// portrait block in `snes` for the arithmetic.
    static let facePairSeparation: CGFloat = 5

    /// The SNES layout, in either orientation.
    ///
    /// Composed to the spec rather than invented: the D-pad and the four
    /// face buttons take the DS's positions, because the SNES pad is that shape,
    /// and SELECT/START take the Game Boy's, because they are that pair. The
    /// shoulders come from the GBA, which is the only other console here that has
    /// them, and Menu and Clip follow the GBA too.
    ///
    /// Sizes follow the same split through
    /// `EmulatorLayoutGeometry.referenceSize(_:system:isLandscape:)`, so what is
    /// drawn matches what is positioned.
    /// - Parameter system: whose page this is. Defaults to the Super Nintendo,
    ///   so that console's answers are untouched; the PlayStation passes its own
    ///   because it borrows this whole layout and does NOT borrow the picture.
    ///   The two shapes really differ, 4:3 against 8:7, and in landscape the
    ///   gutters are what is left over after the picture, so laying out a
    ///   PlayStation page against a Super Nintendo's picture would have put its
    ///   buttons over the game.
    static func snes(containerSize: CGSize, scale k: CGFloat, isLandscape: Bool,
                     safeLeftInset: CGFloat, safeRightInset: CGFloat = 0,
                     system: PresetSystem = .snes) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        // The GBA layout is the base: it already places L/R, Menu and Clip around
        // a single screen, which is the shape of this console's page.
        var layout = isLandscape
            ? gbaLandscape(containerSize: containerSize, scale: k, safeLeftInset: safeLeftInset)
            : gbaPortrait(containerSize: containerSize, scale: k)

        // The pad: D-pad and diamond, straight from the DS. In LANDSCAPE the D-pad is the
        // exception and stays the GBA's, position and size both, because that page is the
        // GBA's page and the GBA already parks a pad in its left gutter. The size table makes
        // the same exception (`snesLandscapeUsesGBAPad`), and it has to: a position from one
        // console and a size from another is how a pad ends up overlapping the picture.
        let ds = isLandscape
            ? ndsLandscape(containerSize: containerSize, scale: k)
            : ndsPortrait(containerSize: containerSize, scale: k)
        for element in EmulatorLayoutGeometry.snesUsesNDSSizing {
            if isLandscape && element == .dpad && EmulatorLayoutGeometry.snesLandscapeUsesGBAPad {
                continue
            }
            if let placed = ds.buttons[element.rawValue] {
                layout.buttons[element.rawValue] = placed
            }
        }

        // SELECT and START: the Game Boy's pair, in the Game Boy's place.
        let gb = isLandscape
            ? gbcLandscape(containerSize: containerSize, scale: k, safeLeftInset: safeLeftInset)
            : gbcPortrait(containerSize: containerSize, scale: k)
        for element in [ControlElement.btnSelect, .btnStart] {
            if let placed = gb.buttons[element.rawValue] {
                layout.buttons[element.rawValue] = placed
            }
        }

        // LANDSCAPE. In portrait the screen is full-width at the top and the whole page below
        // it belongs to the controls, so the DS's positions transfer as they are. Landscape is
        // a different page: one panel in the middle with a gutter each side, and the controls
        // are drawn OVER it. The DS's landscape positions assume its own page (screens above,
        // controls below, full width), so used literally they put the D-pad and the X/Y buttons
        // on top of the game. The SHAPE stays the DS's, as specified; what moves is where the
        // two blocks sit, which is the Game Boy's rule on this page: each in its own gutter.
        if isLandscape {
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: containerSize, safeInsets: .zero, hasTouchScreen: false,
                isLandscape: true, gameAspect: PresetLayoutResolver.displayAspect(system),
                system: system, controllerConnected: false, deviceScale: k)
            let sidePad = 8 * k        // matches the dress's landscape panel margin

            // The D-pad is untouched here: it is the GBA's, and gbcLandscape already centred it
            // in the SAFE left gutter, which is the same rule this used to apply by hand.

            // The diamond: moved as ONE block into the right gutter, so the four buttons keep
            // the DS's exact arrangement relative to each other.
            let faces: [ControlElement] = [.btnA, .btnB, .btnX, .btnY]
            var minX = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            for element in faces {
                guard let b = layout.buttons[element.rawValue] else { continue }
                let size = EmulatorLayoutGeometry.buttonSize(element, system: system,
                                                             isLandscape: true, deviceScale: k)
                minX = Swift.min(minX, b.centerX * w - size.width / 2)
                maxX = Swift.max(maxX, b.centerX * w + size.width / 2)
            }
            if minX < maxX {
                // The SAFE right gutter, not the raw one. In the other landscape rotation the
                // Dynamic Island is on THIS side, and centring on the full width put the block
                // under it: on a 14 Pro the island covers 59pt of a gutter the four buttons
                // very nearly fill. Nothing is resized to fix that — the picture giving up a
                // little width (see `snesLandscapeTopMargin`) is what made the gutter wide
                // enough to hold the block clear of both the island and the game.
                let gutterCentre = (screen.maxX + sidePad + (w - safeRightInset)) / 2
                let shift = gutterCentre - (minX + maxX) / 2
                for element in faces {
                    guard let b = layout.buttons[element.rawValue] else { continue }
                    layout.buttons[element.rawValue] = ButtonLayout(
                        centerX: b.centerX + shift / w, centerY: b.centerY, isHidden: b.isHidden)
                }
            }

            // SELECT · MENU · START: one line, under THIS console's screen. They arrive from two
            // different consoles (SELECT/START the Game Boy's, MENU the GBA's), each stuck to its
            // own console's screen bottom, so left alone they render as a staggered row.
            let rowH = EmulatorLayoutGeometry.buttonSize(.btnStart, system: system,
                                                         isLandscape: true, deviceScale: k).height
            let rowY = (screen.maxY + EmulatorLayoutGeometry.gbcLandscapeRowGap * k + rowH / 2) / h
            for element in [ControlElement.btnSelect, .btnMenu, .btnStart] {
                guard let b = layout.buttons[element.rawValue] else { continue }
                layout.buttons[element.rawValue] =
                    ButtonLayout(centerX: b.centerX, centerY: rowY, isHidden: b.isHidden)
            }

            // CLIP: the RIGHT gutter, in R's column, on the line the Retro Pal plaque takes.
            //
            // It used to sit under L in the left gutter, and that gutter is also where the dress
            // prints the plaque, so the two shared one band. Crossing CLIP to the right empties
            // that band for the plaque and puts the lesser action on the side away from the pad,
            // which is the hand that is not steering.
            //
            // The line itself is `DressKind.snesLandscapeUtilityCenterY`, the SAME call the dress
            // makes for the plaque, so "the same vertical position" is one formula rather than two
            // that happen to agree today. Both shoulders feed it: they are one row, and taking the
            // lower of the two edges means the line clears whichever side it is measured from.
            if let clip = layout.buttons[ControlElement.btnClip.rawValue],
               let r = layout.buttons[ControlElement.btnR.rawValue],
               let l = layout.buttons[ControlElement.btnL.rawValue],
               let pad = layout.buttons[ControlElement.dpad.rawValue] {
                func bottom(_ e: ControlElement, _ b: ButtonLayout) -> CGFloat {
                    b.centerY * h + EmulatorLayoutGeometry.buttonSize(
                        e, system: system, isLandscape: true, deviceScale: k).height / 2
                }
                let padTop = pad.centerY * h - EmulatorLayoutGeometry.buttonSize(
                    .dpad, system: system, isLandscape: true, deviceScale: k).height / 2
                let y = DressKind.snesLandscapeUtilityCenterY(
                    shoulderBottom: Swift.max(bottom(.btnL, l), bottom(.btnR, r)), padTop: padTop)
                layout.buttons[ControlElement.btnClip.rawValue] =
                    ButtonLayout(centerX: r.centerX, centerY: y / h, isHidden: clip.isHidden)
            }
            alignFacesToPad(&layout)
            return layout
        }

        // PORTRAIT, the two face PAIRS pull apart, and the four buttons travel with them.
        //
        // The dress draws one capsule over B and A and another over X and Y, which is the real
        // pad's pair of plateaus. Taken straight from the DS those two overlap: the diamond puts
        // their centre lines 70.7pt apart (50 · √2) while each capsule is 75.8pt thick, so they
        // cross in the middle. Each pair therefore steps `facePairSeparation` along the
        // perpendicular, X and Y up-left, A and B down-right, which opens about 5pt of body
        // between them and leaves both inside the ring (the ring is derived from the buttons, so
        // it follows them out).
        //
        // Symmetric on purpose: equal and opposite steps leave the bloc's centre exactly where
        // it was, which is the D-pad's line, and `theFaceBlocSharesThePadsLine` holds that.
        // NOT ON THE PLAYSTATION. The step below exists for the Super Nintendo's
        // dress, which draws one capsule over B and A and another over X and Y:
        // taken straight from the DS those two capsules cross, so each pair
        // steps apart along the diagonal. This console has no capsules. Its four
        // buttons are four separate mouldings at equal distance, and separating
        // the pairs here made the diamond read as two pills, which is the Super
        // Nintendo's shape rather than this one's.
        if !isLandscape && system != .ps1 {
            let step = Self.facePairSeparation * k / CGFloat(2).squareRoot()   // along (±1, ±1)/√2
            let moves: [(ControlElement, CGFloat)] = [(.btnX, -1), (.btnY, -1), (.btnA, 1), (.btnB, 1)]
            for (element, direction) in moves {
                guard let b = layout.buttons[element.rawValue] else { continue }
                layout.buttons[element.rawValue] = ButtonLayout(
                    centerX: b.centerX + direction * step / w,
                    centerY: b.centerY + direction * step / h,
                    isHidden: b.isHidden)
            }
        }

        alignFacesToPad(&layout)

        // CLIP, portrait. The GBA parks it just under the A button, which on that console
        // is a lone face button with empty case above it. Here A is the RIGHT vertex of a
        // diamond, and the X button occupies exactly that empty case: measured on the real
        // page (safe-area insets included, which is what shortens the controls container),
        // the inherited spot lands 8pt inside X on a 14 Pro and 16pt on an SE. So Clip
        // joins the bottom row instead, on SELECT and START's line and in A's column,
        // which is also where the DS puts its own.
        if !isLandscape,
           let clip = layout.buttons[ControlElement.btnClip.rawValue],
           let a = layout.buttons[ControlElement.btnA.rawValue],
           let row = layout.buttons[ControlElement.btnSelect.rawValue] {
            layout.buttons[ControlElement.btnClip.rawValue] =
                ButtonLayout(centerX: a.centerX, centerY: row.centerY, isHidden: clip.isHidden)
        }

        return layout
    }

    /// Put the four face buttons' vertical centre on the D-pad's, wherever the pad is.
    ///
    /// PORTRAIT it changes nothing and is there so it cannot start to: the pad and the diamond
    /// both come from the DS, both at `h/2 − 6`, so the two lines coincided by accident of
    /// shared parentage rather than by design.
    ///
    /// LANDSCAPE it is a real move of 39 reference points. The pad is the GBA's, which sits
    /// BELOW the mid-line (`h/2 + 39`) because that console's page is a picture with a gutter
    /// each side and the pad is placed for a thumb; the four faces are the DS's, centred on the
    /// mid-line. Composed, they came out staggered — the pad low, the buttons high — which is
    /// exactly the seam you get for free when a layout is assembled from two consoles.
    private static func alignFacesToPad(_ layout: inout OrientationLayout) {
        guard let pad = layout.buttons[ControlElement.dpad.rawValue] else { return }
        let faces: [ControlElement] = [.btnA, .btnB, .btnX, .btnY]
        let ys = faces.compactMap { layout.buttons[$0.rawValue]?.centerY }
        guard let lo = ys.min(), let hi = ys.max() else { return }
        let shift = pad.centerY - (lo + hi) / 2
        guard abs(shift) > 0.0001 else { return }
        for element in faces {
            guard let b = layout.buttons[element.rawValue] else { continue }
            layout.buttons[element.rawValue] = ButtonLayout(
                centerX: b.centerX, centerY: b.centerY + shift, isHidden: b.isHidden)
        }
    }

    // MARK: - NES

    /// The NES layout: the Game Boy's, with one clamp.
    ///
    /// The button set IS the Game Boy's, so the layout is the Game Boy's rather than a copy
    /// of it. What differs is the SCREEN above it: the NES draws 4:3 where GB/GBC draw their
    /// squarer shape, so on a given phone the picture is taller and the controls container is
    /// shorter. Clip is anchored to the top of that container and A to its bottom, so the two
    /// close on each other as it shrinks — on an iPhone SE, by 4pt too much. The clamp keeps
    /// Clip a clear gap above A and does nothing at all where there is room, so the layout
    /// stays the Game Boy's on every other device.
    static func nes(containerSize: CGSize, scale k: CGFloat,
                    isLandscape: Bool, safeLeftInset: CGFloat) -> OrientationLayout {
        var layout = isLandscape
            ? gbcLandscape(containerSize: containerSize, scale: k, safeLeftInset: safeLeftInset)
            : gbcPortrait(containerSize: containerSize, scale: k)
        let h = containerSize.height
        guard h > 0 else { return layout }

        // LANDSCAPE: re-stick SELECT · MENU · START to THIS console's screen, CENTRED in the strip
        // the picture leaves below itself.
        //
        // `gbcLandscape` computes that row against the GAME BOY's screen, which is a different
        // height, so inherited unchanged the row sat 14pt too high and the sweep caught it
        // sitting ON the picture. The Super Nintendo needed the same correction for the same
        // reason. The screen frame also reserves room for the row (see
        // `snesLandscapeBottomReserve`), so this places it in a gap that exists.
        //
        // Centred rather than stuck under the picture with a fixed gap: on this console the row
        // is the ONLY thing in that strip, so a fixed gap left it high with an empty band under
        // it. Every mark in the row centres on its own hitbox (the printed SELECT/START block
        // included — see `DressKind.pillCenterY`), so centring the hitboxes centres what is seen.
        if isLandscape {
            let screen = EmulatorLayoutGeometry.screenFrame(
                deviceSize: containerSize, safeInsets: .zero, hasTouchScreen: false,
                isLandscape: true, gameAspect: PresetLayoutResolver.displayAspect(.nes),
                system: .nes, controllerConnected: false, deviceScale: k)
            // Centred between the picture's bottom edge and the top of the home indicator, not
            // the bottom of the glass: the indicator owns that strip and takes the swipe that
            // starts in it. The reserve is the same flat 21 the screen frame counts (see
            // `snesLandscapeIndicatorReserve`), for the same reason — the layout cannot read the
            // device's insets here, and the two have to agree about where the page ends.
            let rowY = (screen.maxY + h - EmulatorLayoutGeometry.snesLandscapeIndicatorReserve)
                / 2 / h
            for element in [ControlElement.btnSelect, .btnMenu, .btnStart] {
                guard let b = layout.buttons[element.rawValue] else { continue }
                layout.buttons[element.rawValue] =
                    ButtonLayout(centerX: b.centerX, centerY: rowY, isHidden: b.isHidden)
            }
            return layout
        }

        // PORTRAIT: MENU and CLIP take the band the dress leaves between the screen panel and the
        // A/B well, ON ONE LINE. Only their vertical position changes; each keeps the column the
        // Game Boy layout gave it (MENU centred, CLIP top-right).
        //
        // The band is bounded by two things the DRESS draws, which is why both bounds come from
        // `DressKind` rather than from a number chosen here:
        //  - its top is the lower edge of the screen panel. In portrait the controls container
        //    starts exactly at the picture's bottom edge (see `EmulatorLayoutGeometry`.
        //    `controlsFrame`), and the panel keeps a symmetric skirt of body below the picture, so
        //    container-relative that edge is simply the skirt. No safe-area inset enters here,
        //    which matters because this function cannot read one.
        //  - its bottom is the top of the sunken well around A and B. The well, not the buttons:
        //    it is the well's rim the eye measures against, and it stands `nesWellPad` proud of
        //    the larger button on every side.
        //
        // This REPLACES two clamps that only pushed each button up far enough not to collide
        // (CLIP off A, MENU off the pad). They kept the page legal on a short device and left it
        // unbalanced everywhere: a control hard against the thing below it, with the band's whole
        // height empty above.
        let w = containerSize.width
        guard w > 0 else { return layout }
        func rect(_ e: ControlElement, _ b: ButtonLayout) -> CGRect {
            let s = EmulatorLayoutGeometry.buttonSize(e, system: .nes, isLandscape: false,
                                                      deviceScale: k)
            return CGRect(x: b.centerX * w - s.width / 2, y: b.centerY * h - s.height / 2,
                          width: s.width, height: s.height)
        }
        if let a = layout.buttons[ControlElement.btnA.rawValue],
           let b = layout.buttons[ControlElement.btnB.rawValue] {
            let wellTop = DressKind.nesFaceWellTop(a: rect(.btnA, a), b: rect(.btnB, b), scale: k)
            let panelBottom = DressKind.nesPanelSkirt * k
            let y = (panelBottom + wellTop) / 2 / h
            for e in [ControlElement.btnMenu, .btnClip] {
                guard let button = layout.buttons[e.rawValue] else { continue }
                layout.buttons[e.rawValue] =
                    ButtonLayout(centerX: button.centerX, centerY: y, isHidden: button.isHidden)
            }
        }
        return layout
    }
}
