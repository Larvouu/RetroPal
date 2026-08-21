//
//  BoxArtMatchingTests.swift
//  EmulateurGBATests
//
//  Pins the box-art identification pipeline: CRC32 correctness, header
//  serial extraction, the fuzzy scorer's native-language behavior (the
//  reason there is NO translation step), thumbnail URL building, and the
//  real bundled BoxArtIndex.json (the tests run in the app host, so
//  Bundle.main serves the shipping index — lookups here fail if the
//  generated index ever drifts from what the matcher expects).
//
//  Everything here is offline: no request ever leaves the process.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("BoxArt matching")
struct BoxArtMatchingTests {

    // MARK: - CRC32

    @Test func crc32MatchesTheReferenceVector() throws {
        // The canonical CRC-32 check value: "123456789" -> 0xCBF43926.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crc-\(UUID().uuidString).bin")
        try Data("123456789".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BoxArtManager.crc32(of: url) == 0xCBF43926)
    }

    @Test func crc32OfAMissingFileIsNil() {
        let url = URL(fileURLWithPath: "/nonexistent/rom.gba")
        #expect(BoxArtManager.crc32(of: url) == nil)
    }

    // MARK: - Header serial

    @Test func gameCodeReadsGBAAndNDSHeaders() throws {
        // Synthetic 0x200-byte headers with the serial at the real offset:
        // GBA 0xAC-0xB0, NDS 0xC-0x10.
        var gba = Data(count: 0x200)
        gba.replaceSubrange(0x0AC..<0x0B0, with: Data("BPEF".utf8))
        var nds = Data(count: 0x200)
        nds.replaceSubrange(0x00C..<0x010, with: Data("ADAF".utf8))

        let dir = FileManager.default.temporaryDirectory
        let gbaURL = dir.appendingPathComponent("header-\(UUID().uuidString).gba")
        let ndsURL = dir.appendingPathComponent("header-\(UUID().uuidString).nds")
        try gba.write(to: gbaURL)
        try nds.write(to: ndsURL)
        defer {
            try? FileManager.default.removeItem(at: gbaURL)
            try? FileManager.default.removeItem(at: ndsURL)
        }

        #expect(GBAROMParser.gameCode(url: gbaURL, system: .gba) == "BPEF")
        #expect(GBAROMParser.gameCode(url: ndsURL, system: .nds) == "ADAF")
        // GB/GBC carts have no unique code; the helper must say so.
        #expect(GBAROMParser.gameCode(url: gbaURL, system: .gb) == nil)
    }

    @Test func headerTitleReadsTheInternalName() throws {
        var gba = Data(count: 0x200)
        gba.replaceSubrange(0x0A0..<0x0AC, with: Data("POKEMON FIRE".utf8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-\(UUID().uuidString).gba")
        try gba.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GBAROMParser.headerTitle(url: url, system: .gba) == "POKEMON FIRE")
    }

    // MARK: - Fuzzy scorer building blocks

    @Test func normalizationFoldsDiacriticsCaseAndPunctuation() {
        #expect(BoxArtIndex.normalized("Pokémon Émeraude") == "pokemon emeraude")
        #expect(BoxArtIndex.normalized("Pokemon - Version Emeraude") == "pokemon version emeraude")
        #expect(BoxArtIndex.normalized("LEGO Star Wars II!") == "lego star wars ii")
    }

    @Test func parentheticalsAreStrippedFromCandidates() {
        #expect(BoxArtIndex.strippingParentheticals(
            "Pokemon - Version Emeraude (France)") == "Pokemon - Version Emeraude")
        #expect(BoxArtIndex.strippingParentheticals(
            "Mario Kart DS (Europe) (En,Fr,De,Es,It) (Rev 1)") == "Mario Kart DS")
    }

    @Test func diceScoresIdenticalAndDisjointStrings() {
        let a = BoxArtIndex.bigrams("mariokartds")
        #expect(BoxArtIndex.dice(a, a) == 1.0)
        let b = BoxArtIndex.bigrams("zzzzqqqq")
        #expect(BoxArtIndex.dice(a, b) == 0.0)
    }

    @Test func nativeTitleClearsThresholdWhereHackDoesNot() {
        // The two calibration points behind fuzzyThreshold = 0.55:
        // a French-named file against its French stem must pass...
        let emeraude = BoxArtIndex.dice(
            BoxArtIndex.bigrams(BoxArtIndex.normalized("Pokémon Émeraude")),
            BoxArtIndex.bigrams(BoxArtIndex.normalized("Pokemon - Version Emeraude")))
        #expect(emeraude >= BoxArtIndex.fuzzyThreshold)
        // ...while a ROM hack must not silently claim the base game's box.
        let radicalRed = BoxArtIndex.dice(
            BoxArtIndex.bigrams(BoxArtIndex.normalized("Pokemon Radical Red")),
            BoxArtIndex.bigrams(BoxArtIndex.normalized("Pokemon - FireRed Version")))
        #expect(radicalRed < BoxArtIndex.fuzzyThreshold)
    }

    @Test func tokenCoverageCountsQueryWordsInTheCandidate() {
        // The franchise word alone must not carry a hack: 1 of 3 words.
        #expect(BoxArtIndex.tokenCoverage(query: "Pokemon Radical Red",
                                          candidate: "Pokemon - Edicion Rubi") == 1.0 / 3.0)
        // Legit shorthand covers fully ("cap" is found inside "minishcap").
        #expect(BoxArtIndex.tokenCoverage(query: "Zelda Minish Cap",
                                          candidate: "Legend of Zelda, The - The Minish Cap") == 1.0)
    }

    @Test func filenameConsistencyGateSeparatesHacksFromTrims() {
        // A FireRed hack's filename contradicts the serial's game (0.44)...
        #expect(!BoxArtIndex.filenameIsConsistent("Pokemon Radical Red",
                                                  withStem: "Pokemon - FireRed Version (USA)"))
        // ...while a trimmed dump's filename agrees with it (0.79), and a
        // scene-numbered filename still passes (0.72).
        #expect(BoxArtIndex.filenameIsConsistent("Pokemon Diamant",
                                                 withStem: "Pokemon - Version Diamant (France) (Rev 5)"))
        #expect(BoxArtIndex.filenameIsConsistent("3959 - Pokemon Platinum",
                                                 withStem: "Pokemon - Platinum Version (Europe) (En,Fr,De,Es,It)"))
    }

    @Test func regionRankPrefersLocaleThenEurope() {
        let fr = Locale(identifier: "fr_FR")
        #expect(BoxArtIndex.regionRank(of: "Mario Kart DS (France)", locale: fr) == 0)
        #expect(BoxArtIndex.regionRank(of: "Mario Kart DS (Europe)", locale: fr) == 1)
        #expect(BoxArtIndex.regionRank(of: "Mario Kart DS (USA)", locale: fr) == 3)
        #expect(BoxArtIndex.regionRank(of: "Mario Kart DS (Japan)", locale: fr) == 4)
    }

    // MARK: - Thumbnail URLs

    @Test func thumbnailURLEncodesSpacesAndKeepsParentheses() {
        // Verified live 2026-07-10: the server serves parens/commas/
        // apostrophes raw; '&' was substituted at index-build time.
        let url = BoxArtManager.thumbnailURL(
            stem: "Pokemon - Version Emeraude (France)",
            systemDirectory: "Nintendo - Game Boy Advance")
        #expect(url.absoluteString ==
            "https://thumbnails.libretro.com/Nintendo%20-%20Game%20Boy%20Advance/Named_Boxarts/Pokemon%20-%20Version%20Emeraude%20(France).png")
    }

    @Test func stemVariantsAddARevStrippedFallbackOnlyWhenRevved() {
        #expect(BoxArtManager.stemVariants("Tetris (World) (Rev 1)")
                == ["Tetris (World) (Rev 1)", "Tetris (World)"])
        #expect(BoxArtManager.stemVariants("Tetris (World)") == ["Tetris (World)"])
    }

    // MARK: - The real bundled index

    @Test func bundledIndexLoads() {
        #expect(BoxArtIndex.shared.isLoaded)
    }

    @Test func crcLookupResolvesAKnownDump() {
        // Lilo & Stitch (Europe), CRC from the no-intro DAT; the stem must
        // carry libretro's '&' -> '_' substitution (verified live).
        #expect(BoxArtIndex.shared.exactName(crc32: 0x2A10F7E4, system: .gba)
                == "Lilo _ Stitch (Europe) (En,Fr,De,Es,It,Nl)")
    }

    @Test func serialLookupResolvesNativeRegionalReleases() {
        // The whole point of the serial tier: a renamed or trimmed French
        // cart still gets the FRENCH cover, no translation step anywhere.
        #expect(BoxArtIndex.shared.serialName("BPEF", system: .gba)
                == "Pokemon - Version Emeraude (France)")
        #expect(BoxArtIndex.shared.serialName("BPEE", system: .gba)
                == "Pokemon - Emerald Version (USA, Europe)")
        // GB/GBC serials are not a thing; the index must refuse them.
        #expect(BoxArtIndex.shared.serialName("BPEF", system: .gb) == nil)
    }

    @Test func fuzzyFindsTheNativeStemFromAFrenchFilename() {
        let candidates = BoxArtIndex.shared.fuzzyCandidates(
            for: ["Pokémon Version Émeraude"], system: .gba, limit: 3)
        #expect(candidates.first == "Pokemon - Version Emeraude (France)")
    }

    @Test func fuzzyReturnsNothingForHomebrewNames() {
        let candidates = BoxArtIndex.shared.fuzzyCandidates(
            for: ["My Cool Homebrew Adventure 2026"], system: .gba, limit: 3)
        #expect(candidates.isEmpty)
    }

    @Test func fuzzyRejectsDistinctlyNamedHacksButKeepsShorthand() {
        // Bigrams alone score Radical Red 0.61 against Edicion Rubi; the
        // token-coverage bar is what keeps hacks out of the fuzzy tier.
        #expect(BoxArtIndex.shared.fuzzyCandidates(
            for: ["Pokemon Radical Red"], system: .gba, limit: 3).isEmpty)
        #expect(BoxArtIndex.shared.fuzzyCandidates(
            for: ["Pokemon Unbound"], system: .gba, limit: 3).isEmpty)
        // Legit shorthand must survive the same bar.
        #expect(BoxArtIndex.shared.fuzzyCandidates(
            for: ["Zelda Minish Cap"], system: .gba, limit: 3)
            .first?.contains("Minish Cap") == true)
    }

    // MARK: - Candidate assembly (the ROM-hack rule end to end)

    @Test func hackWithBaseGameHeaderGetsNoCandidates() {
        // Radical Red: CRC misses (patched bytes), the header serial says
        // FireRed, the filename says otherwise, the library title is a
        // header echo (excluded upstream, so userTitle is nil).
        let result = BoxArtManager.assembleCandidates(
            crcStem: nil,
            serialStem: "Pokemon - FireRed Version (USA)",
            filenameTitle: "Pokemon Radical Red",
            userTitle: nil,
            system: .gba,
            index: .shared)
        #expect(result.isEmpty)
    }

    @Test func trimmedDumpStillMatchesThroughItsSerial() {
        // A trimmed NDS ROM: CRC misses, but the filename agrees with the
        // serial's game, so the serial stem leads the candidates.
        let result = BoxArtManager.assembleCandidates(
            crcStem: nil,
            serialStem: "Pokemon - Version Diamant (France) (Rev 5)",
            filenameTitle: "Pokemon Diamant",
            userTitle: nil,
            system: .nds,
            index: .shared)
        #expect(result.first == BoxArtCandidate(
            stem: "Pokemon - Version Diamant (France) (Rev 5)", method: "serial"))
    }

    @Test func byteExactDumpNeverGatesItsSerial() {
        // With a CRC match the file is a pristine dump: the serial backup
        // stem is kept even when the filename is opaque.
        let result = BoxArtManager.assembleCandidates(
            crcStem: "Pokemon - Version Emeraude (France)",
            serialStem: "Pokemon - Version Emeraude (France) (Rev 1)",
            filenameTitle: "backup rom 12",
            userTitle: nil,
            system: .gba,
            index: .shared)
        #expect(result.map(\.method) == ["crc", "serial"])
    }

    @Test func inAppRenameRescuesAnOpaqueFilename() {
        // "rom.gba" renamed to the real title in the library: the rename is
        // a user-chosen identity, so fuzzy finds the native stem.
        let result = BoxArtManager.assembleCandidates(
            crcStem: nil,
            serialStem: nil,
            filenameTitle: "rom",
            userTitle: "Pokémon Version Émeraude",
            system: .gba,
            index: .shared)
        #expect(result.first == BoxArtCandidate(
            stem: "Pokemon - Version Emeraude (France)", method: "fuzzy"))
    }

    // MARK: - Regional siblings (the cheat browser's fallback)

    // Run against the real bundled index, because the value of this lookup is
    // entirely a claim about that data.

    @Test("A localized cartridge finds its other regional releases")
    func findsRegionalSiblings() {
        // BPRF is Pokemon Version Rouge Feu (France). Its siblings are the same
        // cartridge everywhere else: BPRE USA/Europe, BPRD Germany, BPRI Italy,
        // BPRS Spain, BPRJ Japan.
        let siblings = BoxArtIndex.shared.regionalSiblingNames(ofSerial: "BPRF", system: .gba)
        #expect(siblings.contains("Pokemon - FireRed Version (USA, Europe)"))
        #expect(siblings.contains("Pokemon - Feuerrote Edition (Germany)"))
        #expect(!siblings.contains("Pokemon - Version Rouge Feu (France)"))   // itself
    }

    @Test("The English release is offered first, not the alphabetical one")
    func prefersEnglishSibling() {
        // The whole point of the ordering. Alphabetically the German title wins
        // and a French player reads German cheat names for no reason.
        let siblings = BoxArtIndex.shared.regionalSiblingNames(ofSerial: "BPRF", system: .gba)
        #expect(siblings.first == "Pokemon - FireRed Version (USA, Europe)")

        let ruby = BoxArtIndex.shared.regionalSiblingNames(ofSerial: "AXVF", system: .gba)
        #expect(ruby.first == "Pokemon - Ruby Version (USA, Europe)")
    }

    @Test("Consoles without a cartridge code get nothing rather than a guess")
    func noSiblingsWithoutASerial() {
        #expect(BoxArtIndex.shared.regionalSiblingNames(ofSerial: "BPRF", system: .gb).isEmpty)
        #expect(BoxArtIndex.shared.regionalSiblingNames(ofSerial: "BPR", system: .gba).isEmpty)
        #expect(BoxArtIndex.shared.regionalSiblingNames(ofSerial: "", system: .gba).isEmpty)
    }
}
