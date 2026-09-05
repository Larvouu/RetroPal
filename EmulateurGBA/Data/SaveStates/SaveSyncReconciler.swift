//
//  SaveSyncReconciler.swift
//  EmulateurGBA
//
//  Pure, testable engine that mirrors the LOCAL save-state tree (the source of
//  truth) with the iCloud container, in BOTH directions and NON-DESTRUCTIVELY.
//
//  Design, in short:
//   - Local is authoritative; iCloud is a mirror. Whether the user can SEE a save
//     never depends on iCloud state.
//   - Reconcile per SLOT, keyed on the `.state` binary; its `.png` preview travels
//     with it.
//   - mtime decides which version is ACTIVE, but the loser is NEVER deleted: it is
//     archived locally under `SaveStates/_Conflicts/<rom>/` before being
//     overwritten. A date can't tell "newer version of the same slot" from "a
//     different playthrough", so the wrong guess must be recoverable, not fatal.
//   - Conflicts are kept LOCAL only (never pushed) so they cannot re-bloat iCloud,
//     and are bounded to one archive per slot.
//   - Modification dates are explicitly preserved on every copy, so a copy never
//     looks artificially "newer" and wins a future comparison by accident.
//   - Excluded from sync: `slot0.state` (auto-save, local-only) and
//     `pre_cheat_backup.state` (a transient local safety net).
//
//  The type is intentionally free of iCloud/singleton coupling so the full branch
//  matrix is unit-testable with two throwaway temp directories.
//
//  BATTERY SAVES (added for 1.2.4): the same engine also mirrors the flat
//  `BatterySaves/*.sav` tree (the in-game progress) via
//  `reconcileBatterySaves(skipping:)` — construct the instance with the
//  two BatterySaves roots and call that entry point instead of `reconcile()`.
//  Same rules (local authoritative, mtime-wins, loser archived, conflicts
//  local-only and bounded), no `.png` companion, `Backups/` and `_Conflicts/`
//  never mirrored. The one extra rule: the ROM whose save is OPEN by a live
//  emulation session is skipped entirely (mGBA holds the file through a
//  retained VFile; melonDS rewrites it as the game saves), so a live save is
//  never replaced or half-read — it reconciles at quit and on the next pass.
//

import Foundation

struct SaveSyncReconciler {

    let localRoot: URL
    let cloudRoot: URL

    /// Result of one reconcile pass.
    struct Result {
        /// The LOCAL tree changed (a pull or a conflict archive) — the caller
        /// should refresh any slot UI. Pushes (local -> cloud) do NOT set this.
        var localChanged = false
        /// iCloud held at least one save-state file this pass — used to arm the
        /// "you had iCloud saves" warning so brand-new users are never warned.
        var cloudHadFiles = false
    }

    /// Materialize an iCloud file that may be evicted (a `.icloud` placeholder)
    /// before reading it; returns true if the file is on disk after the call.
    /// Default is a plain presence check (tests use real files); the app injects a
    /// closure that calls `startDownloadingUbiquitousItem` and polls briefly.
    var materialize: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    private let fm = FileManager.default

    /// Files never synced in either direction.
    private static let excludedStateNames: Set<String> = [
        "slot0.state",              // auto-save: local-only (see df515d9)
        "pre_cheat_backup.state",   // transient local safety net
    ]
    private static let conflictsDirName = "_Conflicts"

    // MARK: - Entry point

    /// Run a full bidirectional reconcile across every ROM present on either side.
    @discardableResult
    func reconcile() -> Result {
        ensureDir(localRoot)
        ensureDir(cloudRoot)
        var result = Result()
        for rom in romDirNames() {
            let r = reconcileROM(rom)
            result.localChanged = result.localChanged || r.localChanged
            result.cloudHadFiles = result.cloudHadFiles || r.cloudHadFiles
        }
        return result
    }

    // MARK: - Battery saves (.sav, flat tree)

    /// Run a full bidirectional reconcile of the flat battery-save tree. The
    /// instance's `localRoot` / `cloudRoot` must be the two `BatterySaves`
    /// directories. `skipping` holds the ROM basenames of the live emulation
    /// session (if any) — the played game, plus the slot-2 GBA game when an
    /// NDS session has one mounted: their `.sav` files are left completely
    /// untouched in BOTH directions and reconcile once the session has ended.
    @discardableResult
    func reconcileBatterySaves(skipping skips: Set<String> = []) -> Result {
        ensureDir(localRoot)
        ensureDir(cloudRoot)
        var result = Result()
        let skipNames = Set(skips.map { $0 + ".sav" })
        let cloudNames = savNames(in: cloudRoot)
        result.cloudHadFiles = !cloudNames.isEmpty
        for name in savNames(in: localRoot).union(cloudNames) {
            if skipNames.contains(name) { continue }
            if reconcileBatteryFile(name) { result.localChanged = true }
        }
        return result
    }

    /// One `.sav`: the save-state slot logic without the `.png` companion,
    /// archived flat (`_Conflicts/<name>`, the file name IS the ROM, bounded to
    /// one copy). Returns true if the local ACTIVE copy changed (a pull).
    private func reconcileBatteryFile(_ name: String) -> Bool {
        let localFile = localRoot.appendingPathComponent(name)
        let cloudFile = cloudRoot.appendingPathComponent(name)
        let localExists = fm.fileExists(atPath: localFile.path)
        let cloudExists = fm.fileExists(atPath: cloudFile.path) || isEvicted(cloudFile)

        switch (localExists, cloudExists) {
        case (false, false):
            return false
        case (true, false):
            copyUp(localFile, cloudFile)
            return false
        case (false, true):
            copyDown(cloudFile, localFile)
            return true
        case (true, true):
            guard materialize(cloudFile) else { return false }   // not downloaded yet; retry next sync
            if sameContents(localFile, cloudFile) { return false }
            let lm = mtime(localFile) ?? .distantPast
            let cm = mtime(cloudFile) ?? .distantPast
            ensureDir(conflictsRoot())
            let archived = conflictsRoot().appendingPathComponent(name)
            if cm > lm {
                // Cloud newer -> cloud wins. Preserve the local loser, then pull.
                copyPreservingDate(from: localFile, to: archived)
                copyDown(cloudFile, localFile)
                return true
            } else {
                // Local newer (or tie) -> local wins. Preserve the cloud loser
                // locally, then push. Local active unchanged.
                copyPreservingDate(from: cloudFile, to: archived)
                copyUp(localFile, cloudFile)
                return false
            }
        }
    }

    /// `.sav` file names in the flat battery dir, with evicted placeholders
    /// normalized. Subdirectories (`Backups`, `_Conflicts`) don't end in `.sav`
    /// and are naturally excluded, as is any non-save stray file.
    private func savNames(in dir: URL) -> Set<String> {
        let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var names = Set<String>()
        for item in items {
            var name = item
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            }
            if name.hasSuffix(".sav") { names.insert(name) }
        }
        return names
    }

    // MARK: - Per-ROM

    private func reconcileROM(_ rom: String) -> Result {
        let localDir = localRoot.appendingPathComponent(rom, isDirectory: true)
        let cloudDir = cloudRoot.appendingPathComponent(rom, isDirectory: true)

        let localStates = stateNames(in: localDir)
        let cloudStates = stateNames(in: cloudDir)
        var result = Result()
        result.cloudHadFiles = !cloudStates.isEmpty

        for state in localStates.union(cloudStates) {
            if reconcileSlot(stateName: state, rom: rom, localDir: localDir, cloudDir: cloudDir) {
                result.localChanged = true
            }
        }
        return result
    }

    /// Reconcile one slot. Returns true if the local ACTIVE copy changed (a pull).
    private func reconcileSlot(stateName: String, rom: String, localDir: URL, cloudDir: URL) -> Bool {
        let pngName = (stateName as NSString).deletingPathExtension + ".png"
        let localState = localDir.appendingPathComponent(stateName)
        let cloudState = cloudDir.appendingPathComponent(stateName)

        let localExists = fm.fileExists(atPath: localState.path)
        let cloudExists = fm.fileExists(atPath: cloudState.path) || isEvicted(cloudState)

        switch (localExists, cloudExists) {
        case (false, false):
            return false
        case (true, false):
            // Local only -> push up. Local active unchanged.
            ensureDir(cloudDir)
            push(state: stateName, png: pngName, localDir: localDir, cloudDir: cloudDir)
            return false
        case (false, true):
            // Cloud only -> pull down. Local changed.
            ensureDir(localDir)
            pull(state: stateName, png: pngName, localDir: localDir, cloudDir: cloudDir)
            return true
        case (true, true):
            return reconcileDivergence(stateName: stateName, pngName: pngName, rom: rom,
                                       localState: localState, cloudState: cloudState,
                                       localDir: localDir, cloudDir: cloudDir)
        }
    }

    /// Both sides have the slot. Identical -> nothing. Otherwise newest is active,
    /// the loser is archived locally first (never destroyed).
    private func reconcileDivergence(stateName: String, pngName: String, rom: String,
                                     localState: URL, cloudState: URL,
                                     localDir: URL, cloudDir: URL) -> Bool {
        guard materialize(cloudState) else { return false }   // not downloaded yet; retry next sync
        if sameContents(localState, cloudState) { return false }

        let lm = mtime(localState) ?? .distantPast
        let cm = mtime(cloudState) ?? .distantPast

        if cm > lm {
            // Cloud newer -> cloud wins. Preserve the local loser, then pull.
            archive(stateName: stateName, pngName: pngName, rom: rom, fromDir: localDir, materializeFirst: false)
            pull(state: stateName, png: pngName, localDir: localDir, cloudDir: cloudDir)
            return true
        } else {
            // Local newer (or equal mtime, different content) -> local wins.
            // Preserve the cloud loser locally, then push. Local active unchanged.
            archive(stateName: stateName, pngName: pngName, rom: rom, fromDir: cloudDir, materializeFirst: true)
            push(state: stateName, png: pngName, localDir: localDir, cloudDir: cloudDir)
            return false
        }
    }

    // MARK: - Copy primitives (date-preserving + iCloud-coordinated)

    private func push(state: String, png: String, localDir: URL, cloudDir: URL) {
        copyUp(localDir.appendingPathComponent(state), cloudDir.appendingPathComponent(state))
        let lpng = localDir.appendingPathComponent(png)
        if fm.fileExists(atPath: lpng.path) {
            copyUp(lpng, cloudDir.appendingPathComponent(png))
        }
    }

    private func pull(state: String, png: String, localDir: URL, cloudDir: URL) {
        copyDown(cloudDir.appendingPathComponent(state), localDir.appendingPathComponent(state))
        let cpng = cloudDir.appendingPathComponent(png)
        if fm.fileExists(atPath: cpng.path) || isEvicted(cpng) {
            copyDown(cpng, localDir.appendingPathComponent(png))
        }
    }

    /// local -> cloud, coordinated on the cloud endpoint, date preserved.
    private func copyUp(_ src: URL, _ dst: URL) {
        guard fm.fileExists(atPath: src.path) else { return }
        let srcDate = mtime(src)
        var coordErr: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: dst, options: .forReplacing, error: &coordErr) { coordURL in
                try? fm.removeItem(at: coordURL)
                try? fm.copyItem(at: src, to: coordURL)
            }
        if let srcDate { try? fm.setAttributes([.modificationDate: srcDate], ofItemAtPath: dst.path) }
    }

    /// cloud -> local, coordinated on the cloud endpoint, date preserved.
    private func copyDown(_ src: URL, _ dst: URL) {
        guard materialize(src) else { return }
        var srcDate: Date?
        var coordErr: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: src, options: [], error: &coordErr) { coordURL in
                srcDate = mtime(coordURL)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: coordURL, to: dst)
            }
        if let srcDate { try? fm.setAttributes([.modificationDate: srcDate], ofItemAtPath: dst.path) }
    }

    /// Archive the losing version of a slot into `localRoot/_Conflicts/<rom>/`,
    /// bounded to one copy per slot (fixed name, overwritten). Local-only: never
    /// pushed to iCloud. `materializeFirst` for a cloud source that may be evicted.
    private func archive(stateName: String, pngName: String, rom: String,
                         fromDir: URL, materializeFirst: Bool) {
        let confDir = conflictsRoot().appendingPathComponent(rom, isDirectory: true)
        ensureDir(confDir)
        let srcState = fromDir.appendingPathComponent(stateName)
        if materializeFirst { _ = materialize(srcState) }
        copyPreservingDate(from: srcState, to: confDir.appendingPathComponent(stateName))
        let srcPng = fromDir.appendingPathComponent(pngName)
        if materializeFirst { _ = materialize(srcPng) }
        if fm.fileExists(atPath: srcPng.path) {
            copyPreservingDate(from: srcPng, to: confDir.appendingPathComponent(pngName))
        }
    }

    /// Plain (uncoordinated) date-preserving copy, for the local-only archive tree.
    private func copyPreservingDate(from src: URL, to dst: URL) {
        guard fm.fileExists(atPath: src.path) else { return }
        let srcDate = mtime(src)
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: src, to: dst)
        if let srcDate { try? fm.setAttributes([.modificationDate: srcDate], ofItemAtPath: dst.path) }
    }

    // MARK: - Listing helpers

    /// ROM subdirectories present on either side, excluding the conflicts tree and
    /// any non-directory entries.
    private func romDirNames() -> Set<String> {
        func dirs(_ root: URL) -> Set<String> {
            let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            var names = Set<String>()
            for item in items {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir, item.lastPathComponent != Self.conflictsDirName else { continue }
                names.insert(item.lastPathComponent)
            }
            return names
        }
        return dirs(localRoot).union(dirs(cloudRoot))
    }

    /// `.state` file names in a directory, with evicted iCloud placeholders
    /// (`.slotN.state.icloud`) normalized back to `slotN.state`, excluding the
    /// local-only files.
    private func stateNames(in dir: URL) -> Set<String> {
        let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var names = Set<String>()
        for item in items {
            var name = item
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            }
            if name.hasSuffix(".state"), !Self.excludedStateNames.contains(name) {
                names.insert(name)
            }
        }
        return names
    }

    // MARK: - Small utilities

    private func conflictsRoot() -> URL {
        localRoot.appendingPathComponent(Self.conflictsDirName, isDirectory: true)
    }

    private func isEvicted(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return fm.fileExists(atPath: placeholder.path)
    }

    private func mtime(_ url: URL) -> Date? {
        try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func ensureDir(_ url: URL) {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Byte-equal check (size first, then contents). Used to skip no-op conflicts.
    private func sameContents(_ a: URL, _ b: URL) -> Bool {
        let sa = (try? fm.attributesOfItem(atPath: a.path)[.size] as? Int) ?? -1
        let sb = (try? fm.attributesOfItem(atPath: b.path)[.size] as? Int) ?? -2
        guard sa == sb else { return false }
        guard let da = try? Data(contentsOf: a), let db = try? Data(contentsOf: b) else { return false }
        return da == db
    }
}
