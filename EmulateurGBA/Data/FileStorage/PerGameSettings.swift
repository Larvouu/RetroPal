//
//  PerGameSettings.swift
//  EmulateurGBA
//
//  Every per-game choice the app keeps in UserDefaults under the game's KEY
//  (`BatterySaveImporter.romBasename`, the stored file name without its
//  extension), listed once, so deleting a game can forget them all.
//
//  Why it matters (audit 2026-10-12): a deleted game's key is free again, and a
//  DIFFERENT game imported later under the same name took it, with every choice
//  stored under it. The cheats were the harmful one: applied automatically at
//  launch (`applySavedCheats`), a code written for another game can corrupt the
//  new game's own save. These are local only (none syncs to iCloud), so
//  forgetting them on delete touches no other device.
//
//  NOT here, on purpose: the battery save and the save states. They sync to
//  iCloud, where another device may still hold the game; deleting them is a
//  different question, with its own answer (1.3.5).
//

import Foundation

enum PerGameSettings {
    /// The prefixes, each followed by the game's key. A new per-game setting
    /// is added here, or a deleted game leaves it behind for the next game of
    /// that name (`PerGameSettingsTests` reads the source for any it misses).
    static let prefixes: [String] = [
        "cheats_",                 // the game's cheat list, applied at launch
        "speed_",                  // emulation speed
        "skin_",                   // the chosen shell
        "orientation_",            // portrait / landscape lock
        "buttonLock_",             // hold-to-lock on the pad
        "videoFilter_",            // screen filter
        "gbPalette_",              // Game Boy palette
        "shareCardStyleChoice_",   // share card style
        "gbaSlot2_",               // a DS game's GBA slot cartridge
        "pt_gameSeconds_",         // play time (the stats and the review prompt)
        "pt_cheatShown_",          // the one-time cheats prompt
        "playAsP2_",               // Play as Player 2 (the game's page)
    ]

    /// Forget every per-game setting stored under this key.
    static func forget(romBasename key: String, in defaults: UserDefaults = .standard) {
        guard !key.isEmpty else { return }
        for prefix in prefixes { defaults.removeObject(forKey: prefix + key) }
    }
}
