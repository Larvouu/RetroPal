//
//  PS1TouchControlsView.swift
//  EmulateurGBA
//
//  PlayStation touch controls: the widest pad the app carries.
//
//  Two things are new here, and only one of them is the obvious one.
//
//  FOUR SHOULDERS. Every console before this had two, so `btnL2` and `btnR2`
//  are the first control elements added since the DS. They are ordinary
//  ShoulderButtons; what is new is that the layout has to fit four bars where
//  it used to fit two, which it does by STACKING them (see ControlLayoutDefaults)
//  rather than by making them thinner. A bar thin enough for four across is a
//  bar too thin to hit.
//
//  THE COLOUR IS ON THE SYMBOL, NOT THE BUTTON. This is the opposite of the
//  Super Nintendo, and it is the one thing that would look wrong if it were
//  copied from there. A Super Nintendo's four face buttons are four different
//  coloured plastics; a PlayStation's four are the same warm grey as the rest of
//  the pad, with a coloured shape PRINTED on each. So every face button takes
//  `DressKind.ps1Face`, and only `dressFaceLabel` differs between them.
//
//  The labels are the geometric shapes themselves rather than letters, because
//  that is what the player is looking at on the controller in their other hand.
//  They are characters, not artwork: a triangle, a circle, a cross and a square
//  are shapes, and drawing them is describing the hardware.
//

import UIKit

final class PS1TouchControlsView: TouchControlsView {
    private let btnX = ActionButton(label: "△")
    private let btnY = ActionButton(label: "□")
    private let btnL2 = ShoulderButton(label: "L2")
    private let btnR2 = ShoulderButton(label: "R2")
    // ANALOG, which is what Sony silkscreens on the pad. MODE was tried and
    // reverted on 2026-08-24: it is the name the same switch carries in wide use
    // and on third-party pads, and it is the shorter word in a 52pt pill, but a
    // player looking for this button is looking at a DualShock in their other
    // hand and that one says ANALOG. The element stays `btnMode` in code, where
    // the name describes what it does rather than what is printed on it.
    private let btnMode = SmallButton(label: "ANALOG")
    private let stickLeft = AnalogStickView()
    private let stickRight = AnalogStickView()
    // L3 and R3 are BUTTONS, not a tap on the stick. A stick is dragged, and a
    // control that is dragged cannot also report a press without one becoming
    // the other's accident: a thumb settling before it pushes would fire the
    // click every time. They sit beside their stick and answer only to a hold.
    private let btnL3 = SmallButton(label: "L3")
    private let btnR3 = SmallButton(label: "R3")

    /// Pressing the pad's ANALOG switch is not an emulated BUTTON, it is a
    /// message to the controller, so it does not travel in the input bitmask
    /// like everything else here. The host hands it to the bridge.
    var onModePressed: (() -> Void)?

    /// The sticks, each axis -1...1, y positive DOWN. Reported together because
    /// the bridge sets both every time and a pair is one fact about the pad.
    var onSticksChanged: ((_ left: CGPoint, _ right: CGPoint) -> Void)?

    /// All four faces lock, as on the DS and the SNES.
    override var lockableMask: UInt32 {
        GBAInput.a.rawValue | GBAInput.b.rawValue | GBAInput.x.rawValue | GBAInput.y.rawValue
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPS1Buttons()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPS1Buttons()
    }

    private func setupPS1Buttons() {
        for v in [btnX, btnY] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            addSubview(v)
        }
        for v in [btnL2, btnR2] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            addSubview(v)
        }
        for v in [btnMode, btnL3, btnR3] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            addSubview(v)
        }

        // The sticks are the ONE kind of control here that keeps its own touches.
        // See AnalogStickView: a stick owns a finger for that finger's whole
        // life, follows it outside its own bounds, and has to work while the
        // other stick is being dragged too. UIKit does that for a view with
        // interaction enabled; the parent's shared button loop does not.
        for stick in [stickLeft, stickRight] {
            stick.translatesAutoresizingMaskIntoConstraints = false
            stick.isUserInteractionEnabled = true
            stick.onChange = { [weak self] _ in self?.reportSticks() }
            addSubview(stick)
        }
        stickLeft.accessibilityLabel = "Left analog stick"
        stickRight.accessibilityLabel = "Right analog stick"

        // A and B come from the base class labelled with letters. On this pad
        // they are the circle and the cross, and they already sit in the right
        // places: `btnA` is the diamond's RIGHT vertex and `btnB` its BOTTOM
        // one, which is the positional convention every console here uses.
        btnA.setTitle("○")
        btnB.setTitle("✕")

        // The accessibility labels are WORDS, not the shapes. VoiceOver reading
        // "white up-pointing triangle" to someone is not the same as telling
        // them which button it is.
        btnX.accessibilityLabel = "Triangle button"
        btnY.accessibilityLabel = "Square button"
        btnA.accessibilityLabel = "Circle button"
        btnB.accessibilityLabel = "Cross button"
        btnL2.accessibilityLabel = "L2 button"
        btnR2.accessibilityLabel = "R2 button"
        btnMode.accessibilityLabel = "Analog mode button"
        btnL3.accessibilityLabel = "L3, left stick click. Hold to press."
        btnR3.accessibilityLabel = "R3, right stick click. Hold to press."

        // The shoulders are printed L1 and R1 on this pad. The base class
        // builds them as L and R, which is right for every console that has
        // only one pair.
        btnL.setTitle("L1")
        btnR.setTitle("R1")

        // Round hit-tests for the diamond so the four buttons do not steal each
        // other's corners, exactly as the DS and the SNES do.
        for b in [btnA, btnB, btnX, btnY] { b.roundHitbox = true }

        addNDSButtonMappings([
            (btnX, GBAInput.x.rawValue),
            (btnY, GBAInput.y.rawValue),
            (btnL2, GBAInput.l2.rawValue),
            (btnR2, GBAInput.r2.rawValue),
        ])
    }

    /// ANALOG is not in the button map above, on purpose. Everything in that
    /// map is a bit the console reads as a pressed button; this one asks the
    /// CONTROLLER to change what it is, so it is reported as a tap and the
    /// bridge turns it into the sequence the core listens for.
    override func tapTriggers() -> [(view: UIView, fire: () -> Void)] {
        [(btnMode, { [weak self] in self?.onModePressed?() })]
    }

    /// The sticks claim their own touches, so the parent has to know they are
    /// there: without this a tap on one passes straight through to the game
    /// screen whenever the controls are in pass-through mode.
    override func extraClaimingViews() -> [UIView] {
        [btnMode, stickLeft, stickRight]
    }

    /// L3 and R3, which fire only after a hold. See `TouchControlsView.holdTriggers`
    /// for why a tap on them must do nothing: they live a thumb's width from a
    /// control the player is on constantly, and an instantaneous stick click
    /// would go off every time a thumb strayed onto one. The hold is not a
    /// safety catch bolted onto the button, it IS the button.
    override func holdTriggers() -> [(view: UIView, mask: UInt32)] {
        [(btnL3, GBAInput.l3.rawValue), (btnR3, GBAInput.r3.rawValue)]
    }

    private func reportSticks() {
        onSticksChanged?(stickLeft.value, stickRight.value)
    }

    /// Both sticks let go. Called when the controls are hidden or relaid out, so
    /// a stick cannot be stranded at full tilt by a touch nobody will end.
    override func releaseAllInputs() {
        super.releaseAllInputs()
        stickLeft.reset()
        stickRight.reset()
    }

    /// The base class labels A and B with letters. On this pad they are the
    /// circle and the cross, and they sit where a PlayStation prints them:
    /// `btnA` is the RIGHT vertex of the diamond and `btnB` the BOTTOM one,
    /// which is the same positional convention every console here uses and the
    /// same one the bridge maps through (see `kButtonMap` in PCSXBridge).
    override func setDressed(_ on: Bool, isLandscape: Bool, system: PresetSystem,
                             variant: DressVariant = .nostalgia) {
        super.setDressed(on, isLandscape: isLandscape, system: system, variant: variant)
        let kind = TouchControlsView.dressKind(for: system)
        for b in [btnX, btnY] {
            b.dressVariant = variant
            b.dressKind = kind
            b.dressed = on
        }
        // THE SECOND SHOULDER PAIR dresses like the first, which the base class
        // has already done for L1 and R1. They draw themselves, so a press still
        // shows, and their engraved word comes from `DressKind.faceInk`.
        for b in [btnL2, btnR2] {
            b.dressVariant = variant
            b.dressKind = kind
            b.dressed = on
        }

        // ANALOG AND THE TWO STICK CLICKS DRESS LIKE SELECT AND START, which the
        // base class has already styled: one pill each, in this console's single
        // control colour.
        //
        // They were briefly drawn by the SKIN instead, with their layer hidden
        // so the two could not stack. That went wrong in the way worth recording:
        // the buttons vanished and the skin's versions never appeared in their
        // place, so five controls were simply gone. Whatever the cause, the
        // lesson is the same one this file keeps relearning -- a control that
        // draws itself the way every other console's does cannot go missing,
        // and a clever second path can.
        // NOT pills, and not one shape for the five of them. A DualShock prints
        // three different things in the middle of itself, and a capsule is none
        // of them: SELECT is a small rounded RECTANGLE with its word under it,
        // START is a TRIANGLE pointing right with its word under it the same
        // way, and ANALOG is a wider plate with its word cut INTO it. L3 and R3
        // take that plate in the shell's own colour, because on the hardware
        // they are moulded plastic rather than a painted control.
        //
        // The base class has already styled SELECT and START as pills, which is
        // right for every console that prints one; they are restyled here.
        //
        // WHICH shape each one prints is `SmallButton.PS1Shape.style(for:)` and
        // not a list here, because the SKIN has to carve a recess of the same
        // shape around each of them. Two copies of that mapping would be two
        // chances for a triangle to end up in a rounded-rectangle well.
        for (element, b) in [(ControlElement.btnSelect, btnSelect), (.btnStart, btnStart),
                             (.btnMode, btnMode), (.btnL3, btnL3), (.btnR3, btnR3)] {
            b.dressVariant = variant
            b.dressKind = kind
            b.dressStyle = on ? (SmallButton.PS1Shape.style(for: element) ?? .none) : .none
        }
        for stick in [stickLeft, stickRight] {
            stick.dressVariant = variant
            stick.dressKind = kind
            stick.dressed = on
        }

        // One plastic, four inks. `dressFace` is the same value for all four on
        // purpose: it is the Super Nintendo that is the exception here, not this.
        // The SHAPE comes with the ink now: the four marks are stroked paths in
        // one shared box rather than glyphs at a shared point size, because a
        // typeface renders triangle and square at visibly different widths.
        let faces: [(ActionButton, UIColor, ActionButton.PS1Symbol)] = [
            (btnA, DressKind.ps1Circle, .circle),
            (btnB, DressKind.ps1Cross, .cross),
            (btnX, DressKind.ps1Triangle, .triangle),
            (btnY, DressKind.ps1Square, .square),
        ]
        // THE BACKING IS A SLOT, THE INK NEVER IS (2026-08-27). The plastic
        // behind the four marks goes through the palette like every other
        // surface, which it did not before: it read `DressKind.ps1Face`
        // directly, so a custom skin could recolour the whole pad and the
        // diamond stayed the built-in grey.
        //
        // `ink` stays a constant on purpose and must never become a slot.
        // Square, cross, circle and triangle are how a player identifies a
        // button, and a skin that recolours them is a skin that makes the pad
        // unreadable.
        let backing = variant.abFace(kind) ?? DressKind.ps1Face
        for (button, ink, symbol) in faces {
            button.dressFace = on ? backing : nil
            button.dressFaceLabel = on ? ink : nil
            button.ps1Symbol = on ? symbol : nil
        }
    }

    /// Extend the base set so the shared layout path positions and sizes the
    /// four buttons the base class does not know about.
    override func allButtonViews() -> [(ControlElement, UIView)] {
        var views = super.allButtonViews()
        views.append(contentsOf: [(.btnX, btnX), (.btnY, btnY),
                                  (.btnL2, btnL2), (.btnR2, btnR2),
                                  (.btnMode, btnMode),
                                  (.stickLeft, stickLeft), (.stickRight, stickRight),
                                  (.btnL3, btnL3), (.btnR3, btnR3)])
        return views
    }
}
