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
    /// The 3DS's microphone, the DS's control: a recorded blow while held
    /// (CTRBridge). Only the 3DS's layout carries it, so it is hidden elsewhere.
    private let btnMic = SmallButton(label: "MIC")

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

    /// The four faces by the symbols this pad prints (the PlayStation's, and the
    /// PSP's on the same view), in the base class's order a, b, x, y. The base
    /// class names them A, B, X and Y, which the pause menu's hold-to-lock row
    /// drew on both consoles (found 2026-10-09). The same glyphs as the remap
    /// screen's (`RemappableInput.displayName(for: .ps1)`), read from there.
    override var lockableLetters: [String] {
        // The 3DS on this view prints letters, its own.
        [RemappableInput.a, .b, .x, .y].map { $0.displayName(for: system == .n3ds ? .n3ds : .ps1) }
    }

    /// The console this pad is drawn for: the PlayStation, or the PSP, which
    /// is this pad without six controls and prints its one shoulder pair L
    /// and R rather than L1 and R1 (found 2026-10-10: the PSP showed L1, R1).
    private let system: PresetSystem

    init(system: PresetSystem) {
        self.system = system
        super.init(frame: .zero)
        setupPS1Buttons()
    }

    override init(frame: CGRect) {
        self.system = .ps1
        super.init(frame: frame)
        setupPS1Buttons()
    }

    required init?(coder: NSCoder) {
        self.system = .ps1
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
        // only one pair, the PSP included: it keeps them. The editor's names
        // (`ControlElement.displayName(for:)`) say the same.
        if system == .ps1 {
            btnL.setTitle("L1")
            btnR.setTitle("R1")
        }

        // THE 3DS borrows this view and prints its own marks: letters
        // in the same diamond (A right, B bottom, X top, Y left, the bits the
        // bridge maps as the 3DS's own), and ZL and ZR on the second shoulder
        // pair, which is where a New 3DS has them, inward of L and R.
        if system == .n3ds {
            btnA.setTitle("A")
            btnB.setTitle("B")
            btnX.setTitle("X")
            btnY.setTitle("Y")
            btnL2.setTitle("ZL")
            btnR2.setTitle("ZR")
            btnX.accessibilityLabel = "X button"
            btnY.accessibilityLabel = "Y button"
            btnA.accessibilityLabel = "A button"
            btnB.accessibilityLabel = "B button"
            btnL2.accessibilityLabel = "ZL button"
            btnR2.accessibilityLabel = "ZR button"
            stickLeft.accessibilityLabel = "Circle pad"
            stickRight.accessibilityLabel = "C-Stick"
            btnMic.translatesAutoresizingMaskIntoConstraints = false
            btnMic.isUserInteractionEnabled = false
            btnMic.accessibilityLabel = "Microphone blow button"
            addSubview(btnMic)
            // Not a key in the bitmask: the base class reports it as the blow.
            micButton = btnMic
        }

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
        if system == .n3ds {
            setCTRDressed(on, isLandscape: isLandscape, variant: variant)
            return
        }
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
        // MIC dresses like SELECT and START, a pill in the console's colour.
        btnMic.dressVariant = variant
        btnMic.dressKind = kind
        btnMic.dressStyle = btnSelect.dressStyle

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
        // Retro Pal darkens the four faces under their inks (`RetroPalPalette.ps1Faces`).
        let backing = variant == .retroPal ? RetroPalPalette.ps1Faces
                                           : (variant.abFace(kind) ?? DressKind.ps1Face)
        // The PSP-1000 prints its four symbols in ONE grey, not four colours
        // (its own looks, 2026-10-10): the palette's print slot carries it.
        let pspInk = variant.isPSP ? variant.ps1Palette?.print : nil
        for (button, ink, symbol) in faces {
            button.dressFace = on ? backing : nil
            button.dressFaceLabel = on ? (pspInk ?? ink) : nil
            button.ps1Symbol = on ? symbol : nil
        }
    }

    /// THE 3DS wears the DS's dress (2026-10-20, `TouchControlsView.dressKind`),
    /// which the base class has applied to the cross, A, B, L, R, SELECT, START,
    /// MENU and CLIP. Here: the controls this view adds (X, Y, ZL, ZR, the two
    /// sticks), MIC as the DS's decal, and the four faces in ONE colour with
    /// their letters in one ink, as on a 3DS (his ask, 2026-10-21).
    ///
    /// Both ways up (his design, 2026-10-21): MENU and CLIP are rounded squares
    /// in the shoulders' corners; SELECT and START print their word, then the
    /// button; the circle pad glides in a still surround. Upright alone, the
    /// columns beside the lower screen are set into the phone's edges.
    /// The 3DS share card (`GBConsoleCardView`): its shoulders stand against its lower screen, not
    /// the phone's edges, upright as it is (`GBCardLayout.n3ds`).
    var shouldersAgainstScreens = false

    /// The edge each 3DS column control is drawn against, as the dress sets
    /// it (`setCTRDressed`), and whether it is the PHONE's edges (upright, not
    /// the share card's). Held apart from the controls' own `flushEdge`
    /// because a control drawn against an edge must stand at it: where a
    /// small iPad window moves CLIP and MENU off the columns, or the bars off
    /// the edge (`ControlLayoutDefaults.n3dsTablet`, audit 2026-10-30), its
    /// square side would face the middle of the page.
    private var ctrIntendedFlush: [ObjectIdentifier: FlushEdge] = [:]
    private var ctrFlushApplies = false

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCTRFlushEdges()
    }

    /// Each control's intended edge, kept only while it stands at that edge
    /// of this view (within a point); against the screens (on its side, the
    /// share card) the dress's edge stands as set.
    private func applyCTRFlushEdges() {
        let columns: [UIView] = [btnClip, btnMenu, btnL, btnL2, btnR, btnR2]
        for view in columns {
            guard let intended = ctrIntendedFlush[ObjectIdentifier(view)] else { continue }
            var edge = intended
            if ctrFlushApplies, bounds.width > 0 {
                let f = view.frame
                if (intended == .left && f.minX > 1) || (intended == .right && f.maxX < bounds.width - 1) {
                    edge = .none
                }
            }
            if let b = view as? SmallButton { b.flushEdge = edge }
            if let b = view as? ShoulderButton { b.flushEdge = edge }
        }
    }

    private func setCTRDressed(_ on: Bool, isLandscape: Bool, variant: DressVariant) {
        let kind = TouchControlsView.dressKind(for: .n3ds)
        for b in [btnX, btnY] {
            b.dressVariant = variant; b.dressKind = kind; b.dressed = on
        }
        for b in [btnL2, btnR2] {
            b.dressVariant = variant; b.dressKind = kind; b.dressed = on
        }
        for stick in [stickLeft, stickRight] {
            stick.dressVariant = variant; stick.dressKind = kind; stick.dressed = on
        }
        btnMic.dressVariant = variant
        btnMic.dressKind = kind
        btnMic.dressStyle = on ? .decal : .none
        let palette = variant.ctrPalette ?? .nostalgia
        let faces: [(ActionButton, UIColor)] = [
            (btnA, palette.faceA), (btnB, palette.faceB), (btnX, palette.faceX), (btnY, palette.faceY),
        ]
        // One ink for the four letters, the palette's letters slot, as on a
        // 3DS (his ask, 2026-10-21: one colour for the faces, one for the marks).
        for (button, colour) in faces {
            button.dressFace = on ? colour : nil
            button.dressFaceLabel = on ? palette.letters : nil
            button.ps1Symbol = nil
        }
        // The controls' LOOK is the same both ways up (his design, 2026-10-21:
        // on its side, each takes its upright look); only the columns set into
        // the phone's edges are upright alone, where they stand against them.
        let upright = on && !isLandscape
        for b in [btnMenu, btnClip] {
            b.squareCornerFraction = on ? ShoulderButton.ndsCornerFactor : nil
        }
        // Each column set into the phone's edge (`FlushEdge`): CLIP, ZL, L on
        // the left, MENU, ZR, R on the right (`ControlLayoutDefaults.n3dsPortrait`).
        ctrIntendedFlush[ObjectIdentifier(btnClip)] = upright ? .left : FlushEdge.none
        ctrIntendedFlush[ObjectIdentifier(btnMenu)] = upright ? .right : FlushEdge.none
        // On its side the columns stand against the SCREENS instead (his design,
        // 2026-10-21), ZL and L left of the top one, ZR and R right of the bottom
        // one: their inner side is the screen's.
        // The share card sets them against its lower screen the same way (`shouldersAgainstScreens`).
        let againstPhoneEdge = upright && !shouldersAgainstScreens
        for b in [btnL, btnL2] { ctrIntendedFlush[ObjectIdentifier(b)] = !on ? FlushEdge.none : (againstPhoneEdge ? .left : .right) }
        for b in [btnR, btnR2] { ctrIntendedFlush[ObjectIdentifier(b)] = !on ? FlushEdge.none : (againstPhoneEdge ? .right : .left) }
        ctrFlushApplies = againstPhoneEdge
        applyCTRFlushEdges()
        for b in [btnSelect, btnStart] { b.selectCircleOnRight = on }
        // The cross moulded like A B X Y (his ask, 2026-10-21).
        setCrossMoulded(on)
        stickLeft.ctrLook = on ? .circlePad : .none
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
        if system == .n3ds { views.append((.btnMic, btnMic)) }
        return views
    }
}
