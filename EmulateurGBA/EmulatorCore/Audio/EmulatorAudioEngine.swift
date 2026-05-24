//
//  EmulatorAudioEngine.swift
//  EmulateurGBA
//
//  Thread-safe audio pipeline: emulator thread writes samples into a ring
//  buffer, audio IO thread reads from it. Lock-free SPSC pattern.
//
//  The GBA audio rate depends on the SOUNDBIAS register (set by each game):
//  - Resolution 0: 32,768 Hz
//  - Resolution 1: 65,536 Hz (most games use this)
//  We query the actual rate from mGBA after reset and configure accordingly.
//

import AVFoundation

final class EmulatorAudioEngine {
    private let engine = AVAudioEngine()
    private let sourceNode: AVAudioSourceNode
    private weak var bridge: (any EmulatorBridge)?

    private static let ringCapacity = 16384 // frames — generous for 65536 Hz

    private let ring: UnsafeMutablePointer<Float>
    private let ringFrameCount: Int
    private let writePos: UnsafeMutablePointer<Int>
    private let readPos: UnsafeMutablePointer<Int>
    private let int16Buf: UnsafeMutablePointer<Int16>

    let sampleRate: Double

    private(set) var isRunning = false

    /// Mute audio output without stopping the engine (preserves sync).
    var isMuted: Bool = false {
        didSet { engine.mainMixerNode.outputVolume = isMuted ? 0 : 1 }
    }

    /// Number of audio frames currently buffered in the ring (read from any thread).
    var bufferedFrames: Int {
        var avail = writePos.pointee - readPos.pointee
        if avail < 0 { avail += ringFrameCount }
        return avail
    }

    deinit {
        ring.deallocate()
        writePos.deallocate()
        readPos.deallocate()
        int16Buf.deallocate()
    }

    init(bridge: any EmulatorBridge) {
        self.bridge = bridge

        // Query actual rate from mGBA (depends on game's SOUNDBIAS setting)
        let rate = bridge.audioSampleRate()
        self.sampleRate = rate > 0 ? Double(rate) : 32768.0

        self.ringFrameCount = EmulatorAudioEngine.ringCapacity
        let floatCount = ringFrameCount * 2
        self.ring = .allocate(capacity: floatCount)
        self.ring.initialize(repeating: 0, count: floatCount)
        self.writePos = .allocate(capacity: 1)
        self.readPos = .allocate(capacity: 1)
        self.writePos.pointee = 0
        self.readPos.pointee = 0
        self.int16Buf = .allocate(capacity: 4096 * 2)

        let ringRef = ring
        let ringCap = ringFrameCount
        let wp = writePos
        let rp = readPos

        let sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!

        sourceNode = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let framesNeeded = Int(frameCount)

            let w = wp.pointee
            let r = rp.pointee
            var available = w - r
            if available < 0 { available += ringCap }

            let framesToRead = min(framesNeeded, available)

            if ablPointer.count >= 2,
               let leftData = ablPointer[0].mData,
               let rightData = ablPointer[1].mData {
                let leftPtr = leftData.assumingMemoryBound(to: Float.self)
                let rightPtr = rightData.assumingMemoryBound(to: Float.self)

                var idx = r
                for i in 0..<framesToRead {
                    let si = idx * 2
                    leftPtr[i] = ringRef[si]
                    rightPtr[i] = ringRef[si + 1]
                    idx += 1
                    if idx >= ringCap { idx = 0 }
                }

                if framesToRead < framesNeeded {
                    for i in framesToRead..<framesNeeded {
                        leftPtr[i] = 0
                        rightPtr[i] = 0
                    }
                }
            }

            rp.pointee = (r + framesToRead) % ringCap
            return noErr
        }
    }

    /// Call on the emulator thread after each runFrame().
    func drainSamples() {
        guard let bridge = bridge else { return }

        let maxRead = 4096
        let framesRead = Int(bridge.readAudioSamples(int16Buf, count: maxRead))
        if framesRead == 0 { return }

        let w = writePos.pointee
        let r = readPos.pointee

        var space = r - w - 1
        if space < 0 { space += ringFrameCount }
        let framesToWrite = min(framesRead, space)

        let scale: Float = 1.0 / 32768.0
        var idx = w
        for i in 0..<framesToWrite {
            let si = idx * 2
            ring[si] = Float(int16Buf[i * 2]) * scale
            ring[si + 1] = Float(int16Buf[i * 2 + 1]) * scale
            idx += 1
            if idx >= ringFrameCount { idx = 0 }
        }

        writePos.pointee = (w + framesToWrite) % ringFrameCount
    }

    func start() {
        configureAudioSession()

        // Pre-roll cushion: advance writePos by ~2 emulator frames of silence so
        // the AVAudioEngine render callback always has samples to read while the
        // first real frames are being produced. mGBA delivers audio in bursts of
        // ~1 frame's worth (~1097 samples at 65,536 Hz) every 16.7 ms, while the
        // render callback consumes continuously and in irregular chunks. Without
        // this cushion, the ring sits near empty just before each runFrame and
        // any render callback that lands in that window zero-pads its output —
        // audible as a 60 Hz crackle, especially on dense audio like the GBA's
        // Direct Sound A/B channels (Zelda GBA orchestral remake samples, etc.).
        //
        // ~33 ms of added one-way audio latency, imperceptible outside rhythm
        // games. The ring's float storage is zero-initialized at allocation, so
        // advancing the write cursor is enough — no explicit silence write needed.
        readPos.pointee = 0
        let preRollFrames = min(Int(sampleRate / 30.0), ringFrameCount - 1)
        writePos.pointee = preRollFrames

        engine.attach(sourceNode)
        let sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!
        engine.connect(sourceNode, to: engine.mainMixerNode, format: sourceFormat)
        do {
            try engine.start()
            isRunning = true
        } catch {
            print("[Audio] Failed to start: \(error)")
        }
    }

    func pause() {
        engine.pause()
        isRunning = false
    }

    func resume() {
        do {
            try engine.start()
            isRunning = true
        } catch {
            print("[Audio] Failed to resume: \(error)")
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .ambient + .mixWithOthers: emulator audio mixes with other apps
            // without affecting their volume. User controls emulator sound via
            // system volume or silent switch (flipping mute kills emulator audio
            // but Spotify/podcasts continue).
            try session.setCategory(.ambient, mode: .default, options: .mixWithOthers)
            try session.setActive(true)
        } catch {
            print("[Audio] Session setup failed: \(error)")
        }
    }
}
