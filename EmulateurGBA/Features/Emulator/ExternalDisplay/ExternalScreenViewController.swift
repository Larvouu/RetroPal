//
//  ExternalScreenViewController.swift
//  EmulateurGBA
//
//  Root of the TV window. Black, with either the running game or the wordmark
//  on it, so a connected television never looks broken or half-configured.
//

import UIKit
import MetalKit

final class ExternalScreenViewController: UIViewController {
    private var screenView: ExternalScreenView?
    private let idleImageView = UIImageView(image: UIImage(named: "RetroPalBrand"))
    /// Tells the viewer what to do next. A television showing only a logo is
    /// indistinguishable from a television showing a bug.
    private let idleLabel = UILabel()

    var sideBySide: Bool = true {
        didSet { screenView?.sideBySide = sideBySide }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        idleImageView.contentMode = .scaleAspectFit
        idleImageView.alpha = 0.85
        view.addSubview(idleImageView)

        idleLabel.text = NSLocalizedString("externalDisplay.idle.hint", comment: "")
        idleLabel.textAlignment = .center
        idleLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        idleLabel.numberOfLines = 2
        view.addSubview(idleLabel)
    }

    // MARK: - Attach / detach

    func attach(source: EmulatorMetalView) {
        if let screenView, screenView.source === source {
            screenView.sideBySide = sideBySide
            return
        }
        detach()
        let screen = ExternalScreenView(source: source)
        screen.sideBySide = sideBySide
        view.addSubview(screen)
        screenView = screen
        idleImageView.isHidden = true
        idleLabel.isHidden = true
        view.setNeedsLayout()
    }

    func detach() {
        // isPaused stops its display link before the view leaves the tree, so
        // no draw can fire against a torn-down source.
        screenView?.isPaused = true
        screenView?.removeFromSuperview()
        screenView = nil
        idleImageView.isHidden = false
        idleLabel.isHidden = false
        view.setNeedsLayout()
    }

    // MARK: - Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds

        // The wordmark sits at a modest size: it is a "nothing is playing"
        // marker, not a splash screen. Wordmark and hint are centred as ONE
        // block so the pair stays optically balanced on any screen shape.
        let markWidth = min(bounds.width * 0.28, 420)
        let markHeight = markWidth * aspectOfBrand()
        // Sized off the screen height, not the phone's type scale: this is read
        // from a sofa, not held in a hand.
        idleLabel.font = .systemFont(ofSize: min(bounds.height * 0.045, 34), weight: .medium)
        let labelWidth = bounds.width * 0.8
        let labelHeight = idleLabel.sizeThatFits(
            CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height
        let gap = markHeight * 0.4
        let blockTop = bounds.midY - (markHeight + gap + labelHeight) / 2

        idleImageView.frame = CGRect(x: bounds.midX - markWidth / 2, y: blockTop,
                                     width: markWidth, height: markHeight)
        idleLabel.frame = CGRect(x: bounds.midX - labelWidth / 2,
                                 y: blockTop + markHeight + gap,
                                 width: labelWidth, height: labelHeight)

        guard let screenView, let source = screenView.source else { return }
        if source.mirrorIsDualScreen {
            // Both DS screens are laid out inside the drawable by the vertex
            // buffer, so the view takes the whole television.
            screenView.frame = bounds
        } else {
            // Single-screen consoles letterbox by SIZING THE VIEW, exactly as
            // the phone does, so the fullscreen-quad shader stays untouched.
            screenView.frame = Self.aspectFitRect(content: source.mirrorGameSize ?? CGSize(width: 3, height: 2),
                                                  in: bounds)
        }
    }

    private func aspectOfBrand() -> CGFloat {
        guard let size = idleImageView.image?.size, size.width > 0 else { return 0.25 }
        return size.height / size.width
    }

    /// Largest rect of `content`'s aspect ratio that fits inside `bounds`, centred.
    static func aspectFitRect(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// Installed for the external-display scene role via Info.plist, so the app's
/// own SwiftUI scene is left entirely alone.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplayManager.shared.sceneDidConnect(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplayManager.shared.sceneDidDisconnect(windowScene)
    }
}
