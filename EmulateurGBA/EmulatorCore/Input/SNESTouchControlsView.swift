//
//  SNESTouchControlsView.swift
//  EmulateurGBA
//
//  SNES-specific touch controls: adds the X/Y face buttons on top of the shared
//  TouchControlsView, exactly as NDSTouchControlsView does, and nothing else.
//
//  This file exists because the X and Y views lived ONLY in the DS subclass. The
//  SNES layout placed four face buttons from the start, but the base class has
//  only two views to place, so on device the diamond rendered as an A and a B
//  sitting where a diamond's right and bottom vertices are — closer together
//  than the GBA pair they replaced, which is exactly the collision reported on device.
//  The layout was right and the views were missing.
//
//  No microphone here: that is a DS cartridge feature, not a pad button.
//

import UIKit

final class SNESTouchControlsView: TouchControlsView {
    private let btnX = ActionButton(label: "X")
    private let btnY = ActionButton(label: "Y")

    /// The SNES widens the lockable set to its four face buttons, like the DS.
    override var lockableMask: UInt32 {
        GBAInput.a.rawValue | GBAInput.b.rawValue | GBAInput.x.rawValue | GBAInput.y.rawValue
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSNESButtons()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSNESButtons()
    }

    private func setupSNESButtons() {
        for v in [btnX, btnY] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            addSubview(v)
        }

        btnX.accessibilityLabel = "X button"
        btnY.accessibilityLabel = "Y button"

        // Round hit-tests for the diamond, so the four buttons do not steal each
        // other's corners. Same reason the DS does it.
        for b in [btnA, btnB, btnX, btnY] { b.roundHitbox = true }

        addNDSButtonMappings([
            (btnX, GBAInput.x.rawValue),
            (btnY, GBAInput.y.rawValue),
        ])
    }

    /// How far each letter is darkened from its own button's colour. The letter is the button's
    /// colour, taken down by half and engraved (`ActionButton.applyLabelStyle` gives it the light
    /// catch underneath), which is the treatment the GBA and DS letters already wear and what the
    /// real pad prints.
    ///
    /// Chosen over one flat colour for all four, tried first: no single colour works well here,
    /// because the faces span the luminance range with red and green in the MIDDLE of it, so a
    /// mid tone dies on those two and a light one dies on the yellow. Black was the best of them
    /// at a worst case of 2.24 (on X). Per-button ink measures 2.40 / 3.54 / 1.68 / 2.06 on
    /// A / B / X / Y, and the engraving's light edge does work no contrast ratio counts. **X is
    /// the weak one under every scheme tried, and lightening it is still the only thing that
    /// would buy real headroom.**
    private static let labelDarkening: CGFloat = 0.5

    /// X and Y wear the same face-button dress as A and B, and all four take their own colour.
    ///
    /// The SNES is the first console here whose faces are not one colour: A red, B yellow,
    /// X blue, Y green, per the spec. The colour therefore cannot live on the
    /// console's palette the way every previous one did, so each button carries its own.
    ///
    /// Retro Pal collapses those four into TWO, X/Y light and A/B deep, on a body and surround
    /// that are the GBA's own. It is read here rather than through `RetroPalPalette.buttonFill`
    /// because that answers per CONSOLE and this is the one dress that answers per button.
    override func setDressed(_ on: Bool, isLandscape: Bool, system: PresetSystem,
                             variant: DressVariant = .nostalgia) {
        super.setDressed(on, isLandscape: isLandscape, system: system, variant: variant)
        let kind = TouchControlsView.dressKind(for: system)
        btnX.dressVariant = variant; btnX.dressKind = kind; btnX.dressed = on
        btnY.dressVariant = variant; btnY.dressKind = kind; btnY.dressed = on
        let retroPal = variant == .retroPal
        let skin = variant.snesPalette
        let faces: [(ActionButton, UIColor)] = [
            (btnA, skin?.faceA ?? (retroPal ? RetroPalPalette.snesAB : DressKind.snesA)),
            (btnB, skin?.faceB ?? (retroPal ? RetroPalPalette.snesAB : DressKind.snesB)),
            (btnX, skin?.faceX ?? (retroPal ? RetroPalPalette.snesXY : DressKind.snesX)),
            (btnY, skin?.faceY ?? (retroPal ? RetroPalPalette.snesXY : DressKind.snesY)),
        ]
        for (button, colour) in faces {
            button.dressFace = on ? colour : nil
            button.dressFaceLabel = on ? colour.rpMixed(with: .black, Self.labelDarkening) : nil
        }
    }

    /// Extend the base set so the shared layout path positions and sizes them.
    override func allButtonViews() -> [(ControlElement, UIView)] {
        var views = super.allButtonViews()
        views.append(contentsOf: [(.btnX, btnX), (.btnY, btnY)])
        return views
    }
}
