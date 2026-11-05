//
//  EmulatorSession.swift
//  EmulateurGBA
//
//  Swift wrapper around MGBABridge. This is the only class
//  the rest of the app should use to interact with the emulator.
//

import Foundation
import CoreGraphics
import UIKit
import os

final class EmulatorSession: ObservableObject {
    /// The one queue every game's saves, state loads, shutdown and (the 3DS's)
    /// boot run on, whichever game screen asks: serial, so a game's work never
    /// overlaps the previous game's. Each screen had a queue of its own, and a
    /// game opened seconds after another (a widget, a file, a quick relaunch)
    /// could boot while the last one still saved or shut down, on the same
    /// core (audit, 2026-10-20: the 3DS's seconds-long boot and saves made it
    /// real). `LibraryView.makeBridge` waits for it before making a bridge.
    static let workQueue = DispatchQueue(label: "com.retropal.save-io", qos: .userInitiated)

    static let defaultScreenWidth = Int(GBAScreenWidth)    // 240
    static let defaultScreenHeight = Int(GBAScreenHeight)  // 160

    /// Actual screen dimensions (depends on loaded ROM: GBA=240x160, GB/GBC=160x144)
    var screenWidth: Int { Int(bridge.screenWidth) }
    var screenHeight: Int { Int(bridge.screenHeight) }
    /// Video buffer stride in pixels (may be larger than screenWidth)
    var bufferStride: Int { Int(bridge.bufferStride) }
    /// Total video buffer height (screenHeight for single-screen, 384 for NDS)
    var totalBufferHeight: Int { Int(bridge.totalBufferHeight) }
    /// The tallest buffer this core can report, which is what the renderer
    /// allocates. Equal to `totalBufferHeight` on the three cartridge cores;
    /// larger on the PlayStation, whose picture changes size mid-game.
    var maxBufferHeight: Int { Int(bridge.maxBufferHeight) }

    /// The size the renderer allocates its video texture at, in pixels.
    ///
    /// The `max` against the live size is a guard, not arithmetic anyone
    /// expects to fire: a core that reported a picture LARGER than the buffer
    /// it declared would make the renderer upload a region bigger than its own
    /// texture, which is a crash rather than a glitch. One `max` costs nothing
    /// and turns that into a harmlessly oversized texture.
    var textureSize: (width: Int, height: Int) {
        (max(bufferStride, screenWidth), max(maxBufferHeight, totalBufferHeight))
    }

    /// Fraction of the video texture the live picture actually occupies, as
    /// (width, height) in 0...1. The renderer multiplies its texture
    /// coordinates by this, so a console drawing into a corner of a larger
    /// texture is sampled correctly.
    ///
    /// It is exactly (1, 1) for GBA, GB/GBC, NDS, SNES and NES, because their
    /// picture and their buffer are the same size, so their rendering is
    /// untouched by its existence. Derived from `textureSize` rather than from
    /// the bridge directly, so the scale and the allocation cannot disagree.
    var textureUVScale: (Float, Float) {
        let size = textureSize
        return (Float(screenWidth) / Float(max(size.width, 1)),
                Float(totalBufferHeight) / Float(max(size.height, 1)))
    }
    /// Whether the current system has a touch screen (NDS bottom screen)
    var hasTouchScreen: Bool { bridge.hasTouchScreen }
    /// Shape the game should be DISPLAYED in: the buffer's own ratio for the
    /// four Nintendo handhelds, and 4:3 for SNES, NES and PS1, which all drew
    /// for a television (see `EmulatorBridge`).
    var displayAspect: CGFloat { bridge.displayAspect }
    /// Byte order of the frame buffer, which decides the renderer's pixel format.
    var usesBGRAPixelOrder: Bool { bridge.usesBGRAPixelOrder }
    /// How long one emulated frame should take. Constant for the four Nintendo
    /// handhelds; a PAL SNES or NES cartridge runs at 50 and a PAL disc at 50
    /// too, so on those three the core answers.
    var frameDuration: CFTimeInterval {
        let fps = bridge.framesPerSecond
        return fps > 1 ? 1.0 / fps : 280896.0 / 16777216.0
    }

    private let bridge: any EmulatorBridge
    private var audioEngine: EmulatorAudioEngine?
    private(set) var saveStateManager: SaveStateManager?

    private(set) var isRunning = false
    private(set) var isROMLoaded = false

    init(bridge: any EmulatorBridge = MGBABridge()) {
        self.bridge = bridge
    }

    // MARK: - ROM Management

    /// ROM basename of the GBA game mounted in slot 2 (NDS dual-slot), nil
    /// when none. Set by `configureGBASlot2` before `loadROM`; folded into
    /// the live-session basenames so the iCloud battery mirror also leaves
    /// the mounted GBA game's .sav alone (the cart holds its save RAM live,
    /// and Pal Park writes to it).
    private var gbaSlot2Basename: String?

    /// Feed the analog sticks, each axis -1...1, **y positive DOWN**, which is
    /// what UIKit and libretro use. On the PlayStation they are the DualShock's
    /// two sticks. On the Nintendo 64 the left one is the control stick and the
    /// right one reaches the C buttons, which is how a modern pad's right stick
    /// plays an N64 game.
    ///
    /// A no-op on every other core, exactly as `configureGBASlot2` is a no-op
    /// off the DS: the protocol stays the cores' common contract and the
    /// console-specific surfaces are reached through a cast.
    ///
    /// No flip here. GameController is the one source that measures +1 as UP,
    /// so its flip lives at ITS boundary. Doing it here instead meant the touch
    /// path had to negate on the way in so this could negate back, and a value
    /// that passes through two negations to arrive unchanged is a sign error
    /// waiting for someone to remove one of them.
    ///
    /// `player` is 0-based (0 = player 1, the touch sticks' player), like
    /// `setKeys(_:player:)`.
    func setAnalogSticks(leftX: CGFloat, leftY: CGFloat, rightX: CGFloat, rightY: CGFloat,
                         player: Int = 0) {
        if let pcsx = bridge as? PCSXBridge {
            pcsx.setLeftStickX(Float(leftX), y: Float(leftY), player: player)
            pcsx.setRightStickX(Float(rightX), y: Float(rightY), player: player)
        } else if let n64 = bridge as? N64Bridge {
            n64.setStickX(Float(leftX), y: Float(leftY), player: player)
            n64.setCStickX(Float(rightX), y: Float(rightY), player: player)
        } else if let psp = bridge as? PSPBridge, player == 0 {
            // One player, one nub: the left stick's values; the right is
            // dropped, as the PSP has none.
            psp.setStickX(Float(leftX), y: Float(leftY))
        } else if let ctr = bridge as? CTRBridge, player == 0 {
            // One player: the circle pad is the left stick, the New 3DS's
            // C-stick the right one.
            ctr.setStickX(Float(leftX), y: Float(leftY))
            ctr.setCStickX(Float(rightX), y: Float(rightY))
        }
    }

    /// Press the PlayStation pad's ANALOG switch, on a player's pad (the touch
    /// controls can play player 2, `PlayAsPlayerTwo`). A no-op on every other core.
    func pressAnalogModeButton(player: Int = 0) {
        (bridge as? PCSXBridge)?.pressAnalogModeButton(forPlayer: player)
    }

    // MARK: - Discs (PlayStation only)

    /// Whether the loaded game holds more than one disc. False on every other
    /// console, whose games are one file from beginning to end.
    ///
    /// This is the ONLY condition the disc picker needs, and it is worth
    /// saying why, because the obvious second one ("are the other discs
    /// actually here?") is already answered. `DiscImportGroup` refuses to
    /// import a group whose parts are not all present: an `.m3u` naming three
    /// discs imports as one game with all three, or it is reported as a GAP
    /// and never becomes a library entry at all. So a multi-disc game that
    /// EXISTS is a multi-disc game whose discs are all on disk, and the core
    /// counting more than one image is proof of it.
    var isMultiDiscGame: Bool {
        (bridge as? PCSXBridge)?.isMultiDisc ?? false
    }

    /// The discs the core knows, in the order the playlist listed them. Empty
    /// for a single-disc game and for every other console.
    var discs: [PS1Disc] {
        (bridge as? PCSXBridge)?.discs ?? []
    }

    /// Index of the disc currently in the drive, 0-based.
    var currentDiscIndex: Int {
        Int((bridge as? PCSXBridge)?.currentDiscIndex ?? 0)
    }

    /// Swap the drive to another disc. The bridge does the full open-swap-close
    /// sequence, because a game watches for the lid and never sees an image
    /// changed underneath it, and it drops the rewind history, because the
    /// spinning disc is part of the state.
    ///
    /// Returns false when the core refuses, which the caller must surface
    /// rather than swallow: a silent failure here leaves the player looking at
    /// a game asking for a disc it did not get.
    @discardableResult
    func changeToDisc(at index: Int) -> Bool {
        guard let pcsx = bridge as? PCSXBridge else { return false }
        return pcsx.changeToDisc(at: UInt(index))
    }

    /// Mount a GBA game in the NDS slot 2 for the next `loadROM`. No-op on
    /// non-NDS bridges. `saveBasename` is the GBA game's battery-save key
    /// (`BatterySaveImporter.romBasename` of its stored filename).
    func configureGBASlot2(romPath: String, savePath: String, saveBasename: String) {
        guard let melon = bridge as? MelonDSBridge else { return }
        melon.configureGBASlotROMPath(romPath, savePath: savePath)
        gbaSlot2Basename = saveBasename
    }

    /// Console label for analytics, read from the ROM this session loaded.
    ///
    /// The existing values are deliberately unchanged: GB and GBC still report
    /// "gba" as they always have, because the signal set is frozen and altering
    /// a dimension's existing values would rewrite history on the dashboards.
    /// Each new console simply adds a value: "snes" and "nes" at 1.2.5, "ps1"
    /// with the PlayStation, "n64" with the Nintendo 64, "md" with the Mega Drive,
    /// "sms" and "gg" with the Master System and the Game Gear, "psp" with the
    /// PSP, "n3ds" with the Nintendo 3DS.
    private var analyticsSystem: String = "gba"

    /// Loads the game, then does on the main thread what must happen there.
    /// The core's half (`loadROMCore`) may run on any ONE thread at a time;
    /// the game screen runs it on its save queue, so the screen stays live
    /// while a heavy console boots (a 3DS took seconds, the UI frozen,
    /// 2026-10-20), and calls `finishLoadOnMain` after.
    func loadROM(at url: URL) -> Bool {
        let success = loadROMCore(at: url)
        if success { finishLoadOnMain(romPath: url.path) }
        return success
    }

    /// The main thread's part of a load: what reads the window (the 3DS's
    /// cameras and motion follow the interface's orientation) and what
    /// publishes to SwiftUI (RetroAchievements). After `loadROMCore`
    /// succeeded, before the game is started.
    func finishLoadOnMain(romPath: String) {
        // The 3DS's cameras and motion follow the interface's orientation.
        interfaceOrientationDidChange()
        // Start a RetroAchievements session (hashes the ROM, loads the set).
        // No-op unless RA is enabled and the user is logged in. A core
        // whose memory does not exist yet (the PSP, booting) is started
        // from `runFrame` once it does (`isMemoryReadable`).
        if bridge.isMemoryReadable?() ?? true {
            RetroAchievements.shared.startSession(self, romPath: romPath)
        } else {
            pendingAchievementsPath = romPath
        }
    }

    /// The core's part of a load: the file read, the core booted and run one
    /// frame, the session's state set. No UIKit, nothing published.
    func loadROMCore(at url: URL) -> Bool {
        // The PSP first: its `.iso` and `.pbp` are disc extensions below, and
        // only the file can say which console it is (`ROMSystemType.resolve`).
        switch ROMSystemType.resolve(url: url) == .psp ? "psp" : url.pathExtension.lowercased() {
        case "psp":         analyticsSystem = "psp"
        case "nds":         analyticsSystem = "nds"
        case "sfc", "smc":  analyticsSystem = "snes"
        case "nes":         analyticsSystem = "nes"
        case "z64", "n64", "v64": analyticsSystem = "n64"
        case "md", "gen", "smd":  analyticsSystem = "md"
        case "sms":         analyticsSystem = "sms"
        case "gg":          analyticsSystem = "gg"
        case "3ds", "cci", "cxi", "3dsx": analyticsSystem = "n3ds"
        // Every disc extension reports one value. The dimension names the
        // CONSOLE, and which container a player's copy happens to be in is a
        // different question that this signal was never asked.
        case let ext where ROMSystemType.discFileExtensions.contains(ext):
            analyticsSystem = "ps1"
        default:            analyticsSystem = "gba"
        }
        // Told BEFORE the load, because the core asks for it while loading and
        // the app's own `setSavePath` below runs after. Only the PlayStation has
        // anything to do with it.
        let romName = BatterySaveImporter.romBasename(forROMURL: url)
        let savePath = BatterySaveImporter.savePath(forRomBasename: romName)
        (bridge as? PCSXBridge)?.setSaveDirectory(savePath.deletingLastPathComponent().path)
        // The PSP's games save into a memory stick, a folder, which the core
        // reads while it initialises: one per game, under the same key as every
        // other save of that game (`BatterySaveImporter.pspMemoryStickFolder`).
        if let psp = bridge as? PSPBridge {
            psp.setMemoryStickDirectory(
                BatterySaveImporter.pspMemoryStickFolder(forRomBasename: romName).path)
        }
        // The 3DS keeps every game's saves inside the emulated console's own
        // SD card and NAND, one folder for the console (`ctrSystemFolder`),
        // read while the core loads.
        // Its cameras and motion are made here, before the load, because the
        // core can start a camera while it boots (`cameraHandler`, set by
        // CTRCamera's init, must exist by then); neither touches the window
        // until `finishLoadOnMain` gives them its orientation.
        if let ctr = bridge as? CTRBridge {
            ctr.setSystemDirectory(BatterySaveImporter.ctrSystemFolder.path)
            ctrTitleID = CTRSaveData.titleID(ofROMAt: url)
            // Live from now, BEFORE the boot: the core opens the game's save
            // folder while it boots (seconds, on the save queue), and an iCloud
            // pass must not swap the folder under it (audit, 2026-10-20), nor
            // be swapping it right now (`markActive` waits for that).
            CTRSaveSync.markActive(ctrTitleID.map { [$0] } ?? [])
            ctrMotion = CTRMotion(bridge: ctr)
            ctrCamera = CTRCamera(bridge: ctr)
        }

        // Telemetry only: whether the game had a battery save before its core
        // read it. See the check after `setSavePath` below.
        let hadBatterySave = FileManager.default.fileExists(atPath: savePath.path)

        let success = bridge.loadROM(atPath: url.path)
        if !success, bridge is CTRBridge { CTRSaveSync.activeTitleIDs = [] }
        if success {
            // Set battery save path BEFORE reset so existing .sav is loaded.
            // The path comes from BatterySaveImporter (single source of truth)
            // so the loader, the per-game save importer, and the path-lock test
            // can never drift apart and orphan a user's save.
            bridge.setSavePath(savePath.path)
            // A save the cartridge cannot hold is MOVED ASIDE by its core when
            // the path is set, to `<save>.sav.unread-<time>` beside it (the
            // Mega Drive's BlastEmBridge `loadSaveRAM`, the Master System /
            // Game Gear's MesenBridge `seedShadowFromCanonical`). Read from
            // that effect, so no bridge had to change.
            if hadBatterySave && ErrorTelemetry.batterySaveWasMovedAside(savePath) {
                Analytics.signal("save_failure", [
                    "kind": "battery_load",
                    "reason": SaveFailureReason.sizeMismatch.rawValue,
                    "system": analyticsSystem
                ])
            }
            // The core now holds this .sav open for the whole session (mGBA
            // retains its VFile; melonDS rewrites it as the game saves) — flag
            // it, plus the slot-2 GBA game's save when one is mounted, so the
            // iCloud battery mirror never touches a live file.
            var live: Set<String> = [romName]
            if let slot2 = gbaSlot2Basename { live.insert(slot2) }
            BatterySaveImporter.activeSessionBasenames = live
            CTRSaveSync.activeTitleIDs = ctrTitleID.map { [$0] } ?? []

            bridge.reset()
            // Run one frame so the game initializes SOUNDBIAS (audio rate)
            bridge.runFrame()
            isROMLoaded = true
            saveStateManager = SaveStateManager(romName: romName)
            loadedRomBasename = romName
            // Create audio engine AFTER reset+first frame so we get the actual
            // sample rate (game may set SOUNDBIAS to 65536 Hz during init)
            audioEngine = EmulatorAudioEngine(bridge: bridge)
            // Initialize rewind buffer at max capacity (35 seconds).
            // Frame count is gated by Pro status at rewind time, not buffer size.
            bridge.initRewind(35)
        }
        return success
    }

    // MARK: - Frame Execution

    /// The game whose RetroAchievements session waits for its console's memory
    /// to exist (`EmulatorBridge.isMemoryReadable`): set at load on the PSP,
    /// started and cleared by the first frame after which the memory reads.
    private var pendingAchievementsPath: String?

    /// Play the rewind ring holds since the last reset, in SIXTIETHS of a
    /// second: the unit `rewind(frames:)` is asked in (`seconds * 60`) and every
    /// bridge's `rewindFrames:` reads. Credited per emulated frame at the core's
    /// own rate, so a 50 Hz game's second counts sixty here, not fifty (it
    /// counted fifty until 2026-10-12: a PAL rewind fell short for the first
    /// ~42 s of a sitting and after every state load). Capped at 35 s.
    var rewindFramesAvailable: Double {
        rewindCreditLock.lock(); defer { rewindCreditLock.unlock() }
        return _rewindFramesAvailable
    }
    private var _rewindFramesAvailable: Double = 0
    /// The 3DS credits it on its emulation queue (`runsFramesOffMain`) while
    /// the main thread's rewind and the work queue's state load take from it.
    private let rewindCreditLock = NSLock()
    private func updateRewindCredit(_ change: (Double) -> Double) {
        rewindCreditLock.lock(); _rewindFramesAvailable = change(_rewindFramesAvailable); rewindCreditLock.unlock()
    }
    private static let rewindBufferCapacity: Double = 35 * 60

    /// Sixtieths of a second one emulated frame lasts at `fps`; one frame when
    /// the core gives no rate.
    static func rewindCredit(perFrameAt fps: Double) -> Double {
        fps > 1 ? 60.0 / fps : 1
    }

    /// Set to true to skip audio drain (used at high speeds to save CPU).
    /// Written by the thread that runs the frames: the main thread, or for
    /// the 3DS the emulation queue (`runFrames`), never both for one game.
    var skipAudio = false

    // MARK: - The 3DS's emulation loop (2026-10-20)
    //
    // Every console runs its frames on the main thread, inside the display's
    // tick (`EmulatorMetalView.draw`). A 3DS frame can take most of a second
    // (a pipeline compile, a module load), and for that long nothing else on
    // the main thread ran: the touch controls froze, the stick's knob stood
    // still under the thumb. Its frames run in a loop of their own instead,
    // paced on its own clock, which publishes each picture (a copy, under a
    // lock); the display's tick only uploads the latest one and never waits.
    //
    // The first version (the same day) handed the loop one batch per display
    // tick and waited for it: at 4x a batch (eight frames, ~36 ms) outlasted
    // the wait, its picture was not shown and the queue sat idle until the
    // next tick; he saw 4x play less smoothly than before. A loop with its own
    // clock never waits for the display, and the display never for it.
    //
    // Only the 3DS: the other cores' frames are a few milliseconds and some
    // of them expect their calls on the main thread.

    /// Whether this game's frames run on `emulationQueue` (the 3DS).
    var runsFramesOffMain: Bool { bridge is CTRBridge }

    /// The 3DS: its picture is two screens of different widths stacked in
    /// one frame (`CTRBridge`), which the CRT filter needs to know.
    var isCTR: Bool { bridge is CTRBridge }

    /// The loop's own queue: one frame at a time.
    let emulationQueue = DispatchQueue(label: "com.retropal.emulation", qos: .userInteractive)

    /// The latest picture the loop finished, copied out of the core's buffer
    /// (which the next frame overwrites). Its lock guards every field below.
    private let publishedLock = NSLock()
    private var publishedPixels: [UInt32] = []
    private var publishedWidth = 0
    private var publishedHeight = 0
    private var publishedStride = 0
    /// Incremented at every new picture; the display uploads only when it moved.
    private var publishedGeneration = 0

    /// The loop's controls: set on the main thread, read by the loop.
    private let loopLock = NSLock()
    private var loopStop = false
    private var loopSpeed: Double = 1
    private var loopSkipAudio = false
    private var loopDone: DispatchSemaphore?

    /// What the loop has run, for the readout and the sitting's smoothness
    /// (taken by the display tick, then zeroed).
    private var loopFramesRun = 0
    private var loopEmulatedTime: Double = 0

    /// Starts the loop (main thread). `frameDuration` is the core's frame.
    func startEmulationLoop(frameDuration: Double, speed: Double, skipAudio: Bool) {
        guard loopDone == nil else { return }
        loopLock.lock()
        loopStop = false
        loopSpeed = speed
        loopSkipAudio = skipAudio
        loopLock.unlock()
        let done = DispatchSemaphore(value: 0)
        loopDone = done
        emulationQueue.async { [self] in
            runEmulationLoop(frameDuration: frameDuration)
            done.signal()
        }
    }

    /// Stops the loop and waits for its frame in progress (main thread):
    /// nothing touches the core after this returns, so a save, a state load
    /// or a shutdown that follows never meets a frame.
    func stopEmulationLoop() {
        guard let done = loopDone else { return }
        loopLock.lock(); loopStop = true; loopLock.unlock()
        done.wait()
        loopDone = nil
    }

    /// The speed and the mute, changed while the loop runs (main thread).
    func updateEmulationLoop(speed: Double, skipAudio: Bool) {
        loopLock.lock(); loopSpeed = speed; loopSkipAudio = skipAudio; loopLock.unlock()
    }

    /// On `emulationQueue` until stopped. Frames at the core's rate times the
    /// speed; up to eight to catch up after a slow one, and lateness past that
    /// dropped, as the display tick does for the other consoles.
    private func runEmulationLoop(frameDuration: Double) {
        var owed: Double = 0
        var last = CACurrentMediaTime()
        // Each pass in a pool of its own. The loop is ONE block that runs for
        // the whole game, and the objects MoltenVK and Metal hand back for
        // later release (command buffers, encoders) are only released when the
        // pool around them drains: GCD's drains when the block returns, which
        // this one never does. Without it the app grew ~100 MB every two
        // seconds until iOS killed it (his log, 10-20: 2.2 GB to 3.07 GB in
        // twenty seconds at 4x). The main thread's run loop drains its pool
        // every tick, which is why the frames never leaked there.
        while autoreleasepool(invoking: { emulationLoopPass(frameDuration: frameDuration,
                                                           owed: &owed, last: &last) }) {}
    }

    /// One pass of the loop: false when it is told to stop.
    private func emulationLoopPass(frameDuration: Double, owed: inout Double, last: inout Double) -> Bool {
        loopLock.lock()
        let stop = loopStop, speed = loopSpeed, skip = loopSkipAudio
        loopLock.unlock()
        if stop { return false }

        let effective = frameDuration / max(0.25, speed)
        let now = CACurrentMediaTime()
        owed += now - last
        last = now
        if owed > effective * 8 { owed = effective }
        if owed < effective {
            // Asleep until the next frame is due, never past it.
            Thread.sleep(forTimeInterval: max(0.0005, effective - owed))
            return true
        }
        var ran = 0
        skipAudio = skip
        while owed >= effective && ran < 8 {
            runFrame()
            owed -= effective
            ran += 1
            loopLock.lock(); let stopNow = loopStop; loopLock.unlock()
            if stopNow { break }
        }
        publishFrame()
        loopLock.lock()
        loopFramesRun += ran
        loopEmulatedTime += Double(ran) * frameDuration
        loopLock.unlock()
        return true
    }

    /// The core's picture, copied for the display (on `emulationQueue`).
    private func publishFrame() {
        guard let source = bridge.frameBuffer() else { return }
        let width = min(screenWidth, bufferStride)
        let height = min(totalBufferHeight, textureSize.height)
        let stride = bufferStride
        let count = stride * height
        publishedLock.lock()
        if publishedPixels.count != count { publishedPixels = [UInt32](repeating: 0, count: count) }
        publishedPixels.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: source, count: count) }
        publishedWidth = width
        publishedHeight = height
        publishedStride = stride
        publishedGeneration &+= 1
        publishedLock.unlock()
    }

    /// The latest published picture, if newer than `generation`, handed to
    /// `body` with the lock held (main thread: the upload). Returns its
    /// generation, or nil when there is nothing new.
    func withPublishedFrame(newerThan generation: Int,
                            _ body: (UnsafePointer<UInt32>, _ width: Int, _ height: Int, _ stride: Int) -> Void) -> Int? {
        publishedLock.lock(); defer { publishedLock.unlock() }
        guard publishedGeneration != generation, publishedHeight > 0 else { return nil }
        publishedPixels.withUnsafeBufferPointer { body($0.baseAddress!, publishedWidth, publishedHeight, publishedStride) }
        return publishedGeneration
    }

    /// Frames and emulated time the loop ran since the last call (main thread).
    func takeLoopProgress() -> (frames: Int, emulated: Double) {
        loopLock.lock(); defer { loopLock.unlock() }
        let progress = (loopFramesRun, loopEmulatedTime)
        loopFramesRun = 0
        loopEmulatedTime = 0
        return progress
    }

    /// The published picture as an image, both screens (the 3DS's stills
    /// while the loop runs: the core's own buffer is being written).
    private func publishedImage() -> CGImage? {
        publishedLock.lock(); defer { publishedLock.unlock() }
        guard publishedHeight > 0, publishedWidth > 0 else { return nil }
        let data = publishedPixels.withUnsafeBytes { Data($0.prefix(publishedStride * publishedHeight * 4)) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: publishedWidth, height: publishedHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: publishedStride * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Ends the game the way Quit does (its auto-save, then `shutdown`, on the
    /// game screen's own save queue), for a game REPLACED rather than quit: a
    /// file or a widget opened mid-game (`LibraryView.handleOpenedURL`). The
    /// game screen installs it; nil when no screen is running this session.
    /// Main thread.
    var endForReplacement: (() -> Void)?

    /// The loaded game's key (`BatterySaveImporter.romBasename`), for the
    /// in-game save's backup before a state load.
    private var loadedRomBasename: String?
    /// A 3DS game's title ID, which names its save folder (`CTRSaveData`);
    /// nil for every other console and for a `.3dsx`.
    private var ctrTitleID: UInt64?
    /// The 3DS's motion sensors, from the phone's (CTRMotion), on while the
    /// game runs. nil on every other console.
    private var ctrMotion: CTRMotion?
    /// The 3DS's cameras, from the phone's (CTRCamera): on only while a game
    /// has one started. nil on every other console.
    private var ctrCamera: CTRCamera?

    /// Called once per emulated frame, after the frame is produced, on the
    /// emulation thread. RetroAchievements installs this to drive
    /// `rc_client_do_frame`; nil (zero cost) when no RA session is active.
    var onFrameAdvance: (() -> Void)?

    /// Block until the LAST `runFrame`'s picture is readable through `frameBuffer`.
    ///
    /// Called ONCE per drawn frame, immediately before the upload — never once per emulated
    /// frame. Only MesenCE implements it (its picture arrives on a decode thread); for mGBA and
    /// melonDS the selector is absent and this is nothing at all.
    func awaitDisplayFrame() {
        guard isROMLoaded else { return }
        bridge.awaitDisplayFrame?()
    }

    func runFrame() {
        guard isROMLoaded else { return }
        bridge.runFrame()

        // If the core reported a new audio sample rate during this frame
        // (GBA SOUNDBIAS rewrite, very rare in commercial games), rebuild the
        // audio engine at the new rate before draining. The few samples still
        // sitting in mGBA's buffer at the OLD rate will play at the new rate
        // for one tick — an audible micro-glitch on the rate change itself,
        // acceptable for an event that essentially never fires.
        let newRate = Int(bridge.consumePendingAudioRate())
        if newRate > 0, newRate != Int(audioEngine?.sampleRate ?? 0) {
            audioEngine?.stop()
            audioEngine = EmulatorAudioEngine(bridge: bridge)
            if isRunning {
                audioEngine?.start()
            }
        }

        bridge.rewindAppend()
        let credit = Self.rewindCredit(perFrameAt: bridge.framesPerSecond)
        updateRewindCredit { min($0 + credit, Self.rewindBufferCapacity) }
        if !skipAudio {
            audioEngine?.drainSamples()
        }

        // Feed the RetroAchievements runtime the frame it watches for unlocks.
        onFrameAdvance?()

        // The achievements of a game whose memory was not there at load (the
        // PSP's boot): started on the main thread, where every other start
        // happens, once the core says its memory reads.
        if let path = pendingAchievementsPath, bridge.isMemoryReadable?() ?? true {
            pendingAchievementsPath = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isROMLoaded else { return }
                RetroAchievements.shared.startSession(self, romPath: path)
            }
        }
    }

    func rewind(frames: Int = 60) -> Bool {
        // Never request more frames than actually buffered
        let available = rewindFramesAvailable
        let safeFrames = min(frames, max(0, Int(available) - 60))
        guard safeFrames > 0 else {
            #if DEBUG
            print(String(format: "[Rewind] refused: %d sixtieths asked, %.0f credited (needs more than 60)",
                         frames, available))
            #endif
            return false
        }
        let result = bridge.rewindFrames(safeFrames)
        #if DEBUG
        if !result { print("[Rewind] the core refused \(safeFrames) sixtieths (\(Int(available)) credited)") }
        #endif
        if result {
            updateRewindCredit { max(0, $0 - Double(safeFrames)) }
            Analytics.signalOnce("rewind_used")
        }
        return result
    }

    // MARK: - Audio Sync

    /// Audio sample rate from the engine, or 0 if audio is off.
    var audioSampleRate: Double {
        audioEngine?.sampleRate ?? 0
    }

    /// Whether the audio engine is actively running.
    var isAudioRunning: Bool {
        audioEngine?.isRunning ?? false
    }

    /// Number of audio frames currently buffered in the ring buffer.
    var audioBufferedFrames: Int {
        audioEngine?.bufferedFrames ?? 0
    }

    /// Mute or unmute audio output without stopping the engine.
    var isAudioMuted: Bool {
        get { audioEngine?.isMuted ?? false }
        set { audioEngine?.isMuted = newValue }
    }

    // MARK: - Video

    func frameBuffer() -> UnsafePointer<UInt32>? {
        return bridge.frameBuffer()
    }

    func createFrameImage() -> CGImage? {
        return bridge.createFrameImage()
    }

    /// The game's own pixel grid behind the image `createScreenshotImage`
    /// returns right now: the live picture, both DS screens stacked. It is the
    /// image's own size on every console but two. The PlayStation and the
    /// Nintendo 64 hand out stills already stretched to 4:3, because their
    /// pixels are not square, so a 640x240 N64 picture is a 640x480 image whose
    /// real rows still number 240. The filter shader draws its rows and cells
    /// on this grid (`gameSize`), never on the stretched image.
    var screenshotPixelGrid: CGSize {
        CGSize(width: screenWidth, height: totalBufferHeight)
    }

    /// `screenshotPixelGrid` for a still just taken, or nil when it is the
    /// still's own size: nil on every console but the PlayStation, the
    /// Nintendo 64 and the Mega Drive (whose stills are rescaled to 4:3 by
    /// their bridges), so a share card that splits a DS still into its two screens
    /// never applies the whole stack's grid to a half.
    func filterPixelGrid(for image: CGImage) -> CGSize? {
        let grid = screenshotPixelGrid
        return grid == CGSize(width: image.width, height: image.height) ? nil : grid
    }

    /// Dual-screen capture for NDS screenshot + clip cards. Falls back to single-screen for
    /// GBA/GB/GBC. Honours the NDS "Swap screens" setting so the share cards show the same top/bottom
    /// order as in-game (both the screenshot and the clip capture flow through here).
    func createScreenshotImage() -> CGImage? {
        // The 3DS while its loop runs: the published copy, never the buffer
        // the next frame is writing.
        if loopDone != nil { return publishedImage() }
        guard let dual = bridge.createDualScreenFrameImage() else { return bridge.createFrameImage() }
        // The DS's setting, never the 3DS's picture (its two screens differ in width).
        guard hasTouchScreen, UserDefaults.standard.bool(forKey: "ndsSwapScreens") else { return dual }
        return Self.swappingDualScreenHalves(dual)
    }

    /// Returns the stacked dual-screen image with its top and bottom halves exchanged (each kept
    /// upright) — the NDS "Swap screens" preference applied to the share-card capture.
    private static func swappingDualScreenHalves(_ image: CGImage) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let half = (h / 2).rounded()
        guard let top = image.cropping(to: CGRect(x: 0, y: 0, width: w, height: half)),
              let bottom = image.cropping(to: CGRect(x: 0, y: half, width: w, height: h - half))
        else { return image }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1; fmt.opaque = true
        let swapped = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
            UIImage(cgImage: bottom).draw(in: CGRect(x: 0, y: 0, width: w, height: h - half))
            UIImage(cgImage: top).draw(in: CGRect(x: 0, y: h - half, width: w, height: half))
        }
        return swapped.cgImage ?? image
    }

    // MARK: - Input

    func setKeys(_ keys: UInt32) {
        bridge.setKeys(keys)
    }

    /// One player's buttons, 0-based. Player 1 takes the path every core has;
    /// the others reach only a core whose console had their port (the caller
    /// feeds no more players than `PresetSystem.playerCount`, and a test holds
    /// every multi-player console's bridge to implementing this).
    func setKeys(_ keys: UInt32, player: Int) {
        if player == 0 {
            bridge.setKeys(keys)
        } else {
            bridge.setKeys?(keys, player: player)
        }
    }

    /// How many players have a controller now, capped by the caller at the
    /// console's count. Only a console whose ports must be told (SNES, NES)
    /// listens; see `EmulatorBridge.setConnectedPlayers:`.
    func setConnectedPlayers(_ count: Int) {
        bridge.setConnectedPlayers?(count)
    }

    // MARK: - Touch Screen (NDS)

    func touchScreen(x: Int, y: Int) {
        bridge.touchScreenAt(x: Int32(x), y: Int32(y))
    }

    func touchScreenRelease() {
        bridge.touchScreenRelease()
    }

    // MARK: - Microphone (NDS, 3DS)

    func setMicBlowActive(_ active: Bool) {
        (bridge as? MelonDSBridge)?.setMicBlowActive(active)
        (bridge as? CTRBridge)?.setMicBlowActive(active)
    }

    // MARK: - Lid (NDS)

    /// Close or open the DS's lid (see `MelonDSBridge.setLidClosed`). A no-op
    /// on every other console.
    func setLidClosed(_ closed: Bool) {
        (bridge as? MelonDSBridge)?.setLidClosed(closed)
    }

    // MARK: - Speed

    func setSpeed(_ multiplier: Double) {
        // Bridge only accepts Int. For sub-1x speeds, frame timing is handled
        // by EmulatorMetalView. For >=1x, pass to bridge for audio sync.
        bridge.setSpeedMultiplier(Int32(max(1, Int(multiplier))))
    }

    // MARK: - Memory (RetroAchievements)

    /// Read `length` bytes of live console memory at the REAL bus `address` into
    /// `buffer`; returns the number of bytes read (0 = unmapped). The RA runtime's
    /// read_memory callback uses this; the RA-flat→real address translation lives
    /// in the RetroAchievements layer (`rc_console_memory_regions`). All 4
    /// consoles: mGBA serves the GBA/GB/GBC bus, melonDS serves the NDS main
    /// RAM + ARM9 DTCM. Read-only, no emulation side effects, called on the
    /// emulation thread inside `rc_client_do_frame`.
    func readMemory(at address: UInt32, into buffer: UnsafeMutablePointer<UInt8>, length: Int) -> Int {
        guard isROMLoaded else { return 0 }
        return bridge.readMemory(atAddress: address, into: buffer, length: length)
    }

    // MARK: - Save States

    /// `coordinated: false` writes the state binary and its preview with a direct
    /// atomic write instead of going through `NSFileCoordinator`. Used by the
    /// background-durability auto-save: the coordinated write can stall on the
    /// iCloud daemon, and a force-kill won't wait for it, so the snapshot would
    /// be lost. The bridge writes atomically (temp + rename), so the uncoordinated
    /// write can't tear a file; iCloud syncs the change afterward.
    func saveState(slot: Int, coordinated: Bool = true) -> Bool {
        guard let manager = saveStateManager else { return false }
        var success = false
        let stateURL = manager.stateFileURL(slot: slot)
        var coordinationGranted = true
        if coordinated {
            coordinationGranted = CoordinatedFileIO.write(at: stateURL) { coordURL in
                success = bridge.saveState(toPath: coordURL.path)
            }
        } else {
            success = bridge.saveState(toPath: stateURL.path)
        }
        if success, let image = bridge.createFrameImage() {
            manager.savePreviewImage(image, slot: slot, coordinated: coordinated)
        }
        // Snapshot the RetroAchievements runtime beside the state so loading this
        // slot restores RA tracking to match the restored memory (no missed or
        // repeated unlocks). Sidecar is removed when there's no active RA session.
        if success {
            let sidecar = stateURL.appendingPathExtension("ra")
            if let raData = RetroAchievements.shared.serializeProgress() {
                try? raData.write(to: sidecar, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: sidecar)
            }
        }
        // A manual save (slots 1-5) is a deliberate engagement signal that
        // feeds the engagedFirstTimer review prompt. The silent auto-save
        // (slot 0) happens to everyone, so it must NOT count or the signal
        // would be meaningless.
        if success, slot != SaveStateManager.autoSaveSlotIndex {
            PromptTracker.shared.recordSaveStateCreated()
        }
        Self.logStateFile(verb: "write", slot: slot, url: stateURL, success: success)
        if !success {
            Analytics.signal("save_failure", [
                "kind": slot == SaveStateManager.autoSaveSlotIndex ? "auto_save" : "state_write",
                "system": analyticsSystem,
                "reason": ErrorTelemetry.stateFailureReason(
                    coordinated: coordinationGranted, fileExists: true, isWrite: true,
                    availableBytes: ErrorTelemetry.availableBytes(near: stateURL)).rawValue
            ])
        }
        return success
    }

    func loadState(slot: Int) -> Bool {
        guard let manager = saveStateManager else { return false }
        // The in-game save as it is NOW, copied aside first: a state can carry
        // an older one back (`BatterySaveImporter.backUpBeforeStateLoad`). The
        // live buffer is flushed so the copy is current. Not the PSP, whose
        // saves are a memory-stick folder the states do not carry. The 3DS's
        // save is a folder too, and a state DOES carry the console, whose game
        // may write its save again from the older moment the state puts back:
        // its folder is zipped aside the same way (`CTRSaveData`).
        if bridge is CTRBridge {
            if let titleID = ctrTitleID, let key = loadedRomBasename {
                CTRSaveData.backUpBeforeStateLoad(titleID: titleID, romBasename: key)
            }
        } else if !(bridge is PSPBridge), let key = loadedRomBasename {
            bridge.flushSaveData()
            BatterySaveImporter.backUpBeforeStateLoad(romBasename: key)
        }
        var success = false
        let coordinationGranted = CoordinatedFileIO.read(at: manager.stateFileURL(slot: slot)) { coordURL in
            success = bridge.loadState(fromPath: coordURL.path)
        }
        if success {
            // Loading a state invalidates rewind buffer position
            updateRewindCredit { _ in 0 }
            // A save state snapshots the NDS clock too, so loading one
            // rewinds the RTC to whenever the snapshot was made. Re-apply the
            // real (or manually set) clock so resuming a game reflects the
            // current date/time instead of the stale snapshot — and so the
            // "set date and time manually" setting takes effect on resume,
            // not only on a fresh boot. mGBA games get their RTC from the
            // host clock, so this is a no-op there.
            (bridge as? MelonDSBridge)?.seedRealTimeClock()
            // Restore the RA runtime captured with this slot (if any), so unlock
            // tracking matches the memory we just loaded.
            let sidecar = manager.stateFileURL(slot: slot).appendingPathExtension("ra")
            if let raData = try? Data(contentsOf: sidecar) {
                RetroAchievements.shared.deserializeProgress(raData)
            }
        }
        Self.logStateFile(verb: "load", slot: slot, url: manager.stateFileURL(slot: slot), success: success)
        if !success {
            let stateURL = manager.stateFileURL(slot: slot)
            Analytics.signal("save_failure", [
                "kind": "state_load",
                "system": analyticsSystem,
                "reason": ErrorTelemetry.stateFailureReason(
                    coordinated: coordinationGranted,
                    fileExists: FileManager.default.fileExists(atPath: stateURL.path),
                    isWrite: false, availableBytes: nil).rawValue
            ])
        }
        return success
    }

    /// Set when a resume could not load the auto-save: the game started fresh,
    /// and an auto-save now would write that fresh start over the session the
    /// player asked for, which may load later (a file the core refused today,
    /// a fix in the next build). Kept until the player chooses (the game
    /// screen's `resumeFailed`). Read on the save queue, set on main.
    var keepsAutoSave: Bool {
        get { autoSaveLock.lock(); defer { autoSaveLock.unlock() }; return _keepsAutoSave }
        set { autoSaveLock.lock(); _keepsAutoSave = newValue; autoSaveLock.unlock() }
    }
    private var _keepsAutoSave = false
    private let autoSaveLock = NSLock()

    /// Set when the core stopped for good and its bridge refuses a state from
    /// then on (a PSP halt or failed boot, an ended 3DS game; NOT a lost
    /// picture, whose quit still saves the game). The auto-save of the quit or
    /// of leaving the app is not attempted: attempted, each such stop was also
    /// counted as an auto-save failure (`save_failure kind=auto_save`), which
    /// it is not (audit, 2026-10-30). Read on the save queue, set on main.
    var coreHalted: Bool {
        get { autoSaveLock.lock(); defer { autoSaveLock.unlock() }; return _coreHalted }
        set { autoSaveLock.lock(); _coreHalted = newValue; autoSaveLock.unlock() }
    }
    private var _coreHalted = false

    func autoSave(coordinated: Bool = true) -> Bool {
        if keepsAutoSave {
            Self.autoSaveLog.notice("auto-save skipped: the session it holds could not be resumed and is kept")
            return false
        }
        if coreHalted {
            Self.autoSaveLog.notice("auto-save skipped: the core has stopped, the last good save is kept")
            return false
        }
        return saveState(slot: SaveStateManager.autoSaveSlotIndex, coordinated: coordinated)
    }

    private static let autoSaveLog = Logger(subsystem: "com.retropal", category: "autosave")

    /// Diagnostics for the rare slot-0 loss: logs the written/loaded auto-save's
    /// size + mtime so a recurrence is traceable from Console even in Release.
    /// Every state read or written, with its slot, file name and date: which
    /// slot a session really resumed from is a question asked from a device
    /// (2026-10-19), and the auto-save alone did not answer it. The file name
    /// and slot carry no player data; the date is printed as the device's.
    private static func logStateFile(verb: String, slot: Int, url: URL, success: Bool) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let date = (attrs?[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "-"
        let kind = slot == SaveStateManager.autoSaveSlotIndex ? "auto-save" : "state"
        autoSaveLog.notice("\(kind, privacy: .public) \(verb, privacy: .public) slot=\(slot) file=\(url.lastPathComponent, privacy: .public) success=\(success) bytes=\(size) modified=\(date, privacy: .public)")
    }

    /// Force the battery save (in-game progress) to disk. Called when the app
    /// backgrounds so a suspended-then-killed app never leaves the `.sav`
    /// stale. The bridge writes only the live save buffer, so it cannot
    /// corrupt; safe to call while paused.
    func flushBatterySave() {
        bridge.flushSaveData()
    }

    // MARK: - GB (DMG) Palette

    /// Apply a DMG palette to the running game. Live on the next rendered
    /// frame for DMG-mode games; a no-op for GBA/NDS and ignored by CGB-mode
    /// games (they define their own colors). Safe to call while paused — the
    /// visible (already-rendered) frame keeps the old colors until the next
    /// frame runs.
    func applyGBPalette(_ palette: GBPalette) {
        var colors = palette.colors12
        bridge.setGBPalette(&colors)
    }

    /// Whether the running game actually renders through the DMG palette
    /// (drives the palette section's availability in the Appearance sheet).
    var isDMGPaletteApplicable: Bool { bridge.isDMGPaletteApplicable() }

    // MARK: - Cheat Codes

    /// Add a cheat code. Sanitizes input, then tries all formats silently until one works.
    func addCheat(_ code: String) -> Bool {
        let cleaned = Self.sanitizeCheatCode(code)
        guard !cleaned.isEmpty else { return false }
        for type: Int32 in [0, 1, 2, 3, 4] {
            if bridge.addCheatCode(cleaned, type: type) {
                return true
            }
        }
        return false
    }

    /// Clean cheat code input for reliable parsing.
    static func sanitizeCheatCode(_ code: String) -> String {
        // Character-level cleanup (fullwidth digits, invisible spaces, line
        // endings) lives in `CheatCodeFormatter.normalized`, the same step the
        // cheat sheet runs BEFORE validating, so the two can never disagree
        // about what a clean code is.
        var s = CheatCodeFormatter.normalized(code)
        // Collapse multiple spaces into one
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        // Trim each line
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // Remove leading/trailing blank lines
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    /// Save a pre-cheat backup (separate from auto-save, never auto-overwritten).
    func savePreCheatBackup() -> Bool {
        guard let manager = saveStateManager else { return false }
        var success = false
        CoordinatedFileIO.write(at: manager.preCheatBackupURL) { coordURL in
            success = bridge.saveState(toPath: coordURL.path)
        }
        return success
    }

    /// Load the pre-cheat backup to recover from a bad cheat.
    func loadPreCheatBackup() -> Bool {
        guard let manager = saveStateManager, manager.hasPreCheatBackup else { return false }
        var success = false
        CoordinatedFileIO.read(at: manager.preCheatBackupURL) { coordURL in
            success = bridge.loadState(fromPath: coordURL.path)
        }
        return success
    }

    func clearCheats() {
        bridge.clearCheats()
    }

    // MARK: - Lifecycle

    func start() {
        hasStarted = true
        isRunning = true
        audioEngine?.start()
        ctrMotion?.start()
    }

    /// Whether `start` ran: the game screen may first run a game through
    /// `resume` (its boot finished with the app in the background, or a failed
    /// resume waiting for an answer), and only `start` sets the audio up.
    private var hasStarted = false

    func pause() {
        isRunning = false
        audioEngine?.pause()
        ctrMotion?.stop()
        ctrCamera?.pause()
    }

    func resume() {
        guard hasStarted else { start(); return }
        isRunning = true
        audioEngine?.resume()
        ctrMotion?.start()
        ctrCamera?.resume()
    }

    func stop() {
        isRunning = false
        audioEngine?.stop()
        ctrMotion?.stop()
    }

    /// The interface has rotated: the 3DS's motion axes and its cameras'
    /// picture follow the screen.
    func interfaceOrientationDidChange() {
        ctrMotion?.orientationDidChange()
        ctrCamera?.orientationDidChange()
    }

    func shutdown() {
        isRunning = false
        // A 3DS loop left running by a path that skipped `stopEmulationLoop`
        // (none does today) ends at its next frame instead of running on.
        loopLock.lock(); loopStop = true; loopLock.unlock()
        RetroAchievements.shared.endSession()
        onFrameAdvance = nil
        audioEngine?.stop()
        audioEngine = nil
        ctrMotion?.stop()
        ctrMotion = nil
        ctrCamera?.stop()
        ctrCamera = nil
        // Final battery flush while the core is still alive (no-op when
        // clean; only the background path flushed until now), so the .sav on
        // disk is fresh for the post-shutdown iCloud mirror pass.
        bridge.flushSaveData()
        isROMLoaded = false
        bridge.shutdown()
        // The core has released the .sav files (final flush included, slot-2
        // GBA save too when mounted). Unflag them and tell the iCloud battery
        // mirror it is now safe to reconcile these games.
        BatterySaveImporter.activeSessionBasenames = []
        CTRSaveSync.activeTitleIDs = []
        gbaSlot2Basename = nil
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .batterySavesDidChange, object: nil)
        }
    }
}
