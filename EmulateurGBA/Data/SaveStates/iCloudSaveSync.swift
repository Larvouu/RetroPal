//
//  iCloudSaveSync.swift
//  EmulateurGBA
//
//  Routes save states + previews through the iCloud Documents
//  container `iCloud.com.retropal` so SaveStateManager writes are
//  automatically synced across the user's Apple-ID-linked devices.
//  Falls back silently to a local Documents/SaveStates directory when
//  iCloud is unavailable (signed out, iCloud Drive disabled, no
//  entitlement, network offline at first launch).
//
//  Decisions carried from the 2026-05-15 eng review:
//  - iCloud Documents, NOT Core Data sync. Cheaper and more reliable
//    for a few-MB binary save-state files.
//  - `URLForUbiquityContainerIdentifier` is resolved on a background
//    queue with retry: the first call after sign-in routinely returns
//    nil while iOS warms up the iCloud daemon, even when iCloud is
//    properly set up on the device.
//  - mtime-wins conflict resolution. `NSFileVersion` is intentionally
//    NOT used (industry norm for save-state binaries; Delta does the
//    same). The actual mtime-wins arbitration happens at write time
//    via `CoordinatedFileIO.write(at:body:)`, which uses
//    `.forReplacing`, so any presenter (and iCloud sync) sees a
//    newest-wins ordering.
//  - Per-session decision: SaveStateManager uses whichever path was
//    available when its init ran. Toggling iCloud mid-session is not
//    supported; leaving and re-entering the emulator picks up the new
//    state. Users do not flip iCloud mid-game.
//
//  What this file does NOT do yet (deliberately deferred):
//  - `NSMetadataQuery` for live "remote save just appeared, refresh
//    slot list" UX. For now, navigating back to the library and
//    re-entering the game re-reads the slot list from the iCloud
//    folder (slot info re-evaluates on view appear).
//  - A Settings status row. The state is observable via
//    `iCloudSaveSync.shared.state` and `objectWillChange`; the UI
//    wiring is a follow-up commit in Week 4.
//
//  PRECONDITION (Xcode side, outside this file):
//  - Target must have the iCloud capability with iCloud Documents
//    enabled and container identifier `iCloud.com.retropal`. Without
//    that entry in the .entitlements file, `url(forUbiquity...)`
//    returns nil on every device and routing stays local — the code
//    degrades gracefully, no crashes, but no actual sync happens.
//

import Foundation
import Combine

final class iCloudSaveSync: ObservableObject, @unchecked Sendable {

    /// App-wide instance. Pre-warmed at app launch by
    /// `EmulateurGBAApp.init` so the container URL resolution starts
    /// before the user opens a game.
    static let shared = iCloudSaveSync()

    enum State: Equatable {
        /// Just launched. Resolution is in flight on a background queue.
        /// Routing treats this as "unavailable" — the first session
        /// after install may land on local; later sessions get iCloud
        /// once resolution completes.
        case resolving
        /// iCloud is available; new save states route to the container.
        case available
        /// User signed out, iCloud Drive off, capability missing, or
        /// resolution failed after retries. Saves stay local.
        case unavailable
    }

    /// Current state, safe from any thread. Observe transitions in
    /// SwiftUI through `objectWillChange`.
    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    private let containerID = "iCloud.com.retropal"
    private let lock = NSLock()
    private var _state: State = .resolving
    private var _iCloudRoot: URL?
    /// NSMetadataQuery watching the iCloud Documents container for
    /// save-state and preview-image changes. Lives for the process
    /// lifetime once started; iOS suspends it automatically on app
    /// background. Created lazily when the container resolves.
    private var metadataQuery: NSMetadataQuery?
    /// Debounce work item for `.iCloudSaveStatesDidChange`. The
    /// metadata query emits many small events during iCloud's upload
    /// lifecycle (state transition, progress, finalisation) — a single
    /// save can produce 10-15 raw events over ~2 seconds. We coalesce
    /// them into one notification per burst so consumers refresh once.
    /// Accessed only from the main queue (observer callbacks).
    private var pendingNotificationWork: DispatchWorkItem?

    private init() {
        // url(forUbiquityContainerIdentifier:) can block (it talks to
        // the iCloud daemon) so it MUST run off the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.resolveUbiquityContainer()
        }
    }

    // MARK: - Public routing API (thread-safe)

    /// Directory in which `SaveStateManager` should place files for
    /// the given ROM. iCloud-backed when available, local otherwise.
    /// Creates the directory on demand. Called once per
    /// `SaveStateManager` init.
    func saveStatesURL(forROM romName: String) -> URL {
        let root: URL = {
            lock.lock(); defer { lock.unlock() }
            if _state == .available, let cloud = _iCloudRoot { return cloud }
            return Self.localSaveStatesRoot()
        }()
        let url = root.appendingPathComponent(romName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Resolution

    private func resolveUbiquityContainer() async {
        let fm = FileManager.default
        // First call frequently returns nil while iOS warms up the
        // iCloud daemon. Back off briefly and retry: 250ms, 500ms, 1s,
        // 2s. After 4 attempts (~3.75s total), give up and route
        // locally; the next app launch will retry from scratch.
        for attempt in 0..<4 {
            if let containerURL = fm.url(forUbiquityContainerIdentifier: containerID) {
                let cloudRoot = containerURL
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent("SaveStates", isDirectory: true)
                try? fm.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
                #if DEBUG
                print("[iCloudSaveSync] resolved on attempt \(attempt + 1): \(cloudRoot.path)")
                #endif
                setState(.available, cloudRoot: cloudRoot)
                migrateLocalToCloudIfNeeded(cloudRoot: cloudRoot)
                startMetadataQuery()
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(250_000_000) << attempt)
        }
        #if DEBUG
        print("[iCloudSaveSync] could not resolve iCloud container after 4 attempts; saves stay local")
        #endif
        setState(.unavailable, cloudRoot: nil)
    }

    private func setState(_ newState: State, cloudRoot: URL?) {
        lock.lock()
        _state = newState
        _iCloudRoot = cloudRoot
        lock.unlock()
        // Hop to main for SwiftUI observers.
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - One-time migration

    /// If the user has existing save states in the local Documents
    /// folder but the matching iCloud folder is empty (first time
    /// iCloud comes online on this device), copy them up. After this
    /// the local folder is no longer touched by writes on this device;
    /// `saveStatesURL(forROM:)` returns the iCloud path on future
    /// init calls.
    ///
    /// Local files are NOT deleted after migration — they act as a
    /// safety net in case the iCloud copy is later lost. Disk cost
    /// per save state is small (a slot is roughly 100 KB to 1 MB).
    private func migrateLocalToCloudIfNeeded(cloudRoot: URL) {
        let fm = FileManager.default
        let local = Self.localSaveStatesRoot()
        // Walk per-ROM subdirectories. Each ROM has its own directory
        // under SaveStates/ that holds slotN.state, slotN.png, and the
        // pre_cheat_backup.state.
        let romDirs = (try? fm.contentsOfDirectory(at: local, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for romDir in romDirs {
            let isDir = (try? romDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let romName = romDir.lastPathComponent
            let cloudROMDir = cloudRoot.appendingPathComponent(romName, isDirectory: true)
            try? fm.createDirectory(at: cloudROMDir, withIntermediateDirectories: true)
            let files = (try? fm.contentsOfDirectory(at: romDir, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let dest = cloudROMDir.appendingPathComponent(file.lastPathComponent)
                // Skip if iCloud already has this file. mtime-wins from
                // the eng review: existing iCloud state is presumably
                // newer (the user already played on another device), so
                // we trust it over our local copy.
                guard !fm.fileExists(atPath: dest.path) else { continue }
                try? fm.copyItem(at: file, to: dest)
            }
        }
    }

    // MARK: - Live remote-update notifications

    /// Starts an `NSMetadataQuery` that watches the app's iCloud
    /// Documents scope for `*.state` and `*.png` files appearing,
    /// updating, or disappearing. On every change it posts the
    /// `.iCloudSaveStatesDidChange` notification on the main queue,
    /// which SwiftUI views displaying slot state observe to refresh
    /// without waiting for the user to navigate out and back.
    ///
    /// Must run on the main thread (the metadata query needs an active
    /// runloop). Idempotent: a second call is a no-op.
    private func startMetadataQuery() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.metadataQuery == nil else { return }
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(
                format: "%K LIKE[c] %@ OR %K LIKE[c] %@",
                NSMetadataItemFSNameKey, "*.state",
                NSMetadataItemFSNameKey, "*.png"
            )
            let nc = NotificationCenter.default
            // Initial gather and subsequent updates both post the same
            // signal — consumers just refresh on either.
            nc.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                           object: query, queue: .main) { [weak self] _ in
                self?.postCoalescedNotification()
            }
            nc.addObserver(forName: .NSMetadataQueryDidUpdate,
                           object: query, queue: .main) { [weak self] note in
                #if DEBUG
                let added   = (note.userInfo?[NSMetadataQueryUpdateAddedItemsKey]   as? [Any])?.count ?? 0
                let removed = (note.userInfo?[NSMetadataQueryUpdateRemovedItemsKey] as? [Any])?.count ?? 0
                let changed = (note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [Any])?.count ?? 0
                print("[iCloudSaveSync] query update: +\(added) -\(removed) ~\(changed)")
                #endif
                self?.postCoalescedNotification()
            }
            query.start()
            self.metadataQuery = query
            #if DEBUG
            print("[iCloudSaveSync] NSMetadataQuery started, watching save-state files")
            #endif
        }
    }

    /// Coalesce `.iCloudSaveStatesDidChange` posts. NSMetadataQuery
    /// emits many small updates during iCloud's upload lifecycle for a
    /// single save; firing the notification on every one would make
    /// `GameDetailsView.refreshSlots()` (and any other consumer) run
    /// 10-15 times for what is logically one user action. We cancel any
    /// pending fire and schedule a new one 300 ms out, so a burst of
    /// raw events collapses to one notification once the burst settles.
    /// Must be called on the main queue.
    private func postCoalescedNotification() {
        pendingNotificationWork?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .iCloudSaveStatesDidChange, object: nil)
        }
        pendingNotificationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Local fallback path

    /// The always-available local SaveStates directory. Used both as
    /// the migration source and as the routing target when iCloud is
    /// not available. Idempotent: creates the directory on first call
    /// per process.
    private static func localSaveStatesRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("SaveStates", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted on the main queue whenever the iCloud-synced
    /// save-state folder gains, loses, or updates a file. Views
    /// displaying slot state observe this to re-read their data when
    /// iCloud pulls a remote save from another device.
    static let iCloudSaveStatesDidChange = Notification.Name("iCloudSaveStatesDidChange")
}
