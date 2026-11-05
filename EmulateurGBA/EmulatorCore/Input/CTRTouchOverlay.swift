//
//  CTRTouchOverlay.swift
//  EmulateurGBA
//
//  The 3DS's touch screen, phase 1: a transparent view over the bottom screen
//  inside the one composed picture (`CTRBottomScreenRect`, CTRBridge.h).
//
//  Why not the DS's overlay. NDSTouchOverlay maps its own bounds to 256x192
//  because the DS's touch screen is a picture of its own; the 3DS's bottom
//  screen is a rectangle inside a 400x480 picture, and CTRBridge takes a touch
//  in THAT picture's pixels (the core maps it back through its own layout). So
//  this view knows the picture it sits on, and reports positions in it.
//

import UIKit

final class CTRTouchOverlay: UIView {
    weak var delegate: NDSTouchOverlayDelegate?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// This view's frame for a picture drawn in `pictureFrame`: the bottom
    /// screen's rectangle, scaled from the picture's pixels to its points. The
    /// single-screen path draws the picture filling its frame, so the scale is
    /// the frame's size over the picture's.
    static func frame(inPicture pictureFrame: CGRect) -> CGRect {
        let sx = pictureFrame.width / CGFloat(CTRPictureWidth)
        let sy = pictureFrame.height / CGFloat(CTRPictureHeight)
        let r = CTRBottomScreenRect
        return CGRect(x: pictureFrame.minX + r.minX * sx, y: pictureFrame.minY + r.minY * sy,
                      width: r.width * sx, height: r.height * sy)
    }

    /// This view's frame when the screens are drawn side by side in
    /// `pictureFrame` (`EmulatorMetalView.ctrSideBySide`): the right quad. A
    /// touch still reports picture pixels (below), which the bottom screen's
    /// rectangle maps the same whatever the quad's place.
    static func frame(sideBySideIn pictureFrame: CGRect) -> CGRect {
        EmulatorMetalView.ctrSideBySideRects(in: pictureFrame.size).bottom
            .offsetBy(dx: pictureFrame.minX, dy: pictureFrame.minY)
    }

    /// A touch as a position in the PICTURE's pixels, clamped to the bottom
    /// screen: a finger sliding off its edge keeps pressing the edge, as on the
    /// DS, rather than letting go.
    private func pictureCoordinate(for touch: UITouch) -> (x: Int, y: Int) {
        let r = CTRBottomScreenRect
        let location = touch.location(in: self)
        let x = Int(r.minX + (location.x / max(bounds.width, 1)) * r.width)
        let y = Int(r.minY + (location.y / max(bounds.height, 1)) * r.height)
        return (max(Int(r.minX), min(Int(r.maxX) - 1, x)),
                max(Int(r.minY), min(Int(r.maxY) - 1, y)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let coord = pictureCoordinate(for: touch)
        delegate?.ndsTouchBegan(x: coord.x, y: coord.y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let coord = pictureCoordinate(for: touch)
        delegate?.ndsTouchMoved(x: coord.x, y: coord.y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        delegate?.ndsTouchEnded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        delegate?.ndsTouchEnded()
    }
}
