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
        // LAUNCHPROBE #if DEBUG
        // LAUNCHPROBE LaunchProbe.startWatchdog()
        // LAUNCHPROBE LaunchProbe.mark("App.init start")
        // LAUNCHPROBE #endif
        // The play history is made HERE, on the main thread, before anything
        // else can reach it (2026-11-02). Its one-time setup reads the Keychain
        // and the disk, and a `static let` made by one thread makes every other
        // thread wait for it: the iCloud pass reached it first on a background
        // queue, the library then asked for it on the main thread, and when
        // that setup did not return the main thread waited with it and the app
        // never drew its first frame (launches from Xcode, the iPhone and the
        // iPad, `LaunchProbe`'s log: "PlayHistory.init start" on a background
        // queue, then the main thread stopped at "Library.refreshStats start").
        // Made first on the main thread, nothing ever waits on another
        // thread's setup, and a setup that is slow is slow here, in the open.
        _ = PlayHistory.shared
        // LAUNCHPROBE #if DEBUG
        // LAUNCHPROBE LaunchProbe.mark("App.init PlayHistory.shared done")
        // LAUNCHPROBE #endif

        // Pre-warm the iCloud container resolution so it has a chance
        // to settle before the user opens their first game. Resolution
        // runs on a background queue inside `iCloudSaveSync`; this
        // call is cheap (just the singleton's lazy init).
        _ = iCloudSaveSync.shared
        // LAUNCHPROBE #if DEBUG
        // LAUNCHPROBE LaunchProbe.mark("App.init iCloudSaveSync.shared done")
        // LAUNCHPROBE #endif

        // Anonymous analytics (opt-out, default ON). No-op if the user opted out.
        Analytics.start()
        // LAUNCHPROBE #if DEBUG
        // LAUNCHPROBE LaunchProbe.mark("App.init Analytics.start done")
        // LAUNCHPROBE #endif

        // The folders of disc imports that never finished (the app killed mid-copy),
        // and what an archive import killed midway left in tmp.
        let sweepContext = persistenceController.container.newBackgroundContext()
        DispatchQueue.global(qos: .utility).async {
            ROMImporter.sweepAbandonedImports(context: sweepContext)
            CTRSaveData.sweepImportScratch()
            GameArchive.sweepScratch()
            // LAUNCHPROBE #if DEBUG
            // LAUNCHPROBE LaunchProbe.mark("launch sweeps done")
            // LAUNCHPROBE #endif
        }
        // LAUNCHPROBE #if DEBUG
        // LAUNCHPROBE LaunchProbe.mark("App.init end")
        // LAUNCHPROBE #endif
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .preferredColorScheme(.dark)
        }
    }
}
