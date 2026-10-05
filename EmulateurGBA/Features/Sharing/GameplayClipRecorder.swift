//
//  GameplayClipRecorder.swift
//  EmulateurGBA
//
//  Keeps a rolling window of the last few seconds of gameplay so it can be
//  turned into a short, looping, "gif-style" clip on demand (see
//  GameplayClipRenderer). Companion to the screenshot card: same "share your
//  moment, subtly branded" idea, in motion.
//
//  Capture model (decided 2026-05-28): WALL-CLOCK. We capture ~captureFPS frames
//  per REAL second, so the clip is the player's actual on-screen experience over
//  the last `clipSeconds` real seconds. A fast-forwarder (e.g. 4x) therefore gets
//  a full, action-packed 6-second moment at the speed THEY chose to play, and the
//  playback speed-up sits on top as a little extra snap (so the clip speed
//  compounds with play speed by design: 4x play * 1.6 playback = 6.4x clip). This
//  is deliberately NOT normalized to game-time — the clip should reflect what the
//  user saw, not a uniform speed.
//
//  - The costly CGImage is only built when a capture is actually due, so the hot
//    path is otherwise just a timestamp compare.
//  - Frames are stored as CGImages (the bridge produces these correctly via
//    EmulatorSession.createScreenshotImage(), so we don't re-handle raw pixel
//    formats) in a fixed-size ring; the oldest is dropped.
//  - MEMORY: up to `captureFPS * clipSeconds` images stay resident during play
//    (~150 KB each for GBA, ~400 KB for NDS). Defaults are conservative; tune.
//

import QuartzCore
import CoreGraphics

final class GameplayClipRecorder {

    /// The choppy "gif" capture rate, in REAL frames per second.
    var captureFPS: Double = 12
    /// How many REAL seconds of play the clip covers.
    var clipSeconds: Double = 6
    /// Playback speed-up to apply, as a function of the player's emulation speed.
    /// It tapers as play speed rises so a fast-forwarder's clip stays watchable
    /// instead of compounding to an absurd rate (4x play would otherwise be 6.4x).
    /// Effective clip speed = emulationSpeed * this:
    ///   <=1x -> 1.6 (1.6x),  1.5x -> 1.5 (2.25x),  2x -> 1.4 (2.8x),
    ///   3x -> 1.3 (3.9x),    >=4x -> 1.2 (4.8x).
    /// The picked emulation speed is whatever is active when the clip is requested.
    static func playbackSpeed(forEmulationSpeed s: Double) -> Double {
        switch s {
        case ..<1.25: return 1.6
        case ..<1.75: return 1.5
        case ..<2.5:  return 1.4
        case ..<3.5:  return 1.3
        default:      return 1.2
        }
    }

    /// Exposed so the encoder paces the output at the same rate it was captured.
    var fps: Double { captureFPS }

    private var maxFrames: Int { max(2, Int((captureFPS * clipSeconds).rounded())) }

    private let lock = NSLock()
    private var ring: [CGImage] = []
    /// The pixel grid behind each frame in `ring`, same index (nil = the
    /// frame's own size). Kept per frame because a PlayStation game changes
    /// resolution mid-clip.
    private var grids: [CGSize?] = []
    private var writeIndex = 0
    private var lastCaptureTime: CFTimeInterval = 0
    private(set) var isEnabled = false

    func start() {
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        grids.removeAll(keepingCapacity: true)
        writeIndex = 0
        lastCaptureTime = 0
        isEnabled = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        isEnabled = false
        ring.removeAll(keepingCapacity: false)
        grids.removeAll(keepingCapacity: false)
        writeIndex = 0
        lock.unlock()
    }

    /// Called from the render thread once per produced frame. Down-samples to
    /// `captureFPS` by wall-clock; `makeImage` (the expensive part) only runs
    /// when a capture is actually due, so most calls cost just a time compare.
    /// `pixelGrid` gives the frame's filter grid (see `GameplayClipFrame`); it
    /// runs only when a capture is taken.
    func captureIfDue(_ makeImage: () -> CGImage?, pixelGrid: (CGImage) -> CGSize? = { _ in nil }) {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        if lastCaptureTime != 0, now - lastCaptureTime < 1.0 / captureFPS { return }
        guard let image = makeImage() else { return }
        let grid = pixelGrid(image)
        lastCaptureTime = now

        lock.lock()
        if ring.count < maxFrames {
            ring.append(image)
            grids.append(grid)
        } else {
            ring[writeIndex] = image
            grids[writeIndex] = grid
            writeIndex = (writeIndex + 1) % maxFrames
        }
        lock.unlock()
    }

    /// Buffered frames in chronological order (oldest first), for encoding.
    /// Safe to call from a background thread while capture continues.
    func snapshotFrames() -> [GameplayClipFrame] {
        lock.lock()
        defer { lock.unlock() }
        let frames = zip(ring, grids).map { GameplayClipFrame(image: $0, pixelGrid: $1) }
        guard frames.count == maxFrames else { return frames }
        return Array(frames[writeIndex...] + frames[..<writeIndex])
    }
}

/// One captured clip frame: the still, and the game's own pixel grid behind it
/// when that is not the still's size (PlayStation and Nintendo 64 stills are
/// stretched to 4:3; see `EmulatorSession.filterPixelGrid`). The display filter
/// draws on the grid.
struct GameplayClipFrame {
    let image: CGImage
    let pixelGrid: CGSize?
}
