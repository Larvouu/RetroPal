//
//  EmulateurGBAApp.swift
//  EmulateurGBA
//
//  Created by Retro Pal on 24/03/2026.
//

import SwiftUI

@main
struct EmulateurGBAApp: App {
    // Provides the window-level orientation hook (see AppDelegate) so the
    // per-game orientation lock holds against physical rotation.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let persistenceController = PersistenceController.shared

    init() {
        // Pre-warm the iCloud container resolution so it has a chance
        // to settle before the user opens their first game. Resolution
        // runs on a background queue inside `iCloudSaveSync`; this
        // call is cheap (just the singleton's lazy init).
        _ = iCloudSaveSync.shared

        // Anonymous analytics (opt-out, default ON). No-op if the user opted out.
        Analytics.start()
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .preferredColorScheme(.dark)
        }
    }
}
