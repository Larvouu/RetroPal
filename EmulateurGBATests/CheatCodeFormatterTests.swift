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

    // MARK: - Normalization

    @Test("Fullwidth digits from a CJK keyboard fold to ASCII before validation")
    func foldsFullwidth() {
        let typed = "９４０００１３０ ＦＣＦＦ００００"
        let folded = CheatCodeFormatter.normalized(typed)
        #expect(folded == "94000130 FCFF0000")
        #expect(CheatCodeFormatter.problem(in: folded, isNDS: true) == nil)
    }

    @Test("Invisible spaces and foreign line endings from a paste become plain ones")
    func foldsInvisibleJunk() {
        let pasted = "94000130\u{3000}FCFF0000\r\n62101D40\u{00A0}00000000\t"
        #expect(CheatCodeFormatter.normalized(pasted) == "94000130 FCFF0000\n62101D40 00000000 ")
    }

    @Test("Formatting folds fullwidth input as it is typed")
    func formatsFullwidth() {
        let out = CheatCodeFormatter.formatted("９４０００１３０ＦＣＦＦ００００", previous: "", isNDS: true)
        #expect(out == "94000130 FCFF0000")
    }

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

    // MARK: - Advisories

    // The advisory exists because a saved entry becomes its own cheat set in
    // the core, and a seed directive only ever serves lines stored beside it.
    // These tests pin the narrowness on purpose: the failure that would matter
    // is firing on ordinary codes until people stop reading it.

    @Test("A lone seed directive is called out")
    func flagsLoneSeedDirective() {
        #expect(CheatCodeFormatter.advisory(in: "DEADFACE 00000000", system: "gba") == .seedLineAlone)
    }

    @Test("The seed directive is recognised unformatted and in lower case")
    func flagsSeedDirectiveWhateverItsShape() {
        #expect(CheatCodeFormatter.advisory(in: "deadface00000000", system: "gba") == .seedLineAlone)
        #expect(CheatCodeFormatter.advisory(in: "  DEADFACE 1234ABCD  ", system: "gba") == .seedLineAlone)
    }

    @Test("A seed directive with its code beside it is exactly right, so it is silent")
    func staysSilentWhenTheCodeIsWhole() {
        let whole = "DEADFACE 00000000\n82003884 0001\n82003886 0002"
        #expect(CheatCodeFormatter.advisory(in: whole, system: "gba") == nil)
    }

    @Test("Blank lines around the code do not make it look lone")
    func ignoresBlankLines() {
        #expect(CheatCodeFormatter.advisory(in: "DEADFACE 00000000\n\n82003884 0001",
                                            system: "gba") == nil)
    }

    @Test("Ordinary codes never raise an advisory")
    func staysSilentOnOrdinaryCodes() {
        #expect(CheatCodeFormatter.advisory(in: "82003884 0001", system: "gba") == nil)
        #expect(CheatCodeFormatter.advisory(in: "", system: "gba") == nil)
        #expect(CheatCodeFormatter.advisory(in: "   \n ", system: "gba") == nil)
    }

    @Test("The directive is a GBA-family thing, so DS input is never flagged")
    func neverFlagsDS() {
        #expect(CheatCodeFormatter.advisory(in: "DEADFACE 00000000", system: "nds") == nil)
    }

    // MARK: - The 1.2.5 consoles

    /// NES cheats are written as Game Genie codes, whose alphabet is NOT hex:
    /// A P Z L G I T Y E O X U K S V N. SXIOPO is infinite lives in Super Mario
    /// Bros. and contains four characters the hex rule rejects, so without the
    /// console key the commonest NES cheat there is would be refused before the
    /// core ever saw it.
    @Test func nesGameGenieCodesAreAccepted() {
        #expect(CheatCodeFormatter.problem(in: "SXIOPO", isNDS: false, system: "nes") == nil)
        #expect(CheatCodeFormatter.problem(in: "GXNTLZEX", isNDS: false, system: "nes") == nil)
        #expect(CheatCodeFormatter.problem(in: "AEUZUGZA", isNDS: false, system: "nes") == nil)
    }

    /// The same letters on a console that does not use them stay an error, so
    /// the check keeps its precision everywhere else.
    @Test func gameGenieLettersStayInvalidOnOtherConsoles() {
        #expect(CheatCodeFormatter.problem(in: "SXIOPO", isNDS: false, system: "gba") == .invalidCharacter)
        #expect(CheatCodeFormatter.problem(in: "SXIOPO", isNDS: false) == .invalidCharacter)
    }

    /// SNES Game Genie needs no widening at all: its own alphabet
    /// (DF4709156BC8A23E) is a subset of hex, so the existing rule already
    /// passes a real code like DD82-64DC.
    @Test func snesGameGenieCodesPassTheHexRule() {
        #expect(CheatCodeFormatter.problem(in: "DD82-64DC", isNDS: false, system: "snes") == nil)
        #expect(CheatCodeFormatter.problem(in: "7E0DBE:63", isNDS: false, system: "snes") == .invalidCharacter)
    }
}
