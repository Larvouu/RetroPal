//
//  SaveSyncReconcilerTests.swift
//  EmulateurGBATests
//
//  Branch matrix for the local-first save-state mirror (SAVE_SYNC_LOCAL_FIRST.md).
//  Uses two throwaway temp roots with plain files, so no iCloud is involved; the
//  reconciler's `materialize` default is a plain presence check.
//
//  The load-bearing assertion across the divergence tests: a conflict NEVER
//  destroys the loser — it is archived under `_Conflicts/<rom>/` so a wrong
//  mtime guess is recoverable, not fatal.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("SaveSyncReconciler", .serialized)
struct SaveSyncReconcilerTests {

    // MARK: - Fixture helpers

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL, modified: Date? = nil) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.data(using: .utf8)!.write(to: url, options: .atomic)
        if let modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func read(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func mtime(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func slot(_ root: URL, _ rom: String, _ name: String) -> URL {
        root.appendingPathComponent(rom, isDirectory: true).appendingPathComponent(name)
    }

    private func conflict(_ localRoot: URL, _ rom: String, _ name: String) -> URL {
        localRoot.appendingPathComponent("_Conflicts", isDirectory: true)
            .appendingPathComponent(rom, isDirectory: true).appendingPathComponent(name)
    }

    private let rom = "Pokemon"
    private let old = Date(timeIntervalSince1970: 1_000_000)
    private let new = Date(timeIntervalSince1970: 2_000_000)

    // MARK: - One-side-only

    @Test("Cloud-only slot pulls down to local")
    func cloudOnlyPullsDown() {
        let local = tempRoot(); let cloud = tempRoot()
        write("CLOUD", to: slot(cloud, rom, "slot1.state"))

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcile()

        #expect(read(slot(local, rom, "slot1.state")) == "CLOUD")
        #expect(result.localChanged == true)
        #expect(result.cloudHadFiles == true)
    }

    @Test("Local-only slot pushes up to cloud, local active unchanged")
    func localOnlyPushesUp() {
        let local = tempRoot(); let cloud = tempRoot()
        write("LOCAL", to: slot(local, rom, "slot1.state"))

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcile()

        #expect(read(slot(cloud, rom, "slot1.state")) == "LOCAL")
        #expect(result.localChanged == false)   // a push is not a local change
    }

    // MARK: - Identical

    @Test("Identical content on both sides does nothing and archives nothing")
    func identicalNoOp() {
        let local = tempRoot(); let cloud = tempRoot()
        write("SAME", to: slot(local, rom, "slot1.state"), modified: old)
        write("SAME", to: slot(cloud, rom, "slot1.state"), modified: new)

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcile()

        #expect(read(slot(local, rom, "slot1.state")) == "SAME")
        #expect(result.localChanged == false)
        #expect(FileManager.default.fileExists(atPath: conflict(local, rom, "slot1.state").path) == false)
    }

    // MARK: - Divergence (the critical, non-destructive cases)

    @Test("Cloud newer wins; the local loser is ARCHIVED, not destroyed")
    func cloudNewerArchivesLocalLoser() {
        let local = tempRoot(); let cloud = tempRoot()
        write("LOCAL_OLD", to: slot(local, rom, "slot1.state"), modified: old)
        write("CLOUD_NEW", to: slot(cloud, rom, "slot1.state"), modified: new)

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcile()

        #expect(read(slot(local, rom, "slot1.state")) == "CLOUD_NEW")          // newest active
        #expect(read(conflict(local, rom, "slot1.state")) == "LOCAL_OLD")      // loser preserved
        #expect(result.localChanged == true)
    }

    @Test("Local newer wins; the cloud loser is ARCHIVED locally, then pushed over")
    func localNewerArchivesCloudLoser() {
        let local = tempRoot(); let cloud = tempRoot()
        write("LOCAL_NEW", to: slot(local, rom, "slot1.state"), modified: new)
        write("CLOUD_OLD", to: slot(cloud, rom, "slot1.state"), modified: old)

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcile()

        #expect(read(slot(local, rom, "slot1.state")) == "LOCAL_NEW")          // active unchanged
        #expect(read(slot(cloud, rom, "slot1.state")) == "LOCAL_NEW")          // pushed over
        #expect(read(conflict(local, rom, "slot1.state")) == "CLOUD_OLD")      // loser preserved
        #expect(result.localChanged == false)                                  // active didn't change
    }

    @Test("Equal mtime + different content keeps local active and preserves the other")
    func equalMtimeKeepsBothViaArchive() {
        let local = tempRoot(); let cloud = tempRoot()
        let t = Date(timeIntervalSince1970: 1_500_000)
        write("LOCAL_X", to: slot(local, rom, "slot1.state"), modified: t)
        write("CLOUD_Y", to: slot(cloud, rom, "slot1.state"), modified: t)

        _ = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcile()

        #expect(read(slot(local, rom, "slot1.state")) == "LOCAL_X")            // local wins the tie
        #expect(read(conflict(local, rom, "slot1.state")) == "CLOUD_Y")        // other preserved
    }

    // MARK: - Date preservation & pairing

    @Test("Pull preserves the source modification date (no artificial 'newer')")
    func pullPreservesDate() {
        let local = tempRoot(); let cloud = tempRoot()
        write("CLOUD", to: slot(cloud, rom, "slot1.state"), modified: old)

        _ = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcile()

        let pulled = mtime(slot(local, rom, "slot1.state"))
        #expect(pulled != nil)
        #expect(abs(pulled!.timeIntervalSince1970 - old.timeIntervalSince1970) < 1.0)
    }

    @Test("A slot's .png travels with its .state")
    func pngTravelsWithState() {
        let local = tempRoot(); let cloud = tempRoot()
        write("CLOUD", to: slot(cloud, rom, "slot1.state"))
        write("PNGDATA", to: slot(cloud, rom, "slot1.png"))

        _ = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcile()

        #expect(read(slot(local, rom, "slot1.state")) == "CLOUD")
        #expect(read(slot(local, rom, "slot1.png")) == "PNGDATA")
    }

    // MARK: - Exclusions

    @Test("slot0 and pre_cheat_backup are never synced")
    func excludedFilesNotSynced() {
        let local = tempRoot(); let cloud = tempRoot()
        write("AUTO", to: slot(cloud, rom, "slot0.state"))
        write("PRECHEAT", to: slot(cloud, rom, "pre_cheat_backup.state"))

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcile()

        #expect(FileManager.default.fileExists(atPath: slot(local, rom, "slot0.state").path) == false)
        #expect(FileManager.default.fileExists(atPath: slot(local, rom, "pre_cheat_backup.state").path) == false)
        #expect(result.cloudHadFiles == false)   // excluded files don't count as cloud saves
    }

    @Test("The _Conflicts tree is not treated as a ROM to mirror")
    func conflictsTreeIgnored() {
        let local = tempRoot(); let cloud = tempRoot()
        write("ARCHIVED", to: conflict(local, rom, "slot1.state"))
        write("CLOUD", to: slot(cloud, rom, "slot1.state"))

        _ = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcile()

        // The pre-existing archive must not have been pushed to cloud as a "_Conflicts" ROM.
        #expect(FileManager.default.fileExists(
            atPath: cloud.appendingPathComponent("_Conflicts").path) == false)
    }
}
