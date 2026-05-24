//
//  ControlLayoutEditorViewController.swift
//  EmulateurGBA
//
//  Full-screen drag-and-drop editor for custom control layouts.
//  Shows a static preview of button positions that the user can reposition.
//

import UIKit

protocol ControlLayoutEditorDelegate: AnyObject {
    func editorDidSave(preset: ControlPreset)
    func editorDidCancel()
}

final class ControlLayoutEditorViewController: UIViewController {
    weak var delegate: ControlLayoutEditorDelegate?

    private let isNDS: Bool
    private var preset: ControlPreset

    // Preview elements
    private let screenPlaceholder = UIView()
    private let screenPlaceholder2 = UIView()
    private var buttonViews: [(ControlElement, UIView)] = []

    // Floating menu (replaces fixed toolbar)
    private let menuButton = UIButton(type: .system)
    private let orientationLabel = UILabel()

    // Sliders panel (toggled from menu)
    private let slidersPanel = UIView()
    private let opacitySlider = UISlider()
    private let scaleSlider = UISlider()
    private let opacityValueLabel = UILabel()
    private let scaleValueLabel = UILabel()
    private var slidersPanelVisible = false

    // NDS screen size panel
    private let ndsPanel = UIView()
    private let ndsTopSizeControl = UISegmentedControl(items: ["S", "M", "L"])
    private let ndsBottomSizeControl = UISegmentedControl(items: ["S", "M", "L"])
    private var ndsPanelVisible = false

    // D-pad / Joystick toggle
    private var useJoystick: Bool

    // Drag state
    private var dragStartCenter: CGPoint = .zero
    private var currentlyDragging = false

    // Layout area = full visible area (no toolbar stealing space)
    private var layoutArea: CGRect = .zero

    init(isNDS: Bool, preset: ControlPreset) {
        self.isNDS = isNDS
        self.preset = preset
        self.useJoystick = UserDefaults.standard.bool(forKey: "useJoystick")
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        setupScreenPlaceholders()
        setupButtons()
        setupFloatingMenu()
        setupSlidersPanel()
        if isNDS { setupNDSPanel() }
        setupOrientationLabel()

        // Tap background to dismiss panels
        let bgTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        bgTap.cancelsTouchesInView = false
        view.addGestureRecognizer(bgTap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !currentlyDragging else { return }
        layoutPreview()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }

    private var isLandscape: Bool { view.bounds.width > view.bounds.height }

    private var currentLayout: OrientationLayout {
        get { isLandscape ? preset.landscape : preset.portrait }
        set {
            if isLandscape { preset.landscape = newValue }
            else { preset.portrait = newValue }
        }
    }

    // MARK: - Setup

    private func setupScreenPlaceholders() {
        for placeholder in [screenPlaceholder, screenPlaceholder2] {
            placeholder.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
            placeholder.layer.cornerRadius = 8
            placeholder.layer.borderWidth = 1
            placeholder.layer.borderColor = UIColor(white: 0.3, alpha: 1.0).cgColor
            view.addSubview(placeholder)
        }

        let gameLabel = UILabel()
        gameLabel.text = NSLocalizedString("layout.editor.screenPreview", comment: "")
        gameLabel.textColor = UIColor(white: 0.4, alpha: 1.0)
        gameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        gameLabel.textAlignment = .center
        gameLabel.translatesAutoresizingMaskIntoConstraints = false
        screenPlaceholder.addSubview(gameLabel)
        NSLayoutConstraint.activate([
            gameLabel.centerXAnchor.constraint(equalTo: screenPlaceholder.centerXAnchor),
            gameLabel.centerYAnchor.constraint(equalTo: screenPlaceholder.centerYAnchor),
        ])

        if isNDS {
            let label2 = UILabel()
            label2.text = NSLocalizedString("layout.editor.touchScreen", comment: "")
            label2.textColor = UIColor(white: 0.4, alpha: 1.0)
            label2.font = .systemFont(ofSize: 14, weight: .medium)
            label2.textAlignment = .center
            label2.translatesAutoresizingMaskIntoConstraints = false
            screenPlaceholder2.addSubview(label2)
            NSLayoutConstraint.activate([
                label2.centerXAnchor.constraint(equalTo: screenPlaceholder2.centerXAnchor),
                label2.centerYAnchor.constraint(equalTo: screenPlaceholder2.centerYAnchor),
            ])
        }
        screenPlaceholder2.isHidden = !isNDS
    }

    private func setupButtons() {
        let elements = isNDS ? ControlElement.ndsElements : ControlElement.gbaElements

        for element in elements {
            let btn: UIView
            switch element {
            case .dpad: btn = useJoystick ? DPadView() : CrossDPadView()
            case .btnA, .btnB, .btnX, .btnY: btn = ActionButton(label: element.displayName)
            case .btnL, .btnR: btn = ShoulderButton(label: element.displayName)
            case .btnStart, .btnSelect, .btnMenu, .btnMic:
                btn = SmallButton(label: element == .btnMenu ? "⋯" : element.displayName.uppercased())
            }

            btn.isUserInteractionEnabled = true
            view.addSubview(btn)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            btn.addGestureRecognizer(pan)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.require(toFail: pan)
            btn.addGestureRecognizer(tap)

            buttonViews.append((element, btn))
        }
    }

    private func swapDPadView() {
        // Find and remove the old D-pad
        guard let idx = buttonViews.firstIndex(where: { $0.0 == .dpad }) else { return }
        let (_, oldBtn) = buttonViews[idx]
        oldBtn.removeFromSuperview()

        // Create the new one
        let newBtn: UIView = useJoystick ? DPadView() : CrossDPadView()
        newBtn.isUserInteractionEnabled = true
        view.insertSubview(newBtn, belowSubview: menuButton)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        newBtn.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: pan)
        newBtn.addGestureRecognizer(tap)

        buttonViews[idx] = (.dpad, newBtn)
        positionButtonsFromLayout()
    }

    private func setupFloatingMenu() {
        menuButton.setImage(UIImage(systemName: "ellipsis.circle.fill"), for: .normal)
        menuButton.tintColor = .white
        menuButton.backgroundColor = UIColor(white: 0.15, alpha: 0.9)
        menuButton.layer.cornerRadius = 22
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuButton)

        NSLayoutConstraint.activate([
            menuButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            menuButton.widthAnchor.constraint(equalToConstant: 44),
            menuButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = buildMenu()
    }

    private func buildMenu() -> UIMenu {
        let done = UIAction(title: NSLocalizedString("layout.editor.done", comment: ""),
                            image: UIImage(systemName: "checkmark")) { [weak self] _ in
            self?.doneTapped()
        }

        let reset = UIAction(title: NSLocalizedString("layout.editor.reset", comment: ""),
                             image: UIImage(systemName: "arrow.counterclockwise"),
                             attributes: .destructive) { [weak self] _ in
            self?.resetTapped()
        }

        let buttons = UIAction(title: NSLocalizedString("layout.editor.buttons", comment: ""),
                               image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
            self?.toggleSlidersPanel()
        }

        // D-pad / Joystick toggle
        let dpadTitle = useJoystick
            ? NSLocalizedString("settings.dpad", comment: "")
            : NSLocalizedString("settings.joystick", comment: "")
        let dpadIcon = useJoystick ? "dpad" : "circle.circle"
        let dpadToggle = UIAction(title: dpadTitle,
                                  image: UIImage(systemName: dpadIcon)) { [weak self] _ in
            self?.toggleDPadJoystick()
        }

        var actions: [UIAction] = [done, buttons, dpadToggle]

        if isNDS {
            let screenSize = UIAction(title: NSLocalizedString("layout.editor.screenSize", comment: ""),
                                      image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                self?.toggleNDSPanel()
            }
            actions.append(screenSize)
        }

        actions.append(reset)

        let cancel = UIAction(title: NSLocalizedString("common.cancel", comment: ""),
                              image: UIImage(systemName: "xmark")) { [weak self] _ in
            self?.cancelTapped()
        }
        actions.append(cancel)

        return UIMenu(children: actions)
    }

    private func setupSlidersPanel() {
        slidersPanel.backgroundColor = UIColor(white: 0.12, alpha: 0.95)
        slidersPanel.layer.cornerRadius = 12
        slidersPanel.translatesAutoresizingMaskIntoConstraints = false
        slidersPanel.isHidden = true
        view.addSubview(slidersPanel)

        opacitySlider.minimumValue = 0.05
        opacitySlider.maximumValue = 0.6
        opacitySlider.value = Float(preset.opacity)
        opacitySlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        scaleSlider.minimumValue = 0.7
        scaleSlider.maximumValue = 1.3
        scaleSlider.value = Float(preset.scale)
        scaleSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        let opacityLabel = UILabel()
        opacityLabel.text = NSLocalizedString("settings.opacity", comment: "")
        opacityLabel.textColor = .white
        opacityLabel.font = .systemFont(ofSize: 13, weight: .medium)

        opacityValueLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        opacityValueLabel.font = .systemFont(ofSize: 13)
        opacityValueLabel.textAlignment = .right

        let scaleLabel = UILabel()
        scaleLabel.text = NSLocalizedString("settings.size", comment: "")
        scaleLabel.textColor = .white
        scaleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        scaleValueLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        scaleValueLabel.font = .systemFont(ofSize: 13)
        scaleValueLabel.textAlignment = .right

        let opacityHeader = UIStackView(arrangedSubviews: [opacityLabel, opacityValueLabel])
        opacityHeader.axis = .horizontal
        let scaleHeader = UIStackView(arrangedSubviews: [scaleLabel, scaleValueLabel])
        scaleHeader.axis = .horizontal

        let stack = UIStackView(arrangedSubviews: [opacityHeader, opacitySlider, scaleHeader, scaleSlider])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        slidersPanel.addSubview(stack)

        NSLayoutConstraint.activate([
            slidersPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            slidersPanel.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 8),
            slidersPanel.widthAnchor.constraint(equalToConstant: 260),

            stack.topAnchor.constraint(equalTo: slidersPanel.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: slidersPanel.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: slidersPanel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: slidersPanel.trailingAnchor, constant: -16),
        ])

        updateSliderLabels()
    }

    private func setupNDSPanel() {
        ndsPanel.backgroundColor = UIColor(white: 0.12, alpha: 0.95)
        ndsPanel.layer.cornerRadius = 12
        ndsPanel.translatesAutoresizingMaskIntoConstraints = false
        ndsPanel.isHidden = true
        view.addSubview(ndsPanel)

        let topLabel = UILabel()
        topLabel.text = NSLocalizedString("layout.editor.topScreen", comment: "")
        topLabel.textColor = .white
        topLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let bottomLabel = UILabel()
        bottomLabel.text = NSLocalizedString("layout.editor.bottomScreen", comment: "")
        bottomLabel.textColor = .white
        bottomLabel.font = .systemFont(ofSize: 13, weight: .medium)

        ndsTopSizeControl.selectedSegmentIndex = sizeToIndex(currentLayout.ndsTopScreenSize)
        ndsBottomSizeControl.selectedSegmentIndex = sizeToIndex(currentLayout.ndsBottomScreenSize)
        ndsTopSizeControl.addTarget(self, action: #selector(ndsScreenSizeChanged), for: .valueChanged)
        ndsBottomSizeControl.addTarget(self, action: #selector(ndsScreenSizeChanged), for: .valueChanged)

        let topRow = UIStackView(arrangedSubviews: [topLabel, ndsTopSizeControl])
        topRow.axis = .horizontal
        topRow.spacing = 8
        let bottomRow = UIStackView(arrangedSubviews: [bottomLabel, ndsBottomSizeControl])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [topRow, bottomRow])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        ndsPanel.addSubview(stack)

        NSLayoutConstraint.activate([
            ndsPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            ndsPanel.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 8),
            ndsPanel.widthAnchor.constraint(equalToConstant: 280),

            stack.topAnchor.constraint(equalTo: ndsPanel.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: ndsPanel.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: ndsPanel.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: ndsPanel.trailingAnchor, constant: -14),
        ])
    }

    private func setupOrientationLabel() {
        orientationLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        orientationLabel.font = .systemFont(ofSize: 12, weight: .medium)
        orientationLabel.textAlignment = .left
        orientationLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(orientationLabel)

        NSLayoutConstraint.activate([
            orientationLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            orientationLabel.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
        ])
    }

    // MARK: - Layout Preview

    private func layoutPreview() {
        let safeInsets = view.safeAreaInsets
        let availW = view.bounds.width
        let availH = view.bounds.height

        orientationLabel.text = isLandscape
            ? NSLocalizedString("layout.editor.landscapeShort", comment: "")
            : NSLocalizedString("layout.editor.portraitShort", comment: "")

        if isNDS {
            ndsTopSizeControl.selectedSegmentIndex = sizeToIndex(currentLayout.ndsTopScreenSize)
            ndsBottomSizeControl.selectedSegmentIndex = sizeToIndex(currentLayout.ndsBottomScreenSize)
        }

        if isNDS {
            layoutNDSScreens(availW: availW, availH: availH, safeInsets: safeInsets)
        } else {
            layoutGBAScreen(availW: availW, availH: availH, safeInsets: safeInsets)
        }

        positionButtonsFromLayout()
    }

    // Layout methods mirror EmulatorViewController.layoutGameView() and
    // applyControlConstraints() exactly so the preview matches the real game.

    private func layoutGBAScreen(availW: CGFloat, availH: CGFloat, safeInsets: UIEdgeInsets) {
        screenPlaceholder2.isHidden = true
        let gameAspect: CGFloat = 240.0 / 160.0  // GBA = 240x160

        if isLandscape {
            // Mirrors: EmulatorViewController GBA landscape
            // Game centered with 160pt control panels on each side
            let panelWidth: CGFloat = 160
            let centerW = availW - panelWidth * 2
            let centerH = availH

            var fitW = centerW
            var fitH = fitW / gameAspect
            if fitH > centerH { fitH = centerH; fitW = fitH * gameAspect }

            let x = panelWidth + (centerW - fitW) / 2
            let y = (centerH - fitH) / 2
            screenPlaceholder.frame = CGRect(x: x, y: y, width: fitW, height: fitH)
            // Controls overlay the full screen in GBA landscape
            layoutArea = CGRect(x: 0, y: 0, width: availW, height: availH)
        } else {
            // Mirrors: EmulatorViewController GBA portrait
            // maxH = viewSize.height * 0.45, y = safeInsets.top + 42
            let maxH = availH * 0.45
            var fitW = availW
            var fitH = fitW / gameAspect
            if fitH > maxH { fitH = maxH; fitW = fitH * gameAspect }

            let x = (availW - fitW) / 2
            let y = safeInsets.top + 42
            screenPlaceholder.frame = CGRect(x: x, y: y, width: fitW, height: fitH)
            // Controls: metalView.frame.maxY to view.bottomAnchor
            let controlsTop = screenPlaceholder.frame.maxY
            layoutArea = CGRect(x: 0, y: controlsTop, width: availW, height: availH - controlsTop)
        }
    }

    private func layoutNDSScreens(availW: CGFloat, availH: CGFloat, safeInsets: UIEdgeInsets) {
        screenPlaceholder2.isHidden = false
        // NDS combined texture = 256x384 (256 wide, 192+192 tall)
        let gameAspect: CGFloat = 256.0 / 384.0
        let screenAspect: CGFloat = 256.0 / 192.0

        if isLandscape {
            // Mirrors: EmulatorViewController NDS landscape
            // screenAreaH = viewSize.height * 0.60, full width
            let screenAreaH = availH * 0.60
            // The Metal view fills (0, 0, availW, screenAreaH) and renders side-by-side
            // We show two placeholders side by side
            let halfW = availW / 2
            var screenW = halfW
            var screenH = screenW / screenAspect
            if screenH > screenAreaH { screenH = screenAreaH; screenW = screenH * screenAspect }

            screenPlaceholder.frame = CGRect(x: halfW - screenW, y: 0, width: screenW, height: screenH)
            screenPlaceholder2.frame = CGRect(x: halfW, y: 0, width: screenW, height: screenH)

            // Controls: metalView.frame.maxY to view.bottomAnchor
            let controlsTop = screenAreaH
            layoutArea = CGRect(x: 0, y: controlsTop, width: availW, height: availH - controlsTop)
        } else {
            // Mirrors: EmulatorViewController NDS portrait
            // maxH = viewSize.height - safeInsets.top - safeInsets.bottom - 280
            // y = safeInsets.top
            let minControlsH: CGFloat = 280
            let maxH = availH - safeInsets.top - safeInsets.bottom - minControlsH

            var fitW = availW
            var fitH = fitW / gameAspect
            if fitH > maxH { fitH = maxH; fitW = fitH * gameAspect }

            let x = (availW - fitW) / 2
            let y = safeInsets.top
            // The Metal view is one rect; inside it the shader splits top/bottom
            // We split into two placeholders to show the sizing
            let topScale = currentLayout.ndsTopScreenSize.scaleFactor
            let bottomScale = currentLayout.ndsBottomScreenSize.scaleFactor
            let gapRatio: CGFloat = 0.01
            let topRatio = CGFloat(topScale) / CGFloat(topScale + bottomScale) * (1.0 - gapRatio)
            let botRatio = 1.0 - topRatio - gapRatio

            let topH = fitH * topRatio
            let gapH = fitH * gapRatio
            let botH = fitH * botRatio

            // Each screen's actual rendered width (maintain 4:3)
            var topW = fitW
            var adjTopH = topW / screenAspect
            if adjTopH > topH { adjTopH = topH; topW = adjTopH * screenAspect }

            var botW = fitW
            var adjBotH = botW / screenAspect
            if adjBotH > botH { adjBotH = botH; botW = adjBotH * screenAspect }

            screenPlaceholder.frame = CGRect(x: (availW - topW) / 2, y: y, width: topW, height: adjTopH)
            screenPlaceholder2.frame = CGRect(
                x: (availW - botW) / 2, y: y + topH + gapH, width: botW, height: adjBotH)

            // Controls: metalView.frame.maxY to view.bottomAnchor
            let metalBottom = y + fitH
            layoutArea = CGRect(x: 0, y: metalBottom, width: availW, height: availH - metalBottom)
        }
    }

    private func positionButtonsFromLayout() {
        let layout = currentLayout
        let containerSize = layoutArea.size
        guard containerSize.width > 0 && containerSize.height > 0 else { return }

        if layout.buttons.isEmpty {
            let defaults = ControlLayoutDefaults.defaultLayout(
                forNDS: isNDS, isLandscape: isLandscape, containerSize: containerSize)
            currentLayout = OrientationLayout(
                buttons: defaults.buttons,
                ndsTopScreenSize: layout.ndsTopScreenSize,
                ndsBottomScreenSize: layout.ndsBottomScreenSize)
        }

        let current = currentLayout
        let effectiveOpacity = CGFloat(opacitySlider.value) * 2.0
        let effectiveScale = CGFloat(scaleSlider.value)

        for (element, btn) in buttonViews {
            guard let bl = current.buttons[element.rawValue] else {
                btn.isHidden = true
                continue
            }

            let size: CGSize
            if isNDS {
                size = isLandscape ? element.defaultNDSLandscapeSize : element.defaultNDSPortraitSize
            } else {
                size = isLandscape ? element.defaultLandscapeSize : element.defaultSize
            }

            let scaledW = size.width * effectiveScale
            let scaledH = size.height * effectiveScale
            let cx = layoutArea.origin.x + containerSize.width * bl.centerX
            let cy = layoutArea.origin.y + containerSize.height * bl.centerY
            btn.frame = CGRect(x: cx - scaledW / 2, y: cy - scaledH / 2, width: scaledW, height: scaledH)
            btn.transform = .identity

            let isHidden = (element != .btnMenu) && bl.isHidden
            btn.isHidden = false

            if isHidden {
                btn.alpha = 0.15
                updateDashedBorder(on: btn, show: true)
            } else {
                // In the editor, all buttons (including menu) use the same opacity
                btn.alpha = effectiveOpacity
                updateDashedBorder(on: btn, show: false)
            }
        }
    }

    private func updateDashedBorder(on view: UIView, show: Bool) {
        view.layer.sublayers?.removeAll { $0.name == "dashedBorder" }
        if show {
            let dashed = CAShapeLayer()
            dashed.name = "dashedBorder"
            dashed.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
            dashed.fillColor = nil
            dashed.lineDashPattern = [4, 4]
            dashed.lineWidth = 1
            dashed.frame = view.bounds
            dashed.path = UIBezierPath(roundedRect: view.bounds, cornerRadius: view.layer.cornerRadius).cgPath
            view.layer.addSublayer(dashed)
        }
    }

    // MARK: - Drag Handling

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let btn = gesture.view,
              let (element, _) = buttonViews.first(where: { $0.1 === btn })
        else { return }

        switch gesture.state {
        case .began:
            currentlyDragging = true
            dragStartCenter = btn.center
            UIView.animate(withDuration: 0.15) {
                btn.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                btn.layer.shadowColor = UIColor.systemBlue.cgColor
                btn.layer.shadowRadius = 8
                btn.layer.shadowOpacity = 0.5
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

        case .changed:
            let translation = gesture.translation(in: view)
            var newCenter = CGPoint(x: dragStartCenter.x + translation.x, y: dragStartCenter.y + translation.y)
            let m: CGFloat = 10
            let safeTop = view.safeAreaInsets.top
            newCenter.x = max(m, min(view.bounds.width - m, newCenter.x))
            // Allow dragging above the layout area (for NDS L/R that overlap screens)
            newCenter.y = max(safeTop, min(view.bounds.height - m, newCenter.y))
            btn.center = newCenter

        case .ended, .cancelled:
            currentlyDragging = false
            UIView.animate(withDuration: 0.15) {
                btn.transform = .identity
                btn.layer.shadowOpacity = 0
            }
            // Normalize relative to layout area (can be negative for buttons above it)
            let nx = (btn.center.x - layoutArea.origin.x) / layoutArea.width
            let ny = (btn.center.y - layoutArea.origin.y) / layoutArea.height
            var layout = currentLayout
            if var bl = layout.buttons[element.rawValue] {
                bl.centerX = max(0.02, min(0.98, nx))
                bl.centerY = min(0.98, ny)  // allow negative for buttons above controls area
                layout.buttons[element.rawValue] = bl
            }
            currentLayout = layout
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

        default: break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let btn = gesture.view,
              let (element, _) = buttonViews.first(where: { $0.1 === btn })
        else { return }
        showVisibilitySheet(for: element)
    }

    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        // Dismiss panels if tap is outside them
        if slidersPanelVisible && !slidersPanel.frame.contains(point) {
            slidersPanelVisible = false
            slidersPanel.isHidden = true
        }
        if ndsPanelVisible && !ndsPanel.frame.contains(point) {
            ndsPanelVisible = false
            ndsPanel.isHidden = true
        }
    }

    // MARK: - Actions

    private func doneTapped() {
        preset.opacity = CGFloat(opacitySlider.value)
        preset.scale = CGFloat(scaleSlider.value)
        delegate?.editorDidSave(preset: preset)
    }

    private func cancelTapped() {
        delegate?.editorDidCancel()
    }

    private func resetTapped() {
        let alert = UIAlertController(
            title: NSLocalizedString("layout.editor.reset.title", comment: ""),
            message: NSLocalizedString("layout.editor.reset.message", comment: ""),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("common.cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("layout.editor.reset", comment: ""), style: .destructive) { [weak self] _ in
            guard let self else { return }
            let defaults = ControlLayoutDefaults.defaultLayout(
                forNDS: self.isNDS, isLandscape: self.isLandscape, containerSize: self.layoutArea.size)
            self.currentLayout = defaults
            self.opacitySlider.value = 0.25
            self.scaleSlider.value = 1.0
            self.updateSliderLabels()
            self.positionButtonsFromLayout()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        })
        present(alert, animated: true)
    }

    private func toggleDPadJoystick() {
        useJoystick.toggle()
        UserDefaults.standard.set(useJoystick, forKey: "useJoystick")
        swapDPadView()
        // Rebuild the menu so the label/icon updates
        menuButton.menu = buildMenu()
    }

    private func toggleSlidersPanel() {
        if ndsPanelVisible { ndsPanelVisible = false; ndsPanel.isHidden = true }
        slidersPanelVisible.toggle()
        slidersPanel.isHidden = !slidersPanelVisible
    }

    private func toggleNDSPanel() {
        if isLandscape {
            // Screen sizing only applies to portrait (stacked) mode
            let alert = UIAlertController(
                title: NSLocalizedString("layout.editor.screenSize", comment: ""),
                message: NSLocalizedString("layout.editor.screenSizeLandscapeInfo", comment: ""),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("common.ok", comment: ""), style: .default))
            present(alert, animated: true)
            return
        }
        if slidersPanelVisible { slidersPanelVisible = false; slidersPanel.isHidden = true }
        ndsPanelVisible.toggle()
        ndsPanel.isHidden = !ndsPanelVisible
    }

    @objc private func sliderChanged() {
        preset.opacity = CGFloat(opacitySlider.value)
        preset.scale = CGFloat(scaleSlider.value)
        updateSliderLabels()
        positionButtonsFromLayout()
    }

    private func updateSliderLabels() {
        opacityValueLabel.text = "\(Int(opacitySlider.value * 100))%"
        scaleValueLabel.text = "\(Int(scaleSlider.value * 100))%"
    }

    @objc private func ndsScreenSizeChanged() {
        var layout = currentLayout
        layout.ndsTopScreenSize = indexToSize(ndsTopSizeControl.selectedSegmentIndex)
        layout.ndsBottomScreenSize = indexToSize(ndsBottomSizeControl.selectedSegmentIndex)
        currentLayout = layout
        layoutPreview()
    }

    // MARK: - Visibility Sheet

    private func showVisibilitySheet(for element: ControlElement) {
        let alert = UIAlertController(title: element.displayName, message: nil, preferredStyle: .actionSheet)
        let layout = currentLayout
        let isHidden = layout.buttons[element.rawValue]?.isHidden ?? false

        if element == .btnMenu {
            alert.message = NSLocalizedString("layout.editor.menuCannotHide", comment: "")
        } else {
            let title = isHidden
                ? NSLocalizedString("layout.editor.show", comment: "")
                : NSLocalizedString("layout.editor.hide", comment: "")
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                var l = self.currentLayout
                if var bl = l.buttons[element.rawValue] {
                    bl.isHidden = !bl.isHidden
                    l.buttons[element.rawValue] = bl
                    self.currentLayout = l
                    self.positionButtonsFromLayout()
                }
            })
        }
        alert.addAction(UIAlertAction(title: NSLocalizedString("common.cancel", comment: ""), style: .cancel))
        if let popover = alert.popoverPresentationController,
           let btn = buttonViews.first(where: { $0.0 == element })?.1 {
            popover.sourceView = btn; popover.sourceRect = btn.bounds
        }
        present(alert, animated: true)
    }

    // MARK: - Helpers

    private func sizeToIndex(_ size: NDSScreenSize) -> Int {
        switch size { case .small: return 0; case .medium: return 1; case .large: return 2 }
    }

    private func indexToSize(_ index: Int) -> NDSScreenSize {
        switch index { case 0: return .small; case 2: return .large; default: return .medium }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Close any open panels
        slidersPanelVisible = false; slidersPanel.isHidden = true
        ndsPanelVisible = false; ndsPanel.isHidden = true
        coordinator.animate(alongsideTransition: { _ in self.layoutPreview() })
    }
}
