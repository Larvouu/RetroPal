//
//  PlayHistorySync.swift
//  EmulateurGBA
//
//  The play history's iCloud mirror (2026-10-28), run inside the saves' own
//  pass (`iCloudSaveSync.reconcileOnce`), so it follows the same switch, the
//  same container and the same queue.
//
//  The rule is simpler than the saves', on purpose: a device's file has ONE
//  writer, that device. So this device's file always goes up, and every other
//  device's file always comes down when iCloud's copy differs from ours.
//  There is no "newer wins" and no conflict to archive, because two versions
//  of one file can only mean an older copy of the same writer's file.
//
//  The files live at the container's root (`PlayHistory/`), not under its
//  Documents folder, which the Files app shows to the player.
//

import Foundation

enum PlayHistorySync {

    /// One pass: push this device's file, pull every other one that changed.
    /// Returns whether anything came down.
    @discardableResult
    static func reconcile(cloudRoot: URL, ownFileName: String, localRoot: URL = PlayHistory.localRoot,
                          materialize: (URL) -> Bool) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cloudRoot, withIntermediateDirectories: true)

        // Up: ours, whenever iCloud's copy is missing or differs.
        let ownLocal = localRoot.appendingPathComponent(ownFileName)
        let ownCloud = cloudRoot.appendingPathComponent(ownFileName)
        if fm.fileExists(atPath: ownLocal.path), !sameContents(ownLocal, ownCloud) {
            coordinatedCopy(from: ownLocal, to: ownCloud, writingCloud: true)
        }

        // Down: everyone else's, an earlier install's on this phone among them
        // (each install writes a file of its own, `PlayHistory.fileName`). Ours
        // too when it is missing here.
        var pulled = false
        for name in cloudNames(in: cloudRoot) {
            let cloud = cloudRoot.appendingPathComponent(name)
            let local = localRoot.appendingPathComponent(name)
            if name == ownFileName, fm.fileExists(atPath: local.path) { continue }
            guard materialize(cloud) else { continue }   // not downloaded yet: next pass
            if sameContents(local, cloud) { continue }
            coordinatedCopy(from: cloud, to: local, writingCloud: false)
            pulled = true
        }
        return pulled
    }

    /// `.json` names in the cloud folder, evicted placeholders included.
    private static func cloudNames(in dir: URL) -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var names = Set<String>()
        for item in items {
            var name = item
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            }
            if name.hasSuffix(".json") { names.insert(name) }
        }
        return names
    }

    private static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let da = try? Data(contentsOf: a), let db = try? Data(contentsOf: b) else { return false }
        return da == db
    }

    /// Coordinated on the iCloud side, as the saves' copies are.
    private static func coordinatedCopy(from src: URL, to dst: URL, writingCloud: Bool) {
        let fm = FileManager.default
        var error: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writingCloud {
            coordinator.coordinate(writingItemAt: dst, options: .forReplacing, error: &error) { url in
                try? fm.removeItem(at: url)
                try? fm.copyItem(at: src, to: url)
            }
        } else {
            coordinator.coordinate(readingItemAt: src, options: [], error: &error) { url in
                guard let data = try? Data(contentsOf: url) else { return }
                try? data.write(to: dst, options: .atomic)
            }
        }
    }
}
