//
//  ControlLayoutDefaults.swift
//  EmulateurGBA
//
//  Generates default OrientationLayouts from the current hardcoded button positions.
//  Used to seed new presets and fill in missing buttons when loading cross-system presets.
//

import CoreGraphics

enum ControlLayoutDefaults {

    // MARK: - GBA Portrait

    /// Default GBA portrait layout, normalized to the given container size.
    /// Matches the constants in TouchControlsView.applyPortraitLayout().
    static func gbaPortrait(containerSize: CGSize) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        // Centers use the same edge anchors as TouchControlsView.applyPortraitLayout().
        // dpad/A/B half-sizes are derived from ControlElement defaults so a seeded
        // preset matches the in-game default at any size.
        let dpadH = ControlElement.dpad.defaultSize.width / 2
        let aH = ControlElement.btnA.defaultSize.width / 2
        let bH = ControlElement.btnB.defaultSize.width / 2
        // btnL: leading +16, top +36, 90x44 → center at (16 + 45, 36 + 22)
        // btnR: trailing -16, top +36, 90x44 → center at (w - 16 - 45, 36 + 22)
        // btnStart: centerX +35, bottom -39, 64x44 → center at (w/2 + 35, h - 39 - 22)
        // btnSelect: centerX -35, bottom -39, 64x44 → center at (w/2 - 35, h - 39 - 22)
        // btnMenu: centerX, top +40, 44x44 → center at (w/2, 40 + 22)

        var buttons: [String: ButtonLayout] = [:]
        // dpad: leading +20, bottom -140
        buttons[ControlElement.dpad.rawValue] = ButtonLayout(
            centerX: (20 + dpadH) / w, centerY: (h - 140 - dpadH) / h)
        // btnA: trailing -30, bottom -170
        buttons[ControlElement.btnA.rawValue] = ButtonLayout(
            centerX: (w - 30 - aH) / w, centerY: (h - 170 - aH) / h)
        // btnB: trailing -100, bottom -120
        buttons[ControlElement.btnB.rawValue] = ButtonLayout(
            centerX: (w - 100 - bH) / w, centerY: (h - 120 - bH) / h)
        buttons[ControlElement.btnL.rawValue] = ButtonLayout(
            centerX: (16 + 45) / w, centerY: (36 + 22) / h)
        buttons[ControlElement.btnR.rawValue] = ButtonLayout(
            centerX: (w - 16 - 45) / w, centerY: (36 + 22) / h)
        buttons[ControlElement.btnStart.rawValue] = ButtonLayout(
            centerX: (w / 2 + 35) / w, centerY: (h - 39 - 22) / h)
        buttons[ControlElement.btnSelect.rawValue] = ButtonLayout(
            centerX: (w / 2 - 35) / w, centerY: (h - 39 - 22) / h)
        buttons[ControlElement.btnMenu.rawValue] = ButtonLayout(
            centerX: 0.5, centerY: (40 + 22) / h)

        return OrientationLayout(buttons: buttons)
    }

    // MARK: - GBA Landscape

    /// Default GBA landscape layout, normalized to the given container size.
    /// Matches the constants in TouchControlsView.applyLandscapeLayout().
    static func gbaLandscape(containerSize: CGSize) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        // Centers use the same edge anchors as TouchControlsView.applyLandscapeLayout().
        // dpad/A/B half-sizes are derived from ControlElement defaults so a seeded
        // preset matches the in-game default at any size.
        let dpadH = ControlElement.dpad.defaultLandscapeSize.width / 2
        let aH = ControlElement.btnA.defaultLandscapeSize.width / 2
        let bH = ControlElement.btnB.defaultLandscapeSize.width / 2
        // btnL: leading +25, top +20, 110x38 → center at (25 + 55, 20 + 19)
        // btnR: trailing -25, top +20, 110x38 → center at (w - 25 - 55, 20 + 19)
        // btnStart: centerX +70, bottom -7, 56x44 → center at (w/2 + 70, h - 7 - 22)
        // btnSelect: centerX -70, bottom -7, 56x44 → center at (w/2 - 70, h - 7 - 22)
        // btnMenu: centerX, top +10, 44x44 → center at (w/2, 10 + 22)

        var buttons: [String: ButtonLayout] = [:]
        // dpad: leading +95, centerY +39
        buttons[ControlElement.dpad.rawValue] = ButtonLayout(
            centerX: (95 + dpadH) / w, centerY: (h / 2 + 39) / h)
        // btnA: trailing -95, centerY +9
        buttons[ControlElement.btnA.rawValue] = ButtonLayout(
            centerX: (w - 95 - aH) / w, centerY: (h / 2 + 9) / h)
        // btnB: trailing -163, centerY +49
        buttons[ControlElement.btnB.rawValue] = ButtonLayout(
            centerX: (w - 163 - bH) / w, centerY: (h / 2 + 49) / h)
        buttons[ControlElement.btnL.rawValue] = ButtonLayout(
            centerX: (25 + 55) / w, centerY: (20 + 19) / h)
        buttons[ControlElement.btnR.rawValue] = ButtonLayout(
            centerX: (w - 25 - 55) / w, centerY: (20 + 19) / h)
        buttons[ControlElement.btnStart.rawValue] = ButtonLayout(
            centerX: (w / 2 + 70) / w, centerY: (h - 7 - 22) / h)
        buttons[ControlElement.btnSelect.rawValue] = ButtonLayout(
            centerX: (w / 2 - 70) / w, centerY: (h - 7 - 22) / h)
        buttons[ControlElement.btnMenu.rawValue] = ButtonLayout(
            centerX: 0.5, centerY: (10 + 22) / h)

        return OrientationLayout(buttons: buttons)
    }

    // MARK: - NDS Portrait

    /// Default NDS portrait layout, normalized to the given container size.
    /// Matches the constants in NDSTouchControlsView.applyPortraitLayout().
    static func ndsPortrait(containerSize: CGSize) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        let diamondR: CGFloat = 50

        // dpad/face half-sizes from ControlElement defaults so a seeded preset
        // matches NDSTouchControlsView.applyPortraitLayout() at any size.
        let dpadH = ControlElement.dpad.defaultNDSPortraitSize.width / 2
        let aH = ControlElement.btnA.defaultNDSPortraitSize.width / 2

        // btnA: trailing -24, centerY -6. X/Y/B sit on the diamond around A.
        let aCenterX = w - 24 - aH
        let aCenterY = h / 2 - 6
        // btnX: center (aCenterX - diamondR, aCenterY - diamondR)
        // btnY: center (aCenterX - diamondR*2, aCenterY)
        // btnB: center (aCenterX - diamondR, aCenterY + diamondR)
        // btnL: leading +16, top +8, 70x36 → center at (16 + 35, 8 + 18)
        // btnR: trailing -16, top +8, 70x36 → center at (w - 16 - 35, 8 + 18)
        // btnSelect: centerX -32, bottom -20, 52x36 → center at (w/2 - 32, h - 20 - 18)
        // btnStart: centerX +32, bottom -20, 52x36 → center at (w/2 + 32, h - 20 - 18)
        // btnMenu: centerX, top +8, 36x36 → center at (w/2, 8 + 18)
        // btnMic: right of Start → center at (w/2 + 32 + 26 + 12 + 26, h - 20 - 18)
        let startCenterX = w / 2 + 32
        let micCenterX = startCenterX + 26 + 12 + 26

        var buttons: [String: ButtonLayout] = [:]
        buttons[ControlElement.dpad.rawValue] = ButtonLayout(
            centerX: (12 + dpadH) / w, centerY: (h / 2 - 6) / h)
        buttons[ControlElement.btnA.rawValue] = ButtonLayout(
            centerX: aCenterX / w, centerY: aCenterY / h)
        buttons[ControlElement.btnX.rawValue] = ButtonLayout(
            centerX: (aCenterX - diamondR) / w, centerY: (aCenterY - diamondR) / h)
        buttons[ControlElement.btnY.rawValue] = ButtonLayout(
            centerX: (aCenterX - diamondR * 2) / w, centerY: aCenterY / h)
        buttons[ControlElement.btnB.rawValue] = ButtonLayout(
            centerX: (aCenterX - diamondR) / w, centerY: (aCenterY + diamondR) / h)
        buttons[ControlElement.btnL.rawValue] = ButtonLayout(
            centerX: (16 + 35) / w, centerY: (8 + 18) / h)
        buttons[ControlElement.btnR.rawValue] = ButtonLayout(
            centerX: (w - 16 - 35) / w, centerY: (8 + 18) / h)
        buttons[ControlElement.btnSelect.rawValue] = ButtonLayout(
            centerX: (w / 2 - 32) / w, centerY: (h - 20 - 18) / h)
        buttons[ControlElement.btnStart.rawValue] = ButtonLayout(
            centerX: (w / 2 + 32) / w, centerY: (h - 20 - 18) / h)
        buttons[ControlElement.btnMenu.rawValue] = ButtonLayout(
            centerX: 0.5, centerY: (8 + 18) / h)
        buttons[ControlElement.btnMic.rawValue] = ButtonLayout(
            centerX: micCenterX / w, centerY: (h - 20 - 18) / h)

        return OrientationLayout(buttons: buttons)
    }

    // MARK: - NDS Landscape

    /// Default NDS landscape layout, normalized to the given container size.
    /// Matches the constants in NDSTouchControlsView.applyLandscapeLayout().
    static func ndsLandscape(containerSize: CGSize) -> OrientationLayout {
        let w = containerSize.width
        let h = containerSize.height
        guard w > 0 && h > 0 else { return OrientationLayout() }

        let vGap: CGFloat = 4
        let rowOffset: CGFloat = 26

        // dpad/face half-sizes from ControlElement defaults so a seeded preset
        // matches NDSTouchControlsView.applyLandscapeLayout() at any size.
        let dpadH = ControlElement.dpad.defaultNDSLandscapeSize.width / 2
        let faceH = ControlElement.btnA.defaultNDSLandscapeSize.width / 2

        // btnA: trailing -140, centerY -(vGap/2)
        let aCenterX = w - 140 - faceH
        let aCenterY = h / 2 - vGap / 2 - faceH
        // btnX: btnX.trailing = btnA.leading - (hGap + 24); X center = aCenterX - faceH - (4+24) - faceH
        let xCenterX = aCenterX - faceH - (4 + 24) - faceH
        // btnB: aCenterX - rowOffset, lower row
        let bCenterX = aCenterX - rowOffset
        let bCenterY = h / 2 + vGap / 2 + faceH
        // btnY: left of B, same pattern as X
        let yCenterX = bCenterX - faceH - (4 + 24) - faceH
        // btnL: leading +65, centerY = topAnchor -50 → center at (65 + 20, -50)
        // L/R extend above the controls area. Negative normalized Y is valid.
        // btnR: trailing -65, centerY = topAnchor -50 → center at (w - 65 - 20, -50)
        // btnSelect: centerX -55, bottom -24, 52x36 → center at (w/2 - 55, h - 24 - 18)
        // btnStart: centerX +55, bottom -24, 52x36 → center at (w/2 + 55, h - 24 - 18)
        // btnMenu: centerX, same Y as Select → center at (w/2, h - 24 - 18)
        // btnMic: centerX, bottom = menu.top - 8 → center at (w/2, menu.centerY - menuH/2 - 8 - micH/2)
        let menuCenterY = h - 24 - 18
        let micCenterY = menuCenterY - 18 - 8 - 18  // menu half-height - gap - mic half-height

        var buttons: [String: ButtonLayout] = [:]
        buttons[ControlElement.dpad.rawValue] = ButtonLayout(
            centerX: (110 + dpadH) / w, centerY: (h / 2 - 4) / h)
        buttons[ControlElement.btnA.rawValue] = ButtonLayout(
            centerX: aCenterX / w, centerY: aCenterY / h)
        buttons[ControlElement.btnX.rawValue] = ButtonLayout(
            centerX: xCenterX / w, centerY: aCenterY / h)
        buttons[ControlElement.btnB.rawValue] = ButtonLayout(
            centerX: bCenterX / w, centerY: bCenterY / h)
        buttons[ControlElement.btnY.rawValue] = ButtonLayout(
            centerX: yCenterX / w, centerY: bCenterY / h)
        buttons[ControlElement.btnL.rawValue] = ButtonLayout(
            centerX: (65 + 20) / w, centerY: -50 / h)
        buttons[ControlElement.btnR.rawValue] = ButtonLayout(
            centerX: (w - 65 - 20) / w, centerY: -50 / h)
        buttons[ControlElement.btnSelect.rawValue] = ButtonLayout(
            centerX: (w / 2 - 55) / w, centerY: (h - 24 - 18) / h)
        buttons[ControlElement.btnStart.rawValue] = ButtonLayout(
            centerX: (w / 2 + 55) / w, centerY: (h - 24 - 18) / h)
        buttons[ControlElement.btnMenu.rawValue] = ButtonLayout(
            centerX: 0.5, centerY: menuCenterY / h)
        buttons[ControlElement.btnMic.rawValue] = ButtonLayout(
            centerX: 0.5, centerY: micCenterY / h)

        return OrientationLayout(buttons: buttons)
    }

    // MARK: - Helpers

    /// Returns the appropriate default layout for the given parameters.
    static func defaultLayout(forNDS: Bool, isLandscape: Bool, containerSize: CGSize) -> OrientationLayout {
        if forNDS {
            return isLandscape ? ndsLandscape(containerSize: containerSize) : ndsPortrait(containerSize: containerSize)
        } else {
            return isLandscape ? gbaLandscape(containerSize: containerSize) : gbaPortrait(containerSize: containerSize)
        }
    }
}
