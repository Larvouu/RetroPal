//
//  RewindDepthsTests.swift
//  EmulateurGBATests
//
//  What the rewind button offers, and what each way of pressing it asks for.
//
//  These exist because the question "does the five-second pill rewind five
//  seconds" could only be answered by holding a phone: the arithmetic lived in
//  two private computed properties on a view controller. It is now in
//  `RewindDepths`, and this is the answer written down.
//

import Testing
@testable import EmulateurGBA

@Suite("RewindDepths")
struct RewindDepthsTests {

    private let free = 5
    private let pro = 30

    /// The whole row, once the sitting is long enough to serve all of it.
    @Test func aProPlayerIsOfferedEveryStep() {
        #expect(RewindDepths.available(maxSeconds: pro, playedSeconds: 40) == [5, 10, 15, 20, 30])
        #expect(RewindDepths.available(maxSeconds: pro, playedSeconds: 400) == [5, 10, 15, 20, 30])
    }

    /// ⚠ THE FREE TIER GETS NO ROW, and this is the assertion that says so. Five
    /// seconds is the whole allowance, so there is at most ONE depth, and the
    /// overlay shows no row for fewer than two. A press that opens a list of one
    /// is worse than a press that does nothing.
    @Test func aFreePlayerNeverGetsAChoice() {
        for played in [0, 1, 6, 30, 600] {
            #expect(RewindDepths.available(maxSeconds: free, playedSeconds: played).count <= 1,
                    "free tier offered a choice at \(played)s played")
        }
        // And the one it can name is its own ceiling, never something longer.
        #expect(RewindDepths.available(maxSeconds: free, playedSeconds: 600) == [5])
    }

    /// Nothing is offered that the ring cannot serve. Ten seconds in, a Pro
    /// player is offered five and ten and that is the whole row.
    @Test func theRowNeverOutrunsTheSitting() {
        #expect(RewindDepths.available(maxSeconds: pro, playedSeconds: 0).isEmpty)
        #expect(RewindDepths.available(maxSeconds: pro, playedSeconds: 5) == [])
        #expect(RewindDepths.available(maxSeconds: pro, playedSeconds: 6) == [5])
        #expect(RewindDepths.available(maxSeconds: pro, playedSeconds: 12) == [5, 10])
        #expect(RewindDepths.available(maxSeconds: pro, playedSeconds: 21) == [5, 10, 15, 20])
    }

    /// A chosen depth asks for exactly itself. This is the one the device test
    /// is checking by eye: five rewinds five, ten rewinds ten.
    @Test func aChosenDepthAsksForExactlyThatMany() {
        for seconds in RewindDepths.steps {
            #expect(RewindDepths.chosenSeconds(seconds, maxSeconds: pro, playedSeconds: 120) == seconds,
                    "the \(seconds)s pill asked for something else")
        }
    }

    /// Except where the sitting is shorter than the pill, which can only happen
    /// if the player sat in the pause menu after the row was built. Then it asks
    /// for everything there is, and never for more.
    @Test func aChosenDepthIsStillClampedToWhatWasPlayed() {
        #expect(RewindDepths.chosenSeconds(30, maxSeconds: pro, playedSeconds: 12) == 11)
        #expect(RewindDepths.chosenSeconds(30, maxSeconds: free, playedSeconds: 600) == 5)
    }

    /// The tap goes as far as the button says: five seconds free, ten Pro
    /// (2026-10-11); the long press still reaches the Pro thirty.
    @Test func theTapGoesAsFarAsTheTierAllows() {
        #expect(RewindDepths.tapCap(isPro: true) == 10 && RewindDepths.tapCap(isPro: false) == 5)
        // The call the screen makes.
        #expect(RewindDepths.tapSeconds(isPro: true, playedSeconds: 120) == 10)
        #expect(RewindDepths.tapSeconds(isPro: false, playedSeconds: 120) == 5)
        #expect(RewindDepths.tapSeconds(isPro: true, playedSeconds: 8) == 7)
        #expect(RewindDepths.ceiling(isPro: true) == 30 && RewindDepths.ceiling(isPro: false) == 5)
        #expect(RewindDepths.tapSeconds(maxSeconds: RewindDepths.tapCap(isPro: true), playedSeconds: 120) == 10)
        #expect(RewindDepths.tapSeconds(maxSeconds: RewindDepths.tapCap(isPro: false), playedSeconds: 120) == 5)
        #expect(RewindDepths.available(maxSeconds: RewindDepths.ceiling(isPro: true), playedSeconds: 120).last == 30)
        #expect(RewindDepths.tapSeconds(maxSeconds: pro, playedSeconds: 120) == 30)
        #expect(RewindDepths.tapSeconds(maxSeconds: free, playedSeconds: 120) == 5)
        // Early in a sitting it is everything played, minus the frame the
        // restore has to land on.
        #expect(RewindDepths.tapSeconds(maxSeconds: pro, playedSeconds: 12) == 11)
        // And never zero or negative, however early it is asked.
        #expect(RewindDepths.tapSeconds(maxSeconds: pro, playedSeconds: 0) == 1)
    }

    /// The steps are five-second multiples because two of the six cores hold one
    /// snapshot every five seconds and round to the one at or before the point
    /// asked for. A step that is not a multiple of five would be a number the
    /// PlayStation and the DS cannot honour.
    @Test func everyStepIsSomethingEveryConsoleCanHonour() {
        for seconds in RewindDepths.steps {
            #expect(seconds % 5 == 0, "\(seconds)s is not a whole number of snapshots")
        }
        #expect(RewindDepths.steps.max() == 30, "the deepest step must match the Pro ceiling")
    }

    /// A 50 Hz second credits the rewind a whole second, as a 60 Hz one does:
    /// the ring is asked in sixtieths of a second, whatever the console's rate.
    @Test func aPALSecondCreditsAWholeSecond() {
        var pal = 0.0
        for _ in 0..<50 { pal += EmulatorSession.rewindCredit(perFrameAt: 50) }
        #expect(abs(pal - 60) < 0.001, "fifty PAL frames did not credit one second of rewind")
        var ntsc = 0.0
        for _ in 0..<60 { ntsc += EmulatorSession.rewindCredit(perFrameAt: 60) }
        #expect(abs(ntsc - 60) < 0.001, "sixty NTSC frames did not credit one second of rewind")
        #expect(EmulatorSession.rewindCredit(perFrameAt: 0) == 1, "an unknown rate did not fall back to one frame")
    }
}
