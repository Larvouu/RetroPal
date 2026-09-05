//
//  SaveStateManagerTests.swift
//  EmulateurGBATests
//
//  Regression coverage for the 2026-05-26 auto-save fix.
//
//  Bug: after the "save IO off the main thread" change (34f5edd), the auto-save
//  (slot 0) preview was written asynchronously, AFTER the library cover +
//  game-details views had already refreshed (on dismiss / lastPlayedAt re-stamp),
//  and nothing told them to refresh again — so the "Reprendre la session"
//  thumbnail stayed stale until the view was recreated. The fix makes
//  `savePreviewImage` announce `.saveStatesDidChange` once the PNG is on disk so
//  the views re-read. These tests lock that contract (and that the write is
//  synchronous, including the uncoordinated path used by the background save).
//
//  `baseDir` is injected so the test writes to a throwaway temp directory and
//  never touches the real save container.
//

import Testing
import Foundation
import UIKit
@testable import EmulateurGBA

/// A delivery flag the notification block can set and the test task can read.
///
/// `.saveStatesDidChange` is posted with `DispatchQueue.main.async` and observed on the main
/// queue, so the test has to wait for the main queue to get round to it. It used to wait a flat
/// 500ms, and that is a race the test host loses: this host is the whole app, booting iCloud's
/// metadata query and a RetroAchievements login while the suite runs, and delivery there took
/// about a second. Only the COORDINATED test survived it, and by luck rather than by design --
/// `NSFileCoordinator` blocks long enough for the main queue to drain before the sleep even
/// starts. The uncoordinated write is instant, so it had nothing but the 500ms and failed.
private final class DeliveryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    func set() { lock.lock(); delivered = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return delivered }
}

/// Waits for the flag, checking often and giving up after `timeout` seconds. Returns as soon as
/// it is set, so a healthy run costs a few milliseconds rather than a fixed sleep.
private func waitForDelivery(_ flag: DeliveryFlag, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !flag.isSet && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

@Suite("SaveStateManager", .serialized)
struct SaveStateManagerTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePixel() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test("Coordinated preview write persists synchronously and posts saveStatesDidChange")
    func coordinatedWritePersistsAndNotifies() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SaveStateManager(romName: "test", baseDir: dir)
        let slot = SaveStateManager.autoSaveSlotIndex

        // expectedCount 1... : the live iCloudSaveSync NSMetadataQuery in the test
        // host can post .saveStatesDidChange too, so tolerate extra posts; we only
        // need to prove savePreviewImage posts at least once.
        await confirmation("posts .saveStatesDidChange", expectedCount: 1...) { posted in
            let flag = DeliveryFlag()
            let token = NotificationCenter.default.addObserver(
                forName: .saveStatesDidChange, object: nil, queue: .main) { _ in
                    flag.set(); posted()
                }
            defer { NotificationCenter.default.removeObserver(token) }

            manager.savePreviewImage(makePixel(), slot: slot)

            // Synchronous write: the PNG exists the instant the call returns.
            #expect(FileManager.default.fileExists(atPath: manager.previewImageURL(slot: slot).path))

            // The notification is posted on the main queue; wait for it to arrive.
            await waitForDelivery(flag)
        }
    }

    @Test("Uncoordinated preview write (background path) persists synchronously and posts")
    func uncoordinatedWritePersistsAndNotifies() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SaveStateManager(romName: "test", baseDir: dir)
        let slot = SaveStateManager.autoSaveSlotIndex

        // expectedCount 1... : the live iCloudSaveSync NSMetadataQuery in the test
        // host can post .saveStatesDidChange too, so tolerate extra posts; we only
        // need to prove savePreviewImage posts at least once.
        await confirmation("posts .saveStatesDidChange", expectedCount: 1...) { posted in
            let flag = DeliveryFlag()
            let token = NotificationCenter.default.addObserver(
                forName: .saveStatesDidChange, object: nil, queue: .main) { _ in
                    flag.set(); posted()
                }
            defer { NotificationCenter.default.removeObserver(token) }

            manager.savePreviewImage(makePixel(), slot: slot, coordinated: false)

            #expect(FileManager.default.fileExists(atPath: manager.previewImageURL(slot: slot).path))
            await waitForDelivery(flag)
        }
    }
}
