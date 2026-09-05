//
//  DiscImportGrouperTests.swift
//  EmulateurGBATests
//
//  The PlayStation is the first console whose games are not files, so the step
//  that decides "which of these picked files are one game?" is new logic with
//  no precedent in the app to lean on. It is also pure, which is why it lives
//  in its own type: everything below runs against real files in a temp
//  directory and needs no core, no Core Data and no device.
//
//  The cases are the shapes a real collection actually arrives in, plus the two
//  that must NOT become failures: a lone sidecar, and a cartridge batch that
//  happens to travel with disc files.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("DiscImportGrouper")
struct DiscImportGrouperTests {

    // MARK: - Helpers

    /// A temp directory that cleans itself up when the test ends.
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disc-group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func write(_ name: String, in dir: URL, bytes: Int = 16, text: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        if let text {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try Data(repeating: 0xAB, count: bytes).write(to: url)
        }
        return url
    }

    private func cue(_ tracks: [String]) -> String {
        tracks.map { "FILE \"\($0)\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00" }
            .joined(separator: "\n") + "\n"
    }

    private func names(_ urls: [URL]) -> Set<String> {
        Set(urls.map(\.lastPathComponent))
    }

    // MARK: - The ordinary shapes

    @Test("A single .chd is one game that boots from itself")
    func singleImage() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chd = try write("Crash Bandicoot.chd", in: dir, bytes: 512)

        let (cartridges, discs, gaps) = DiscImportGrouper.group([chd])

        #expect(cartridges.isEmpty)
        #expect(gaps.isEmpty)
        #expect(discs.count == 1)
        #expect(discs.first?.boot == chd)
        #expect(discs.first?.members.count == 1)
    }

    @Test("A .cue and its .bin are ONE game, booting from the .cue")
    func cueAndBin() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = try write("Metal Gear Solid.bin", in: dir, bytes: 4096)
        let cueURL = try write("Metal Gear Solid.cue", in: dir,
                               text: cue(["Metal Gear Solid.bin"]))

        let (_, discs, gaps) = DiscImportGrouper.group([bin, cueURL])

        #expect(gaps.isEmpty)
        #expect(discs.count == 1, "two files, one game")
        #expect(discs.first?.boot == cueURL)
        #expect(names(discs.first?.members ?? []) == ["Metal Gear Solid.cue", "Metal Gear Solid.bin"])
    }

    @Test("A multi-track .cue claims every .bin it names")
    func multiTrackCue() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracks = ["Game (Track 1).bin", "Game (Track 2).bin", "Game (Track 3).bin"]
        for t in tracks { try write(t, in: dir, bytes: 64) }
        let cueURL = try write("Game.cue", in: dir, text: cue(tracks))

        let picked = tracks.map { dir.appendingPathComponent($0) } + [cueURL]
        let (_, discs, gaps) = DiscImportGrouper.group(picked)

        #expect(gaps.isEmpty)
        #expect(discs.count == 1)
        #expect(discs.first?.members.count == 4)
    }

    @Test("An .m3u makes several discs one game, and it is the boot file")
    func multiDisc() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in 1...2 {
            try write("FF7 (Disc \(n)).bin", in: dir, bytes: 2048)
            try write("FF7 (Disc \(n)).cue", in: dir, text: cue(["FF7 (Disc \(n)).bin"]))
        }
        let m3u = try write("FF7.m3u", in: dir,
                            text: "# Final Fantasy VII\nFF7 (Disc 1).cue\nFF7 (Disc 2).cue\n")

        let picked = [m3u,
                      dir.appendingPathComponent("FF7 (Disc 1).cue"),
                      dir.appendingPathComponent("FF7 (Disc 1).bin"),
                      dir.appendingPathComponent("FF7 (Disc 2).cue"),
                      dir.appendingPathComponent("FF7 (Disc 2).bin")]
        let (_, discs, gaps) = DiscImportGrouper.group(picked)

        #expect(gaps.isEmpty)
        #expect(discs.count == 1, "five files, one game")
        #expect(discs.first?.boot == m3u)
        #expect(discs.first?.members.count == 5)
    }

    // MARK: - Names only, which is the path the ZIP importer uses

    @Test("A 58-part archive is ONE game, not 58")
    func realArchiveShape() {
        // The exact shape that shipped broken to a device: Tomb Raider (USA)
        // (Rev 1) is one .cue and fifty-seven .bin tracks in a single zip. The
        // importer offered all fifty-eight as games, every one unplayable.
        let stem = "Tomb Raider (USA) (Rev 1)"
        let tracks = (1...57).map { String(format: "\(stem) (Track %02d).bin", $0) }
        let cueName = "\(stem).cue"
        let cueText = tracks.map { "FILE \"\($0)\" BINARY\n  TRACK 01 MODE2/2352" }
            .joined(separator: "\n")

        let (others, discs, gaps) = DiscImportGrouper.groupNames(tracks + [cueName]) { name in
            name == cueName ? cueText : nil
        }

        #expect(others.isEmpty)
        #expect(gaps.isEmpty)
        #expect(discs.count == 1, "58 files, one game")
        #expect(discs.first?.boot == cueName)
        #expect(discs.first?.members.count == 58)
        #expect(discs.first?.displayName == stem)
    }

    @Test("Archive entries keep their folder prefix while matching bare references")
    func folderPrefixedEntries() {
        // A zip routinely nests its files in a directory, while a .cue always
        // names its tracks WITHOUT a path. Both sides have to meet.
        let names = ["Game/Game.cue", "Game/Game (Track 1).bin", "Game/Game (Track 2).bin"]
        let cue = "FILE \"Game (Track 1).bin\" BINARY\nFILE \"Game (Track 2).bin\" BINARY\n"

        let (_, discs, gaps) = DiscImportGrouper.groupNames(names) {
            $0.hasSuffix(".cue") ? cue : nil
        }

        #expect(gaps.isEmpty)
        #expect(discs.count == 1)
        #expect(discs.first?.members.count == 3)
        #expect(discs.first?.boot == "Game/Game.cue", "the full entry name is what extraction needs")
        #expect(discs.first?.displayName == "Game", "but the NAME is what the library shows")
    }

    @Test("Two complete games in one archive stay two games")
    func twoGamesInOneArchive() {
        let names = ["A.cue", "A.bin", "B.cue", "B.bin"]
        let (_, discs, gaps) = DiscImportGrouper.groupNames(names) { name in
            name == "A.cue" ? "FILE \"A.bin\" BINARY\n"
                : name == "B.cue" ? "FILE \"B.bin\" BINARY\n" : nil
        }
        #expect(gaps.isEmpty)
        #expect(discs.count == 2)
        #expect(discs.allSatisfy { $0.members.count == 2 })
    }

    // MARK: - The cases that must not silently half-work

    @Test("A .cue without its .bin is a gap that names the missing file")
    func missingTrack() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cueURL = try write("Tekken 3.cue", in: dir, text: cue(["Tekken 3.bin"]))

        let (_, discs, gaps) = DiscImportGrouper.group([cueURL])

        #expect(discs.isEmpty, "a game we cannot read must not be imported")
        #expect(gaps.count == 1)
        #expect(gaps.first?.missing == ["Tekken 3.bin"],
                "the message has to name the file, not say 'something is missing'")
    }

    @Test("A .cue whose capitalisation disagrees with the file still matches")
    func caseInsensitiveTrack() throws {
        // Cues are routinely written by Windows tools and disagree with the
        // filesystem's own casing. Losing a game to that would be absurd.
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Ridge Racer.bin", in: dir, bytes: 128)
        let cueURL = try write("Ridge Racer.cue", in: dir, text: cue(["RIDGE RACER.BIN"]))

        let (_, discs, gaps) = DiscImportGrouper.group(
            [cueURL, dir.appendingPathComponent("Ridge Racer.bin")])

        #expect(gaps.isEmpty)
        #expect(discs.first?.members.count == 2)
    }

    @Test("A .sbi travels with its disc, and alone it is dropped rather than failed")
    func libCryptSidecar() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Ape Escape.bin", in: dir, bytes: 256)
        let sbi = try write("Ape Escape.sbi", in: dir, bytes: 32)
        let cueURL = try write("Ape Escape.cue", in: dir, text: cue(["Ape Escape.bin"]))

        let (_, withDisc, _) = DiscImportGrouper.group(
            [cueURL, dir.appendingPathComponent("Ape Escape.bin"), sbi])
        #expect(withDisc.first?.members.count == 3, "the .sbi belongs to the game")

        let (cartridges, alone, gaps) = DiscImportGrouper.group([sbi])
        #expect(alone.isEmpty, "a patch file is not a game")
        #expect(gaps.isEmpty, "and picking one is not an error worth an alert")
        #expect(cartridges.isEmpty, "nor is it a cartridge")
    }

    // MARK: - Not regressing the six consoles that already work

    @Test("Cartridges come back untouched, in their original order")
    func cartridgesUnaffected() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gba = try write("Pokemon.gba", in: dir, bytes: 64)
        let nds = try write("Mario Kart.nds", in: dir, bytes: 64)
        let zip = try write("Collection.zip", in: dir, bytes: 64)
        let chd = try write("Wipeout.chd", in: dir, bytes: 64)

        let (cartridges, discs, gaps) = DiscImportGrouper.group([gba, nds, zip, chd])

        #expect(cartridges == [gba, nds, zip], "order preserved, zip still a cartridge concern")
        #expect(discs.count == 1)
        #expect(gaps.isEmpty)
    }

    // MARK: - Discs of one game that arrived with no playlist

    @Test("Three .chd of one game become ONE game, with a playlist written for it")
    func chdDiscsWithNoPlaylistMerge() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Redump's own naming, which is how nearly every dump in the world is
        // named, and the case that used to produce three library entries: three
        // memory cards, and the save from disc one absent when disc two started.
        let picked = try (1...3).map {
            try write("Final Fantasy VII (USA) (Disc \($0)).chd", in: dir, bytes: 64)
        }

        let (_, discs, gaps) = DiscImportGrouper.group(picked)

        #expect(gaps.isEmpty)
        #expect(discs.count == 1, "three discs, one game")
        let game = try #require(discs.first)
        #expect(game.displayName == "Final Fantasy VII (USA)",
                "the game is named without the disc token")
        #expect(game.members.count == 3)
        #expect(game.playlistDiscs == ["Final Fantasy VII (USA) (Disc 1).chd",
                                       "Final Fantasy VII (USA) (Disc 2).chd",
                                       "Final Fantasy VII (USA) (Disc 3).chd"],
                "the playlist names every disc, in disc order")
        #expect(game.boot.lastPathComponent == "Final Fantasy VII (USA) (Disc 1).chd",
                "something has to identify the game before its playlist exists")
    }

    @Test("Discs picked out of order still come back in disc order")
    func playlistIsOrderedByDiscNumber() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let three = try write("MGS (Disc 3).chd", in: dir, bytes: 64)
        let one = try write("MGS (Disc 1).chd", in: dir, bytes: 64)
        let two = try write("MGS (Disc 2).chd", in: dir, bytes: 64)

        let (_, discs, _) = DiscImportGrouper.group([three, one, two])
        #expect(discs.first?.playlistDiscs == ["MGS (Disc 1).chd", "MGS (Disc 2).chd",
                                               "MGS (Disc 3).chd"])
    }

    @Test("A .cue+.bin pair per disc merges too, and every part comes along")
    func cueDiscsMerge() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var picked: [URL] = []
        for n in 1...2 {
            try write("Grandia (Disc \(n)).bin", in: dir, bytes: 2048)
            picked.append(try write("Grandia (Disc \(n)).cue", in: dir,
                                    text: cue(["Grandia (Disc \(n)).bin"])))
            picked.append(dir.appendingPathComponent("Grandia (Disc \(n)).bin"))
        }

        let (_, discs, gaps) = DiscImportGrouper.group(picked)
        #expect(gaps.isEmpty)
        #expect(discs.count == 1)
        let game = try #require(discs.first)
        #expect(game.members.count == 4, "two cues and their two bins")
        #expect(game.playlistDiscs == ["Grandia (Disc 1).cue", "Grandia (Disc 2).cue"],
                "a playlist names the DESCRIPTORS, not the data tracks")
        #expect(game.displayName == "Grandia")
    }

    @Test("The naming conventions people actually have all merge")
    func theCommonSpellingsAllWork() throws {
        for (first, second, expected) in [
            ("Chrono Cross [CD1].chd", "Chrono Cross [CD2].chd", "Chrono Cross"),
            ("Parasite Eve - Disc 1.chd", "Parasite Eve - Disc 2.chd", "Parasite Eve"),
            ("FF8_Disc_1.chd", "FF8_Disc_2.chd", "FF8"),
            ("MGS (Disc 1 of 2).chd", "MGS (Disc 2 of 2).chd", "MGS"),
            ("Grandia (Disc1).chd", "Grandia (Disc2).chd", "Grandia"),
        ] {
            let dir = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let a = try write(first, in: dir, bytes: 64)
            let b = try write(second, in: dir, bytes: 64)
            let (_, discs, _) = DiscImportGrouper.group([a, b])
            #expect(discs.count == 1, "\(first) and \(second) should be one game")
            #expect(discs.first?.displayName == expected)
        }
    }

    /// ⚠ THE HALF THAT MATTERS MORE. Merging two games that are not one is worse
    /// than leaving a multi-disc game as separate entries: the player can work
    /// around the second and cannot undo the first.
    @Test("What must NOT merge, does not")
    func theConservativeHalf() throws {
        for (first, second, why) in [
            ("Gran Turismo.chd", "Rayman.chd", "two unrelated games"),
            ("Crash Bandicoot 2.chd", "Crash Bandicoot 3.chd", "a number is not a disc token"),
            ("Ridge Racer Type 4.chd", "Ridge Racer Type 2.chd", "nor is one in the title"),
            ("Tekken (Disc 1).chd", "Tomb Raider (Disc 1).chd", "different games, same number"),
            ("FF7 (Disc 1).chd", "FF8 (Disc 2).chd", "different bases"),
            ("Wipeout (Disc 1).chd", "Wipeout (Disc 1) (Alt).chd", "the same number twice"),
        ] {
            let dir = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let a = try write(first, in: dir, bytes: 64)
            let b = try write(second, in: dir, bytes: 64)
            let (_, discs, _) = DiscImportGrouper.group([a, b])
            #expect(discs.count == 2, "\(why): \(first) + \(second) must stay two games")
        }
    }

    /// The merge's own invariant, asserted where it lives.
    ///
    /// Merging puts every part into ONE folder, so two discs carrying files of
    /// the same name from different places would overwrite each other and disc
    /// two would read disc one's data. The picked-files and archive paths make
    /// this hard to reach on their own, because `groupNames` keys references on
    /// the bare filename and so never hands the same name to two groups. That is
    /// a property of today's callers rather than of the merge, which is why the
    /// guard is here and why this test calls the merge directly.
    @Test("Discs whose parts share a filename are left apart rather than merged")
    func filenameCollisionsBlockTheMerge() throws {
        let colliding = [
            DiscNameGroup(boot: "/a/Wild Arms (Disc 1).cue",
                          members: ["/a/Wild Arms (Disc 1).cue", "/a/track01.bin"]),
            DiscNameGroup(boot: "/b/Wild Arms (Disc 2).cue",
                          members: ["/b/Wild Arms (Disc 2).cue", "/b/track01.bin"]),
        ]
        let out = DiscImportGrouper.mergeDiscsOfOneGame(colliding)
        #expect(out.count == 2, "a filename collision must block the merge, not corrupt the game")
        #expect(out.allSatisfy { $0.playlistDiscs == nil })

        // And the same two discs with their tracks named apart DO merge, which
        // is what proves the guard above is the thing doing the blocking.
        let distinct = [
            DiscNameGroup(boot: "/a/Wild Arms (Disc 1).cue",
                          members: ["/a/Wild Arms (Disc 1).cue", "/a/wa1.bin"]),
            DiscNameGroup(boot: "/b/Wild Arms (Disc 2).cue",
                          members: ["/b/Wild Arms (Disc 2).cue", "/b/wa2.bin"]),
        ]
        let merged = DiscImportGrouper.mergeDiscsOfOneGame(distinct)
        #expect(merged.count == 1)
        #expect(merged.first?.displayName == "Wild Arms")
    }

    @Test("One disc on its own is one game, and gets no playlist")
    func aLoneDiscIsNotAMultiDiscGame() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let only = try write("Final Fantasy VII (USA) (Disc 2).chd", in: dir, bytes: 64)

        let (_, discs, _) = DiscImportGrouper.group([only])
        #expect(discs.count == 1)
        #expect(discs.first?.playlistDiscs == nil, "nothing to write a playlist from")
        #expect(discs.first?.displayName == "Final Fantasy VII (USA) (Disc 2)",
                "and it keeps its own name, disc token included")
    }

    @Test("A real .m3u still wins, and nothing is written for it")
    func anExistingPlaylistIsUntouched() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in 1...2 { try write("FF7 (Disc \(n)).chd", in: dir, bytes: 64) }
        let m3u = try write("FF7.m3u", in: dir, text: "FF7 (Disc 1).chd
FF7 (Disc 2).chd
")
        let picked = [m3u,
                      dir.appendingPathComponent("FF7 (Disc 1).chd"),
                      dir.appendingPathComponent("FF7 (Disc 2).chd")]

        let (_, discs, gaps) = DiscImportGrouper.group(picked)
        #expect(gaps.isEmpty)
        #expect(discs.count == 1)
        #expect(discs.first?.boot == m3u, "the playlist the user has is the boot file")
        #expect(discs.first?.playlistDiscs == nil, "and no second playlist is invented")
    }

    @Test("A merged game and an unrelated one both survive, in order")
    func mergingKeepsTheRestOfTheBatch() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = try write("FF7 (Disc 1).chd", in: dir, bytes: 64)
        let other = try write("Rayman.chd", in: dir, bytes: 64)
        let two = try write("FF7 (Disc 2).chd", in: dir, bytes: 64)

        let (_, discs, _) = DiscImportGrouper.group([one, other, two])
        #expect(discs.count == 2)
        #expect(discs.map(\.displayName) == ["FF7", "Rayman"],
                "the merged game takes the place of its first disc")
    }

    @Test("A missing part is still a gap, and a gap is never merged into a game")
    func aBrokenDiscStaysAGap() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Disc 1 is complete; disc 2's data track was not picked.
        try write("Grandia (Disc 1).bin", in: dir, bytes: 2048)
        let cue1 = try write("Grandia (Disc 1).cue", in: dir, text: cue(["Grandia (Disc 1).bin"]))
        let cue2 = try write("Grandia (Disc 2).cue", in: dir, text: cue(["Grandia (Disc 2).bin"]))

        let (_, discs, gaps) = DiscImportGrouper.group(
            [cue1, dir.appendingPathComponent("Grandia (Disc 1).bin"), cue2])

        #expect(gaps.count == 1, "the incomplete disc is reported, not swallowed")
        #expect(gaps.first?.missing == ["Grandia (Disc 2).bin"])
        #expect(discs.count == 1, "and the complete one is still a game")
        #expect(discs.first?.playlistDiscs == nil,
                "one surviving disc is not a multi-disc game")
    }

    @Test("Two unrelated discs stay two games")
    func twoDiscsTwoGames() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try write("Gran Turismo.chd", in: dir, bytes: 64)
        let b = try write("Rayman.chd", in: dir, bytes: 64)

        let (_, discs, _) = DiscImportGrouper.group([a, b])
        #expect(discs.count == 2)
    }

    // MARK: - What the library records about a disc

    @Test("A disc game's size is every file in its folder, not the boot file")
    func installedSizeCountsTheWholeGame() throws {
        // The first device run failed here, and the log line was the whole
        // diagnosis: `size=6822 expected=362586672`. The size had been recorded
        // from the data track while the path pointed at the .cue, so the launch
        // preflight compared a text file against a disc and called a perfectly
        // good game damaged.
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let roms = root.appendingPathComponent("ROMs", isDirectory: true)
        let game = roms.appendingPathComponent("Tomb Raider", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)

        let boot = try write("Tomb Raider.cue", in: game, bytes: 6822)
        try write("Tomb Raider (Track 01).bin", in: game, bytes: 100_000)
        try write("Tomb Raider (Track 02).bin", in: game, bytes: 50_000)

        #expect(DiscStorage.gameFolder(forROMAt: boot) == game)
        #expect(DiscStorage.installedSize(ofROMAt: boot) == 156_822,
                "the game is all three files, not the 6822 bytes of text")
    }

    @Test("A cartridge has no folder and keeps its own size")
    func cartridgeSizeIsUnchanged() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let roms = root.appendingPathComponent("ROMs", isDirectory: true)
        try FileManager.default.createDirectory(at: roms, withIntermediateDirectories: true)
        let cart = try write("Pokemon.gba", in: roms, bytes: 4096)

        #expect(DiscStorage.gameFolder(forROMAt: cart) == nil,
                "a cartridge sits in ROMs/ directly and is not a folder")
        #expect(DiscStorage.installedSize(ofROMAt: cart) == 4096)
    }

    // MARK: - Identity

    @Test("The identity file is the largest member, never the descriptor")
    func identityIsTheDataTrack() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Vagrant Story.bin", in: dir, bytes: 8192)
        let cueURL = try write("Vagrant Story.cue", in: dir, text: cue(["Vagrant Story.bin"]))

        let (_, discs, _) = DiscImportGrouper.group(
            [cueURL, dir.appendingPathComponent("Vagrant Story.bin")])

        // Hashing the .cue would give every game whose descriptor happens to
        // match the same identity, and the descriptor is a few hundred bytes.
        #expect(discs.first?.identityFile.pathExtension == "bin")
    }

    // MARK: - Descriptor parsing

    @Test("Both quoted and bare FILE lines are read")
    func cueSyntaxVariants() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let quoted = try write("a.cue", in: dir, text: "FILE \"track one.bin\" BINARY\n")
        let bare = try write("b.cue", in: dir, text: "FILE track.bin BINARY\n")

        #expect(DiscImportGrouper.readCueTracks(quoted) == ["track one.bin"])
        #expect(DiscImportGrouper.readCueTracks(bare) == ["track.bin"])
    }

    @Test("A playlist skips comments and blank lines")
    func playlistParsing() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m3u = try write("p.m3u", in: dir,
                            text: "# a comment\n\nDisc 1.cue\n   Disc 2.cue   \n\n")

        #expect(DiscImportGrouper.readPlaylist(m3u) == ["Disc 1.cue", "Disc 2.cue"])
    }
}
