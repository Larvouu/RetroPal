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
            Analytics.signal("rewind_used")
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
                "system": bridge is MelonDSBridge ? "nds" : "gba"
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
                "system": bridge is MelonDSBridge ? "nds" : "gba"
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
        RetroAchievements.shared.endSession()
        onFrameAdvance = nil
        audioEngine?.stop()
        audioEngine = nil
        isROMLoaded = false
        bridge.shutdown()
    }
}
