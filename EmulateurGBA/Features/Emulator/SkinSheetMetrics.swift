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
