//
//  ControllerNavigatorTests.swift
//  EmulateurGBATests
//
//  Moving around the app with a controller (1.3.3): the one pure piece of
//  `ControllerNavigator`, the choice of the next control in a direction, on
//  hand-built frames. The rest (probes, the ring, reachability) needs a live
//  window and is checked on device.
//

import Testing
import CoreGraphics
@testable import EmulateurGBA

@Suite("Controller navigation")
struct ControllerNavigatorTests {

    private func rows(_ count: Int, x: CGFloat = 16, width: CGFloat = 360,
                      height: CGFloat = 44, top: CGFloat = 100) -> [(Int, CGRect)] {
        (0..<count).map { ($0, CGRect(x: x, y: top + CGFloat($0) * (height + 1), width: width, height: height)) }
    }

    @Test
    func down_takesTheNextRow() {
        let list = rows(4)
        let from = list[1].1
        #expect(ControllerNavigator.nearest(from: from, direction: .down, among: list) == 2)
        #expect(ControllerNavigator.nearest(from: from, direction: .up, among: list) == 0)
    }

    @Test
    func nothingThatWay_isNil() {
        let list = rows(3)
        #expect(ControllerNavigator.nearest(from: list[2].1, direction: .down, among: list) == nil)
        #expect(ControllerNavigator.nearest(from: list[0].1, direction: .up, among: list) == nil)
        #expect(ControllerNavigator.nearest(from: list[0].1, direction: .left, among: list) == nil)
    }

    /// Play and (i) side by side, a card row below: right from Play is (i),
    /// not the card, even though the card is nearer to Play's centre.
    @Test
    func right_staysInItsLane() {
        let play = CGRect(x: 20, y: 300, width: 120, height: 44)
        let info = CGRect(x: 152, y: 300, width: 44, height: 44)
        let card = CGRect(x: 60, y: 356, width: 300, height: 60)
        let candidates: [(String, CGRect)] = [("info", info), ("card", card)]
        #expect(ControllerNavigator.nearest(from: play, direction: .right, among: candidates) == "info")
        #expect(ControllerNavigator.nearest(from: play, direction: .down, among: candidates) == "card")
    }

    /// From a bar button at the top right, down lands on the first row of the
    /// list under the bar, whose width covers the button's lane.
    @Test
    func down_fromTheBar_landsOnTheFirstRow() {
        let plus = CGRect(x: 340, y: 50, width: 32, height: 32)
        let list = rows(3)
        #expect(ControllerNavigator.nearest(from: plus, direction: .down, among: list) == 0)
    }

    /// Of two controls equally far down, the one straight ahead wins.
    @Test
    func tieBreak_prefersStraightAhead() {
        let from = CGRect(x: 100, y: 100, width: 40, height: 40)
        let ahead = CGRect(x: 90, y: 200, width: 60, height: 40)
        let aside = CGRect(x: 60, y: 200, width: 60, height: 40)
        let candidates: [(String, CGRect)] = [("aside", aside), ("ahead", ahead)]
        #expect(ControllerNavigator.nearest(from: from, direction: .down, among: candidates) == "ahead")
    }
}
