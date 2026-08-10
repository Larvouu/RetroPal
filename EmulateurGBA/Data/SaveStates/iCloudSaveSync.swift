//
//  iCloudSaveSync.swift
//  EmulateurGBA
//
//  LOCAL-FIRST save-state sync (see SAVE_SYNC_LOCAL_FIRST.md).
//
//  The device's local `Documents/SaveStates/` is the SOURCE OF TRUTH: every
//  manual-slot read and write goes there (via `saveStatesURL(forROM:)`), so
//  whether the user can SEE their saves never depends on iCloud being reachable,
//  resolved, or un-evicted. iCloud is a MIRROR layer on top: when the container
//  is available, `SaveSyncReconciler` mirrors the local tree <-> the iCloud
//  container in both directions, non-destructively (newest is active, the loser
//  is archived locally, never deleted; conflicts never pushed back up).
//
//  Reconcile runs whenever iCloud becomes reachable (container resolve + every
//  NSMetadataQuery update) and after local writes (observing `.saveStatesDidChange`
//  and `.batterySavesDidChange`), so a device that was offline / had iCloud
//  unavailable recovers automatically the moment it comes back.
//
//  BATTERY SAVES (1.2.4): every pass also mirrors `Documents/BatterySaves/*.sav`
//  (the in-game progress) with the same engine and rules, EXCEPT the save of the
//  live emulation session, which is skipped in both directions while the core
//  holds the file open (see SaveSyncReconciler's header) and reconciles at quit
//  (EmulatorSession.shutdown posts `.batterySavesDidChange`) or on the next pass.
//
//  Decisions carried from the 2026-05-15 eng review (still hold):
//  - iCloud Documents, NOT Core Data sync (cheap, reliable for a few-MB binary).
//  - mtime-wins conflict resolution — but the loser is preserved, not destroyed
//    (the redesign's safety net; a date can't distinguish "newer version" from
//    "different playthrough").
//  - `URLForUbiquityContainerIdentifier` resolves on a background queue with retry
//    + a hard deadline (the daemon can return nil while warming up, or hang).
//
//  PRECONDITION (Xcode side): the target must carry the iCloud capability with
//  iCloud Documents enabled and container `iCloud.com.retropal`, committed to git
//  (the `.entitlements` file + `CODE_SIGN_ENTITLEMENTS`). Without it,
//  `url(forUbiquity...)` returns nil on every device and routing stays local —
//  saves are still safe (local-first), just not mirrored.
//

import Foundation
import Combine

final class iCloudSaveSync: ObservableObject, @unchecked Sendable {

    /// App-wide instance. Pre-warmed at app launch by `EmulateurGBAApp.init` so
    /// the container URL resolution starts before the user opens a game.
    static let shared = iCloudSaveSync()

    enum State: Equatable {
        /// Just launched. Resolution is in flight on a background queue.
        case resolving
        /// iCloud is available; the local tree is mirrored to the container.
        case available
        /// Signed out, iCloud Drive off, capability missing, or resolution failed.
        /// Saves are still fully usable from local; they just aren't mirrored.
        case unavailable
    }

    /// Current state, safe from any thread.
    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    private let containerID = "iCloud.com.retropal"
    /// User preference: mirror saves to iCloud when available. Default true (opt-out).
    private let syncEnabledKey = "iCloudSyncEnabled"
    /// Sticky flag: set once iCloud has ever resolved with save files present, so we
    /// only warn about "iCloud unavailable" users who actually had cloud saves.
    private let hasSeeniCloudSavesKey = "hasSeeniCloudSaves"

    private let lock = NSLock()
    private var _state: State = .resolving
    private var _iCloudRoot: URL?
    private var _iCloudBatteryRoot: URL?

    private var metadataQuery: NSMetadataQuery?
    /// Debounce for the outward `.saveStatesDidChange` UI notification.
    private var pendingNotificationWork: DispatchWorkItem?

    /// Serial queue for reconcile passes; `syncScheduled` coalesces a burst into one.
    private let syncQueue = DispatchQueue(label: "com.retropal.savesync.reconcile", qos: .utility)
    private var syncScheduled = false

    private init() {
        // Mirror to / from iCloud after any local write (manual save, etc.).
        NotificationCenter.default.addObserver(
            forName: .saveStatesDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.syncNow()
        }
        // Same for battery-save writes (session quit, per-game save import).
        NotificationCenter.default.addObserver(
            forName: .batterySavesDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.syncNow()
        }
        // url(forUbiquityContainerIdentifier:) can block (it talks to the iCloud
        // daemon) so it MUST run off the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.resolveUbiquityContainer()
        }
    }

    // MARK: - User preference (opt-out)

    var syncEnabled: Bool {
        UserDefaults.standard.object(forKey: syncEnabledKey) as? Bool ?? true
    }

    /// Whether iCloud has ever held save files for this user.
    var hasSeeniCloudSaves: Bool {
        UserDefaults.standard.bool(forKey: hasSeeniCloudSavesKey)
    }

    /// True when the user expects iCloud, it's down, and they actually had cloud
    /// saves — the condition under which the save UI should warn instead of showing
    /// an empty list. Brand-new / no-iCloud users never trip this.
    var shouldWarnUnavailable: Bool {
        syncEnabled && state == .unavailable && hasSeeniCloudSaves
    }

    /// Flip the iCloud-mirror preference. Local stays authoritative either way.
    /// Turning ON resumes mirroring; turning OFF first pulls anything cloud-only
    /// down so local is complete, then stops mirroring (existing cloud copies are
    /// left untouched in the user's iCloud).
    func setSyncEnabled(_ enabled: Bool) {
        guard enabled != syncEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: syncEnabledKey)
        Analytics.signal("icloud_sync_toggled", ["enabled": enabled ? "true" : "false"])
        if enabled {
            startMetadataQuery()
            syncNow()
        } else {
            // syncEnabled is already false, so the normal guarded path would skip;
            // force one last reconcile to guarantee local completeness.
            syncQueue.async { [weak self] in self?.reconcileOnce(force: true) }
        }
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: - Public routing API (thread-safe)

    /// Directory in which `SaveStateManager` places files for a ROM. ALWAYS local
    /// now: the local tree is the working directory; iCloud is mirrored separately.
    func saveStatesURL(forROM romName: String) -> URL {
        let url = Self.localSaveStatesRoot().appendingPathComponent(romName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Reconcile (the mirror)

    /// Request a reconcile pass; coalesces a burst into a single run shortly after.
    func syncNow() {
        lock.lock()
        if syncScheduled { lock.unlock(); return }
        syncScheduled = true
        lock.unlock()
        syncQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.syncScheduled = false; self.lock.unlock()
            self.reconcileOnce(force: false)
        }
    }

    /// One reconcile pass on the current queue. `force` bypasses the opt-out gate
    /// (used by sync-off so local is made complete before mirroring stops).
    /// Covers both trees: save states, then battery saves (minus the live
    /// session's file, which the core holds open).
    private func reconcileOnce(force: Bool) {
        if !force && !syncEnabled { return }
        let roots: (states: URL, battery: URL)? = {
            lock.lock(); defer { lock.unlock() }
            guard _state == .available, let s = _iCloudRoot, let b = _iCloudBatteryRoot else { return nil }
            return (s, b)
        }()
        guard let roots else { return }

        var reconciler = SaveSyncReconciler(localRoot: Self.localSaveStatesRoot(), cloudRoot: roots.states)
        reconciler.materialize = { Self.materializeUbiquitousItem($0) }
        let stateResult = reconciler.reconcile()

        var battery = SaveSyncReconciler(localRoot: BatterySaveImporter.batterySavesRoot,
                                         cloudRoot: roots.battery)
        battery.materialize = { Self.materializeUbiquitousItem($0) }
        let batteryResult = battery.reconcileBatterySaves(
            skipping: BatterySaveImporter.activeSessionBasenames)

        if stateResult.cloudHadFiles || batteryResult.cloudHadFiles, !hasSeeniCloudSaves {
            UserDefaults.standard.set(true, forKey: hasSeeniCloudSavesKey)
            DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        }
        if stateResult.localChanged || batteryResult.localChanged {
            postCoalescedNotification()   // a pull happened: refresh slot UI
        }
    }

    /// Materialize a possibly-evicted iCloud file before reading it. Runs on the
    /// reconcile (background) queue, so the bounded poll is safe.
    private static func materializeUbiquitousItem(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        try? fm.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<25 {                       // up to ~5s
            if fm.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return fm.fileExists(atPath: url.path)
    }

    // MARK: - Resolution

    private func resolveUbiquityContainer() async {
        let containerID = self.containerID
        let resolved: URL? = await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let stateLock = NSLock()
            var didResume = false
            func resume(_ url: URL?) {
                stateLock.lock(); let already = didResume; didResume = true; stateLock.unlock()
                if !already { cont.resume(returning: url) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                // First call frequently returns nil while iOS warms up the daemon;
                // back off and retry: 250ms, 500ms, 1s, 2s.
                for attempt in 0..<4 {
                    if let url = fm.url(forUbiquityContainerIdentifier: containerID) {
                        resume(url); return
                    }
                    Thread.sleep(forTimeInterval: 0.25 * Double(1 << attempt))
                }
                resume(nil)
            }
            // Hard deadline: if the daemon call is wedged, stop waiting and stay
            // local rather than hang on "Connecting…" forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { resume(nil) }
        }

        if let containerURL = resolved {
            let docs = containerURL.appendingPathComponent("Documents", isDirectory: true)
            let cloudRoot = docs.appendingPathComponent("SaveStates", isDirectory: true)
            let batteryRoot = docs.appendingPathComponent("BatterySaves", isDirectory: true)
            try? FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: batteryRoot, withIntermediateDirectories: true)
            #if DEBUG
            print("[iCloudSaveSync] resolved: \(cloudRoot.path)")
            #endif
            setState(.available, cloudRoot: cloudRoot, batteryRoot: batteryRoot)
            if syncEnabled {
                startMetadataQuery()
                syncNow()
            }
        } else {
            #if DEBUG
            print("[iCloudSaveSync] iCloud container did not resolve (timeout or unavailable); saves stay local")
            #endif
            setState(.unavailable, cloudRoot: nil, batteryRoot: nil)
        }
    }

    private func setState(_ newState: State, cloudRoot: URL?, batteryRoot: URL?) {
        lock.lock()
        _state = newState
        _iCloudRoot = cloudRoot
        _iCloudBatteryRoot = batteryRoot
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Live remote-update notifications

    /// Watches the app's iCloud Documents scope for `*.state` / `*.png` /
    /// `*.sav` changes and triggers a reconcile (which pulls remote saves down
    /// and refreshes the UI). Must run on the main thread (needs an active
    /// runloop). Idempotent.
    private func startMetadataQuery() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.metadataQuery == nil else { return }
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(
                format: "%K LIKE[c] %@ OR %K LIKE[c] %@ OR %K LIKE[c] %@",
                NSMetadataItemFSNameKey, "*.state",
                NSMetadataItemFSNameKey, "*.png",
                NSMetadataItemFSNameKey, "*.sav"
            )
            let nc = NotificationCenter.default
            nc.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                           object: query, queue: .main) { [weak self] _ in
                self?.syncNow()
            }
            nc.addObserver(forName: .NSMetadataQueryDidUpdate,
                           object: query, queue: .main) { [weak self] _ in
                self?.syncNow()
            }
            query.start()
            self.metadataQuery = query
            #if DEBUG
            print("[iCloudSaveSync] NSMetadataQuery started, watching save-state files")
            #endif
        }
    }

    /// Coalesce outward `.saveStatesDidChange` posts (a single pull can trigger
    /// several metadata events). Safe to call from any thread; it hops to main.
    private func postCoalescedNotification() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingNotificationWork?.cancel()
            let work = DispatchWorkItem {
                NotificationCenter.default.post(name: .saveStatesDidChange, object: nil)
            }
            self.pendingNotificationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    // MARK: - Local fallback path (now the primary path)

    /// The always-available local SaveStates directory: the working tree for all
    /// manual slots. Idempotent.
    static func localSaveStatesRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("SaveStates", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted on the main queue whenever a save state changes on disk: a local
    /// write (auto-save on quit/background, or a manual save) OR an iCloud pull of
    /// a remote save. Views displaying slot state or cover previews observe this to
    /// re-read from disk. `iCloudSaveSync` also observes it to mirror local writes
    /// up to iCloud.
    static let saveStatesDidChange = Notification.Name("saveStatesDidChange")

    /// Posted on the main queue when a battery save (`.sav`) lands on disk at a
    /// moment it is safe to mirror: session shutdown (the core has released the
    /// file) and per-game save import. `iCloudSaveSync` observes it to run a
    /// reconcile pass. NOT posted for the continuous in-play writes — the live
    /// session's file is excluded from sync anyway.
    static let batterySavesDidChange = Notification.Name("batterySavesDidChange")
}
