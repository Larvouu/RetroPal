//
//  NDSTouchControlsView.swift
//  EmulateurGBA
//
//  NDS-specific touch controls: ABXY diamond layout matching real NDS ergonomics.
//  Portrait: compact diamond + D-pad below game screens.
//  Landscape: D-pad bottom-left, ABXY bottom-right, screens fill upper area.
//
//  Reference: Manic EMU button layout (portrait1.jpg, landscape2.jpg)
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

        addNDSButtonMappings([
            (btnX, GBAInput.x.rawValue),
            (btnY, GBAInput.y.rawValue),
        ])

        // Register mic button for blow detection (not a key bitmask)
        micButton = btnMic
    }

    // MARK: - Custom Layout Support

    override func allButtonViews() -> [(ControlElement, UIView)] {
        var views = super.allButtonViews()
        views.append(contentsOf: [(.btnX, btnX), (.btnY, btnY), (.btnMic, btnMic)])
        return views
    }

    // MARK: - Portrait Layout
    // Compact ABXY diamond + D-pad, matching Manic EMU proportions.
    // Diamond: X=top, Y=left, A=right, B=bottom (NDS standard).
    // D-pad and diamond are vertically centered in the controls area.

    override func applyPortraitLayout() {
        NSLayoutConstraint.deactivate(constraints.filter { $0.firstItem is UIView })
        removeAllSubviewConstraints()
        clipsToBounds = true  // Reset from landscape's false

        // Button sizes — slightly larger and more spread out
        let btnSize: CGFloat = 63.8     // Face buttons
        let dpadSize: CGFloat = 159.5   // D-pad — large cross
        let shoulderW: CGFloat = 70
        let shoulderH: CGFloat = 36
        let smallW: CGFloat = 52
        let smallH: CGFloat = 36
        let menuSize: CGFloat = 36

        // Diamond radius: distance from diamond center to each button center.
        let diamondR: CGFloat = 50

        // Diamond center position: right side, vertically centered with slight upward shift
        // Reference: diamond center is roughly at trailing -80, centerY -10
        NSLayoutConstraint.activate([
            // D-pad: left side, vertically centered
            dpad.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dpad.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            dpad.widthAnchor.constraint(equalToConstant: dpadSize),
            dpad.heightAnchor.constraint(equalToConstant: dpadSize),

            // A = right of diamond
            btnA.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            btnA.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            btnA.widthAnchor.constraint(equalToConstant: btnSize),
            btnA.heightAnchor.constraint(equalToConstant: btnSize),

            // X = top of diamond (directly above B, left of A)
            btnX.centerXAnchor.constraint(equalTo: btnA.centerXAnchor, constant: -diamondR),
            btnX.centerYAnchor.constraint(equalTo: btnA.centerYAnchor, constant: -diamondR),
            btnX.widthAnchor.constraint(equalToConstant: btnSize),
            btnX.heightAnchor.constraint(equalToConstant: btnSize),

            // Y = left of diamond (same height as A)
            btnY.centerXAnchor.constraint(equalTo: btnA.centerXAnchor, constant: -diamondR * 2),
            btnY.centerYAnchor.constraint(equalTo: btnA.centerYAnchor),
            btnY.widthAnchor.constraint(equalToConstant: btnSize),
            btnY.heightAnchor.constraint(equalToConstant: btnSize),

            // B = bottom of diamond (directly below X, left of A)
            btnB.centerXAnchor.constraint(equalTo: btnA.centerXAnchor, constant: -diamondR),
            btnB.centerYAnchor.constraint(equalTo: btnA.centerYAnchor, constant: diamondR),
            btnB.widthAnchor.constraint(equalToConstant: btnSize),
            btnB.heightAnchor.constraint(equalToConstant: btnSize),

            // L: top-left
            btnL.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            btnL.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            btnL.widthAnchor.constraint(equalToConstant: shoulderW),
            btnL.heightAnchor.constraint(equalToConstant: shoulderH),

            // R: top-right
            btnR.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            btnR.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            btnR.widthAnchor.constraint(equalToConstant: shoulderW),
            btnR.heightAnchor.constraint(equalToConstant: shoulderH),

            // Select + Start: centered at bottom
            btnSelect.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -32),
            btnSelect.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            btnSelect.widthAnchor.constraint(equalToConstant: smallW),
            btnSelect.heightAnchor.constraint(equalToConstant: smallH),

            btnStart.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 32),
            btnStart.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            btnStart.widthAnchor.constraint(equalToConstant: smallW),
            btnStart.heightAnchor.constraint(equalToConstant: smallH),

            // Menu: top-center between L and R
            btnMenu.centerXAnchor.constraint(equalTo: centerXAnchor),
            btnMenu.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            btnMenu.widthAnchor.constraint(equalToConstant: menuSize),
            btnMenu.heightAnchor.constraint(equalToConstant: menuSize),

            // MIC: to the right of Start
            btnMic.leadingAnchor.constraint(equalTo: btnStart.trailingAnchor, constant: 12),
            btnMic.centerYAnchor.constraint(equalTo: btnStart.centerYAnchor),
            btnMic.widthAnchor.constraint(equalToConstant: smallW),
            btnMic.heightAnchor.constraint(equalToConstant: smallH),
        ])
        applyAllSettings()
    }

    // MARK: - Landscape Layout
    // Screens above in metalView. Controls area below.
    // ABXY layout from landscape_goal.jpg — two offset columns:
    //       X     A      (right column shifted up relative to left)
    //    Y     B
    // This matches real NDS/SNES hardware button placement.

    override func applyLandscapeLayout() {
        NSLayoutConstraint.deactivate(constraints.filter { $0.firstItem is UIView })
        removeAllSubviewConstraints()
        clipsToBounds = false  // Allow L/R to extend above into the screen area

        let btnSize: CGFloat = 63.8
        let dpadSize: CGFloat = 148.5
        let shoulderW: CGFloat = 40
        let shoulderH: CGFloat = 100
        let smallW: CGFloat = 52
        let smallH: CGFloat = 36
        let menuSize: CGFloat = 36

        // Two rows, two columns. Right column shifted up by half a button.
        //    Row 1:    X     A     (X and A on same line, A to the right)
        //    Row 2: Y     B       (Y and B on same line, shifted left + down)
        let hGap: CGFloat = 4       // horizontal gap between buttons in a row
        let vGap: CGFloat = 4       // vertical gap between rows
        let rowOffset: CGFloat = 26 // bottom row shifted LEFT by this amount

        NSLayoutConstraint.activate([
            // D-pad: left side, nudged right for easier left-thumb reach
            dpad.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 110),
            dpad.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4),
            dpad.widthAnchor.constraint(equalToConstant: dpadSize),
            dpad.heightAnchor.constraint(equalToConstant: dpadSize),

            // Row 1 (top): X then A
            btnA.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -140),
            btnA.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -(vGap / 2)),
            btnA.widthAnchor.constraint(equalToConstant: btnSize),
            btnA.heightAnchor.constraint(equalToConstant: btnSize),

            // X = left of A, same row — pushed further left
            btnX.trailingAnchor.constraint(equalTo: btnA.leadingAnchor, constant: -(hGap + 24)),
            btnX.centerYAnchor.constraint(equalTo: btnA.centerYAnchor),
            btnX.widthAnchor.constraint(equalToConstant: btnSize),
            btnX.heightAnchor.constraint(equalToConstant: btnSize),

            // Row 2 (bottom): Y then B, shifted left
            btnB.centerXAnchor.constraint(equalTo: btnA.centerXAnchor, constant: -rowOffset),
            btnB.topAnchor.constraint(equalTo: centerYAnchor, constant: vGap / 2),
            btnB.widthAnchor.constraint(equalToConstant: btnSize),
            btnB.heightAnchor.constraint(equalToConstant: btnSize),

            // Y = left of B, same row — pushed further left
            btnY.trailingAnchor.constraint(equalTo: btnB.leadingAnchor, constant: -(hGap + 24)),
            btnY.centerYAnchor.constraint(equalTo: btnB.centerYAnchor),
            btnY.widthAnchor.constraint(equalToConstant: btnSize),
            btnY.heightAnchor.constraint(equalToConstant: btnSize),

            // L: far left, vertically centered with screens above
            // Screens = 60% of total height, controls = 40%.
            // Screen center from controls top = -(screenH/2) = -(60%*totalH/2)
            // In controls-relative coords: topAnchor is the boundary.
            // Screen center is at topAnchor - (screen area height / 2)
            // L: glued to left edge of left screen, centered vertically with screens
            btnL.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 65),
            btnL.centerYAnchor.constraint(equalTo: topAnchor, constant: -50),
            btnL.widthAnchor.constraint(equalToConstant: shoulderW),
            btnL.heightAnchor.constraint(equalToConstant: shoulderH),

            // R: glued to right edge of right screen, centered vertically with screens
            btnR.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -65),
            btnR.centerYAnchor.constraint(equalTo: topAnchor, constant: -50),
            btnR.widthAnchor.constraint(equalToConstant: shoulderW),
            btnR.heightAnchor.constraint(equalToConstant: shoulderH),

            // Select + Start + Menu: higher to avoid iPhone home bar
            btnSelect.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -55),
            btnSelect.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            btnSelect.widthAnchor.constraint(equalToConstant: smallW),
            btnSelect.heightAnchor.constraint(equalToConstant: smallH),

            btnStart.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 55),
            btnStart.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            btnStart.widthAnchor.constraint(equalToConstant: smallW),
            btnStart.heightAnchor.constraint(equalToConstant: smallH),

            btnMenu.centerXAnchor.constraint(equalTo: centerXAnchor),
            btnMenu.centerYAnchor.constraint(equalTo: btnSelect.centerYAnchor),
            btnMenu.widthAnchor.constraint(equalToConstant: menuSize),
            btnMenu.heightAnchor.constraint(equalToConstant: menuSize),

            // MIC: above the menu button
            btnMic.centerXAnchor.constraint(equalTo: btnMenu.centerXAnchor),
            btnMic.bottomAnchor.constraint(equalTo: btnMenu.topAnchor, constant: -8),
            btnMic.widthAnchor.constraint(equalToConstant: smallW),
            btnMic.heightAnchor.constraint(equalToConstant: smallH),
        ])
        applyAllSettings()
    }

    // removeAllSubviewConstraints is inherited from TouchControlsView

    private func applyAllSettings() {
        let opacity = UserDefaults.standard.double(forKey: "controlOpacity")
        let scale = UserDefaults.standard.double(forKey: "controlScale")
        let effectiveOpacity = opacity > 0 ? opacity : 0.5
        let effectiveScale = scale > 0 ? scale : 1.0

        let scaleTransform = CGAffineTransform(scaleX: effectiveScale, y: effectiveScale)
        for v in [dpad, btnA, btnB, btnX, btnY, btnL, btnR, btnStart, btnSelect, btnMic] as [UIView] {
            v.alpha = CGFloat(effectiveOpacity) * 2.0
            v.transform = scaleTransform
            (v as? ActionButton)?.baseTransform = scaleTransform
        }
        btnMenu.alpha = max(0.5, CGFloat(effectiveOpacity) * 2.0)
    }
}
