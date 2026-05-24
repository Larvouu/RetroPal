//
//  EmulatorViewController.swift
//  EmulateurGBA
//
//  UIKit view controller for the active emulator session.
//  Manages Metal display, touch controls, overlay menu, and emulation lifecycle.
//

import UIKit
import MetalKit
import SwiftUI
import StoreKit
import Photos

final class EmulatorViewController: UIViewController, TouchControlsDelegate, OverlayMenuDelegate, UIAdaptivePresentationControllerDelegate, NDSTouchOverlayDelegate {
    private let session: EmulatorSession
    private let romURL: URL
    private var metalView: EmulatorMetalView!
    private let controls: TouchControlsView
    private let overlay = OverlayMenuView()
    private var ndsTouchOverlay: NDSTouchOverlay?

    private var currentSpeed: Double {
        get { _currentSpeed }
        set {
            _currentSpeed = newValue
            let key = "speed_\(romURL.deletingPathExtension().lastPathComponent)"
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
    private var _currentSpeed: Double = 1.0

    /// Tracks active play time (excludes paused/overlay time).
    /// Reset on each resume, accumulated into `accumulatedPlaySeconds`.
    private var lastResumeTime = Date()
    private var accumulatedPlaySeconds: TimeInterval = 0

    /// Slot to load immediately after ROM loads (nil = fresh start)
    var loadSlotOnStart: Int?

    /// User-facing display name (post-rename). Used for the screenshot share card
    /// so a renamed game shows the user's chosen title, not the raw ROM filename.
    /// Falls back to the filename when nil.
    var gameTitle: String?

    /// Called when the user quits to library
    var onQuit: (() -> Void)?

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    #if DEBUG
    // In-game translation feature (Phase 1: battle-screen species overlay).
    // DEBUG-only — the whole feature is stripped from release builds.

    /// Positioned overlay drawing translated species names over the battle UI.
    private let battleOverlayView = BattleOverlayView()
    /// Text readout: per-battler species + move names (move overlay is Phase 1b).
    private let translationDebugLabel: UILabel = {
        let label = UILabel()
        label.textColor = .systemGreen
        label.textAlignment = .left
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.numberOfLines = 0
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    private var translationProbe: TranslationProbe?
    private var translationTimer: Timer?
    #endif

    init(romURL: URL, session: EmulatorSession) {
        self.romURL = romURL
        self.session = session
        self.controls = session.hasTouchScreen ? NDSTouchControlsView() : TouchControlsView()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Metal view — frame set manually in viewDidLayoutSubviews (not Auto Layout)
        metalView = EmulatorMetalView(frame: .zero, device: nil)
        metalView.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(metalView)

        // Touch controls overlay
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.delegate = self
        controls.onMenuTap = { [weak self] in self?.showOverlay() }
        view.addSubview(controls)

        // NDS touch screen overlay (placed over the bottom screen area)
        // Insert above metalView but below controls so it doesn't steal button touches
        if session.hasTouchScreen {
            let touchOverlay = NDSTouchOverlay()
            touchOverlay.delegate = self
            touchOverlay.translatesAutoresizingMaskIntoConstraints = true
            view.insertSubview(touchOverlay, aboveSubview: metalView)
            ndsTouchOverlay = touchOverlay
        }

        // Pause overlay (hidden initially)
        overlay.rewindHidden = session.hasTouchScreen  // No rewind for NDS
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.delegate = self
        overlay.isHidden = true
        view.addSubview(overlay)

        setupController()

        // Status label
        view.addSubview(statusLabel)

        #if DEBUG
        battleOverlayView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(battleOverlayView, aboveSubview: metalView)
        view.addSubview(translationDebugLabel)
        #endif

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Overlay covers full screen
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        #if DEBUG
        NSLayoutConstraint.activate([
            battleOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
            battleOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            battleOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            battleOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            translationDebugLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            translationDebugLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            translationDebugLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])
        #endif

        // Swipe down to pause (alternative to menu button)
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(swipeDownToPause))
        swipeDown.direction = .down
        swipeDown.numberOfTouchesRequired = 2
        swipeDown.delaysTouchesEnded = false
        view.addGestureRecognizer(swipeDown)

        registerLifecycleObservers()
        loadAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        metalView.stopRendering()
        session.pause()
        NotificationCenter.default.removeObserver(self)
        #if DEBUG
        stopTranslationProbe()
        #endif
    }

    // MARK: - App Lifecycle

    private var hasShownScreenshotPopupThisSession = false

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default
        // System screenshot detection
        nc.addObserver(self, selector: #selector(userDidTakeScreenshot),
                       name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillResignActive),
                       name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func appWillResignActive() {
        // Triggered by: app going to background, incoming call, Control Center, etc.
        // Pause immediately to stop rendering and audio.
        guard session.isRunning else { return }
        accumulatedPlaySeconds += Date().timeIntervalSince(lastResumeTime)
        persistPlayTime()  // Save now in case app is force-quit before didEnterBackground
        session.pause()
        metalView.stopRendering()
    }

    @objc private func appDidEnterBackground() {
        guard session.isROMLoaded else { return }
        persistPlayTime()
        // Snapshot the full machine state (captures live, unsynced save RAM)...
        _ = session.autoSave()
        // ...and force the battery save itself to disk, so a fresh boot after
        // an iOS kill also sees the latest in-game progress. iOS only kills a
        // suspended app, and didEnterBackground always fires first, so this is
        // the guaranteed pre-kill persistence point. The emulator is already
        // paused (appWillResignActive), so the flush has no concurrent frame.
        session.flushBatterySave()
    }

    @objc private func appDidBecomeActive() {
        // Resume whenever the game screen is the live foreground content. Decided
        // purely from current state (see resumeGameplayIfForeground) rather than a
        // "was running before backgrounding" flag, so it also recovers the case
        // where a share/activity sheet had already paused the game before the app
        // was backgrounded mid-share, then dismissed off-screen on the way back.
        resumeGameplayIfForeground()
    }

    /// Resume gameplay only when the emulator screen is the live foreground
    /// content: app active, no sheet or alert presented, not sitting in the pause
    /// menu, and a ROM loaded but currently paused. Idempotent and safe to call
    /// from any path (becoming active, share-sheet completion) — it no-ops unless
    /// the game *should* be running, so it can never fight the pause menu or a
    /// modal that is intentionally holding the game paused.
    private func resumeGameplayIfForeground() {
        guard UIApplication.shared.applicationState == .active,
              presentedViewController == nil,
              overlay.isHidden,
              session.isROMLoaded,
              !session.isRunning else { return }
        session.resume()
        metalView.startRendering()
        lastResumeTime = Date()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutGameView()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    /// Full-screen emulator: claim the screen-edge touch zones the system would
    /// otherwise reserve. With the status bar hidden, iOS keeps a thin band at the
    /// top edge for its status-bar / Notification-Center reveal gesture, swallowing
    /// touches that begin there. In landscape the NDS bottom screen is rendered
    /// flush against that top edge (y = 0), so its top row of touch targets (e.g.
    /// the HG/SS bag category icons) became untappable. Deferring the system
    /// gestures routes those edge touches to the game instead. The system UI still
    /// reveals on a second, deliberate swipe.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    @objc private func swipeDownToPause() {
        guard overlay.isHidden else { return }
        showOverlay()
    }

    // MARK: - Overlay

    private func showOverlay() {
        session.pause()
        metalView.stopRendering()
        overlay.setCurrentSpeed(currentSpeed)
        overlay.setSoundEnabled(!session.isAudioMuted)
        overlay.isAudioSuspendedBySpeed = currentSpeed > 2.0
        overlay.refreshProState()
        overlay.isHidden = false
        updateControlsVisibility()

        // Load slot info off main thread to avoid hang
        if let manager = session.saveStateManager {
            DispatchQueue.global(qos: .userInitiated).async {
                let slots = manager.allManualSlotsWithLockState()
                DispatchQueue.main.async { [weak self] in
                    self?.overlay.updateSlots(slots)
                }
            }
        }

        // Accumulate active play time since last resume
        accumulatedPlaySeconds += Date().timeIntervalSince(lastResumeTime)

        // Check contextual Pro triggers (returns true if a Pro sheet will show)
        let proWillShow = checkProTriggers()

        // Check App Store review prompt (only if no Pro sheet is coming)
        if !proWillShow {
            checkReviewPrompt()
        }
    }

    private func hideOverlay() {
        overlay.isHidden = true
        updateControlsVisibility()
        session.resume()
        metalView.startRendering()
        lastResumeTime = Date()
    }

    // MARK: - OverlayMenuDelegate

    func overlayDidTapResume() {
        hideOverlay()
    }

    func overlayDidSelectSpeed(_ multiplier: Double) {
        currentSpeed = multiplier
        metalView.speedMultiplier = multiplier
        overlay.isAudioSuspendedBySpeed = multiplier > 2.0
    }

    func overlayDidSaveState(slot: Int) {
        // Check if slot already has data — confirm overwrite
        if let manager = session.saveStateManager {
            let info = manager.slotInfo(slot: slot)
            if info.exists {
                let alert = UIAlertController(
                    title: String(format: NSLocalizedString("overlay.overwrite.title", comment: ""), "\(slot)"),
                    message: NSLocalizedString("overlay.overwrite.message", comment: ""),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: NSLocalizedString("common.cancel", comment: ""), style: .cancel))
                alert.addAction(UIAlertAction(title: NSLocalizedString("overlay.overwrite", comment: ""), style: .destructive) { [weak self] _ in
                    self?.performSave(slot: slot)
                })
                present(alert, animated: true)
                return
            }
        }
        performSave(slot: slot)
    }

    private func performSave(slot: Int) {
        let isPro = UserDefaults.standard.bool(forKey: "isPro")
        // Gate Pro slots. Only use .saveSlotFull when the free slots are
        // actually full — otherwise the sheet's copy would lie.
        if slot > SaveStateManager.freeSlotCount && !isPro {
            let ctx: ProPromptContext
            if let manager = session.saveStateManager {
                let freeSlots = manager.allManualSlotsWithLockState().prefix(SaveStateManager.freeSlotCount)
                let allFreeFull = freeSlots.count == SaveStateManager.freeSlotCount
                    && freeSlots.allSatisfy { $0.info.exists }
                ctx = allFreeFull ? .saveSlotFull : .saveSlotTapped
            } else {
                ctx = .saveSlotTapped
            }
            overlayDidTapLockedFeature(context: ctx)
            return
        }
        let success = session.saveState(slot: slot)
        if success, let manager = session.saveStateManager {
            DispatchQueue.global(qos: .userInitiated).async {
                let slots = manager.allManualSlotsWithLockState()
                DispatchQueue.main.async { [weak self] in
                    self?.overlay.updateSlots(slots)

                    // Trigger 2: Save slot full — all free slots used
                    if !isPro {
                        let freeSlots = slots.prefix(SaveStateManager.freeSlotCount)
                        let allFull = freeSlots.allSatisfy { $0.info.exists }
                        if allFull && PromptTracker.shared.shouldShowSaveSlotFull() {
                            self?.showProSheet(context: .saveSlotFull)
                        }
                    }
                }
            }
        }
    }

    func overlayDidLoadState(slot: Int) {
        let alert = UIAlertController(
            title: String(format: NSLocalizedString("overlay.load.confirm.title", comment: ""), "\(slot)"),
            message: NSLocalizedString("overlay.load.confirm.message", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("common.cancel", comment: ""), style: .cancel))
        alert.addAction(UIAlertAction(title: NSLocalizedString("overlay.load", comment: ""), style: .destructive) { [weak self] _ in
            self?.performLoad(slot: slot)
        })
        present(alert, animated: true)
    }

    private func performLoad(slot: Int) {
        let success = session.loadState(slot: slot)
        if success {
            hideOverlay()
        }
    }


    func overlayDidTapRewind() {
        let isPro = UserDefaults.standard.bool(forKey: "isPro")
        let maxSeconds = isPro ? 30 : 5
        let playedSeconds = Int(Date().timeIntervalSince(lastResumeTime) + accumulatedPlaySeconds)
        let actualSeconds = min(maxSeconds, max(1, playedSeconds - 1))
        let frames = actualSeconds * 60
        let success = session.rewind(frames: frames)
        hideOverlay()

        // Trigger 4: Rewind limit — if free user rewound max 5s, hint at 30s.
        // Only fires after several max-rewinds (tracked in PromptTracker),
        // not on the first tap, to avoid feeling aggressive.
        if !isPro && actualSeconds >= 5 && success {
            PromptTracker.shared.recordMaxRewind()
            if PromptTracker.shared.shouldShowRewindLimit() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.showProSheet(context: .rewindLimit)
                }
            }
        }
    }

    func overlayDidTapLockedFeature(context: ProPromptContext) {
        showProSheet(context: context)
    }

    private func showProSheet(context: ProPromptContext) {
        let vc = ProUpgradeHostingController(context: context) { [weak self] in
            guard let self else { return }
            self.overlay.refreshProState()
            if let manager = self.session.saveStateManager {
                DispatchQueue.global(qos: .userInitiated).async {
                    let slots = manager.allManualSlotsWithLockState()
                    DispatchQueue.main.async {
                        self.overlay.updateSlots(slots)
                    }
                }
            }
        }
        present(vc, animated: true)
        if context != .tappedLockedFeature {
            PromptTracker.shared.recordPromptShown()
        }
    }

    /// Check contextual triggers when overlay opens (after gameplay pause).
    /// Returns true if a Pro sheet will be presented (even if async).
    @discardableResult
    private func checkProTriggers() -> Bool {
        let isPro = UserDefaults.standard.bool(forKey: "isPro")
        guard !isPro else { return false }

        let playSeconds = Date().timeIntervalSince(lastResumeTime) + accumulatedPlaySeconds
        let tracker = PromptTracker.shared

        // Trigger 1: Speed moment (30+ min at free speed)
        if tracker.shouldShowSpeedMoment(sessionPlaySeconds: playSeconds) {
            tracker.markSpeedMomentShown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showProSheet(context: .speedMoment(minutesAtFreeSpeed: Int(playSeconds / 60)))
            }
            return true
        }

        // Trigger 3: Session milestone (1+ hour total)
        if tracker.shouldShowSessionMilestone() {
            tracker.markSessionMilestoneShown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                let totalMin = Int(tracker.totalPlaySeconds / 60)
                self?.showProSheet(context: .sessionMilestone(totalMinutes: totalMin))
            }
            return true
        }

        // Trigger 5: Cheat codes (4+ hours on the same game)
        let gameName = romURL.deletingPathExtension().lastPathComponent
        if tracker.shouldShowCheatCodes(romName: gameName) {
            tracker.markCheatCodesShown(romName: gameName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showProSheet(context: .cheatCodes(gameName: gameName))
            }
            return true
        }

        return false
    }

    // MARK: - App Store Review Prompt

    private func checkReviewPrompt() {
        let tracker = PromptTracker.shared
        guard tracker.shouldShowReviewPrompt(currentSessionSeconds: accumulatedPlaySeconds) else { return }

        tracker.recordReviewPromptPresented()

        // Present the warm-up card after a short delay (same timing as Pro sheets)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.presentReviewCard()
        }
    }

    private func presentReviewCard() {
        let reviewView = ReviewPromptView(
            onRate: { [weak self] in
                PromptTracker.shared.recordReviewPromptRated()
                self?.dismiss(animated: true) {
                    // Fire the system review prompt
                    if let windowScene = self?.view.window?.windowScene {
                        SKStoreReviewController.requestReview(in: windowScene)
                    }
                }
            },
            onDismiss: { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        let host = UIHostingController(rootView: reviewView)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium()]
        }
        present(host, animated: true)
    }

    func overlayDidTapShareScreenshot() {
        presentScreenshotCard()
    }

    // MARK: - System Screenshot Detection

    @objc private func userDidTakeScreenshot() {
        // Only during active gameplay, max once per session
        guard overlay.isHidden,
              presentedViewController == nil,
              !hasShownScreenshotPopupThisSession else { return }
        hasShownScreenshotPopupThisSession = true
        presentScreenshotCard()
    }

    private func presentScreenshotCard() {
        guard let cgImage = session.createScreenshotImage() else { return }

        let romName = romURL.deletingPathExtension().lastPathComponent
        let tracker = PromptTracker.shared
        let gameTime = tracker.gamePlayTime(romName: romName)
            + Date().timeIntervalSince(lastResumeTime) + accumulatedPlaySeconds
        let totalTime = tracker.totalPlaySeconds
            + Date().timeIntervalSince(lastResumeTime) + accumulatedPlaySeconds

        // If the user renamed the game we use their title verbatim — parens
        // and punctuation included. Without a rename we clean up the raw ROM
        // filename ("POKEMON FIRE (USA, Europe)" → "Pokemon Fire") so the
        // share card doesn't surface region/version cruft.
        let trimmedTitle = gameTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = trimmedTitle.isEmpty
            ? ROMImporter.cleanGameTitle(romName)
            : trimmedTitle

        let info = ScreenshotCardRenderer.GameInfo(
            name: displayName,
            playTimeSeconds: gameTime,
            totalPlayTimeSeconds: totalTime,
            isPro: UserDefaults.standard.bool(forKey: "isPro")
        )

        guard let cardImage = ScreenshotCardRenderer.render(gameFrame: cgImage, info: info) else { return }

        // Pause game while share sheet is up
        let wasRunning = session.isRunning
        if wasRunning {
            session.pause()
            metalView.stopRendering()
        }

        let shareView = ScreenshotShareView(
            cardImage: cardImage,
            onShare: { [weak self] in
                self?.dismiss(animated: true) {
                    let activityVC = UIActivityViewController(activityItems: [cardImage], applicationActivities: nil)
                    // Resume once the share finishes (completed OR cancelled). The
                    // share-card pause already set session.isRunning = false, so if
                    // sharing backgrounds the app (e.g. opening Snapchat) the
                    // lifecycle path can't arm its own resume — without this hook the
                    // game stays frozen after sharing. Dispatched async so the
                    // activity VC has fully dismissed; if the share opened another
                    // app the guard no-ops here and defers to appDidBecomeActive.
                    activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
                        DispatchQueue.main.async { self?.resumeGameplayIfForeground() }
                    }
                    self?.present(activityVC, animated: true)
                }
            },
            onSave: { [weak self] in
                self?.saveScreenshotToPhotos(cardImage, wasRunning: wasRunning)
            },
            onDismiss: { [weak self] in
                self?.dismiss(animated: true) {
                    if wasRunning { self?.resumeAfterShare() }
                }
            }
        )

        let hostingVC = UIHostingController(rootView: shareView)
        hostingVC.modalPresentationStyle = .pageSheet
        if let sheet = hostingVC.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        // Resume game on dismiss (covers swipe-down)
        hostingVC.presentationController?.delegate = self
        present(hostingVC, animated: true)

        // Auto-dismiss after 30 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.presentedViewController === hostingVC {
                self?.dismiss(animated: true) {
                    if wasRunning { self?.resumeAfterShare() }
                }
            }
        }
    }

    private func resumeAfterShare() {
        guard !session.isRunning else { return }
        session.resume()
        metalView.startRendering()
        lastResumeTime = Date()
    }

    private func saveScreenshotToPhotos(_ image: UIImage, wasRunning: Bool) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            performPhotoSave(image, wasRunning: wasRunning)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self?.performPhotoSave(image, wasRunning: wasRunning)
                    } else {
                        self?.showPhotoPermissionDeniedAlert(wasRunning: wasRunning)
                    }
                }
            }
        default:
            showPhotoPermissionDeniedAlert(wasRunning: wasRunning)
        }
    }

    private func performPhotoSave(_ image: UIImage, wasRunning: Bool) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.dismiss(animated: true) {
                        if wasRunning { self?.resumeAfterShare() }
                    }
                } else {
                    let alert = UIAlertController(
                        title: NSLocalizedString("screenshot.saveError.title", comment: ""),
                        message: error?.localizedDescription ?? NSLocalizedString("screenshot.saveError.message", comment: ""),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: NSLocalizedString("common.ok", comment: ""), style: .default))
                    self?.presentedViewController?.present(alert, animated: true)
                }
            }
        }
    }

    private func showPhotoPermissionDeniedAlert(wasRunning: Bool) {
        let alert = UIAlertController(
            title: NSLocalizedString("screenshot.permissionDenied.title", comment: ""),
            message: NSLocalizedString("screenshot.permissionDenied.message", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("screenshot.permissionDenied.settings", comment: ""), style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("screenshot.permissionDenied.cancel", comment: ""), style: .cancel))
        presentedViewController?.present(alert, animated: true)
    }

    // UIAdaptivePresentationControllerDelegate — handle swipe-to-dismiss
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        resumeAfterShare()
    }

    func overlayDidTapCheats() {
        let romName = romURL.deletingPathExtension().lastPathComponent
        let hasBackup = session.saveStateManager?.hasPreCheatBackup ?? false
        let cheatView = CheatManagerView(
            romName: romName,
            isNDS: session.hasTouchScreen,
            onAddCheat: { [weak self] code in
                self?.session.addCheat(code) ?? false
            },
            onClearCheats: { [weak self] in
                self?.session.clearCheats()
            },
            onReapplyCheats: { [weak self] cheats in
                for cheat in cheats {
                    _ = self?.session.addCheat(cheat.code)
                }
            },
            onBackupSave: { [weak self] in
                _ = self?.session.savePreCheatBackup()
            },
            onRestoreBackup: { [weak self] in
                self?.session.loadPreCheatBackup() ?? false
            },
            hasBackup: hasBackup,
            onResume: { [weak self] in
                // The user confirmed "Restore pre-cheat save". Dismiss
                // the cheats sheet first, then close the overlay menu and
                // resume the game so we land directly back in gameplay.
                self?.dismiss(animated: true) {
                    self?.hideOverlay()
                }
            }
        )
        let vc = UIHostingController(rootView: cheatView)
        vc.modalPresentationStyle = .pageSheet
        if let sheet = vc.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(vc, animated: true)
    }

    func overlayDidToggleSound(enabled: Bool) {
        session.isAudioMuted = !enabled
        UserDefaults.standard.set(!enabled, forKey: "audioMuted")
    }

    func overlayDidTapQuit() {
        persistPlayTime()
        _ = session.autoSave()
        session.shutdown()
        metalView.stopRendering()
        onQuit?()
    }

    /// Save accumulated play time to PromptTracker. Called on quit and app background.
    private func persistPlayTime() {
        // Add any time since last resume (if game was actively running)
        if session.isRunning {
            accumulatedPlaySeconds += Date().timeIntervalSince(lastResumeTime)
            lastResumeTime = Date()
        }
        guard accumulatedPlaySeconds > 0 else { return }
        let gameName = romURL.deletingPathExtension().lastPathComponent
        PromptTracker.shared.recordSessionEnd(playSeconds: accumulatedPlaySeconds)
        PromptTracker.shared.recordGamePlayTime(romName: gameName, seconds: accumulatedPlaySeconds)
        accumulatedPlaySeconds = 0
    }

    // MARK: - TouchControlsDelegate

    func touchControlsDidChange(buttons: UInt32) {
        session.setKeys(buttons)
    }

    func touchControlsMicBlowStateChanged(active: Bool) {
        session.setMicBlowActive(active)
    }

    // MARK: - Game Controller

    /// Route a connected controller's input through the same path as touch
    /// input, and hide the on-screen controls while a controller is connected.
    private func setupController() {
        let manager = ControllerManager.shared
        manager.onButtonsChanged = { [weak self] mask in
            self?.session.setKeys(mask)
        }
        manager.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            // Drop any stale touch mask (e.g. a long-press-locked button) so
            // the controller starts from a clean slate.
            if connected { self.session.setKeys(0) }
            self.updateControlsVisibility()
            // Re-lay the game view: hiding the controls frees space the screen
            // reclaims (NDS portrait/landscape, GBA landscape).
            self.layoutGameView()
        }
        updateControlsVisibility()  // a controller may already be connected
    }

    /// Pause overlay open: hide the whole control layer. Controller connected:
    /// keep the layer so the Menu button stays reachable, but switch it to
    /// controller mode, which hides only the d-pad and action buttons. The NDS
    /// stylus overlay is left alone — a controller cannot replace the touchscreen.
    private func updateControlsVisibility() {
        controls.isHidden = !overlay.isHidden
        controls.controllerModeActive = ControllerManager.shared.isConnected
    }

    // MARK: - NDSTouchOverlayDelegate

    func ndsTouchBegan(x: Int, y: Int) {
        session.touchScreen(x: x, y: y)
    }

    func ndsTouchMoved(x: Int, y: Int) {
        session.touchScreen(x: x, y: y)
    }

    func ndsTouchEnded() {
        session.touchScreenRelease()
    }

    // MARK: - Layout

    private var lastLayoutSize: CGSize = .zero
    private var controlConstraintsApplied = false

    /// Sets metalView frame directly (no Auto Layout) and updates controls.
    /// Called from viewDidLayoutSubviews so bounds are always correct.
    private func layoutGameView() {
        let viewSize = view.bounds.size
        let safeInsets = view.safeAreaInsets
        let isLandscape = viewSize.width > viewSize.height

        let gameW = CGFloat(session.screenWidth > 0 ? session.screenWidth : EmulatorSession.defaultScreenWidth)
        // Use totalBufferHeight for the rendered area (384 for NDS, screenHeight for GBA)
        let gameH = CGFloat(session.totalBufferHeight > 0 ? session.totalBufferHeight : EmulatorSession.defaultScreenHeight)
        let gameAspect = gameW / gameH

        // Apply NDS screen size ratio from active preset (affects Metal vertex layout)
        let isNDS = session.hasTouchScreen
        let controllerConnected = ControllerManager.shared.isConnected
        // With a controller connected the on-screen controls are hidden; that
        // freed space goes to the game screen, leaving only this thin strip
        // for the still-visible Menu button.
        let controllerMenuStrip: CGFloat = 72
        if isNDS {
            // With a controller connected the goal is to fill the reclaimed
            // space, so the preset's NDS screen-size split is ignored (equal
            // screens). The stored preset is untouched and reapplies when the
            // controller disconnects.
            var activeLayout = ControlLayoutStore.shared.activePreset(forNDS: true)
                .map { isLandscape ? $0.landscape : $0.portrait }
            if controllerConnected { activeLayout = nil }
            if let layout = activeLayout {
                let topScale = layout.ndsTopScreenSize.scaleFactor
                let bottomScale = layout.ndsBottomScreenSize.scaleFactor
                let gapRatio: Float = 0.01
                let topRatio = Float(topScale) / Float(topScale + bottomScale) * (1.0 - gapRatio)
                metalView.ndsTopScreenRatio = topRatio
            } else {
                metalView.ndsTopScreenRatio = 0.495
            }
        }

        if isLandscape {
            if session.hasTouchScreen {
                metalView.ndsSideBySide = true
                // A controller frees the bottom controls area: keep only a
                // thin strip for the Menu button, give the rest to the screens.
                let screenAreaH = controllerConnected
                    ? viewSize.height - controllerMenuStrip
                    : viewSize.height * 0.60
                metalView.frame = CGRect(x: 0, y: 0, width: viewSize.width, height: screenAreaH)
            } else {
                metalView.ndsSideBySide = false
                // A controller frees the side control panels: the screen uses
                // the full width and then height-clamps larger.
                let panelWidth: CGFloat = controllerConnected ? 0 : 160
                let availW = viewSize.width - panelWidth * 2
                let availH = viewSize.height

                var fitW = availW
                var fitH = fitW / gameAspect
                if fitH > availH {
                    fitH = availH
                    fitW = fitH * gameAspect
                }

                let x = panelWidth + (availW - fitW) / 2
                let y = (availH - fitH) / 2
                metalView.frame = CGRect(x: x, y: y, width: fitW, height: fitH)
            }

            applyControlConstraints(isLandscape: true)
        } else {
            metalView.ndsSideBySide = false
            let availW = viewSize.width
            // A controller frees the controls area: keep only the Menu strip
            // so the NDS screen can reclaim the height.
            let minControlsH: CGFloat = session.hasTouchScreen
                ? (controllerConnected ? controllerMenuStrip : 280)
                : 0
            let maxH = session.hasTouchScreen
                ? viewSize.height - safeInsets.top - safeInsets.bottom - minControlsH
                : viewSize.height * 0.45
            let topOffset = safeInsets.top

            var fitW = availW
            var fitH = fitW / gameAspect
            if fitH > maxH {
                fitH = maxH
                fitW = fitH * gameAspect
            }

            let x = (availW - fitW) / 2
            let extraPadding: CGFloat = session.hasTouchScreen ? 0 : 42
            let y = topOffset + extraPadding
            metalView.frame = CGRect(x: x, y: y, width: fitW, height: fitH)

            applyControlConstraints(isLandscape: false)
        }

        // Position NDS touch overlay over whichever screen shows touch content.
        // Normally: bottom (portrait) / right (landscape).
        // When swapped: top (portrait) / left (landscape).
        if let touchOverlay = ndsTouchOverlay {
            let metalFrame = metalView.frame
            let screenAspect: CGFloat = 256.0 / 192.0
            let swapped = UserDefaults.standard.bool(forKey: "ndsSwapScreens")

            if isLandscape {
                var screenW = metalFrame.width / 2.0
                var screenH = screenW / screenAspect
                if screenH > metalFrame.height {
                    screenH = metalFrame.height
                    screenW = screenH * screenAspect
                }
                let screenY = metalFrame.origin.y + (metalFrame.height - screenH) / 2.0
                if swapped {
                    // Touch content is on the LEFT screen
                    let leftX = metalFrame.origin.x + metalFrame.width / 2.0 - screenW
                    touchOverlay.frame = CGRect(x: leftX, y: screenY, width: screenW, height: screenH)
                } else {
                    // Touch content is on the RIGHT screen
                    let rightX = metalFrame.origin.x + metalFrame.width / 2.0
                    touchOverlay.frame = CGRect(x: rightX, y: screenY, width: screenW, height: screenH)
                }
            } else {
                // Use the actual screen ratio from the Metal view for correct sizing
                let topRatio = CGFloat(metalView.ndsTopScreenRatio)
                let gapRatio: CGFloat = 0.01
                let botRatio = 1.0 - topRatio - gapRatio

                let topScreenH = metalFrame.height * topRatio
                let botScreenH = metalFrame.height * botRatio
                let gapH = metalFrame.height * gapRatio

                // Compute pixel dimensions respecting 4:3 aspect
                var topW = metalFrame.width
                var topH = topW / screenAspect
                if topH > topScreenH { topH = topScreenH; topW = topH * screenAspect }

                var botW = metalFrame.width
                var botH = botW / screenAspect
                if botH > botScreenH { botH = botScreenH; botW = botH * screenAspect }

                let screenX = metalFrame.origin.x + (metalFrame.width - topW) / 2.0
                if swapped {
                    // Touch content is on the TOP screen
                    touchOverlay.frame = CGRect(x: screenX, y: metalFrame.origin.y, width: topW, height: topH)
                } else {
                    // Touch content is on the BOTTOM screen
                    let botX = metalFrame.origin.x + (metalFrame.width - botW) / 2.0
                    let botY = metalFrame.origin.y + topScreenH + gapH
                    touchOverlay.frame = CGRect(x: botX, y: botY, width: botW, height: botH)
                }
            }
        }
    }

    /// Controls still use Auto Layout (they're standard UI, not performance-critical)
    private func applyControlConstraints(isLandscape: Bool) {
        // Remove old control constraints
        for constraint in view.constraints {
            if constraint.firstItem === controls || constraint.secondItem === controls {
                view.removeConstraint(constraint)
            }
        }

        if isLandscape {
            // NDS: controls below the screens. GBA: controls overlay full screen.
            let controlsTop = session.hasTouchScreen ? metalView.frame.maxY : 0
            NSLayoutConstraint.activate([
                controls.topAnchor.constraint(equalTo: view.topAnchor, constant: controlsTop),
                controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        } else {
            let metalBottom = metalView.frame.maxY
            NSLayoutConstraint.activate([
                controls.topAnchor.constraint(equalTo: view.topAnchor, constant: metalBottom),
                controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        // Force layout pass so controls.bounds is valid before applying custom layout
        view.layoutIfNeeded()

        // Check for active custom layout
        let isNDS = session.hasTouchScreen
        if let resolved = ControlLayoutStore.shared.resolvedPreset(
            forNDS: isNDS, isLandscape: isLandscape, containerSize: controls.bounds.size) {
            if resolved.hasCustomButtonPositions {
                // User customized button positions — use the full custom layout
                controls.applyCustomLayout(resolved.layout, isLandscape: isLandscape, isNDS: isNDS,
                                           presetOpacity: resolved.opacity, presetScale: resolved.scale)
            } else {
                // User only changed non-button settings (screen size, opacity, scale).
                // Use the hardcoded layout for correct button placement (e.g. NDS L/R
                // extending above the controls area), then apply preset opacity/scale.
                if isLandscape {
                    controls.applyLandscapeLayout()
                } else {
                    controls.applyPortraitLayout()
                }
                controls.applyPresetOpacityScale(opacity: resolved.opacity, scale: resolved.scale)
            }
        } else {
            // No preset — default layout with default opacity/scale
            if isLandscape {
                controls.applyLandscapeLayout()
            } else {
                controls.applyPortraitLayout()
            }
        }
    }

    // MARK: - Emulation

    private func loadAndStart() {
        statusLabel.text = NSLocalizedString("emulator.loading", comment: "")

        let success = session.loadROM(at: romURL)

        if success {
            // Load save state if requested
            if let slot = loadSlotOnStart {
                _ = session.loadState(slot: slot)
            }
            // Restore per-game speed preference (migrates Int→Double)
            let speedKey = "speed_\(romURL.deletingPathExtension().lastPathComponent)"
            var savedSpeed = UserDefaults.standard.double(forKey: speedKey)
            if savedSpeed == 0 { savedSpeed = 1.0 }
            // Clamp to free speeds if not Pro (free: 1.0, 1.5)
            let isPro = UserDefaults.standard.bool(forKey: "isPro")
            if !isPro && ![1.0, 1.5].contains(savedSpeed) {
                savedSpeed = min(savedSpeed, 1.5)
                if savedSpeed < 1.0 { savedSpeed = 1.0 }
            }
            _currentSpeed = savedSpeed
            metalView.speedMultiplier = savedSpeed
            lastResumeTime = Date()
            accumulatedPlaySeconds = 0
            statusLabel.text = nil
            metalView.attach(session: session)
            // Directly recalculate layout now that we know the actual screen
            // dimensions. Can't rely on setNeedsLayout because viewDidLayoutSubviews
            // won't fire again if the view's bounds haven't changed.
            layoutGameView()
            session.start()
            session.isAudioMuted = UserDefaults.standard.bool(forKey: "audioMuted")
            metalView.startRendering()

            // Auto-apply saved cheat codes for this game
            applySavedCheats()

            #if DEBUG
            if UserDefaults.standard.object(forKey: "debugTranslationEnabled") as? Bool ?? true {
                startTranslationProbe()
            }
            #endif
        } else {
            statusLabel.text = String(format: NSLocalizedString("emulator.loadFailed", comment: ""), romURL.lastPathComponent)
        }
    }

    private func applySavedCheats() {
        let romName = romURL.deletingPathExtension().lastPathComponent
        let key = "cheats_\(romName)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cheats = try? JSONDecoder().decode([CheatManagerView.StoredCheat].self, from: data)
        else { return }

        for cheat in cheats where cheat.enabled {
            _ = session.addCheat(cheat.code)
        }
    }

    #if DEBUG
    // MARK: - Translation feature (Phase 1, DEBUG only)

    /// Detect the Gen 3 game, start the translation probe, and poll it twice a
    /// second to refresh the battle overlay and the debug text label.
    private func startTranslationProbe() {
        // A non-Gen3 or unknown ROM returns nil — the feature stays dormant.
        guard let profile = Gen3GameDetector.detect(memory: session) else { return }
        let probe = TranslationProbe(session: session, profile: profile)
        translationProbe = probe
        translationTimer?.invalidate()
        translationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let frame = probe.poll()
            self.translationDebugLabel.text = frame.debugText
            self.battleOverlayView.update(items: frame.overlayItems,
                                          gameRect: self.metalView.frame)
        }
    }

    private func stopTranslationProbe() {
        translationTimer?.invalidate()
        translationTimer = nil
        translationProbe = nil
        battleOverlayView.update(items: [], gameRect: .zero)
    }
    #endif
}
