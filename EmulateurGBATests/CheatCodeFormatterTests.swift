//
//  CheatCodeFormatterTests.swift
//  EmulateurGBATests
//
//  Locks the two promises the cheat field makes:
//   - formatting only ever fires on an append, so the caret cannot jump while
//     someone edits the middle of a code;
//   - the shape check stays CONSERVATIVE. Reporting a problem for a code the
//     core would have accepted is a regression, so anything ambiguous must
//     come back nil and be left to the core.
//

import Testing
@testable import EmulateurGBA

@Suite("CheatCodeFormatter")
struct CheatCodeFormatterTests {

    // MARK: - Formatting

    @Test("A pasted 16-digit run is split into two blocks")
    func splitsSixteen() {
        let out = CheatCodeFormatter.formatted("94000130FCFF0000", previous: "", isNDS: true)
        #expect(out == "94000130 FCFF0000")
    }

    @Test("A GBA CodeBreaker run of 12 splits 8 then 4")
    func splitsTwelveOnGBA() {
        let out = CheatCodeFormatter.formatted("820038840001", previous: "", isNDS: false)
        #expect(out == "82003884 0001")
    }

    @Test("Twelve digits are left alone on DS, where that length means nothing")
    func leavesTwelveOnNDS() {
        let out = CheatCodeFormatter.formatted("820038840001", previous: "", isNDS: true)
        #expect(out == "820038840001")
    }

    @Test("Lowercase input is uppercased")
    func uppercases() {
        let out = CheatCodeFormatter.formatted("94000130fcff0000", previous: "", isNDS: true)
        #expect(out == "94000130 FCFF0000")
    }

    @Test("An unusual length is never reshaped")
    func leavesUnknownLengths() {
        let out = CheatCodeFormatter.formatted("ABCDEF", previous: "", isNDS: false)
        #expect(out == "ABCDEF")
    }

    @Test("A mid-string edit is left untouched, so the caret cannot jump")
    func ignoresMidStringEdits() {
        // Shorter than before: a deletion, not an append.
        let out = CheatCodeFormatter.formatted("9400013", previous: "94000130", isNDS: true)
        #expect(out == "9400013")
    }

    @Test("An edit that is not a pure append is left untouched")
    func ignoresNonAppend() {
        let out = CheatCodeFormatter.formatted("X94000130FCFF0000", previous: "94000130", isNDS: true)
        #expect(out == "X94000130FCFF0000")
    }

    @Test("Each line is grouped on its own")
    func groupsPerLine() {
        let out = CheatCodeFormatter.formatted("94000130FCFF0000\n62101D4000000000",
                                               previous: "", isNDS: true)
        #expect(out == "94000130 FCFF0000\n62101D40 00000000")
    }

    // MARK: - Validation

    @Test("A letter outside hex is named")
    func namesInvalidCharacter() {
        #expect(CheatCodeFormatter.problem(in: "9400Z130 FCFF0000", isNDS: true) == .invalidCharacter)
    }

    @Test("Game Genie dashes are allowed, not flagged")
    func allowsGameGenieDashes() {
        #expect(CheatCodeFormatter.problem(in: "00A-17B-C49", isNDS: false) == nil)
    }

    @Test("A DS line with a single block is named as unpaired")
    func namesUnpairedDSLine() {
        #expect(CheatCodeFormatter.problem(in: "94000130", isNDS: true) == .unpairedLine)
    }

    @Test("A well-formed DS pair passes to the core")
    func acceptsDSPair() {
        #expect(CheatCodeFormatter.problem(in: "94000130 FCFF0000", isNDS: true) == nil)
    }

    @Test("Blank lines between DS pairs are tolerated")
    func toleratesBlankLines() {
        #expect(CheatCodeFormatter.problem(in: "94000130 FCFF0000\n\n62101D40 00000000",
                                           isNDS: true) == nil)
    }

    @Test("GBA block lengths are never judged here, only by the core")
    func leavesGBABlocksToTheCore() {
        // Both are shapes we deliberately do not model.
        #expect(CheatCodeFormatter.problem(in: "82003884 0001", isNDS: false) == nil)
        #expect(CheatCodeFormatter.problem(in: "1234", isNDS: false) == nil)
    }

    @Test("An empty field is not a problem")
    func emptyIsNotAProblem() {
        #expect(CheatCodeFormatter.problem(in: "   \n ", isNDS: true) == nil)
    }
}
