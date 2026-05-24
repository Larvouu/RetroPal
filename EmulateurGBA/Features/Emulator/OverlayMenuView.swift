//
//  OverlayMenuView.swift
//  EmulateurGBA
//
//  Translucent overlay shown when the player pauses the game.
//  Provides Resume, Save/Load slots, Speed selection, Screenshot, and Quit.
//

import UIKit

protocol OverlayMenuDelegate: AnyObject {
    func overlayDidTapResume()
    func overlayDidSelectSpeed(_ multiplier: Double)
    func overlayDidSaveState(slot: Int)
    func overlayDidLoadState(slot: Int)
    func overlayDidTapRewind()
    func overlayDidTapQuit()
    func overlayDidTapLockedFeature(context: ProPromptContext)
    func overlayDidTapShareScreenshot()
    func overlayDidTapCheats()
    func overlayDidToggleSound(enabled: Bool)
}

final class OverlayMenuView: UIView {
    weak var delegate: OverlayMenuDelegate?

    // MARK: - Constants

    private static let allSpeeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4]
    private static let freeSpeeds: Set<Double> = [1, 1.5]

    // MARK: - State

    private var currentSpeed: Double = 1.0
    private var slotInfos: [(info: SaveSlotInfo, isLocked: Bool)] = []

    // MARK: - Subviews

    private let blurView: UIVisualEffectView = {
        let v = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let scrollView: UIScrollView = {
        let s = UIScrollView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.showsVerticalScrollIndicator = false
        return s
    }()

    private let contentStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 16
        s.alignment = .center
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = NSLocalizedString("overlay.paused", comment: "")
        l.textColor = .white
        l.font = .preferredFont(forTextStyle: .title1)
        l.textAlignment = .center
        l.accessibilityTraits = .header
        return l
    }()

    /// Set to true to hide the rewind button (e.g., NDS games)
    var rewindHidden = false {
        didSet { rewindButton.isHidden = rewindHidden }
    }

    private var isSoundEnabled = true

    /// Set to true when emulator speed > 2x, which forces audio off via
    /// `session.skipAudio`. The user's mute preference (isSoundEnabled)
    /// stays untouched — the button just reflects the effective silence.
    var isAudioSuspendedBySpeed: Bool = false {
        didSet { updateSoundButton() }
    }

    private let resumeButton: UIButton = {
        let btn = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = NSLocalizedString("overlay.resume", comment: "")
        config.image = UIImage(systemName: "play.fill")
        config.imagePadding = 8
        config.baseBackgroundColor = UIColor.systemGreen.withAlphaComponent(0.3)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        btn.configuration = config
        btn.accessibilityLabel = NSLocalizedString("overlay.resume", comment: "")
        return btn
    }()
    private let rewindButton = OverlayMenuView.makeButton(
        title: String(format: NSLocalizedString("overlay.rewind", comment: ""), "5"), icon: "backward.fill")
    private let screenshotButton = OverlayMenuView.makeButton(
        title: NSLocalizedString("overlay.screenshot", comment: ""), icon: "camera.fill")
    private let cheatsButton = OverlayMenuView.makeButton(
        title: NSLocalizedString("overlay.cheats", comment: ""), icon: "command")
    private let soundButton = OverlayMenuView.makeButton(
        title: NSLocalizedString("overlay.sound", comment: ""), icon: "speaker.wave.2.fill")
    private let quitButton: UIButton = {
        let btn = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = NSLocalizedString("overlay.quit", comment: "")
        config.image = UIImage(systemName: "xmark.circle")
        config.imagePadding = 8
        config.baseBackgroundColor = UIColor.systemRed.withAlphaComponent(0.4)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        btn.configuration = config
        btn.accessibilityLabel = NSLocalizedString("overlay.quit", comment: "")
        return btn
    }()

    private lazy var speedLabel = makeSectionLabel(NSLocalizedString("overlay.speed", comment: ""))
    private lazy var saveLoadLabel = makeSectionLabel(NSLocalizedString("overlay.saveSlots", comment: ""))

    private func makeSectionLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.textColor = UIColor.white.withAlphaComponent(0.5)
        l.font = .preferredFont(forTextStyle: .caption1)
        l.textAlignment = .center
        return l
    }


    private let speedStack: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 8
        s.distribution = .fillEqually
        return s
    }()

    private let slotsStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 8
        s.alignment = .fill
        return s
    }()

    private var speedButtons: [UIButton] = []

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityViewIsModal = true
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Two-column containers for landscape
    private let landscapeContainer: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 24
        s.alignment = .top
        s.distribution = .fillEqually
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let leftColumn: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 10
        s.alignment = .center
        return s
    }()

    private let rightColumn: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 10
        s.alignment = .center
        return s
    }()

    private var isLandscapeLayout = false
    private var slotsWidthConstraint: NSLayoutConstraint?
    private var layoutConstraints: [NSLayoutConstraint] = []

    // MARK: - Setup

    private func setup() {
        addSubview(blurView)
        addSubview(scrollView)
        scrollView.addSubview(contentStack)
        scrollView.addSubview(landscapeContainer)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -8),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            contentStack.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),

            landscapeContainer.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            landscapeContainer.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -8),
            landscapeContainer.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            landscapeContainer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            landscapeContainer.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        landscapeContainer.addArrangedSubview(leftColumn)
        landscapeContainer.addArrangedSubview(rightColumn)
        landscapeContainer.isHidden = true

        // Create speed buttons
        for speed in Self.allSpeeds {
            let btn = UIButton(type: .system)
            let title: String
            if speed == floor(speed) {
                title = "\(Int(speed))x"
            } else {
                title = "\(speed)x"
            }
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
            btn.layer.cornerRadius = 8
            btn.layer.borderWidth = 1.5
            btn.addTarget(self, action: #selector(speedTapped(_:)), for: .touchUpInside)
            btn.accessibilityLabel = "\(title) speed"
            speedButtons.append(btn)
            speedStack.addArrangedSubview(btn)
            btn.heightAnchor.constraint(equalToConstant: 36).isActive = true
            // accessibilityHint is set per-button in updateSpeedHighlight so
            // it reacts to Pro state changes at runtime.
        }

        slotsWidthConstraint = slotsStack.widthAnchor.constraint(equalToConstant: 280)
        slotsWidthConstraint?.isActive = true

        // Wire actions
        resumeButton.addTarget(self, action: #selector(resumeTapped), for: .touchUpInside)
        rewindButton.addTarget(self, action: #selector(rewindTapped), for: .touchUpInside)
        screenshotButton.addTarget(self, action: #selector(screenshotTapped), for: .touchUpInside)
        cheatsButton.addTarget(self, action: #selector(cheatsTapped), for: .touchUpInside)
        soundButton.addTarget(self, action: #selector(soundTapped), for: .touchUpInside)
        quitButton.addTarget(self, action: #selector(quitTapped), for: .touchUpInside)
        // The premium styling in refreshProState() draws a border and a
        // purple shadow directly on the button's layer, so the layer needs
        // its own rounded corners and must not clip its shadow.
        cheatsButton.layer.cornerRadius = 10
        cheatsButton.layer.masksToBounds = false

        // Initial layout
        buildPortraitLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let landscape = bounds.width > bounds.height
        if landscape != isLandscapeLayout {
            isLandscapeLayout = landscape
            if landscape {
                buildLandscapeLayout()
            } else {
                buildPortraitLayout()
            }
        }
    }

    private func buildPortraitLayout() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints.removeAll()

        landscapeContainer.isHidden = true
        contentStack.isHidden = false

        // Remove all from both columns
        leftColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rightColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionRow1.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionRow2.arrangedSubviews.forEach { $0.removeFromSuperview() }
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(quitButton)
        addSpacer(height: 8, to: contentStack)

        for btn in [resumeButton, rewindButton, screenshotButton, cheatsButton, soundButton] {
            contentStack.addArrangedSubview(btn)
        }
        // Portrait buttons are full-width: restore the roomy single-line style
        // (undoes the landscape compact style after a rotation back to portrait).
        for btn in [resumeButton, rewindButton, screenshotButton, cheatsButton, soundButton, quitButton] {
            setActionButtonCompact(btn, false)
        }
        addSpacer(height: 8, to: contentStack)

        contentStack.addArrangedSubview(speedLabel)
        contentStack.addArrangedSubview(speedStack)
        addSpacer(height: 8, to: contentStack)

        contentStack.addArrangedSubview(saveLoadLabel)
        contentStack.addArrangedSubview(slotsStack)

        // Button sizes for portrait
        for btn in [quitButton, resumeButton, rewindButton, screenshotButton, cheatsButton, soundButton] {
            layoutConstraints.append(btn.widthAnchor.constraint(equalToConstant: 240))
            layoutConstraints.append(btn.heightAnchor.constraint(equalToConstant: 46))
        }
        NSLayoutConstraint.activate(layoutConstraints)
        slotsWidthConstraint?.constant = 280
    }

    // 2x2 grid rows for landscape action buttons
    private let actionRow1: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 8
        s.distribution = .fillEqually
        return s
    }()

    private let actionRow2: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 8
        s.distribution = .fillEqually
        return s
    }()

    private func buildLandscapeLayout() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints.removeAll()

        contentStack.isHidden = true
        landscapeContainer.isHidden = false

        // Remove all from portrait stack
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        leftColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rightColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionRow1.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionRow2.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Left column: title, quit, [top full-width button], 2x2 action grid, speed.
        // For GBA/GB/GBC, Resume gets the full-width slot (primary action).
        // For NDS, Rewind sits in the slot but stays hidden, keeping Resume in the grid.
        leftColumn.addArrangedSubview(titleLabel)
        leftColumn.addArrangedSubview(quitButton)
        addSpacer(height: 6, to: leftColumn)

        let topButton: UIButton = rewindHidden ? rewindButton : resumeButton
        let gridLeadButton: UIButton = rewindHidden ? resumeButton : rewindButton
        leftColumn.addArrangedSubview(topButton)

        // 2x2 grid
        actionRow1.addArrangedSubview(gridLeadButton)
        actionRow1.addArrangedSubview(screenshotButton)
        actionRow2.addArrangedSubview(cheatsButton)
        actionRow2.addArrangedSubview(soundButton)
        leftColumn.addArrangedSubview(actionRow1)
        leftColumn.addArrangedSubview(actionRow2)

        // The ~156pt grid buttons are too narrow for the longer localized labels
        // ("Rembobiner 30s", "Partager une capture") at the portrait font, so make
        // the grid buttons compact (smaller icon, tighter insets, two-line wrap) so
        // the full label is visible. Full-width Resume/Quit keep the roomy style.
        for b in [gridLeadButton, screenshotButton, cheatsButton, soundButton] {
            setActionButtonCompact(b, true)
        }
        for b in [topButton, quitButton] {
            setActionButtonCompact(b, false)
        }

        addSpacer(height: 6, to: leftColumn)
        leftColumn.addArrangedSubview(speedLabel)
        leftColumn.addArrangedSubview(speedStack)

        // Right column: save slots only
        rightColumn.addArrangedSubview(saveLoadLabel)
        rightColumn.addArrangedSubview(slotsStack)

        // Button sizes for landscape
        let fullW: CGFloat = 200
        let gridW: CGFloat = 320
        let btnH: CGFloat = 40
        layoutConstraints.append(quitButton.widthAnchor.constraint(equalToConstant: fullW))
        layoutConstraints.append(quitButton.heightAnchor.constraint(equalToConstant: btnH))
        layoutConstraints.append(topButton.widthAnchor.constraint(equalToConstant: fullW))
        layoutConstraints.append(topButton.heightAnchor.constraint(equalToConstant: btnH))
        for row in [actionRow1, actionRow2] {
            layoutConstraints.append(row.widthAnchor.constraint(equalToConstant: gridW))
        }
        for btn in [gridLeadButton, screenshotButton, cheatsButton, soundButton] {
            layoutConstraints.append(btn.heightAnchor.constraint(equalToConstant: btnH))
        }
        NSLayoutConstraint.activate(layoutConstraints)
        slotsWidthConstraint?.constant = 320
    }

    /// The landscape 2x2 grid buttons are only ~156pt wide, too narrow for the
    /// longer localized labels at the portrait font. UIButton.Configuration
    /// ignores titleLabel.adjustsFontSizeToFitWidth, so to show the full label we
    /// shrink the icon, tighten the insets, and let the title wrap to two lines.
    /// Passing `compact = false` restores the roomy single-line style (portrait
    /// and the full-width Resume/Quit buttons), so a rotation back is clean.
    private func setActionButtonCompact(_ btn: UIButton, _ compact: Bool) {
        guard var config = btn.configuration else { return }
        if compact {
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            config.imagePadding = 5
            config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
            config.titleLineBreakMode = .byWordWrapping
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .systemFont(ofSize: 13, weight: .medium)
                return out
            }
            btn.titleLabel?.numberOfLines = 2
            btn.titleLabel?.textAlignment = .center
        } else {
            config.preferredSymbolConfigurationForImage = nil
            config.imagePadding = 8
            config.contentInsets = UIButton.Configuration.filled().contentInsets
            config.titleLineBreakMode = .byTruncatingTail
            config.titleTextAttributesTransformer = nil
            btn.titleLabel?.numberOfLines = 1
            btn.titleLabel?.textAlignment = .natural
        }
        btn.configuration = config
    }

    // MARK: - Public

    func setCurrentSpeed(_ speed: Double) {
        currentSpeed = speed
        refreshProState()
    }

    func updateSlots(_ slots: [(info: SaveSlotInfo, isLocked: Bool)]) {
        slotInfos = slots
        slotsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for slot in slots {
            slotsStack.addArrangedSubview(makeSlotRow(slot.info, isLocked: slot.isLocked))
        }
    }

    func setSoundEnabled(_ enabled: Bool) {
        isSoundEnabled = enabled
        updateSoundButton()
    }

    func refreshProState() {
        let isPro = UserDefaults.standard.bool(forKey: "isPro")
        updateSpeedHighlight()
        let rewindSeconds = isPro ? "30" : "5"
        rewindButton.configuration?.title = String(format: NSLocalizedString("overlay.rewind", comment: ""), rewindSeconds)
        // Cheats button: gold→purple premium gradient when free, plain fill
        // when Pro. No border, no chip — the background does the talking.
        applyPremiumStyle(to: cheatsButton, active: !isPro)
        cheatsButton.accessibilityHint = isPro ? nil : NSLocalizedString("pro.badge", comment: "")
    }

    /// Applies the premium visual signature (smooth gold→purple gradient
    /// background + soft purple shadow, no border) to a Pro-gated UI
    /// element. Kept light so the shift from regular to premium is a
    /// gentle temptation rather than a loud paywall.
    ///
    /// Idempotent: repeated calls with the same `active` value leave the
    /// existing GradientBackgroundView (and its particle emitter state) in
    /// place. This matters because updateSpeedHighlight runs on every speed
    /// change — without this guard, every locked speed's emitter would
    /// reset on each tap, causing a visible particle-position jump.
    private func applyPremiumStyle(to view: UIView, active: Bool) {
        let purple = UIColor(red: 0.45, green: 0.2, blue: 0.85, alpha: 1.0)

        if let btn = view as? UIButton, var config = btn.configuration {
            let hasGradient = config.background.customView is GradientBackgroundView
            if active && !hasGradient {
                let bg = GradientBackgroundView()
                bg.layer.cornerRadius = btn.layer.cornerRadius
                config.background.customView = bg
                config.background.backgroundColor = .clear
                btn.configuration = config
            } else if !active && hasGradient {
                config.background.customView = nil
                config.background.backgroundColor = UIColor.white.withAlphaComponent(0.15)
                btn.configuration = config
            }
        } else {
            let existing = view.subviews.compactMap { $0 as? GradientBackgroundView }.first
            if active && existing == nil {
                let bg = GradientBackgroundView()
                bg.layer.cornerRadius = view.layer.cornerRadius
                bg.translatesAutoresizingMaskIntoConstraints = false
                view.insertSubview(bg, at: 0)
                NSLayoutConstraint.activate([
                    bg.topAnchor.constraint(equalTo: view.topAnchor),
                    bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                ])
            } else if !active, let existing = existing {
                existing.removeFromSuperview()
            }
        }

        view.layer.borderWidth = 0
        if active {
            view.layer.shadowColor = purple.cgColor
            view.layer.shadowOpacity = 0.4
            view.layer.shadowRadius = 5
            view.layer.shadowOffset = .zero
            view.layer.masksToBounds = false
        } else {
            view.layer.shadowOpacity = 0
        }
    }

    // MARK: - Slot Row

    private func makeSlotRow(_ slot: SaveSlotInfo, isLocked: Bool) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        container.layer.cornerRadius = 12

        // Preview image
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.layer.magnificationFilter = .nearest
        imageView.layer.minificationFilter = .nearest
        imageView.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        imageView.layer.cornerRadius = 4
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.accessibilityLabel = "Slot \(slot.slotIndex) preview"

        if let preview = loadPreview(slot) {
            imageView.image = preview
        }

        // Slot label — no lock icon; the Pro chip on the right carries the
        // "Pro" signal for locked slots, and keeping the label clean avoids
        // the defeated-UI feel of a lock icon.
        let titleLbl = UILabel()
        titleLbl.textColor = .white
        titleLbl.font = .preferredFont(forTextStyle: .subheadline)
        titleLbl.text = String(format: NSLocalizedString("overlay.slot", comment: ""), "\(slot.slotIndex)")

        let dateLbl = UILabel()
        dateLbl.font = .preferredFont(forTextStyle: .caption2)
        if isLocked && !slot.exists {
            dateLbl.text = NSLocalizedString("overlay.slot.empty", comment: "")
            dateLbl.textColor = UIColor.white.withAlphaComponent(0.4)
        } else if let date = slot.date {
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .short
            dateLbl.text = fmt.string(from: date)
            dateLbl.textColor = UIColor.white.withAlphaComponent(0.5)
        } else {
            dateLbl.text = NSLocalizedString("overlay.slot.empty", comment: "")
            dateLbl.textColor = UIColor.white.withAlphaComponent(0.4)
        }

        let labelStack = UIStackView(arrangedSubviews: [titleLbl, dateLbl])
        labelStack.axis = .vertical
        labelStack.spacing = 2

        // Add either Save/Load buttons (Pro slot) or premium styling on the
        // container itself (locked slot — the container IS the Pro invite).
        var trailing: UIView?
        if isLocked {
            // Drop the white-8% fill so the gradient view shows as-designed.
            container.backgroundColor = .clear
            applyPremiumStyle(to: container, active: true)
            let tap = UITapGestureRecognizer(target: self, action: #selector(lockedSlotTapped))
            container.addGestureRecognizer(tap)
            container.isUserInteractionEnabled = true
        } else {
            let saveBtn = makeSlotButton(
                title: NSLocalizedString("overlay.save", comment: ""),
                color: .systemBlue,
                tag: slot.slotIndex
            )
            let loadBtn = makeSlotButton(
                title: NSLocalizedString("overlay.load", comment: ""),
                color: slot.exists ? .systemGreen : .gray,
                tag: slot.slotIndex
            )
            saveBtn.addTarget(self, action: #selector(saveTapped(_:)), for: .touchUpInside)
            loadBtn.addTarget(self, action: #selector(loadTapped(_:)), for: .touchUpInside)
            loadBtn.isEnabled = slot.exists
            loadBtn.alpha = slot.exists ? 1.0 : 0.4
            saveBtn.accessibilityLabel = "Save to slot \(slot.slotIndex)"
            loadBtn.accessibilityLabel = "Load slot \(slot.slotIndex)"

            let btnStack = UIStackView(arrangedSubviews: [saveBtn, loadBtn])
            btnStack.axis = .vertical
            btnStack.spacing = 4
            btnStack.translatesAutoresizingMaskIntoConstraints = false
            trailing = btnStack

            NSLayoutConstraint.activate([
                saveBtn.widthAnchor.constraint(equalToConstant: 52),
                saveBtn.heightAnchor.constraint(equalToConstant: 32),
                loadBtn.widthAnchor.constraint(equalToConstant: 52),
                loadBtn.heightAnchor.constraint(equalToConstant: 32),
            ])
        }

        // Accessibility
        container.isAccessibilityElement = true
        container.accessibilityLabel = isLocked
            ? "Slot \(slot.slotIndex), \(NSLocalizedString("pro.badge", comment: ""))"
            : "Slot \(slot.slotIndex), \(slot.exists ? "has save data" : "empty")"

        var subviews: [UIView] = [imageView, labelStack]
        if let trailing = trailing { subviews.append(trailing) }
        for v in subviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }

        var constraints: [NSLayoutConstraint] = [
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 48),
            imageView.heightAnchor.constraint(equalToConstant: 32),

            labelStack.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
            labelStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            container.heightAnchor.constraint(equalToConstant: 76),
        ]
        if let trailing = trailing {
            constraints.append(contentsOf: [
                trailing.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                trailing.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)

        return container
    }

    private func makeSlotButton(title: String, color: UIColor, tag: Int) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = color.withAlphaComponent(0.5)
        btn.layer.cornerRadius = 8
        btn.tag = tag
        return btn
    }

    private func loadPreview(_ slot: SaveSlotInfo) -> UIImage? {
        guard slot.exists else { return nil }
        var image: UIImage?
        CoordinatedFileIO.read(at: slot.previewImageURL) { coordURL in
            image = UIImage(contentsOfFile: coordURL.path)
        }
        return image
    }

    // MARK: - Actions

    @objc private func resumeTapped() { delegate?.overlayDidTapResume() }
    @objc private func rewindTapped() { delegate?.overlayDidTapRewind() }
    @objc private func screenshotTapped() { delegate?.overlayDidTapShareScreenshot() }
    @objc private func quitTapped() { delegate?.overlayDidTapQuit() }
    @objc private func lockedSlotTapped() {
        // Only claim "all slots are full" when the free slots are genuinely
        // full. Otherwise fall back to envy copy that doesn't lie.
        let freeSlots = slotInfos.prefix(SaveStateManager.freeSlotCount)
        let allFreeFull = freeSlots.count == SaveStateManager.freeSlotCount
            && freeSlots.allSatisfy { $0.info.exists }
        let ctx: ProPromptContext = allFreeFull ? .saveSlotFull : .saveSlotTapped
        delegate?.overlayDidTapLockedFeature(context: ctx)
    }
    @objc private func soundTapped() {
        isSoundEnabled.toggle()
        updateSoundButton()
        delegate?.overlayDidToggleSound(enabled: isSoundEnabled)
    }

    @objc private func cheatsTapped() {
        let isPro = UserDefaults.standard.bool(forKey: "isPro")
        if isPro {
            delegate?.overlayDidTapCheats()
        } else {
            delegate?.overlayDidTapLockedFeature(context: .cheatCodesTapped)
        }
    }

    @objc private func speedTapped(_ sender: UIButton) {
        let index = speedButtons.firstIndex(of: sender) ?? 0
        let speed = Self.allSpeeds[index]

        let isPro = UserDefaults.standard.bool(forKey: "isPro")
        if !Self.freeSpeeds.contains(speed) && !isPro {
            // Tap-based entry: never claim a stat the user hasn't earned.
            // The earned .speedMoment(minutes) context fires only when the
            // 30-min threshold is crossed at overlay-open.
            delegate?.overlayDidTapLockedFeature(context: .speedTapped)
            return
        }

        currentSpeed = speed
        updateSpeedHighlight()
        delegate?.overlayDidSelectSpeed(speed)
    }

    @objc private func saveTapped(_ sender: UIButton) {
        delegate?.overlayDidSaveState(slot: sender.tag)
    }

    @objc private func loadTapped(_ sender: UIButton) {
        delegate?.overlayDidLoadState(slot: sender.tag)
    }

    private func updateSpeedHighlight() {
        let isPro = UserDefaults.standard.bool(forKey: "isPro")

        for (index, btn) in speedButtons.enumerated() {
            let speed = Self.allSpeeds[index]
            let locked = !Self.freeSpeeds.contains(speed) && !isPro
            let sel = speed == currentSpeed

            btn.alpha = 1.0
            btn.layer.masksToBounds = false

            if locked {
                // Same premium treatment as cheats / save slots: gold→purple
                // gradient background + purple glow, no border. Text stays
                // white to match the other speed buttons.
                btn.backgroundColor = .clear
                btn.setTitleColor(.white, for: .normal)
                applyPremiumStyle(to: btn, active: true)
                btn.accessibilityHint = NSLocalizedString("pro.badge", comment: "")
            } else {
                applyPremiumStyle(to: btn, active: false)
                btn.backgroundColor = sel ? UIColor.white.withAlphaComponent(0.25) : .clear
                btn.setTitleColor(sel ? .white : UIColor.white.withAlphaComponent(0.6), for: .normal)
                btn.layer.borderWidth = 1.5
                btn.layer.borderColor = sel ? UIColor.white.cgColor : UIColor.white.withAlphaComponent(0.25).cgColor
                btn.accessibilityHint = nil
            }
        }
    }

    private func updateSoundButton() {
        let effectiveOn = isSoundEnabled && !isAudioSuspendedBySpeed
        let icon = effectiveOn ? "speaker.wave.2.fill" : "speaker.slash.fill"
        let title = effectiveOn
            ? NSLocalizedString("overlay.sound", comment: "")
            : NSLocalizedString("overlay.sound.off", comment: "")
        soundButton.configuration?.image = UIImage(systemName: icon)
        soundButton.configuration?.title = title
        soundButton.configuration?.baseBackgroundColor = effectiveOn
            ? UIColor.white.withAlphaComponent(0.15)
            : UIColor.systemRed.withAlphaComponent(0.3)
    }

    // MARK: - Helpers

    private func addSpacer(height: CGFloat, to stack: UIStackView? = nil) {
        let spacer = UIView()
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        (stack ?? contentStack).addArrangedSubview(spacer)
    }

    // MARK: - Factory

    private static func makeButton(title: String, icon: String) -> UIButton {
        let btn = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = UIImage(systemName: icon)
        config.imagePadding = 8
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.15)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.titleLineBreakMode = .byTruncatingTail
        btn.configuration = config
        btn.titleLabel?.adjustsFontSizeToFitWidth = true
        btn.titleLabel?.minimumScaleFactor = 0.75
        btn.accessibilityLabel = title
        return btn
    }

}

/// Subtle gold→purple gradient used as the premium background for Pro-gated
/// UI in the pause overlay. The gradient is clipped to the view's rounded
/// corners via a sublayer mask (rather than clipping the whole view) so the
/// embedded ParticleEmitterView can emanate past the button bounds.
final class GradientBackgroundView: UIView {
    private let gradient = CAGradientLayer()
    private let gradientMask = CAShapeLayer()
    private let particles = ParticleEmitterView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        isUserInteractionEnabled = false
        clipsToBounds = false
        layer.masksToBounds = false

        gradient.colors = [
            UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 0.25).cgColor,
            UIColor(red: 0.45, green: 0.2, blue: 0.85, alpha: 0.22).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.mask = gradientMask
        layer.addSublayer(gradient)

        particles.translatesAutoresizingMaskIntoConstraints = false
        addSubview(particles)
        NSLayoutConstraint.activate([
            particles.topAnchor.constraint(equalTo: topAnchor),
            particles.bottomAnchor.constraint(equalTo: bottomAnchor),
            particles.leadingAnchor.constraint(equalTo: leadingAnchor),
            particles.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        gradientMask.frame = bounds
        gradientMask.path = UIBezierPath(roundedRect: bounds,
                                         cornerRadius: layer.cornerRadius).cgPath
    }
}
