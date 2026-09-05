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

    /// Feed the PlayStation's analog sticks, each axis -1...1, **y positive
    /// DOWN**, which is what UIKit, libretro and the PlayStation all use.
    ///
    /// A no-op on every other core, exactly as `configureGBASlot2` is a no-op
    /// off the DS: the protocol stays the four cores' common contract and the
    /// console-specific surfaces are reached through a cast.
    ///
    /// No flip here. GameController is the one source that measures +1 as UP,
    /// so its flip lives at ITS boundary. Doing it here instead meant the touch
    /// path had to negate on the way in so this could negate back, and a value
    /// that passes through two negations to arrive unchanged is a sign error
    /// waiting for someone to remove one of them.
    func setAnalogSticks(leftX: CGFloat, leftY: CGFloat, rightX: CGFloat, rightY: CGFloat) {
        guard let pcsx = bridge as? PCSXBridge else { return }
        pcsx.setLeftStickX(Float(leftX), y: Float(leftY))
        pcsx.setRightStickX(Float(rightX), y: Float(rightY))
    }

    /// Press the PlayStation pad's ANALOG switch. A no-op on every other core.
    func pressAnalogModeButton() {
        (bridge as? PCSXBridge)?.pressAnalogModeButton()
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
    /// with the PlayStation.
    private var analyticsSystem: String = "gba"

    func loadROM(at url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "nds":         analyticsSystem = "nds"
        case "sfc", "smc":  analyticsSystem = "snes"
        case "nes":         analyticsSystem = "nes"
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

        let success = bridge.loadROM(atPath: url.path)
        if success {
            // Set battery save path BEFORE reset so existing .sav is loaded.
            // The path comes from BatterySaveImporter (single source of truth)
            // so the loader, the per-game save importer, and the path-lock test
            // can never drift apart and orphan a user's save.
            bridge.setSavePath(savePath.path)
            // The core now holds this .sav open for the whole session (mGBA
            // retains its VFile; melonDS rewrites it as the game saves) — flag
            // it, plus the slot-2 GBA game's save when one is mounted, so the
            // iCloud battery mirror never touches a live file.
            var live: Set<String> = [romName]
            if let slot2 = gbaSlot2Basename { live.insert(slot2) }
            BatterySaveImporter.activeSessionBasenames = live

            bridge.reset()
            // Run one frame so the game initializes SOUNDBIAS (audio rate)
            bridge.runFrame()
            isROMLoaded = true
            saveStateManager = SaveStateManager(romName: romName)
            // Create audio engine AFTER reset+first frame so we get the actual
            // sample rate (game may set SOUNDBIAS to 65536 Hz during init)
            audioEngine = EmulatorAudioEngine(bridge: bridge)
            // Initialize rewind buffer at max capacity (35 seconds).
            // Frame count is gated by Pro status at rewind time, not buffer size.
            bridge.initRewind(35)
            // Start a RetroAchievements session (hashes the ROM, loads the set).
            // No-op unless RA is enabled and the user is logged in.
            RetroAchievements.shared.startSession(self, romPath: url.path)
        }
        return success
    }

    // MARK: - Frame Execution

    /// Number of frames appended to the rewind buffer since last reset.
    /// Capped at the buffer capacity (35 * 60 = 2100).
    private(set) var rewindFramesAvailable: Int = 0
    private static let rewindBufferCapacity = 35 * 60

    /// Set to true to skip audio drain (used at high speeds to save CPU)
    var skipAudio = false

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
        rewindFramesAvailable = min(rewindFramesAvailable + 1, Self.rewindBufferCapacity)
        if !skipAudio {
            audioEngine?.drainSamples()
        }

        // Feed the RetroAchievements runtime the frame it watches for unlocks.
        onFrameAdvance?()
    }

    func rewind(frames: Int = 60) -> Bool {
        // Never request more frames than actually buffered
        let safeFrames = min(frames, max(0, rewindFramesAvailable - 60))
        guard safeFrames > 0 else { return false }
        let result = bridge.rewindFrames(safeFrames)
        if result {
            rewindFramesAvailable = max(0, rewindFramesAvailable - safeFrames)
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

    /// Dual-screen capture for NDS screenshot + clip cards. Falls back to single-screen for
    /// GBA/GB/GBC. Honours the NDS "Swap screens" setting so the share cards show the same top/bottom
    /// order as in-game (both the screenshot and the clip capture flow through here).
    func createScreenshotImage() -> CGImage? {
        guard let dual = bridge.createDualScreenFrameImage() else { return bridge.createFrameImage() }
        guard UserDefaults.standard.bool(forKey: "ndsSwapScreens") else { return dual }
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

    // MARK: - Touch Screen (NDS)

    func touchScreen(x: Int, y: Int) {
        bridge.touchScreenAt(x: Int32(x), y: Int32(y))
    }

    func touchScreenRelease() {
        bridge.touchScreenRelease()
    }

    // MARK: - Microphone (NDS)

    func setMicBlowActive(_ active: Bool) {
        (bridge as? MelonDSBridge)?.setMicBlowActive(active)
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
        if coordinated {
            CoordinatedFileIO.write(at: stateURL) { coordURL in
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
        if slot == SaveStateManager.autoSaveSlotIndex {
            Self.logAutoSave(verb: "write", url: stateURL, success: success)
        }
        if !success {
            Analytics.signal("save_failure", [
                "kind": slot == SaveStateManager.autoSaveSlotIndex ? "auto_save" : "state_write",
                "system": analyticsSystem
            ])
        }
        return success
    }

    func loadState(slot: Int) -> Bool {
        guard let manager = saveStateManager else { return false }
        var success = false
        CoordinatedFileIO.read(at: manager.stateFileURL(slot: slot)) { coordURL in
            success = bridge.loadState(fromPath: coordURL.path)
        }
        if success {
            // Loading a state invalidates rewind buffer position
            rewindFramesAvailable = 0
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
        if slot == SaveStateManager.autoSaveSlotIndex {
            Self.logAutoSave(verb: "load", url: manager.stateFileURL(slot: slot), success: success)
        }
        if !success {
            Analytics.signal("save_failure", [
                "kind": "state_load",
                "system": analyticsSystem
            ])
        }
        return success
    }

    func autoSave(coordinated: Bool = true) -> Bool {
        return saveState(slot: SaveStateManager.autoSaveSlotIndex, coordinated: coordinated)
    }

    private static let autoSaveLog = Logger(subsystem: "com.retropal", category: "autosave")

    /// Diagnostics for the rare slot-0 loss: logs the written/loaded auto-save's
    /// size + mtime so a recurrence is traceable from Console even in Release.
    private static func logAutoSave(verb: String, url: URL, success: Bool) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        autoSaveLog.notice("auto-save \(verb, privacy: .public) success=\(success) bytes=\(size) mtime=\(mtime)")
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
        var s = code
        // Replace non-breaking spaces, zero-width chars, and other invisible junk from copy-paste
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")  // non-breaking space
        s = s.replacingOccurrences(of: "\u{200B}", with: "")   // zero-width space
        s = s.replacingOccurrences(of: "\u{FEFF}", with: "")   // BOM
        s = s.replacingOccurrences(of: "\r\n", with: "\n")     // Windows line endings
        s = s.replacingOccurrences(of: "\r", with: "\n")       // Old Mac line endings
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
        isRunning = true
        audioEngine?.start()
    }

    func pause() {
        isRunning = false
        audioEngine?.pause()
    }

    func resume() {
        isRunning = true
        audioEngine?.resume()
    }

    func stop() {
        isRunning = false
        audioEngine?.stop()
    }

    func shutdown() {
        isRunning = false
        RetroAchievements.shared.endSession()
        onFrameAdvance = nil
        audioEngine?.stop()
        audioEngine = nil
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
        gbaSlot2Basename = nil
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .batterySavesDidChange, object: nil)
        }
    }
}
