//
//  VideoFilterPreviewTests.swift
//  EmulateurGBATests
//
//  The display filters away from the live screen: the Appearance sheet's
//  preview and the share cards, which both render through
//  `VideoFilterRenderer.apply`. Two defects lived there, reported on the
//  PlayStation and the Nintendo 64 (2026-10-01):
//
//   1. The offscreen pass sent the shader a 16-byte uniform struct after the
//      shader's had grown to 24 (`uvScale`, added for the PlayStation's CRT).
//      The CRT divides by that field, so offscreen it read past the end of
//      what was bound: black or warped, on every console.
//   2. The PlayStation and N64 stills come out of their bridges stretched to
//      4:3, and the preview was filtered on that stretched image at a fixed
//      800 px. The grid filters fade out under two or three display pixels per
//      game pixel, so a 320- or 640-wide picture got no scanlines at all.
//
//  These run the REAL shader on the device or simulator running the suite, so
//  they are what proves the fix: nothing here can be checked without Metal.
//

import Testing
import CoreGraphics
import Metal
import UIKit
@testable import EmulateurGBA

struct VideoFilterPreviewTests {

    // MARK: - Helpers

    /// A flat mid-grey picture: every difference a filter makes is the filter's.
    private static func flatImage(width: Int, height: Int, grey: UInt8 = 160) -> CGImage? {
        var bytes = [UInt8](repeating: grey, count: width * height * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }

    /// RGBA bytes of `image`, row 0 at the top.
    private static func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// Mean green of each output row: the scanline pattern, top to bottom.
    private static func rowMeans(_ image: CGImage) -> [Double] {
        let w = image.width, h = image.height
        let p = pixels(image)
        return (0..<h).map { y in
            var sum = 0
            for x in 0..<w { sum += Int(p[(y * w + x) * 4 + 1]) }
            return Double(sum) / Double(w)
        }
    }

    /// Number of row boundaries down the picture: each step from a light row
    /// into a clearly darker one. A scanline filter on N game rows darkens the
    /// edges of every row, so it steps down N times (the half-band at the very
    /// top is not a step and is not counted).
    private static func darkBands(_ rows: [Double]) -> Int {
        guard let top = rows.max() else { return 0 }
        let dark = rows.map { $0 < top * 0.9 }
        return (1..<max(dark.count, 1)).filter { dark[$0] && !dark[$0 - 1] }.count
    }

    private static var hasMetal: Bool { MTLCreateSystemDefaultDevice() != nil }

    // MARK: - The uniform layout

    /// The shader's `FilterUniforms` is uint, uint, float2, float2: 24 bytes.
    /// Swift has ONE copy now, which the live view and the offscreen pass both
    /// send; this holds it to the shader's size, the field that went missing.
    @Test func filterUniformsMatchTheShaderLayout() {
        #expect(MemoryLayout<EmulatorMetalView.FilterUniforms>.size == 24)
        #expect(MemoryLayout<EmulatorMetalView.FilterUniforms>.stride == 24)
        #expect(MemoryLayout<EmulatorMetalView.FilterUniforms>.offset(of: \.gameSize) == 8)
        #expect(MemoryLayout<EmulatorMetalView.FilterUniforms>.offset(of: \.uvScale) == 16)
    }

    // MARK: - CRT offscreen (every console)

    /// The CRT through the offscreen pass draws the picture, not black. With
    /// `uvScale` unbound it divided by whatever followed the 16 bytes sent.
    @Test func crtOffscreenDrawsThePicture() throws {
        try #require(Self.hasMetal, "no Metal device")
        // GBA, GB, SNES, a PlayStation / N64 low resolution, an N64 high one.
        for size in [(240, 160), (160, 144), (256, 224), (320, 240), (640, 240)] {
            try crtDrawsThePicture(width: size.0, height: size.1)
        }
    }

    private func crtDrawsThePicture(width: Int, height: Int) throws {
        let size = (width, height)
        let image = try #require(Self.flatImage(width: size.0, height: size.1))
        let target = CGSize(width: size.0 * 4, height: size.1 * 4)
        let out = try #require(VideoFilterRenderer.apply(.crt, to: image, targetSize: target))
        try #require(out !== image, "the filter pass fell back to the unfiltered image")
        // The centre of a mid-grey picture under the CRT is lit: scanlines and
        // the mask darken it a little, a black frame darkens it all the way.
        let p = Self.pixels(out)
        let cx = out.width / 2
        var lit = 0
        for y in (out.height / 2 - 4)..<(out.height / 2 + 4) {
            if p[(y * out.width + cx) * 4 + 1] > 60 { lit += 1 }
        }
        #expect(lit >= 4, "CRT centre is black at \(size.0)x\(size.1)")
    }

    // MARK: - The pixel grid (PlayStation, Nintendo 64)

    /// The scanlines follow the GAME's rows, not the stretched still's. An
    /// N64 640x240 frame reaches the preview as a 640x480 image; told its grid,
    /// the filter draws 240 dark bands, one per real row, not 480.
    @Test func scanlinesFollowTheGamesRows() throws {
        try #require(Self.hasMetal, "no Metal device")
        // (game grid, the 4:3 still the bridge hands out)
        let cases: [((Int, Int), (Int, Int))] = [
            ((640, 240), (640, 480)),   // N64 NTSC, progressive
            ((640, 288), (640, 480)),   // N64 PAL
            ((320, 240), (320, 240)),   // N64 / PS1 low resolution: already 4:3
            ((256, 240), (320, 240)),   // PS1 256 wide
            ((368, 240), (368, 276)),   // PS1 368 wide
            ((512, 240), (512, 384)),   // PS1 512 wide
            ((640, 480), (640, 480)),   // PS1 interlaced
        ]
        for (grid, still) in cases {
            try scanlinesFollowRows(grid: grid, still: still)
        }
    }

    private func scanlinesFollowRows(grid: (Int, Int), still: (Int, Int)) throws {
        let image = try #require(Self.flatImage(width: still.0, height: still.1))
        // Four display pixels per game row: the density of a phone screen.
        let target = CGSize(width: grid.0 * 2, height: grid.1 * 4)
        let out = try #require(VideoFilterRenderer.apply(
            .scanlines, to: image, targetSize: target,
            pixelGrid: CGSize(width: grid.0, height: grid.1)))
        let bands = Self.darkBands(Self.rowMeans(out))
        #expect(abs(bands - grid.1) <= 1,
                "\(grid.0)x\(grid.1) via a \(still.0)x\(still.1) still: \(bands) scanlines, expected \(grid.1)")
    }

    /// Without the grid the same still would be treated as 480 rows: the
    /// regression this guards (and the proof the test above can fail).
    @Test func withoutTheGridTheStretchedStillDoublesTheRows() throws {
        try #require(Self.hasMetal, "no Metal device")
        let image = try #require(Self.flatImage(width: 640, height: 480))
        let out = try #require(VideoFilterRenderer.apply(
            .scanlines, to: image, targetSize: CGSize(width: 1280, height: 1920)))
        #expect(abs(Self.darkBands(Self.rowMeans(out)) - 480) <= 1)
    }

    /// The share cards get the same correction: an N64 640x240 frame captured
    /// as a 640x480 still, filtered with its grid at the card's size, draws one
    /// scanline per real row. Without the grid (the share cards until
    /// 2026-10-01) the same card drew 480.
    @Test func shareCardScanlinesFollowTheGamesRows() throws {
        try #require(Self.hasMetal, "no Metal device")
        let image = try #require(Self.flatImage(width: 640, height: 480))
        let card = ScreenshotCardRenderer.cleanGameImage(
            image, target: CGSize(width: 960, height: 960), filter: .scanlines,
            pixelGrid: CGSize(width: 640, height: 240))
        let cg = try #require(card.cgImage)
        #expect(abs(Self.darkBands(Self.rowMeans(cg)) - 240) <= 1)
    }

    // MARK: - The preview's size

    /// The preview is rendered at the density it is displayed at, so a grid
    /// filter is visible exactly when it is on the live screen. The old fixed
    /// 800 px gave a 640-wide picture 1.25 pixels per game pixel, under the
    /// shader's fade threshold of two: no scanlines.
    @Test func previewTargetFitsTheGameScreen() {
        // An N64 4:3 still on a 14 Pro's portrait game screen (393 pt x 3).
        let fitted = VideoFilterRenderer.previewTargetSize(
            imageSize: CGSize(width: 640, height: 480),
            screenPixelSize: CGSize(width: 1179, height: 884))
        #expect(fitted.width == 1179)
        #expect(fitted.height == 884)
        // Capped by height: the shape is kept.
        let capped = VideoFilterRenderer.previewTargetSize(
            imageSize: CGSize(width: 640, height: 480),
            screenPixelSize: CGSize(width: 2000, height: 960))
        #expect(capped == CGSize(width: 1280, height: 960))
        // Nothing to fit into: the image's own size, never zero.
        #expect(VideoFilterRenderer.previewTargetSize(
            imageSize: CGSize(width: 240, height: 160),
            screenPixelSize: .zero) == CGSize(width: 240, height: 160))
    }

    /// At the preview's size, each filter changes a PlayStation or N64 picture
    /// exactly where it does on the live screen. This is the reported symptom:
    /// on these two consoles the previews looked like None.
    ///
    /// Not every pair shows, and that is the SHADER's rule, live included: the
    /// LCD grid fades out under two display pixels per game pixel and the dot
    /// matrix under three, in both directions. A 640-wide N64 picture on a
    /// phone is 1.8 pixels per game pixel across, so those two cannot show on
    /// it, live or previewed; scanlines and CRT, which follow the rows, do.
    @Test func filtersShowOnPlayStationAndN64Previews() throws {
        try #require(Self.hasMetal, "no Metal device")
        let cases: [(VideoFilter, [(Int, Int)])] = [
            (.scanlines, [(640, 240), (320, 240), (256, 240)]),
            (.crt,       [(640, 240), (320, 240), (256, 240)]),
            (.lcdGrid,   [(320, 240), (256, 240)]),
            (.dotMatrix, [(320, 240), (256, 240)]),
        ]
        for (filter, grids) in cases {
            try filterShows(filter, grids: grids)
        }
    }

    private func filterShows(_ filter: VideoFilter, grids: [(Int, Int)]) throws {
        for grid in grids {
            // The 4:3 still the bridge hands out for that grid.
            let still = grid.0 == 640 ? (640, 480) : (320, 240)
            let image = try #require(Self.flatImage(width: still.0, height: still.1))
            // A 14 Pro's portrait game screen.
            let target = VideoFilterRenderer.previewTargetSize(
                imageSize: CGSize(width: still.0, height: still.1),
                screenPixelSize: CGSize(width: 1179, height: 884))
            let out = try #require(VideoFilterRenderer.apply(
                filter, to: image, targetSize: target,
                pixelGrid: CGSize(width: grid.0, height: grid.1)))
            let rows = Self.rowMeans(out)
            let spread = (rows.max() ?? 0) - (rows.min() ?? 0)
            #expect(spread > 4,
                    "\(filter.rawValue) on \(grid.0)x\(grid.1): the preview is flat, the filter does not show")
        }
    }
}
