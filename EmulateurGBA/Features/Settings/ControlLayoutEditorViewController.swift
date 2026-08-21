//
//  ControlLayoutEditorViewController.swift
//  EmulateurGBA
//
//  Full-screen drag-and-drop editor for custom control layouts. Every
//  component — the game screen(s) AND each control — can be moved, resized,
//  faded, or hidden independently, per orientation.
//
//  The editor renders exclusively from PresetLayoutResolver, the same source
//  the in-game renderer uses, so what you arrange here is pixel-identical in
//  the game. Components the user has not touched stay unstored and keep
//  resolving to the built-in default for the device; the first touch
//  materializes the component into the preset (full-view space).
//
//  Interaction model: drag any component to move it; tap to select it (a
//  floating panel offers Size / Opacity sliders + Hide for buttons); pinch to
//  resize the selection. Controls sit visually ABOVE the screens (like
//  in-game), and keep grab priority over them.
//

import UIKit

protocol ControlLayoutEditorDelegate: AnyObject {
    func editorDidSave(preset: ControlPreset)
    func editorDidCancel()
}

final class ControlLayoutEditorViewController: UIViewController, UIGestureRecognizerDelegate {
    weak var delegate: ControlLayoutEditorDelegate?

    private let system: PresetSystem
    /// Derived from `system`; NDS drives the dual-screen preview. GBA and
    /// GB/GBC are both non-NDS here.
    private let isNDS: Bool
    private var preset: ControlPreset

    /// One editable thing on the canvas.
    private enum Component: Equatable {
        case screen(ScreenComponent)
        case button(ControlElement)
    }

    // Component views
    private var screenViews: [(ScreenComponent, UIView)] = []
    private var buttonViews: [(ControlElement, UIView)] = []

    // Floating chrome
    private let menuButton = UIButton(type: .system)
    private let orientationLabel = UILabel()
    private let hintLabel = UILabel()

    // Selection + per-component panel
    private var selected: Component?
    private let panel = UIView()
    private let panelTitle = UILabel()
    private let hideButton = UIButton(type: .system)
    private let resetComponentButton = UIButton(type: .system)
    private let cannotHideLabel = UILabel()
    private let sizeSlider = UISlider()
    private let opacitySlider = UISlider()
    private let sizeValueLabel = UILabel()
    private let opacityValueLabel = UILabel()

    // The panel docks at the bottom, but hops to the top whenever it would
    // cover the selected component (re-evaluated as the component moves or
    // grows), so it never gets in the way of what's being edited.
    private var panelBottomConstraint: NSLayoutConstraint!
    private var panelTopConstraint: NSLayoutConstraint!
    private var panelAtTop = false
    /// Vertical offset of the top dock below the safe area: clears the 44pt
    /// floating menu button row.
    private static let panelTopOffset: CGFloat = 56

    // D-pad / Joystick (per-preset, applies to BOTH orientations)
    private var useJoystick: Bool

    // Gesture state
    private var draggingView: UIView?
    private var draggingComponent: Component?
    private var dragStartCenter: CGPoint = .zero
    private var currentlyDragging = false
    private var pinchStartScale: CGFloat = 1

    /// The resolved scene currently on the canvas (re-resolved after every edit).
    private var scene: PresetLayoutResolver.ResolvedScene?

    /// Controller mode edits the layout used while a physical controller is
    /// attached: only the screens and Menu exist, nothing can be hidden, and
    /// the preview must show the game as it renders WITH a controller (the
    /// other buttons gone, the screens filling the reclaimed space). The
    /// preset is a carrier for the two OrientationLayouts here; the caller
    /// converts back to a ControllerLayout on save.
    private let controllerMode: Bool

    init(system: PresetSystem, preset: ControlPreset, controllerMode: Bool = false) {
        self.system = system
        self.isNDS = (system == .nds)
        self.preset = preset
        self.useJoystick = preset.useJoystick
        self.controllerMode = controllerMode
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    /// The elements this editor exposes. Controller mode shows Menu alone: it
    /// is the only control that survives with a pad attached, and it is the
    /// only on-screen way back to the pause menu.
    private var editableElements: [ControlElement] {
        controllerMode ? [ControllerLayout.element] : ControlElement.elements(for: system)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        setupComponents()
        setupFloatingMenu()
        setupOrientationLabel()
        setupHintLabel()
        setupPanel()
        setupGestures()
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

    private func setupComponents() {
        // Screens first, buttons after: the controls render ABOVE the screens,
        // the same stacking the game uses (a button placed over a screen stays
        // visible and usable; Menu can never end up trapped under a screen).
        for component in ScreenComponent.components(for: system) {
            let placeholder = UIView()
            placeholder.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
            placeholder.layer.cornerRadius = 8
            placeholder.layer.borderWidth = 1
            placeholder.layer.borderColor = UIColor(white: 0.3, alpha: 1.0).cgColor
            placeholder.isUserInteractionEnabled = false

            let label = UILabel()
            label.text = screenName(component)
            label.textColor = UIColor(white: 0.4, alpha: 1.0)
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.translatesAutoresizingMaskIntoConstraints = false
            placeholder.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: placeholder.leadingAnchor, constant: 4),
            ])

            view.addSubview(placeholder)
            screenViews.append((component, placeholder))
        }

        for element in editableElements {
            let btn: UIView
            switch element {
            case .dpad: btn = useJoystick ? DPadView() : CrossDPadView()
            case .btnA, .btnB, .btnX, .btnY: btn = ActionButton(label: element.displayName)
            case .btnL, .btnR: btn = ShoulderButton(label: element.displayName)
            case .btnStart, .btnSelect, .btnMic:
                btn = SmallButton(label: element.displayName.uppercased())
            case .btnMenu:
                btn = SmallButton(systemImage: "gearshape.fill")
            case .btnClip:
                btn = SmallButton(systemImage: "film.fill")
            }
            btn.isUserInteractionEnabled = false
            view.addSubview(btn)
            buttonViews.append((element, btn))
        }
    }

    private func screenName(_ component: ScreenComponent) -> String {
        switch component {
        case .main: return NSLocalizedString("layout.editor.screenPreview", comment: "")
        case .top: return NSLocalizedString("layout.editor.topScreen", comment: "")
        case .bottom: return NSLocalizedString("layout.editor.bottomScreen", comment: "")
        }
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

        // D-pad / Joystick toggle — the one per-preset choice that applies to
        // BOTH orientations.
        let dpadTitle = useJoystick
            ? NSLocalizedString("settings.dpad", comment: "")
            : NSLocalizedString("settings.joystick", comment: "")
        let dpadIcon = useJoystick ? "dpad" : "circle.circle"
        let dpadToggle = UIAction(title: dpadTitle,
                                  image: UIImage(systemName: dpadIcon)) { [weak self] _ in
            self?.toggleDPadJoystick()
        }

        let reset = UIAction(title: NSLocalizedString("layout.editor.reset", comment: ""),
                             image: UIImage(systemName: "arrow.counterclockwise"),
                             attributes: .destructive) { [weak self] _ in
            self?.resetTapped()
        }

        let cancel = UIAction(title: NSLocalizedString("common.cancel", comment: ""),
                              image: UIImage(systemName: "xmark")) { [weak self] _ in
            self?.cancelTapped()
        }

        // Controller mode has no D-pad to toggle: only the screens and Menu
        // exist there, so the choice would be meaningless.
        return controllerMode
            ? UIMenu(children: [done, reset, cancel])
            : UIMenu(children: [done, dpadToggle, reset, cancel])
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

    private func setupHintLabel() {
        hintLabel.text = NSLocalizedString("layout.editor.hint", comment: "")
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.35)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - Per-component panel

    private func setupPanel() {
        panel.backgroundColor = UIColor(white: 0.12, alpha: 0.96)
        panel.layer.cornerRadius = 14
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        view.addSubview(panel)

        panelTitle.textColor = .white
        panelTitle.font = .systemFont(ofSize: 15, weight: .semibold)

        // Hide/Show toggle for the selected component (eye icon + word).
        hideButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        hideButton.tintColor = .white
        hideButton.addAction(UIAction { [weak self] _ in self?.toggleHideSelected() }, for: .touchUpInside)

        // Per-component reset (back to the built-in default spot/size/opacity).
        resetComponentButton.setImage(UIImage(systemName: "arrow.counterclockwise"), for: .normal)
        resetComponentButton.tintColor = UIColor.white.withAlphaComponent(0.7)
        resetComponentButton.accessibilityLabel = NSLocalizedString("layout.editor.reset", comment: "")
        resetComponentButton.addAction(UIAction { [weak self] _ in self?.resetSelectedComponent() }, for: .touchUpInside)

        let titleRow = UIStackView(arrangedSubviews: [panelTitle, UIView(), resetComponentButton, hideButton])
        titleRow.axis = .horizontal
        titleRow.spacing = 14
        titleRow.alignment = .center

        cannotHideLabel.text = NSLocalizedString("layout.editor.cannotHide", comment: "")
        cannotHideLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        cannotHideLabel.font = .systemFont(ofSize: 11)
        cannotHideLabel.numberOfLines = 0

        let sizeLabel = UILabel()
        sizeLabel.text = NSLocalizedString("layout.editor.size", comment: "")
        sizeLabel.textColor = .white
        sizeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sizeValueLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        sizeValueLabel.font = .systemFont(ofSize: 13)
        sizeValueLabel.textAlignment = .right
        let sizeHeader = UIStackView(arrangedSubviews: [sizeLabel, sizeValueLabel])
        sizeHeader.axis = .horizontal

        let opacityLabel = UILabel()
        opacityLabel.text = NSLocalizedString("layout.editor.opacity", comment: "")
        opacityLabel.textColor = .white
        opacityLabel.font = .systemFont(ofSize: 13, weight: .medium)
        opacityValueLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        opacityValueLabel.font = .systemFont(ofSize: 13)
        opacityValueLabel.textAlignment = .right
        let opacityHeader = UIStackView(arrangedSubviews: [opacityLabel, opacityValueLabel])
        opacityHeader.axis = .horizontal

        sizeSlider.addTarget(self, action: #selector(sizeSliderChanged), for: .valueChanged)
        opacitySlider.minimumValue = Float(PresetLayoutResolver.minOpacity)
        opacitySlider.maximumValue = Float(PresetLayoutResolver.maxOpacity)
        opacitySlider.addTarget(self, action: #selector(opacitySliderChanged), for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [
            titleRow, cannotHideLabel, sizeHeader, sizeSlider, opacityHeader, opacitySlider,
        ])
        stack.axis = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(8, after: titleRow)
        stack.setCustomSpacing(8, after: cannotHideLabel)
        stack.setCustomSpacing(10, after: sizeSlider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        panelBottomConstraint = panel.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10)
        panelTopConstraint = panel.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Self.panelTopOffset)
        panelBottomConstraint.isActive = true

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            panel.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32).withPriority(.defaultHigh),

            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
        ])
    }

    /// Docks the panel at the bottom unless it would overlap the selected
    /// component (with a small margin); then it hops to the top dock, and back
    /// once the bottom is free again. If both docks overlap (a huge screen),
    /// the lesser overlap wins. Animated, both orientations.
    private func updatePanelPosition(animated: Bool = true) {
        guard !panel.isHidden, let selectedFrame = selectedView()?.frame else { return }

        let safe = view.safeAreaInsets
        let width = min(360, view.bounds.width - 32)
        let height = panel.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        guard height > 0 else { return }

        let x = (view.bounds.width - width) / 2
        let bottomFrame = CGRect(x: x, y: view.bounds.height - safe.bottom - 10 - height,
                                 width: width, height: height)
        let topFrame = CGRect(x: x, y: safe.top + Self.panelTopOffset,
                              width: width, height: height)
        let target = selectedFrame.insetBy(dx: -12, dy: -12)

        let shouldBeTop: Bool
        let bottomBlocked = bottomFrame.intersects(target)
        let topBlocked = topFrame.intersects(target)
        if bottomBlocked && topBlocked {
            let overlap = { (a: CGRect) -> CGFloat in
                let i = a.intersection(target)
                return i.isNull ? 0 : i.width * i.height
            }
            shouldBeTop = overlap(topFrame) < overlap(bottomFrame)
        } else {
            shouldBeTop = bottomBlocked
        }
        guard shouldBeTop != panelAtTop else { return }
        panelAtTop = shouldBeTop

        if shouldBeTop {
            panelBottomConstraint.isActive = false
            panelTopConstraint.isActive = true
        } else {
            panelTopConstraint.isActive = false
            panelBottomConstraint.isActive = true
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
                self.view.layoutIfNeeded()
            }
        }
    }

    // MARK: - Gestures (handled at the root, mirroring the in-game touch model
    // where components themselves are not interactive)

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
    }

    /// Keep the canvas gestures off the floating chrome (panel, menu) so the
    /// sliders and menu receive their own touches.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        if let v = touch.view, v.isDescendant(of: panel) || v.isDescendant(of: menuButton) {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// The drag only begins on a component; elsewhere the touch falls through
    /// to the tap (select / deselect).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer {
            return hitComponent(at: gestureRecognizer.location(in: view)) != nil
        }
        return true
    }

    /// The component under `point`, for grabbing. Buttons take priority over
    /// screens, matching the visual stacking (smallest hit area first, so a
    /// small control overlapping the D-pad stays reachable); screens are hit last.
    private func hitComponent(at point: CGPoint) -> (Component, UIView)? {
        let buttonHits = buttonViews
            .filter { $0.1.frame.insetBy(dx: -8, dy: -8).contains(point) }
            .sorted { $0.1.frame.width * $0.1.frame.height < $1.1.frame.width * $1.1.frame.height }
        if let hit = buttonHits.first { return (.button(hit.0), hit.1) }
        let screenHits = screenViews
            .filter { $0.1.frame.contains(point) }
            .sorted { $0.1.frame.width * $0.1.frame.height < $1.1.frame.width * $1.1.frame.height }
        if let hit = screenHits.first { return (.screen(hit.0), hit.1) }
        return nil
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let (component, v) = hitComponent(at: gesture.location(in: view)) else { return }
            currentlyDragging = true
            draggingView = v
            draggingComponent = component
            dragStartCenter = v.center
            select(component)
            UIView.animate(withDuration: 0.15) {
                v.layer.shadowColor = UIColor.systemBlue.cgColor
                v.layer.shadowRadius = 8
                v.layer.shadowOpacity = 0.5
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

        case .changed:
            guard let v = draggingView else { return }
            let translation = gesture.translation(in: view)
            let newCenter = CGPoint(x: dragStartCenter.x + translation.x,
                                    y: dragStartCenter.y + translation.y)
            // The component's full frame stays inside the device screen: it
            // slides along the edges instead of leaving them.
            v.center = PresetLayoutResolver.clampedCenter(
                newCenter, size: v.frame.size, viewSize: view.bounds.size)
            // Keep the panel out of the way while the component travels.
            updatePanelPosition()

        case .ended, .cancelled:
            defer {
                draggingView = nil
                draggingComponent = nil
                currentlyDragging = false
            }
            guard let v = draggingView, let component = draggingComponent else { return }
            UIView.animate(withDuration: 0.15) { v.layer.shadowOpacity = 0 }
            commit(component, center: v.center)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

        default: break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if let (component, _) = hitComponent(at: gesture.location(in: view)) {
            select(component)
        } else {
            select(nil)
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            // Pinch resizes the selection; starting a pinch over an unselected
            // component selects it first.
            if selected == nil, let (component, _) = hitComponent(at: gesture.location(in: view)) {
                select(component)
            }
            pinchStartScale = currentScaleOfSelection() ?? 1
        case .changed:
            guard selected != nil else { return }
            commitScale(pinchStartScale * gesture.scale)
        case .ended:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        default: break
        }
    }

    // MARK: - Selection

    private func select(_ component: Component?) {
        guard selected != component else {
            if component == nil { updateSelectionUI() }
            return
        }
        selected = component
        updateSelectionUI()
        if component != nil {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func selectedView() -> UIView? {
        switch selected {
        case .button(let e): return buttonViews.first { $0.0 == e }?.1
        case .screen(let s): return screenViews.first { $0.0 == s }?.1
        case nil: return nil
        }
    }

    private func currentScaleOfSelection() -> CGFloat? {
        switch selected {
        case .button(let e): return scene?.buttons[e]?.scale
        case .screen(let s): return scene.flatMap { sc in
            sc.screens[s].map { screen in
                // Recover the scale from the resolved frame vs the default.
                let defaultRect = defaultGeometry().screens[s]
                guard let dw = defaultRect?.width, dw > 0 else { return 1 }
                return screen.frame.width / dw
            }
        }
        case nil: return nil
        }
    }

    private func isSelectionHidden() -> Bool {
        switch selected {
        case .button(let e): return scene?.buttons[e]?.isHidden ?? false
        case .screen, nil: return false   // screens can never be hidden
        }
    }

    private func updateSelectionUI() {
        // Selection ring on the selected view only.
        for (_, v) in buttonViews { updateSelectionRing(on: v, show: false) }
        for (_, v) in screenViews { updateSelectionRing(on: v, show: false) }

        guard let component = selected else {
            panel.isHidden = true
            hintLabel.isHidden = false
            return
        }
        if let v = selectedView() { updateSelectionRing(on: v, show: true) }
        panel.isHidden = false
        hintLabel.isHidden = true

        switch component {
        case .button(let element):
            guard let rc = scene?.buttons[element] else { return }
            panelTitle.text = element.displayName
            let protected = (element == .btnMenu || element == .btnClip)
            hideButton.isHidden = protected
            cannotHideLabel.isHidden = !protected
            sizeSlider.minimumValue = Float(PresetLayoutResolver.minControlScale)
            sizeSlider.maximumValue = Float(PresetLayoutResolver.maxControlScale)
            sizeSlider.value = Float(rc.scale)
            opacitySlider.value = Float(rc.opacity)
            updateHideButton(hidden: rc.isHidden)
        case .screen(let screenComponent):
            guard let rs = scene?.screens[screenComponent] else { return }
            panelTitle.text = screenName(screenComponent)
            // Screens can never be hidden: no Hide control, no caption needed.
            hideButton.isHidden = true
            cannotHideLabel.isHidden = true
            sizeSlider.minimumValue = Float(PresetLayoutResolver.minScreenScale)
            // The slider tops out where the screen would leave the device.
            sizeSlider.maximumValue = Float(maxScaleForScreen(screenComponent))
            sizeSlider.value = Float(currentScaleOfSelection() ?? 1)
            opacitySlider.value = Float(rs.opacity)
        }
        updateSliderValueLabels()
        updatePanelPosition()
    }

    private func updateHideButton(hidden: Bool) {
        let title = hidden
            ? NSLocalizedString("layout.editor.show", comment: "")
            : NSLocalizedString("layout.editor.hide", comment: "")
        let icon = hidden ? "eye" : "eye.slash"
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: icon)
        config.imagePadding = 5
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13)
        config.contentInsets = .zero
        config.baseForegroundColor = .white
        hideButton.configuration = config
    }

    private func updateSliderValueLabels() {
        sizeValueLabel.text = "\(Int(round(sizeSlider.value * 100)))%"
        opacityValueLabel.text = "\(Int(round(opacitySlider.value * 100)))%"
    }

    private func updateSelectionRing(on v: UIView, show: Bool) {
        v.layer.sublayers?.removeAll { $0.name == "selectionRing" }
        guard show else { return }
        let ring = CAShapeLayer()
        ring.name = "selectionRing"
        ring.strokeColor = UIColor.systemBlue.cgColor
        ring.fillColor = nil
        ring.lineWidth = 2
        let rect = v.bounds.insetBy(dx: -3, dy: -3)
        ring.frame = v.bounds
        ring.path = UIBezierPath(roundedRect: rect, cornerRadius: v.layer.cornerRadius + 3).cgPath
        v.layer.addSublayer(ring)
    }

    // MARK: - Edits (materialize the component, then re-render from the resolver)

    /// Writes the component into the preset with its CURRENT resolved values,
    /// overriding only the fields passed in. First touch stores it; untouched
    /// components keep tracking the built-in default.
    private func commit(_ component: Component, center: CGPoint? = nil,
                        scale: CGFloat? = nil, opacity: CGFloat? = nil,
                        isHidden: Bool? = nil) {
        let w = view.bounds.width, h = view.bounds.height
        guard w > 0, h > 0 else { return }
        var layout = currentLayout

        let viewSize = view.bounds.size
        switch component {
        case .button(let element):
            guard let rc = scene?.buttons[element] else { return }
            // Containment: the scaled frame must stay fully on the device.
            let newScale = scale ?? rc.scale
            let scaledSize = CGSize(width: rc.baseSize.width * newScale,
                                    height: rc.baseSize.height * newScale)
            let c = PresetLayoutResolver.clampedCenter(
                center ?? rc.center, size: scaledSize, viewSize: viewSize)
            layout.buttons[element.rawValue] = ButtonLayout(
                centerX: c.x / w,
                centerY: c.y / h,
                isHidden: PresetLayoutResolver.hidden(isHidden ?? rc.isHidden, element: element),
                scale: newScale,
                opacity: opacity ?? rc.opacity)
        case .screen(let screenComponent):
            guard let rs = scene?.screens[screenComponent],
                  let defaultRect = defaultGeometry().screens[screenComponent] else { return }
            // Containment: cap the scale so the screen fits the device, then
            // keep the resized frame inside it.
            let newScale = min(scale ?? (currentScaleOfScreen(screenComponent) ?? 1),
                               PresetLayoutResolver.maxFittingScreenScale(
                                   defaultSize: defaultRect.size, viewSize: viewSize))
            let size = CGSize(width: defaultRect.width * newScale,
                              height: defaultRect.height * newScale)
            let c = PresetLayoutResolver.clampedCenter(
                center ?? CGPoint(x: rs.frame.midX, y: rs.frame.midY),
                size: size, viewSize: viewSize)
            layout.screens[screenComponent.rawValue] = ScreenLayout(
                centerX: c.x / w,
                centerY: c.y / h,
                scale: newScale,
                opacity: opacity ?? rs.opacity)
        }

        currentLayout = layout
        refreshScene()
    }

    private func currentScaleOfScreen(_ s: ScreenComponent) -> CGFloat? {
        guard let frame = scene?.screens[s]?.frame,
              let defaultRect = defaultGeometry().screens[s], defaultRect.width > 0 else { return nil }
        return frame.width / defaultRect.width
    }

    /// The largest scale that keeps this screen fully on the device in the
    /// current orientation (never below the slider's minimum).
    private func maxScaleForScreen(_ s: ScreenComponent) -> CGFloat {
        guard let defaultRect = defaultGeometry().screens[s] else {
            return PresetLayoutResolver.maxScreenScale
        }
        return max(PresetLayoutResolver.minScreenScale,
                   PresetLayoutResolver.maxFittingScreenScale(
                       defaultSize: defaultRect.size, viewSize: view.bounds.size))
    }

    private func commitScale(_ raw: CGFloat) {
        guard let component = selected else { return }
        let clamped: CGFloat
        switch component {
        case .button:
            clamped = min(max(raw, PresetLayoutResolver.minControlScale),
                          PresetLayoutResolver.maxControlScale)
        case .screen(let s):
            clamped = min(max(raw, PresetLayoutResolver.minScreenScale), maxScaleForScreen(s))
        }
        commit(component, scale: clamped)
        sizeSlider.value = Float(clamped)
        updateSliderValueLabels()
    }

    private func toggleHideSelected() {
        // Buttons only: screens can never be hidden (no Hide control shown).
        guard let component = selected, case .button = component else { return }
        commit(component, isHidden: !isSelectionHidden())
        updateSelectionUI()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func resetSelectedComponent() {
        guard let component = selected else { return }
        var layout = currentLayout
        switch component {
        case .button(let e): layout.buttons[e.rawValue] = nil
        case .screen(let s): layout.screens[s.rawValue] = nil
        }
        currentLayout = layout
        refreshScene()
        updateSelectionUI()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @objc private func sizeSliderChanged() {
        guard let component = selected else { return }
        commit(component, scale: CGFloat(sizeSlider.value))
        updateSliderValueLabels()
    }

    @objc private func opacitySliderChanged() {
        guard let component = selected else { return }
        commit(component, opacity: CGFloat(opacitySlider.value))
        updateSliderValueLabels()
    }

    // MARK: - Rendering (resolver-driven, identical to the game)

    private func defaultGeometry() -> PresetLayoutResolver.DefaultGeometry {
        PresetLayoutResolver.defaultGeometry(
            system: system, isLandscape: isLandscape,
            viewSize: view.bounds.size, safeInsets: view.safeAreaInsets,
            controllerConnected: controllerMode)
    }

    /// One-time conversion of a legacy (pre-component) orientation layout to
    /// full-view space the first time the editor shows it; positions are
    /// preserved exactly. Saved with the preset on Done.
    private func ensureFullViewSpace() {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let layout = currentLayout
        guard layout.space == OrientationLayout.legacySpace else { return }
        currentLayout = PresetLayoutResolver.upgradedToFullView(
            layout, preset: preset, system: system, isLandscape: isLandscape,
            viewSize: view.bounds.size, safeInsets: view.safeAreaInsets)
    }

    private func refreshScene() {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        // Render through the SAME resolver the game uses, so the preview cannot
        // drift from what the player will actually see.
        scene = controllerMode
            ? PresetLayoutResolver.resolveController(
                layout: ControllerLayout(portrait: preset.portrait, landscape: preset.landscape),
                system: system, isLandscape: isLandscape,
                viewSize: view.bounds.size, safeInsets: view.safeAreaInsets)
            : PresetLayoutResolver.resolve(
                preset: preset, system: system, isLandscape: isLandscape,
                viewSize: view.bounds.size, safeInsets: view.safeAreaInsets)
        positionComponents()
    }

    private func layoutPreview() {
        orientationLabel.text = isLandscape
            ? NSLocalizedString("layout.editor.landscapeShort", comment: "")
            : NSLocalizedString("layout.editor.portraitShort", comment: "")
        ensureFullViewSpace()
        refreshScene()
        updateSelectionUI()
    }

    private func positionComponents() {
        guard let scene else { return }

        for (component, v) in screenViews {
            guard let rs = scene.screens[component] else { continue }
            v.frame = rs.frame
            v.alpha = rs.opacity
        }

        for (element, v) in buttonViews {
            guard let rc = scene.buttons[element] else {
                v.isHidden = true
                continue
            }
            v.isHidden = false
            // Mirror the in-game render exactly: bounds = device-scaled base
            // size, the user's scale as a transform (so fonts/borders/corners
            // scale together), centered at the resolved spot.
            v.transform = .identity
            v.frame = CGRect(x: rc.center.x - rc.baseSize.width / 2,
                             y: rc.center.y - rc.baseSize.height / 2,
                             width: rc.baseSize.width, height: rc.baseSize.height)
            v.transform = CGAffineTransform(scaleX: rc.scale, y: rc.scale)

            if rc.isHidden {
                v.alpha = 0.15
                updateDashedBorder(on: v, show: true)
            } else {
                v.alpha = rc.opacity
                updateDashedBorder(on: v, show: false)
            }
        }

        // A resize re-renders the canvas; keep the selection ring sized to the
        // selected view's current bounds, and the panel clear of the component.
        if selected != nil, let v = selectedView() {
            updateSelectionRing(on: v, show: true)
            updatePanelPosition()
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

    // MARK: - Actions

    private func doneTapped() {
        preset.useJoystick = useJoystick
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
            // Empty full-view layout = every component back on the built-in
            // default for this orientation. The other orientation is untouched.
            self.currentLayout = OrientationLayout()
            self.select(nil)
            self.refreshScene()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        })
        present(alert, animated: true)
    }

    private func toggleDPadJoystick() {
        useJoystick.toggle()
        // Per-preset: saved on Done; applies to both orientations.
        preset.useJoystick = useJoystick
        swapDPadView()
        menuButton.menu = buildMenu()
    }

    private func swapDPadView() {
        guard let idx = buttonViews.firstIndex(where: { $0.0 == .dpad }) else { return }
        let (_, oldBtn) = buttonViews[idx]
        let wasSelected = (selected == .button(.dpad))
        oldBtn.removeFromSuperview()

        let newBtn: UIView = useJoystick ? DPadView() : CrossDPadView()
        newBtn.isUserInteractionEnabled = false
        // Keep the canvas stacking: above the screens, below the floating chrome.
        view.insertSubview(newBtn, belowSubview: menuButton)
        buttonViews[idx] = (.dpad, newBtn)
        positionComponents()
        if wasSelected { updateSelectionUI() }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        select(nil)
        coordinator.animate(alongsideTransition: { _ in self.layoutPreview() })
    }
}

// MARK: - Small helpers

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
