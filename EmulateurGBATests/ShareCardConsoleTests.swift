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

    /// The three cards drawn 2026-10-11 (Master System, Game Gear, PSP): every
    /// control the card shows inside the card and off the picture, none on
    /// another (drawn shapes, as the Nintendo 64's card test measures them),
    /// and, on the PSP, a column left for the game's name.
    @Test(arguments: [PresetSystem.sms, .gg, .psp])
    func theNewCardsHoldTheirControlsClearOfThePictureAndEachOther(system: PresetSystem) {
        let side: CGFloat = 1080
        let aspect = PresetLayoutResolver.displayAspect(system)
        let gameSize = CGSize(width: aspect, height: 1)
        let layout: GBCardLayout
        switch system {
        case .sms: layout = GBCardLayout.sms(side: side, gameNativeSize: gameSize)
        case .gg: layout = GBCardLayout.gg(side: side, gameNativeSize: gameSize)
        default: layout = GBCardLayout.psp(side: side, gameNativeSize: gameSize)
        }
        // The PSP's picture is the SIZE the achievement card composes its
        // screen at, so the two agree pixel for pixel (it sits lower).
        if system == .psp {
            #expect(layout.screen.size == ScreenshotCardRenderer.standardGameScreenRect(
                side: side, gameNativeSize: gameSize).size)
        }
        let k = layout.deviceScale
        var rects: [ControlElement: CGRect] = [:]
        for e in ControlElement.elements(for: system) where e != .btnMenu && e != .btnClip {
            // The two controls a photograph of the PSP shows elsewhere: none.
            guard let b = layout.buttons[e.rawValue], !b.isHidden else {
                Issue.record(Comment(rawValue: "\(system.rawValue): \(e.rawValue) is not on the card"))
                continue
            }
            let s = EmulatorLayoutGeometry.buttonSize(e, system: system, isLandscape: false, deviceScale: k)
            rects[e] = CGRect(x: b.centerX * side - s.width / 2, y: b.centerY * side - s.height / 2,
                              width: s.width, height: s.height)
        }
        let card = CGRect(x: 0, y: 0, width: side, height: side)
        for (e, r) in rects {
            #expect(card.contains(r), Comment(rawValue: "\(system.rawValue): \(e.rawValue) leaves the card"))
            let covered = r.intersection(layout.screen)
            #expect(covered.isNull || covered.width < 0.5 || covered.height < 0.5,
                    Comment(rawValue: "\(system.rawValue): \(e.rawValue) is on the picture"))
        }
        let elements = Array(rects.keys)
        for i in elements.indices {
            for j in elements.indices where j > i {
                let depth = ButtonShape.penetration(ButtonShape.of(elements[i], rects[elements[i]]!, system: system),
                                                    ButtonShape.of(elements[j], rects[elements[j]]!, system: system))
                #expect(depth < 0.5, Comment(rawValue: "\(system.rawValue): \(elements[i].rawValue) "
                                                       + "overlaps \(elements[j].rawValue)"))
            }
        }
        if system == .psp {
            #expect((GBCardLayout.pspInfoColumnWidth(layout, side: side) ?? 0) > 300)
        }
    }

    /// The Master System's plates (130 % of a button) stay inside the card:
    /// on the NES card's picture-edge columns they reached its edge.
    @Test func theMasterSystemPlatesStayOnTheCard() {
        let side: CGFloat = 1080
        let layout = GBCardLayout.sms(side: side, gameNativeSize: CGSize(width: 256.0 / 192.0, height: 1))
        let face = EmulatorLayoutGeometry.buttonSize(.btnA, system: .sms, isLandscape: false,
                                                     deviceScale: layout.deviceScale).width
        let plate = face * ControlLayoutDefaults.smsPlateScale
        guard let a = layout.buttons[ControlElement.btnA.rawValue] else {
            Issue.record("2 is not on the card"); return
        }
        #expect(a.centerX * side + plate / 2 < side - 24)
    }

    /// A share card asks the library which console a game is before it reads
    /// the extension: a PSP game and a PlayStation disc share `.iso`.
    @Test func aShareCardAsksTheLibraryForAGamesConsole() {
        // Not in the library: the extension answers.
        #expect(PresetSystem.forRomFilename("no-such-game-\(UUID().uuidString).sms") == .sms)
        #expect(PresetSystem.forRomFilename("no-such-game-\(UUID().uuidString).gg") == .gg)
        #expect(PresetSystem.forRomFilename("no-such-game-\(UUID().uuidString).cso") == .psp)
        #expect(PresetSystem.forRomFilename("no-such-game-\(UUID().uuidString).iso") == .ps1)
    }
}
