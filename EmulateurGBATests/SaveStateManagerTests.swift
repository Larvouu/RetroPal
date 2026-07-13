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
            let token = NotificationCenter.default.addObserver(
                forName: .saveStatesDidChange, object: nil, queue: .main) { _ in posted() }
            defer { NotificationCenter.default.removeObserver(token) }

            manager.savePreviewImage(makePixel(), slot: slot)

            // Synchronous write: the PNG exists the instant the call returns.
            #expect(FileManager.default.fileExists(atPath: manager.previewImageURL(slot: slot).path))

            // The notification is posted on the main queue; let it deliver.
            try? await Task.sleep(nanoseconds: 500_000_000)
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
            let token = NotificationCenter.default.addObserver(
                forName: .saveStatesDidChange, object: nil, queue: .main) { _ in posted() }
            defer { NotificationCenter.default.removeObserver(token) }

            manager.savePreviewImage(makePixel(), slot: slot, coordinated: false)

            #expect(FileManager.default.fileExists(atPath: manager.previewImageURL(slot: slot).path))
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
