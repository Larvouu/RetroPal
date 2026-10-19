//
//  SegaPSPCheatsAndAchievementsTests.swift
//  EmulateurGBATests
//
//  The cheat browser, the cheat field and RetroAchievements identification
//  for the four consoles of 1.3.4/1.3.5: the Mega Drive, the Master System,
//  the Game Gear and the PSP. Written from the 2026-10-10 audit, where every
//  code of libretro's four folders was run on the host through the real
//  formatter and, for the Master System and the Game Gear, through MesenCE's
//  own converters (libmesen-core-host.a).
//

import Testing
import Foundation
@testable import EmulateurGBA

struct SegaPSPCheatsAndAchievementsTests {

    // MARK: - Cheat browser: the Master System and the Game Gear

    /// Both consoles have their libretro folder in the bundled index, under the
    /// exact folder name the CDN serves, so the browser finds their games.
    @Test func theIndexCarriesBothEightBitSegaFolders() throws {
        let sms = try #require(CheatIndex.shared.url(forCheatFile: "Columns (USA, Europe, Brazil)",
                                                     system: "sms"), "no Master System folder in the index")
        #expect(sms.absoluteString.contains("Sega%20-%20Master%20System%20-%20Mark%20III/"),
                "folder was \(sms.absoluteString)")
        let gg = try #require(CheatIndex.shared.url(forCheatFile: "Columns (USA, Europe, Brazil)",
                                                    system: "gg"), "no Game Gear folder in the index")
        #expect(gg.absoluteString.contains("Sega%20-%20Game%20Gear/"), "folder was \(gg.absoluteString)")
    }

    /// Two real games, checked against the folder listing on 2026-10-10: the
    /// Master System's Wonder Boy III and the Game Gear's Columns.
    @Test func realGamesAreFound() {
        let wonderBoy = CheatIndex.shared.candidates(
            forTitle: "Wonder Boy III - The Dragon's Trap (USA, Europe)", system: "sms")
        #expect(wonderBoy.contains("Wonder Boy III - The Dragon's Trap (USA, Europe) (Action Replay)"),
                "Wonder Boy III stems: \(wonderBoy)")
        let columns = CheatIndex.shared.candidates(forTitle: "Columns (USA, Europe, Brazil) (En)", system: "gg")
        #expect(columns.contains("Columns (USA, Europe, Brazil)"), "Columns stems: \(columns)")
    }

    /// libretro prints the Master System's and the Game Gear's Pro Action
    /// Replay codes with a DASH (00C0-0F05; 3,474 and 3,195 of them), and the
    /// Game Genie's with dashes too. Both shapes reach the core untouched by
    /// the formatter: the field passes them, and the browser lays them out one
    /// per line exactly as the file joins them with "+".
    @Test func libretroShapesPassTheField() {
        for system in ["sms", "gg"] {
            #expect(CheatCodeFormatter.problem(in: "00C0-0F05", isNDS: false, system: system) == nil,
                    "dashed Pro Action Replay refused on \(system)")
            #expect(CheatCodeFormatter.problem(in: "00A-19F-E66", isNDS: false, system: system) == nil,
                    "Game Genie refused on \(system)")
        }
        #expect(CheatLibrary.formatCode("00C1-3405+00C1-3505") == "00C1-3405\n00C1-3505")
        let cheats = CheatLibrary.parse("""
            cheats = 1
            cheat0_desc = "Infinite "Fire Ball" Blocks"
            cheat0_code = "00CF-3E99"
            cheat0_enable = false
            """)
        #expect(cheats.count == 1, "parsed \(cheats.count) cheats")
        #expect(cheats.first?.code == "00CF-3E99", "code was \(cheats.first?.code ?? "nil")")
        #expect(cheats.first?.description == "Infinite \"Fire Ball\" Blocks",
                "description was \(cheats.first?.description ?? "nil")")
    }

    // MARK: - Cheat field: blanks printed as "?"

    /// libretro's Sega files print a value to choose as "?" (FFFE10:??,
    /// 00C0-820? "Replace ? With 1-8"), 525 codes across the three folders.
    /// They now get the sentence that says to fill the blank in, not the one
    /// that says the character is unexpected.
    @Test func aQuestionMarkIsABlankToFill() {
        #expect(CheatCodeFormatter.problem(in: "FFFE10:??", isNDS: false, system: "md") == .placeholderValue)
        #expect(CheatCodeFormatter.problem(in: "FFFE10:0?", isNDS: false, system: "md") == .placeholderValue)
        for system in ["sms", "gg"] {
            #expect(CheatCodeFormatter.problem(in: "00C0-820?", isNDS: false, system: system) == .placeholderValue,
                    "single ? on \(system)")
            #expect(CheatCodeFormatter.problem(in: "00C1-34??\n00C1-3505", isNDS: false, system: system)
                    == .placeholderValue, "?? among lines on \(system)")
        }
        // The NES keeps X as a letter of its Game Genie alphabet.
        #expect(CheatCodeFormatter.problem(in: "SXXOPO", isNDS: false, system: "nes") == nil)
        // A stray "?" inside a word that is not a code stays a character problem.
        #expect(CheatCodeFormatter.problem(in: "HELLO?", isNDS: false, system: "gba") == .invalidCharacter)
    }

    // MARK: - RetroAchievements: the console of every extension

    /// Every extension the importer gives these consoles answers their
    /// RetroAchievements console: Mega Drive 1, Master System 11, Game Gear
    /// 15, PSP 41. A missing answer leaves `_regions` empty at load, and every
    /// achievement then reads as unsupported with nothing saying why.
    @Test func everyExtensionHasItsConsole() {
        for ext in ["md", "gen", "smd", "MD", "Gen"] {
            #expect(RAClient.consoleId(forROMPath: "/games/Sonic.\(ext)") == 1, "\(ext)")
        }
        #expect(RAClient.consoleId(forROMPath: "/games/Wonder Boy III.sms") == 11)
        #expect(RAClient.consoleId(forROMPath: "/games/Columns.gg") == 15)
        #expect(RAClient.consoleId(forROMPath: "/games/Columns.GG") == 15)
        #expect(RAClient.consoleId(forROMPath: "/games/Game.cso") == 41)
    }
}
