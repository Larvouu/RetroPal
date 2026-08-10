//
//  SkinSheetMetrics.swift
//  EmulateurGBA
//
//  Shared geometry for the in-game Skin picker sheet, so the SwiftUI layout (SkinPickerView) and the
//  UIKit sheet detent (EmulatorViewController) agree without drifting. Portrait pins the OK / Create
//  / Import actions and scrolls the card grid above them (≤ 2 rows shown, the rest scrolls); the
//  detent is sized to fit two card rows + the actions, capped at 95% of the screen. Landscape shrinks
//  the cards (aspect kept) so two rows of three are visible at a glance before scrolling.
//

import CoreGraphics

enum SkinSheetMetrics {
    /// Card preview aspect (the reference iPhone 16 Pro Max portrait the cards render at).
    static let aspect: CGFloat = 956.0 / 440.0
    static let hPad: CGFloat = 16
    static let cardSpacing: CGFloat = 12
    static let columns = 3
    static let nameLabelH: CGFloat = 20          // the skin-name label under each card
    static let cardLabelGap: CGFloat = 8         // VStack(spacing:) inside a card
    static let rowGap: CGFloat = 16              // spacing between grid rows
    static let buttonH: CGFloat = 50             // one action-button row
    static let buttonGap: CGFloat = 12           // spacing between stacked action rows
    static let topPad: CGFloat = 16
    static let bottomPad: CGFloat = 16
    static let sectionGap: CGFloat = 16          // grid ↔ actions (and ↔ caption)
    static let captionH: CGFloat = 44            // the preset-lock caption, when shown

    static func cardWidth(containerWidth: CGFloat) -> CGFloat {
        max(1, (containerWidth - hPad * 2 - cardSpacing * CGFloat(columns - 1)) / CGFloat(columns))
    }
    static func cellHeight(containerWidth: CGFloat) -> CGFloat {
        cardWidth(containerWidth: containerWidth) * aspect + cardLabelGap + nameLabelH
    }
    /// Rows drawn for N items; rows shown before scrolling is capped at 2.
    static func rowCount(itemCount: Int) -> Int { (itemCount + columns - 1) / columns }
    static func visibleRows(itemCount: Int) -> Int { min(rowCount(itemCount: itemCount), 2) }

    /// Action area height: OK alone, or OK + the Create/Import row when custom skins are supported.
    static func actionHeight(supportsCustom: Bool) -> CGFloat {
        supportsCustom ? buttonH * 2 + buttonGap : buttonH
    }

    /// The portrait sheet (detent) height: two card rows + the pinned actions, capped at 95% screen.
    static func portraitSheetHeight(containerWidth: CGFloat, screenHeight: CGFloat,
                                    itemCount: Int, supportsCustom: Bool, locked: Bool) -> CGFloat {
        let rows = CGFloat(visibleRows(itemCount: itemCount))
        let gridH = cellHeight(containerWidth: containerWidth) * rows + rowGap * (rows - 1)
        var h = topPad + gridH + sectionGap + actionHeight(supportsCustom: supportsCustom) + bottomPad
        if locked { h += captionH + sectionGap }
        return min(h, screenHeight * 0.95)
    }

    // MARK: - Appearance sheet (tabbed: Console / Screen)

    /// The segmented tab bar row (control + its vertical padding), added on top
    /// of the per-tab content height when the sheet shows tabs (GB/GBC).
    static let tabBarH: CGFloat = 52
    /// Palette preview aspect: the GB screen (160×144), height/width.
    static let paletteAspect: CGFloat = 144.0 / 160.0
    static let paletteGroupHeaderH: CGFloat = 28

    static func paletteCellHeight(containerWidth: CGFloat) -> CGFloat {
        cardWidth(containerWidth: containerWidth) * paletteAspect + cardLabelGap + nameLabelH
    }

    /// Estimated Screen-tab portrait content height: section header + the big
    /// filter showcase (GB aspect at full width, capped like the view caps it)
    /// + two chip rows + the (worst-case, non-Pro) Apply invitation + OK.
    /// The scroll absorbs any estimate error; palettes below simply scroll.
    private static func screenTabContentEstimate(containerWidth: CGFloat,
                                                 screenHeight: CGFloat) -> CGFloat {
        let showcaseH = min((containerWidth - hPad * 2) * (144.0 / 160.0), 320)
        let chipRowsH: CGFloat = 3 * 38 + 16     // 7 chips, ~3 rows at the wider minimum
        return topPad + paletteGroupHeaderH + showcaseH + 12 + chipRowsH
            + sectionGap + buttonH + bottomPad   // one pinned row (OK, or OK + Apply beside it)
    }

    /// The Appearance sheet's SINGLE portrait detent: the taller of the two
    /// tabs' content heights (the height never changes on a tab switch —
    /// settled UX, 2026-07-24), plus the tab bar, capped at 95% screen.
    static func appearancePortraitHeight(containerWidth: CGFloat, screenHeight: CGFloat,
                                         itemCount: Int, supportsCustom: Bool,
                                         locked: Bool, showTabs: Bool) -> CGFloat {
        var h = portraitSheetHeight(containerWidth: containerWidth, screenHeight: screenHeight,
                                    itemCount: itemCount, supportsCustom: supportsCustom,
                                    locked: locked)
        if showTabs {
            h = max(h, screenTabContentEstimate(containerWidth: containerWidth,
                                                screenHeight: screenHeight))
            h += tabBarH
        }
        return min(h, screenHeight * 0.95)
    }

    /// The scrollable grid's max height inside the sheet of `sheetHeight`: whatever remains after the
    /// pinned actions (so the grid scrolls if the sheet was capped, while the actions stay visible).
    static func portraitGridBound(sheetHeight: CGFloat, supportsCustom: Bool, locked: Bool) -> CGFloat {
        var chrome = topPad + bottomPad + actionHeight(supportsCustom: supportsCustom) + sectionGap
        if locked { chrome += captionH + sectionGap }
        return max(0, sheetHeight - chrome)
    }

    /// Landscape card width sized so `rows` rows fit the left column's height (aspect kept), clamped
    /// to the three-per-row width.
    static func landscapeCardWidth(leftWidth: CGFloat, columnHeight: CGFloat,
                                   rows: Int, locked: Bool) -> CGFloat {
        let byWidth = cardWidth(containerWidth: leftWidth)
        let r = CGFloat(max(1, rows))
        let cellExtra = cardLabelGap + nameLabelH
        var chrome: CGFloat = 16
        if locked { chrome += captionH }
        let avail = columnHeight - chrome - rowGap * (r - 1)
        let byHeight = (avail - cellExtra * r) / (aspect * r)
        return max(1, min(byWidth, byHeight))
    }
}
