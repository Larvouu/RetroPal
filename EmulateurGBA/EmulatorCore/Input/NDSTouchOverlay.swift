//
//  NDSTouchOverlay.swift
//  EmulateurGBA
//
//  Transparent overlay placed over the rendered NDS bottom screen.
//  Converts touch coordinates to NDS space (0-255, 0-191)
//  and forwards to the emulator session.
//

import UIKit

protocol NDSTouchOverlayDelegate: AnyObject {
    func ndsTouchBegan(x: Int, y: Int)
    func ndsTouchMoved(x: Int, y: Int)
    func ndsTouchEnded()
}

final class NDSTouchOverlay: UIView {
    weak var delegate: NDSTouchOverlayDelegate?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func ndsCoordinate(for touch: UITouch) -> (x: Int, y: Int) {
        let location = touch.location(in: self)
        let x = Int((location.x / bounds.width) * 256)
        let y = Int((location.y / bounds.height) * 192)
        return (max(0, min(255, x)), max(0, min(191, y)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let coord = ndsCoordinate(for: touch)
        delegate?.ndsTouchBegan(x: coord.x, y: coord.y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let coord = ndsCoordinate(for: touch)
        delegate?.ndsTouchMoved(x: coord.x, y: coord.y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        delegate?.ndsTouchEnded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        delegate?.ndsTouchEnded()
    }
}
