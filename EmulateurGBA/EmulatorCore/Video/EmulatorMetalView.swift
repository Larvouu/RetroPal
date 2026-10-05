//
//  EmulatorMetalView.swift
//  EmulateurGBA
//
//  Metal-backed view for rendering emulator frames at low latency.
//  Supports single-screen (GBA) and dual-screen (NDS) rendering.
//

import Combine
import UIKit
import MetalKit

/// Whether a game is producing frames right now: true between
/// `EmulatorMetalView.startRendering()` and `stopRendering()`, false while the
/// game is paused (the menu, a sheet over it, the app in the background).
///
/// It exists for the animated grounds (`LibraryLandscapeBackground`), and the
/// reason is measured, not supposed (2026-09-23). The game is a full-screen
/// cover over the library, so the library, and the game page when a game is
/// started from it, stay alive underneath, and their grounds kept animating
/// behind the game: a 30 Hz `TimelineView` whose body runs on the MAIN thread,
/// the same thread `draw(in:)` advances the emulator on. With headroom nobody
/// saw it. Without it the emulator fell behind: frames bunched up and the
/// sound broke at 1x (a player on an iPhone 12 Pro, a German review, then
/// reproduced on an iPhone 14 Pro in Low Power Mode, where Reduce Motion or
/// the Classic look each made it go away). Every ground reads this and holds
/// still while it is true.
final class EmulationActivity: ObservableObject {
    static let shared = EmulationActivity()

    @Published private(set) var isRunning = false

    /// Main thread only (the rendering calls come from UIKit's lifecycle).
    /// Assigns only on a change, so a repeated start or stop re-renders nothing.
    func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
    }
}

final class EmulatorMetalView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    /// Boot pipelines: the trivial nearest fragment, compiled synchronously
    /// (near-instant) so the first frame shows immediately.
    private var pipelineState: MTLRenderPipelineState?
    private var ndsPipelineState: MTLRenderPipelineState?
    /// Filter pipelines: the heavier filteredFragment, compiled ASYNC at setup
    /// (its PSO build was delaying the first NDS frames ~0.5s behind the dress
    /// — device report, 2026-07-24). Until ready, a filtered game renders
    /// plain for a beat and the filter pops in — never the other way around.
    private var filteredPipelineState: MTLRenderPipelineState?
    private var filteredNDSPipelineState: MTLRenderPipelineState?
    private var ndsVertexBuffer: MTLBuffer?
    private var textures: [MTLTexture] = []
    /// The texture holding the newest picture: the one presented, and the one
    /// the external-display mirror shows.
    private var latestTextureIndex = 0
    /// Three, not two, because the picture is presented on another thread (see
    /// `FramePresenter`): one holds the newest picture, one may still be read
    /// by the GPU for a presentation in flight, and the third is always free to
    /// write the next picture into, so the emulation never waits for either.
    private static let textureCount = 3
    /// Presents the pictures, off the main thread. Created in `setup()`.
    private var presenter: FramePresenter?
    private weak var session: EmulatorSession?

    private var isEmulatorRunning = false
    private var isDualScreen = false
    /// When true, NDS screens are rendered side-by-side (landscape mode)
    var ndsSideBySide = false { didSet { if isDualScreen { rebuildNDSVertices() } } }
    var speedMultiplier: Double = 1.0 {
        // A reading taken across a speed change would compare frames run at
        // one speed with the target of another.
        didSet { if speedMultiplier != oldValue { resetPerformance() } }
    }

    // MARK: - The performance readout (2026-09-23)
    //
    // The pause menu shows what the frame loop actually achieved, because the
    // 1.3.1 stutter report cost an investigation where a number would have
    // done: a player could have sent "40 frames of 59.7, 4 ms of 16.7" and the
    // two halves say different things. Frames per second below the target
    // with a small frame time means something ELSE held the main thread (what
    // 1.3.1's animated grounds did); a frame time near the budget means the
    // game itself is too heavy for the phone.

    /// What the pause menu shows. Rates and times are at the chosen speed.
    struct PerformanceReading {
        let framesPerSecond: Double
        let targetFramesPerSecond: Double
        /// Time `draw(in:)` spent per emulated frame: running the core and
        /// uploading the picture. Presenting it happens on another thread
        /// (`FramePresenter`) and is not part of the emulation's cost.
        let frameMilliseconds: Double
        let budgetMilliseconds: Double
    }

    private var performanceWallTime: CFTimeInterval = 0
    private var performanceFrames: Double = 0
    private var performanceWorkTime: CFTimeInterval = 0

    /// Past this much play time the three sums are halved together, so the
    /// reading leans on the last few seconds rather than the whole session and
    /// a slow start (the load, a first cutscene) fades out of it.
    private static let performanceWindow: CFTimeInterval = 6

    private func recordPerformance(elapsed: CFTimeInterval, frames: Int, work: CFTimeInterval) {
        performanceWallTime += elapsed
        performanceFrames += Double(frames)
        performanceWorkTime += work
        if performanceWallTime > Self.performanceWindow {
            performanceWallTime /= 2
            performanceFrames /= 2
            performanceWorkTime /= 2
        }
    }

    // MARK: How smooth the whole sitting was (2026-09-27)
    //
    // The reading above leans on the last few seconds, which is right for the
    // pause menu and wrong for "was this sitting smooth?": at the quit it only
    // describes the moments before it. So two more sums run for the whole
    // sitting, at normal speed only (fast-forward has its own target): the
    // wall time, and the emulated time the loop actually produced. Their ratio
    // falls below 1 for both things a player feels, a core too slow to keep up
    // and a stall whose time is thrown away. Read by the review ask
    // (`PromptTracker.directReviewRequestTrigger`), which must not follow a
    // sitting that stuttered: the Nintendo 64 runs without JIT, and a heavy
    // game on an older phone is exactly the sitting not to ask after.
    private var sittingWallTime: CFTimeInterval = 0
    private var sittingEmulatedTime: CFTimeInterval = 0

    /// Below this much measured play the ratio says nothing, and is nil.
    private static let sittingMinimum: CFTimeInterval = 60

    /// Emulated time over wall time for the sitting so far, at normal speed:
    /// 1 is full speed throughout. nil until a minute of it has been measured.
    var sittingSmoothness: Double? {
        guard sittingWallTime >= Self.sittingMinimum else { return nil }
        return sittingEmulatedTime / sittingWallTime
    }

    private func resetPerformance() {
        performanceWallTime = 0
        performanceFrames = 0
        performanceWorkTime = 0
    }

    /// The reading over the last few seconds of play; nil before one second
    /// of it, which is too little to say anything.
    var performanceReading: PerformanceReading? {
        guard performanceWallTime >= 1, performanceFrames > 0, let session else { return nil }
        let duration = session.frameDuration / max(0.25, speedMultiplier)
        return PerformanceReading(
            framesPerSecond: performanceFrames / performanceWallTime,
            targetFramesPerSecond: 1 / duration,
            frameMilliseconds: performanceWorkTime / performanceFrames * 1000,
            budgetMilliseconds: duration * 1000)
    }

    /// Optional rolling clip recorder, fed one frame image per produced frame.
    /// It down-samples internally to its low "gif" fps, so the image is only
    /// built a few times per second. Owned/assigned by EmulatorViewController.
    weak var clipRecorder: GameplayClipRecorder?

    /// The live display filter (per-game, Pro). `.none` renders byte-identical
    /// to the historical plain-nearest path. Set by EmulatorViewController at
    /// start and on selection; read per draw (a uniform, no pipeline rebuild).
    /// Setting a real filter lazily kicks the filter-pipeline compile — boot
    /// never pays for the filter shader unless a filter is actually in play.
    var videoFilter: VideoFilter = .none {
        didSet { if videoFilter != .none { buildFilterPipelinesIfNeeded() } }
    }

    /// Swift twin of the shader's FilterUniforms — keep layouts in sync.
    /// Internal because the external-display mirror sends the same bytes;
    /// two copies of a struct that must match a shader layout would drift.
    struct FilterUniforms {
        var filterType: UInt32
        var screenCount: UInt32
        var gameSize: SIMD2<Float>
        /// The same fraction the vertex stage scales its texture coordinates by.
        /// The CRT filter needs it: that one normalises uv into -1...1 to warp
        /// it, and uv only reaches 1 on a console whose picture fills its
        /// texture. Every console but the PlayStation passes (1, 1) here.
        var uvScale: SIMD2<Float>
    }

    // Frame timing now comes from the core (`session.frameDuration`). The GBA
    // figure it replaced, 16,777,216 Hz / 280,896 cycles = 59.7275 fps, is what
    // MGBABridge still returns, so its pacing is unchanged; the DS returns its
    // own 59.8261 since 1.3.3 (MelonDSBridge.framesPerSecond says why).
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
        if let queue = commandQueue, let metalLayer = layer as? CAMetalLayer {
            presenter = FramePresenter(layer: metalLayer, commandQueue: queue)
        }
        setupPipelines(device: device)
    }

    private func setupPipelines(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary() else {
            print("[Metal] Failed to load default library")
            return
        }

        // Boot pipelines only, SYNC — the trivial nearest fragment compiles
        // near-instantly. The filter pipelines are built lazily on demand
        // (buildFilterPipelinesIfNeeded), never at boot.
        let plainFrag = library.makeFunction(name: "fragmentShader")

        // Single-screen pipeline (GBA)
        let singleDesc = MTLRenderPipelineDescriptor()
        singleDesc.vertexFunction = library.makeFunction(name: "vertexShader")
        singleDesc.fragmentFunction = plainFrag
        singleDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        pipelineState = try? device.makeRenderPipelineState(descriptor: singleDesc)

        // Dual-screen pipeline (NDS) — uses vertex buffer. Alpha blending carries
        // a preset's per-screen opacity; at the default alpha of 1.0 the blend
        // is an exact pass-through, so the default rendering is unchanged.
        let dualDesc = MTLRenderPipelineDescriptor()
        dualDesc.vertexFunction = library.makeFunction(name: "ndsVertexShader")
        dualDesc.fragmentFunction = plainFrag
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

    /// True once the async filter-pipeline builds were kicked off (idempotence
    /// guard; the states themselves land later).
    private var filterPipelinesRequested = false

    /// Compile the filter pipelines, ASYNC, on demand — first time a real
    /// filter is set. Boot never waits on (or contends with) the heavy filter
    /// shader: melonDS's CPU-hungry first frames were still being slowed by
    /// the boot-time async compiles (a second NDS device report), and a
    /// no-filter user never needs them at all. Until they land, a filtered
    /// game renders plain and the filter pops in. Completion runs on an
    /// arbitrary thread; assign on main, where draw() runs.
    private func buildFilterPipelinesIfNeeded() {
        guard !filterPipelinesRequested, let device = self.device,
              let library = device.makeDefaultLibrary() else { return }
        filterPipelinesRequested = true
        let filterFrag = library.makeFunction(name: "filteredFragment")

        let singleDesc = MTLRenderPipelineDescriptor()
        singleDesc.vertexFunction = library.makeFunction(name: "vertexShader")
        singleDesc.fragmentFunction = filterFrag
        singleDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        device.makeRenderPipelineState(descriptor: singleDesc) { [weak self] state, _ in
            DispatchQueue.main.async { self?.filteredPipelineState = state }
        }

        let dualDesc = MTLRenderPipelineDescriptor()
        dualDesc.vertexFunction = library.makeFunction(name: "ndsVertexShader")
        dualDesc.fragmentFunction = filterFrag
        dualDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        dualDesc.colorAttachments[0].isBlendingEnabled = true
        dualDesc.colorAttachments[0].rgbBlendOperation = .add
        dualDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        dualDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        dualDesc.colorAttachments[0].alphaBlendOperation = .add
        dualDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        dualDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        device.makeRenderPipelineState(descriptor: dualDesc) { [weak self] state, _ in
            DispatchQueue.main.async { self?.filteredNDSPipelineState = state }
        }
    }

    // MARK: - Public API

    func attach(session: EmulatorSession) {
        self.session = session
        resetPerformance()
        sittingWallTime = 0
        sittingEmulatedTime = 0
        isDualScreen = session.hasTouchScreen

        guard let device = self.device else { return }
        // The core declares its own byte order. This used to read
        // `session.hasTouchScreen`, which gave the same answer only because the
        // DS was the single BGRA core; Mesen is BGRA and has no touch screen.
        let pixelFormat: MTLPixelFormat = session.usesBGRAPixelOrder ? .bgra8Unorm : .rgba8Unorm
        // Allocated at the core's MAXIMUM, which for the three cartridge cores
        // is exactly the live picture and changes nothing. The PlayStation is
        // the one that differs: its picture changes size mid-game and a texture
        // cannot, so it draws into the top-left of a texture sized for its
        // largest mode and the vertex stage scales the coordinates down.
        let texture = session.textureSize
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        textures = (0..<Self.textureCount).compactMap { _ in device.makeTexture(descriptor: desc) }
        latestTextureIndex = 0

        if isDualScreen {
            rebuildNDSVertices()
        }
    }

    func startRendering() {
        isEmulatorRunning = true
        EmulationActivity.shared.setRunning(true)
        lastDrawTime = CACurrentMediaTime()
        // `session` is weak here, unlike in draw() where it is already unwrapped.
        // The fallback is the GBA figure the accumulator was seeded with before.
        let duration = session?.frameDuration ?? (280896.0 / 16777216.0)
        timeAccumulator = duration
        presenter?.setAllowed(true)
        startClock(fps: duration > 0 ? 1.0 / duration : 60)
    }

    func stopRendering() {
        // First, so no presentation starts once the game is paused or the app
        // is on its way to the background, where the GPU may not be used.
        presenter?.setAllowed(false)
        isEmulatorRunning = false
        EmulationActivity.shared.setRunning(false)
        isPaused = true
        stopOwnClock()
    }

    // MARK: - The frame clock
    //
    // MTKView's own display link runs at `preferredFramesPerSecond`, which the system rounds to
    // a whole division of the display's refresh rate. That is right for every console we shipped
    // before 1.2.5, because all of them run at 59.7275 fps and a 60 Hz refresh carries one
    // emulated frame per tick.
    //
    // A PAL cartridge does not. A European Super Nintendo or NES runs at 50.007 fps, and against
    // a 60 Hz clock the pacing accumulator can only produce five new frames in every six ticks:
    // one refresh in six shows the picture again. The speed is exactly right and the motion is
    // not, which is what "laggy" means when a scrolling game stutters six times a second. It
    // gets worse, not better, when the screen is made larger.
    //
    // So a game whose rate is nowhere near 60 gets a clock of its own: a CADisplayLink asking
    // for the cartridge's own rate. On a variable-refresh display that is delivered, every tick
    // carries exactly one frame, and the repeats disappear. On a fixed 60 Hz display the system
    // cannot honour it and runs at 60, which is precisely today's behaviour, so nothing is worse
    // anywhere. The four consoles that shipped before this never take the path at all.

    /// How far a game's rate must be from 60 before it gets its own clock. 59.7275 (GBA, GB/GBC),
    /// 59.8261 (NDS) and 60.0988 (NTSC SNES/NES) stay on MTKView's; 50.007 (PAL) does not.
    private static let ownClockThreshold: Double = 2

    /// Retains the view weakly, because a CADisplayLink retains its target and the view owns the
    /// link. Without it the pair keeps each other alive and the clock outlives the game.
    private final class ClockProxy: NSObject {
        weak var view: EmulatorMetalView?
        init(_ view: EmulatorMetalView) { self.view = view; super.init() }
        @objc func tick(_ link: CADisplayLink) {
            #if DEBUG
            MainThreadProbe.linkInterval = link.targetTimestamp - link.timestamp
            #endif
            view?.ownClockTick()
        }
    }

    private var ownClock: CADisplayLink?

    private func startClock(fps: Double) {
        stopOwnClock()
        guard abs(fps - 60) > Self.ownClockThreshold else {
            isPaused = false          // MTKView's own link, exactly as before
            return
        }
        let link = CADisplayLink(target: ClockProxy(self), selector: #selector(ClockProxy.tick(_:)))
        let rate = Float(fps)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        ownClock = link
        isPaused = true               // MTKView's link stays off; ours drives instead
    }

    private func stopOwnClock() {
        ownClock?.invalidate()
        ownClock = nil
    }

    fileprivate func ownClockTick() {
        guard isEmulatorRunning else { return }
        draw()
    }

    deinit {
        ownClock?.invalidate()
        // A view released while still running must not leave the flag set, or
        // every animated ground would stay frozen after the game is gone.
        if isEmulatorRunning { EmulationActivity.shared.setRunning(false) }
    }

    // MARK: - External-display mirror
    //
    // The mirror is PRESENTATION ONLY. This view stays the emulation clock:
    // startRendering() unpauses it, its display link drives draw(in:), and
    // draw(in:) is what advances the core. A view on an AirPlay screen has no
    // dependable display link, so it must never be given that job. It only
    // ever encodes the texture this view last wrote.

    /// Everything the mirror needs to draw the current frame, resolved on the
    /// producer so pipeline selection can never diverge between the two views.
    struct MirrorFrame {
        let texture: MTLTexture
        let isDualScreen: Bool
        let pipeline: MTLRenderPipelineState
        /// The plain boot pipeline takes no FRAGMENT uniforms; only the
        /// filtered one does. Both take the vertex-stage `uvScale` below.
        let usesFilterUniforms: Bool
        let uniforms: FilterUniforms
        /// Fraction of the texture the live picture occupies. (1, 1) for every
        /// console but the PlayStation; see `EmulatorSession.textureUVScale`.
        let uvScale: SIMD2<Float>
    }

    /// Shared with the mirror: one GPU on iOS, so one queue is enough.
    var mirrorCommandQueue: MTLCommandQueue? { commandQueue }

    /// The mirror MUST match this, because the pipeline states below were
    /// compiled against it; a different format makes them invalid for it.
    var mirrorPixelFormat: MTLPixelFormat { colorPixelFormat }

    /// Native frame size of the running game, so a mirror can letterbox
    /// itself for single-screen consoles. nil when nothing is attached.
    var mirrorGameSize: CGSize? {
        guard let session else { return nil }
        return CGSize(width: session.screenWidth, height: session.totalBufferHeight)
    }

    var mirrorIsDualScreen: Bool { isDualScreen }

    /// nil while nothing is running, so the mirror shows the idle screen
    /// instead of a stale last frame.
    func mirrorFrame() -> MirrorFrame? {
        guard isEmulatorRunning, let session, textures.count == Self.textureCount else { return nil }
        let wantsFilter = videoFilter != .none
        let filtered = wantsFilter
            ? (isDualScreen ? filteredNDSPipelineState : filteredPipelineState)
            : nil
        guard let pipeline = filtered ?? (isDualScreen ? ndsPipelineState : pipelineState) else {
            return nil
        }
        return MirrorFrame(
            texture: textures[latestTextureIndex],
            isDualScreen: isDualScreen,
            pipeline: pipeline,
            usesFilterUniforms: filtered != nil,
            uniforms: FilterUniforms(
                filterType: videoFilter.metalIndex,
                screenCount: UInt32(isDualScreen ? 2 : 1),
                gameSize: SIMD2(Float(session.textureSize.width), Float(session.textureSize.height)),
                uvScale: SIMD2(session.textureUVScale.0, session.textureUVScale.1)),
            uvScale: SIMD2(session.textureUVScale.0, session.textureUVScale.1))
    }

    // MARK: - NDS Vertex Geometry

    /// One vertex of a screen quad. Internal, so the external-display mirror
    /// can build its own buffer from exactly the same geometry.
    struct ScreenVertex {
        var px: Float; var py: Float; var u: Float; var v: Float; var a: Float
    }

    /// Pure geometry: the two NDS quads for a view of the given size. Both
    /// this view and the external-display mirror call it, so the TV layout
    /// can never drift away from the phone's.
    static func ndsScreenVertices(viewW: Float, viewH: Float,
                                  sideBySide: Bool,
                                  topScreenRatio: Float,
                                  custom: (top: CustomScreenQuad, bottom: CustomScreenQuad)?,
                                  swapped: Bool) -> [ScreenVertex] {
        typealias V = ScreenVertex
        let viewAspect = viewW / viewH
        let screenAspect: Float = 256.0 / 192.0  // 4:3

        // Texture V coordinates: top screen = 0.0–0.5, bottom screen = 0.5–1.0
        // When swapped, the "first" quad shows the bottom texture and vice versa
        let firstVMin: Float = swapped ? 0.5 : 0.0
        let firstVMax: Float = swapped ? 1.0 : 0.5
        let secondVMin: Float = swapped ? 0.0 : 0.5
        let secondVMax: Float = swapped ? 0.5 : 1.0

        if let custom {
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
            return quad(custom.top, vMin: firstVMin, vMax: firstVMax)
                + quad(custom.bottom, vMin: secondVMin, vMax: secondVMax)

        } else if sideBySide {
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

            return [
                // Left screen (first screen)
                V(px: leftL, py: leftBot, u: 0, v: firstVMax, a: 1), V(px: leftR, py: leftBot, u: 1, v: firstVMax, a: 1), V(px: leftL, py: leftTop, u: 0, v: firstVMin, a: 1),
                V(px: leftL, py: leftTop, u: 0, v: firstVMin, a: 1), V(px: leftR, py: leftBot, u: 1, v: firstVMax, a: 1), V(px: leftR, py: leftTop, u: 1, v: firstVMin, a: 1),
                // Right screen (second screen = touch)
                V(px: rightL2, py: rightBot, u: 0, v: secondVMax, a: 1),   V(px: rightR2, py: rightBot, u: 1, v: secondVMax, a: 1),   V(px: rightL2, py: rightTop, u: 0, v: secondVMin, a: 1),
                V(px: rightL2, py: rightTop, u: 0, v: secondVMin, a: 1),   V(px: rightR2, py: rightBot, u: 1, v: secondVMax, a: 1),   V(px: rightR2, py: rightTop, u: 1, v: secondVMin, a: 1),
            ]

        } else {
            // === Stacked (portrait): screens sized according to topScreenRatio ===
            let topRatio = topScreenRatio
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

            return [
                // Top quad (first screen)
                V(px: topL, py: topBottom, u: 0, v: firstVMax, a: 1), V(px: topR, py: topBottom, u: 1, v: firstVMax, a: 1), V(px: topL, py: topTop, u: 0, v: firstVMin, a: 1),
                V(px: topL, py: topTop,    u: 0, v: firstVMin, a: 1), V(px: topR, py: topBottom, u: 1, v: firstVMax, a: 1), V(px: topR, py: topTop, u: 1, v: firstVMin, a: 1),
                // Bottom quad (second screen = touch)
                V(px: botL, py: botBottom, u: 0, v: secondVMax, a: 1), V(px: botR, py: botBottom, u: 1, v: secondVMax, a: 1), V(px: botL, py: botTop, u: 0, v: secondVMin, a: 1),
                V(px: botL, py: botTop,    u: 0, v: secondVMin, a: 1), V(px: botR, py: botBottom, u: 1, v: secondVMax, a: 1), V(px: botR, py: botTop, u: 1, v: secondVMin, a: 1),
            ]
        }
    }

    /// Build vertex data for two quads rendering both NDS screens.
    /// Supports two modes: stacked (portrait) and side-by-side (landscape).
    /// Each screen maintains its native 4:3 aspect ratio.
    private func rebuildNDSVertices() {
        guard let device = self.device else { return }
        let vertices = EmulatorMetalView.ndsScreenVertices(
            viewW: Float(bounds.width > 0 ? bounds.width : 256),
            viewH: Float(bounds.height > 0 ? bounds.height : 384),
            sideBySide: ndsSideBySide,
            topScreenRatio: ndsTopScreenRatio,
            custom: ndsCustomScreens,
            swapped: UserDefaults.standard.bool(forKey: "ndsSwapScreens"))
        ndsVertexBuffer = device.makeBuffer(bytes: vertices,
                                            length: MemoryLayout<ScreenVertex>.stride * vertices.count,
                                            options: .storageModeShared)
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

        // The core says how long its frame is. For GBA and GB/GBC that is still
        // 59.7275 fps, byte for byte, because that bridge returns the constant
        // this line used to hardcode; the DS says its own 59.8261; a PAL SNES
        // or NES cartridge runs at 50, and pacing it at 59.7275 plays it a
        // fifth too fast.
        let frameDuration = session.frameDuration
        let effectiveDuration = frameDuration / max(0.25, speedMultiplier)

        // How much lateness is CAUGHT UP rather than dropped: as many frames as
        // the loop below may run in one call. Anything later than that is a real
        // stall (a sheet, a hitch the core cannot recover in one go) and is
        // dropped, so the game resumes instead of racing.
        //
        // It was three frames (60 ms at 50 fps), set when every game ran on a
        // steady 60 Hz clock and a frame cost a millisecond, and it turned
        // ordinary clock jitter into lost time (measured 2026-09-26, iPhone 14
        // Pro, Ocarina of Time): iOS paces our clock at 48 Hz, and at 30 Hz while
        // the player taps quickly; a call that runs two frames outlasts its tick
        // and iOS skips the next one instead of queueing it, so a 42 ms gap on
        // top of the time already owed crossed 60 ms and was thrown away, heard
        // as the sound cutting out. The core had the headroom to catch up (8 ms
        // a frame against 20); only this cap stopped it.
        //
        // The old floor stays for fast-forward, where eight frames are shorter
        // than three at normal speed; its behaviour there is unchanged.
        let maxFramesPerDraw = 8
        let capThreshold = max(frameDuration * 3, effectiveDuration * Double(maxFramesPerDraw))
        if timeAccumulator > capThreshold {
            #if DEBUG
            MainThreadProbe.droppedSeconds += timeAccumulator - effectiveDuration
            MainThreadProbe.dropCount += 1
            #endif
            timeAccumulator = effectiveDuration
        }
        #if DEBUG
        MainThreadProbe.frameGap(elapsed, now: now)
        #endif

        // Skip the audio drain only while muted (saves CPU — notably at high
        // speeds, which auto-mute by default). When the user keeps sound on, we
        // drain at every speed so fast-forward plays its (sped-up) audio.
        session.skipAudio = session.isAudioMuted

        var didRunFrame = false
        var framesThisDraw = 0
        while timeAccumulator >= effectiveDuration && framesThisDraw < maxFramesPerDraw {
            session.runFrame()
            timeAccumulator -= effectiveDuration
            didRunFrame = true
            framesThisDraw += 1
        }
        if speedMultiplier == 1 {
            sittingWallTime += elapsed
            sittingEmulatedTime += Double(framesThisDraw) * frameDuration
        }
        // Recorded on the way out, whichever return below is taken, so the
        // upload counts as part of the frame's cost.
        defer {
            recordPerformance(elapsed: elapsed, frames: framesThisDraw,
                              work: CACurrentMediaTime() - now)
            #if DEBUG
            MainThreadProbe.drawLongest = max(MainThreadProbe.drawLongest, CACurrentMediaTime() - now)
            #endif
        }

        guard textures.count == Self.textureCount else { return }

        // One wait per DRAWN frame, for the core that needs one (see EmulatorBridge.h). It sits
        // here rather than inside runFrame because the loop above can run up to 8 emulated frames
        // and only the last one's picture is ever uploaded: waiting inside the loop would have
        // paid the decode thread's cost for seven pictures nobody sees, which is exactly the kind
        // of throughput a fast-forward has none of to spare.
        if didRunFrame { session.awaitDisplayFrame() }

        // Only upload when a new frame was produced, and into a texture nobody
        // is reading: not the newest picture, and not one a presentation still
        // in flight has handed to the GPU. With three there is always one. If
        // the display has fallen so far behind that all three are taken, this
        // picture is skipped; the emulation never waits for the display.
        if didRunFrame, let frameBuffer = session.frameBuffer() {
            let inUse = presenter?.texturesInUse() ?? [:]
            if let target = (0..<textures.count).first(where: {
                $0 != latestTextureIndex && inUse[$0, default: 0] == 0
            }) {
                // Clamped to the stride the source rows actually have. `replace`
                // reads width x 4 bytes out of every bytesPerRow-long row, so a
                // width past the stride would read into the NEXT row rather than
                // fail. No core reports it, and `textureSize` already guards the
                // texture side; this guards the source side for the same cost.
                let w = min(session.screenWidth, session.bufferStride)
                let h = min(session.totalBufferHeight, session.textureSize.height)
                let bytesPerRow = session.bufferStride * 4
                let region = MTLRegionMake2D(0, 0, w, h)
                textures[target].replace(region: region, mipmapLevel: 0,
                                         withBytes: frameBuffer,
                                         bytesPerRow: bytesPerRow)
                latestTextureIndex = target
            }

            // Feed the rolling clip recorder. It down-samples to its low gif fps
            // by wall-clock, so the clip is the player's actual on-screen
            // experience (their chosen speed), and createScreenshotImage() runs
            // only a few times per real second.
            clipRecorder?.captureIfDue({ session.createScreenshotImage() },
                                       pixelGrid: { session.filterPixelGrid(for: $0) })
        }

        // PRESENTATION IS HANDED OFF, never done here (2026-09-26).
        //
        // It used to be done here, on the main thread, and `currentDrawable`
        // blocks until the display gives a drawable back. Measured on an iPhone
        // 14 Pro (Ocarina of Time, PAL): 11 ms of every 20 ms frame spent in that
        // wait, 17 ms while the player tapped quickly, because iOS changes the
        // display's cadence around touches (it granted 48 Hz to a 50 Hz request,
        // and 30 Hz during bursts). Emulation shares this thread, so the display's
        // pace became the emulation's: past three frames the accumulator above
        // drops the time, and a burst of taps was heard as the sound breaking.
        // The emulation now never waits for the display; a slow display skips
        // pictures instead, which is the only thing a slow display can do anyway.
        //
        // Everything the presentation reads is resolved HERE, on the main thread,
        // into one value, so the other thread touches no state of this view.
        guard let presenter else { return }
        let wantsFilter = videoFilter != .none
        let filtered = wantsFilter
            ? (isDualScreen ? filteredNDSPipelineState : filteredPipelineState)
            : nil
        guard let pipeline = filtered ?? (isDualScreen ? ndsPipelineState : pipelineState) else { return }
        if isDualScreen && ndsVertexBuffer == nil { return }
        presenter.submit(FramePresenter.Frame(
            texture: textures[latestTextureIndex],
            textureIndex: latestTextureIndex,
            pipeline: pipeline,
            usesFilterUniforms: filtered != nil,
            uniforms: FilterUniforms(
                filterType: videoFilter.metalIndex,
                screenCount: UInt32(isDualScreen ? 2 : 1),
                gameSize: SIMD2(Float(session.textureSize.width), Float(session.textureSize.height)),
                uvScale: SIMD2(session.textureUVScale.0, session.textureUVScale.1)),
            uvScale: SIMD2(session.textureUVScale.0, session.textureUVScale.1),
            ndsVertexBuffer: isDualScreen ? ndsVertexBuffer : nil,
            clearColor: clearColor))
        #if DEBUG
        MainThreadProbe.drawableLongest = max(MainThreadProbe.drawableLongest,
                                              presenter.takeLongestDrawableWait())
        #endif
    }
}

/// Presents the emulator's pictures on a thread of its own.
///
/// The main thread writes a picture into a texture and hands it here; this
/// takes the newest one, waits for a drawable (the wait that used to hold the
/// emulation, see `draw(in:)`), encodes and presents it. Frames handed over
/// while a presentation is still waiting replace one another, so only the
/// newest is ever presented: a display that falls behind skips pictures and
/// never slows the game.
///
/// It touches nothing of the view but the layer, whose `nextDrawable()` may be
/// called from any thread. Everything else arrives resolved in a `Frame`.
private final class FramePresenter {
    struct Frame {
        let texture: MTLTexture
        let textureIndex: Int
        let pipeline: MTLRenderPipelineState
        let usesFilterUniforms: Bool
        let uniforms: EmulatorMetalView.FilterUniforms
        let uvScale: SIMD2<Float>
        /// Set for the dual-screen layout, nil for a single screen.
        let ndsVertexBuffer: MTLBuffer?
        let clearColor: MTLClearColor
    }

    private let layer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let queue = DispatchQueue(label: "com.retropal.frame-presenter", qos: .userInteractive)
    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    private var pending: Frame?
    private var draining = false
    private var allowed = false
    /// How many submitted command buffers may still read each texture. Counted,
    /// not a set: the newest picture is presented again on every tick that runs
    /// no frame, so one texture can be in several presentations at once.
    private var inUse: [Int: Int] = [:]
    private var longestDrawableWait: CFTimeInterval = 0

    init(layer: CAMetalLayer, commandQueue: MTLCommandQueue) {
        self.layer = layer
        self.commandQueue = commandQueue
    }

    /// Off while the game is paused or leaving the foreground: a frame waiting
    /// is dropped and none starts.
    func setAllowed(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        allowed = on
        if !on { pending = nil }
    }

    func texturesInUse() -> [Int: Int] {
        lock.lock(); defer { lock.unlock() }
        return inUse
    }

    /// The longest wait for a drawable since the last call (the DEBUG probe).
    func takeLongestDrawableWait() -> CFTimeInterval {
        lock.lock(); defer { lock.unlock() }
        let value = longestDrawableWait
        longestDrawableWait = 0
        return value
    }

    func submit(_ frame: Frame) {
        lock.lock()
        guard allowed else { lock.unlock(); return }
        pending = frame
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard allowed, let frame = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            inUse[frame.textureIndex, default: 0] += 1
            lock.unlock()
            present(frame)
        }
    }

    private func release(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        let count = (inUse[index] ?? 1) - 1
        inUse[index] = count > 0 ? count : nil
    }

    private func present(_ frame: Frame) {
        let waitStart = CACurrentMediaTime()
        let drawable = layer.nextDrawable()
        let waited = CACurrentMediaTime() - waitStart
        lock.lock()
        longestDrawableWait = max(longestDrawableWait, waited)
        // Paused while this thread waited: present nothing.
        let stillAllowed = allowed
        lock.unlock()

        guard stillAllowed, let drawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            release(frame.textureIndex)
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = frame.clearColor
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            release(frame.textureIndex)
            return
        }

        var uniforms = frame.uniforms
        var uvScale = frame.uvScale
        encoder.setRenderPipelineState(frame.pipeline)
        encoder.setFragmentTexture(frame.texture, index: 0)
        if let vertexBuffer = frame.ndsVertexBuffer {
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            if frame.usesFilterUniforms {
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EmulatorMetalView.FilterUniforms>.stride, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12)
        } else {
            // Bound for BOTH pipelines: the fullscreen-quad vertex shader
            // takes it, and the plain boot pipeline uses that same shader.
            encoder.setVertexBytes(&uvScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            if frame.usesFilterUniforms {
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EmulatorMetalView.FilterUniforms>.stride, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        let index = frame.textureIndex
        // The texture is free again once the GPU has finished reading it.
        commandBuffer.addCompletedHandler { [weak self] _ in self?.release(index) }
        commandBuffer.commit()
    }
}

#if DEBUG
/// DEBUG only: where the MAIN thread's time goes between emulated frames.
///
/// The emulation runs on the main thread (`draw(in:)`), so anything else the
/// main thread does, touches, haptics, UIKit, delays the next frame. A delay
/// longer than the pacing cap (three frames) is not caught up: the accumulator
/// is reset and that emulated time is dropped, which the player feels as a
/// freeze and the audio engine logs as padded silence. The per-frame figures
/// the bridges log cannot see this, because the time is spent outside a frame.
/// Reported every two seconds from `draw(in:)`, never from the touch path.
enum MainThreadProbe {
    static var hapticSeconds: CFTimeInterval = 0
    static var hapticLongest: CFTimeInterval = 0
    static var hapticCount = 0
    static var touchSeconds: CFTimeInterval = 0
    static var touchLongest: CFTimeInterval = 0
    static var longestGap: CFTimeInterval = 0
    static var droppedSeconds: CFTimeInterval = 0
    static var dropCount = 0
    static var windowStart: CFTimeInterval = 0
    /// The longest whole `draw(in:)`, and the longest wait for a drawable, which
    /// happens on the presenter's thread since the presentation moved there.
    static var drawLongest: CFTimeInterval = 0
    static var drawableLongest: CFTimeInterval = 0
    /// The cadence iOS actually granted our own clock (PAL games only; 0 when
    /// MTKView's link drives, i.e. every 60 Hz game).
    static var linkInterval: CFTimeInterval = 0
    /// The longest stretch the main run loop spent AWAKE (between waking and
    /// going back to sleep). A gap between frames with no long busy stretch
    /// means the thread was idle and the clock did not fire.
    static var busyLongest: CFTimeInterval = 0
    private static var awakeSince: CFTimeInterval = 0
    private static var observer: CFRunLoopObserver?

    private static func installObserverIfNeeded() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let o = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            let t = CACurrentMediaTime()
            if activity == .afterWaiting {
                awakeSince = t
            } else if awakeSince > 0 {
                busyLongest = max(busyLongest, t - awakeSince)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
    }

    static func haptic(since start: CFTimeInterval) {
        let d = CACurrentMediaTime() - start
        hapticSeconds += d; hapticLongest = max(hapticLongest, d); hapticCount += 1
    }

    static func touch(since start: CFTimeInterval) {
        let d = CACurrentMediaTime() - start
        touchSeconds += d; touchLongest = max(touchLongest, d)
    }

    static func frameGap(_ gap: CFTimeInterval, now: CFTimeInterval) {
        installObserverIfNeeded()
        longestGap = max(longestGap, gap)
        if windowStart == 0 { windowStart = now }
        guard now - windowStart >= 2 else { return }
        print(String(format: "[Main] longest gap between frames %.1f ms | %.0f ms of emulation dropped in %d stalls | haptics %d, %.1f ms total, longest %.1f ms | touch handling %.1f ms total, longest %.1f ms",
                     longestGap * 1000, droppedSeconds * 1000, dropCount,
                     hapticCount, hapticSeconds * 1000, hapticLongest * 1000,
                     touchSeconds * 1000, touchLongest * 1000))
        print(String(format: "[Main] longest draw %.1f ms | drawable wait on the presenter thread %.1f ms | longest main-thread busy stretch %.1f ms | own clock interval %.1f ms",
                     drawLongest * 1000, drawableLongest * 1000, busyLongest * 1000,
                     linkInterval * 1000))
        drawLongest = 0; drawableLongest = 0; busyLongest = 0
        hapticSeconds = 0; hapticLongest = 0; hapticCount = 0
        touchSeconds = 0; touchLongest = 0
        longestGap = 0; droppedSeconds = 0; dropCount = 0
        windowStart = now
    }
}
#endif
