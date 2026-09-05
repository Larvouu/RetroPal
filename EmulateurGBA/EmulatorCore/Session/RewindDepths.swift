//
//  RewindDepths.swift
//  EmulateurGBA
//
//  How far back the rewind button offers to go, and how far a plain tap goes.
//
//  Pulled out of `EmulatorViewController` so it can be tested: it lived there as
//  two private computed properties, which meant the only way to check that a
//  five-second pill rewinds five seconds was to hold a phone. The view
//  controller still owns the two INPUTS (the tier, and how long this sitting has
//  run); this owns the arithmetic on them.
//

import Foundation

enum RewindDepths {

    /// The depths the long-press row can offer, shortest first.
    ///
    /// FIVE-SECOND STEPS, one rule for all six consoles, and the rule is the
    /// coarsest core's granularity rather than a taste. mGBA keeps one entry per
    /// FRAME and MesenCE one per second, but melonDS and PCSX-ReARMed hold a
    /// snapshot every five seconds and round to the one at or before the point
    /// asked for. Offering "3 seconds" would be a promise two consoles cannot
    /// keep, and a button that jumps back five when it says three is worse than
    /// one that only offers what it can do.
    static let steps: [Int] = [5, 10, 15, 20, 30]

    /// The depths to offer, filtered by the tier's ceiling AND by how long the
    /// sitting has actually run, so the row never lists a depth the ring cannot
    /// serve.
    ///
    /// The `- 1` is the same one the tap has always used: the buffer holds the
    /// frames that have been played, and asking for every single one of them
    /// leaves the restore with nothing to land on.
    ///
    /// A free player's five seconds is their whole allowance, so this returns at
    /// most one depth for them and the caller shows no row at all. That is the
    /// gate, and it is here rather than in the view so it can be tested.
    static func available(maxSeconds: Int, playedSeconds: Int) -> [Int] {
        let cap = min(maxSeconds, max(0, playedSeconds - 1))
        return steps.filter { $0 <= cap }
    }

    /// What a plain TAP rewinds: as far back as this tier allows, which is what
    /// the button's own title says. Unchanged since it shipped, and deliberately
    /// not routed through `available` — the tap is not one of the steps, it is
    /// "everything you have", which after twelve seconds of play is eleven.
    static func tapSeconds(maxSeconds: Int, playedSeconds: Int) -> Int {
        min(maxSeconds, max(1, playedSeconds - 1))
    }

    /// What a chosen depth actually asks for. The pill is clamped the same way
    /// the tap is, because the row was built from a reading taken when the
    /// overlay opened and a player can sit in it.
    static func chosenSeconds(_ seconds: Int, maxSeconds: Int, playedSeconds: Int) -> Int {
        min(seconds, tapSeconds(maxSeconds: maxSeconds, playedSeconds: playedSeconds))
    }
}
