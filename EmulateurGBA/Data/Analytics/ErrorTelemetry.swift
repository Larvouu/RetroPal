//
//  ErrorTelemetry.swift
//  EmulateurGBA
//
//  The CLOSED vocabulary of the error signals (2026-10-10), and the mapping
//  from the app's real error types onto it.
//
//  Why a vocabulary and not the error's own text: an error message can carry
//  a file name or a path ("Game (Track 01).bin is missing", an NSError's
//  description), and a game's name is exactly what the anonymity allowlist
//  exists to keep out. So every failure is reduced HERE to one of a fixed set
//  of snake_case words, and `Analytics.sanitized` refuses any `reason` or
//  `phase` value that is not one of them, whatever a call site passes.
//
//  Adding a category: add a case to the right enum. The allowlist reads the
//  enums, so a new case is accepted the moment it exists, and a string typed
//  at a call site that is not a case is dropped. Never rename a case: the raw
//  value is the dashboard's series name.
//

import Foundation

// MARK: - Vocabulary

/// Why a game import failed (`rom_import` result=error, key `reason`).
/// Finer than `errorType`, which stays the `ROMImportError` case name: one
/// `copyFailed` can be a full disk, a source iCloud had not downloaded, or a
/// truncated copy, and those have three different fixes.
enum ImportFailureReason: String, CaseIterable {
    case fileAccessDenied = "file_access_denied"
    /// A copy into the library failed for a cause the file system did not name.
    case copyFailed = "copy_failed"
    /// The device ran out of space while copying (ENOSPC / out-of-space).
    case diskFull = "disk_full"
    /// The source file was not there to read (typically an iCloud Drive file
    /// not downloaded yet, or a file removed while it was being imported).
    case sourceUnavailable = "source_unavailable"
    /// The copy finished with a size different from the source's.
    case copyTruncated = "copy_truncated"
    /// The file was not a game this app reads, cause not narrowed further.
    case invalidROM = "invalid_rom"
    /// An extension the app has no console for.
    case unsupportedExtension = "unsupported_extension"
    /// A known extension whose bytes are not that console's game.
    case invalidHeader = "invalid_header"
    /// A disc image that is not one (no filesystem / magic where it belongs).
    case discNotBootable = "disc_not_bootable"
    /// A disc that is CERTAINLY another console's (PlayStation 2, Sega CD,
    /// Saturn), refused at import (2026-10-12). Kept apart from
    /// `discNotBootable` so demand for those consoles can be read.
    case otherConsoleDisc = "other_console_disc"
    /// A cartridge of a machine the app does not offer: a 32X or a Sega Pico
    /// cartridge in Mega Drive clothing (2026-10-12).
    case otherConsoleCartridge = "other_console_cartridge"
    case discMissingFiles = "disc_missing_files"
    case zipNoROM = "zip_no_rom"
    case zipCorrupt = "zip_corrupt"
    case zipUnsupportedCompression = "zip_unsupported_compression"
    case zipEncrypted = "zip_encrypted"
    case duplicate = "duplicate"
    /// The game was copied but its library entry could not be saved.
    case libraryWriteFailed = "library_write_failed"
    /// Replacing a game's file with a different game.
    case differentGame = "different_game"
    case unknownError = "unknown_error"

    /// The narrowings a `copyFailed` may carry.
    static let copyCauses: Set<ImportFailureReason> = [.diskFull, .sourceUnavailable, .copyTruncated, .fileAccessDenied]
    /// The narrowings an `invalidROM` may carry.
    static let invalidCauses: Set<ImportFailureReason> = [.unsupportedExtension, .invalidHeader, .discNotBootable,
                                                          .otherConsoleDisc, .otherConsoleCartridge]
}

/// Why a game did not start, or stopped (`rom_load_fail`, key `reason`).
enum LoadFailureReason: String, CaseIterable {
    /// Launch preflight: the game's file is not on disk.
    case fileMissing = "file_missing"
    /// Launch preflight: the file (or a disc's folder) exists but its size
    /// could not be read.
    case fileUnreadable = "file_unreadable"
    /// Launch preflight: the file is empty.
    case fileEmpty = "file_empty"
    /// Launch preflight: the size on disk differs from the size recorded at
    /// import (a truncated file, a disc missing a track).
    case sizeMismatch = "size_mismatch"
    /// The file looked intact and the core refused it.
    case coreRejected = "core_rejected"
    /// A Nintendo 64 game built with current libdragon, refused before start.
    case n64Libdragon = "n64_libdragon"
    /// The PSP accepted the file and failed to boot it in its first frames.
    case bootFailed = "boot_failed"
}

/// Why a save failed (`save_failure`, key `reason`).
enum SaveFailureReason: String, CaseIterable {
    /// The core could not write the state with under 100 MB free on the
    /// device, MEASURED at the failure (a condition, not a diagnosis).
    case lowStorage = "low_storage"
    /// iOS refused the file coordination (the iCloud daemon) around the write
    /// or read, so the core was never asked.
    case coordinationFailed = "coordination_failed"
    /// The core answered no with storage available: for a load, the state is
    /// damaged or not one this core can read.
    case coreRefused = "core_refused"
    /// The slot's state file is not on disk.
    case fileMissing = "file_missing"
    /// The file system reported out-of-space.
    case diskFull = "disk_full"
    /// A file write failed for any other reason.
    case writeFailed = "write_failed"
    /// A battery save whose size does not fit the cartridge (moved aside).
    case sizeMismatch = "size_mismatch"
}

/// Why an imported battery save was refused (`save_import_fail`, key `reason`).
enum SaveImportFailureReason: String, CaseIterable {
    case invalidFormat = "invalid_format"
    case fileUnreadable = "file_unreadable"
    /// The save's size is not one this game's console writes.
    case wrongSystem = "wrong_system"
    /// Opened from Files, and no game in the library could take it.
    case noMatchingGame = "no_matching_game"
    case writeFailed = "write_failed"
    case diskFull = "disk_full"
    case unknownError = "unknown_error"
}

/// Which tree an iCloud conflict was resolved in (`icloud_conflict`, `reason`).
enum SyncConflictReason: String, CaseIterable {
    case saveState = "save_state"
    case batterySave = "battery_save"
}

/// iOS's own count of how the app was ended abnormally, from MetricKit's
/// daily exit metrics (`app_exit`, key `reason`). Counts only, never a stack.
enum AppExitReason: String, CaseIterable {
    /// Killed for exceeding its memory limit (jetsam on the app itself).
    case memoryLimit = "memory_limit"
    /// A crash on a bad memory access (EXC_BAD_ACCESS / SIGSEGV / SIGBUS).
    case badAccess = "bad_access"
    /// Any other crash signal (abort, assertion, uncaught exception).
    case abnormal = "abnormal"
    /// A crash on an illegal instruction (Swift traps: force unwrap, overflow).
    case illegalInstruction = "illegal_instruction"
    /// Killed by the watchdog (the main thread blocked too long).
    case watchdog = "watchdog"
    /// Killed for sustained CPU use (background).
    case cpuLimit = "cpu_limit"
    /// Suspended while holding a file lock (background; file coordination).
    case lockedFile = "locked_file"
    /// A background task outlived its assertion (the background auto-save).
    case backgroundTaskTimeout = "background_task_timeout"
}

/// Where the app was when it ended unexpectedly (`unexpected_exit`, key
/// `phase`), or which state iOS counted an exit in (`app_exit`, key `phase`:
/// `foreground` | `background` only).
enum TelemetryPhase: String, CaseIterable {
    /// The first scene coming on screen, before the app's first activation.
    case appLaunch = "app_launch"
    /// In the app, no game open.
    case browsing = "browsing"
    /// A game's core loading the file, before its first frame.
    case startingGame = "starting_game"
    case playing = "playing"
    /// A manual save state being written.
    case savingState = "saving_state"
    /// A save state being read (from the pause menu or at launch).
    case loadingState = "loading_state"
    /// Between Quit and the end of the auto-save and core shutdown.
    case quittingGame = "quitting_game"
    /// A game import running (picker, Files / AirDrop, ZIP selection).
    case importing = "importing"
    case foreground = "foreground"
    case background = "background"
}

/// A game that started and then could not go on, or a pause-menu action the
/// core refused (`game_error`, key `reason`).
enum GameErrorReason: String, CaseIterable {
    /// The N64 or PSP picture could no longer be updated (GPU readback lost).
    case displayLost = "display_lost"
    /// The PlayStation core refused a disc change from the pause menu.
    case discChangeRefused = "disc_change_refused"
}

/// How many exits of one kind a MetricKit payload counted (`app_exit`, key
/// `count`). Bucketed so one bad day cannot be confused with a trend and the
/// signal stays one per kind per day.
enum ExitCountBucket: String, CaseIterable {
    case one = "1"
    case twoToFive = "2-5"
    case sixOrMore = "6+"

    init?(count: Int) {
        switch count {
        case ..<1: return nil
        case 1: self = .one
        case 2...5: self = .twoToFive
        default: self = .sixOrMore
        }
    }
}

// MARK: - Mapping from the app's real errors

enum ErrorTelemetry {

    /// Every value the `reason` key may carry. `Analytics.sanitized` drops
    /// any other.
    static let allReasonValues: Set<String> = {
        var values = Set<String>()
        values.formUnion(ImportFailureReason.allCases.map(\.rawValue))
        values.formUnion(LoadFailureReason.allCases.map(\.rawValue))
        values.formUnion(SaveFailureReason.allCases.map(\.rawValue))
        values.formUnion(SaveImportFailureReason.allCases.map(\.rawValue))
        values.formUnion(SyncConflictReason.allCases.map(\.rawValue))
        values.formUnion(GameErrorReason.allCases.map(\.rawValue))
        values.formUnion(AppExitReason.allCases.map(\.rawValue))
        return values
    }()

    /// Every value the `phase` key may carry.
    static let allPhaseValues: Set<String> = Set(TelemetryPhase.allCases.map(\.rawValue))

    /// Every value the `count` key may carry.
    static let allCountValues: Set<String> = Set(ExitCountBucket.allCases.map(\.rawValue))

    // MARK: File-system causes

    /// What the file system said, narrowed to the three causes worth a
    /// category. Read from the error's domain and code (and its underlying
    /// errors), never from its text.
    enum FileCause: Equatable {
        case diskFull, missing, noPermission
    }

    static func fileCause(of error: Error) -> FileCause? {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 4 {
            if ns.domain == NSCocoaErrorDomain {
                switch ns.code {
                case CocoaError.Code.fileWriteOutOfSpace.rawValue:
                    return .diskFull
                case CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue:
                    return .missing
                case CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue:
                    return .noPermission
                default: break
                }
            } else if ns.domain == NSPOSIXErrorDomain {
                switch ns.code {
                case Int(POSIXErrorCode.ENOSPC.rawValue), Int(POSIXErrorCode.EDQUOT.rawValue):
                    return .diskFull
                case Int(POSIXErrorCode.ENOENT.rawValue):
                    return .missing
                case Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue):
                    return .noPermission
                default: break
                }
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }

    // MARK: Import

    /// The cause a file-system error narrows a failed copy to, or nil when it
    /// names none of the three. A `ROMImportError` passing through (a size
    /// check that already said `copy_truncated`) is not re-read.
    static func copyCause(of error: Error) -> ImportFailureReason? {
        guard !(error is ROMImportError) else { return nil }
        switch fileCause(of: error) {
        case .diskFull: return .diskFull
        case .missing: return .sourceUnavailable
        case .noPermission: return .fileAccessDenied
        case nil: return nil
        }
    }

    /// Why a file was not a game: an extension no console has, or a known
    /// one whose bytes are not that console's.
    static func invalidFileCause(_ url: URL) -> ImportFailureReason {
        guard ROMSystemType.from(fileExtension: url.pathExtension) != nil else { return .unsupportedExtension }
        return GBAROMParser.isOtherSegaMachineCartridge(url: url) ? .otherConsoleCartridge : .invalidHeader
    }

    /// The `reason` for an import failure.
    ///
    /// `noted` is the finer cause the importer recorded where it threw
    /// (`ROMImporter.takeFailureCause`): the `ROMImportError` cases are what
    /// the alert says, and one `copyFailed` can be a full disk, a source
    /// iCloud had not downloaded, or a truncated copy. A note is used only
    /// when it narrows the case actually caught (`copyCauses` for
    /// `copyFailed`, `invalidCauses` for `invalidROM`), so a note left by an
    /// earlier failure can never relabel an unrelated one.
    static func importReason(for error: Error, noted: ImportFailureReason? = nil) -> ImportFailureReason {
        guard let importError = error as? ROMImportError else {
            switch fileCause(of: error) {
            case .diskFull: return .diskFull
            case .missing: return .sourceUnavailable
            case .noPermission: return .fileAccessDenied
            case nil: return .unknownError
            }
        }
        switch importError {
        case .fileAccessDenied: return .fileAccessDenied
        case .copyFailed:
            if let noted, ImportFailureReason.copyCauses.contains(noted) { return noted }
            return .copyFailed
        case .invalidROM:
            if let noted, ImportFailureReason.invalidCauses.contains(noted) { return noted }
            return .invalidROM
        case .zipNoGBA: return .zipNoROM
        // Control flow, never signaled (the selection sheet); mapped only so
        // the switch is exhaustive.
        case .zipNeedsSelection: return .unknownError
        // The player cancelled the console question: never signaled either.
        case .consoleChoiceCancelled: return .unknownError
        case .zipExtractionFailed: return .zipCorrupt
        case .zipUnsupportedCompression: return .zipUnsupportedCompression
        case .zipEncrypted: return .zipEncrypted
        case .alreadyImported: return .duplicate
        case .saveFailed: return .libraryWriteFailed
        case .differentGame: return .differentGame
        case .discMissingFiles: return .discMissingFiles
        }
    }

    // MARK: Battery-save import

    static func saveImportReason(for error: Error) -> SaveImportFailureReason {
        if let e = error as? BatterySaveImportError {
            switch e {
            case .invalidFormat: return .invalidFormat
            case .fileAccessDenied: return .fileUnreadable
            case .writeFailed: return .writeFailed
            // A question to the player, not a failure; mapped for exhaustiveness.
            case .duplicateExists: return .unknownError
            }
        }
        return fileCause(of: error) == .diskFull ? .diskFull : .unknownError
    }

    /// `disk_full` or `write_failed` for a failed file write.
    static func writeReason(for error: Error) -> SaveFailureReason {
        fileCause(of: error) == .diskFull ? .diskFull : .writeFailed
    }

    // MARK: Battery saves

    /// Whether a core just moved this battery save aside as unreadable: the
    /// canonical file is gone and a `<name>.unread-<time>` sits beside it.
    /// Both, because the iCloud mirror replaces a file by removing it first,
    /// and a missing file alone could be that instant.
    static func batterySaveWasMovedAside(_ savePath: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: savePath.path) else { return false }
        let prefix = savePath.lastPathComponent + ".unread-"
        let siblings = (try? fm.contentsOfDirectory(atPath: savePath.deletingLastPathComponent().path)) ?? []
        return siblings.contains { $0.hasPrefix(prefix) }
    }

    // MARK: Launch preflight

    /// The launch preflight's verdict as a category, or nil when the file
    /// passes. Same four tests `EmulatorViewController.loadAndStart` runs, in
    /// the same order, so the category names the test that failed.
    static func preflightReason(exists: Bool, onDiskSize: Int64?, expectedSize: Int64) -> LoadFailureReason? {
        if !exists { return .fileMissing }
        guard let size = onDiskSize else { return .fileUnreadable }
        if size == 0 { return .fileEmpty }
        if expectedSize > 0 && size != expectedSize { return .sizeMismatch }
        return nil
    }

    // MARK: Save states

    /// Free space below which a failed state write is reported as
    /// `low_storage`. A DS state is 32 MB and a PSP one about as much, so
    /// 100 MB is "a state may not fit".
    static let lowStorageBytes: Int64 = 100 * 1024 * 1024

    /// The `reason` for a state write or read the core answered no to.
    /// `coordinated == false` means iOS refused the coordination itself.
    static func stateFailureReason(coordinated: Bool, fileExists: Bool, isWrite: Bool,
                                   availableBytes: Int64?) -> SaveFailureReason {
        if !coordinated { return .coordinationFailed }
        if !isWrite && !fileExists { return .fileMissing }
        if isWrite, let free = availableBytes, free < lowStorageBytes { return .lowStorage }
        return .coreRefused
    }

    /// Free bytes on the volume holding `url`, as iOS reports them for
    /// important (user-initiated) writes. nil when iOS does not say.
    static func availableBytes(near url: URL) -> Int64? {
        let values = try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
