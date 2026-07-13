//
//  NDSTouchControlsView.swift
//  EmulateurGBA
//
//  NDS-specific touch controls: adds the X/Y face buttons and a Mic/blow button
//  on top of the shared TouchControlsView. All positioning and sizing now flow
//  through the shared device-scaled layout path (TouchControlsView.applyLayout /
//  applyDefaultLayout + ControlLayoutDefaults); this subclass only contributes the
//  extra button views, their bitmask mappings, and the wider lockable set.
//
//  Reference: Manic EMU button layout (portrait1.jpg, landscape2.jpg).
//

import UIKit

final class NDSTouchControlsView: TouchControlsView {
    private let btnX = ActionButton(label: "X")
    private let btnY = ActionButton(label: "Y")
    private let btnMic = SmallButton(label: "MIC")

    /// NDS widens the lockable set to include X and Y.
    override var lockableMask: UInt32 {
        GBAInput.a.rawValue | GBAInput.b.rawValue | GBAInput.x.rawValue | GBAInput.y.rawValue
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupNDSButtons()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupNDSButtons()
    }

    private func setupNDSButtons() {
        for v in [btnX, btnY, btnMic] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            addSubview(v)
        }

        btnX.accessibilityLabel = "X button"
        btnY.accessibilityLabel = "Y button"
        btnMic.accessibilityLabel = "Microphone blow button"

        // Round hit-tests for the diamond face buttons so they don't overlap at the corners.
        for b in [btnA, btnB, btnX, btnY] { b.roundHitbox = true }

        addNDSButtonMappings([
            (btnX, GBAInput.x.rawValue),
            (btnY, GBAInput.y.rawValue),
        ])

        // Register mic button for blow detection (not a key bitmask)
        micButton = btnMic
    }

    /// Dress the NDS-only buttons alongside the shared set: X/Y wear the same face-button dress as
    /// A/B. The Mic button's dress (its decal) lands in a later slice, so it stays plain for now.
    override func setDressed(_ on: Bool, isLandscape: Bool, system: PresetSystem,
                             variant: DressVariant = .nostalgia) {
        super.setDressed(on, isLandscape: isLandscape, system: system, variant: variant)
        let kind: DressKind = (system == .gba) ? .gba : (system == .nds) ? .nds : .gbc
        btnX.dressVariant = variant; btnX.dressKind = kind; btnX.dressed = on
        btnY.dressVariant = variant; btnY.dressKind = kind; btnY.dressed = on
        // SELECT/START keep the shared pill dress (the skin draws the creusé pill + label; the
        // tiny button mirrors to the LEFT for NDS).
        // MIC: a pure skin decal (vertical slit + "MIC." label); the button itself draws nothing.
        btnMic.dressVariant = variant; btnMic.dressKind = kind
        btnMic.dressStyle = on ? .decal : .none
    }

    /// Extend the base set with the NDS-only buttons so the shared layout path
    /// positions and sizes them too.
    override func allButtonViews() -> [(ControlElement, UIView)] {
        var views = super.allButtonViews()
        views.append(contentsOf: [(.btnX, btnX), (.btnY, btnY), (.btnMic, btnMic)])
        return views
    }
}
