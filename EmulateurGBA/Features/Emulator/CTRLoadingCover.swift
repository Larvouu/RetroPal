//
//  CTRLoadingCover.swift
//  EmulateurGBA
//
//  The 3DS's two screens while its game boots (2026-10-20). The page around
//  them is already the game's own (shell, dress, controls), so only the
//  screens stand in: the top one shows the resumed state's screenshot under the
//  app's skeleton sweep (`UI/Skeleton.swift`), the bottom one is black with
//  "Loading the game…". Laid over the game's picture, in its coordinates;
//  `screens` are the two rects there (`ConsoleSkinView.ctrScreens`).
//

import UIKit

final class CTRLoadingCover: UIView {
    /// [top, bottom], in this view's coordinates.
    var screens: [CGRect] = [] { didSet { if screens != oldValue { setNeedsLayout() } } }

    private let top = UIImageView()
    private let bottom = UIView()
    private let label = UILabel()
    private let sweep = CAGradientLayer()

    init(screenshot: UIImage?) {
        super.init(frame: .zero)
        backgroundColor = .clear

        top.image = screenshot
        top.contentMode = .scaleToFill
        top.backgroundColor = .black
        top.clipsToBounds = true
        // Dimmed: a picture of where the game will be, not the game.
        top.alpha = screenshot == nil ? 1 : 0.55
        addSubview(top)

        bottom.backgroundColor = .black
        bottom.clipsToBounds = true
        addSubview(bottom)

        label.text = NSLocalizedString("emulator.loadingGame", comment: "")
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        bottom.addSubview(label)

        isAccessibilityElement = true
        accessibilityLabel = label.text
        accessibilityTraits = .updatesFrequently

        if !UIAccessibility.isReduceMotionEnabled {
            sweep.colors = [UIColor.clear.cgColor, UIColor.white.withAlphaComponent(0.28).cgColor,
                            UIColor.clear.cgColor]
            sweep.startPoint = CGPoint(x: 0, y: 0.5)
            sweep.endPoint = CGPoint(x: 1, y: 0.5)
            top.layer.addSublayer(sweep)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard screens.count == 2 else { return }
        top.frame = screens[0]
        bottom.frame = screens[1]
        let corner: CGFloat = 2
        top.layer.cornerRadius = corner
        bottom.layer.cornerRadius = corner
        label.frame = bottom.bounds.insetBy(dx: 12, dy: 8)

        // The sweep: a band 70 % of the screen's width crossing it every 1.25 s,
        // the skeleton's own pace (`ShimmerModifier`).
        guard sweep.superlayer != nil else { return }
        let w = top.bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.frame = CGRect(x: 0, y: 0, width: w * 0.7, height: top.bounds.height)
        CATransaction.commit()
        sweep.removeAnimation(forKey: "shimmer")
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -w * 0.35
        move.toValue = w * 1.35
        move.duration = 1.25
        move.repeatCount = .infinity
        sweep.add(move, forKey: "shimmer")
    }
}
