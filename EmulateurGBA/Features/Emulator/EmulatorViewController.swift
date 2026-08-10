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
import CoreData
import os

final class EmulatorViewController: UIViewController, TouchControlsDelegate, OverlayMenuDelegate, NDSTouchOverlayDelegate {
    private let session: EmulatorSession

    /// Serializes all save-state file IO (manual save/load, auto-save on quit
    /// and on background) off the main thread. The coordinated write goes
    /// through NSFileCoordinator, which can block on the system file-coordination
    /// / iCloud daemon; running it on the main thread froze the whole UI (incl.
    /// the Quit button) when iCloud was wedged. Serial so two operations never
    /// touch the emulator bridge at once. Safe because the emulator is always
    /// paused at these points (the pause menu pauses it; backgrounding pauses it).
    private let saveIOQueue = DispatchQueue(label: "com.retropal.save-io", qos: .userInitiated)
    private let romURL: URL
    /// Which control/layout family this game belongs to (GBA, GB/GBC, or NDS).
    /// Drives the on-screen button set, the default layout, and the active preset
    /// bucket. Resolved once from the ROM extension at init.
    private let presetSystem: PresetSystem
    private var metalView: EmulatorMetalView!
    /// Cosmetic console "dress" drawn behind the screen + controls (GB/GBC for now).
    private let consoleSkin = ConsoleSkinView()
    private let controls: TouchControlsView
    private let overlay = OverlayMenuView()
    /// Rolling recorder for the shareable gameplay clip (1.1). Owned here; the
    /// metal view holds a weak ref and feeds it frames during play.
    private let clipRecorder = GameplayClipRecorder()
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

    /// Per-game screen orientation (Auto / Lock Landscape / Lock Portrait),
    /// loaded in init and applied on first appearance + when changed.
    private var currentOrientationMode: GameOrientationMode = .auto
    private var didApplyInitialOrientation = false

    /// Tracks active play time (excludes paused/overlay time).
    /// Reset on each resume, accumulated into `accumulatedPlaySeconds`.
    private var lastResumeTime = Date()
    private var accumulatedPlaySeconds: TimeInterval = 0
    /// The whole session's play time (survives the background/foreground
    /// banking that resets `accumulatedPlaySeconds`), for the anonymous
    /// bucketed play_session signal at quit.
    private var sessionTotalPlaySeconds: TimeInterval = 0

    /// Slot to load immediately after ROM loads (nil = fresh start)
    var loadSlotOnStart: Int?

    /// User-facing display name (post-rename). Used for the screenshot share card
    /// so a renamed game shows the user's chosen title, not the raw ROM filename.
    /// Falls back to the filename when nil.
    var gameTitle: String?

    /// Called when the user quits to library
    var onQuit: (() -> Void)?

    /// File size recorded at import. Used to pre-flight the on-disk ROM before
    /// handing it to the core (a missing/truncated file is the cause of the rare
    /// "won't load" black screen). 0 = unknown, so the size comparison is skipped.
    var expectedROMSize: Int64 = 0

    /// Bridge to the SwiftUI `.sheet` that presents the share cards (clip +
    /// screenshot). Set by `EmulatorScreen`. Owned there (as a `@StateObject`),
    /// so a weak ref is safe — it outlives the VC's use of it.
    weak var shareModel: EmulatorShareModel?

    /// Diagnostic log for the ROM load path. Uses os.Logger so a failure on a
    /// tester's device is traceable via Console / sysdiagnose even in Release.
    private static let romLoadLog = Logger(subsystem: "com.retropal", category: "rom-load")

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    init(romURL: URL, session: EmulatorSession) {
        self.romURL = romURL
        self.session = session
        self.controls = session.hasTouchScreen ? NDSTouchControlsView() : TouchControlsView()
        // Resolve the layout family from the ROM extension. NDS is authoritative
        // via the running core (hasTouchScreen); GB/GBC vs GBA comes from the file
        // type, falling back to GBA for anything unrecognized but non-touch.
        if session.hasTouchScreen {
            self.presetSystem = .nds
        } else {
            let romType = ROMSystemType.from(fileExtension: romURL.pathExtension)
            self.presetSystem = (romType == .gb || romType == .gbc) ? .gbc : .gba
        }
        super.init(nibName: nil, bundle: nil)
        currentOrientationMode = GameOrientationMode(
            rawValue: UserDefaults.standard.string(forKey: orientationKey) ?? "") ?? .auto
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Console dress (cosmetic) sits behind everything; frame/geometry set in layout.
        consoleSkin.system = presetSystem
        consoleSkin.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(consoleSkin)

        // Metal view — frame set manually in viewDidLayoutSubviews (not Auto Layout)
        metalView = EmulatorMetalView(frame: .zero, device: nil)
        metalView.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(metalView)

        // Touch controls overlay
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.delegate = self
        controls.onMenuTap = { [weak self] in self?.showOverlay() }
        // In-game clip control: same flow as the pause menu's Clip button, one tap.
        // Guard re-entry. the touch handler can fire repeatedly while a finger rests
        // on the button, and presenting twice would stack/​warn.
        controls.onClipTap = { [weak self] in
            guard let self, self.presentedViewController == nil,
                  self.shareModel?.card == nil, self.overlay.isHidden else { return }
            self.presentClipCard(pauseAndResume: true)
        }
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
        overlay.setLockableButtons(forNDS: session.hasTouchScreen)  // A/B, or A/B/X/Y for NDS
        overlay.setSkinIcon(UIImage(named: skinIconAssetName))      // console glyph on the Skin button
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.delegate = self
        overlay.isHidden = true
        view.addSubview(overlay)

        setupController()

        // Status label
        view.addSubview(statusLabel)

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

        registerLifecycleObservers()

        // The RA unlock share card is presented by EmulatorScreen (SwiftUI),
        // not by this controller, so it can't pause/resume gameplay itself.
        // Arm the model with the same contract the screenshot/clip cards get
        // in their present methods: bank the live play interval, pause, and
        // resume through the sheet's onDismiss (guarded, so the pause-menu
        // case stays paused). Without this, closing the card left the game
        // stuck paused until a manual pause-menu resume.
        shareModel?.pauseForCard = { [weak self] in
            guard let self else { return }
            self.shareModel?.onDismiss = { [weak self] in
                self?.resumeGameplayIfForeground(viaDismiss: true)
            }
            guard self.session.isRunning else { return }
            self.accumulatedPlaySeconds += Date().timeIntervalSince(self.lastResumeTime)
            self.lastResumeTime = Date()
            self.session.pause()
            self.metalView.stopRendering()
        }

        loadAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        metalView.stopRendering()
        session.pause()
        NotificationCenter.default.removeObserver(self)
        // Give the television back its idle screen. Like the orientation lock
        // below, this fires on dismiss (quit) and not on app backgrounding, so
        // a backgrounded game keeps its picture on the TV while paused.
        ExternalDisplayManager.shared.setSource(nil)
        // Never leave the library holding the screen awake.
        UIApplication.shared.isIdleTimerDisabled = false
        // Release any per-game orientation lock so the library rotates freely
        // again. This fires on dismiss (quit), not on app backgrounding, so a
        // locked game keeps its lock across background/foreground.
        AppOrientationLock.mask = .allButUpsideDown
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Enforce the per-game orientation once the window/scene exists. The
        // dynamic supportedInterfaceOrientations already biases presentation;
        // this rotates a locked game into place and overrides the iOS lock.
        if !didApplyInitialOrientation {
            didApplyInitialOrientation = true
            applyOrientation(currentOrientationMode)
        }
        // Hand the live game view to any connected television. Idempotent, and
        // a no-op when nothing is plugged in or the user is not Pro.
        ExternalDisplayManager.shared.setSource(metalView)
        updateIdleTimer()
        // Initial status bar state (a locked rotation, if any, also fires
        // viewWillTransition which refreshes it).
        updateSystemChrome(isPortrait: expectedPortrait())
    }

    /// Pin (or release) the device orientation for this game. Setting the
    /// app-wide mask via `AppOrientationLock` is what makes the lock *hold*
    /// against physical rotation and the iOS portrait lock: the system reads
    /// that mask from the app delegate (it never queries this nested VC).
    /// `requestGeometryUpdate` then snaps the device into the locked
    /// orientation immediately.
    private func applyOrientation(_ mode: GameOrientationMode) {
        let mask: UIInterfaceOrientationMask
        switch mode {
        case .auto: mask = .allButUpsideDown
        case .landscape: mask = .landscape
        case .portrait: mask = .portrait
        }
        AppOrientationLock.mask = mask
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
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
        // A television appearing or disappearing mid-game changes whether the
        // phone is still the input surface.
        nc.addObserver(self, selector: #selector(externalDisplayDidChange),
                       name: ExternalDisplayManager.didChangeNotification, object: nil)
    }

    @objc private func externalDisplayDidChange() { updateIdleTimer() }

    /// iOS auto-lock does NOT reset on controller input, and a player on a
    /// television never touches the screen at all. Without this the phone
    /// locks after its normal timeout, which fires appWillResignActive, which
    /// pauses the session: the game stops and the TV freezes mid-play.
    ///
    /// Deliberately conditional. Touch players reset the idle timer with every
    /// tap, so holding the screen awake for them would only change battery
    /// behaviour for no benefit.
    ///
    /// A hardware keyboard counts too (audit, 2026-07-27). It never sets
    /// `isConnected` — by design, so the touch controls stay visible — but a
    /// keyboard player touches the screen no more than a pad player does, and
    /// would have hit exactly the same lock-out.
    private func updateIdleTimer() {
        let phoneIsNotTheInput = ControllerManager.shared.isConnected
            || ControllerManager.shared.isKeyboardAttached
            || ExternalDisplayManager.shared.isShowingGame
        UIApplication.shared.isIdleTimerDisabled = session.isROMLoaded && phoneIsNotTheInput
    }

    @objc private func appWillResignActive() {
        // Triggered by: app going to background, incoming call, Control Center, etc.
        // Pause immediately to stop rendering and audio.
        guard session.isRunning else { return }
        // persistPlayTime() banks the time since last resume itself (the session
        // is still running here; pause is just below), so pre-adding it would
        // double-count the interval on every deactivation.
        persistPlayTime()  // Save now in case app is force-quit before didEnterBackground
        session.pause()
        metalView.stopRendering()
    }

    @objc private func appDidEnterBackground() {
        guard session.isROMLoaded else { return }
        persistPlayTime()
        // Persist the latest snapshot + battery save and BLOCK here until it
        // lands, so progress is durable before the app can be killed. A user
        // force-kill (swipe-away) terminates the process immediately and does
        // NOT honor a background task, so an async save can be lost mid-write —
        // the regression that cost a tester's NDS session. Two things keep the
        // block safe:
        //   1. The auto-save is written UNCOORDINATED + atomic (coordinated:
        //      false, like flushBatterySave), so it can't stall on the iCloud
        //      daemon — the common case finishes in well under 100 ms.
        //   2. It still runs on the serial saveIOQueue, so it never collides
        //      with an in-flight manual save touching the emulator bridge.
        // The wait is capped so a rare in-flight COORDINATED save hanging on a
        // wedged iCloud daemon can't trip the ~5 s background watchdog; the
        // background task lets the save finish if the cap is hit and the app is
        // not force-killed. Emulation is already paused (appWillResignActive).
        let session = self.session
        let app = UIApplication.shared
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = app.beginBackgroundTask(withName: "retropal.autosave") {
            if bgTask != .invalid { app.endBackgroundTask(bgTask); bgTask = .invalid }
        }
        let done = DispatchSemaphore(value: 0)
        saveIOQueue.async {
            _ = session.autoSave(coordinated: false)
            session.flushBatterySave()
            done.signal()
            // The auto-save is on disk, so its screenshot is the newest thing
            // the widget could show — and this is the last moment we are alive
            // to publish it. Killing the app straight from a game never
            // reaches coverDidDismiss, which is why a widget showing a
            // save-state preview used to stay stale until the next launch.
            // Safe here specifically because the blocking save is already done.
            WidgetSnapshotWriter.refresh(force: true)
            // End the task on the main thread so begin/end and the expiration
            // handler all mutate bgTask on the same thread (no race).
            DispatchQueue.main.async {
                if bgTask != .invalid { app.endBackgroundTask(bgTask); bgTask = .invalid }
            }
        }
        // Block until the (fast, uncoordinated) save lands, capped at 3 s.
        _ = done.wait(timeout: .now() + 3.0)
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
    /// content: app active, not sitting in the pause menu, and a ROM loaded but
    /// currently paused. Idempotent and safe to call from any path — it no-ops
    /// unless the game *should* be running, so it can never fight the pause menu or
    /// a modal that is intentionally holding the game paused.
    ///
    /// `viaDismiss` distinguishes the two callers:
    ///   - `false` (becoming active): a share card or activity/alert may be covering
    ///     the game, so the full guard set applies — `presentedViewController == nil`
    ///     and `shareModel?.card == nil` keep the game paused behind whatever is up
    ///     (e.g. foregrounding after sharing to another app).
    ///   - `true` (a share card's own `onDismiss`): the card is *by definition* going
    ///     away, so those two conditions must NOT gate the resume. On an interactive
    ///     swipe-dismiss the sheet's view controller is still detaching when
    ///     `onDismiss` fires, so `presentedViewController` is transiently non-nil and
    ///     would wrongly block the resume (verified on device); the programmatic
    ///     Close/Save paths finish dismissing first, which is why only the swipe was
    ///     stuck. The pause-menu (option 2) case stays correctly paused via
    ///     `overlay.isHidden`.
    private func resumeGameplayIfForeground(viaDismiss: Bool = false) {
        guard UIApplication.shared.applicationState == .active,
              viaDismiss || presentedViewController == nil,
              viaDismiss || shareModel?.card == nil,
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

    /// Whether the system chrome (status bar + home indicator) is currently hidden —
    /// i.e. whether the game is in immersive full-screen mode. Read by the system for
    /// both prefersStatusBarHidden and prefersHomeIndicatorAutoHidden.
    private var chromeHidden = true
    /// Cached once: whether this device reserves a top safe-area band (notch /
    /// Dynamic Island / Face ID). Detected via the home-indicator BOTTOM inset,
    /// which is present in both orientations on Face ID devices and absent on
    /// Touch ID devices (SE) — a stable, orientation-independent test, unlike the
    /// top inset which is zero in landscape.
    private var deviceReservesTopBand: Bool?

    /// Show the system chrome (status bar + home indicator, and with them OTHER
    /// apps' persistent Dynamic Island Live Activities) only in portrait on devices
    /// that reserve a top band: there the status bar fills space the game already
    /// leaves empty (the portrait screen is laid out at safeInsets.top) and the home
    /// indicator sits in the already-reserved bottom inset, so nothing moves. Hidden
    /// (immersive) in landscape and on the SE (where showing the bar would add ~20pt
    /// of top safe area and push the screen down).
    ///
    /// Showing the home indicator (i.e. NOT immersive) is what keeps the Dynamic
    /// Island Live Activities on screen: in immersive mode iOS shows them briefly
    /// then auto-hides them, so an un-hidden status bar alone was not enough.
    ///
    /// Driven ONCE per orientation change (viewWillTransition), synchronized with the
    /// rotation — never from viewDidLayoutSubviews. Toggling the chrome changes the
    /// safe area, which re-runs the layout; doing it from the layout pass fired
    /// repeated updates per rotation that fed back into the layout, and with a
    /// Dynamic Island Live Activity active that storm scrambled the UI for seconds
    /// before settling. One synchronized update avoids the loop.
    private func updateSystemChrome(isPortrait: Bool) {
        if deviceReservesTopBand == nil, let window = view.window {
            deviceReservesTopBand = window.safeAreaInsets.bottom > 0
        }
        let hidden = !(isPortrait && (deviceReservesTopBand ?? false))
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    /// The orientation the game will settle into: the locked mode, or the live
    /// device orientation in auto.
    private func expectedPortrait() -> Bool {
        switch currentOrientationMode {
        case .portrait: return true
        case .landscape: return false
        case .auto: return view.bounds.height >= view.bounds.width
        }
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Update the bar once, animated alongside the rotation (see above).
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.updateSystemChrome(isPortrait: size.height >= size.width)
            // Re-fit the Skin picker sheet so it never keeps the previous orientation's detent.
            self?.updateSkinSheetDetents(for: size)
        })
    }

    override var prefersStatusBarHidden: Bool { chromeHidden }
    // White status bar text/icons: the band behind it (above the game screen) is the
    // black view background.
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    // In lockstep with the status bar: shown in portrait-with-chrome (non-immersive,
    // which keeps the Dynamic Island Live Activities persistent), auto-hidden in the
    // immersive landscape / SE case.
    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch currentOrientationMode {
        case .auto: return .allButUpsideDown
        case .landscape: return .landscape
        case .portrait: return .portrait
        }
    }

    /// Full-screen emulator: claim the screen-edge touch zones the system would
    /// otherwise reserve. With the status bar hidden, iOS keeps a thin band at the
    /// top edge for its status-bar / Notification-Center reveal gesture, swallowing
    /// touches that begin there. In landscape the NDS bottom screen is rendered
    /// flush against that top edge (y = 0), so its top row of touch targets (e.g.
    /// the HG/SS bag category icons) became untappable. Deferring the system
    /// gestures routes those edge touches to the game instead. The system UI still
    /// reveals on a second, deliberate swipe.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    // MARK: - Overlay

    private func showOverlay() {
        // Idempotent per pause. The Menu button's touch handler can fire onMenuTap
        // more than once per tap; without this guard each call re-banked the play
        // interval since the last resume, over-counting play time (worse the more
        // you opened the menu, e.g. to change speed).
        guard overlay.isHidden else { return }
        session.pause()
        metalView.stopRendering()
        overlay.setCurrentSpeed(currentSpeed)
        overlay.setSoundEnabled(!session.isAudioMuted)
        overlay.setButtonLockEnabled(controls.buttonLockEnabled)
        overlay.setOrientationMode(currentOrientationMode)
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

        // Bank the active play time since the last resume, then advance the
        // reference so the live "since resume" term reads ~0 while paused (the
        // cards / prompt thresholds that add it below can't then double-count it).
        accumulatedPlaySeconds += Date().timeIntervalSince(lastResumeTime)
        lastResumeTime = Date()

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
        // Auto-mute when crossing INTO fast-forward (>2x) so a 3x/4x jump doesn't
        // blast sped-up audio. Reversible: the user can re-enable sound at any
        // speed. Persisted like a manual mute so it stays consistent with the
        // per-game saved speed: returning to a game still at 3x/4x stays muted
        // instead of suddenly playing sound.
        let enteringFastForward = multiplier > 2.0 && currentSpeed <= 2.0
        currentSpeed = multiplier
        metalView.speedMultiplier = multiplier
        if enteringFastForward && !session.isAudioMuted {
            setAudioMuted(true)
            overlay.setSoundEnabled(false)
        }
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
        // Past the gate: a Pro slot (3-5) here means a Pro user using the feature.
        if slot > SaveStateManager.freeSlotCount {
            Analytics.signal("pro_feature_used", ["feature": "save_slot_extra"])
        }
        // Write off the main thread: the coordinated write can stall on the
        // iCloud/file-coordination daemon, which used to freeze the UI. The
        // emulator is paused (the pause menu is open), so reading its state on
        // the IO queue is race-free, and the serial queue keeps it ordered.
        let session = self.session
        saveIOQueue.async { [weak self] in
            let success = session.saveState(slot: slot)
            guard success, let manager = session.saveStateManager else { return }
            let slots = manager.allManualSlotsWithLockState()
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Core-loop engagement: deliberate manual saves only (the
                // auto-save is machine behavior and would just mirror quits).
                Analytics.signal("save_state", ["action": "save"])
                self.overlay.updateSlots(slots)

                // Trigger 2: Save slot full — all free slots used
                if !isPro {
                    let freeSlots = slots.prefix(SaveStateManager.freeSlotCount)
                    let allFull = freeSlots.allSatisfy { $0.info.exists }
                    if allFull && PromptTracker.shared.shouldShowSaveSlotFull() {
                        self.showProSheet(context: .saveSlotFull)
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
        // Loading a Pro slot (3-5) is using the extra-slots feature (only a Pro
        // user could have saved there).
        if slot > SaveStateManager.freeSlotCount {
            Analytics.signal("pro_feature_used", ["feature": "save_slot_extra"])
        }
        // Read off the main thread (same coordinated-IO stall risk as saving).
        // The emulator is paused (pause menu open), so applying the loaded state
        // on the IO queue is race-free; resume on the main thread once it lands.
        let session = self.session
        saveIOQueue.async { [weak self] in
            let success = session.loadState(slot: slot)
            DispatchQueue.main.async {
                if success {
                    Analytics.signal("save_state", ["action": "load"])
                    self?.hideOverlay()
                }
            }
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
        if isPro && success {
            Analytics.signal("pro_feature_used", ["feature": "rewind_30s"])
        }

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
        guard let arm = tracker.reviewPromptArm(currentSessionSeconds: accumulatedPlaySeconds) else { return }

        tracker.recordReviewPromptPresented()

        // Present the warm-up card after a short delay (same timing as Pro sheets)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.presentReviewCard(arm: arm)
        }
    }

    private func presentReviewCard(arm: String) {
        Analytics.signal("review_prompt_shown", ["trigger": arm])
        weak var hostRef: ReviewPromptHostController?
        let reviewView = ReviewPromptView(
            onRate: { [weak self] in
                hostRef?.markOutcomeRecorded()
                Analytics.signal("review_prompt_outcome", ["outcome": "rated", "trigger": arm])
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
        let host = ReviewPromptHostController(rootView: reviewView)
        host.arm = arm
        hostRef = host
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium()]
        }
        present(host, animated: true)
    }

    func overlayDidTapShareScreenshot() {
        // Opened deliberately from the in-game menu: stay up until the user closes it
        // (no auto-dismiss). Only the system-screenshot detection path times out.
        presentScreenshotCard(autoDismiss: false)
    }

    func overlayDidTapShareClip() {
        presentClipCard()
    }

    /// Display name + current per-game play time for the share cards (screenshot
    /// + clip), so both show the same title and time. Name is the user's rename
    /// if set, else the cleaned ROM filename ("POKEMON FIRE (USA, Europe)" ->
    /// "Pokemon Fire"). Play time = stored per-game total plus the live session.
    private func currentShareInfo() -> (name: String, playTime: TimeInterval) {
        let romName = romURL.deletingPathExtension().lastPathComponent
        let playTime = PromptTracker.shared.gamePlayTime(romName: romName)
            + Date().timeIntervalSince(lastResumeTime) + accumulatedPlaySeconds
        let trimmed = gameTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmed.isEmpty ? ROMImporter.cleanGameTitle(romName) : trimmed
        return (name, playTime)
    }

    /// Present the clip share card (a SwiftUI `.sheet`, via the shared `shareModel`)
    /// immediately with a shimmering skeleton, then encode the buffered last-seconds
    /// clip off-thread and reveal the MP4 in the card when ready. The card shares +
    /// saves itself (see ClipShareView); this only sets up the card and the resume.
    private func presentClipCard(pauseAndResume: Bool = false) {
        let frames = clipRecorder.snapshotFrames()
        guard frames.count >= 2 else {
            let alert = UIAlertController(
                title: NSLocalizedString("clip.notReady.title", value: "Clip not ready yet", comment: ""),
                message: NSLocalizedString("clip.notReady.message", value: "Play a few more seconds, then try again.", comment: ""),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("common.ok", value: "OK", comment: ""), style: .default))
            present(alert, animated: true)
            return
        }

        // From the in-game button the game is still running; pause it. From the pause
        // menu it is already paused (pauseAndResume false), so nothing changes here.
        // The resume is unified through resumeGameplayIfForeground, fired by the card
        // sheet's onDismiss — it no-ops in the pause-menu case because the overlay is up.
        if pauseAndResume && session.isRunning {
            // Bank the active play since the last resume BEFORE pausing, exactly as
            // showOverlay does. The resume after this card (resumeGameplayIfForeground)
            // resets lastResumeTime without banking, so without this the live interval
            // would be lost — the card shows it, but it never reaches the stored total,
            // making a later share read LOWER than an earlier one.
            accumulatedPlaySeconds += Date().timeIntervalSince(lastResumeTime)
            lastResumeTime = Date()
            session.pause()
            metalView.stopRendering()
        }

        let model = ClipShareModel()
        let frameAspect: CGFloat = {
            guard let f = frames.first, f.height > 0 else { return 1 }
            return CGFloat(f.width) / CGFloat(f.height)
        }()

        // First-open hint: shown once as a header, then never again. The Debug
        // settings preview it without consuming this flag.
        let showClipHint = !UserDefaults.standard.bool(forKey: "clipHintShown")
        if showClipHint { UserDefaults.standard.set(true, forKey: "clipHintShown") }
        let clipHint = showClipHint
            ? NSLocalizedString("clip.hint", value: "You can save the last 6 seconds anytime.", comment: "")
            : nil

        // Present the clip card as a SwiftUI `.sheet` (via EmulatorScreen) with a
        // shimmering skeleton; the background encode fills in the video when ready,
        // which reveals the clip and enables Share / Save / Close (see ClipShareView).
        // All three share cards use this one presentation path. The card is fully
        // self-contained (it shares + saves itself); we only resume on dismiss.
        // Title + play time for the live card, and the on-demand final-clip export
        // (the chrome'd MP4 is baked at the chosen style only when sharing/saving).
        let clipSpeed = GameplayClipRecorder.playbackSpeed(forEmulationSpeed: metalView.speedMultiplier)
        let fps = clipRecorder.fps
        let share = currentShareInfo()
        let system = presetSystem
        let skinContext = shareCardSkinContext
        model.title = share.name
        model.playTime = share.playTime
        model.system = system
        model.skinContext = skinContext
        model.exportFinalClip = { style, done in
            GameplayClipRenderer.renderClip(frames: frames, fps: fps, speed: clipSpeed,
                                            title: share.name, playTime: share.playTime, style: style,
                                            isPro: UserDefaults.standard.bool(forKey: "isPro"),
                                            system: system, skinVariant: skinContext.skin?.variant,
                                            filter: skinContext.filter,
                                            completion: done)
        }

        let card = EmulatorShareCard(content: .clip(model, frameAspect: frameAspect), hint: clipHint)
        shareModel?.onDismiss = { [weak self] in self?.resumeGameplayIfForeground(viaDismiss: true) }
        shareModel?.card = card

        // Encode the RAW (chrome-less) preview clip in the background; the card chrome
        // is drawn as a live SwiftUI overlay, so the Standard/Pro style toggles
        // instantly. The chrome'd MP4 is baked only on Share/Save (exportFinalClip).
        GameplayClipRenderer.renderGameplayClip(frames: frames, fps: fps, speed: clipSpeed,
                                                frameAspect: frameAspect,
                                                filter: skinContext.filter) { [weak model] url in
            guard let url = url else {
                // Encode failed (rare): flag the model so ClipShareView shows the
                // "couldn't create the clip" alert and closes the card on OK.
                model?.renderFailed = true
                return
            }
            model?.gameplayURL = url   // reveals the clip + enables the buttons
        }
    }

    // MARK: - System Screenshot Detection

    @objc private func userDidTakeScreenshot() {
        // Only during active gameplay, max once per session, and never stacked over
        // a share card already up (those are SwiftUI `.sheet`s, so they don't show as
        // `presentedViewController` — guard on the model instead).
        guard overlay.isHidden,
              presentedViewController == nil,
              shareModel?.card == nil,
              !hasShownScreenshotPopupThisSession else { return }
        hasShownScreenshotPopupThisSession = true
        presentScreenshotCard(autoDismiss: true)
    }

    /// Presents the screenshot share card. `autoDismiss` is true only for the system
    /// screenshot-detection path (the card slides in unprompted, so it times out after
    /// 30s); the in-game menu Share button passes false so the card stays up until the
    /// user dismisses it.
    private func presentScreenshotCard(autoDismiss: Bool) {
        guard let cgImage = session.createScreenshotImage() else { return }

        let share = currentShareInfo()

        // Pause the game while the card is up; resume is unified through
        // resumeGameplayIfForeground, fired by the card sheet's onDismiss.
        // Bank the active play since the last resume BEFORE pausing (as showOverlay
        // does); the resume path resets lastResumeTime without banking, so otherwise
        // this interval is shown on the card but never persisted, and a later share
        // can read lower than an earlier one.
        if session.isRunning {
            accumulatedPlaySeconds += Date().timeIntervalSince(lastResumeTime)
            lastResumeTime = Date()
            session.pause()
            metalView.stopRendering()
        }

        // First-open hint: shown once as a header, then never again (Debug previews it).
        let showShotHint = !UserDefaults.standard.bool(forKey: "screenshotHintShown")
        if showShotHint { UserDefaults.standard.set(true, forKey: "screenshotHintShown") }
        let shotHint = showShotHint
            ? NSLocalizedString("screenshot.hint", value: "Capture your best moment, anytime.", comment: "")
            : nil

        // Present as a SwiftUI `.sheet` (via EmulatorScreen) — the same path as the
        // clip and stats cards. The card shares + saves itself; we only resume on
        // dismiss.
        // Pass the SOURCE (frame + info), not a pre-rendered image, so the share
        // view can re-render the card live when the Standard/Pro style is toggled.
        let card = EmulatorShareCard(
            content: .screenshot(gameFrame: cgImage, name: share.name, playTime: share.playTime,
                                 system: presetSystem, skin: shareCardSkinContext),
            hint: shotHint)
        let cardId = card.id
        shareModel?.onDismiss = { [weak self] in self?.resumeGameplayIfForeground(viaDismiss: true) }
        shareModel?.card = card

        // Auto-dismiss after 30 seconds if the user hasn't interacted — only when the
        // card was triggered by screenshot detection. Cards opened from the in-game menu
        // stay up until dismissed. Clearing the card triggers the sheet's onDismiss,
        // which resumes the game.
        guard autoDismiss else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.shareModel?.card?.id == cardId { self?.shareModel?.card = nil }
        }
    }

    func overlayDidTapCheats() {
        let romName = romURL.deletingPathExtension().lastPathComponent
        let hasBackup = session.saveStateManager?.hasPreCheatBackup ?? false
        let cheatView = CheatManagerView(
            romName: romName,
            isNDS: session.hasTouchScreen,
            systemKey: ROMSystemType.from(fileExtension: romURL.pathExtension)?.rawValue ?? "gba",
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
        setAudioMuted(!enabled)
    }

    /// Set the live mute state and persist it (the saved preference is global,
    /// restored on the next game launch). Used by the manual Son toggle and the
    /// fast-forward auto-mute so both behave the same.
    private func setAudioMuted(_ muted: Bool) {
        session.isAudioMuted = muted
        UserDefaults.standard.set(muted, forKey: "audioMuted")
    }

    func overlayDidToggleButtonLock(enabled: Bool) {
        controls.buttonLockEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: buttonLockKey)
    }

    /// Per-game key for the hold-to-lock preference (off by default).
    private var buttonLockKey: String {
        "buttonLock_\(romURL.deletingPathExtension().lastPathComponent)"
    }

    func overlayDidSelectOrientation(_ mode: GameOrientationMode) {
        currentOrientationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: orientationKey)
        applyOrientation(mode)
        // Covers a mode change that does NOT rotate the device (so no
        // viewWillTransition fires), e.g. locking the current orientation.
        updateSystemChrome(isPortrait: expectedPortrait())
    }

    /// Per-game key for the screen-orientation preference (auto by default).
    private var orientationKey: String {
        "orientation_\(romURL.deletingPathExtension().lastPathComponent)"
    }

    // MARK: - Per-game skin (in-game menu ▸ Skin)

    /// Per-game key for the on-screen skin choice (Nostalgia by default).
    private var skinKey: String {
        "skin_\(romURL.deletingPathExtension().lastPathComponent)"
    }

    /// The skin the player picked for this game (Nostalgia if never set). May be a built-in
    /// skin or a user custom skin referenced by id (see SkinSelection).
    private var storedSelection: SkinSelection {
        SkinSelection.decode(UserDefaults.standard.string(forKey: skinKey))
    }

    /// The selection actually rendered. A custom control preset for this console forces the
    /// whole console to Invisible: the console-body dress is positioned around the
    /// DEFAULT button frames and can't track a custom layout (matches the picker, which
    /// disables the dressed skins while a preset is active).
    private var effectiveSelection: SkinSelection {
        if ControlLayoutStore.shared.activePreset(system: presetSystem) != nil { return .builtin(.invisible) }
        return storedSelection
    }

    /// Whether this console has a custom control preset active, so the dressed skins are
    /// unavailable and the picker is restricted to Invisible. Drives the picker sheet.
    var skinLockedToInvisible: Bool {
        ControlLayoutStore.shared.activePreset(system: presetSystem) != nil
    }

    /// The dress palette variant for the effective selection: Retro Pal recolour, a user custom
    /// palette, or Nostalgia. A custom skin whose palette was since deleted falls back to Nostalgia.
    private var dressVariant: DressVariant {
        switch effectiveSelection {
        case .builtin(.retroPal): return .retroPal
        case .builtin:            return .nostalgia
        case .custom(let id):
            if let skin = CustomSkinStore.shared.skin(id: id, system: presetSystem) {
                return .custom(skin.palette)
            }
            return .nostalgia
        }
    }

    /// The selection to pre-select in the picker (the effective one, so a preset-locked game
    /// shows Invisible selected; a custom skin shows its own card selected).
    var currentSkinForPicker: SkinSelection { effectiveSelection }

    /// The skin context the screenshot + clip cards carry: this game's card-style key, plus the
    /// current dress (+ display name) when it is Retro Pal or a custom skin — the card then offers
    /// (and defaults to) a "current skin" style. Nostalgia / Invisible (incl. preset-locked) games
    /// pass no skin, so their cards keep the two built-in looks.
    /// Per-game key for the screenshot + clip card-style choice. Empty / absent = the card
    /// follows the live in-game skin (see `ShareCardStyle.effective`).
    private var shareCardStyleKey: String {
        ShareCardStyle.choiceKey(forRom: romURL.deletingPathExtension().lastPathComponent)
    }

    private var shareCardSkinContext: ShareCardSkinContext {
        // The shared resolver (also used by the RA achievement card, which has no
        // live VC): same stored-skin decode, same preset-locks-to-Invisible rule.
        ShareCardSkinContext.forRom(romName: romURL.deletingPathExtension().lastPathComponent,
                                    system: presetSystem)
    }

    /// The console glyph asset for the Skin button (distinguishes GB vs GBC, which share
    /// the `.gbc` preset system); matches the `console-<system>` art used in library stats.
    private var skinIconAssetName: String {
        switch romURL.pathExtension.lowercased() {
        case "gb":  return "console-gb"
        case "gbc": return "console-gbc"
        case "nds": return "console-nds"
        default:    return "console-gba"
        }
    }

    func overlayDidSelectSkin(_ selection: SkinSelection) {
        let previous = storedSelection
        UserDefaults.standard.set(selection.serialized, forKey: skinKey)
        // The screenshot + clip card default mirrors the live in-game skin. When the skin
        // actually changes, drop any stale explicit Nostalgia / Classic card choice for this
        // game so the card re-defaults to the new skin (the `.skin` style then resolves to it).
        if selection != previous {
            UserDefaults.standard.removeObject(forKey: shareCardStyleKey)
        }
        // Re-apply the dress + console body from the new effective selection, live.
        layoutGameView()
    }

    /// The presented Appearance sheet, so its portrait detent can grow when the custom library
    /// gains its first row (or shrink when emptied). Weak — the sheet owns its own lifetime.
    private weak var skinSheetHost: UIViewController?
    /// Every console gets the tabbed sheet: the Screen tab holds the filters
    /// (all systems) and the DMG palettes (GB/GBC).
    private var appearanceShowsTabs: Bool { true }

    /// Apply the right detents for the given size: full height in landscape (previews-left /
    /// actions-right split), ONE content-fitted custom height in portrait — the taller of the
    /// two tabs, so switching Console/Screen never resizes the sheet. Shared by presentation,
    /// rotation, and library-change resizes — so the sheet is never left displaying the
    /// previous orientation's detent.
    private func applySkinSheetDetents(for size: CGSize, sheet: UISheetPresentationController) {
        if size.width > size.height {
            sheet.detents = [.large()]
        } else {
            let itemCount = 3 + CustomSkinStore.shared.skins(for: presetSystem).count
            let h = SkinSheetMetrics.appearancePortraitHeight(
                containerWidth: size.width, screenHeight: size.height, itemCount: itemCount,
                supportsCustom: presetSystem.supportsCustomSkins, locked: skinLockedToInvisible,
                showTabs: appearanceShowsTabs)
            sheet.detents = [.custom { _ in h }]
        }
    }

    /// Re-fit the picker sheet to a new size (rotation) or a changed library (create / delete),
    /// animated. No-op when the picker isn't presented.
    func updateSkinSheetDetents(for size: CGSize) {
        guard let sheet = skinSheetHost?.sheetPresentationController else { return }
        sheet.animateChanges { applySkinSheetDetents(for: size, sheet: sheet) }
    }

    /// This game's stored DMG palette id (per-game, Classic Green by default).
    private var storedPaletteID: String {
        GBPalettes.storedID(forRomBasename: romURL.deletingPathExtension().lastPathComponent)
    }

    /// Palette pick from the Appearance sheet's Screen tab: persist + apply
    /// live. The paused screen keeps its already-rendered frame; the new
    /// colors show from the next emulated frame (resume). The preview cards
    /// carry the recolored look meanwhile.
    private func overlayDidSelectPalette(_ palette: GBPalette) {
        let key = GBPalettes.storageKey(forRomBasename: romURL.deletingPathExtension().lastPathComponent)
        UserDefaults.standard.set(palette.id, forKey: key)
        session.applyGBPalette(palette)
    }

    /// Filter pick from the Appearance sheet's Screen tab (the UI only lets
    /// Pro users in; `effective` re-checks anyway): persist + live update.
    /// The Metal loop is paused under the sheet, so the change shows at
    /// resume — the preview cards carry the filtered look meanwhile.
    private func overlayDidSelectFilter(_ filter: VideoFilter) {
        let romName = romURL.deletingPathExtension().lastPathComponent
        UserDefaults.standard.set(filter.rawValue, forKey: VideoFilter.storageKey(forRomBasename: romName))
        metalView.videoFilter = VideoFilter.effective(forRomBasename: romName)
    }

    /// Opens the Appearance sheet (pause menu ▸ Appearance): the skin picker,
    /// tabbed with the Screen tab (palettes) on GB/GBC.
    func overlayDidTapSkin() {
        // The current game frame fills each preview's screen (like the screenshot card),
        // so a skin — or a palette — is judged against the real game, not a placeholder.
        let frame = session.createScreenshotImage().map { UIImage(cgImage: $0) }
        let sheet = AppearanceView(
            system: presetSystem,
            skinCurrent: currentSkinForPicker,
            lockedToInvisible: skinLockedToInvisible,
            gameImage: frame,
            realInsets: view.safeAreaInsets,
            onSelectSkin: { [weak self] selection in self?.overlayDidSelectSkin(selection) },
            onLibraryChanged: { [weak self] in
                guard let self else { return }
                self.updateSkinSheetDetents(for: self.view.bounds.size)
            },
            showScreenTab: appearanceShowsTabs,
            showPaletteSection: presetSystem == .gbc,
            paletteApplicable: session.isDMGPaletteApplicable,
            openPalette: GBPalettes.palette(id: storedPaletteID),
            initialPaletteID: storedPaletteID,
            onSelectPalette: { [weak self] palette in self?.overlayDidSelectPalette(palette) },
            initialFilterID: VideoFilter.effective(
                forRomBasename: romURL.deletingPathExtension().lastPathComponent).rawValue,
            onSelectFilter: { [weak self] filter in self?.overlayDidSelectFilter(filter) })

        let host = UIHostingController(rootView: sheet)
        host.modalPresentationStyle = .pageSheet
        // Same dark backing as the share-card sheets.
        host.view.backgroundColor = UIColor(red: 0.06, green: 0.04, blue: 0.08, alpha: 1)
        skinSheetHost = host

        if let presentation = host.sheetPresentationController {
            applySkinSheetDetents(for: view.bounds.size, sheet: presentation)
            presentation.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    func overlayDidTapQuit() {
        // Direct system review request (1.2.3): decided BEFORE persistPlayTime,
        // whose recordSessionEnd bumps sessionCount and zeroes the live
        // seconds — the trigger must see the session as it was played.
        var liveSessionSeconds = accumulatedPlaySeconds
        if session.isRunning {
            liveSessionSeconds += Date().timeIntervalSince(lastResumeTime)
        }
        let directReviewTrigger = PromptTracker.shared
            .directReviewRequestTrigger(currentSessionSeconds: liveSessionSeconds)

        persistPlayTime()
        // One bucketed signal per ended game session: how much people actually
        // play, per console (play depth vs conversion / churn).
        if sessionTotalPlaySeconds > 0 {
            Analytics.signal("play_session", [
                "system": ROMSystemType.from(fileExtension: romURL.pathExtension)?.rawValue ?? "unknown",
                "minutes": Self.playMinutesBucket(sessionTotalPlaySeconds)
            ])
            sessionTotalPlaySeconds = 0
        }
        metalView.stopRendering()
        // Leave immediately so Quit always feels instant. The auto-save +
        // teardown run on the serial IO queue; capturing `session` strongly keeps
        // the emulator state alive for that save even after this VC is gone.
        // The auto-save is UNCOORDINATED + atomic (coordinated: false): it can't
        // stall on the iCloud daemon (which can be slow or even erroring), so the
        // write lands promptly, savePreviewImage posts `.saveStatesDidChange`, and
        // the library + details thumbnails refresh right after. Emulation is
        // already paused (pause menu open), so the off-main read is race-free;
        // shutdown() is idempotent and the serial queue runs the save before it.
        let session = self.session
        onQuit?()
        // Fire the direct review request once the library is back on screen,
        // so the system dialog never lands over gameplay. `requestReview` is
        // silent when Apple's per-user quota is spent, so this repeating ask
        // costs nothing (see PromptTracker's two-path doc). The signal means
        // "requested", not "displayed" — Apple never reports the display.
        if let trigger = directReviewTrigger {
            PromptTracker.shared.recordDirectReviewRequested()
            Analytics.signal("review_prompt_shown", ["trigger": trigger])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }) {
                    SKStoreReviewController.requestReview(in: scene)
                }
            }
        }
        clipRecorder.stop()
        saveIOQueue.async {
            _ = session.autoSave(coordinated: false)
            session.shutdown()
        }
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
        sessionTotalPlaySeconds += accumulatedPlaySeconds
        accumulatedPlaySeconds = 0
    }

    /// Anonymous play-depth bucket for the play_session signal. Buckets, never
    /// raw durations: enough to correlate depth with conversion and churn,
    /// nothing that could fingerprint a user.
    private static func playMinutesBucket(_ seconds: TimeInterval) -> String {
        switch seconds / 60 {
        case ..<5: return "<5"
        case ..<15: return "5-15"
        case ..<30: return "15-30"
        case ..<60: return "30-60"
        default: return "60+"
        }
    }

    // MARK: - TouchControlsDelegate

    func touchControlsDidChange(buttons: UInt32) {
        session.setKeys(buttons)
    }

    func touchControlsMicBlowStateChanged(active: Bool) {
        session.setMicBlowActive(active)
        consoleSkin.micPressed = active   // shrink + recolour the dressed "MIC." label
    }

    // MARK: - Game Controller

    /// Route a connected controller's input through the same path as touch
    /// input, and hide the on-screen controls while a controller is connected.
    private func setupController() {
        let manager = ControllerManager.shared
        // This console family's custom button mapping (Pro; nil = built-in).
        manager.activeMapping = ControllerMappingStore.effective(for: presetSystem)
        manager.onButtonsChanged = { [weak self] mask in
            self?.session.setKeys(mask)
        }
        // The pad's spare menu-ish button (DS4/DualSense touchpad click, Xbox
        // Share) opens the pause menu, like the on-screen Menu button.
        manager.onMenuRequested = { [weak self] in
            guard let self, self.overlay.isHidden, self.presentedViewController == nil,
                  self.shareModel?.card == nil else { return }
            self.showOverlay()
        }
        // The pad's east button (Circle / B) is "back": it closes whatever
        // pause-y surface is up — a share card (screenshot/clip), a presented
        // sheet (Appearance, back to the menu), or the pause menu (resume) —
        // so the controller can always reach gameplay again. Alerts are never
        // swallowed (they demand an explicit choice). The closing press must
        // not leak into gameplay, so the input mask is dropped everywhere
        // (the release event re-syncs it).
        manager.onBackRequested = { [weak self] in
            guard let self else { return }
            if self.shareModel?.card != nil {
                // SwiftUI sheet: nil-ing the item dismisses it; its onDismiss
                // runs the unified resume.
                self.shareModel?.card = nil
                self.session.setKeys(0)
                return
            }
            if let presented = self.presentedViewController {
                guard !(presented is UIAlertController) else { return }
                presented.dismiss(animated: true)
                self.session.setKeys(0)
                return
            }
            if !self.overlay.isHidden {
                self.hideOverlay()
                self.session.setKeys(0)
            }
        }
        // Bound shortcut verbs (wave 2; unbound by default).
        manager.onActionChanged = { [weak self] action, pressed in
            self?.handleControllerAction(action, pressed: pressed)
        }
        manager.onKeyboardChanged = { [weak self] in
            self?.updateIdleTimer()
        }
        manager.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            // Drop any stale touch mask (e.g. a long-press-locked button) so
            // the controller starts from a clean slate.
            if connected { self.session.setKeys(0) }
            self.updateControlsVisibility()
            self.updateIdleTimer()
            // Re-lay the game view: hiding the controls frees space the screen
            // reclaims (NDS portrait/landscape, GBA landscape).
            self.layoutGameView()
        }
        updateControlsVisibility()  // a controller may already be connected
    }

    /// Speed active before a hold-to-fast-forward began (nil = no hold), and
    /// whether the hold muted the audio (so release restores it).
    private var ffHoldPriorSpeed: Double?
    private var ffHoldDidMute = false

    /// A bound controller shortcut changed state. Fast forward applies while
    /// HELD (3x, restoring the prior speed and any temporary mute on release —
    /// target speed owes device tuning); the card verbs act on press with the
    /// same guards as their on-screen buttons.
    private func handleControllerAction(_ action: RemapAction, pressed: Bool) {
        switch action {
        case .fastForward:
            if pressed {
                guard overlay.isHidden, session.isRunning, ffHoldPriorSpeed == nil else { return }
                ffHoldPriorSpeed = currentSpeed
                metalView.speedMultiplier = 3.0
                // Same courtesy as picking 3x/4x in the menu: don't blast
                // sped-up audio — but here only for the hold's duration.
                if !session.isAudioMuted {
                    ffHoldDidMute = true
                    setAudioMuted(true)
                    overlay.setSoundEnabled(false)
                }
            } else {
                guard let prior = ffHoldPriorSpeed else { return }
                ffHoldPriorSpeed = nil
                metalView.speedMultiplier = prior
                if ffHoldDidMute {
                    ffHoldDidMute = false
                    setAudioMuted(false)
                    overlay.setSoundEnabled(true)
                }
            }
        case .screenshot:
            guard pressed, overlay.isHidden, presentedViewController == nil,
                  shareModel?.card == nil else { return }
            presentScreenshotCard(autoDismiss: false)
        case .clip:
            guard pressed, overlay.isHidden, presentedViewController == nil,
                  shareModel?.card == nil else { return }
            presentClipCard(pauseAndResume: true)
        }
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

        // NDS portrait keeps the default stacked split (the old per-preset S/M/L
        // screen-size feature was removed; preset-driven free screen layout
        // replaces it).
        let isNDS = session.hasTouchScreen
        let controllerConnected = ControllerManager.shared.isConnected
        if isNDS {
            metalView.ndsTopScreenRatio = 0.495
        }

        metalView.ndsSideBySide = isLandscape && session.hasTouchScreen

        // Resolve the active preset into absolute view-space frames for every
        // component (screens + controls) — the same resolver the editor renders
        // from, so the two cannot drift. nil = the built-in default layout.
        // With a controller connected the preset is set aside: the on-screen
        // controls hide and the screens fill the reclaimed space, as before.
        let presetScene: PresetLayoutResolver.ResolvedScene?
        if !controllerConnected,
           let preset = ControlLayoutStore.shared.activePreset(system: presetSystem) {
            presetScene = PresetLayoutResolver.resolve(
                preset: preset, system: presetSystem, isLandscape: isLandscape,
                viewSize: viewSize, safeInsets: safeInsets)
        } else {
            presetScene = nil
        }

        if let scene = presetScene {
            if isNDS, let top = scene.screens[.top], let bottom = scene.screens[.bottom] {
                // The metal view spans the whole view; each screen renders as a
                // quad at its preset rect, with its own alpha.
                metalView.frame = view.bounds
                metalView.ndsCustomScreens = (
                    top: EmulatorMetalView.CustomScreenQuad(rect: top.frame, alpha: top.opacity),
                    bottom: EmulatorMetalView.CustomScreenQuad(rect: bottom.frame, alpha: bottom.opacity))
                metalView.alpha = 1
            } else {
                // Single screen: the metal frame IS the screen; opacity applies
                // at the view level.
                metalView.ndsCustomScreens = nil
                let main = scene.screens[.main]
                if let frame = main?.frame { metalView.frame = frame }
                metalView.alpha = main?.opacity ?? 1
            }
        } else {
            // Built-in default: screen frame + control reserves from the single
            // geometry engine, which scales every absolute length by the device
            // factor (1.0 on the reference iPhone 14 Pro).
            metalView.ndsCustomScreens = nil
            metalView.alpha = 1
            metalView.frame = EmulatorLayoutGeometry.screenFrame(
                deviceSize: viewSize, safeInsets: safeInsets,
                hasTouchScreen: session.hasTouchScreen, isLandscape: isLandscape,
                gameAspect: gameAspect, system: presetSystem, controllerConnected: controllerConnected,
                deviceScale: EmulatorLayoutGeometry.deviceScale(for: viewSize))
        }

        // One canonical stacking, preset or not: screens below, stylus overlay
        // above them, controls on top (set once in viewDidLoad). A control
        // placed over a screen stays visible and usable, and Menu is always
        // reachable. Under a preset the controls span the whole view, so they
        // claim only the touches that land on a control (pass-through below)
        // and let the rest reach the stylus overlay / screens.
        controls.passThroughUnusedTouches = (presetScene != nil)

        applyControlConstraints(isLandscape: isLandscape, presetScene: presetScene)

        // Console dress: fill the view, frame the game screen, hide it unless this system
        // has a skin and the built-in default layout is in use (custom presets stay plain).
        consoleSkin.frame = view.bounds
        consoleSkin.screenFrame = metalView.frame
        consoleSkin.deviceScale = EmulatorLayoutGeometry.deviceScale(for: viewSize)
        consoleSkin.usesJoystick = UserDefaults.standard.bool(forKey: "useJoystick")
        consoleSkin.variant = dressVariant   // Nostalgia / Retro Pal / custom recolour
        // Skin-driven: hidden for Invisible (which `effectiveSelection` also returns when a
        // custom preset is active) or for a system with no dress at all.
        consoleSkin.isHidden = !ConsoleSkinView.hasSkin(for: presetSystem) || !effectiveSelection.isDressed

        // NDS dual-screen sub-frames (physical order: portrait [top, bottom], landscape
        // [left, right]) — one source of truth, shared by the console dress (screen outlines +
        // speakers) and the touch overlay. Touch content sits on the swapped primary (top/left),
        // otherwise the secondary (bottom/right).
        // Default: opaque black metalView, square corners (GBA/GB + undressed NDS).
        metalView.layer.mask = nil
        metalView.isOpaque = true
        metalView.backgroundColor = .black
        if let scene = presetScene {
            // Preset screens: the NDS metal view spans the whole view, so it
            // must not paint outside its quads (clears to transparent around
            // them); the single-screen consoles' frame IS the screen and their
            // opacity rides on the view alpha set above.
            metalView.isOpaque = false
            if isNDS { metalView.backgroundColor = .clear }
            consoleSkin.ndsScreens = []
            if session.hasTouchScreen, let touchOverlay = ndsTouchOverlay {
                // The stylus overlay tracks wherever the touch screen's CONTENT
                // is (the swap setting moves it to the other quad).
                let swapped = UserDefaults.standard.bool(forKey: "ndsSwapScreens")
                if let target = swapped ? scene.screens[.top] : scene.screens[.bottom] {
                    touchOverlay.frame = target.frame
                }
            }
        } else if session.hasTouchScreen {
            let (primary, secondary) = ndsScreenRects(in: metalView.frame, isLandscape: isLandscape)
            consoleSkin.ndsScreens = [primary, secondary]
            if let touchOverlay = ndsTouchOverlay {
                let swapped = UserDefaults.standard.bool(forKey: "ndsSwapScreens")
                touchOverlay.frame = swapped ? primary : secondary
            }
            // When the NDS dress is showing, clip the metalView to just the two screens with
            // rounded corners (concentric with the skin's +2pt / 4pt printed rim). This rounds
            // the screen corners to "fit" the outline AND drops the black letterbox gutters so the
            // dressed body shows everywhere behind the screens (not just the controls area).
            if !consoleSkin.isHidden {
                let corner = 2 * EmulatorLayoutGeometry.deviceScale(for: viewSize)
                let maskPath = UIBezierPath()
                for s in [primary, secondary] {
                    let local = s.offsetBy(dx: -metalView.frame.minX, dy: -metalView.frame.minY)
                    maskPath.append(UIBezierPath(roundedRect: local, cornerRadius: corner))
                }
                let mask = CAShapeLayer()
                mask.path = maskPath.cgPath
                metalView.layer.mask = mask
                metalView.isOpaque = false
                metalView.backgroundColor = .clear
            }
        } else {
            consoleSkin.ndsScreens = []
        }
    }

    /// The two NDS game-screen sub-frames within the combined metal frame, in physical order:
    /// portrait (top, bottom), landscape (left, right). Mirrors the Metal view's split so the
    /// console dress and the touch overlay agree on screen geometry.
    private func ndsScreenRects(in metalFrame: CGRect, isLandscape: Bool) -> (CGRect, CGRect) {
        let aspect: CGFloat = 256.0 / 192.0
        if isLandscape {
            var w = metalFrame.width / 2.0
            var h = w / aspect
            if h > metalFrame.height { h = metalFrame.height; w = h * aspect }
            let y = metalFrame.origin.y + (metalFrame.height - h) / 2.0
            let leftX = metalFrame.origin.x + metalFrame.width / 2.0 - w
            let rightX = metalFrame.origin.x + metalFrame.width / 2.0
            return (CGRect(x: leftX, y: y, width: w, height: h),
                    CGRect(x: rightX, y: y, width: w, height: h))
        } else {
            let topRatio = CGFloat(metalView.ndsTopScreenRatio)
            let gapRatio: CGFloat = 0.01
            let botRatio = 1.0 - topRatio - gapRatio
            let topScreenH = metalFrame.height * topRatio
            let botScreenH = metalFrame.height * botRatio
            let gapH = metalFrame.height * gapRatio
            var topW = metalFrame.width
            var topH = topW / aspect
            if topH > topScreenH { topH = topScreenH; topW = topH * aspect }
            var botW = metalFrame.width
            var botH = botW / aspect
            if botH > botScreenH { botH = botScreenH; botW = botH * aspect }
            let topX = metalFrame.origin.x + (metalFrame.width - topW) / 2.0
            let botX = metalFrame.origin.x + (metalFrame.width - botW) / 2.0
            let botY = metalFrame.origin.y + topScreenH + gapH
            return (CGRect(x: topX, y: metalFrame.origin.y, width: topW, height: topH),
                    CGRect(x: botX, y: botY, width: botW, height: botH))
        }
    }

    /// Controls still use Auto Layout (they're standard UI, not performance-critical)
    private func applyControlConstraints(isLandscape: Bool,
                                         presetScene: PresetLayoutResolver.ResolvedScene?) {
        // Remove old control constraints
        for constraint in view.constraints {
            if constraint.firstItem === controls || constraint.secondItem === controls {
                view.removeConstraint(constraint)
            }
        }

        if presetScene != nil {
            // Preset: the controls container spans the WHOLE view, because the
            // resolver hands back absolute view-space coordinates (screens are
            // free-floating components, so "below the screen" means nothing).
            NSLayoutConstraint.activate([
                controls.topAnchor.constraint(equalTo: view.topAnchor),
                controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        } else if isLandscape {
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

        // Force a layout pass so controls.bounds is valid before positioning buttons.
        view.layoutIfNeeded()

        let deviceScale = EmulatorLayoutGeometry.deviceScale(for: view.bounds.size)
        // Leading safe-area inset (Dynamic Island side in landscape) — keeps the GB/GBC
        // landscape D-pad out from under the island.
        let safeLeftInset = view.safeAreaInsets.left
        if let scene = presetScene {
            // Active preset: per-component centers/sizes/opacity from the
            // resolved scene, exactly as the editor showed them.
            controls.applyResolvedScene(buttons: scene.buttons, useJoystick: scene.useJoystick)
        } else {
            // No preset: the built-in default layout with the global opacity/size.
            controls.applyDefaultLayout(isLandscape: isLandscape, system: presetSystem,
                                        deviceScale: deviceScale, safeLeftInset: safeLeftInset)
        }

        // Dress the buttons (maroon A/B, grey pills, charcoal cross) when the system's buttons
        // have a dress AND the built-in default layout is in use. Tracks the console skin, but
        // NDS shows its body/screen dress before its buttons are dressed (later slice).
        // Skin-driven: dressed only for a dressed skin (`effectiveSelection` returns Invisible
        // when a custom preset is active, so custom layouts stay undressed as before). The
        // variant selects the Nostalgia / Retro Pal / custom recolour.
        controls.setDressed(effectiveSelection.isDressed
            && ConsoleSkinView.hasDressedControls(for: presetSystem),
            isLandscape: isLandscape, system: presetSystem, variant: dressVariant)

        // Hand the console dress the resolved button frames so it can place decorations
        // (and later, wells) clear of the controls. Resolve the frames first.
        controls.layoutIfNeeded()
        consoleSkin.buttonFrames = controls.visibleButtonFrames(in: consoleSkin)
        // Controller mode: the dress hides/repositions its controls-relative decorations. It also
        // needs the hidden buttons' frames (still laid out at their normal spots) to anchor to.
        consoleSkin.allButtonFrames = controls.allButtonFrames(in: consoleSkin)
        consoleSkin.controllerConnected = ControllerManager.shared.isConnected
    }

    // MARK: - Emulation

    private func showLoadFailed() {
        statusLabel.text = String(format: NSLocalizedString("emulator.loadFailed", comment: ""), romURL.lastPathComponent)
    }

    /// Resolve this NDS game's slot-2 preference (`gbaSlot2_<rom>` = the GBA
    /// game's stored ROM filename) and hand it to the session before boot.
    /// Fail-soft everywhere: a missing file (GBA game deleted since) just
    /// boots with an empty slot, exactly like removing the cart.
    private func configureGBASlot2IfNeeded() {
        guard romURL.pathExtension.lowercased() == "nds" else { return }
        let ndsBasename = romURL.deletingPathExtension().lastPathComponent
        guard let storedFilename = UserDefaults.standard.string(forKey: "gbaSlot2_\(ndsBasename)"),
              !storedFilename.isEmpty else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let gbaROM = docs.appendingPathComponent("ROMs", isDirectory: true)
            .appendingPathComponent(storedFilename)
        guard FileManager.default.fileExists(atPath: gbaROM.path) else { return }
        let saveBasename = BatterySaveImporter.romBasename(forStoredFilename: storedFilename)
        let savePath = BatterySaveImporter.savePath(forRomBasename: saveBasename)
        session.configureGBASlot2(romPath: gbaROM.path,
                                  savePath: savePath.path,
                                  saveBasename: saveBasename)
        // The NDS dress shows the inserted game's box art in a recessed square
        // (portrait). Same cover chain as the library rows; no cover -> no
        // square (nil), never an empty well.
        consoleSkin.slot2Cover = slot2CoverImage(storedFilename: storedFilename)
    }

    /// The slot-2 GBA game's cover image for the dress, resolved through the
    /// library's cover-priority chain (custom > adopted RA > downloaded).
    /// nil when the game has no cover on disk.
    private func slot2CoverImage(storedFilename: String) -> UIImage? {
        let request = NSFetchRequest<GameEntity>(entityName: "GameEntity")
        request.predicate = NSPredicate(format: "romFilePath == %@", storedFilename)
        request.fetchLimit = 1
        guard let game = try? PersistenceController.shared.container.viewContext
            .fetch(request).first else { return nil }
        guard let url = BoxArtManager.shared.coverFileURL(
            forROMHash: game.romHash, coverType: game.coverType) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private func loadAndStart() {
        statusLabel.text = NSLocalizedString("emulator.loading", comment: "")

        // Pre-flight the ROM file before the core touches it. A previously-good
        // file can go missing or get truncated/corrupted on disk — the cause of
        // the rare "won't load" black screen that only delete + re-import fixes.
        // Catch it here, log the specifics, and show an actionable message.
        let fm = FileManager.default
        let onDiskSize = ((try? fm.attributesOfItem(atPath: romURL.path))?[.size] as? NSNumber)?.int64Value
        let exists = fm.fileExists(atPath: romURL.path)
        let sizeMismatch = expectedROMSize > 0 && onDiskSize != nil && onDiskSize != expectedROMSize
        if !exists || onDiskSize == nil || onDiskSize == 0 || sizeMismatch {
            let diag = "exists=\(exists) size=\(onDiskSize ?? -1) expected=\(expectedROMSize) file=\(romURL.lastPathComponent)"
            Self.romLoadLog.error("ROM preflight failed: \(diag, privacy: .public)")
            showLoadFailed()
            return
        }

        // Slot-2 dual-slot: mount this NDS game's chosen GBA game before the
        // core boots (carts are probed at boot, like on real hardware).
        configureGBASlot2IfNeeded()

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
            // Per-game hold-to-lock preference (off by default — bool() is false when unset).
            controls.buttonLockEnabled = UserDefaults.standard.bool(forKey: buttonLockKey)
            lastResumeTime = Date()
            accumulatedPlaySeconds = 0
            statusLabel.text = nil
            metalView.attach(session: session)
            metalView.clipRecorder = clipRecorder
            clipRecorder.start()
            // Directly recalculate layout now that we know the actual screen
            // dimensions. Can't rely on setNeedsLayout because viewDidLayoutSubviews
            // won't fire again if the view's bounds haven't changed.
            layoutGameView()
            session.start()
            // This game's stored DMG palette (Classic Green default). No-op
            // for GBA/NDS; ignored by CGB-mode games (their own colors win).
            session.applyGBPalette(GBPalettes.palette(id: storedPaletteID))
            // This game's display filter (Pro; .none otherwise or unset).
            metalView.videoFilter = VideoFilter.effective(
                forRomBasename: romURL.deletingPathExtension().lastPathComponent)
            session.isAudioMuted = UserDefaults.standard.bool(forKey: "audioMuted")
            metalView.startRendering()

            // One-time "ever played" signal, mirroring import_first: completes
            // the activation funnel (installed -> imported -> actually played)
            // and splits imported-never-played churn from played-then-left.
            if !UserDefaults.standard.bool(forKey: "didStartFirstGame") {
                UserDefaults.standard.set(true, forKey: "didStartFirstGame")
                Analytics.signal("first_game_started")
            }

            // Auto-apply saved cheat codes for this game
            applySavedCheats()
        } else {
            // File looked intact on disk but the core rejected it. Log size/exists
            // so a recurrence is diagnosable (MGBABridge also NSLogs which mGBA
            // step failed: detect / open / loadROM).
            let diag = "core rejected: size=\(onDiskSize ?? -1) expected=\(expectedROMSize) file=\(romURL.lastPathComponent)"
            Self.romLoadLog.error("\(diag, privacy: .public)")
            Analytics.signal("rom_load_fail", ["system": ROMSystemType.from(fileExtension: romURL.pathExtension)?.rawValue ?? "unknown"])
            showLoadFailed()
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
}
