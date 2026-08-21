//
//  ExternalDisplayManager.swift
//  EmulateurGBA
//
//  Owns the window on a connected TV (AirPlay or cable) and decides what it
//  shows: the running game, or the wordmark when nothing is running.
//
//  Scope, deliberately: this ADDS an output. It changes nothing about the
//  phone's own layout, which is EmulatorLayoutGeometry's territory and stays
//  closed (see the controls-layout notes). Making the phone a pure controller
//  is a later, separate pass.
//
//  Pro feature, and the gate is structural rather than cosmetic: the moment we
//  put a window on the external scene, iOS stops mirroring the phone and shows
//  ours instead. So for a free user we create NO window at all, and their
//  system mirroring keeps working exactly as it does today. Pro adds a
//  dedicated full-screen output; nothing is taken away from anyone.
//

import UIKit

final class ExternalDisplayManager {
    static let shared = ExternalDisplayManager()
    private init() {}

    /// Posted when `isShowingGame` flips, so the emulator can re-evaluate
    /// whether the phone still needs to stay awake.
    static let didChangeNotification = Notification.Name("ExternalDisplayManager.didChange")

    /// True while a television is actually showing the running game (Pro,
    /// connected, and a game handed over). Not merely "a TV is plugged in".
    private(set) var isShowingGame = false {
        didSet {
            guard isShowingGame != oldValue else { return }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Stored globally, not per game: it describes the television, not the title.
    static let ndsSideBySideKey = "externalDisplayNDSSideBySide"

    /// The connected TV's scene, if any. Kept so the window can still be built
    /// later, e.g. when Pro is purchased while the TV is already plugged in.
    private weak var connectedScene: UIWindowScene?

    /// True while a television is connected to the app at all, by AirPlay or by
    /// cable.
    ///
    /// Deliberately NOT the same question as `isShowingGame`, which also demands
    /// Pro and a game already handed over. This is the plain "is there a screen
    /// there", which is the only one a settings screen can usefully ask: no game
    /// is running while Settings is open, so `isShowingGame` is false there even
    /// with a television plugged in and working.
    ///
    /// The scene reference is weak, so if it ever went away without its
    /// disconnect callback this reads false. That is the safe direction: the app
    /// offers the connection guide for a television that IS there, rather than a
    /// screen-arrangement picker for one that is not.
    var isTVConnected: Bool { connectedScene != nil }
    private var window: UIWindow?
    private var screenVC: ExternalScreenViewController?
    /// The live game view. Weak: the emulator view controller owns it and its
    /// lifetime must not depend on us.
    private weak var source: EmulatorMetalView?

    /// Side by side unless the user chose stacked. Nothing registers a default,
    /// so an absent key must read as `true`, hence the explicit object check.
    var ndsSideBySide: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Self.ndsSideBySideKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Self.ndsSideBySideKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.ndsSideBySideKey)
            screenVC?.sideBySide = newValue
        }
    }

    /// Read straight from UserDefaults rather than through ProManager, whose
    /// flag is main-actor isolated (the approach SaveStateManager already takes).
    private var isPro: Bool { UserDefaults.standard.bool(forKey: "isPro") }

    /// True for the window we put on the TV. The app delegate asks this so the
    /// per-game orientation lock stays a phone concern: without it, a game
    /// pinned to portrait would pin the television to portrait too.
    func isExternalWindow(_ window: UIWindow?) -> Bool {
        guard let window, let ours = self.window else { return false }
        return window === ours
    }

    // MARK: - Scene lifecycle

    func sceneDidConnect(_ scene: UIWindowScene) {
        let wasConnected = isTVConnected
        connectedScene = scene
        update()
        // `isShowingGame` does not move on a bare connection (no game is handed
        // over yet), so its own didSet posts nothing. Settings watches this
        // notification to swap its row between the connection guide and the
        // screen-arrangement picker, and that swap has to happen the moment the
        // television appears.
        if !wasConnected { notifyChanged() }
    }

    func sceneDidDisconnect(_ scene: UIWindowScene) {
        guard connectedScene === scene || window?.windowScene === scene else { return }
        let wasConnected = isTVConnected
        connectedScene = nil
        teardownWindow()
        if wasConnected { notifyChanged() }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Game lifecycle

    /// Called by the emulator view controller when a game starts, and with nil
    /// when it shuts down.
    func setSource(_ source: EmulatorMetalView?) {
        self.source = source
        update()
    }

    // MARK: - Wiring

    private func update() {
        guard let scene = connectedScene, isPro else {
            teardownWindow()
            return
        }
        if window == nil { buildWindow(on: scene) }
        guard let screenVC else { isShowingGame = false; return }
        if let source {
            screenVC.attach(source: source)
        } else {
            screenVC.detach()
        }
        screenVC.sideBySide = ndsSideBySide
        isShowingGame = source != nil
    }

    private func buildWindow(on scene: UIWindowScene) {
        let vc = ExternalScreenViewController()
        vc.sideBySide = ndsSideBySide
        let window = UIWindow(windowScene: scene)
        window.rootViewController = vc
        // Never makeKeyAndVisible: the phone's window must keep key status.
        window.isHidden = false
        self.window = window
        self.screenVC = vc
    }

    private func teardownWindow() {
        isShowingGame = false
        screenVC?.detach()
        window?.isHidden = true
        window = nil
        screenVC = nil
    }
}
