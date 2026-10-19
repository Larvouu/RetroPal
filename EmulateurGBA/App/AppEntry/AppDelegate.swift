//
//  AppDelegate.swift
//  EmulateurGBA
//
//  Hosts the window-level orientation hook. The emulator view controller is
//  nested deep inside a SwiftUI `.fullScreenCover`, so the system never queries
//  *its* `supportedInterfaceOrientations` when the device rotates. The only
//  orientation authority iOS always consults is the app delegate's
//  `application(_:supportedInterfaceOrientationsFor:)`. We route that through a
//  shared mask the emulator updates, which is what makes a per-game orientation
//  lock actually hold against physical rotation (and against the iOS lock).
//

import UIKit

/// The orientations the app currently permits. Defaults to `unlocked` (the
/// library and any auto-rotating game). The emulator narrows it to a single
/// orientation while a game is pinned to Landscape or Portrait, then restores
/// the default when the game is dismissed.
enum AppOrientationLock {
    /// The resting mask. A phone never turns upside down; an iPad does, the
    /// way every iPad app does (2026-09-05, with the iPad build), and
    /// `Info.plist` already lists the four iPad orientations.
    static let unlocked: UIInterfaceOrientationMask =
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    static var mask: UIInterfaceOrientationMask = unlocked
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The app's own window scene gets `MainSceneDelegate`, which is where iOS
    /// hands a Home Screen quick action. The television's scene keeps the
    /// delegate Info.plist names for its role (`ExternalDisplaySceneDelegate`).
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: connectingSceneSession.configuration.name,
                                                 sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = MainSceneDelegate.self
        } else {
            configuration.delegateClass = connectingSceneSession.configuration.delegateClass
        }
        return configuration
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // The per-game lock is a PHONE concern. This hook is asked about every
        // window, so once a television is connected an un-checked mask would
        // pin the TV to the game's orientation too — a portrait-locked game
        // would rotate the whole television.
        if ExternalDisplayManager.shared.isExternalWindow(window) { return .all }
        return AppOrientationLock.mask
    }
}

/// The app window's scene delegate, for one thing only: the Home Screen quick
/// action (`FeedbackQuickAction`). SwiftUI still builds and owns the window;
/// this class adds no window of its own.
///
/// iOS delivers the action two ways: in the connection options when the tap
/// cold-launches the app, and through `windowScene(_:performActionFor:)` when
/// the app was already running.
final class MainSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// A cold launch's action, kept until the scene is active: opening another
    /// app while the scene is still connecting is not reliable.
    private var pendingItem: UIApplicationShortcutItem?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        pendingItem = connectionOptions.shortcutItem
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let item = pendingItem else { return }
        pendingItem = nil
        FeedbackQuickAction.handle(item)
    }

    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(FeedbackQuickAction.handle(shortcutItem))
    }
}
