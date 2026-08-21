//
//  SkinPreviewView.swift
//  EmulateurGBA
//
//  Production preview of one console's in-game layout under a given skin — used by the in-game
//  Skin picker (portrait) and the debug Skin gallery (both orientations). It drives the REAL
//  ConsoleSkinView + TouchControlsView through the same EmulatorLayoutGeometry the game uses, so
//  each skin renders exactly as it will in play. (The DEBUG-only InGameLayoutPreview does the
//  same for the layout gallery, but it is `#if DEBUG`, carries magenta/hitbox debug chrome, and
//  depends on a DEBUG-only enum, so it can't be reused here.)
//
//  The "screen" shows the current game frame when provided (like the screenshot card), else a
//  dark LCD-off placeholder. Emulation never runs here.
//

import UIKit
import SwiftUI

final class SkinPreviewView: UIView {
    private let system: PresetSystem
    private let skin: GameSkin
    private let isNDS: Bool
    private let isLandscape: Bool
    private let insets: UIEdgeInsets
    private let gameImage: UIImage?

    private let consoleSkin = ConsoleSkinView()
    private let screen = UIImageView()
    private let screen2 = UIImageView()            // NDS second screen
    private let controls: TouchControlsView

    /// When set, the preview renders this user custom palette live (overrides `skin`). Used by the
    /// skin editor's full-screen preview and the picker's custom cards; changing it redraws.
    var paletteOverride: SkinPalette? { didSet { if paletteOverride != oldValue { setNeedsLayout() } } }

    /// Retro Pal recolour, a live custom palette, or the original Nostalgia look.
    private var variant: DressVariant {
        if let p = paletteOverride { return .custom(p) }
        return skin == .retroPal ? .retroPal : .nostalgia
    }

    init(system: PresetSystem, skin: GameSkin, isLandscape: Bool,
         safeInsets: UIEdgeInsets, gameImage: UIImage?) {
        self.system = system
        self.skin = skin
        self.isNDS = (system == .nds)
        self.isLandscape = isLandscape
        self.insets = safeInsets
        self.gameImage = gameImage
        self.controls = TouchControlsView.make(for: system)
        super.init(frame: .zero)

        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false           // the SwiftUI card handles the tap

        addSubview(consoleSkin)
        for s in [screen, screen2] {
            s.backgroundColor = UIColor(white: 0.04, alpha: 1)   // LCD-off look if no frame yet
            s.contentMode = .scaleAspectFill
            s.clipsToBounds = true
            s.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
            s.layer.borderWidth = 1
            addSubview(s)
        }
        screen2.isHidden = true

        controls.translatesAutoresizingMaskIntoConstraints = true
        addSubview(controls)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// One half of the NDS combined frame (top = top screen). The buffer stacks the two
    /// screens vertically, so a 50/50 crop maps each to its preview rect.
    private func ndsHalf(top: Bool) -> UIImage? {
        guard let cg = gameImage?.cgImage else { return nil }
        let h = cg.height / 2
        let rect = CGRect(x: 0, y: top ? 0 : h, width: cg.width, height: h)
        return cg.cropping(to: rect).map { UIImage(cgImage: $0) }
    }

    /// Rendered game aspect (width / height), matching EmulatorSession / the layout engine.
    /// The one table lives in `PresetLayoutResolver`, because a preview drawing a different
    /// shape from the game is a preview that lies.
    private var gameAspect: CGFloat { PresetLayoutResolver.displayAspect(system) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let k = EmulatorLayoutGeometry.deviceScale(for: size)
        let metalFrame = EmulatorLayoutGeometry.screenFrame(
            deviceSize: size, safeInsets: insets,
            hasTouchScreen: isNDS, isLandscape: isLandscape,
            gameAspect: gameAspect, system: system,
            controllerConnected: false, deviceScale: k)
        let containerFrame = EmulatorLayoutGeometry.controlsFrame(
            deviceSize: size, screenFrame: metalFrame,
            hasTouchScreen: isNDS, isLandscape: isLandscape)

        // A custom palette always dresses the console (it IS a dressed skin); otherwise track the skin.
        let dressed = (paletteOverride != nil || skin.isDressed)
            && ConsoleSkinView.hasDressedControls(for: system)

        consoleSkin.frame = bounds
        consoleSkin.system = system
        consoleSkin.screenFrame = metalFrame
        consoleSkin.deviceScale = k
        consoleSkin.usesJoystick = UserDefaults.standard.bool(forKey: "useJoystick")
        consoleSkin.variant = variant
        consoleSkin.isHidden = !dressed || !ConsoleSkinView.hasSkin(for: system)

        if isNDS && isLandscape {
            // Two screens side by side; the gutters around the pair stay black.
            let s = EmulatorLayoutGeometry.ndsLandscapeScreenRects(controlsContainer: containerFrame.size)
            screen.frame = CGRect(x: s.left.minX, y: metalFrame.minY,
                                  width: s.left.width, height: metalFrame.height)
            screen2.frame = CGRect(x: s.touch.minX, y: metalFrame.minY,
                                   width: s.touch.width, height: metalFrame.height)
            screen2.isHidden = false
            consoleSkin.ndsScreens = [screen.frame, screen2.frame]
            for v in [screen, screen2] { v.layer.cornerRadius = 2 * k; v.layer.masksToBounds = true }
            screen.image = ndsHalf(top: true)
            screen2.image = ndsHalf(top: false)
        } else if isNDS {
            // Portrait: split the combined band into the two stacked screens.
            let topRatio: CGFloat = 0.495, gapRatio: CGFloat = 0.01
            let topH = metalFrame.height * topRatio
            let gapH = metalFrame.height * gapRatio
            screen.frame = CGRect(x: metalFrame.minX, y: metalFrame.minY,
                                  width: metalFrame.width, height: topH)
            screen2.frame = CGRect(x: metalFrame.minX, y: metalFrame.minY + topH + gapH,
                                   width: metalFrame.width,
                                   height: metalFrame.height * (1 - topRatio - gapRatio))
            screen2.isHidden = false
            consoleSkin.ndsScreens = [screen.frame, screen2.frame]
            for v in [screen, screen2] { v.layer.cornerRadius = 2 * k; v.layer.masksToBounds = true }
            screen.image = ndsHalf(top: true)
            screen2.image = ndsHalf(top: false)
        } else {
            screen.frame = metalFrame
            screen2.isHidden = true
            consoleSkin.ndsScreens = []
            screen.layer.cornerRadius = 0
            screen.image = gameImage
        }

        controls.frame = containerFrame
        controls.layoutIfNeeded()
        controls.applyDefaultLayout(isLandscape: isLandscape, system: system,
                                    deviceScale: k, safeLeftInset: insets.left,
                                    safeRightInset: insets.right)
        controls.setDressed(dressed, isLandscape: isLandscape, system: system, variant: variant)
        controls.layoutIfNeeded()
        consoleSkin.buttonFrames = controls.visibleButtonFrames(in: consoleSkin)
    }
}

/// SwiftUI bridge for `SkinPreviewView`. Built-in cards hold a FIXED skin/orientation. When a
/// `customPalette` is supplied (custom cards + the editor's live preview) it is pushed on every
/// update so the console recolours instantly as the user edits.
struct SkinPreviewRepresentable: UIViewRepresentable {
    let system: PresetSystem
    var skin: GameSkin = .nostalgia
    var isLandscape: Bool = false
    let safeInsets: UIEdgeInsets
    let gameImage: UIImage?
    var customPalette: SkinPalette? = nil

    func makeUIView(context: Context) -> SkinPreviewView {
        let v = SkinPreviewView(system: system, skin: skin, isLandscape: isLandscape,
                                safeInsets: safeInsets, gameImage: gameImage)
        v.paletteOverride = customPalette
        return v
    }
    func updateUIView(_ uiView: SkinPreviewView, context: Context) {
        uiView.paletteOverride = customPalette
    }
}
