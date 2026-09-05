//
//  ShareCardConsoleTests.swift
//  EmulateurGBATests
//
//  One question, asked in two places: does this console have a card shaped like
//  the machine, or does it get the branded one?
//
//  The mapping from a console to its share-card chrome has been copied three
//  times in this feature and the copies drifted every time. The Super Nintendo's
//  clip preview wore a Game Boy after the exporter had been fixed, because
//  fixing one copy is indistinguishable from fixing the bug. The PlayStation
//  then found the next one: it has no dress yet, so the mapping correctly
//  answered "no card", and the clip preview papered over that nil with another
//  console's layout and drew a screen floating on nothing.
//
//  So the mapping is now one function with a cheap companion that answers the
//  same question without rendering, and this file is what keeps the two honest.
//  It is not a test of how a card looks; it is a test that two answers agree.
//

import Testing
import Foundation
import UIKit
@testable import EmulateurGBA

@MainActor
struct ShareCardConsoleTests {

    /// `hasConsoleCard` must agree with `consoleCard`, for every console.
    ///
    /// The cheap one exists so the clip card's live preview can choose which of
    /// two cards to build without building both, and a predicate that disagrees
    /// with the thing it predicts is worse than no predicate: it would send the
    /// preview down the console path for a console that has no console to draw,
    /// which is the exact bug this pair was introduced to end.
    ///
    /// `PresetSystem.allCases` rather than a hand-written list, so a seventh
    /// console is covered by this test the day its case is added and not the day
    /// someone remembers to come back here.
    @Test func consoleCardAvailabilityMatchesTheCards() {
        let info = ScreenshotCardRenderer.GameInfo(name: "Test", playTimeSeconds: 3600, isPro: false)
        for system in PresetSystem.allCases {
            let card = ScreenshotCardRenderer.consoleCard(
                system: system, gameFrame: nil, gameAspect: 4.0 / 3.0,
                info: info, variant: .nostalgia)
            // Comment(rawValue:) rather than a bare string: `#expect`'s second
            // parameter is a `Comment?`, which a string LITERAL converts to and
            // a built String does not. This message is assembled, so it has to
            // be wrapped. Same reason for every wrap below.
            let says = ScreenshotCardRenderer.hasConsoleCard(system)
            let got = card == nil ? "returned nil" : "returned a card"
            #expect(says == (card != nil),
                    Comment(rawValue: "\(system.rawValue): hasConsoleCard says \(says) "
                                      + "but consoleCard \(got)"))
        }
    }

    /// A console that HAS a card must return both halves of it. The chrome and
    /// the layout are a pair: a layout with no chrome is the headless card the
    /// clip preview used to draw, and chrome with someone else's layout puts the
    /// picture outside the machine's screen.
    @Test func aConsoleCardCarriesBothItsHalves() {
        let info = ScreenshotCardRenderer.GameInfo(name: "Test", playTimeSeconds: 60, isPro: false)
        for system in PresetSystem.allCases where ScreenshotCardRenderer.hasConsoleCard(system) {
            guard let pair = ScreenshotCardRenderer.consoleCard(
                system: system, gameFrame: nil, gameAspect: 4.0 / 3.0,
                info: info, variant: .nostalgia) else {
                Issue.record(Comment(rawValue: "\(system.rawValue): claims a console card and returned nil"))
                continue
            }
            #expect(pair.image != nil,
                    Comment(rawValue: "\(system.rawValue): a console card with no chrome"))
            #expect(pair.layout.screen.width > 0 && pair.layout.screen.height > 0,
                    Comment(rawValue: "\(system.rawValue): a console card with an empty screen rect"))
        }
    }
}
