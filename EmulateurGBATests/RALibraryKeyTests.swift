//
//  RALibraryKeyTests.swift
//  EmulateurGBATests
//
//  The RetroAchievements index files every game under `GameEntity.romFilePath`,
//  the path relative to the ROMs folder. A cartridge's is its filename; a disc
//  game's carries its folder ("Tomb Raider/Tomb Raider.cue"). The session used
//  to look games up by the last path component alone, so no PlayStation session
//  ever found its record (found 2026-09-02, fixed 2026-09-03). This pins the
//  key derivation on the path shapes iOS actually hands us.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("RetroAchievements library key")
struct RALibraryKeyTests {

    private let documents = "/private/var/mobile/Containers/Data/Application/7A4654A4-1440-429B-86C3-E2E1F2CF35F8/Documents"

    @Test("A cartridge's key is its filename")
    func cartridge() {
        #expect(RetroAchievements.libraryKey(forROMPath: "\(documents)/ROMs/Pokemon Emerald.gba") == "Pokemon Emerald.gba")
    }

    @Test("A disc game's key keeps its folder, which is what the library stored")
    func disc() {
        #expect(RetroAchievements.libraryKey(forROMPath: "\(documents)/ROMs/Tomb Raider/Tomb Raider.cue") == "Tomb Raider/Tomb Raider.cue")
        #expect(RetroAchievements.libraryKey(forROMPath: "\(documents)/ROMs/Final Fantasy VII/Final Fantasy VII.m3u") == "Final Fantasy VII/Final Fantasy VII.m3u")
    }

    @Test("The /var and /private/var spellings of the same file give the same key")
    func privatePrefix() {
        let a = RetroAchievements.libraryKey(forROMPath: "/var/mobile/Containers/Data/Application/X/Documents/ROMs/Game/Game.chd")
        let b = RetroAchievements.libraryKey(forROMPath: "/private/var/mobile/Containers/Data/Application/X/Documents/ROMs/Game/Game.chd")
        #expect(a == "Game/Game.chd")
        #expect(a == b)
    }

    @Test("A game folder that is itself named ROMs still resolves under the real ROMs folder")
    func folderNamedROMs() {
        #expect(RetroAchievements.libraryKey(forROMPath: "\(documents)/ROMs/ROMs/Game.cue") == "ROMs/Game.cue")
    }

    @Test("A path outside the ROMs folder falls back to the filename")
    func outsideLibrary() {
        #expect(RetroAchievements.libraryKey(forROMPath: "/tmp/inbox/Game.gba") == "Game.gba")
    }
}
