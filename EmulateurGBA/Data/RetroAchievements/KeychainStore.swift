//
//  KeychainStore.swift
//  EmulateurGBA
//
//  Minimal Keychain helper (generic-password items). Used to persist the
//  RetroAchievements session TOKEN — never the password. Accessible after first
//  unlock so the session can be restored on a cold launch in the background.
//

import Foundation
import Security

enum KeychainStore {
    /// Store (or replace) a string value for `account`. Silently no-ops on error;
    /// a failed token write just means the user re-enters credentials next launch.
    /// `thisDeviceOnly` keeps the item out of backups restored onto another
    /// device (the play history's device id, 2026-10-28), and applies when the
    /// item is created.
    static func set(_ value: String, account: String, thisDeviceOnly: Bool = false) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = thisDeviceOnly
                ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                : kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    enum Lookup: Equatable {
        case found(String)
        /// No such item: the only answer that means the value does not exist.
        case notFound
        /// Any other failure (the device locked before its first unlock, a
        /// Keychain error): the value may well exist, it could not be read.
        case failed
    }

    /// `get`, telling a missing item from one that could not be read, for a
    /// caller that must never replace a value it merely failed to read (the
    /// play history's device id, audit 2026-10-29).
    static func lookup(_ account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return .failed }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed
        }
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
