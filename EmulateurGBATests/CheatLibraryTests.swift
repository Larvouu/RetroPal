//
//  CheatLibraryTests.swift
//  EmulateurGBATests
//
//  The two pure halves of the cheat database: the title key that has to stay
//  byte-identical to Tools/build_cheat_index.py, and the .cht parser.
//
//  The normalisation test is the load-bearing one. If Swift and Python ever
//  disagree about what a bare title is, every lookup silently returns nothing
//  and the feature looks broken rather than failing loudly.
//

import Testing
@testable import EmulateurGBA

@Suite("Cheat database")
struct CheatLibraryTests {

    // MARK: - Retail before hacks, the own release before the siblings (2026-09-10)

    @Test("A hack's stem nests a parenthesis, a retail dump's never does")
    func hackStemsNest() {
        #expect(CheatIndex.isHackStem("Pokemon - SoulSilver Version (Europe) (Rev 10) (Pokemon - SoothingSilver Version (v1.3.1))"))
        #expect(CheatIndex.isHackStem("Pocket Monsters - SoulSilver (Japan) (Pokemon - Absolute SoulSilver - The End (v1.0))"))
        #expect(!CheatIndex.isHackStem("Pokemon - SoulSilver Version (Europe) (Rev 10)"))
        #expect(!CheatIndex.isHackStem("Pokemon - Silberne Edition SoulSilver (Germany)"))
        #expect(!CheatIndex.isHackStem("Legend of Zelda, The - A Link to the Past (USA) [T-Fr]"))
    }

    @Test("Retail dumps come first and each group keeps its order")
    func retailStemsComeFirst() {
        let sorted = CheatIndex.retailFirst([
            "Pokemon - SoulSilver Version (Europe) (Rev 10) (Pokemon - SoothingSilver Version (v1.3.1))",
            "Pokemon - SoulSilver Version (Europe) (Rev 10)",
            "Pokemon - SoulSilver Version (USA) (Pokemon - MoonSilver Version (20160416))",
            "Pokemon - SoulSilver Version (USA)",
        ])
        #expect(sorted == [
            "Pokemon - SoulSilver Version (Europe) (Rev 10)",
            "Pokemon - SoulSilver Version (USA)",
            "Pokemon - SoulSilver Version (Europe) (Rev 10) (Pokemon - SoothingSilver Version (v1.3.1))",
            "Pokemon - SoulSilver Version (USA) (Pokemon - MoonSilver Version (20160416))",
        ])
    }

    @Test("The bundled index serves the retail SoulSilver before its hacks")
    func bundledSoulSilverLeadsWithRetail() {
        let stems = CheatIndex.shared.candidates(forTitle: "Pokemon - SoulSilver Version", system: "nds")
        #expect(stems.count > 2)
        #expect(stems.first == "Pokemon - SoulSilver Version (Europe) (Rev 10)")
        // Every retail stem precedes every hack.
        if let firstHack = stems.firstIndex(where: CheatIndex.isHackStem) {
            #expect(!stems[firstHack...].contains { !CheatIndex.isHackStem($0) })
        }
    }

    @Test("A numbered set's filename resolves through its cartridge code to its own release")
    func numberedFilenameResolvesThroughTheSerial() {
        let filename = "4828 - Pokemon - Silberne Edition SoulSilver (G)"
        // The filename alone keys nothing: the catalogue number survives the tag strip.
        #expect(CheatIndex.shared.candidates(forTitle: filename, system: "nds").isEmpty)
        // The serial names the German release, and that name has its own file.
        let own = BoxArtIndex.shared.serialName("IPGD", system: .nds)
        #expect(own == "Pokemon - Silberne Edition SoulSilver (Germany)")
        guard let own else { return }
        let title = CheatIndex.ownReleaseTitle(forROMName: filename, serialName: own)
        #expect(title == own)
        #expect(CheatIndex.shared.candidates(forTitle: own, system: "nds")
                == ["Pokemon - Silberne Edition SoulSilver (Germany)"])
    }

    @Test("A filename that already keys its own release asks nothing more of the serial")
    func wellNamedFileNeedsNoSerialStep() {
        #expect(CheatIndex.ownReleaseTitle(forROMName: "Pokemon - Silberne Edition SoulSilver (Germany)",
                                           serialName: "Pokemon - Silberne Edition SoulSilver (Germany)") == nil)
        #expect(CheatIndex.ownReleaseTitle(forROMName: "Pokemon Silberne Edition SoulSilver",
                                           serialName: "Pokemon - Silberne Edition SoulSilver (Germany)") == nil)
    }

    // MARK: - Title normalisation (mirrors build_cheat_index.bare_title)

    @Test("Region and language tags are dropped")
    func dropsTags() {
        #expect(CheatIndex.bareTitle("Pokemon - Emerald Version (USA, Europe)")
                == "pokemonemeraldversion")
        #expect(CheatIndex.bareTitle("Pokemon - Emerald Version (USA, Europe) (Code Breaker)")
                == "pokemonemeraldversion")
    }

    @Test("Bracketed tags are dropped too")
    func dropsBrackets() {
        #expect(CheatIndex.bareTitle("Some Game [!] (Europe)") == "somegame")
    }

    @Test("libretro's underscore substitution reads as 'and'")
    func underscoreBecomesAnd() {
        // '&' is served as '_' in libretro filenames.
        #expect(CheatIndex.bareTitle("Dungeons _ Dragons - Eye of the Beholder (USA)")
                == "dungeonsanddragonseyeofthebeholder")
    }

    @Test("Accented letters are dropped, exactly as the Python side drops them")
    func stripsAccents() {
        // The builder keeps [a-z0-9] only. If Swift kept the accent the two
        // sides would disagree and every Pokemon lookup would miss.
        #expect(CheatIndex.bareTitle("Pokémon Emerald") == "pokmonemerald")
    }

    @Test("Punctuation and case do not matter")
    func ignoresPunctuationAndCase() {
        #expect(CheatIndex.bareTitle("The Legend of Zelda: A Link to the Past")
                == CheatIndex.bareTitle("the legend of zelda - a link to the past"))
    }

    @Test("A differently named file still lands on the same key")
    func matchesLooseFilenames() {
        #expect(CheatIndex.bareTitle("Mario Kart DS (USA)") == CheatIndex.bareTitle("mario kart ds"))
    }

    // MARK: - Code layout

    @Test("Eight-digit words are paired two per line")
    func pairsThirtyTwoBitWords() {
        #expect(CheatLibrary.formatCode("D8BAE4D9+4864DCE5+A86CDBA5+19BA49B3")
                == "D8BAE4D9 4864DCE5\nA86CDBA5 19BA49B3")
    }

    @Test("CodeBreaker address-then-value pairs stay together")
    func pairsCodeBreaker() {
        #expect(CheatLibrary.formatCode("3200E924+0096+330034B8+0096")
                == "3200E924 0096\n330034B8 0096")
    }

    @Test("A single word is left alone")
    func singleWord() {
        #expect(CheatLibrary.formatCode("82003884") == "82003884")
    }

    @Test("Game Genie codes are not reshaped")
    func leavesGameGenie() {
        #expect(CheatLibrary.formatCode("009-15C") == "009-15C")
    }

    @Test("An empty code stays empty")
    func emptyCode() {
        #expect(CheatLibrary.formatCode("") == "")
        #expect(CheatLibrary.formatCode("+++") == "")
    }

    // MARK: - .cht parsing

    @Test("Descriptions and codes are paired by index")
    func parsesPairs() {
        let text = """
        cheats = 2

        cheat0_desc = "Infinite Health"
        cheat0_code = "3200E924+0096"
        cheat0_enable = false

        cheat1_desc = "Infinite Ammo"
        cheat1_code = "33003981+00FF"
        cheat1_enable = false
        """
        let cheats = CheatLibrary.parse(text)
        #expect(cheats.count == 2)
        #expect(cheats[0].description == "Infinite Health")
        #expect(cheats[0].code == "3200E924 0096")
        #expect(cheats[1].description == "Infinite Ammo")
    }

    @Test("Category headers with no code are dropped")
    func dropsHeaders() {
        // The DS files are full of these; they would otherwise show as
        // tappable rows that insert nothing.
        let text = """
        cheats = 2

        cheat0_desc = "Miscellaneous Codes"

        cheat1_desc = "Real code"
        cheat1_code = "520A98E8+EE070F90"
        """
        let cheats = CheatLibrary.parse(text)
        #expect(cheats.count == 1)
        #expect(cheats[0].description == "Real code")
    }

    @Test("An empty file yields nothing rather than a phantom row")
    func parsesEmptyFile() {
        #expect(CheatLibrary.parse("cheats = 0\n").isEmpty)
    }

    @Test("A code with no description still comes through")
    func codeWithoutDescription() {
        let cheats = CheatLibrary.parse("cheat0_code = \"82003884+0001\"")
        #expect(cheats.count == 1)
        #expect(cheats[0].description.isEmpty)
    }
}
