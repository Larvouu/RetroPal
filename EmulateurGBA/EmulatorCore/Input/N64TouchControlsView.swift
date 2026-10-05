//
//  N64TouchControlsView.swift
//  EmulateurGBA
//
//  Nintendo 64 touch controls: the pad's own buttons and nothing else.
//
//  What the base class already carries serves as is: the cross, A, B, L, R,
//  START, MENU and CLIP. This adds the three things the pad has that the base
//  does not:
//
//  Z, the trigger under the pad. It is `btnL2` in the layout and travels as
//  `GBAInput.l2`, which is the bit the bridge reads as Z. On the page it is a
//  round face, the third corner of the A-B-Z triangle (layout of 2026-09-27),
//  so it is an ActionButton with a round hitbox, not a bar like L and R.
//
//  THE FOUR C BUTTONS, each its own bit (`GBAInput.cUp` and so on, the values
//  `N64InputBits` gives them in N64Bridge.h). Round hitboxes, because they sit
//  in a diamond close enough that square ones would steal each other's corners.
//
//  THE CONTROL STICK, the pad's main input. One stick, reported through
//  `onStickChanged`; the C buttons are buttons, so there is no second one.
//
//  SELECT exists in the base class and is never laid out here: the console has
//  no such button, `ControlElement.n64Elements` leaves it out, and a control
//  with no layout entry is hidden and has no frame to hit.
//
//  THE DRESS (palette given 2026-09-27) colours the BUTTONS, as the Super
//  Nintendo's does and the PlayStation's does not: A blue, B green, the four C
//  buttons and Z yellow, START red, L and R grey, each with its letter, word or
//  triangle set into it a shade darker. `setDressed` hands out those colours;
//  the shapes (the C triangle, START's disc, the cross's triangles, the stick's
//  rings) are drawn by the controls themselves.
//

import UIKit

final class N64TouchControlsView: TouchControlsView {
    private let btnZ = ActionButton(label: "Z")
    private let btnCUp = ActionButton(label: ControlElement.btnCUp.cButtonFace ?? "")
    private let btnCDown = ActionButton(label: ControlElement.btnCDown.cButtonFace ?? "")
    private let btnCLeft = ActionButton(label: ControlElement.btnCLeft.cButtonFace ?? "")
    private let btnCRight = ActionButton(label: ControlElement.btnCRight.cButtonFace ?? "")
    private let stick = AnalogStickView()

    /// The control stick, each axis -1...1, y positive DOWN, which is what the
    /// session passes on.
    var onStickChanged: ((_ value: CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupN64Buttons()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupN64Buttons()
    }

    private func setupN64Buttons() {
        for v in [btnZ, btnCUp, btnCDown, btnCLeft, btnCRight] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            addSubview(v)
        }

        // The stick keeps its own touches, as the PlayStation's do: it owns a
        // finger for that finger's whole life and follows it outside its bounds.
        stick.translatesAutoresizingMaskIntoConstraints = false
        stick.isUserInteractionEnabled = true
        stick.onChange = { [weak self] value in self?.onStickChanged?(value) }
        addSubview(stick)

        stick.accessibilityLabel = "Control stick"
        btnZ.accessibilityLabel = "Z trigger"
        btnCUp.accessibilityLabel = "C up button"
        btnCDown.accessibilityLabel = "C down button"
        btnCLeft.accessibilityLabel = "C left button"
        btnCRight.accessibilityLabel = "C right button"

        for b in [btnZ, btnCUp, btnCDown, btnCLeft, btnCRight] { b.roundHitbox = true }

        addNDSButtonMappings([
            (btnZ, GBAInput.l2.rawValue),
            (btnCUp, GBAInput.cUp.rawValue),
            (btnCDown, GBAInput.cDown.rawValue),
            (btnCLeft, GBAInput.cLeft.rawValue),
            (btnCRight, GBAInput.cRight.rawValue),
        ])
    }

    /// The stick claims its own touches, so the parent has to know it is there:
    /// without this a tap on it passes through to the game screen whenever the
    /// controls are in pass-through mode (a custom layout).
    override func extraClaimingViews() -> [UIView] { [stick] }

    /// The stick lets go too. Called when the controls are hidden or relaid out,
    /// so it cannot be stranded at full tilt by a touch nobody will end.
    override func releaseAllInputs() {
        super.releaseAllInputs()
        stick.reset()
    }

    override func setDressed(_ on: Bool, isLandscape: Bool, system: PresetSystem,
                             variant: DressVariant = .nostalgia) {
        super.setDressed(on, isLandscape: isLandscape, system: system, variant: variant)
        let kind = TouchControlsView.dressKind(for: system)
        // Every colour below comes from the variant's palette: the built-in one
        // for Classic and Retro Pal, the player's own for a custom skin.
        let palette = variant.n64
        // A and B: their own colours, the letter set into each. The base class
        // gave them the console's shared face, which on this pad is the triggers'.
        for (button, face) in [(btnA, palette.a), (btnB, palette.b)] {
            button.dressFace = on ? face : nil
            button.dressFaceLabel = on ? DressKind.n64Incised(face) : nil
        }
        // The C buttons: yellow, each carrying its triangle instead of "C▴".
        for (button, arrow) in [(btnCUp, ActionButton.N64Arrow.up), (btnCDown, .down),
                                (btnCLeft, .left), (btnCRight, .right)] {
            button.dressVariant = variant
            button.dressKind = kind
            button.dressFace = on ? palette.c : nil
            button.dressFaceLabel = on ? DressKind.n64Incised(palette.c) : nil
            button.n64Arrow = on ? arrow : nil
            button.dressed = on
        }
        // Z: the C buttons' yellow (palette revised 2026-09-27), its letter set into it.
        btnZ.dressVariant = variant
        btnZ.dressKind = kind
        btnZ.dressFace = on ? palette.z : nil
        btnZ.dressFaceLabel = on ? DressKind.n64Incised(palette.z) : nil
        btnZ.dressed = on
        // START is a red disc, not the pill the base class gives it.
        btnStart.dressStyle = on ? .n64Start : .none
        stick.dressVariant = variant
        stick.dressKind = kind
        stick.dressed = on
    }

    override func allButtonViews() -> [(ControlElement, UIView)] {
        var views = super.allButtonViews()
        views.append(contentsOf: [(.btnL2, btnZ), (.stickLeft, stick),
                                  (.btnCUp, btnCUp), (.btnCDown, btnCDown),
                                  (.btnCLeft, btnCLeft), (.btnCRight, btnCRight)])
        return views
    }
}
