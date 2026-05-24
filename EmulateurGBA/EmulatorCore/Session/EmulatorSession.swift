//
//  EmulatorSession.swift
//  EmulateurGBA
//
//  Swift wrapper around MGBABridge. This is the only class
//  the rest of the app should use to interact with the emulator.
//

import Foundation
import CoreGraphics

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
    /// Whether the current system has a touch screen (NDS bottom screen)
    var hasTouchScreen: Bool { bridge.hasTouchScreen }

    private let bridge: any EmulatorBridge
    private var audioEngine: EmulatorAudioEngine?
    private(set) var saveStateManager: SaveStateManager?

    private(set) var isRunning = false
    private(set) var isROMLoaded = false

    init(bridge: any EmulatorBridge = MGBABridge()) {
        self.bridge = bridge
    }

    // MARK: - ROM Management

    func loadROM(at url: URL) -> Bool {
        let success = bridge.loadROM(atPath: url.path)
        if success {
            // Set battery save path BEFORE reset so existing .sav is loaded.
            // The path comes from BatterySaveImporter (single source of truth)
            // so the loader, the per-game save importer, and the path-lock test
            // can never drift apart and orphan a user's save.
            let romName = BatterySaveImporter.romBasename(forStoredFilename: url.lastPathComponent)
            let savePath = BatterySaveImporter.savePath(forRomBasename: romName).path
            bridge.setSavePath(savePath)

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
    }

    func rewind(frames: Int = 60) -> Bool {
        // Never request more frames than actually buffered
        let safeFrames = min(frames, max(0, rewindFramesAvailable - 60))
        guard safeFrames > 0 else { return false }
        let result = bridge.rewindFrames(safeFrames)
        if result {
            rewindFramesAvailable = max(0, rewindFramesAvailable - safeFrames)
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

    /// Dual-screen capture for NDS screenshot cards. Falls back to single-screen for GBA/GB/GBC.
    func createScreenshotImage() -> CGImage? {
        return bridge.createDualScreenFrameImage() ?? bridge.createFrameImage()
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

    // MARK: - Memory Access (GBA only)

    /// Read a byte / halfword / word from the emulated machine's address space.
    /// GBA-only: routed through the concrete MGBABridge (the EmulatorBridge
    /// protocol stays clean). Returns 0 for non-GBA cores or no loaded ROM.
    /// Used by the in-game translation feature to read structured game state.
    func readMemory8(_ address: UInt32) -> UInt8 {
        (bridge as? MGBABridge)?.readMemory8(address) ?? 0
    }

    func readMemory16(_ address: UInt32) -> UInt16 {
        (bridge as? MGBABridge)?.readMemory16(address) ?? 0
    }

    func readMemory32(_ address: UInt32) -> UInt32 {
        (bridge as? MGBABridge)?.readMemory32(address) ?? 0
    }

    // MARK: - Speed

    func setSpeed(_ multiplier: Double) {
        // Bridge only accepts Int. For sub-1x speeds, frame timing is handled
        // by EmulatorMetalView. For >=1x, pass to bridge for audio sync.
        bridge.setSpeedMultiplier(Int32(max(1, Int(multiplier))))
    }

    // MARK: - Save States

    func saveState(slot: Int) -> Bool {
        guard let manager = saveStateManager else { return false }
        var success = false
        CoordinatedFileIO.write(at: manager.stateFileURL(slot: slot)) { coordURL in
            success = bridge.saveState(toPath: coordURL.path)
        }
        if success, let image = bridge.createFrameImage() {
            manager.savePreviewImage(image, slot: slot)
        }
        // A manual save (slots 1-5) is a deliberate engagement signal that
        // feeds the engagedFirstTimer review prompt. The silent auto-save
        // (slot 0) happens to everyone, so it must NOT count or the signal
        // would be meaningless.
        if success, slot != SaveStateManager.autoSaveSlotIndex {
            PromptTracker.shared.recordSaveStateCreated()
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
        }
        return success
    }

    func autoSave() -> Bool {
        return saveState(slot: SaveStateManager.autoSaveSlotIndex)
    }

    /// Force the battery save (in-game progress) to disk. Called when the app
    /// backgrounds so a suspended-then-killed app never leaves the `.sav`
    /// stale. The bridge writes only the live save buffer, so it cannot
    /// corrupt; safe to call while paused.
    func flushBatterySave() {
        bridge.flushSaveData()
    }

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

    func setCheatsEnabled(_ enabled: Bool) {
        bridge.setCheatsEnabled(enabled)
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
        audioEngine?.stop()
        audioEngine = nil
        isROMLoaded = false
        bridge.shutdown()
    }
}
