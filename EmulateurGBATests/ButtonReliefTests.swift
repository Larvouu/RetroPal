//
//  ButtonReliefTests.swift
//  EmulateurGBATests
//
//  The rim relief the Nintendo 64 and the Mega Drive wear on their buttons,
//  extended on 2026-10-09 to every console's face buttons, MENU, CLIP, its
//  SELECT and START where the pill is the button, and the PlayStation's
//  cross keys; never L and R. The relief is a layer each control owns, so
//  these read the layer's visibility off real, dressed controls.
//

import Testing
import UIKit
@testable import EmulateurGBA

@MainActor
struct ButtonReliefTests {

    /// The control's own relief layer, found by its class.
    private func relief(in view: UIView) -> ReliefLayer? {
        view.layer.sublayers?.compactMap { $0 as? ReliefLayer }.first
    }

    private func dressedControls(_ system: PresetSystem, isLandscape: Bool = false)
        -> [(ControlElement, UIView)] {
        let controls = TouchControlsView.make(for: system)
        controls.frame = CGRect(x: 0, y: 0, width: 393, height: 480)
        controls.setDressed(true, isLandscape: isLandscape, system: system)
        let views = controls.allButtonViews()
        for (_, v) in views {
            v.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
            v.layoutIfNeeded()
        }
        return views
    }

    /// Every console's face buttons, MENU and CLIP wear the rim, dressed.
    @Test(arguments: PresetSystem.allCases)
    func facesMenuAndClipWearTheRim(_ system: PresetSystem) {
        for (element, view) in dressedControls(system) {
            switch element {
            case .btnA, .btnB, .btnX, .btnY, .btnMenu, .btnClip,
                 .btnCUp, .btnCDown, .btnCLeft, .btnCRight:
                #expect(relief(in: view)?.isHidden == false,
                        "\(system) \(element.rawValue) has no rim relief")
            default:
                break
            }
        }
    }

    /// Never on L and R, which were not asked (the Mega Drive's X and Z are
    /// round faces laid out as L and R, so they are faces there).
    @Test(arguments: PresetSystem.allCases.filter { $0 != .md })
    func shouldersHaveNoRim(_ system: PresetSystem) {
        for (element, view) in dressedControls(system) where element == .btnL || element == .btnR {
            #expect(relief(in: view).map { $0.isHidden } ?? true,
                    "\(system) \(element.rawValue) wears the rim relief")
        }
    }

    /// SELECT and START wear it where the pill is the button (GB/GBC, NES,
    /// SNES) and on the PlayStation; not the GBA's and the DS's tiny circle
    /// beside a printed pill. Both orientations.
    @Test func selectAndStartWearItWhereAsked() {
        for isLandscape in [false, true] {
            for system in [PresetSystem.gbc, .nes, .snes, .ps1] {
                for (element, view) in dressedControls(system, isLandscape: isLandscape)
                where element == .btnSelect || element == .btnStart {
                    #expect(relief(in: view)?.isHidden == false,
                            "\(system) \(element.rawValue) has no rim relief")
                }
            }
            for system in [PresetSystem.gba, .nds] {
                for (element, view) in dressedControls(system, isLandscape: isLandscape)
                where element == .btnSelect || element == .btnStart {
                    #expect(relief(in: view).map { $0.isHidden } ?? true,
                            "\(system) \(element.rawValue): the tiny circle wears the rim relief")
                }
            }
        }
    }

    /// Undressed (Invisible, or a preset), no control wears it.
    @Test(arguments: PresetSystem.allCases)
    func undressedControlsHaveNoRim(_ system: PresetSystem) {
        let controls = TouchControlsView.make(for: system)
        controls.setDressed(false, isLandscape: false, system: system)
        for (element, view) in controls.allButtonViews() {
            #expect(relief(in: view).map { $0.isHidden } ?? true,
                    "\(system) \(element.rawValue) wears the rim relief undressed")
        }
    }

    /// PS1 Retro Pal: the four faces under their inks are darker than every
    /// other control (asked 2026-10-09, the symbols were too light on
    /// #727272), so each ink reads at 4:1 or better, as on Nostalgia.
    @Test func ps1RetroPalSymbolsReadOnTheirFaces() {
        func luminance(_ c: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        func contrast(_ x: UIColor, _ y: UIColor) -> CGFloat {
            let (l1, l2) = (luminance(x), luminance(y))
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }
        let face = RetroPalPalette.ps1Faces
        for ink in [DressKind.ps1Circle, DressKind.ps1Cross, DressKind.ps1Triangle, DressKind.ps1Square] {
            #expect(contrast(ink, face) >= 4, "a PS1 symbol reads at \(contrast(ink, face)):1 on Retro Pal")
        }
        // And the dressed faces really wear it, Nostalgia unchanged.
        let controls = TouchControlsView.make(for: .ps1)
        controls.setDressed(true, isLandscape: false, system: .ps1, variant: .retroPal)
        for (element, view) in controls.allButtonViews()
        where [ControlElement.btnA, .btnB, .btnX, .btnY].contains(element) {
            #expect((view as? ActionButton)?.dressFace == face, "\(element.rawValue) is not the darker face")
        }
        controls.setDressed(true, isLandscape: false, system: .ps1, variant: .nostalgia)
        for (element, view) in controls.allButtonViews() where element == .btnA {
            #expect((view as? ActionButton)?.dressFace == DressKind.ps1Face)
        }
    }
}
