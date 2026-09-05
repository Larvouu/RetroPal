//
//  SaveSyncReconcilerTests.swift
//  EmulateurGBATests
//
//  Branch matrix for the local-first save-state mirror (see SaveSyncReconciler).
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

    // MARK: - Battery saves (.sav, flat tree)

    private func sav(_ root: URL, _ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    private func batteryConflict(_ localRoot: URL, _ name: String) -> URL {
        localRoot.appendingPathComponent("_Conflicts", isDirectory: true).appendingPathComponent(name)
    }

    @Test("Battery: cloud-only .sav pulls down, local-only pushes up")
    func batteryOneSideOnly() {
        let local = tempRoot(); let cloud = tempRoot()
        write("CLOUD", to: sav(cloud, "Pokemon.sav"))
        write("LOCAL", to: sav(local, "Zelda.sav"))

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcileBatterySaves()

        #expect(read(sav(local, "Pokemon.sav")) == "CLOUD")
        #expect(read(sav(cloud, "Zelda.sav")) == "LOCAL")
        #expect(result.localChanged == true)      // the pull
        #expect(result.cloudHadFiles == true)
    }

    @Test("Battery: identical content does nothing and archives nothing")
    func batteryIdenticalNoOp() {
        let local = tempRoot(); let cloud = tempRoot()
        write("SAME", to: sav(local, "Pokemon.sav"), modified: old)
        write("SAME", to: sav(cloud, "Pokemon.sav"), modified: new)

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcileBatterySaves()

        #expect(result.localChanged == false)
        #expect(FileManager.default.fileExists(
            atPath: batteryConflict(local, "Pokemon.sav").path) == false)
    }

    @Test("Battery: cloud newer wins; the local loser is ARCHIVED, not destroyed")
    func batteryCloudNewerArchivesLoser() {
        let local = tempRoot(); let cloud = tempRoot()
        write("LOCAL_OLD", to: sav(local, "Pokemon.sav"), modified: old)
        write("CLOUD_NEW", to: sav(cloud, "Pokemon.sav"), modified: new)

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcileBatterySaves()

        #expect(read(sav(local, "Pokemon.sav")) == "CLOUD_NEW")
        #expect(read(batteryConflict(local, "Pokemon.sav")) == "LOCAL_OLD")
        #expect(result.localChanged == true)
    }

    @Test("Battery: local newer wins; the cloud loser is ARCHIVED locally, then pushed over")
    func batteryLocalNewerArchivesCloudLoser() {
        let local = tempRoot(); let cloud = tempRoot()
        write("LOCAL_NEW", to: sav(local, "Pokemon.sav"), modified: new)
        write("CLOUD_OLD", to: sav(cloud, "Pokemon.sav"), modified: old)

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcileBatterySaves()

        #expect(read(sav(local, "Pokemon.sav")) == "LOCAL_NEW")
        #expect(read(sav(cloud, "Pokemon.sav")) == "LOCAL_NEW")
        #expect(read(batteryConflict(local, "Pokemon.sav")) == "CLOUD_OLD")
        #expect(result.localChanged == false)
    }

    @Test("Battery: the live session's .sav is untouched in BOTH directions")
    func batteryActiveSessionSkipped() {
        let local = tempRoot(); let cloud = tempRoot()
        write("LOCAL_LIVE", to: sav(local, "Pokemon.sav"), modified: old)
        write("CLOUD_NEW", to: sav(cloud, "Pokemon.sav"), modified: new)
        write("OTHER", to: sav(cloud, "Zelda.sav"))

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud)
            .reconcileBatterySaves(skipping: ["Pokemon"])

        // The live save is neither replaced nor archived, and nothing was pushed.
        #expect(read(sav(local, "Pokemon.sav")) == "LOCAL_LIVE")
        #expect(read(sav(cloud, "Pokemon.sav")) == "CLOUD_NEW")
        #expect(FileManager.default.fileExists(
            atPath: batteryConflict(local, "Pokemon.sav").path) == false)
        // Other games still reconcile in the same pass.
        #expect(read(sav(local, "Zelda.sav")) == "OTHER")
        #expect(result.localChanged == true)
    }

    @Test("Battery: an NDS session with a slot-2 GBA game skips BOTH live .sav files")
    func batteryDualSlotSessionSkipsBothSaves() {
        let local = tempRoot(); let cloud = tempRoot()
        // The played NDS game and the GBA game mounted in its slot 2: both
        // saves are live in the core (Pal Park writes to the GBA one).
        write("NDS_LIVE", to: sav(local, "PokemonDiamond.sav"), modified: old)
        write("CLOUD_NDS", to: sav(cloud, "PokemonDiamond.sav"), modified: new)
        write("GBA_LIVE", to: sav(local, "PokemonEmerald.sav"), modified: old)
        write("CLOUD_GBA", to: sav(cloud, "PokemonEmerald.sav"), modified: new)
        write("OTHER", to: sav(cloud, "Zelda.sav"))

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud)
            .reconcileBatterySaves(skipping: ["PokemonDiamond", "PokemonEmerald"])

        // Neither live save is replaced or archived.
        #expect(read(sav(local, "PokemonDiamond.sav")) == "NDS_LIVE")
        #expect(read(sav(local, "PokemonEmerald.sav")) == "GBA_LIVE")
        #expect(FileManager.default.fileExists(
            atPath: batteryConflict(local, "PokemonDiamond.sav").path) == false)
        #expect(FileManager.default.fileExists(
            atPath: batteryConflict(local, "PokemonEmerald.sav").path) == false)
        // Other games still reconcile in the same pass.
        #expect(read(sav(local, "Zelda.sav")) == "OTHER")
        #expect(result.localChanged == true)
    }

    @Test("Battery: Backups and _Conflicts subtrees are never mirrored")
    func batteryBackupsAndConflictsIgnored() {
        let local = tempRoot(); let cloud = tempRoot()
        write("BACKUP", to: local.appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("Pokemon-20260101-120000.sav"))
        write("ARCHIVED", to: batteryConflict(local, "Pokemon.sav"))

        let result = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcileBatterySaves()

        #expect(FileManager.default.fileExists(
            atPath: cloud.appendingPathComponent("Backups").path) == false)
        #expect(FileManager.default.fileExists(
            atPath: cloud.appendingPathComponent("_Conflicts").path) == false)
        #expect(FileManager.default.fileExists(
            atPath: sav(cloud, "Pokemon.sav").path) == false)
        #expect(result.cloudHadFiles == false)
    }

    @Test("Battery: pull preserves the source modification date")
    func batteryPullPreservesDate() {
        let local = tempRoot(); let cloud = tempRoot()
        write("CLOUD", to: sav(cloud, "Pokemon.sav"), modified: old)

        _ = SaveSyncReconciler(localRoot: local, cloudRoot: cloud).reconcileBatterySaves()

        let pulled = mtime(sav(local, "Pokemon.sav"))
        #expect(pulled != nil)
        #expect(abs(pulled!.timeIntervalSince1970 - old.timeIntervalSince1970) < 1.0)
    }
}
