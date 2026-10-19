//
//  SegaEightBitTouchControlsView.swift
//  EmulateurGBA
//
//  Master System and Game Gear touch controls: the cross, the pad's two
//  buttons printed 1 and 2, the console's own extra button (PAUSE on the
//  Master System, START on the Game Gear), with the app's MENU and CLIP.
//
//  NOTHING HERE IS A NEW VIEW. The base class's B and A are buttons 1 and 2,
//  in the places a NES pad's B and A take on the page each console is laid
//  out on (`layoutPage`), and they travel as the b and a bits, which
//  MesenBridge sends as 1 and 2. START travels as the start bit, which the
//  bridge sends as the console's Pause bit. SELECT, which neither console has,
//  is left out of the layout (`ControlLayoutDefaults.sega8Bit`), and the base
//  class hides any control a layout does not carry.
//

import UIKit

final class SegaEightBitTouchControlsView: TouchControlsView {
    /// The console, for the one label that differs between the two: the Master
    /// System's extra button is PAUSE, on the console itself; the Game Gear's
    /// is START.
    private let system: PresetSystem

    /// The pad prints numbers where most consoles print letters, so the
    /// hold-to-lock line in the pause menu names 1 and 2, in the order the pad
    /// reads (1 on the left).
    override var lockableLetters: [String] { ["1", "2"] }

    init(system: PresetSystem) {
        self.system = system
        super.init(frame: .zero)
        setupLabels()
    }

    required init?(coder: NSCoder) {
        self.system = .sms
        super.init(coder: coder)
        setupLabels()
    }

    /// Each console's own controls (2026-10-10): on both, 1 and 2 are plain,
    /// their numbers printed on the shell by the dress (above them on the
    /// Game Gear, in the red bar over each on the Master System). The Game
    /// Gear's START is the blue cut disc with its word beside it; the Master
    /// System's PAUSE is the console's black plate with its rocker.
    override func setDressed(_ on: Bool, isLandscape: Bool, system: PresetSystem,
                             variant: DressVariant = .nostalgia) {
        super.setDressed(on, isLandscape: isLandscape, system: system, variant: variant)
        btnStart.dressStyle = on ? (system == .gg ? .ggStart : .smsPause) : .none
    }

    private func setupLabels() {
        btnB.setTitle("1")
        btnA.setTitle("2")
        btnB.accessibilityLabel = "Button 1"
        btnA.accessibilityLabel = "Button 2"
        if system == .sms {
            btnStart.setTitle("PAUSE")
            btnStart.accessibilityLabel = "Pause button"
        }
    }
}
