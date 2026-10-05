//
//  NDSLidMessageView.swift
//  EmulateurGBA
//
//  What the DS's top screen shows while its lid is closed from the pause menu
//  (asked 2026-09-28): the screen dimmed, and one sentence saying the console
//  is closed and how to open it. Laid over the screen that shows the DS's TOP
//  picture, by the game screen and by the Debug gallery alike, so the gallery
//  reviews exactly what plays.
//
//  THE TEXT ALWAYS FITS THE SCREEN, whatever its size (an SE upright, a
//  13-inch iPad on its side, a preset that shrank the screens): each layout
//  picks the largest font, up to a cap, whose wrapped text fits inside the
//  screen with a margin. Nothing is cut and nothing spills out.
//

import UIKit

final class NDSLidMessageView: UIView {
    private let label = UILabel()

    /// Largest and smallest type, in points. The largest keeps a 13-inch iPad
    /// from shouting; the smallest is a floor that a DS screen on any
    /// supported device clears easily (an SE's top screen is ~190 points tall).
    private static let maxFontSize: CGFloat = 22
    private static let minFontSize: CGFloat = 9

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.62)
        label.text = NSLocalizedString("nds.lid.closedMessage", comment: "")
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = label.text
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        // A margin proportional to the screen, so a small screen keeps room
        // for its words and a large one does not look crowded.
        let margin = max(8, min(bounds.width, bounds.height) * 0.08)
        let box = bounds.insetBy(dx: margin, dy: margin)
        let size = Self.fittingFontSize(for: label.text ?? "", in: box.size)
        label.font = .systemFont(ofSize: size, weight: .semibold)
        let needed = Self.textSize(label.text ?? "", fontSize: size, width: box.width)
        label.frame = CGRect(x: box.minX, y: box.midY - needed.height / 2,
                             width: box.width, height: needed.height)
    }

    /// The largest size between the floor and the cap whose wrapped text fits
    /// `box`, by halving the interval (a dozen measurements at most).
    static func fittingFontSize(for text: String, in box: CGSize) -> CGFloat {
        var low = minFontSize, high = maxFontSize
        if fits(text, fontSize: high, in: box) { return high }
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if fits(text, fontSize: mid, in: box) { low = mid } else { high = mid }
        }
        return low
    }

    private static func fits(_ text: String, fontSize: CGFloat, in box: CGSize) -> Bool {
        let size = textSize(text, fontSize: fontSize, width: box.width)
        return size.height <= box.height && size.width <= box.width + 0.5
    }

    private static func textSize(_ text: String, fontSize: CGFloat, width: CGFloat) -> CGSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .center
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                         .paragraphStyle: paragraph],
            context: nil)
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// The screen that shows the DS's TOP picture, among the two the game
    /// draws: the first in physical order (above upright, left on its side),
    /// or the other one when the player swapped the screens.
    static func topPictureRect(primary: CGRect, secondary: CGRect, swapped: Bool) -> CGRect {
        swapped ? secondary : primary
    }
}
