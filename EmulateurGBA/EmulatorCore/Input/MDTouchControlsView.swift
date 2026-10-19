//
//  MDTouchControlsView.swift
//  EmulateurGBA
//
//  Mega Drive touch controls: the cross, the six-button pad's two rows, START
//  and MODE, with the app's MENU and CLIP.
//
//  THE SIX FACES are six round buttons, each sending the bit the bridge maps
//  to that Mega Drive button (BlastEmBridge.h). The bits are positions on a
//  modern pad, so a controller needs no mapping of its own; on the glass the
//  buttons are drawn where the Mega Drive has them instead, A B C below and
//  X Y Z above (`ControlLayoutDefaults.md`):
//
//    A  `btnY`  bit y (0x800)        X  `btnL`  bit l (0x200)
//    B  `btnA`  bit a (0x001)        Y  `btnX`  bit x (0x400)
//    C  `btnB`  bit b (0x002)        Z  `btnR`  bit r (0x100)
//
//  The base class's A and B serve as B and C, relabelled, as the PlayStation
//  relabels them as its circle and cross. A and Y are new views. X and Z are
//  new ROUND views laid out as `btnL` and `btnR`, in place of the base class's
//  shoulder bars, which this console does not have: those two stay hidden and
//  unlaid, so they have no frame to hit (the Nintendo 64 leaves SELECT the
//  same way).
//
//  MODE is the base class's SELECT, relabelled: it sits where SELECT sits and
//  travels as the select bit, which the bridge sends as MODE.
//

import UIKit

final class MDTouchControlsView: TouchControlsView {
    private let btnFaceA = ActionButton(label: "A")
    private let btnFaceY = ActionButton(label: "Y")
    private let btnFaceX = ActionButton(label: "X")
    private let btnFaceZ = ActionButton(label: "Z")

    /// A, B and C lock, the three every Mega Drive game uses; X, Y and Z are
    /// read only by six-button games and are left out of the gesture.
    override var lockableMask: UInt32 {
        GBAInput.y.rawValue | GBAInput.b.rawValue | GBAInput.a.rawValue
    }

    /// The letters this pad prints on the lockable buttons. The base class
    /// names bits by the letters most consoles print on them, which here are
    /// the wrong ones (the a bit is B, the b bit C).
    override var lockableLetters: [String] { ["A", "B", "C"] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupMDButtons()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMDButtons()
    }

    private func setupMDButtons() {
        for v in [btnFaceA, btnFaceY, btnFaceX, btnFaceZ] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            addSubview(v)
        }

        btnA.setTitle("B")
        btnB.setTitle("C")
        btnSelect.setTitle("MODE")

        // The shoulder bars this pad does not have.
        btnL.isHidden = true
        btnR.isHidden = true

        btnFaceA.accessibilityLabel = "A button"
        btnA.accessibilityLabel = "B button"
        btnB.accessibilityLabel = "C button"
        btnFaceX.accessibilityLabel = "X button"
        btnFaceY.accessibilityLabel = "Y button"
        btnFaceZ.accessibilityLabel = "Z button"
        btnSelect.accessibilityLabel = "Mode button"

        // Round hit-tests: six buttons in two close rows would steal each
        // other's corners with square ones.
        for b in [btnA, btnB, btnFaceA, btnFaceX, btnFaceY, btnFaceZ] { b.roundHitbox = true }

        addNDSButtonMappings([
            (btnFaceA, GBAInput.y.rawValue),
            (btnFaceY, GBAInput.x.rawValue),
            (btnFaceX, GBAInput.l.rawValue),
            (btnFaceZ, GBAInput.r.rawValue),
        ])
    }

    /// The dress (palettes given 2026-10-08), the Nintendo 64's way: every
    /// control a moulding with its rim relief (`DressKind.wearsRelief`), each
    /// colour from the variant's palette, the letters printed on Classic and
    /// set into their buttons on Retro Pal (`MDSkinPalette.label(on:)`). A B C
    /// take one colour and X Y Z another; MODE and START are the discs the
    /// Nintendo 64 gives its START, in the small buttons' colour.
    override func setDressed(_ on: Bool, isLandscape: Bool, system: PresetSystem,
                             variant: DressVariant = .nostalgia) {
        super.setDressed(on, isLandscape: isLandscape, system: system, variant: variant)
        let kind = TouchControlsView.dressKind(for: system)
        let palette = variant.md
        for b in [btnFaceA, btnFaceX, btnFaceY, btnFaceZ] {
            b.dressVariant = variant
            b.dressKind = kind
            b.dressed = on
        }
        let faces: [(ActionButton, UIColor)] = [
            (btnFaceA, palette.abc), (btnA, palette.abc), (btnB, palette.abc),
            (btnFaceX, palette.xyz), (btnFaceY, palette.xyz), (btnFaceZ, palette.xyz),
        ]
        for (button, colour) in faces {
            button.dressFace = on ? colour : nil
            button.dressFaceLabel = on ? palette.label(on: colour) : nil
        }
        btnStart.dressStyle = on ? .n64Start : .none
        btnSelect.dressStyle = on ? .n64Start : .none
        // The pad's tactile dots: one under B, two under Y.
        btnA.mdDots = on ? 1 : 0
        btnFaceY.mdDots = on ? 2 : 0
    }

    /// The base set with the two shoulder bars swapped for the round X and Z,
    /// plus A and Y, so the shared layout path positions and sizes all six.
    override func allButtonViews() -> [(ControlElement, UIView)] {
        var views = super.allButtonViews().filter { $0.0 != .btnL && $0.0 != .btnR }
        views.append(contentsOf: [(.btnY, btnFaceA), (.btnX, btnFaceY),
                                  (.btnL, btnFaceX), (.btnR, btnFaceZ)])
        return views
    }
}
