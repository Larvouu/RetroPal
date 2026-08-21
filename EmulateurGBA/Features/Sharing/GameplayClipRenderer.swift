//
//  GameplayClipRenderer.swift
//  EmulateurGBA
//
//  Turns the frames buffered by GameplayClipRecorder into a short, looping,
//  "gif-style" clip: a neon card (matching ScreenshotCardRenderer's look, but
//  smaller and badge-free) with the gameplay playing inside the bezel, encoded
//  as a low-frame-rate MP4. MP4 (not GIF) on purpose: tiny, full color, and it
//  autoplays inline on Discord / Reddit / Bluesky / X and saves cleanly to
//  Photos. The low fps + the loop give the choppy "gif" feel.
//
//  Runs entirely off the render thread.
//
//  ⚠️ FIRST-RUN VERIFY (blind-written, untested on device):
//   1. Colors: if the clip looks colour-swapped (red/blue inverted), flip the
//      pixel format / bitmapInfo pair in `pixelBuffer(from:)` (ARGB <-> BGRA).
//   2. Orientation: if the video is upside down, uncomment the one-line flip
//      in `pixelBuffer(from:)`.
//

import AVFoundation
import UIKit

enum GameplayClipRenderer {

    /// Square card. Smaller than the screenshot card (1080x1350); no badges.
    private static let cardSide: CGFloat = 1080
    /// How many times the captured sequence is written back-to-back, so the
    /// loop is visible even where a platform does not autoloop.
    private static let loops = 2

    // Brand colors (kept in sync with ScreenshotCardRenderer).
    private static let purple = UIColor(red: 0.45, green: 0.2, blue: 0.85, alpha: 1)
    private static let gold = UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 1)

    /// Encode the FINAL shareable MP4 with the full card chrome baked in at the
    /// chosen style (called at Share/Save time). Calls back on the main thread with
    /// the file URL (or nil on failure); the heavy work runs on a background queue.
    /// The crown follows `isPro` (real ownership), the gold UI follows `style`;
    /// `skinVariant` is the game's current dress, rendered when `style == .skin`.
    static func renderClip(frames: [CGImage], fps: Double, speed: Double = 1.0,
                           title: String, playTime: TimeInterval, style: ShareCardStyle, isPro: Bool,
                           system: PresetSystem = .gba, skinVariant: DressVariant? = nil,
                           filter: VideoFilter = .none,
                           completion: @escaping (URL?) -> Void) {
        guard frames.count >= 2 else { completion(nil); return }
        let size = CGSize(width: cardSide, height: cardSide)

        // Nostalgia / current-skin styles: the console card, in the dress's palette. Its chrome
        // (console + text + edge) instantiates UIViews, so build it ONCE here on the main thread,
        // then composite each frame into the screen off-thread. The layout + chrome are the
        // matching console pair per system.
        if let variant = ScreenshotCardRenderer.consoleVariant(style: style, skinVariant: skinVariant) {
            let aspect = frames.first.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1
            let info = ScreenshotCardRenderer.GameInfo(name: title, playTimeSeconds: playTime, isPro: isPro)
            // Chrome and layout are a PAIR and must come from the same console, and the
            // mapping lives in ScreenshotCardRenderer so this card and the screenshot card can
            // never disagree about which console a game is. nil would mean a console with no
            // dress; every console has one since the NES's landed, so the branded card below is
            // now reached only by the Classic style.
            let pair = ScreenshotCardRenderer.consoleCard(
                system: system, gameFrame: nil, gameAspect: aspect, info: info,
                variant: variant, side: cardSide)
            if let (chrome, layout) = pair {
                // NDS Nostalgia clip uses the separated two-screen layout (matching the screenshot
                // card); every other console uses the single combined screen.
                let screens = layout.ndsScreens.isEmpty ? [layout.screen] : layout.ndsScreens
                DispatchQueue.global(qos: .userInitiated).async {
                    let url = encode(frames: frames, fps: max(1, fps), speed: max(0.25, speed), size: size) { game in
                        gbCompositeFrame(chrome: chrome, screens: screens, gameImage: game, side: cardSide,
                                         filter: filter)
                    }
                    DispatchQueue.main.async { completion(url) }
                }
                return
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let url = encode(frames: frames, fps: max(1, fps), speed: max(0.25, speed), size: size) { game in
                compositeCard(gameImage: game, title: title, playTime: playTime, style: style, isPro: isPro,
                              filter: filter)
            }
            DispatchQueue.main.async { completion(url) }
        }
    }

    /// One GB/GBC console-card frame: the prebuilt chrome (console + text + edge, dark screen) with
    /// the gameplay frame drawn into the GB screen rect. UIGraphicsImageRenderer is thread-safe, so
    /// this runs off the main thread; the chrome was built on the main thread by `renderClip`.
    private static func gbCompositeFrame(chrome: UIImage?, screens: [CGRect],
                                         gameImage: CGImage, side: CGFloat,
                                         filter: VideoFilter = .none) -> CGImage? {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { rctx in
            let ctx = rctx.cgContext
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            chrome?.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            func drawGame(_ cg: CGImage, into rect: CGRect) {
                // Filter at the on-card screen size, mirroring the live view.
                let drawn = VideoFilterRenderer.apply(filter, to: cg, targetSize: rect.size) ?? cg
                ctx.saveGState()
                UIBezierPath(roundedRect: rect, cornerRadius: 6).addClip()
                ctx.interpolationQuality = .none
                UIImage(cgImage: drawn).draw(in: rect)
                ctx.restoreGState()
            }
            if screens.count == 2 {
                // NDS separated: split the stacked frame into the upper + lower screens.
                let H = gameImage.height
                let top = gameImage.cropping(to: CGRect(x: 0, y: 0, width: gameImage.width, height: H / 2))
                let bottom = gameImage.cropping(to: CGRect(x: 0, y: H / 2, width: gameImage.width, height: H - H / 2))
                if let top { drawGame(top, into: screens[0]) }
                if let bottom { drawGame(bottom, into: screens[1]) }
            } else if let screen = screens.first {
                drawGame(gameImage, into: screen)
            }
        }
        return img.cgImage
    }

    /// Encode the RAW gameplay (no card chrome) into a looping MP4 for the live
    /// preview. The card chrome is drawn as a SwiftUI overlay over this clip so the
    /// Standard/Pro style can be toggled instantly; the chrome is baked into the MP4
    /// only at Share/Save via `renderClip`.
    static func renderGameplayClip(frames: [CGImage], fps: Double, speed: Double = 1.0,
                                   frameAspect: CGFloat, filter: VideoFilter = .none,
                                   completion: @escaping (URL?) -> Void) {
        guard frames.count >= 2 else { completion(nil); return }
        let size = rawVideoSize(frameAspect: frameAspect)
        DispatchQueue.global(qos: .userInitiated).async {
            let url = encode(frames: frames, fps: max(1, fps), speed: max(0.25, speed), size: size) { game in
                rawFrame(gameImage: game, size: size, filter: filter)
            }
            DispatchQueue.main.async { completion(url) }
        }
    }

    // MARK: - Encoding

    /// Shared encoder: writes `frames` (looped) into an MP4 at `size`, running each
    /// gameplay frame through `makeFrame` to produce the output image (the full card
    /// for the export, or the raw game for the preview).
    private static func encode(frames: [CGImage], fps: Double, speed: Double,
                               size: CGSize, makeFrame: (CGImage) -> CGImage?) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retropal-clip-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }

        let w = Int(size.width), h = Int(size.height)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: bufferAttrs)

        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        // Playback rate = capture fps * speed. Higher plays faster (shorter,
        // snappier) without changing how choppy the captured motion is.
        let playbackFPS = max(1, (fps * speed).rounded())
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(playbackFPS))
        var outIndex = 0
        var success = true

        outer: for _ in 0..<loops {
            for game in frames {
                // Wait (briefly) for the writer to be ready; bail if it errors.
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { success = false; break outer }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                guard let card = makeFrame(game),
                      let pb = pixelBuffer(from: card, pool: adaptor.pixelBufferPool) else {
                    continue
                }
                let time = CMTimeMultiply(frameDuration, multiplier: Int32(outIndex))
                if !adaptor.append(pb, withPresentationTime: time) { success = false; break outer }
                outIndex += 1
            }
        }

        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting {
            success = success && writer.status == .completed
            sem.signal()
        }
        sem.wait()
        return success ? url : nil
    }

    /// Even-dimension size for the raw preview clip: the game at `frameAspect`, with
    /// the larger side ~768 (crisp enough; the preview scales it via AVPlayer). H.264
    /// needs even dimensions.
    private static func rawVideoSize(frameAspect: CGFloat) -> CGSize {
        let target: CGFloat = 768
        var w: CGFloat, h: CGFloat
        if frameAspect >= 1 { w = target; h = target / max(frameAspect, 0.1) }
        else { h = target; w = target * frameAspect }
        func even(_ v: CGFloat) -> CGFloat { let i = Int(v.rounded()); return CGFloat(i - (i % 2)) }
        return CGSize(width: max(2, even(w)), height: max(2, even(h)))
    }

    /// One raw preview frame: the game image filling the video frame, nearest-
    /// neighbor (sharp pixels), no card chrome. Uses the same UIGraphics path as
    /// `compositeCard` so colour + orientation handling matches the export.
    private static func rawFrame(gameImage: CGImage, size: CGSize,
                                 filter: VideoFilter = .none) -> CGImage? {
        // Filter at the raw video size so the LIVE preview mirrors the screen
        // too (the export re-applies the filter at the card's screen size; the
        // preview's slight point-rescale of this video is preview-only).
        if filter != .none {
            return VideoFilterRenderer.apply(filter, to: gameImage, targetSize: size)
        }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rctx in
            rctx.cgContext.interpolationQuality = .none
            UIImage(cgImage: gameImage).draw(in: CGRect(origin: .zero, size: size))
        }
        return img.cgImage
    }

    // MARK: - Card composite (one output frame)

    /// Draw one neon card frame with `gameImage` inside the bezel. Uses
    /// UIGraphicsImageRenderer (upright, correct colours) like the screenshot card.
    private static func compositeCard(gameImage: CGImage, title: String, playTime: TimeInterval,
                                      style: ShareCardStyle, isPro: Bool,
                                      filter: VideoFilter = .none) -> CGImage? {
        let side = cardSide
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: { let f = UIGraphicsImageRendererFormat.default(); f.scale = 1; f.opaque = true; return f }())

        let image = renderer.image { rctx in
            let ctx = rctx.cgContext

            // Rounded card on a pure-black surround: an MP4 frame can't be
            // transparent, so fill the frame with black and round the card against
            // it. The four corners keep this black fill; everything inside the clip
            // is the card. Pure black matches the screenshot + stats cards so all
            // three read identically. (48 matches the screenshot/stats corner.)
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                         cornerRadius: 48).addClip()

            // Background gradient (deep purple -> near-black), matching the card.
            let bgTop = UIColor(red: 0.10, green: 0.06, blue: 0.18, alpha: 1)
            let bgBot = UIColor(red: 0.04, green: 0.02, blue: 0.08, alpha: 1)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [bgTop.cgColor, bgBot.cgColor] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: side), options: [])
            }

            // Pro: faint warm gold wash from the top (no-op for standard).
            ScreenshotCardRenderer.drawProWash(in: ctx, cardW: side, cardH: side, style: style)

            // Retro Pal logo — sole element above the game, shared with the
            // screenshot card so the two read as siblings.
            let logoSize: CGFloat = 56
            let logoY: CGFloat = 64
            ScreenshotCardRenderer.drawLogo(in: ctx, cardW: side, y: logoY, size: logoSize)

            // Game frame inside a neon bezel, at the SAME rect as the standard
            // screenshot card and the GB/GBC console card, so the three cards line up
            // and the live preview (ClipShareView.neonCardBody) matches this export.
            let nativeW = CGFloat(gameImage.width), nativeH = CGFloat(gameImage.height)
            let gameRect = ScreenshotCardRenderer.standardGameScreenRect(
                side: side, gameNativeSize: CGSize(width: nativeW, height: nativeH))
            let gw = gameRect.width, gh = gameRect.height
            let gx = gameRect.minX, gy = gameRect.minY
            let bezelPad: CGFloat = 8
            let bezel = CGRect(x: gx - bezelPad, y: gy - bezelPad, width: gw + bezelPad * 2, height: gh + bezelPad * 2)

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 14, color: purple.withAlphaComponent(0.4).cgColor)
            ctx.setFillColor(UIColor(red: 0.08, green: 0.06, blue: 0.12, alpha: 1).cgColor)
            UIBezierPath(roundedRect: bezel, cornerRadius: 16).fill()
            ctx.restoreGState()

            ctx.saveGState()
            UIBezierPath(roundedRect: gameRect, cornerRadius: 12).addClip()
            ctx.interpolationQuality = .none
            // UIImage.draw handles CGImage orientation correctly inside a
            // UIGraphics context (same approach as ScreenshotCardRenderer), so
            // no manual flip needed here. The display filter bakes in at the
            // on-card screen size, mirroring the live view.
            let drawnGame = VideoFilterRenderer.apply(filter, to: gameImage,
                                                      targetSize: gameRect.size) ?? gameImage
            UIImage(cgImage: drawnGame).draw(in: gameRect)
            ctx.restoreGState()

            purple.withAlphaComponent(0.6).setStroke()
            let path = UIBezierPath(roundedRect: bezel, cornerRadius: 16)
            path.lineWidth = 1.5
            path.stroke()

            // Title below the game (same cursor as the screenshot + console cards).
            var cursorY = gy + gh + bezelPad + 32
            cursorY += ScreenshotCardRenderer.drawFittedTitle(title, cardW: side, y: cursorY,
                                                              maxWidth: side - 120) + 8

            let mutedWhite = UIColor.white.withAlphaComponent(0.55)

            // Play-time line. For Pro, the metal crown badge + "Pro member" label join
            // the play time on ONE horizontally-centered line:
            //     <play time>   [crown]  Pro member
            // with a little empty separator before the badge. Otherwise it's just the
            // centered play time, unchanged.
            let ptStr = ScreenshotCardRenderer.playTimeString(seconds: playTime) as NSString
            let ptAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .medium), .foregroundColor: gold]
            let ptSize = ptStr.size(withAttributes: ptAttrs)

            if isPro {
                let cfg = UIImage.SymbolConfiguration(pointSize: 100, weight: .bold)
                let aspect = (UIImage(systemName: "crown.fill", withConfiguration: cfg)?.size)
                    .map { $0.width / max($0.height, 1) } ?? 1.5
                // Crown sized to ~the play-time text height so it sits cleanly in line.
                let badgeSide = ptSize.height * aspect
                let emblem = ScreenshotCardRenderer.proCrownBadgeImage(side: badgeSide)
                let emblemMargin = badgeSide * 0.26   // matches proCrownBadgeImage's glow margin

                // Label matches the play-time text size (28pt) so the two read as one
                // line; muted footer color, crown emoji stripped (the badge is the crown).
                let label = (NSLocalizedString("screenshot.proMember", comment: "")
                    .replacingOccurrences(of: "👑", with: "")
                    .trimmingCharacters(in: .whitespaces)) as NSString
                let labelAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 28, weight: .medium), .foregroundColor: mutedWhite]
                let lSize = label.size(withAttributes: labelAttrs)

                let sep: CGFloat = 20   // little empty space between play time and badge
                let gap: CGFloat = 12   // between the crown and its label
                // The crown's visible box is `badgeSide` wide (the emblem image is
                // wider by the glow margin each side); lay the line out in visible
                // widths and center it.
                let lineW = ptSize.width + sep + badgeSide + gap + lSize.width
                let centerY = cursorY + ptSize.height / 2
                var x = (side - lineW) / 2

                ptStr.draw(at: CGPoint(x: x, y: centerY - ptSize.height / 2), withAttributes: ptAttrs)
                x += ptSize.width + sep
                emblem.draw(at: CGPoint(x: x - emblemMargin, y: centerY - emblem.size.height / 2))
                x += badgeSide + gap
                label.draw(at: CGPoint(x: x, y: centerY - lSize.height / 2), withAttributes: labelAttrs)
            } else {
                ptStr.draw(at: CGPoint(x: (side - ptSize.width) / 2, y: cursorY), withAttributes: ptAttrs)
            }

            // Footer "Retro Pal on the App Store".
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: mutedWhite]
            let footer = NSLocalizedString("screenshot.footer", comment: "") as NSString
            let fSize = footer.size(withAttributes: footerAttrs)
            footer.draw(at: CGPoint(x: (side - fSize.width) / 2, y: side - 64 - fSize.height),
                        withAttributes: footerAttrs)

            // Surrounding card edge (two-tone gold for Pro, subtle purple otherwise).
            // Traces the rounded outline so the corners read against the dark surround.
            ScreenshotCardRenderer.drawCardEdge(in: ctx, cardW: side, cardH: side, cornerRadius: 48, style: style)
        }
        return image.cgImage
    }

    // MARK: - CGImage -> CVPixelBuffer

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool = pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        }
        guard let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        // 32ARGB pairs with premultipliedFirst + 32-big byte order. If colours
        // come out swapped on device, switch to kCVPixelFormatType_32BGRA above
        // and premultipliedFirst | byteOrder32Little here.
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        // If the clip is upside-down on device, uncomment this vertical flip:
        // ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
