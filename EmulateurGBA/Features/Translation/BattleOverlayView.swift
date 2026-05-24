//
//  BattleOverlayView.swift
//  EmulateurGBA
//
//  Transparent, non-interactive overlay drawn above the emulator's Metal view.
//  Draws translated species names at battle-UI positions, mapping game pixels
//  (the 240x160 GBA space) to screen points via the current game display rect.
//
//  Phase 1 of the in-game translation feature. The whole feature is `#if DEBUG`
//  — it ships dormant in release builds.
//

import UIKit

#if DEBUG

/// A positioned datum for the battle overlay: a string and where it belongs,
/// expressed in game-pixel coordinates (the 240x160 GBA space).
struct BattleOverlayItem {
    let text: String
    let gameAnchor: CGPoint
}

final class BattleOverlayView: UIView {

    /// GBA display width. The translation feature only runs for Gen 3 GBA
    /// games, so the game space is always 240x160.
    private static let gameWidth: CGFloat = 240

    private var labels: [UILabel] = []
    private var items: [BattleOverlayItem] = []
    private var gameRect: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false   // never steals touches from controls
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Update the overlay with new items and the current game display rect
    /// (the `EmulatorMetalView` frame, in this view's coordinate space).
    /// Called ~2x/second by the translation probe; an empty `items` clears it.
    func update(items: [BattleOverlayItem], gameRect: CGRect) {
        self.items = items
        self.gameRect = gameRect
        layoutItems()
    }

    private func layoutItems() {
        while labels.count < items.count {
            labels.append(makeLabel())
        }
        // A zero-width game rect means the metal view is not laid out yet.
        guard gameRect.width > 0 else {
            labels.forEach { $0.isHidden = true }
            return
        }
        let scale = gameRect.width / Self.gameWidth

        for (index, label) in labels.enumerated() {
            guard index < items.count else {
                label.isHidden = true
                continue
            }
            let item = items[index]
            label.text = item.text
            label.sizeToFit()
            label.frame.origin = CGPoint(
                x: gameRect.minX + item.gameAnchor.x * scale,
                y: gameRect.minY + item.gameAnchor.y * scale
            )
            label.isHidden = false
        }
    }

    private func makeLabel() -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .systemYellow
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.textAlignment = .center
        addSubview(label)
        return label
    }
}

#endif
