//
//  DiscConsoleQuestion.swift
//  EmulateurGBA
//
//  The question an import asks when a disc image's bytes cannot say which
//  console it belongs to: an `.iso` or a `.chd` whose volume names neither the
//  PlayStation nor the PSP (`ROMSystemType.consoleIsUndecided`). Asked from the
//  import's own background queue, which waits for the answer; shown on the
//  main thread as an alert a finger or a controller can answer
//  (`ControllerAlert`). Added 2026-10-12, after a PSP `.chd` was filed under
//  the PlayStation and could not start.
//

import Foundation

enum DiscConsoleQuestion {
    /// Ask which console `fileName` is for, and wait. `.ps1`, `.psp`, or nil
    /// when the player cancels. Must NOT be called on the main thread, which
    /// it needs free to show the question.
    ///
    /// When there is no screen to ask on, answers the PlayStation at once,
    /// which is what every such image was filed under before this question
    /// existed; the import never waits on a question nobody can see.
    static func ask(fileName: String) -> ROMSystemType? {
        precondition(!Thread.isMainThread, "the console question waits for the main thread")
        let answered = DispatchSemaphore(value: 0)
        var answer: ROMSystemType? = .ps1
        DispatchQueue.main.async {
            let shown = ControllerAlert.present(
                title: NSLocalizedString("import.console.title", comment: ""),
                message: String(format: NSLocalizedString("import.console.message", comment: ""), fileName),
                actions: [
                    .init(title: SystemColor.name(ROMSystemType.ps1.rawValue)) {
                        answer = .ps1
                        answered.signal()
                    },
                    .init(title: SystemColor.name(ROMSystemType.psp.rawValue)) {
                        answer = .psp
                        answered.signal()
                    },
                    .init(title: NSLocalizedString("common.cancel", comment: ""), style: .cancel) {
                        answer = nil
                        answered.signal()
                    },
                ])
            if !shown { answered.signal() }
        }
        answered.wait()
        return answer
    }
}
