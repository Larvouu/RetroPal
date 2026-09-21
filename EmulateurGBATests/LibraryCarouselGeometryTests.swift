//
//  LibraryCarouselGeometryTests.swift
//  EmulateurGBATests
//
//  The notches of the landscape library, written down.
//
//  The line of covers must stop on a game, never between two, and a flick
//  must carry a few games and no further. Those two sentences are the whole
//  feel of the surface, and they live in `LibraryCarouselGeometry`, a value
//  with no view in it, so they can be pinned here without a phone. The rack
//  shape (where a cover stands, how far it turns, how big it is) is pinned
//  beside them.
//

import Testing
import CoreGraphics
@testable import EmulateurGBA

@Suite("LibraryCarouselGeometry")
struct LibraryCarouselGeometryTests {

    /// Ten tiles of 180 points: one notch every 171 points of finger travel,
    /// stacked covers 72 points apart.
    private let line = LibraryCarouselGeometry(itemSide: 180, count: 10)

    private func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }

    @Test func eachIndexHasItsOwnNotch() {
        #expect(close(line.stride, 171))
        #expect(close(line.stackStride, 72))
        #expect(line.offset(forIndex: 0) == 0)
        #expect(close(line.offset(forIndex: 1), -171))
        #expect(close(line.offset(forIndex: 9), -1539))
        #expect(close(line.minOffset, -1539))
        #expect(line.maxOffset == 0)
    }

    @Test func offsetsOutsideTheLineClampToItsEnds() {
        #expect(line.offset(forIndex: -3) == 0)
        #expect(close(line.offset(forIndex: 40), -1539))
        #expect(line.clamp(-1) == 0)
        #expect(line.clamp(10) == 9)
    }

    /// The tile under the centre follows the finger and rounds at the half-way
    /// point, which is where the haptic tick fires during a drag.
    @Test func theNearestNotchRoundsAtHalfAStride() {
        #expect(close(line.progress(forOffset: -256.5), 1.5))
        #expect(line.nearestIndex(forOffset: 0) == 0)
        #expect(line.nearestIndex(forOffset: -85) == 0)
        #expect(line.nearestIndex(forOffset: -86) == 1)
        #expect(line.nearestIndex(forOffset: -288) == 2)
        #expect(line.nearestIndex(forOffset: 300) == 0)
        #expect(line.nearestIndex(forOffset: -5000) == 9)
    }

    /// A slow release lands on the tile under the finger.
    @Test func aSlowReleaseStaysOnTheTileUnderTheFinger() {
        #expect(line.targetIndex(releasedAt: -180, projectedOffset: -190) == 1)
        #expect(line.targetIndex(releasedAt: -270, projectedOffset: -280) == 2)
    }

    /// A flick carries to where the drag would have stopped, snapped.
    @Test func aFlickCarriesToTheProjectedNotch() {
        #expect(line.targetIndex(releasedAt: -40, projectedOffset: -300) == 2)
        #expect(line.targetIndex(releasedAt: -720, projectedOffset: -500) == 3)
    }

    /// ...but never more than three tiles past the one it left, so a hard
    /// flick steps through the library instead of throwing it to its end.
    @Test func aHardFlickIsCappedAtThreeTiles() {
        #expect(line.targetIndex(releasedAt: 0, projectedOffset: -4000) == 3)
        #expect(line.targetIndex(releasedAt: -1539, projectedOffset: 3000) == 6)
        #expect(line.targetIndex(releasedAt: 0, projectedOffset: -4000, maxFlingItems: 1) == 1)
    }

    @Test func aFlickPastEitherEndStopsAtTheEnd() {
        #expect(line.targetIndex(releasedAt: -1200, projectedOffset: -1900) == 9)
        #expect(line.targetIndex(releasedAt: -70, projectedOffset: 900) == 0)
    }

    /// Pulling past an end moves the line a third as far as the finger, and a
    /// pull that stays inside the line is passed through untouched.
    @Test func pullingPastAnEndIsDamped() {
        #expect(line.rubberBandedTranslation(-50, base: -288) == -50)
        #expect(close(line.rubberBandedTranslation(100, base: 0), 35))
        #expect(close(line.rubberBandedTranslation(-100, base: -1539), -35))
        // Starting one notch in and pulling 300 past the start: 171 free, then a third of the rest.
        #expect(close(line.rubberBandedTranslation(300, base: -171), 171 + 129 * 0.35))
    }

    /// The rack: the centred cover at 0, its neighbours one stride out, then
    /// one stack stride per cover, mirrored on the left.
    @Test func coversStandOneStrideThenOneStackStrideApart() {
        #expect(line.x(forDistance: 0) == 0)
        #expect(close(line.x(forDistance: 0.5), 85.5))
        #expect(close(line.x(forDistance: 1), 171))
        #expect(close(line.x(forDistance: -1), -171))
        #expect(close(line.x(forDistance: 2), 243))
        #expect(close(line.x(forDistance: -3), -315))
    }

    /// A cover turns progressively over the first notch and no further, and
    /// the two sides turn opposite ways. The sign of the angle itself is the
    /// constant's, settled on the device.
    @Test func coversTurnTowardsTheCentreAndNoFurtherThanTheStackAngle() {
        #expect(line.angle(forDistance: 0) == 0)
        #expect(close(CGFloat(line.angle(forDistance: 0.5)), CGFloat(LibraryCarouselGeometry.stackAngle / 2)))
        #expect(line.angle(forDistance: 1) == LibraryCarouselGeometry.stackAngle)
        #expect(line.angle(forDistance: 3) == LibraryCarouselGeometry.stackAngle)
        #expect(line.angle(forDistance: -2) == -LibraryCarouselGeometry.stackAngle)
    }

    /// Only the centred cover grows, and it shrinks back over the first notch.
    @Test func onlyTheCentredCoverGrows() {
        #expect(close(line.scale(forDistance: 0), LibraryCarouselGeometry.selectedScale))
        #expect(close(line.scale(forDistance: 0.5), 1 + (LibraryCarouselGeometry.selectedScale - 1) / 2))
        #expect(close(line.scale(forDistance: 1), 1))
        #expect(close(line.scale(forDistance: -4), 1))
    }

    /// An empty line never indexes anything.
    @Test func anEmptyLineAnswersZeroEverywhere() {
        let empty = LibraryCarouselGeometry(itemSide: 180, count: 0)
        #expect(empty.offset(forIndex: 4) == 0)
        #expect(empty.nearestIndex(forOffset: -900) == 0)
        #expect(empty.targetIndex(releasedAt: -900, projectedOffset: -2000) == 0)
        #expect(empty.minOffset == 0)
    }

    /// Covers far from the centre are not drawn; the window is counted in
    /// stacked covers from the first neighbour to the screen's edge, plus two.
    @Test func theDrawnWindowCoversTheScreenPlusMargin() {
        // (667 / 2 - 171) / 72 = 2.26, rounded up to 3, plus 2.
        #expect(line.visibleRadius(forWidth: 667) == 5)
        // (956 / 2 - 171) / 72 = 4.26, rounded up to 5, plus 2.
        #expect(line.visibleRadius(forWidth: 956) == 7)
    }

    /// The tile side leaves room for the chrome and grows with the phone,
    /// within the two bounds that keep a cover a cover.
    @Test func theTileSideFollowsTheScreenHeightWithinBounds() {
        let se = LibraryLandscapeView.tileSide(forHeight: 375)
        let proMax = LibraryLandscapeView.tileSide(forHeight: 440)
        #expect(se > 120 && se < 135)
        #expect(close(proMax, 148.5))
        #expect(close(LibraryLandscapeView.tileSide(forHeight: 200), 90))
    }
}
