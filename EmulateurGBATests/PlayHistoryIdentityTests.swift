//
//  PlayHistoryIdentityTests.swift
//  EmulateurGBATests
//
//  Which file the play history writes, and which device it says it is, in
//  every situation a phone meets (audit, 2026-10-29). Each rule was a bug:
//  a reinstall wrote its empty history over the old one, here and in iCloud;
//  a Keychain read that failed (a phone locked since it started) replaced the
//  device id; a file named after the device changed name once the Keychain
//  answered, and one phone wrote two files; a backup restored onto another
//  phone would write the first phone's file. The rules run here against
//  stand-ins for the Keychain and this install's UserDefaults.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("Play history identity")
struct PlayHistoryIdentityTests {

    /// A Keychain that can be locked, and an install's UserDefaults.
    final class Phone {
        var keychain: [String: String] = [:]
        var locked = false
        var defaults: UserDefaults
        let directory: URL
        private let suite: String

        init() throws {
            suite = "PlayHistoryIdentityTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var stores: PlayHistory.Stores {
            PlayHistory.Stores(
                defaults: defaults,
                lookup: { [unowned self] account in
                    if self.locked { return .failed }
                    return self.keychain[account].map { .found($0) } ?? .notFound
                },
                set: { [unowned self] value, account in
                    if !self.locked { self.keychain[account] = value }
                })
        }

        /// A launch: the device and the file it writes.
        func launch() -> (device: String, file: String) {
            let device = PlayHistory.loadDeviceID(stores: stores)
            let file = PlayHistory.loadFileName(deviceID: device.id, deviceIDWasRead: device.read,
                                                directory: directory, stores: stores)
            return (device.id, file)
        }

        /// Deleting the app: UserDefaults and Application Support go, the
        /// Keychain stays.
        func reinstall() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("A relaunch keeps its device and its file")
    func relaunch() throws {
        let phone = try Phone()
        defer { phone.cleanUp() }
        let first = phone.launch()
        let again = phone.launch()
        #expect(first.device == again.device)
        #expect(first.file == again.file)
        #expect(phone.keychain["playHistory.deviceID"] == first.device)
    }

    @Test("A reinstall is the same device, writing a NEW file, never the old one")
    func reinstall() throws {
        let phone = try Phone()
        defer { phone.cleanUp() }
        let before = phone.launch()
        phone.reinstall()
        let after = phone.launch()
        #expect(after.device == before.device)
        #expect(after.file != before.file, "the reinstall would write over the history before it")
    }

    @Test("A backup restored onto another phone is another device with its own file")
    func restoredBackup() throws {
        let first = try Phone()
        defer { first.cleanUp() }
        let original = first.launch()
        // The new phone: the first one's UserDefaults, its own empty Keychain.
        let second = try Phone()
        defer { second.cleanUp() }
        for (key, value) in first.defaults.dictionaryRepresentation() where key.hasPrefix("playHistory.") {
            second.defaults.set(value, forKey: key)
        }
        let restored = second.launch()
        #expect(restored.device != original.device)
        #expect(restored.file != original.file, "the restored phone would write the first phone's file")
    }

    @Test("Locked at its first launch: one file throughout, the real id once the Keychain answers")
    func lockedFirstLaunch() throws {
        let phone = try Phone()
        defer { phone.cleanUp() }
        phone.locked = true
        let locked = phone.launch()
        let stillLocked = phone.launch()
        #expect(phone.keychain.isEmpty, "a failed read wrote over the Keychain")
        #expect(locked.file == stillLocked.file)
        #expect(locked.device == stillLocked.device, "a new stand-in id at every locked launch")
        phone.locked = false
        let unlocked = phone.launch()
        #expect(unlocked.file == locked.file, "the file changed name when the Keychain answered")
        #expect(phone.keychain["playHistory.deviceID"] == unlocked.device)
        #expect(phone.launch() == unlocked)
    }

    @Test("A failed read never replaces an id the Keychain holds")
    func failedReadKeepsTheID() throws {
        let phone = try Phone()
        defer { phone.cleanUp() }
        let real = phone.launch()
        phone.locked = true
        let locked = phone.launch()
        #expect(locked.device == real.device, "the id this install last read is the one used")
        #expect(locked.file == real.file)
        #expect(phone.keychain["playHistory.deviceID"] == real.device)
    }

    @Test("The file of a build that named it after the device alone is kept")
    func legacyFileKept() throws {
        let phone = try Phone()
        defer { phone.cleanUp() }
        phone.keychain["playHistory.deviceID"] = "LEGACY-DEVICE"
        try Data("{}".utf8).write(to: phone.directory.appendingPathComponent("LEGACY-DEVICE.json"))
        #expect(phone.launch().file == "LEGACY-DEVICE.json")
    }
}
