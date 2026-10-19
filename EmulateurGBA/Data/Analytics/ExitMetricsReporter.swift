//
//  ExitMetricsReporter.swift
//  EmulateurGBA
//
//  iOS's own count of how the app ended abnormally, forwarded as categories
//  (2026-10-10). MetricKit, a system framework: no SDK, no stack trace, no
//  diagnostic payload. Only the exit COUNTS of `MXAppExitMetric` are read,
//  one `app_exit {reason, phase, count}` per non-zero kind, where `count` is
//  a bucket. iOS delivers a payload about once a day, so this costs a handful
//  of signals per user per day at most, and none on a day nothing went wrong.
//
//  It covers what `SessionLiveness` cannot: deaths while the app was not
//  active (the background auto-save, a suspended app killed for a reason
//  other than reclaiming memory). Normal exits and background memory-pressure
//  exits are iOS doing its job and are not reported.
//

import Foundation
import MetricKit

final class ExitMetricsReporter: NSObject, MXMetricManagerSubscriber {

    static let shared = ExitMetricsReporter()

    private var started = false

    /// Subscribe once, at launch.
    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            // Typed as optionals on purpose: whichever way the SDK declares
            // them, this reads both.
            let fg: MXForegroundExitData? = exits.foregroundExitData
            let bg: MXBackgroundExitData? = exits.backgroundExitData
            var foreground: [AppExitReason: Int] = [:]
            if let fg {
                foreground[.memoryLimit] = Int(fg.cumulativeMemoryResourceLimitExitCount)
                foreground[.badAccess] = Int(fg.cumulativeBadAccessExitCount)
                foreground[.abnormal] = Int(fg.cumulativeAbnormalExitCount)
                foreground[.illegalInstruction] = Int(fg.cumulativeIllegalInstructionExitCount)
                foreground[.watchdog] = Int(fg.cumulativeAppWatchdogExitCount)
            }
            var background: [AppExitReason: Int] = [:]
            if let bg {
                background[.memoryLimit] = Int(bg.cumulativeMemoryResourceLimitExitCount)
                background[.badAccess] = Int(bg.cumulativeBadAccessExitCount)
                background[.abnormal] = Int(bg.cumulativeAbnormalExitCount)
                background[.illegalInstruction] = Int(bg.cumulativeIllegalInstructionExitCount)
                background[.watchdog] = Int(bg.cumulativeAppWatchdogExitCount)
                background[.cpuLimit] = Int(bg.cumulativeCPUResourceLimitExitCount)
                background[.lockedFile] = Int(bg.cumulativeSuspendedWithLockedFileExitCount)
                background[.backgroundTaskTimeout] = Int(bg.cumulativeBackgroundTaskAssertionTimeoutExitCount)
            }
            for params in Self.signalParameters(foreground: foreground, background: background) {
                Analytics.signal("app_exit", params)
            }
        }
    }

    /// One parameter set per non-zero kind, in a stable order (foreground
    /// first, then the enum's order). Pure, for the tests.
    static func signalParameters(foreground: [AppExitReason: Int],
                                 background: [AppExitReason: Int]) -> [[String: String]] {
        var out: [[String: String]] = []
        let sides: [(TelemetryPhase, [AppExitReason: Int])] = [(.foreground, foreground), (.background, background)]
        for (phase, counts) in sides {
            for reason in AppExitReason.allCases {
                guard let n = counts[reason], let bucket = ExitCountBucket(count: n) else { continue }
                out.append(["reason": reason.rawValue, "phase": phase.rawValue, "count": bucket.rawValue])
            }
        }
        return out
    }
}
