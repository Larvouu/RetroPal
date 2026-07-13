//
//  EmulatorMetalView.swift
//  EmulateurGBA
//
//  Metal-backed view for rendering emulator frames at low latency.
//  Supports single-screen (GBA) and dual-screen (NDS) rendering.
//

import UIKit
import MetalKit

final class EmulatorMetalView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var ndsPipelineState: MTLRenderPipelineState?
    private var ndsVertexBuffer: MTLBuffer?
    private var textures: [MTLTexture] = []
    private var currentTextureIndex = 0
    private weak var session: EmulatorSession?

    private var isEmulatorRunning = false
    private var isDualScreen = false
    /// When true, NDS screens are rendered side-by-side (landscape mode)
    var ndsSideBySide = false { didSet { if isDualScreen { rebuildNDSVertices() } } }
    var speedMultiplier: Double = 1.0

    /// Optional rolling clip recorder, fed one frame image per produced frame.
    /// It down-samples internally to its low "gif" fps, so the image is only
    /// built a few times per second. Owned/assigned by EmulatorViewController.
    weak var clipRecorder: GameplayClipRecorder?

    // GBA frame timing: 16,777,216 Hz CPU / 280,896 cycles per frame ≈ 59.7275 fps
    private static let gbaFrameDuration: CFTimeInterval = 280896.0 / 16777216.0
    private var timeAccumulator: CFTimeInterval = 0
    private var lastDrawTime: CFTimeInterval = 0

    // NDS screen split ratios
    private static let ndsGapRatio: Float = 0.01

    /// Ratio of the view height allocated to the top NDS screen (0.0–1.0, excluding gap).
    /// Default 0.495 = each screen gets ~49.5% with a 1% gap.
    var ndsTopScreenRatio: Float = 0.495 { didSet { if isDualScreen { rebuildNDSVertices() } } }

    /// One NDS screen quad of a preset-customized layout: a rect in this view's
    /// own coordinate space + the screen's opacity.
    struct CustomScreenQuad {
        var rect: CGRect
        var alpha: CGFloat
    }

    /// Custom NDS screen layout from an active control preset: arbitrary
    /// view-space rects with per-screen alpha, in physical order. nil = the
    /// default stacked / side-by-side split. While set, the view renders
    /// transparently outside the quads (clear color alpha 0) so whatever sits
    /// behind shows through; the host must make the view non-opaque with a
    /// clear background.
    var ndsCustomScreens: (top: CustomScreenQuad, bottom: CustomScreenQuad)? {
        didSet {
            clearColor = ndsCustomScreens != nil
                ? MTLClearColorMake(0, 0, 0, 0)
                : MTLClearColorMake(0, 0, 0, 1)
            if isDualScreen { rebuildNDSVertices() }
        }
    }


    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        setup()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        setup()
    }

    private func setup() {
        guard let device = self.device else {
            print("[Metal] No Metal device available")
            return
        }

        delegate = self
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        backgroundColor = .black

        commandQueue = device.makeCommandQueue()
        setupPipelines(device: device)
    }

    private func setupPipelines(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary() else {
            print("[Metal] Failed to load default library")
            return
        }

        let fragmentFunc = library.makeFunction(name: "fragmentShader")

        // Single-screen pipeline (GBA)
        let singleDesc = MTLRenderPipelineDescriptor()
        singleDesc.vertexFunction = library.makeFunction(name: "vertexShader")
        singleDesc.fragmentFunction = fragmentFunc
        singleDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        pipelineState = try? device.makeRenderPipelineState(descriptor: singleDesc)

        // Dual-screen pipeline (NDS) — uses vertex buffer. Alpha blending carries
        // a preset's per-screen opacity; at the default alpha of 1.0 the blend
        // is an exact pass-through, so the default rendering is unchanged.
        let dualDesc = MTLRenderPipelineDescriptor()
        dualDesc.vertexFunction = library.makeFunction(name: "ndsVertexShader")
        dualDesc.fragmentFunction = fragmentFunc
        dualDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        dualDesc.colorAttachments[0].isBlendingEnabled = true
        dualDesc.colorAttachments[0].rgbBlendOperation = .add
        dualDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        dualDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        dualDesc.colorAttachments[0].alphaBlendOperation = .add
        dualDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        dualDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        ndsPipelineState = try? device.makeRenderPipelineState(descriptor: dualDesc)
    }

    // MARK: - Public API

    func attach(session: EmulatorSession) {
        self.session = session
        isDualScreen = session.hasTouchScreen

        guard let device = self.device else { return }
        let pixelFormat: MTLPixelFormat = session.hasTouchScreen ? .bgra8Unorm : .rgba8Unorm
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: session.screenWidth,
            height: session.totalBufferHeight,
            mipmapped: false
        )
        desc.usage = .shaderRead
        textures = (0..<2).compactMap { _ in device.makeTexture(descriptor: desc) }
        currentTextureIndex = 0

        if isDualScreen {
            rebuildNDSVertices()
        }
    }

    func startRendering() {
        isEmulatorRunning = true
        lastDrawTime = CACurrentMediaTime()
        timeAccumulator = EmulatorMetalView.gbaFrameDuration
        isPaused = false
    }

    func stopRendering() {
        isEmulatorRunning = false
        isPaused = true
    }

    // MARK: - NDS Vertex Geometry

    /// Build vertex data for two quads rendering both NDS screens.
    /// Supports two modes: stacked (portrait) and side-by-side (landscape).
    /// Each screen maintains its native 4:3 aspect ratio.
    private func rebuildNDSVertices() {
        guard let device = self.device else { return }

        let viewW = Float(bounds.width > 0 ? bounds.width : 256)
        let viewH = Float(bounds.height > 0 ? bounds.height : 384)
        let viewAspect = viewW / viewH
        let screenAspect: Float = 256.0 / 192.0  // 4:3
        let swapped = UserDefaults.standard.bool(forKey: "ndsSwapScreens")

        // Texture V coordinates: top screen = 0.0–0.5, bottom screen = 0.5–1.0
        // When swapped, the "first" quad shows the bottom texture and vice versa
        let firstVMin: Float = swapped ? 0.5 : 0.0
        let firstVMax: Float = swapped ? 1.0 : 0.5
        let secondVMin: Float = swapped ? 0.0 : 0.5
        let secondVMax: Float = swapped ? 0.5 : 1.0

        struct V {
            var px: Float; var py: Float; var u: Float; var v: Float; var a: Float
        }

        let vertices: [V]

        if let custom = ndsCustomScreens {
            // === Preset layout: arbitrary view-space rect + alpha per screen ===
            // Convert each rect from view coordinates (y down) to clip space (y up).
            func quad(_ q: CustomScreenQuad, vMin: Float, vMax: Float) -> [V] {
                let l = Float(q.rect.minX / CGFloat(viewW)) * 2.0 - 1.0
                let r = Float(q.rect.maxX / CGFloat(viewW)) * 2.0 - 1.0
                let t = 1.0 - Float(q.rect.minY / CGFloat(viewH)) * 2.0
                let b = 1.0 - Float(q.rect.maxY / CGFloat(viewH)) * 2.0
                let a = Float(q.alpha)
                return [
                    V(px: l, py: b, u: 0, v: vMax, a: a), V(px: r, py: b, u: 1, v: vMax, a: a), V(px: l, py: t, u: 0, v: vMin, a: a),
                    V(px: l, py: t, u: 0, v: vMin, a: a), V(px: r, py: b, u: 1, v: vMax, a: a), V(px: r, py: t, u: 1, v: vMin, a: a),
                ]
            }
            vertices = quad(custom.top, vMin: firstVMin, vMax: firstVMax)
                + quad(custom.bottom, vMin: secondVMin, vMax: secondVMax)

        } else if ndsSideBySide {
            // === Side-by-side (landscape): left = top screen, right = bottom screen ===
            // Both screens same size, touching each other, centered horizontally.
            // Each screen is aspect-fit to 4:3 within half the view width.

            // Compute screen pixel dimensions: fit within half-width, full height
            var screenPixelW = viewW / 2.0
            var screenPixelH = screenPixelW / screenAspect
            if screenPixelH > viewH {
                screenPixelH = viewH
                screenPixelW = screenPixelH * screenAspect
            }

            // Convert to clip space
            let clipW = screenPixelW / viewW * 2.0
            let clipH = screenPixelH / viewH * 2.0

            // Two screens touching at the center (no gap), centered as a pair
            let leftR: Float = 0.0       // left screen's right edge at center
            let leftL: Float = -clipW    // left screen's left edge
            let rightL2: Float = 0.0     // right screen's left edge at center
            let rightR2: Float = clipW   // right screen's right edge

            let leftTop = clipH / 2.0
            let leftBot = -clipH / 2.0
            let rightTop = clipH / 2.0
            let rightBot = -clipH / 2.0

            vertices = [
                // Left screen (first screen)
                V(px: leftL, py: leftBot, u: 0, v: firstVMax, a: 1), V(px: leftR, py: leftBot, u: 1, v: firstVMax, a: 1), V(px: leftL, py: leftTop, u: 0, v: firstVMin, a: 1),
                V(px: leftL, py: leftTop, u: 0, v: firstVMin, a: 1), V(px: leftR, py: leftBot, u: 1, v: firstVMax, a: 1), V(px: leftR, py: leftTop, u: 1, v: firstVMin, a: 1),
                // Right screen (second screen = touch)
                V(px: rightL2, py: rightBot, u: 0, v: secondVMax, a: 1),   V(px: rightR2, py: rightBot, u: 1, v: secondVMax, a: 1),   V(px: rightL2, py: rightTop, u: 0, v: secondVMin, a: 1),
                V(px: rightL2, py: rightTop, u: 0, v: secondVMin, a: 1),   V(px: rightR2, py: rightBot, u: 1, v: secondVMax, a: 1),   V(px: rightR2, py: rightTop, u: 1, v: secondVMin, a: 1),
            ]

        } else {
            // === Stacked (portrait): screens sized according to ndsTopScreenRatio ===
            let topRatio = ndsTopScreenRatio
            let gapRatio = EmulatorMetalView.ndsGapRatio
            let botRatio: Float = 1.0 - topRatio - gapRatio

            let topH: Float = topRatio * 2.0
            let gapH: Float = gapRatio * 2.0
            let botH: Float = botRatio * 2.0

            // Compute width to maintain 4:3 aspect for each screen independently.
            var adjTopH = topH
            var topW = topH * screenAspect / viewAspect
            if topW > 2.0 {
                topW = 2.0
                adjTopH = topW * viewAspect / screenAspect
            }

            // Bottom screen: independently computed to maintain 4:3 aspect
            var adjBotH = botH
            var botW = botH * screenAspect / viewAspect
            if botW > 2.0 {
                botW = 2.0
                adjBotH = botW * viewAspect / screenAspect
            }

            let topTop: Float    =  1.0
            let topBottom: Float =  1.0 - adjTopH
            let botTop: Float    = topBottom - gapH
            let botBottom: Float = botTop - adjBotH

            let topL = -topW / 2.0, topR = topW / 2.0
            let botL = -botW / 2.0, botR = botW / 2.0

            vertices = [
                // Top quad (first screen)
                V(px: topL, py: topBottom, u: 0, v: firstVMax, a: 1), V(px: topR, py: topBottom, u: 1, v: firstVMax, a: 1), V(px: topL, py: topTop, u: 0, v: firstVMin, a: 1),
                V(px: topL, py: topTop,    u: 0, v: firstVMin, a: 1), V(px: topR, py: topBottom, u: 1, v: firstVMax, a: 1), V(px: topR, py: topTop, u: 1, v: firstVMin, a: 1),
                // Bottom quad (second screen = touch)
                V(px: botL, py: botBottom, u: 0, v: secondVMax, a: 1), V(px: botR, py: botBottom, u: 1, v: secondVMax, a: 1), V(px: botL, py: botTop, u: 0, v: secondVMin, a: 1),
                V(px: botL, py: botTop,    u: 0, v: secondVMin, a: 1), V(px: botR, py: botBottom, u: 1, v: secondVMax, a: 1), V(px: botR, py: botTop, u: 1, v: secondVMin, a: 1),
            ]
        }

        ndsVertexBuffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<V>.stride * vertices.count, options: .storageModeShared)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if isDualScreen {
            rebuildNDSVertices()
        }
    }

    func draw(in view: MTKView) {
        guard isEmulatorRunning,
              let session = session,
              session.isRunning else { return }

        // Time-based frame pacing.
        //
        // Wall-clock accumulator at the GBA native rate (59.7275 fps). The emulator
        // produces audio at a hardware-derived rate (SOUNDBIAS-driven for GBA,
        // 131,072 Hz for GB/GBC), and AVAudioEngine's source-format-to-hardware
        // resampler handles the playback-rate conversion accurately, so emulator
        // pacing does NOT need to react to ring-buffer fill level. The Swift ring
        // pre-roll in EmulatorAudioEngine.start() absorbs the burst-vs-continuous
        // mismatch between mGBA's per-frame audio output and AVAudioEngine's
        // streaming consumer.
        //
        // Earlier versions had a drift-correction block here that targeted 4 ms
        // of ring fill (well below one emulated frame's worth of samples) and
        // applied its correction with an inverted sign, producing constant ±3%
        // frame-time jitter and chronic underruns. Removed deliberately.
        let now = CACurrentMediaTime()
        let elapsed = now - lastDrawTime
        lastDrawTime = now
        timeAccumulator += elapsed

        let frameDuration = EmulatorMetalView.gbaFrameDuration
        let effectiveDuration = frameDuration / max(0.25, speedMultiplier)

        let capThreshold = max(frameDuration * 3, effectiveDuration * 1.5)
        if timeAccumulator > capThreshold {
            timeAccumulator = effectiveDuration
        }

        // Skip the audio drain only while muted (saves CPU — notably at high
        // speeds, which auto-mute by default). When the user keeps sound on, we
        // drain at every speed so fast-forward plays its (sped-up) audio.
        session.skipAudio = session.isAudioMuted

        var didRunFrame = false
        var framesThisDraw = 0
        while timeAccumulator >= effectiveDuration && framesThisDraw < 8 {
            session.runFrame()
            timeAccumulator -= effectiveDuration
            didRunFrame = true
            framesThisDraw += 1
        }

        guard textures.count == 2 else { return }

        // Only upload and flip texture when a new frame was produced.
        // At sub-1x speeds, draw() fires more often than frames run;
        // flipping without new data causes shaking between stale textures.
        if didRunFrame, let frameBuffer = session.frameBuffer() {
            let texture = textures[currentTextureIndex]
            let w = session.screenWidth
            let h = session.totalBufferHeight
            let bytesPerRow = session.bufferStride * 4
            let region = MTLRegionMake2D(0, 0, w, h)
            texture.replace(region: region, mipmapLevel: 0,
                            withBytes: frameBuffer,
                            bytesPerRow: bytesPerRow)
            currentTextureIndex = 1 - currentTextureIndex

            // Feed the rolling clip recorder. It down-samples to its low gif fps
            // by wall-clock, so the clip is the player's actual on-screen
            // experience (their chosen speed), and createScreenshotImage() runs
            // only a few times per real second.
            clipRecorder?.captureIfDue { session.createScreenshotImage() }
        }

        // Always render the last-written texture (the one we just flipped away from,
        // or the current one if no new frame was produced this draw call)
        let displayTexture = textures[1 - currentTextureIndex]

        guard let drawable = currentDrawable,
              let passDesc = currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        if isDualScreen, let ndsPipeline = ndsPipelineState, let vertexBuf = ndsVertexBuffer {
            encoder.setRenderPipelineState(ndsPipeline)
            encoder.setVertexBuffer(vertexBuf, offset: 0, index: 0)
            encoder.setFragmentTexture(displayTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12)
        } else if let pipeline = pipelineState {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(displayTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
