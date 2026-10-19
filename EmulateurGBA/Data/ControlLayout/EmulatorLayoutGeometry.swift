//
//  EmulatorLayoutGeometry.swift
//  EmulateurGBA
//
//  Single source of truth for the device-relative layout of the in-game
//  screen(s) and the on-screen touch controls.
//
//  The whole in-game layout is expressed as the iPhone 14 Pro layout uniformly
//  scaled by a per-device factor (`deviceScale`). Controls and screen keep the
//  same proportions on every iPhone — smaller on an iPhone SE, larger on a Pro
//  Max — instead of overflowing or overlapping the way the previous hardcoded
//  points did on anything that was not a 14 Pro.
//
//  Reference device: iPhone 14 Pro (393 x 852 pt). At that size deviceScale == 1
//  and every value below is pixel-identical to the original hand-tuned constants,
//  so the device this layout was designed on is unaffected.
//
//  Consumers (all go through this type, none re-encode the numbers):
//   - TouchControlsView / NDSTouchControlsView  (default + custom button layout)
//   - ControlLayoutDefaults                     (normalized default positions)
//   - EmulatorViewController.layoutGameView      (game screen frame)
//   - ControlLayoutEditorViewController          (editor preview geometry)
//   - InGameLayoutPreview (DEBUG)                (Xcode canvas preview)
//

import UIKit

enum EmulatorLayoutGeometry {

    // MARK: - Device scale

    /// Short / long side of the reference device (iPhone 14 Pro), in points.
    static let referenceShortSide: CGFloat = 393
    static let referenceLongSide: CGFloat = 852

    /// Paranoid lower bound for the whole-layout scale. Does NOT engage on any
    /// current iPhone (the smallest, the SE at 375x667, lands at ~0.78). Comfort
    /// for touch targets is enforced separately, per button, by `minButtonDimension`.
    static let minDeviceScale: CGFloat = 0.7
    /// Upper bound for the PHONE family. Does NOT engage on any current iPhone
    /// (the Pro Max lands at ~1.12); it guards against a future jumbo phone
    /// blowing the controls up absurdly. A tablet window never reaches this
    /// clamp: it has its own pair below.
    static let maxDeviceScale: CGFloat = 1.25

    /// The tablet family's clamp (2026-09-05). A tablet's raw ratio runs from
    /// ~1.33 (iPad mini, 744x1133) to ~1.61 (13-inch, 1032x1376), and a pad
    /// drawn at phone size on a 13-inch screen is a pad the thumbs hunt for,
    /// so the range is allowed to be larger than the phones'. Both named so
    /// the device review can move them without touching a formula.
    static let tabletMinDeviceScale: CGFloat = 1.25
    static let tabletMaxDeviceScale: CGFloat = 1.6

    /// Uniform scale for `deviceSize` relative to the iPhone 14 Pro.
    /// Orientation-independent: compares short side to short side and long to long,
    /// then takes the tighter ratio so the scaled layout always fits the device.
    /// The clamp pair depends on the window's `LayoutFamily`; a phone window's
    /// answer is unchanged by the tablet family's existence.
    static func deviceScale(for deviceSize: CGSize) -> CGFloat {
        let shortSide = min(deviceSize.width, deviceSize.height)
        let longSide = max(deviceSize.width, deviceSize.height)
        guard shortSide > 0, longSide > 0 else { return 1 }
        let raw = min(shortSide / referenceShortSide, longSide / referenceLongSide)
        switch LayoutFamily.of(deviceSize) {
        case .phone:
            return min(max(raw, minDeviceScale), maxDeviceScale)
        case .tablet:
            return min(max(raw, tabletMinDeviceScale), tabletMaxDeviceScale)
        }
    }

    // MARK: - Button sizing

    /// Comfortable minimum on-screen dimension for a button (Apple's 44pt target).
    /// Applied per axis, but never raises a button above its own reference size —
    /// so intentionally-thin buttons (the L/R bars, Start/Select) stay thin and the
    /// reference device stays pixel-identical. Set to 0 to disable the floor.
    static let minButtonDimension: CGFloat = 44

    /// Reference (iPhone 14 Pro) size for an element in the given context, before
    /// the device scale. The per-context base sizes live on `ControlElement`.
    static func referenceSize(_ element: ControlElement, isNDS: Bool, isLandscape: Bool) -> CGSize {
        if isNDS {
            return isLandscape ? element.defaultNDSLandscapeSize : element.defaultNDSPortraitSize
        } else {
            return isLandscape ? element.defaultLandscapeSize : element.defaultSize
        }
    }

    /// Elements the SNES sizes like a DS rather than like a Game Boy.
    ///
    /// The console's pad is the DS's shape — a D-pad and four face buttons in a
    /// diamond — so those five take the DS's measurements. Everything else keeps
    /// the Game Boy family's, which is why this is a SET of elements and not a
    /// per-console table: the difference really is element by element.
    ///
    /// The D-pad is in the set for PORTRAIT ONLY (2026-08-17). In landscape this console's pad
    /// is the GBA's, in position and in size, because that page is the GBA's page: one panel
    /// with a gutter each side, and the gutter is where a pad goes. `snesLandscapeUsesGBAPad`
    /// names the exception so the two places that must agree — this size table and the layout
    /// in `ControlLayoutDefaults.snes` — cannot answer differently.
    static let snesUsesNDSSizing: Set<ControlElement> = [.dpad, .btnA, .btnB, .btnX, .btnY]
    static let snesLandscapeUsesGBAPad = true

    /// The PlayStation's four shoulders, which take a width of their own in BOTH
    /// orientations: one line of four across a portrait page, and two to a
    /// gutter in landscape. No other console has more than two of them.
    static let ps1Shoulders: Set<ControlElement> = [.btnL, .btnR, .btnL2, .btnR2]

    /// How much of the inherited bar HEIGHT those four keep. They are four where
    /// every other console has two, so they read as a band rather than as a pair;
    /// taking depth off turns the band back into a line. The top edge is held
    /// where the inherited row put it, so the picture above does not move.
    ///
    /// 0.805, which is 0.70 raised by 15%. It stays expressed against the
    /// INHERITED bar rather than as an absolute, so the row's top edge is still
    /// recovered from the height it was laid out with and the extra depth is
    /// spent downward, into the empty band, with nothing else moving.
    static let ps1PortraitShoulderHeightScale: CGFloat = 0.805

    /// How much of their own size the four faces keep in PORTRAIT.
    ///
    /// They sit inside a cross-shaped mark printed on their plateau, and at full
    /// size the outermost point of each just cleared the end of the mark's arm.
    /// This pulls them inside it. Their CENTRES are untouched -- only the size
    /// changes, so the diamond keeps its spacing and its middle.
    static let ps1PortraitFaceScale: CGFloat = 0.92

    /// How much of their own size the sticks keep in portrait. A tenth off the
    /// outer ring, which is the part that reads as furniture rather than as
    /// target: the thumb aims at the middle either way.
    static let ps1PortraitStickScale: CGFloat = 0.90

    /// PlayStation portrait: the picture rides up under the Dynamic Island
    /// instead of sitting `gbaPortraitTopPadding` below the safe area.
    ///
    /// This page carries more controls than any other the app draws, and every
    /// point the picture gives back at the top is a point they get at the bottom.
    /// Only the picture's ORIGIN moves; its size is unchanged, so the console's
    /// share of the page is the same and only the empty band above it is spent.
    static let ps1PortraitTopPadding: CGFloat = 8

    /// How wide those four bars are, against 90 for every other console's pair.
    ///
    /// The number is forced, not chosen. That row is pinned at three points: the
    /// L pair centres on the cross, the R pair on the diamond, and MENU on the
    /// page. Nothing there is free, so width is the only thing that can give.
    ///
    /// It was chosen when the two clusters were NOT symmetric about the page, and
    /// the note here recorded a tight side: 10.6pt from MENU to R1 against 24.8 on
    /// the other. That asymmetry is gone -- the diamond has since been slid right
    /// to mirror the cross's own margin -- so at 55 the row now leaves about 25pt
    /// at BOTH ends of MENU on a 14 Pro, 28 on a Pro Max and 47 on an SE (where
    /// the bar floors to 44 instead of scaling down). The bar therefore has slack
    /// it did not have when the number was set; it is kept at 55 because the page
    /// was reviewed on device at that width, not because it is still the ceiling.
    static let ps1PortraitShoulderWidth: CGFloat = 55

    /// And how wide they are in LANDSCAPE, against 110 for a console with two.
    ///
    /// Four bars, two to a gutter, side by side. The binding device is the SE,
    /// whose gutter is about 185 points: at 88 the pair plus its gap measures
    /// ~143 there and leaves a real margin, while on a Pro Max it is ~204 in a
    /// 265-point gutter. Wider than the portrait bar because a landscape gutter
    /// is wider than half a portrait page.
    static let ps1LandscapeShoulderWidth: CGFloat = 88

    /// The Nintendo 64's cross against the PlayStation's it was first laid out
    /// with: a fifth smaller (asked 2026-09-27).
    static let n64PadScale: CGFloat = 0.8
    static let n64LandscapePadScale: CGFloat = 0.6

    /// The C buttons, larger than the 40 they started at now that each group
    /// has a quarter of the page (asked 2026-09-27).
    static let n64CButtonSize: CGFloat = 46

    /// The Mega Drive's six faces, one size for all six: the real pad's two
    /// rows are close to the same size, and six buttons have to fit where the
    /// Super Nintendo fits four (the right half of an upright page, the right
    /// gutter on its side). Smaller than the DS face's 63.8 for that reason;
    /// the gap is the space left between two neighbours in a row and between
    /// the rows, and the rise is how much each button sits above its left
    /// neighbour, which is what makes the two rows the pad's arc rather than a
    /// grid. Named so the device review can move them.
    ///
    /// 50 on its side is forced by the 14 Pro: the right gutter between the
    /// picture and the Dynamic Island's inset is about 169 points there, and
    /// three faces and two gaps measure 166 at 50 (172 at 52 reached the
    /// island).
    static let mdFaceSize: CGFloat = 56
    static let mdLandscapeFaceSize: CGFloat = 50
    static let mdFaceGap: CGFloat = 8
    static let mdFaceRise: CGFloat = 12
    /// X Y Z against A B C: smaller on the six-button pad (about four fifths
    /// across in close photographs, asked 2026-10-08). The rows keep their
    /// centres, so the upper row simply leaves more room round itself.
    static let mdUpperFaceScale: CGFloat = 0.82

    /// The six-button arc's half extents from its centre, the largest face
    /// (A B C) deciding both: across, one step and a half face; up and down,
    /// half the rows' spacing, one rise and a half face.
    /// Only the tablet page reads it, so its faces are the tablet's
    /// (`ControlLayoutDefaults.tabletSize`).
    static func mdArcHalfExtent(isLandscape: Bool, deviceScale k: CGFloat) -> CGSize {
        let face = ControlLayoutDefaults.tabletSize(.btnA, system: .md, isLandscape: isLandscape,
                                                    deviceScale: k)
        let step = face.width + mdFaceGap * k
        let rowOffset = (face.height + mdFaceGap * k) / 2
        return CGSize(width: step + face.width / 2,
                      height: rowOffset + mdFaceRise * k + face.height / 2)
    }

    /// THE MEGA DRIVE ON AN IPAD (asked 2026-10-08), its own page as the
    /// Nintendo 64 has (`ControlLayoutDefaults.mdTablet`). Reference points:
    /// the margin from each column to the window's edge and from the lowest
    /// control to the bottom, the gap between groups, the gap between the
    /// picture and MENU under it (the surround reaches the same distance
    /// above the picture), and the margin kept round the cross (where the
    /// dress draws its bowl) and round the six buttons.
    static let mdTabletEdge: CGFloat = 20
    static let mdTabletBottom: CGFloat = 24
    static let mdTabletGap: CGFloat = 12
    static let mdTabletMenuGap: CGFloat = 16
    static let mdBowlMargin: CGFloat = 8
    /// On its side, where the two thumbs rest: the line the cross and the six
    /// buttons are centred on, as a fraction of the window's height. Below the
    /// middle, where hands holding an iPad by its sides reach without moving.
    static let mdTabletLandscapeThumbLine: CGFloat = 0.60

    /// The band an upright iPad keeps under the Mega Drive's picture, in
    /// points: MENU and the surround's foot, then the controls (CLIP over the
    /// six buttons on the right, MODE over the cross on the left), then the
    /// bottom margin. Every number is the page's own (`mdTablet`), so the picture
    /// takes everything else.
    static func mdTabletPortraitControlsHeight(deviceScale k: CGFloat) -> CGFloat {
        func size(_ e: ControlElement) -> CGSize {
            ControlLayoutDefaults.tabletSize(e, system: .md, isLandscape: false, deviceScale: k)
        }
        let menuBand = mdTabletMenuGap * k + size(.btnMenu).height + mdLandscapeSurroundBottom * k
        let arc = mdArcHalfExtent(isLandscape: false, deviceScale: k)
        let right = size(.btnClip).height + mdTabletGap * k + 2 * (arc.height + mdBowlMargin * k)
        let left = size(.btnSelect).height + mdTabletGap * k
            + size(.dpad).height + 2 * mdBowlMargin * k
        return menuBand + mdTabletGap * k + max(left, right) + mdTabletBottom * k
    }

    /// Reference size, chosen per element for the console being laid out.
    ///
    /// The `isNDS:` overload above is kept exactly as it was and still answers
    /// for every console that shipped before 1.2.5, so their sizes cannot move
    /// through this change. Only the SNES asks a different question.
    static func referenceSize(_ element: ControlElement, system: PresetSystem,
                              isLandscape: Bool) -> CGSize {
        // The Mega Drive is laid out on the Super Nintendo's page, so every
        // control the two share takes the Super Nintendo's size; its six faces
        // are its own, L and R included (they are X and Z here, round faces in
        // the upper row, not shoulder bars).
        // The Game Gear's cross a step smaller than the Game Boy page's (asked
        // 2026-10-10), the speaker under it taking the room. Its centre stays
        // where the page puts it, so nothing else moves.
        if system == .gg, element == .dpad {
            let pad = referenceSize(.dpad, isNDS: false, isLandscape: isLandscape)
            return CGSize(width: pad.width * ggPadScale, height: pad.height * ggPadScale)
        }
        // The Master System's 1 and 2 are the same size on its pad, side by
        // side (its dress, 2026-10-10): both take B's, the smaller of the two
        // the NES page gives, which leaves the right gutter room for the grey
        // plate each sits on.
        if system == .sms, element == .btnA {
            return referenceSize(.btnB, system: .nes, isLandscape: isLandscape)
        }
        if system == .md {
            if ControlElement.mdFaces.contains(element) {
                var side = isLandscape ? mdLandscapeFaceSize : mdFaceSize
                if ControlElement.mdUpperRow.contains(element) { side *= mdUpperFaceScale }
                return CGSize(width: side, height: side)
            }
            return referenceSize(element, system: .snes, isLandscape: isLandscape)
        }
        // The Nintendo 64 started on the PlayStation's page (`layoutPage`), so
        // every control the two share takes the PlayStation's size unless it
        // was asked otherwise below. The four C buttons are its own.
        if system == .n64 {
            if ControlElement.n64CButtons.contains(element) {
                return CGSize(width: n64CButtonSize, height: n64CButtonSize)
            }
            switch element {
            // Z is a ROUND button beside A and B, the three forming a triangle
            // (asked 2026-09-27), so it takes a face button's size rather than
            // the PlayStation's L2 bar.
            case .btnL2:
                return referenceSize(.btnA, system: .ps1, isLandscape: isLandscape)
            // The cross a fifth smaller than the PlayStation's upright, and
            // smaller again on its side, where it shares the gutter with the
            // stick above it (both asked 2026-09-27).
            case .dpad:
                let pad = referenceSize(.dpad, system: .ps1, isLandscape: isLandscape)
                let scale = isLandscape ? n64LandscapePadScale : n64PadScale
                return CGSize(width: pad.width * scale, height: pad.height * scale)
            // Upright, L and R are the GBA's bars, in the GBA's places: one row
            // with MENU at the top of the page (asked 2026-09-27).
            case .btnL where !isLandscape, .btnR where !isLandscape:
                return referenceSize(element, isNDS: false, isLandscape: false)
            default:
                return referenceSize(element, system: .ps1, isLandscape: isLandscape)
            }
        }
        // The PSP is laid out on the PlayStation's page (`layoutPage`) and is
        // that pad without the controls it lacks, so every control it has takes
        // the PlayStation's size, the nub its left stick's.
        if system == .psp {
            // The cross a step smaller than the PlayStation's (asked 2026-10-10):
            // on the PSP it is the second-rank control, the nub under it the first.
            if element == .dpad {
                let pad = referenceSize(.dpad, system: .ps1, isLandscape: isLandscape)
                return CGSize(width: pad.width * pspPadScale, height: pad.height * pspPadScale)
            }
            // On its side the four faces a little smaller than the PlayStation's
            // (which take the DS's landscape size, 63.8): the diamond's width is
            // what sets each gutter, and every point it gives back goes to the
            // picture (asked 2026-10-10: the picture was too small on its side).
            // Still well above the 44-point comfort floor.
            if isLandscape, [.btnA, .btnB, .btnX, .btnY].contains(element) {
                let f = referenceSize(element, system: .ps1, isLandscape: true)
                return CGSize(width: f.width * pspLandscapeFaceScale, height: f.height * pspLandscapeFaceScale)
            }
            return referenceSize(element, system: .ps1, isLandscape: isLandscape)
        }
        // The PlayStation joins the Super Nintendo here, and for the same
        // reason: its pad is the DS's shape too, a cross and four buttons in a
        // diamond, so those five take the DS's measurements. The SNES's own
        // answers are untouched by the addition, including the landscape D-pad
        // exception below, which both consoles want for the same reason (that
        // page is the GBA's page, and the GBA already parks a pad in its gutter).
        if system == .ps1, isLandscape, ps1Shoulders.contains(element) {
            let base = referenceSize(element, isNDS: false, isLandscape: true)
            return CGSize(width: ps1LandscapeShoulderWidth, height: base.height)
        }
        if system == .ps1, !isLandscape {
            let base = referenceSize(element, isNDS: false, isLandscape: false)
            if ps1Shoulders.contains(element) {
                return CGSize(width: ps1PortraitShoulderWidth,
                              height: base.height * ps1PortraitShoulderHeightScale)
            }
            if element == .stickLeft || element == .stickRight {
                return CGSize(width: base.width * ps1PortraitStickScale,
                              height: base.height * ps1PortraitStickScale)
            }
            if snesUsesNDSSizing.contains(element), element != .dpad {
                let face = referenceSize(element, isNDS: true, isLandscape: false)
                return CGSize(width: face.width * ps1PortraitFaceScale,
                              height: face.height * ps1PortraitFaceScale)
            }
        }
        if (system == .snes || system == .ps1) && snesUsesNDSSizing.contains(element) {
            let padIsGBAs = snesLandscapeUsesGBAPad && isLandscape && element == .dpad
            if !padIsGBAs {
                return referenceSize(element, isNDS: true, isLandscape: isLandscape)
            }
        }
        return referenceSize(element, isNDS: system == .nds, isLandscape: isLandscape)
    }

    /// Device-scaled size, chosen per element for the console being laid out.
    static func buttonSize(_ element: ControlElement, system: PresetSystem,
                           isLandscape: Bool, deviceScale: CGFloat) -> CGSize {
        let base = referenceSize(element, system: system, isLandscape: isLandscape)
        return CGSize(width: flooredDimension(base.width, scale: deviceScale),
                      height: flooredDimension(base.height, scale: deviceScale))
    }

    /// Device-scaled button size with the comfortable-minimum floor applied.
    /// At deviceScale == 1 this equals the reference size exactly.
    static func buttonSize(_ element: ControlElement, isNDS: Bool, isLandscape: Bool,
                           deviceScale: CGFloat) -> CGSize {
        let base = referenceSize(element, isNDS: isNDS, isLandscape: isLandscape)
        return CGSize(width: flooredDimension(base.width, scale: deviceScale),
                      height: flooredDimension(base.height, scale: deviceScale))
    }

    /// A single button dimension, device-scaled, never below `min(minButtonDimension, reference)`.
    private static func flooredDimension(_ reference: CGFloat, scale: CGFloat) -> CGFloat {
        max(reference * scale, Swift.min(minButtonDimension, reference))
    }

    // MARK: - Screen reserves (reference points — scaled by deviceScale at use)

    /// Bottom strip kept for the still-visible Menu button when a controller is
    /// connected and the on-screen pad is hidden.
    static let controllerMenuStrip: CGFloat = 72

    /// Where the pause menu's button goes with a controller on a device on its
    /// side, for a one-picture console (device report, 2026-09-27, on the
    /// Nintendo 64).
    ///
    /// A controller takes the side panels away and the picture grows to the
    /// full height, but MENU stays where the touch page put it: under the
    /// picture's centre on the Nintendo 64 and the PlayStation, in the bottom
    /// row on the others, so it now sits ON the game. It moves to the right
    /// gutter instead, at the height it had (clamped inside the page), and
    /// hugs the right edge when the gutter is narrower than the button. Where
    /// it already clears the picture it stays exactly where it was. The DS is
    /// not a case: its screens keep a strip below them for MENU.
    static func controllerLandscapeMenuCenter(current: CGPoint, menuSize: CGSize, screen: CGRect,
                                              container: CGSize, safeRightInset: CGFloat,
                                              deviceScale k: CGFloat) -> CGPoint {
        let menu = CGRect(x: current.x - menuSize.width / 2, y: current.y - menuSize.height / 2,
                          width: menuSize.width, height: menuSize.height)
        guard menu.intersects(screen) else { return current }
        let margin = 8 * k
        let rightEdge = container.width - max(safeRightInset, margin)
        let gutter = rightEdge - screen.maxX
        let x = gutter >= menuSize.width + 2 * margin
            ? (screen.maxX + rightEdge) / 2
            : rightEdge - menuSize.width / 2
        let y = min(max(current.y, margin + menuSize.height / 2),
                    container.height - margin - menuSize.height / 2)
        return CGPoint(x: x, y: y)
    }
    /// The same question upright, for a one-picture console: with a controller
    /// the picture grows down into the band the pad used to take, and MENU, the
    /// one control left, can end up ON it where the page placed it relative to
    /// controls that are now hidden. Found 2026-10-10 by the real-inset sweep on
    /// the iPads: the PSP's MENU 12 points into the picture on a 13-inch, the
    /// NES's wholly on it on all three. MENU then drops to just under the
    /// picture, at its own x, kept inside the page. Where it already clears the
    /// picture (every phone, every other console) it does not move.
    /// `pictureBottom` and the result are in the same space as `current`.
    static func controllerPortraitMenuCenter(current: CGPoint, menuSize: CGSize,
                                             pictureBottom: CGFloat, containerHeight: CGFloat,
                                             deviceScale k: CGFloat) -> CGPoint {
        guard current.y - menuSize.height / 2 < pictureBottom else { return current }
        let margin = 8 * k
        let y = min(pictureBottom + margin + menuSize.height / 2,
                    containerHeight - margin - menuSize.height / 2)
        return CGPoint(x: current.x, y: y)
    }

    /// NDS portrait: minimum height reserved below the screens for the controls.
    static let ndsPortraitControlsReserve: CGFloat = 280
    /// GBA portrait: extra top padding below the safe area before the screen.
    /// GBA-only — GB/GBC have their own `gbcPortraitTopPadding`.
    static let gbaPortraitTopPadding: CGFloat = 42
    /// Fraction of the view height given to the game screen in GBA portrait.
    /// GBA-only — GB/GBC have their own `gbcPortraitScreenRatio`.
    static let gbaPortraitScreenRatio: CGFloat = 0.45
    /// Fraction of the view height given to the two screens in NDS landscape.
    static let ndsLandscapeScreenRatio: CGFloat = 0.60

    // MARK: - Tablet reserves (2026-09-05, the iPad family; unused by any phone)

    /// Tablet landscape, single-screen consoles: the picture is height-bound
    /// between the safe area and a band below it for the SELECT · MENU · START
    /// row (the GBA, GB/GBC, NES and PlayStation stick that row to the picture's
    /// bottom edge). This is the gap kept above and below the row, in reference
    /// points; the row's own height comes from the element's landscape size.
    /// The SNES keeps its own two reserves, which already do this job.
    static let tabletLandscapeRowGap: CGFloat = 8
    /// Tablet portrait, single-screen consoles: the band kept under the picture
    /// for the pad is the 14 Pro's OWN band for this console, scaled. The pads
    /// are the 14 Pro's page scaled by the device factor, anchored to the top
    /// and the bottom of their band, so a band shorter than the reference band
    /// times the factor closes the two anchors on each other: a flat reserve of
    /// 300 reference points put Clip 58 points into A on a 13-inch (the first
    /// sweep, 2026-09-05). Computed through the phone page itself at the
    /// reference size and insets, so it can never drift from the page it
    /// scales.
    static let referencePortraitInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)

    /// Tablet portrait, the DS: the band under the two screens is the 14
    /// Pro's WHOLE band, scaled (2026-09-08). On the phone that band is the
    /// reserve above plus the phone's 34-point bottom inset, 314 points, and
    /// `ControlLayoutDefaults.ndsPortrait` was tuned against it; a tablet's
    /// inset is 20, so the reserve alone left the band seven percent short in
    /// reference points and closed the D-pad on the SELECT · START row: the
    /// dress's slot-2 well between the two needs twelve reference points of
    /// room and had two on a 13-inch, so it was never drawn.
    static var referenceNDSPortraitControlsHeight: CGFloat {
        ndsPortraitControlsReserve + referencePortraitInsets.bottom
    }

    static func referencePortraitControlsHeight(gameAspect: CGFloat, system: PresetSystem) -> CGFloat {
        let reference = CGSize(width: referenceShortSide, height: referenceLongSide)
        let picture = screenFrame(deviceSize: reference, safeInsets: referencePortraitInsets,
                                  hasTouchScreen: false, isLandscape: false,
                                  gameAspect: gameAspect, system: system,
                                  controllerConnected: false, deviceScale: 1)
        return referenceLongSide - picture.maxY
    }

    /// SNES landscape only: the gap above the picture, so the dress's inlaid panel has a top
    /// edge to draw, and the height reserved below it for the SELECT · MENU · START row (that
    /// row's gap, its height, and the panel's bottom margin). The device's bottom safe inset is
    /// added to the reserve at use, so the row clears the home indicator too.
    static let snesLandscapeTopMargin: CGFloat = 12
    static let snesLandscapeBottomReserve: CGFloat = 56
    /// The landscape home-indicator inset, counted into that reserve as a FLAT value rather
    /// than read from the device or scaled. Read from the device it would not be available
    /// where the layout needs it: `ControlLayoutDefaults.snes` recomputes this same screen
    /// frame with zero insets to place the row against it, and a picture whose height depended
    /// on an inset the layout does not have is a picture the row is positioned against wrongly.
    /// Flat rather than scaled because the indicator is 21pt on every phone that has one; the
    /// phones that do not are width-bound here and lose nothing to it.
    static let snesLandscapeIndicatorReserve: CGFloat = 21

    /// The Mega Drive dress's landscape surround (`MegaDriveSkin`): how far it
    /// reaches above the picture, and below the SELECT · MENU · START row. Here
    /// because the picture is placed from them (`mdLandscapePictureTop`).
    static let mdLandscapeSurroundTop: CGFloat = 12
    static let mdLandscapeSurroundBottom: CGFloat = 10

    /// The Mega Drive's picture on its side, on a phone: the block the dress
    /// draws (the surround, the picture in it and the MODE · MENU · START row
    /// it takes in) CENTRED on the page, asked 2026-10-08. The page is the
    /// Super Nintendo's, which puts its picture under a fixed top margin, and
    /// that fits the Super Nintendo because its picture is as tall as the page
    /// allows; the Mega Drive's 4:3 picture is narrower-shaped, is bound by the
    /// width instead, and so was left with all the spare height under the
    /// block. Never lower than leaves the home indicator's flat reserve under
    /// the block, never higher than the Super Nintendo's margin, so a picture
    /// with no spare height lands exactly where it did.
    static func mdLandscapePictureTop(deviceHeight h: CGFloat, pictureHeight: CGFloat,
                                      deviceScale k: CGFloat) -> CGFloat {
        func height(_ e: ControlElement) -> CGFloat {
            buttonSize(e, system: .md, isLandscape: true, deviceScale: k).height
        }
        // The row is centred on START's line (`ControlLayoutDefaults.snes`),
        // and the tallest of the three sets its bottom.
        let rowBottom = gbcLandscapeRowGap * k + height(.btnStart) / 2
            + max(height(.btnStart), height(.btnSelect), height(.btnMenu)) / 2
        let above = mdLandscapeSurroundTop * k
        let below = rowBottom + mdLandscapeSurroundBottom * k
        let centred = (h - (above + pictureHeight + below)) / 2 + above
        let lowest = h - snesLandscapeIndicatorReserve - below - pictureHeight
        return max(snesLandscapeTopMargin * k, min(centred, lowest))
    }

    /// The Master System's dress on its side (2026-10-10, asked that day): the
    /// picture's surround reaches this far above it and below the CLIP · MENU
    /// · PAUSE row it takes in, and the block is centred on the page.
    static let smsLandscapeSurroundTop: CGFloat = 12
    static let smsLandscapeSurroundBottom: CGFloat = 10

    /// The top of the Master System's picture on its side: the surround, the
    /// picture and the row stuck `gbcLandscapeRowGap` under it CENTRED on the
    /// page, as the Mega Drive's block is (`mdLandscapePictureTop`). The
    /// picture keeps the size the NES page gives it; only where it sits moves.
    /// Never lower than leaves the home indicator's flat reserve under the
    /// block, never above the page's top.
    static func smsLandscapePictureTop(deviceHeight h: CGFloat, pictureHeight: CGFloat,
                                       deviceScale k: CGFloat) -> CGFloat {
        let row = buttonSize(.btnMenu, system: .sms, isLandscape: true, deviceScale: k).height
        let above = smsLandscapeSurroundTop * k
        let below = gbcLandscapeRowGap * k + row + smsLandscapeSurroundBottom * k
        let centred = (h - (above + pictureHeight + below)) / 2 + above
        let lowest = h - snesLandscapeIndicatorReserve - below - pictureHeight
        return max(0, min(centred, lowest))
    }

    // MARK: - GB/GBC screen (decoupled from GBA)

    /// GB/GBC own their screen geometry so changes to the GBA screen never move them.
    /// These start equal to the GBA values above (zero visual change at introduction)
    /// and are tuned independently from here on. The shared 3:2 height shape below is
    /// the only constant GB/GBC keep in common with GBA, and GBA hardware aspect never
    /// changes, so it is not a coupling point.
    static let gbcLandscapePanel: CGFloat = 170
    static let gbcPortraitTopPadding: CGFloat = 42
    static let gbcPortraitScreenRatio: CGFloat = 0.45
    /// GB/GBC landscape: gap between the game-screen bottom and the SELECT·MENU·START row
    /// (and the same gap below the row to the dress surround's bottom). The row is stuck
    /// this far below the screen instead of floating centered in the strip below it.
    static let gbcLandscapeRowGap: CGFloat = 8

    /// Fixed shape used to derive the GB/GBC on-screen HEIGHT (the classic GBA 3:2
    /// footprint). Width then comes from the 160×144 display aspect. This is GB/GBC's
    /// own reference, independent of GBA's actual on-screen width, which they no longer track.
    static let gbcScreenHeightAspect: CGFloat = 240.0 / 160.0

    /// GB/GBC display aspect (160×144). The landscape on-screen WIDTH derives from this and
    /// is SHARED by GBA (so the two console dresses line up); each system keeps its own height.
    static let gbcDisplayAspect: CGFloat = 160.0 / 144.0

    // MARK: - Game screen frame

    /// Frame of the Metal view (the game screen, or the NDS side-by-side / stacked
    /// pair) for the given device + orientation + system. Matches the original
    /// EmulatorViewController.layoutGameView math exactly at deviceScale == 1.
    ///
    /// `gameAspect` is rendered width / rendered height (the DISPLAY aspect). For
    /// GBA pass 240/160; for GB/GBC pass 160/144; for NDS portrait pass the combined
    /// 256/384 texture aspect (the NDS-landscape branch fills the screen area edge-to-
    /// edge and ignores `gameAspect`). `system` selects the geometry family: GB/GBC use
    /// their own panel/ratio/padding + a fixed 3:2 height shape, fully decoupled from
    /// GBA, and `gameAspect` only sets their (narrower) width.
    static func screenFrame(deviceSize: CGSize, safeInsets: UIEdgeInsets,
                            hasTouchScreen: Bool, isLandscape: Bool,
                            gameAspect: CGFloat, system: PresetSystem,
                            controllerConnected: Bool,
                            deviceScale k: CGFloat) -> CGRect {
        // The picture is the page's: the Nintendo 64 frames its game exactly as
        // the PlayStation does, so it is answered as that console everywhere below.
        // One rule below is the Mega Drive's own, so it is noted first.
        let isMD = (system == .md)
        let isPSP = (system == .psp)
        let isSMS = (system == .sms)
        let system = system.layoutPage
        let menuStrip = controllerMenuStrip * k
        // GB/GBC derive their on-screen HEIGHT from a fixed 3:2 shape (independent of
        // GBA's width); their width then comes from their own (narrower) display aspect.
        // Every other system uses its own aspect for both.
        let heightAspect: CGFloat = (system == .gbc) ? gbcScreenHeightAspect : gameAspect

        if isLandscape {
            if hasTouchScreen {
                // NDS landscape: screens fill the upper band, side by side.
                let screenAreaH = controllerConnected
                    ? deviceSize.height - menuStrip
                    : deviceSize.height * ndsLandscapeScreenRatio
                // With a controller the screens fill the width edge-to-edge, so on
                // notched devices the front-camera housing overlaps the screen on
                // the notch side. Inset by the horizontal safe area to clear it.
                // Without a controller the side gutters (the screens are height-
                // bound) already clear it, so the reference layout is untouched;
                // the insets are also 0 on non-notched devices like the SE.
                let leftInset = controllerConnected ? safeInsets.left : 0
                let rightInset = controllerConnected ? safeInsets.right : 0
                return CGRect(x: leftInset, y: 0,
                              width: deviceSize.width - leftInset - rightInset,
                              height: screenAreaH)
            } else {
                // A tablet window without a controller takes the tablet page below;
                // with one, the picture fills the window as it does on a phone.
                // THE PSP ON AN IPAD ON ITS SIDE (asked 2026-10-11: the picture
                // bigger): side panels only as wide as its column of controls
                // needs, the picture takes the rest.
                if isPSP, LayoutFamily.of(deviceSize) == .tablet, !controllerConnected {
                    return pspTabletLandscapeScreenFrame(deviceSize: deviceSize, gameAspect: gameAspect,
                                                         deviceScale: k)
                }
                if LayoutFamily.of(deviceSize) == .tablet, !controllerConnected {
                    return tabletLandscapeScreenFrame(
                        deviceSize: deviceSize, safeInsets: safeInsets,
                        gameAspect: gameAspect, system: system, deviceScale: k)
                }
                // GBA + GB/GBC landscape: game between two side control panels. They SHARE the
                // panel width AND the on-screen WIDTH (derived from the GB/GBC display shape),
                // so the two console dresses line up; each system then takes its own HEIGHT from
                // its aspect (GBA keeps 3:2, GB/GBC its 10:9). Both top-aligned.
                // THE PSP keeps gutters only as wide as its own controls need
                // (`pspLandscapePanel`), so its wide picture takes the rest
                // (asked 2026-10-10: the picture was too small on its side).
                if isPSP && !controllerConnected {
                    return pspLandscapeScreenFrame(deviceSize: deviceSize, gameAspect: gameAspect,
                                                   deviceScale: k)
                }
                let panelWidth: CGFloat = controllerConnected ? 0 : gbcLandscapePanel * k
                let availW = deviceSize.width - panelWidth * 2
                // The SNES gives up a little height at BOTH ends, and only this console does.
                // Its dress frames the picture in an inlaid panel, and a picture flush with
                // y = 0 leaves that panel nowhere to be: the surround's top edge rendered off
                // the device and the game stood proud of its own frame. Below, the
                // SELECT · MENU · START row is stuck to the picture's bottom, so a taller
                // picture pushes the row into the home indicator. Reserving both ends here is
                // what lets the panel be a frame.
                // The SNES reserves at BOTH ends, the NES only at the bottom: both stick their
                // SELECT · MENU · START row under the picture, so both need room for it, and
                // only the SNES's dress needs a top edge to draw (the NES's panel grows from the
                // picture instead). Without the bottom reserve the row lands ON the game, which
                // is what the landscape sweep caught.
                let snesInset = (system == .snes && !controllerConnected)
                let nesInset = (system == .nes && !controllerConnected)
                let topInset = snesInset ? snesLandscapeTopMargin * k : 0
                let bottomReserve = (snesInset || nesInset)
                    ? snesLandscapeBottomReserve * k + snesLandscapeIndicatorReserve : 0
                let availH = deviceSize.height - topInset - bottomReserve
                let commonWidth = (availW / gbcScreenHeightAspect) * gbcDisplayAspect
                var fitW = commonWidth
                var fitH = fitW / gameAspect
                if fitH > availH { fitH = availH; fitW = fitH * gameAspect }
                let x = panelWidth + (availW - fitW) / 2
                // GBA is vertically centered; GB/GBC stays top-aligned; the SNES sits under
                // its own top margin.
                // THE PLAYSTATION CENTRES TOO, and unlike the GBA it needs the band
                // that leaves UNDER the picture: its SELECT · MENU · START row lives
                // there rather than in a gutter. It reserves nothing at either end,
                // so the two bands are equal and the row sits in the lower one.
                // THE MEGA DRIVE, on the Super Nintendo's page, centres its
                // block (`mdLandscapePictureTop`).
                let y: CGFloat
                if system == .gba || system == .ps1 {
                    y = (availH - fitH) / 2
                } else if isMD && snesInset {
                    y = mdLandscapePictureTop(deviceHeight: deviceSize.height,
                                              pictureHeight: fitH, deviceScale: k)
                } else if isSMS && nesInset {
                    y = smsLandscapePictureTop(deviceHeight: deviceSize.height,
                                               pictureHeight: fitH, deviceScale: k)
                } else {
                    y = topInset
                }
                return CGRect(x: x, y: y, width: fitW, height: fitH)
            }
        } else {
            let availW = deviceSize.width
            // The DS keeps a band under its screens on every family; a tablet
            // window keeps the reference band whole (see
            // `referenceNDSPortraitControlsHeight`). The window's bottom inset
            // is subtracted here and comes back below the picture, so the band
            // measures the same whatever inset the caller passes.
            let minControlsH: CGFloat
            if !hasTouchScreen {
                minControlsH = 0
            } else if controllerConnected {
                minControlsH = menuStrip
            } else if LayoutFamily.of(deviceSize) == .tablet {
                minControlsH = max(0, referenceNDSPortraitControlsHeight * k - safeInsets.bottom)
            } else {
                minControlsH = ndsPortraitControlsReserve * k
            }
            // GB/GBC portrait uses its own screen-height fraction + top padding, so
            // GBA portrait can be tuned without moving GB/GBC.
            let portraitRatio = (system == .gbc) ? gbcPortraitScreenRatio : gbaPortraitScreenRatio
            let phoneMaxH: CGFloat = hasTouchScreen
                ? deviceSize.height - safeInsets.top - safeInsets.bottom - minControlsH
                : deviceSize.height * portraitRatio
            // Three answers, not two: the PlayStation joined with its own so the
            // other five keep theirs to the point.
            let portraitPad: CGFloat
            switch system {
            case .gbc: portraitPad = gbcPortraitTopPadding
            case .ps1: portraitPad = ps1PortraitTopPadding
            default:   portraitPad = gbaPortraitTopPadding
            }
            let extraPadding: CGFloat = hasTouchScreen ? 0 : portraitPad * k
            // A tablet window keeps the 14 Pro's band for the pad, scaled (see
            // `referencePortraitControlsHeight`), instead of the phone's fraction;
            // the DS already reserves a band on every family and is unchanged. The
            // flat status band stands in for the top inset so the cap is the same
            // whether the caller passes real insets or the zero ones
            // `ControlLayoutDefaults` recomputes with; the reference band already
            // holds the phone's bottom inset, which is deeper than an iPad's.
            // THE MEGA DRIVE ON AN IPAD takes the window's whole width upright
            // (asked 2026-10-08): its own page packs the controls into the band
            // it needs (`mdTabletPortraitControlsHeight`), where the shared rule
            // kept the 14 Pro's band scaled and left the picture 595 points wide
            // on a 744-point mini. The surround reaches above the picture as far
            // as MENU sits below it, so the picture starts that far down.
            // THE PSP ON A PHONE (asked 2026-10-10: the picture sat too high):
            // full width, lowered so the pad's block below it is as tall as the
            // controls need (`pspPortraitControlsHeight`, home indicator
            // included) and no taller. The page then reads picture, shoulders,
            // clusters, SELECT · START, with no empty band anywhere. Never above
            // the GBA's top padding, which is where the picture sat lowest
            // before (the PlayStation's own padding is 8).
            if isPSP, !hasTouchScreen, !controllerConnected, LayoutFamily.of(deviceSize) == .phone {
                let w = availW
                let h = w / gameAspect
                let top = safeInsets.top + gbaPortraitTopPadding * k
                let low = deviceSize.height - pspPortraitControlsHeight(deviceScale: k) - h
                // Raised by the triangle's height (asked 2026-10-12), the
                // controls staying where they are: `pspPortraitPictureLift`
                // says how far it actually rose, and the layout puts the
                // controls that hang from the picture back down by as much.
                let lift = pspPortraitPictureLift(deviceScale: k, top: top, low: low)
                return CGRect(x: 0, y: max(top, low) - lift, width: w, height: h)
            }
            // THE PSP ON AN UPRIGHT IPAD (asked 2026-10-11: the picture lower),
            // as on the phone: full width, as low as leaves its controls their
            // band (`pspTabletPortraitControlsHeight`), never above the top reserve.
            if isPSP, !hasTouchScreen, !controllerConnected, LayoutFamily.of(deviceSize) == .tablet {
                var w = availW
                var h = w / gameAspect
                let room = deviceSize.height - tabletLandscapeTopReserve - pspTabletPortraitControlsHeight(deviceScale: k)
                if h > room { h = max(0, room); w = h * gameAspect }
                let low = deviceSize.height - pspTabletPortraitControlsHeight(deviceScale: k) - h
                return CGRect(x: (availW - w) / 2, y: max(safeInsets.top + tabletLandscapeTopReserve, low),
                              width: w, height: h)
            }
            if isMD, !hasTouchScreen, !controllerConnected, LayoutFamily.of(deviceSize) == .tablet {
                let above = mdTabletMenuGap * k
                let room = deviceSize.height - tabletLandscapeTopReserve - above
                    - mdTabletPortraitControlsHeight(deviceScale: k)
                var w = availW
                var h = w / gameAspect
                if h > room { h = max(0, room); w = h * gameAspect }
                return CGRect(x: (availW - w) / 2, y: safeInsets.top + above, width: w, height: h)
            }
            let maxH: CGFloat = (LayoutFamily.of(deviceSize) == .tablet && !hasTouchScreen)
                ? deviceSize.height - tabletLandscapeTopReserve - extraPadding
                    - (controllerConnected
                        ? menuStrip
                        : referencePortraitControlsHeight(gameAspect: gameAspect, system: system) * k)
                : phoneMaxH
            var fitH = availW / heightAspect
            if fitH > maxH { fitH = maxH }
            var fitW = fitH * gameAspect
            var x = (availW - fitW) / 2
            var y = safeInsets.top + extraPadding
            // The NES fills the WIDTH, always, and grows upward to do it.
            //
            // The height cap above exists to protect the controls, and it protects them by
            // taking width away from the picture, which on a short phone left this console's
            // game floating in a band of body with a margin each side. So it takes back the
            // width and pays for it from the top of the page instead: same bottom edge, so the
            // controls container is untouched and the cap keeps the room it was defending, and
            // a taller picture above it. Every other console is unchanged, and so is the NES
            // wherever the cap never bound (a 14 Pro reaches full width on its own).
            // A tablet window keeps the cap's answer as it is: the margin it leaves
            // is a few points each side of a picture over 800 points tall, and
            // growing upward would spend the very band the tablet cap reserves.
            if system == .nes, !hasTouchScreen, fitW < availW,
               LayoutFamily.of(deviceSize) == .phone {
                let bottom = y + fitH
                fitW = availW
                fitH = fitW / gameAspect
                x = 0
                // Grow upward from the bottom edge the cap chose — but not off the page. On an
                // SE the full-width picture is taller than the room above that edge, and the
                // overflow is the TOP of the picture, which would simply not be drawn. Pinning
                // the top instead spends the difference downward, where it costs the controls
                // container a few points it can absorb, rather than costing the player pixels.
                y = max(0, bottom - fitH)
            }
            return CGRect(x: x, y: y, width: fitW, height: fitH)
        }
    }

    /// Tablet landscape, single-screen consoles (2026-09-05). The phone page keeps
    /// the picture at 74 % of the room between the two panels so the GB and GBA
    /// dresses share a width; on a tablet that room is over 800 points wide and
    /// the picture would sit small in the middle of it, so here it takes the
    /// whole width between the panels and is capped by the height instead: the
    /// window minus a status-bar band at the top, a home-indicator band at the
    /// bottom, and the SELECT · MENU · START row the single-screen consoles stick
    /// under the picture. Then it is centred in what is left, every console alike.
    ///
    /// Inset-free ON PURPOSE, like the phone page: `ControlLayoutDefaults`
    /// recomputes this frame with zero insets to place the row against it, and
    /// a frame that moved with the insets would put the row against a picture
    /// the app does not draw. The two bands are flat reference points for that
    /// reason, the same reason `snesLandscapeIndicatorReserve` is flat.
    static let tabletLandscapeTopReserve: CGFloat = 24
    static let tabletLandscapeBottomReserve: CGFloat = 20
    /// The side panel, in reference points. Ten wider than the phone's 170: the
    /// D-pad is centred in the gutter between the LEFT SAFE INSET and the
    /// picture, and on a phone the island's 59 points push it clear of the edge;
    /// a tablet has no side inset, and at 170 the scaled D-pad's hit rect ran
    /// three points off the window. At 180 it keeps four to five on every size.
    static let tabletLandscapePanel: CGFloat = 180
    /// The SNES's diamond is the DS's four buttons centred in the right gutter,
    /// and it needs about 195 reference points of gutter; on a phone the picture
    /// is narrower than the room between the panels, so the diamond borrows the
    /// unused margin, and on a tablet the picture takes all of it. Its panel is
    /// wider by this much (the first sweep had A seven points off the window).
    static let tabletLandscapeSNESPanelExtra: CGFloat = 20

    /// The PSP on a phone held sideways (2026-10-10): each gutter exactly as
    /// wide as the widest cluster it holds (the diamond) and a margin each
    /// side, plus the side safe area; the picture takes all the width between,
    /// capped by the page's height above its row, and is centred in that
    /// height. Measured against the PlayStation's fixed panel, the picture is
    /// 12 % wider on a 14 Pro and a third wider on an SE (no side inset).
    ///
    /// Inset-free like every landscape frame here (the layout recomputes it
    /// with zero insets, `ControlLayoutDefaults.psp`), so the side inset is a
    /// flat reference value: the 59 points of the notched phones, which are
    /// the ones held sideways with an island; the SE, whose deviceScale is
    /// lowest, is the one phone without it and is told so by its shape.
    static let pspLandscapeSideInset: CGFloat = 59
    static let pspLandscapeGutterMargin: CGFloat = 8
    static let pspLandscapeFaceScale: CGFloat = 0.85
    /// The row band under the picture on its side (SELECT · START and the
    /// indicator), in reference points.
    static let pspLandscapeRowBand: CGFloat = 48
    /// Upright on a phone, the height kept under the picture for the pad: the
    /// stack `ControlLayoutDefaults.psp` builds, measured from its own parts
    /// rather than written as a constant, so every phone gets exactly the
    /// room it needs and no empty band (a constant left the SE's cross on the
    /// nub). Top to bottom: the shoulder row and its recess, the cross, the
    /// nub with the diamond level with it, SELECT · START, and their lift above
    /// the bottom of the glass (which holds the home indicator, as the layout's
    /// own `pspPortraitBottomLift` does, so no inset is counted twice).
    static func pspPortraitControlsHeight(deviceScale k: CGFloat) -> CGFloat {
        func s(_ e: ControlElement) -> CGSize { buttonSize(e, system: .psp, isLandscape: false, deviceScale: k) }
        let face = s(.btnA).width
        let diamondHalf = face * ControlLayoutDefaults.diamondStep + face / 2
        let gap = ControlLayoutDefaults.pspGap * k
        let shoulders = ControlLayoutDefaults.pspPortraitShoulderTop * k
            + max(s(.btnL).height, s(.btnMenu).height) + ControlLayoutDefaults.pspShoulderRecessDepth * k
        let left = s(.dpad).height + gap + s(.stickLeft).height / 2
        let thumbToRow = max(s(.stickLeft).height / 2, diamondHalf) + gap
        let row = max(s(.btnSelect).height, s(.btnStart).height) + ControlLayoutDefaults.pspPortraitBottomLift * k
        return shoulders + gap + max(left, diamondHalf * 2) + thumbToRow + row
    }
    /// Upright on a phone, how far the picture rises above the pad's block:
    /// the triangle's whole height (asked 2026-10-12), less whatever the top
    /// padding does not leave (the SE's picture would otherwise reach it).
    /// One answer for the frame here and for the layout, which moves the
    /// controls hanging from the picture's edge (L, R, MENU, CLIP) back down by
    /// it, so none of them moves on the glass.
    static func pspPortraitPictureLift(deviceScale k: CGFloat, top: CGFloat, low: CGFloat) -> CGFloat {
        let triangle = buttonSize(.btnX, system: .psp, isLandscape: false, deviceScale: k).height
        return max(0, min(triangle, max(top, low) - top))
    }

    /// The PSP's cross against the PlayStation's.
    static let pspPadScale: CGFloat = 0.8
    /// The Game Gear's cross against the Game Boy's.
    static let ggPadScale: CGFloat = 0.8

    private static func pspLandscapeScreenFrame(deviceSize: CGSize, gameAspect: CGFloat,
                                                deviceScale k: CGFloat) -> CGRect {
        let face = buttonSize(.btnA, system: .psp, isLandscape: true, deviceScale: k).width
        let diamond = face * (2 * ControlLayoutDefaults.diamondStep + 1)
        // A phone without a notch (a home button) has no side safe area: its
        // shape is 16:9, where every notched phone is about 19.5:9.
        let notched = deviceSize.width / max(1, deviceSize.height) > 2
        let inset = notched ? pspLandscapeSideInset : 0
        let panel = inset + diamond + pspLandscapeGutterMargin * 2 * k
        let availW = deviceSize.width - panel * 2
        let availH = deviceSize.height - pspLandscapeRowBand * k - snesLandscapeIndicatorReserve
        var w = availW
        var h = w / gameAspect
        if h > availH { h = availH; w = h * gameAspect }
        // Centred in the glass's height (asked 2026-10-12: it sat high, centred
        // in the height ABOVE the row), or, where the row of four under it
        // would then not fit, as low as leaves that row its height and a row
        // gap (`pspRowGap`, the one between SELECT and START) above and below
        // it. The row follows the picture (`ControlLayoutDefaults.psp`).
        let row = [ControlElement.btnSelect, .btnStart, .btnMenu, .btnClip]
            .map { buttonSize($0, system: .psp, isLandscape: true, deviceScale: k).height }.max() ?? 0
        let lowest = deviceSize.height - snesLandscapeIndicatorReserve
            - row - 2 * ControlLayoutDefaults.pspRowGap * k - h
        let y = max((availH - h) / 2, min((deviceSize.height - h) / 2, lowest))
        return CGRect(x: (deviceSize.width - w) / 2, y: y, width: w, height: h)
    }

    /// The PSP on an iPad on its side: each side panel the width of its widest
    /// column (the diamond, or the cross over the nub) and a margin either
    /// side; the picture as large as the rest of the width and the height above
    /// SELECT · START allow, centred in the height above that row.
    private static func pspTabletLandscapeScreenFrame(deviceSize: CGSize, gameAspect: CGFloat,
                                                      deviceScale k: CGFloat) -> CGRect {
        func s(_ e: ControlElement) -> CGSize {
            ControlLayoutDefaults.tabletSize(e, system: .psp, isLandscape: true, deviceScale: k)
        }
        let face = s(.btnA).width
        let diamond = face * (2 * ControlLayoutDefaults.diamondStep + 1)
        let column = max(diamond, s(.dpad).width * ControlLayoutDefaults.ps1PlateauScale)
        let panel = ControlLayoutDefaults.n64TabletEdge * k + column + ControlLayoutDefaults.n64TabletGap * k
        let availW = deviceSize.width - panel * 2
        let row = max(s(.btnSelect).height, s(.btnStart).height) + tabletLandscapeRowGap * k * 2
        let availH = deviceSize.height - tabletLandscapeTopReserve - tabletLandscapeBottomReserve - row
        var w = availW
        var h = w / gameAspect
        if h > availH { h = availH; w = h * gameAspect }
        return CGRect(x: (deviceSize.width - w) / 2, y: tabletLandscapeTopReserve + (availH - h) / 2,
                      width: w, height: h)
    }

    /// The band an upright iPad keeps under the PSP's picture: what its tablet
    /// page stacks (L and R, the cross over the nub or the diamond, SELECT ·
    /// START) and the bottom margin, so the picture sits just above it.
    static func pspTabletPortraitControlsHeight(deviceScale k: CGFloat) -> CGFloat {
        func s(_ e: ControlElement) -> CGSize {
            ControlLayoutDefaults.tabletSize(e, system: .psp, isLandscape: false, deviceScale: k)
        }
        let gap = ControlLayoutDefaults.n64TabletGap * k
        let face = s(.btnA).width
        let diamondHalf = face * ControlLayoutDefaults.diamondStep + face / 2
        let stickReach = s(.stickLeft).width * ControlLayoutDefaults.ps1StickBossSpan / 2
        let padReach = s(.dpad).width * ControlLayoutDefaults.ps1PlateauScale / 2
        let left = stickReach * 2 + gap + padReach * 2
        let right = diamondHalf * 2
        let shoulders = s(.btnL).height + gap + s(.btnClip).height + gap
        return gap + shoulders + max(left, right) + gap
            + max(s(.btnSelect).height, s(.btnStart).height) + ControlLayoutDefaults.n64TabletBottom * k
    }

    private static func tabletLandscapeScreenFrame(deviceSize: CGSize, safeInsets: UIEdgeInsets,
                                                   gameAspect: CGFloat, system: PresetSystem,
                                                   deviceScale k: CGFloat) -> CGRect {
        let isSNES = (system == .snes)
        let panelWidth = (tabletLandscapePanel + (isSNES ? tabletLandscapeSNESPanelExtra : 0)) * k
        let availW = deviceSize.width - panelWidth * 2
        let topInset = tabletLandscapeTopReserve + (isSNES ? snesLandscapeTopMargin * k : 0)
        let rowH = buttonSize(.btnStart, system: system, isLandscape: true, deviceScale: k).height
        // The PlayStation does not stick its row to the picture: it centres it in
        // whatever band is left below its skirt, indicator band included, so its
        // band gets one gap more or the row's bottom edge lands in the indicator.
        let rowBand = isSNES
            ? snesLandscapeBottomReserve * k
            : tabletLandscapeRowGap * k * (system == .ps1 ? 3 : 2) + rowH
        let availH = deviceSize.height - topInset - tabletLandscapeBottomReserve - rowBand
        var fitW = availW
        var fitH = fitW / gameAspect
        if fitH > availH { fitH = availH; fitW = fitH * gameAspect }
        let x = panelWidth + (availW - fitW) / 2
        let y = topInset + (availH - fitH) / 2
        return CGRect(x: x, y: y, width: fitW, height: fitH)
    }

    /// The controls container frame for a given device + screen frame: the area the
    /// normalized button positions are relative to. Mirrors
    /// EmulatorViewController.applyControlConstraints():
    ///  - GBA landscape: controls overlay the whole view.
    ///  - everything else: controls sit below the screen(s).
    static func controlsFrame(deviceSize: CGSize, screenFrame: CGRect,
                              hasTouchScreen: Bool, isLandscape: Bool) -> CGRect {
        let top: CGFloat = (isLandscape && !hasTouchScreen) ? 0 : screenFrame.maxY
        return CGRect(x: 0, y: top, width: deviceSize.width, height: deviceSize.height - top)
    }

    // MARK: - NDS landscape side bars (L / R)

    /// Aspect ratio of a single NDS screen (256 x 192 = 4:3).
    static let ndsScreenAspect: CGFloat = 256.0 / 192.0

    /// Smallest width a gutter-fitted L/R bar is allowed to shrink to, so it stays
    /// tappable even on the narrowest device.
    static let minSideBarWidth: CGFloat = 28

    /// Recovers the NDS-landscape screen band height from the controls container.
    /// The landscape frames carry no safe-area inset, so the controls always occupy
    /// the lower `1 - ndsLandscapeScreenRatio` of the device height — the band above
    /// is therefore exactly `containerH · ratio / (1 - ratio)`.
    private static func ndsLandscapeBandHeight(controlsContainer c: CGSize) -> CGFloat {
        let ratio = ndsLandscapeScreenRatio
        guard ratio > 0, ratio < 1, c.height > 0 else { return 0 }
        return c.height * ratio / (1 - ratio)
    }

    /// Width of the empty letterbox gutter on each side of the two side-by-side NDS
    /// screens in landscape. Each screen is aspect-fit (4:3) to half the view width
    /// and the pair is centred touching at the middle (see
    /// `EmulatorMetalView.rebuildNDSVertices`), so the empty space is split between
    /// the two outer edges. On a narrow device (iPhone SE) the pair is wide and the
    /// gutter thin (~34pt); on the 14 Pro the gutter is wide (~112pt).
    static func ndsLandscapeScreenGutter(controlsContainer c: CGSize) -> CGFloat {
        guard c.width > 0 else { return 0 }
        let band = ndsLandscapeBandHeight(controlsContainer: c)
        let pairWidth = Swift.min(c.width, 2 * band * ndsScreenAspect)
        return Swift.max(0, (c.width - pairWidth) / 2)
    }

    /// The two rendered NDS screen rects in landscape, expressed in the controls
    /// container's coordinate space: the screen band sits directly above the
    /// container, so its `y` runs from `-bandHeight` to `0`. `touch` is the right
    /// screen (the interactive one). Used to assert controls never cover a screen.
    static func ndsLandscapeScreenRects(controlsContainer c: CGSize) -> (left: CGRect, touch: CGRect) {
        let band = ndsLandscapeBandHeight(controlsContainer: c)
        let gutter = ndsLandscapeScreenGutter(controlsContainer: c)
        let screenW = Swift.max(0, c.width - 2 * gutter) / 2
        let left = CGRect(x: gutter, y: -band, width: screenW, height: band)
        let touch = CGRect(x: gutter + screenW, y: -band, width: screenW, height: band)
        return (left, touch)
    }

    /// Fits an NDS-landscape L/R bar into the gutter beside the screens when its
    /// default geometry would put it *on* a screen — the iPhone-SE bug where R lands
    /// on the touch screen. Returns the adjusted `(centerX, width)` in the container,
    /// or `nil` to keep the default. On wide-gutter devices (14 Pro) the default bar
    /// already clears the screens, so this returns `nil` and that device is untouched.
    /// `defaultCenterX` / `defaultWidth` are the resolved (device-scaled) values.
    static func ndsLandscapeSideBarFit(
        element: ControlElement, isNDS: Bool, isLandscape: Bool,
        defaultCenterX: CGFloat, defaultWidth: CGFloat, container: CGSize
    ) -> (centerX: CGFloat, width: CGFloat)? {
        guard isNDS, isLandscape, element == .btnL || element == .btnR else { return nil }
        let gutter = ndsLandscapeScreenGutter(controlsContainer: container)
        guard gutter > 0, gutter < container.width / 2 else { return nil }
        let edge: CGFloat = 2   // clearance from the device edge and the screen edge
        let width = Swift.min(defaultWidth, Swift.max(minSideBarWidth, gutter - 2 * edge))

        if element == .btnL {
            // Already clear of the left screen at its default geometry? Leave it.
            guard defaultCenterX + defaultWidth / 2 > gutter else { return nil }
            return (edge + width / 2, width)
        } else {
            let screenRight = container.width - gutter
            guard defaultCenterX - defaultWidth / 2 < screenRight else { return nil }
            return (container.width - edge - width / 2, width)
        }
    }

    /// The render-time NDS-landscape geometry fix that the layout's normalized
    /// positions can't apply itself, because it depends on the comfort-FLOORED sizes
    /// (computed here, not in `ControlLayoutDefaults`): keep the L/R bars in the
    /// screen-side gutter. Acts only when the default geometry would overlap, so
    /// devices that don't need it (the 14 Pro) get their input back unchanged. Single
    /// entry point for every consumer (`TouchControlsView`, editor, layout tests).
    /// (The Mic/Clip bottom-row lift was removed once Mic moved INTO that row; the
    /// `layout` / `deviceScale` params are kept for the call contract + future fixups.)
    static func ndsLandscapeAdjusted(
        element: ControlElement, isNDS: Bool, isLandscape: Bool,
        center: CGPoint, size: CGSize, container: CGSize,
        layout: OrientationLayout, deviceScale: CGFloat
    ) -> (center: CGPoint, size: CGSize) {
        guard isNDS, isLandscape else { return (center, size) }
        var center = center
        var size = size

        if let fit = ndsLandscapeSideBarFit(
            element: element, isNDS: true, isLandscape: true,
            defaultCenterX: center.x, defaultWidth: size.width, container: container) {
            center.x = fit.centerX
            size.width = fit.width
        }

        return (center, size)
    }
}
