//
//  OverlayMenuView.swift
//  EmulateurGBA
//
//  Translucent overlay shown when the player pauses the game.
//  Provides Resume, Save/Load slots, Speed selection, Screenshot, and Quit.
//

import UIKit
import CoreImage

/// Per-game screen-orientation preference, chosen in the pause menu.
/// `landscape`/`portrait` pin that orientation (and override the iOS portrait
/// lock, since the screen then supports only that orientation); `auto` rotates
/// freely with the device.
enum GameOrientationMode: String {
    case auto, landscape, portrait
}

protocol OverlayMenuDelegate: AnyObject {
    func overlayDidTapResume()
    func overlayDidSelectSpeed(_ multiplier: Double)
    func overlayDidSaveState(slot: Int)
    func overlayDidLoadState(slot: Int)
    func overlayDidTapRewind()
    func overlayDidTapQuit()
    func overlayDidTapLockedFeature(context: ProPromptContext)
    func overlayDidTapShareScreenshot()
    func overlayDidTapShareClip()
    func overlayDidTapCheats()
    func overlayDidToggleSound(enabled: Bool)
    func overlayDidToggleButtonLock(enabled: Bool)
    func overlayDidSelectOrientation(_ mode: GameOrientationMode)
    func overlayDidTapSkin()
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
        s.spacing = 10
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

    /// Set to true to hide the rewind button.
    ///
    /// Nothing sets it any more: rewind covers every console since 1.2.5, the DS
    /// included. Kept as the one switch that would hide the button if a console
    /// ever arrives without rewind, rather than deleted and reinvented.
    var rewindHidden = false {
        didSet { rewindButton.isHidden = rewindHidden }
    }

    private var isSoundEnabled = true

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
    /// Share a short looping "gif-style" clip of the last few seconds.
    /// `value:` gives a fallback until the `overlay.shareClip` key is added to
    /// the 10 Localizable.strings (follow-up; "Clip" reads in most of them).
    private let clipButton = OverlayMenuView.makeButton(
        title: NSLocalizedString("overlay.shareClip", value: "Clip", comment: "Pause menu: share a short looping gameplay clip"),
        icon: "film.fill")
    private let soundButton = OverlayMenuView.makeButton(
        title: NSLocalizedString("overlay.sound", comment: ""), icon: "speaker.wave.2.fill")
    /// Per-game "keep a button held" toggle (off by default). Its icon is a row
    /// of mini A/B (GBA/GB/GBC) or A/B/X/Y (NDS) buttons drawn to match the
    /// in-game look: un-pressed when the toggle is off, pressed when on, so the
    /// affected buttons and the on/off state are both legible at a glance.
    private let buttonLockButton = OverlayMenuView.makeButton(
        title: NSLocalizedString("overlay.buttonLock", comment: ""), icon: "pin.slash")
    private var buttonLockEnabled = false
    /// Opens the per-game Appearance sheet (skins; plus palettes/filters on the
    /// Screen tab for GB/GBC). Sits in the "occasionally-tapped options" row next
    /// to Sound + hold-to-lock. Renamed from the fixed-English "Skin" 2026-07-24:
    /// the button now governs more than the dress, so it carries the localized
    /// iOS-standard word (Appearance/Apparence).
    private let skinButton = OverlayMenuView.makeButton(
        title: NSLocalizedString("overlay.appearance", comment: "Pause-menu button opening the skin/palette/filter sheet"),
        icon: "paintpalette.fill")
    /// Which face buttons the hold-to-lock gesture affects, mirrored into the
    /// toggle icon and the caption. Set from the running console's own
    /// `TouchControlsView.lockableLetters`, so it cannot name a different set
    /// from the one the gesture acts on. A/B on GBA/GB/GBC/NES, A/B/X/Y on
    /// NDS and SNES.
    private var lockableLetters: [String] = ["A", "B"]
    /// One-line explanation of the non-obvious hold-to-lock gesture, shown under
    /// the toggle pair (the label alone can't convey what it does). Built as an
    /// attributed string so the mini buttons can be inlined into the text.
    private lazy var buttonLockCaption = makeCaptionLabel("")

    /// Per-game screen orientation as a pill row (Auto / Landscape / Portrait),
    /// styled identically to the Speed pills so the two selectors read alike.
    private let orientationStack: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 8
        s.distribution = .fillEqually
        return s
    }()
    private var orientationButtons: [UIButton] = []
    private var currentOrientationMode: GameOrientationMode = .auto
    private lazy var orientationLabel = makeSectionLabel(NSLocalizedString("overlay.orientation", comment: ""))
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

    /// Section header (Speed / Orientation / Quick-save slots). Uppercased in
    /// code so the casing stays uniform no matter how each locale's string is
    /// authored (the originals were typed in caps, "Orientation" was not).
    private func makeSectionLabel(_ text: String) -> UILabel {
        let l = makeCaptionLabel(text.localizedUppercase)
        l.numberOfLines = 1
        return l
    }

    /// Sentence-case helper text (the hold-to-lock caption). Same dim caption
    /// style as a section header but never uppercased, and free to wrap.
    private func makeCaptionLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.textColor = UIColor.white.withAlphaComponent(0.5)
        l.font = .preferredFont(forTextStyle: .caption1)
        l.textAlignment = .center
        l.numberOfLines = 0
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
        s.spacing = 8
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
            // Portrait pills are only ~33pt wide, too narrow for "0.25x" at the
            // footnote size, which truncated to "0...x". Scale the label down to
            // fit rather than truncate (only the widest value needs it).
            btn.titleLabel?.adjustsFontSizeToFitWidth = true
            btn.titleLabel?.minimumScaleFactor = 0.6
            btn.titleLabel?.lineBreakMode = .byClipping
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

        // Create orientation pills (same pill style as Speed)
        let orientationKeys = ["overlay.orientation.auto", "overlay.orientation.landscape", "overlay.orientation.portrait"]
        for (index, key) in orientationKeys.enumerated() {
            let btn = UIButton(type: .system)
            btn.setTitle(NSLocalizedString(key, comment: ""), for: .normal)
            btn.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
            btn.titleLabel?.adjustsFontSizeToFitWidth = true
            btn.titleLabel?.minimumScaleFactor = 0.7
            btn.layer.cornerRadius = 8
            btn.layer.borderWidth = 1.5
            btn.tag = index
            btn.addTarget(self, action: #selector(orientationTapped(_:)), for: .touchUpInside)
            orientationButtons.append(btn)
            orientationStack.addArrangedSubview(btn)
            btn.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }

        slotsWidthConstraint = slotsStack.widthAnchor.constraint(equalToConstant: 280)
        slotsWidthConstraint?.isActive = true

        // Wire actions
        resumeButton.addTarget(self, action: #selector(resumeTapped), for: .touchUpInside)
        rewindButton.addTarget(self, action: #selector(rewindTapped), for: .touchUpInside)
        screenshotButton.addTarget(self, action: #selector(screenshotTapped), for: .touchUpInside)
        cheatsButton.addTarget(self, action: #selector(cheatsTapped), for: .touchUpInside)
        clipButton.addTarget(self, action: #selector(clipTapped), for: .touchUpInside)
        soundButton.addTarget(self, action: #selector(soundTapped), for: .touchUpInside)
        buttonLockButton.addTarget(self, action: #selector(buttonLockTapped), for: .touchUpInside)
        skinButton.addTarget(self, action: #selector(skinTapped), for: .touchUpInside)
        quitButton.addTarget(self, action: #selector(quitTapped), for: .touchUpInside)
        // The premium styling in refreshProState() draws a border and a
        // purple shadow directly on the button's layer, so the layer needs
        // its own rounded corners and must not clip its shadow.
        cheatsButton.layer.cornerRadius = 10
        cheatsButton.layer.masksToBounds = false

        // Apply the initial selected/toggle styling so the pills and the
        // hold-to-lock toggle look right before the first showOverlay().
        updateOrientationHighlight()
        updateButtonLockButton()

        // Initial layout
        buildPortraitLayout()
        updateButtonLockCaption()
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

        // Detach everything, then rebuild the single vertical stack.
        leftColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rightColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        togglesRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Header + primary actions (full-width, single line for label clarity).
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(resumeButton)
        contentStack.addArrangedSubview(quitButton)

        // Secondary actions in one compact row; Rewind would collapse out if
        // `rewindHidden` were ever set, which nothing does since 1.2.5.
        actionRow.addArrangedSubview(rewindButton)
        actionRow.addArrangedSubview(screenshotButton)
        actionRow.addArrangedSubview(clipButton)
        actionRow.addArrangedSubview(cheatsButton)
        contentStack.addArrangedSubview(actionRow)
        for btn in [quitButton, resumeButton] { setActionButtonCompact(btn, false) }
        for btn in [rewindButton, screenshotButton, clipButton, cheatsButton] { setActionButtonCompact(btn, true) }

        addSpacer(height: 4, to: contentStack)
        contentStack.addArrangedSubview(speedLabel)
        contentStack.addArrangedSubview(speedStack)
        addSpacer(height: 4, to: contentStack)
        contentStack.addArrangedSubview(orientationLabel)
        contentStack.addArrangedSubview(orientationStack)
        addSpacer(height: 4, to: contentStack)

        // Per-game "occasionally-tapped options" row: Sound + hold-to-lock + Skin, side by
        // side (fillEqually splits the fixed row width 3 ways now), with the lock's
        // explanatory caption beneath.
        togglesRow.addArrangedSubview(soundButton)
        togglesRow.addArrangedSubview(buttonLockButton)
        togglesRow.addArrangedSubview(skinButton)
        for btn in [soundButton, buttonLockButton, skinButton] { setActionButtonCompact(btn, true) }
        contentStack.addArrangedSubview(togglesRow)
        contentStack.addArrangedSubview(buttonLockCaption)
        addSpacer(height: 4, to: contentStack)

        contentStack.addArrangedSubview(saveLoadLabel)
        contentStack.addArrangedSubview(slotsStack)

        // Sizes: full-width primaries, fixed-width rows, taller compact action
        // cells so the wrapped two-line labels are not clipped. 280pt matches
        // the slots width (proven safe down to the 375pt-wide iPhone SE).
        let w: CGFloat = 280
        for btn in [quitButton, resumeButton] {
            layoutConstraints.append(btn.widthAnchor.constraint(equalToConstant: w))
            layoutConstraints.append(btn.heightAnchor.constraint(equalToConstant: 46))
        }
        for stack in [actionRow, togglesRow, speedStack, orientationStack] {
            layoutConstraints.append(stack.widthAnchor.constraint(equalToConstant: w))
        }
        for btn in [rewindButton, screenshotButton, clipButton, cheatsButton] {
            layoutConstraints.append(btn.heightAnchor.constraint(equalToConstant: 62))
        }
        for btn in [soundButton, buttonLockButton, skinButton] {
            layoutConstraints.append(btn.heightAnchor.constraint(equalToConstant: 56))
        }
        layoutConstraints.append(buttonLockCaption.widthAnchor.constraint(equalToConstant: w))
        NSLayoutConstraint.activate(layoutConstraints)
        slotsWidthConstraint?.constant = 280
    }

    /// Secondary actions in one compact row (Rewind / Screenshot / Clip / Cheats).
    /// Every console shows all four since 1.2.5; `rewindHidden` would collapse
    /// Rewind out of this fill-equally row, and nothing sets it.
    private let actionRow: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 8
        s.distribution = .fillEqually
        s.alignment = .fill
        return s
    }()

    /// The two per-game toggles (Sound + hold-to-lock) side by side.
    private let togglesRow: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 8
        s.distribution = .fillEqually
        s.alignment = .fill
        return s
    }()

    private func buildLandscapeLayout() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints.removeAll()

        contentStack.isHidden = true
        landscapeContainer.isHidden = false

        // Detach everything from both layouts before rebuilding the columns.
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        leftColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rightColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        togglesRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Left column mirrors portrait: header, primary actions, then the
        // per-game settings (Speed pills, Orientation pills, the toggles).
        // Resume is always the full-width primary; the action row holds the
        // secondary actions, with Rewind collapsing out only if `rewindHidden`.
        leftColumn.addArrangedSubview(titleLabel)
        leftColumn.addArrangedSubview(resumeButton)
        leftColumn.addArrangedSubview(quitButton)

        actionRow.addArrangedSubview(rewindButton)
        actionRow.addArrangedSubview(screenshotButton)
        actionRow.addArrangedSubview(clipButton)
        actionRow.addArrangedSubview(cheatsButton)
        leftColumn.addArrangedSubview(actionRow)
        for b in [quitButton, resumeButton] { setActionButtonCompact(b, false) }
        for b in [rewindButton, screenshotButton, clipButton, cheatsButton] { setActionButtonCompact(b, true) }

        addSpacer(height: 4, to: leftColumn)
        leftColumn.addArrangedSubview(speedLabel)
        leftColumn.addArrangedSubview(speedStack)
        addSpacer(height: 4, to: leftColumn)
        leftColumn.addArrangedSubview(orientationLabel)
        leftColumn.addArrangedSubview(orientationStack)
        addSpacer(height: 4, to: leftColumn)

        togglesRow.addArrangedSubview(soundButton)
        togglesRow.addArrangedSubview(buttonLockButton)
        togglesRow.addArrangedSubview(skinButton)
        for b in [soundButton, buttonLockButton, skinButton] { setActionButtonCompact(b, true) }
        leftColumn.addArrangedSubview(togglesRow)
        leftColumn.addArrangedSubview(buttonLockCaption)

        // Right column: save slots only, with room for all five.
        rightColumn.addArrangedSubview(saveLoadLabel)
        rightColumn.addArrangedSubview(slotsStack)

        // Sizes for landscape
        let fullW: CGFloat = 320
        let btnH: CGFloat = 40
        for btn in [quitButton, resumeButton] {
            layoutConstraints.append(btn.widthAnchor.constraint(equalToConstant: fullW))
            layoutConstraints.append(btn.heightAnchor.constraint(equalToConstant: btnH))
        }
        for stack in [actionRow, togglesRow, speedStack, orientationStack] {
            layoutConstraints.append(stack.widthAnchor.constraint(equalToConstant: fullW))
        }
        for btn in [rewindButton, screenshotButton, clipButton, cheatsButton] {
            layoutConstraints.append(btn.heightAnchor.constraint(equalToConstant: 58))
        }
        for btn in [soundButton, buttonLockButton, skinButton] {
            layoutConstraints.append(btn.heightAnchor.constraint(equalToConstant: 52))
        }
        layoutConstraints.append(buttonLockCaption.widthAnchor.constraint(equalToConstant: fullW))
        NSLayoutConstraint.activate(layoutConstraints)
        slotsWidthConstraint?.constant = 320
    }

    /// Compact "tile" style for the narrow action/toggle cells: icon stacked
    /// on top of a wrapping label, so the full localized label gets the whole
    /// cell width (icon-beside-text left it too narrow and wrapped to 3-4 lines).
    /// Passing `compact = false` restores the roomy single-line icon-beside
    /// style (full-width Resume/Quit), so a rotation back is clean.
    private func setActionButtonCompact(_ btn: UIButton, _ compact: Bool) {
        guard var config = btn.configuration else { return }
        if compact {
            // Icon ON TOP of the label (tile style). Labels are localized to a
            // single word (see Localizable.strings) on ONE line, so four tiles
            // fit one row on GBA; the auto-shrink below handles the few longer-
            // word locales (e.g. "Screenshot", "Skärmbild") by scaling just them.
            config.imagePlacement = .top
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            config.imagePadding = 4
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
            config.titleLineBreakMode = .byTruncatingTail
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .systemFont(ofSize: 12, weight: .medium)
                return out
            }
            // One line so the auto-shrink from makeButton applies (UIKit only
            // scales single-line labels); shrinks only labels that don't fit.
            btn.titleLabel?.numberOfLines = 1
            btn.titleLabel?.adjustsFontSizeToFitWidth = true
            btn.titleLabel?.minimumScaleFactor = 0.6
            btn.titleLabel?.textAlignment = .center
        } else {
            config.imagePlacement = .leading
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

    /// Reflect the per-game hold-to-lock preference (set by the VC when the menu opens).
    func setButtonLockEnabled(_ enabled: Bool) {
        buttonLockEnabled = enabled
        updateButtonLockButton()
    }

    /// Tell the menu which face buttons hold-to-lock affects, so the toggle icon
    /// and caption show the right set. A/B for GBA/GB/GBC; A/B/X/Y for NDS.
    /// The letters come from `TouchControlsView.lockableLetters`, which derives
    /// them from the mask the gesture actually uses. Pass them; do not recompute
    /// them here, or the menu can once again describe a lock the console does
    /// not have (or omit one it does).
    func setLockableButtons(_ letters: [String]) {
        lockableLetters = letters.isEmpty ? ["A", "B"] : letters
        updateButtonLockButton()
        updateButtonLockCaption()
    }

    func refreshProState() {
        let isPro = UserDefaults.standard.bool(forKey: "isPro")
        updateSpeedHighlight()
        let rewindSeconds = isPro ? "30" : "5"
        rewindButton.configuration?.title = String(format: NSLocalizedString("overlay.rewind", comment: ""), rewindSeconds)
        // Cheats: subtle gold→purple premium border + faint fill when free,
        // plain fill when Pro. No lock icon — the gentle gold border tempts a
        // player who sees this many times, where a lock would only frustrate.
        applyPremiumStyle(to: cheatsButton, active: !isPro)
        cheatsButton.accessibilityHint = isPro ? nil : NSLocalizedString("pro.badge", comment: "")
    }

    /// Applies the premium visual signature to a Pro-gated UI element: a faint
    /// gold→purple fill, the gold→purple hairline gradient *border* shared with
    /// the Settings Pro card and the Pro sheet, and a soft purple glow.
    /// `particles` adds the slow luxury dust (on the roomy cheats tile + save
    /// slots; off for the tiny, busy speed pills). Kept deliberately light so
    /// the shift to premium is a gentle temptation rather than a loud paywall.
    ///
    /// Idempotent: repeated calls with the same `active` value leave the
    /// existing GradientBackgroundView (and its particle emitter state) in
    /// place. This matters because updateSpeedHighlight runs on every speed
    /// change — without this guard, every locked speed's emitter would
    /// reset on each tap, causing a visible particle-position jump.
    private func applyPremiumStyle(to view: UIView, active: Bool, particles: Bool = true) {
        let purple = UIColor(red: 0.45, green: 0.2, blue: 0.85, alpha: 1.0)

        if let btn = view as? UIButton, var config = btn.configuration {
            let hasGradient = config.background.customView is GradientBackgroundView
            if active && !hasGradient {
                let bg = GradientBackgroundView(showsParticles: particles)
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
                let bg = GradientBackgroundView(showsParticles: particles)
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
            view.layer.shadowOpacity = 0.3
            view.layer.shadowRadius = 6
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
            // Drop the white-8% fill so the gradient view shows as-designed. No
            // lock icon — the gentle gold border invites Pro, where a lock would
            // make the slot read as disabled and frustrating.
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
    @objc private func clipTapped() { delegate?.overlayDidTapShareClip() }
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

    @objc private func buttonLockTapped() {
        buttonLockEnabled.toggle()
        updateButtonLockButton()
        delegate?.overlayDidToggleButtonLock(enabled: buttonLockEnabled)
    }

    @objc private func skinTapped() { delegate?.overlayDidTapSkin() }

    /// Sets the Skin button's icon to the running game's console glyph (the same
    /// console-<system> art used in the library stats). Rendered like the Retro Pal brand
    /// component on the Nostalgia skins — a monochrome duotone that KEEPS the image's detail
    /// but in a single hue, here the menu-icon colour (white) — instead of a flat silhouette.
    func setSkinIcon(_ image: UIImage?) {
        guard let image else { return }   // keep the SF fallback if no console art
        let tinted = Self.monochrome(image, color: .white) ?? image
        skinButton.configuration?.image = Self.resized(tinted, maxWidth: 30, maxHeight: 22)
            .withRenderingMode(.alwaysOriginal)   // carry the duotone shading, don't re-tint
    }

    private static let ciContext = CIContext(options: nil)

    /// Monochrome duotone of `image` in `color`, preserving luminance detail — the same
    /// CIColorMonochrome treatment the console dresses use for the Retro Pal brand mark.
    private static func monochrome(_ image: UIImage, color: UIColor) -> UIImage? {
        guard let ci = CIImage(image: image) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        guard let f = CIFilter(name: "CIColorMonochrome", parameters: [
            kCIInputImageKey: ci,
            "inputColor": CIColor(red: r, green: g, blue: b),
            "inputIntensity": 1.0,
        ]), let out = f.outputImage,
            let cg = ciContext.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Aspect-fits `image` into a small icon box (raster console art has no point-size,
    /// unlike an SF Symbol, so it must be resized before sitting in the compact tile).
    private static func resized(_ image: UIImage, maxWidth: CGFloat, maxHeight: CGFloat) -> UIImage {
        guard image.size.width > 0, image.size.height > 0 else { return image }
        let s = min(maxWidth / image.size.width, maxHeight / image.size.height)
        let target = CGSize(width: image.size.width * s, height: image.size.height * s)
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Icon = a row of mini face buttons drawn like the in-game controls,
    /// pressed when the toggle is on. The brighter tile background reinforces the
    /// on state, matching the Sound toggle's treatment.
    private func updateButtonLockButton() {
        // Match the mini buttons inlined in the caption below the row (diameter 16,
        // spacing 3) so the in-button A/B(/X/Y) glyphs are not oversized — for every
        // console (A/B on GBA/GB/GBC/NES, A/B/X/Y on NDS and SNES).
        let row = miniButtonRowImage(letters: lockableLetters, pressed: buttonLockEnabled,
                                     diameter: 16, spacing: 3)
        buttonLockButton.configuration?.image = row.withRenderingMode(.alwaysOriginal)
        buttonLockButton.configuration?.baseBackgroundColor = buttonLockEnabled
            ? UIColor.white.withAlphaComponent(0.28)
            : UIColor.white.withAlphaComponent(0.15)
    }

    /// Rebuild the caption with the affected buttons inlined into the localized
    /// sentence (the `%@` token marks where the mini-button row goes).
    private func updateButtonLockCaption() {
        let format = NSLocalizedString("overlay.buttonLock.caption", comment: "")
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.5)
        ]
        let row = miniButtonRowImage(letters: lockableLetters, pressed: false, diameter: 16, spacing: 3)
            .withRenderingMode(.alwaysOriginal)
        let result = NSMutableAttributedString()
        let parts = format.components(separatedBy: "%@")
        for (index, part) in parts.enumerated() {
            result.append(NSAttributedString(string: part, attributes: baseAttrs))
            guard index < parts.count - 1 else { continue }
            let attachment = NSTextAttachment()
            attachment.image = row
            attachment.bounds = CGRect(
                x: 0, y: (font.capHeight - row.size.height) / 2,
                width: row.size.width, height: row.size.height)
            result.append(NSAttributedString(attachment: attachment))
        }
        buttonLockCaption.attributedText = result
        // The inlined image reads poorly under VoiceOver; give it plain text.
        buttonLockCaption.accessibilityLabel = format.replacingOccurrences(
            of: "%@", with: lockableLetters.joined(separator: " "))
    }

    /// Draws a horizontal row of mini face buttons that match the in-game
    /// ActionButton look (translucent white circle + bold white letter), used as
    /// the hold-to-lock toggle icon and inlined into its caption. `pressed`
    /// mirrors the in-game pressed treatment (brighter fill + border).
    private func miniButtonRowImage(letters: [String], pressed: Bool,
                                    diameter: CGFloat, spacing: CGFloat = 4) -> UIImage {
        let lineWidth: CGFloat = diameter < 20 ? 1.0 : 1.5
        let count = CGFloat(letters.count)
        let size = CGSize(width: count * diameter + max(0, count - 1) * spacing, height: diameter)
        let fill = UIColor.white.withAlphaComponent(pressed ? 0.55 : 0.2)
        let stroke = UIColor.white.withAlphaComponent(pressed ? 0.8 : 0.45)
        let font = UIFont.systemFont(ofSize: diameter * 0.52, weight: .bold)

        return UIGraphicsImageRenderer(size: size).image { _ in
            for (i, letter) in letters.enumerated() {
                let x = CGFloat(i) * (diameter + spacing)
                let rect = CGRect(x: x + lineWidth / 2, y: lineWidth / 2,
                                  width: diameter - lineWidth, height: diameter - lineWidth)
                let circle = UIBezierPath(ovalIn: rect)
                fill.setFill(); circle.fill()
                stroke.setStroke(); circle.lineWidth = lineWidth; circle.stroke()

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: UIColor.white]
                let glyph = letter as NSString
                let textSize = glyph.size(withAttributes: attrs)
                glyph.draw(in: CGRect(x: x + (diameter - textSize.width) / 2,
                                      y: (diameter - textSize.height) / 2,
                                      width: textSize.width, height: textSize.height),
                           withAttributes: attrs)
            }
        }
    }

    /// Reflect the per-game orientation preference (set by the VC when the menu opens).
    func setOrientationMode(_ mode: GameOrientationMode) {
        currentOrientationMode = mode
        updateOrientationHighlight()
    }

    @objc private func orientationTapped(_ sender: UIButton) {
        currentOrientationMode = Self.mode(forSegment: sender.tag)
        updateOrientationHighlight()
        delegate?.overlayDidSelectOrientation(currentOrientationMode)
    }

    /// Highlight the selected orientation pill exactly like the selected Speed
    /// pill (white fill + white border + white text; dim otherwise).
    private func updateOrientationHighlight() {
        let selected = Self.segmentIndex(for: currentOrientationMode)
        for (index, btn) in orientationButtons.enumerated() {
            let sel = index == selected
            btn.backgroundColor = sel ? UIColor.white.withAlphaComponent(0.25) : .clear
            btn.setTitleColor(sel ? .white : UIColor.white.withAlphaComponent(0.6), for: .normal)
            btn.layer.borderColor = sel ? UIColor.white.cgColor : UIColor.white.withAlphaComponent(0.25).cgColor
        }
    }

    private static func segmentIndex(for mode: GameOrientationMode) -> Int {
        switch mode { case .auto: return 0; case .landscape: return 1; case .portrait: return 2 }
    }
    private static func mode(forSegment index: Int) -> GameOrientationMode {
        switch index { case 1: return .landscape; case 2: return .portrait; default: return .auto }
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
        Analytics.signal("speed_changed", ["speed": String(speed)])
        // Pro speeds are anything outside the free 1x / 1.5x set; reaching here
        // with one means the user is Pro (the gate above returns otherwise).
        if !Self.freeSpeeds.contains(speed) {
            Analytics.signal("pro_feature_used", ["feature": "speed"])
        }
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
                // Same Pro family as the cheats tile / locked slots: gold→purple
                // hairline border + faint fill + soft glow. Text stays the same
                // dimmed white as an unselected free pill so the whole row reads
                // as one set. No particles (five pills with drifting dust would
                // be noise) and no lock icon (it would frustrate the player who
                // sees this often, where the gentle border tempts instead).
                btn.backgroundColor = .clear
                btn.setTitleColor(UIColor.white.withAlphaComponent(0.6), for: .normal)
                applyPremiumStyle(to: btn, active: true, particles: false)
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
        // Sound is controllable at every speed now (no speed-based suspension),
        // so the button reflects only the user's mute state. The title stays
        // "Son" so it fits the half-width toggle chip; the muted state is carried
        // by the slashed icon + red tint, with the off label surfaced to VoiceOver.
        let muted = !isSoundEnabled
        soundButton.configuration?.image = UIImage(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        soundButton.configuration?.title = NSLocalizedString("overlay.sound", comment: "")
        soundButton.configuration?.baseBackgroundColor = muted
            ? UIColor.systemRed.withAlphaComponent(0.3)
            : UIColor.white.withAlphaComponent(0.15)
        soundButton.accessibilityValue = muted
            ? NSLocalizedString("overlay.sound.off", comment: "")
            : nil
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

/// The premium surface for Pro-gated UI in the pause overlay: a faint gold→
/// purple fill plus the gold→purple hairline gradient *border* that is the
/// shared signature of the Settings Pro card and the Pro sheet, so a locked
/// pause feature reads as the same family. Both gradients are clipped to the
/// view's rounded corners via sublayer masks (rather than clipping the whole
/// view) so the optional ParticleEmitterView can emanate past the bounds.
final class GradientBackgroundView: UIView {
    private let gradient = CAGradientLayer()
    private let gradientMask = CAShapeLayer()
    private let border = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    private var particles: ParticleEmitterView?
    private let borderWidth: CGFloat = 1.2

    /// `showsParticles` adds the slow luxury dust. On for the roomy cheats tile
    /// and save slots; off for the tiny speed pills, where it would be noise.
    init(showsParticles: Bool = true) {
        super.init(frame: .zero)
        setup(showsParticles: showsParticles)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup(showsParticles: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup(showsParticles: Bool) {
        isUserInteractionEnabled = false
        clipsToBounds = false
        layer.masksToBounds = false

        // Faint warm tint — much gentler than a paywall fill.
        gradient.colors = [
            UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 0.12).cgColor,
            UIColor(red: 0.45, green: 0.2, blue: 0.85, alpha: 0.10).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.mask = gradientMask
        layer.addSublayer(gradient)

        // The signature gold→purple hairline border (matches the Pro card/sheet).
        border.colors = [
            UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 0.85).cgColor,
            UIColor(red: 0.45, green: 0.2, blue: 0.85, alpha: 0.85).cgColor
        ]
        border.startPoint = CGPoint(x: 0, y: 0)
        border.endPoint = CGPoint(x: 1, y: 1)
        borderMask.fillColor = UIColor.clear.cgColor
        borderMask.strokeColor = UIColor.white.cgColor
        borderMask.lineWidth = borderWidth
        border.mask = borderMask
        layer.addSublayer(border)

        if showsParticles {
            let p = ParticleEmitterView()
            p.alpha = 0.45
            p.translatesAutoresizingMaskIntoConstraints = false
            addSubview(p)
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: topAnchor),
                p.bottomAnchor.constraint(equalTo: bottomAnchor),
                p.leadingAnchor.constraint(equalTo: leadingAnchor),
                p.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            particles = p
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = layer.cornerRadius
        gradient.frame = bounds
        gradientMask.frame = bounds
        gradientMask.path = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath

        // Inset the stroked path by half the line width so the border sits fully
        // inside the bounds rather than being clipped in half at the edge.
        border.frame = bounds
        borderMask.frame = bounds
        let inset = borderWidth / 2
        borderMask.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerRadius: max(0, radius - inset)).cgPath
    }
}
