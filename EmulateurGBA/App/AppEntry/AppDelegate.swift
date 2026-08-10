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

/// The orientations the app currently permits. Defaults to "all but upside
/// down" (the library and any auto-rotating game). The emulator narrows it to
/// a single orientation while a game is pinned to Landscape or Portrait, then
/// restores the default when the game is dismissed.
enum AppOrientationLock {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
}

final class AppDelegate: NSObject, UIApplicationDelegate {
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
