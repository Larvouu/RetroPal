//
//  LaunchProbe.swift
//  EmulateurGBA
//
//  DEBUG only: where a launch stops (2026-11-02).
//
//  Some launches from Xcode, on the iPhone and the iPad, never draw a first
//  frame: the app prints its iCloud and telemetry lines and then nothing, the
//  screen stays black (or white), and the same build opened by hand always
//  starts. Intermittent, no crash: something waits. A first frame never drawn
//  means the main thread is not getting back to its run loop.
//
//  Two instruments:
//  - `mark(_:)`, a numbered line at each step of the launch, with the thread
//    it ran on: the last line printed is the last step that finished.
//  - A watchdog on a background thread that pings the main queue every
//    second. If the main queue has not answered for 3 seconds it prints the
//    last step the main thread reached and every step reached since launch,
//    then again every 5 seconds while it stays stuck. A stuck launch so
//    tells, on its own, which call it is stuck in, with nothing to press.
//
//  FOUND AND FIXED 2026-11-02 (`da0671cc`): the iCloud pass made
//  `PlayHistory.shared` first, on a background queue, and the main thread
//  waited for it; the history is now made on the main thread first.
//
//  SWITCHED OFF, NOT REMOVED (his call): every call is commented out and
//  tagged `// LAUNCHPROBE ` in six files. To switch it back on, remove that
//  tag everywhere (search `// LAUNCHPROBE `). This file stays compiled, DEBUG
//  only, and does nothing while no one calls it.
//

#if DEBUG
import Foundation

enum LaunchProbe {
    private static let lock = NSLock()
    private static var steps: [String] = []
    private static var lastMainStep = "(none yet)"
    private static var lastMainAnswer = Date()
    private static let start = Date()
    private static var started = false

    /// A step of the launch: printed at once, and kept for the watchdog.
    static func mark(_ step: String) {
        // On iOS the main queue always runs on the main thread.
        let main = Thread.isMainThread
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let line = "[Launch] +\(ms) ms \(main ? "main" : "bg  ") \(step)"
        lock.lock()
        steps.append(line)
        if main { lastMainStep = step }
        lock.unlock()
        print(line)
    }

    /// Starts the watchdog. Idempotent.
    static func startWatchdog() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lastMainAnswer = Date()
        lock.unlock()
        let thread = Thread {
            var reported = Date.distantPast
            while true {
                Thread.sleep(forTimeInterval: 1)
                DispatchQueue.main.async {
                    lock.lock(); lastMainAnswer = Date(); lock.unlock()
                }
                lock.lock()
                let silent = Date().timeIntervalSince(lastMainAnswer)
                let last = lastMainStep
                let all = steps
                lock.unlock()
                guard silent > 3, Date().timeIntervalSince(reported) > 5 else { continue }
                reported = Date()
                print("[Launch] ⚠ MAIN THREAD NOT ANSWERING for \(Int(silent)) s. Last main step: \(last)")
                print("[Launch] steps so far:\n" + all.joined(separator: "\n"))
            }
        }
        thread.name = "LaunchProbe.watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
#endif
