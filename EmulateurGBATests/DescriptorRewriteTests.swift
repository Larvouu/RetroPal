import Testing
import Foundation
@testable import EmulateurGBA

/// A disc descriptor names its files exactly as stored (audit 2026-10-27): the core opens
/// each reference by its bytes on a case-sensitive volume and skips one it cannot open.
struct DescriptorRewriteTests {
    @Test func caseMismatchIsRewrittenToTheStoredName() {
        let cue = "FILE \"GAME.BIN\" BINARY\r\n  TRACK 01 MODE2/2352\r\n    INDEX 01 00:00:00\r\n"
        let out = DiscImportGrouper.descriptorPointingAt(storedNames: ["Game.cue", "Game.bin"], text: cue, ext: "cue")
        #expect(out == "FILE \"Game.bin\" BINARY\r\n  TRACK 01 MODE2/2352\r\n    INDEX 01 00:00:00\r\n")
    }
    @Test func aWindowsPathIsGroupedAndRewritten() {
        let cue = "FILE \"D:\\rips\\Game (Track 1).bin\" BINARY\n  TRACK 01 MODE2/2352\nFILE \"D:\\rips\\Game (Track 2).bin\" BINARY\n  TRACK 02 AUDIO\n"
        let names = ["Game.cue", "Game (Track 1).bin", "Game (Track 2).bin"]
        let g = DiscImportGrouper.groupNames(names, descriptorText: { _ in cue })
        #expect(g.gaps.isEmpty, "gaps: \(g.gaps)")
        #expect(g.discs.count == 1 && Set(g.discs[0].members) == Set(names), "\(g.discs)")
        let out = DiscImportGrouper.descriptorPointingAt(storedNames: names, text: cue, ext: "cue")
        #expect(out == "FILE \"Game (Track 1).bin\" BINARY\n  TRACK 01 MODE2/2352\nFILE \"Game (Track 2).bin\" BINARY\n  TRACK 02 AUDIO\n")
    }
    @Test func anExactDescriptorIsLeftAlone() {
        let cue = "FILE \"Game.bin\" BINARY\n  TRACK 01 MODE2/2352\n"
        #expect(DiscImportGrouper.descriptorPointingAt(storedNames: ["Game.bin"], text: cue, ext: "cue") == nil)
    }
    @Test func aBareTokenAndATabAreHandled() {
        let cue = "FILE\tgame.bin BINARY\n"
        #expect(DiscImportGrouper.descriptorPointingAt(storedNames: ["Game.bin"], text: cue, ext: "cue") == "FILE\tGame.bin BINARY\n")
    }
    @Test func aBOMIsStrippedBeforeGrouping() {
        var bytes = Data([0xEF, 0xBB, 0xBF]); bytes.append(Data("FILE \"Game.bin\" BINARY\n".utf8))
        let text = DiscImportGrouper.decode(bytes)
        #expect(DiscImportGrouper.cueTracks(text) == ["Game.bin"])
    }
    @Test func aJapaneseNameKeepsItsCharacters() {
        // 表 is 0x95 0x5C in Shift-JIS: the trail byte is a backslash in ASCII.
        let name = "実況パワフルプロ野球99 表.bin"
        let sjis = ("FILE \"" + name.uppercased() + "\" BINARY\n").data(using: .shiftJIS)!
        // A Japanese phone, the one this cue comes from: legacy bytes are read in
        // the PHONE's codepage first, so on a French device they read as CP850 by
        // design (the ZIP tests' "same Japanese zip on a French phone" case).
        let text = LegacyTextEncoding.$preferredLanguagesOverride.withValue(["ja-JP"]) {
            DiscImportGrouper.decode(sjis)!
        }
        #expect(DiscImportGrouper.cueTracks(text) == [name.uppercased()])
        #expect(DiscImportGrouper.bareName(name) == name)
        let wrong = text.replacingOccurrences(of: ".bin", with: ".BIN")
        #expect(DiscImportGrouper.descriptorPointingAt(storedNames: [name], text: wrong, ext: "cue") == "FILE \"\(name)\" BINARY\n")
    }
    @Test func tocAndM3uReferencesAreRewritten() {
        let toc = "CD_ROM\nTRACK MODE2_RAW\nDATAFILE \"TRACK01.BIN\" 0\nTRACK AUDIO\nFILE \"Track02.BIN\" 0 03:00:00\n"
        #expect(DiscImportGrouper.descriptorPointingAt(storedNames: ["track01.bin", "track02.bin"], text: toc, ext: "toc")
                == "CD_ROM\nTRACK MODE2_RAW\nDATAFILE \"track01.bin\" 0\nTRACK AUDIO\nFILE \"track02.bin\" 0 03:00:00\n")
        let m3u = "# discs\nGAME (DISC 1).CUE\nGame (Disc 2).cue\n"
        #expect(DiscImportGrouper.descriptorPointingAt(storedNames: ["Game (Disc 1).cue", "Game (Disc 2).cue"], text: m3u, ext: "m3u")
                == "# discs\nGame (Disc 1).cue\nGame (Disc 2).cue\n")
    }
    @Test func anUnknownReferenceIsLeftAsItIs() {
        let cue = "FILE \"Other.bin\" BINARY\n"
        #expect(DiscImportGrouper.descriptorPointingAt(storedNames: ["Game.bin"], text: cue, ext: "cue") == nil)
    }
}
