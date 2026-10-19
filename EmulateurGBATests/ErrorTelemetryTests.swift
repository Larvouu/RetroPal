//
//  ErrorTelemetryTests.swift
//  EmulateurGBATests
//
//  The error signals (2026-10-10): what may leave the device, and what each
//  real failure is called when it does.
//
//  Three things are held here:
//   1. The anonymity gate. The new keys (`reason`, `phase`, `count`) pass
//      only with a word from their closed sets; a file name, a path or an
//      error message in any of them is dropped, and so is an unknown key.
//   2. The mapping. Every `ROMImportError`, `BatterySaveImportError` and file
//      system cause lands on the category the dashboard doc says it does.
//   3. The unexpected-exit marker: armed only while the app is on screen,
//      cleared by every way of leaving on purpose, and decoded defensively.
//

import Testing
import Foundation
import CoreData
@testable import EmulateurGBA

@Suite("ErrorTelemetry")
struct ErrorTelemetryTests {

    // MARK: - 1. The anonymity gate

    @Test func everyCategoryValuePassesTheGate() {
        for value in ErrorTelemetry.allReasonValues {
            #expect(Analytics.sanitized(["reason": value])["reason"] == value, "reason \(value) was dropped")
        }
        for value in ErrorTelemetry.allPhaseValues {
            #expect(Analytics.sanitized(["phase": value])["phase"] == value, "phase \(value) was dropped")
        }
        for value in ErrorTelemetry.allCountValues {
            #expect(Analytics.sanitized(["count": value])["count"] == value, "count \(value) was dropped")
        }
    }

    @Test func freeTextInTheNewKeysIsDropped() {
        let leaks = [
            "Pokemon Emerald (U).gba",
            "/var/mobile/Containers/Data/Application/X/Documents/ROMs/Zelda.gba",
            "The file \u{201C}Game (Track 01).bin\u{201D} couldn\u{2019}t be opened.",
            "copy_failed: Zelda.gba",
            "Disk_Full",
            "",
        ]
        for leak in leaks {
            let clean = Analytics.sanitized(["reason": leak, "phase": leak, "count": leak])
            #expect(clean.isEmpty, "free text passed the gate: \(leak)")
        }
    }

    @Test func unknownKeysAreStillDroppedAndOldKeysUntouched() {
        let clean = Analytics.sanitized([
            "title": "Zelda",
            "filename": "Zelda.gba",
            "path": "/Documents/ROMs/Zelda.gba",
            "message": "The operation couldn\u{2019}t be completed.",
            "result": "error",
            "errorType": "copyFailed",
            "system": "gba",
            "method": "picker",
            "kind": "state_write",
            "reason": ImportFailureReason.diskFull.rawValue,
        ])
        #expect(clean == [
            "result": "error",
            "errorType": "copyFailed",
            "system": "gba",
            "method": "picker",
            "kind": "state_write",
            "reason": "disk_full",
        ])
    }

    /// Every raw value is a plain snake_case word (or a count bucket), so no
    /// category can ever look like, or be mistaken for, user content.
    @Test func categoryValuesAreClosedWords() {
        let word = try! NSRegularExpression(pattern: "^[a-z0-9]+(_[a-z0-9]+)*$")
        for value in ErrorTelemetry.allReasonValues.union(ErrorTelemetry.allPhaseValues) {
            let range = NSRange(value.startIndex..., in: value)
            #expect(word.firstMatch(in: value, range: range) != nil, "not a closed word: \(value)")
        }
    }

    // MARK: - 2. Import mapping

    @Test func everyImportErrorMapsToItsCategory() {
        let cases: [(ROMImportError, ImportFailureReason)] = [
            (.fileAccessDenied, .fileAccessDenied),
            (.copyFailed, .copyFailed),
            (.invalidROM, .invalidROM),
            (.zipNoGBA, .zipNoROM),
            (.zipExtractionFailed, .zipCorrupt),
            (.zipUnsupportedCompression, .zipUnsupportedCompression),
            (.zipEncrypted, .zipEncrypted),
            (.alreadyImported, .duplicate),
            (.saveFailed, .libraryWriteFailed),
            (.differentGame, .differentGame),
            (.discMissingFiles(names: ["Game (Track 02).bin"]), .discMissingFiles),
        ]
        for (error, expected) in cases {
            #expect(ErrorTelemetry.importReason(for: error) == expected, "\(error.analyticsID) mapped wrong")
        }
    }

    /// A note narrows only the case it belongs to: a stale `disk_full` cannot
    /// turn a corrupt ZIP into a full disk.
    @Test func aNoteNarrowsOnlyItsOwnCase() {
        #expect(ErrorTelemetry.importReason(for: ROMImportError.copyFailed, noted: .diskFull) == .diskFull)
        #expect(ErrorTelemetry.importReason(for: ROMImportError.copyFailed, noted: .copyTruncated) == .copyTruncated)
        #expect(ErrorTelemetry.importReason(for: ROMImportError.copyFailed, noted: .sourceUnavailable) == .sourceUnavailable)
        #expect(ErrorTelemetry.importReason(for: ROMImportError.invalidROM, noted: .unsupportedExtension) == .unsupportedExtension)
        #expect(ErrorTelemetry.importReason(for: ROMImportError.invalidROM, noted: .discNotBootable) == .discNotBootable)

        #expect(ErrorTelemetry.importReason(for: ROMImportError.zipExtractionFailed, noted: .diskFull) == .zipCorrupt)
        #expect(ErrorTelemetry.importReason(for: ROMImportError.invalidROM, noted: .diskFull) == .invalidROM)
        #expect(ErrorTelemetry.importReason(for: ROMImportError.copyFailed, noted: .invalidHeader) == .copyFailed)
    }

    @Test func fileSystemErrorsMapByCodeNeverByText() {
        let full = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteOutOfSpace.rawValue)
        let posixFull = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue))
        let missing = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoSuchFile.rawValue)
        let denied = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoPermission.rawValue)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: posixFull])
        let other = NSError(domain: "Zelda.gba", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "no space left on Zelda.gba"])

        #expect(ErrorTelemetry.copyCause(of: full) == .diskFull)
        #expect(ErrorTelemetry.copyCause(of: posixFull) == .diskFull)
        #expect(ErrorTelemetry.copyCause(of: wrapped) == .diskFull)
        #expect(ErrorTelemetry.copyCause(of: missing) == .sourceUnavailable)
        #expect(ErrorTelemetry.copyCause(of: denied) == .fileAccessDenied)
        #expect(ErrorTelemetry.copyCause(of: other) == nil)
        #expect(ErrorTelemetry.copyCause(of: ROMImportError.copyFailed) == nil)

        #expect(ErrorTelemetry.importReason(for: full) == .diskFull)
        #expect(ErrorTelemetry.importReason(for: other) == .unknownError)
        #expect(ErrorTelemetry.writeReason(for: full) == .diskFull)
        #expect(ErrorTelemetry.writeReason(for: other) == .writeFailed)
    }

    @Test func anInvalidFileIsTheExtensionOrTheBytes() {
        #expect(ErrorTelemetry.invalidFileCause(URL(fileURLWithPath: "/tmp/Game.exe")) == .unsupportedExtension)
        #expect(ErrorTelemetry.invalidFileCause(URL(fileURLWithPath: "/tmp/Game.txt")) == .unsupportedExtension)
        #expect(ErrorTelemetry.invalidFileCause(URL(fileURLWithPath: "/tmp/Game.gba")) == .invalidHeader)
        #expect(ErrorTelemetry.invalidFileCause(URL(fileURLWithPath: "/tmp/Game.SFC")) == .invalidHeader)
    }

    /// The importer records the finer cause where it throws, and the caller
    /// takes it once. A file with an extension no console has is the real
    /// path, end to end.
    @Test func theImporterRecordsWhyAFileWasRefused() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let importer = ROMImporter(context: context)
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString).gba")
        // Too short for any console's header: refused by its bytes.
        try Data("this is not a game".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        do {
            _ = try importer.importROM(from: src, method: "picker")
            Issue.record("a .gba holding text should have been refused")
        } catch {
            #expect(ErrorTelemetry.importReason(for: error, noted: importer.takeFailureCause()) == .invalidHeader)
        }
        #expect(importer.takeFailureCause() == nil, "the cause must be taken only once")
    }

    @Test func everySaveImportErrorMapsToItsCategory() {
        #expect(ErrorTelemetry.saveImportReason(for: BatterySaveImportError.invalidFormat) == .invalidFormat)
        #expect(ErrorTelemetry.saveImportReason(for: BatterySaveImportError.fileAccessDenied) == .fileUnreadable)
        #expect(ErrorTelemetry.saveImportReason(for: BatterySaveImportError.writeFailed) == .writeFailed)
        let full = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteOutOfSpace.rawValue)
        #expect(ErrorTelemetry.saveImportReason(for: full) == .diskFull)
    }

    // MARK: - Load and save mapping

    @Test func thePreflightNamesTheTestThatFailed() {
        #expect(ErrorTelemetry.preflightReason(exists: false, onDiskSize: nil, expectedSize: 100) == .fileMissing)
        #expect(ErrorTelemetry.preflightReason(exists: true, onDiskSize: nil, expectedSize: 100) == .fileUnreadable)
        #expect(ErrorTelemetry.preflightReason(exists: true, onDiskSize: 0, expectedSize: 100) == .fileEmpty)
        #expect(ErrorTelemetry.preflightReason(exists: true, onDiskSize: 99, expectedSize: 100) == .sizeMismatch)
        #expect(ErrorTelemetry.preflightReason(exists: true, onDiskSize: 100, expectedSize: 100) == nil)
        // No size recorded at import (older entries): only existence counts.
        #expect(ErrorTelemetry.preflightReason(exists: true, onDiskSize: 99, expectedSize: 0) == nil)
    }

    @Test func aStateFailureIsNamedFromWhatWasMeasured() {
        let plenty: Int64 = 10 * 1024 * 1024 * 1024
        let tight: Int64 = 20 * 1024 * 1024
        #expect(ErrorTelemetry.stateFailureReason(coordinated: false, fileExists: true, isWrite: true, availableBytes: plenty) == .coordinationFailed)
        #expect(ErrorTelemetry.stateFailureReason(coordinated: true, fileExists: true, isWrite: true, availableBytes: tight) == .lowStorage)
        #expect(ErrorTelemetry.stateFailureReason(coordinated: true, fileExists: true, isWrite: true, availableBytes: plenty) == .coreRefused)
        #expect(ErrorTelemetry.stateFailureReason(coordinated: true, fileExists: true, isWrite: true, availableBytes: nil) == .coreRefused)
        #expect(ErrorTelemetry.stateFailureReason(coordinated: true, fileExists: false, isWrite: false, availableBytes: nil) == .fileMissing)
        // A load refused with the file there is a damaged or foreign state,
        // whatever the free space.
        #expect(ErrorTelemetry.stateFailureReason(coordinated: true, fileExists: true, isWrite: false, availableBytes: tight) == .coreRefused)
    }

    @Test func aMovedAsideSaveIsSeenAndAMissingOneIsNot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let save = dir.appendingPathComponent("Sonic.sav")

        // Gone, nothing beside it: not a move aside (an iCloud replace in flight).
        #expect(ErrorTelemetry.batterySaveWasMovedAside(save) == false)

        try Data([1]).write(to: dir.appendingPathComponent("Sonic.sav.unread-1760000000"))
        #expect(ErrorTelemetry.batterySaveWasMovedAside(save) == true)

        // Still there: never a move aside, whatever lies beside it.
        try Data([2]).write(to: save)
        #expect(ErrorTelemetry.batterySaveWasMovedAside(save) == false)
    }

    // MARK: - Exit counts (MetricKit)

    @Test func exitCountsBecomeOneSignalPerNonZeroKind() {
        let params = ExitMetricsReporter.signalParameters(
            foreground: [.memoryLimit: 1, .badAccess: 0, .watchdog: 7],
            background: [.backgroundTaskTimeout: 3])
        #expect(params == [
            ["reason": "memory_limit", "phase": "foreground", "count": "1"],
            ["reason": "watchdog", "phase": "foreground", "count": "6+"],
            ["reason": "background_task_timeout", "phase": "background", "count": "2-5"],
        ])
        for p in params {
            #expect(Analytics.sanitized(p) == p, "an app_exit parameter was dropped: \(p)")
        }
        #expect(ExitMetricsReporter.signalParameters(foreground: [:], background: [:]).isEmpty)
    }

    @Test func countBuckets() {
        #expect(ExitCountBucket(count: 0) == nil)
        #expect(ExitCountBucket(count: -1) == nil)
        #expect(ExitCountBucket(count: 1) == .one)
        #expect(ExitCountBucket(count: 5) == .twoToFive)
        #expect(ExitCountBucket(count: 6) == .sixOrMore)
    }
}

// MARK: - 3. The unexpected-exit marker

@Suite("SessionLiveness")
struct SessionLivenessTests {

    private func makeTracker() -> (SessionLiveness, UserDefaults) {
        let suite = "telemetry-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SessionLiveness(defaults: defaults), defaults)
    }

    /// What the marker says, without the phone's start-up time it also
    /// carries (`aPowerLossIsNotAnUnexpectedExit` tests that one).
    private func stored(_ defaults: UserDefaults) -> [String: String]? {
        (defaults.dictionary(forKey: SessionLiveness.markerKey) as? [String: String])?
            .filter { $0.key != "boot" }
    }

    @Test func nothingIsArmedBeforeTheAppIsOnScreen() {
        let (tracker, defaults) = makeTracker()
        tracker.begin(.importing)
        #expect(stored(defaults) == nil, "a prewarmed process must not arm the marker")
        #expect(tracker.currentRecord == nil)
    }

    @Test func theMarkerFollowsWhatTheAppIsDoing() {
        let (tracker, defaults) = makeTracker()
        tracker.appWillEnterForeground()
        #expect(stored(defaults) == ["phase": "app_launch"])
        tracker.appDidBecomeActive()
        #expect(stored(defaults) == ["phase": "browsing"])

        let token = tracker.gameWillStart(system: "psp")
        #expect(stored(defaults) == ["phase": "starting_game", "system": "psp"])
        tracker.end(.startingGame)
        #expect(stored(defaults) == ["phase": "playing", "system": "psp"])
        tracker.begin(.savingState)
        #expect(stored(defaults) == ["phase": "saving_state", "system": "psp"])
        tracker.end(.savingState)
        tracker.begin(.quittingGame)
        #expect(stored(defaults) == ["phase": "quitting_game", "system": "psp"])
        tracker.gameScreenDidClose()
        #expect(stored(defaults) == ["phase": "quitting_game", "system": "psp"], "a quit keeps its phase until its save ends")
        tracker.gameEnded(generation: token)
        #expect(stored(defaults) == ["phase": "browsing"])
    }

    @Test func leavingOnPurposeClearsIt() {
        let (tracker, defaults) = makeTracker()
        tracker.appDidBecomeActive()
        _ = tracker.gameWillStart(system: "n64")
        tracker.end(.startingGame)
        #expect(stored(defaults) != nil)

        // Resign active (the app switcher, Home, a lock): cleared, so a
        // swipe-away from the switcher is never reported.
        tracker.appDidEnterBackground()
        #expect(stored(defaults) == nil)
        #expect(tracker.consumePreviousRecord() == nil)

        // Back on screen, the game is still open: armed again as playing.
        tracker.appDidBecomeActive()
        #expect(stored(defaults) == ["phase": "playing", "system": "n64"])
    }

    @Test func aMarkerLeftBehindIsReportedOnceAtTheNextLaunch() {
        let (crashed, defaults) = makeTracker()
        crashed.appDidBecomeActive()
        _ = crashed.gameWillStart(system: "nds")
        crashed.end(.startingGame)
        crashed.begin(.loadingState)
        // The process dies here: nothing clears the marker.

        let nextLaunch = SessionLiveness(defaults: defaults)
        let record = nextLaunch.consumePreviousRecord()
        #expect(record == SessionLiveness.Record(phase: .loadingState, system: "nds"))
        #expect(record?.parameters == ["phase": "loading_state", "system": "nds"])
        #expect(Analytics.sanitized(record?.parameters ?? [:]) == record?.parameters)
        #expect(nextLaunch.consumePreviousRecord() == nil, "reported once, then cleared")
    }

    @Test func aLateQuitDoesNotEndTheNextGame() {
        let (tracker, defaults) = makeTracker()
        tracker.appDidBecomeActive()
        let first = tracker.gameWillStart(system: "gba")
        tracker.begin(.quittingGame)
        _ = tracker.gameWillStart(system: "snes")
        tracker.gameEnded(generation: first)
        #expect(stored(defaults) == ["phase": "starting_game", "system": "snes"])
    }

    @Test func anEndOnlyClearsItsOwnPhase() {
        let (tracker, defaults) = makeTracker()
        tracker.appDidBecomeActive()
        tracker.begin(.importing)
        tracker.end(.savingState)
        #expect(stored(defaults) == ["phase": "importing"])
        tracker.end(.importing)
        #expect(stored(defaults) == ["phase": "browsing"])
    }

    @Test func aStoredMarkerIsReadDefensively() {
        #expect(SessionLiveness.decode(["phase": "Zelda.gba"]) == nil)
        #expect(SessionLiveness.decode([:]) == nil)
        #expect(SessionLiveness.decode(["phase": "playing", "system": "Zelda.gba"])
                == SessionLiveness.Record(phase: .playing, system: "unknown"))
        #expect(SessionLiveness.decode(["phase": "playing", "system": "md"])
                == SessionLiveness.Record(phase: .playing, system: "md"))
        #expect(SessionLiveness.decode(["phase": "browsing"])
                == SessionLiveness.Record(phase: .browsing, system: nil))
    }

    /// A phone that lost power with the app on screen came back with a new
    /// start-up time: that is a power event, never reported (2026-10-10). The
    /// same start-up, read a few seconds apart, is still a crash.
    @Test func aPowerLossIsNotAnUnexpectedExit() {
        let record = SessionLiveness.Record(phase: .playing, system: "psp")
        let written = SessionLiveness.encode(record, bootTime: 1_000_000)
        #expect(written["boot"] == "1000000")
        #expect(!SessionLiveness.phoneRestarted(since: written, now: 1_000_003))
        #expect(SessionLiveness.phoneRestarted(since: written, now: 1_090_000))
        // A marker from before the start-up time was recorded is reported.
        #expect(!SessionLiveness.phoneRestarted(since: ["phase": "playing"], now: 1_090_000))

        // End to end: a marker written on this start-up is consumed as a crash.
        let suite = "telemetry-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(SessionLiveness.encode(record), forKey: SessionLiveness.markerKey)
        #expect(SessionLiveness(defaults: defaults).consumePreviousRecord() == record)
        // And one from an earlier start-up is not.
        defaults.set(SessionLiveness.encode(record, bootTime: 1), forKey: SessionLiveness.markerKey)
        #expect(SessionLiveness(defaults: defaults).consumePreviousRecord() == nil)
    }
}

/// The Pro signals carry the console of the game on screen (2026-10-10).
struct ProSignalSystemTests {
    @Test func theProSignalsCarryTheGameOnScreen() {
        for name in ["pro_sheet_shown", "pro_feature_used", "pro_purchased"] {
            #expect(Analytics.withGameSystem(name, ["trigger": "speedTapped"], current: "psp")["system"] == "psp",
                    "\(name)")
            // Outside a game, nothing is added.
            #expect(Analytics.withGameSystem(name, ["trigger": "speedTapped"], current: nil)["system"] == nil,
                    "\(name)")
            // A call that names its console keeps it.
            #expect(Analytics.withGameSystem(name, ["system": "gbc"], current: "psp")["system"] == "gbc",
                    "\(name)")
        }
        // Every other signal is left as it is.
        #expect(Analytics.withGameSystem("rewind_used", [:], current: "psp")["system"] == nil)
        // And the console passes the anonymity gate.
        #expect(Analytics.sanitized(Analytics.withGameSystem("pro_sheet_shown", [:], current: "md"))["system"] == "md")
    }
}
