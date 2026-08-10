//
//  CheatCodeFormatter.swift
//  EmulateurGBA
//
//  Typing GameShark codes on glass is the worst part of an otherwise good Pro
//  feature. Two jobs here, both pure functions so they are testable without a
//  running core:
//
//   1. `formatted` — tidy the text as it is typed or pasted.
//   2. `problem` — a shape check run BEFORE the core, so a rejection can say
//      WHY instead of only "not recognised".
//
//  Deliberately CONSERVATIVE. The core (which tries five cheat types in turn)
//  stays the final authority and accepts shapes we do not model, so this only
//  reports mistakes it can name with certainty. Anything it is unsure about it
//  passes through untouched, and the core's own refusal remains the fallback
//  message. A pre-flight check that rejected a code the core would have
//  accepted would be a regression, not a feature.
//

import Foundation

enum CheatCodeFormatter {

    /// A problem precise enough to be worth its own message.
    enum Problem: Equatable {
        /// Something that is not a hex digit, space, newline or dash.
        case invalidCharacter
        /// Action Replay DS wants two 8-digit blocks per line, always.
        case unpairedLine
    }

    /// Characters a cheat code may legitimately contain. Dashes are allowed
    /// because Game Boy Game Genie codes are written `XXX-XXX-XXX`.
    private static let allowed = Set("0123456789ABCDEFabcdef -\n")

    // MARK: - Formatting

    /// Tidies `new` given what the field held before.
    ///
    /// Only reformats when the edit was an append or a paste at the END of the
    /// text. Rewriting the string while someone edits its middle would send the
    /// caret to the end on every keystroke, which is worse than no formatting
    /// at all. Typing and pasting are how codes are actually entered, and both
    /// are appends.
    static func formatted(_ new: String, previous: String, isNDS: Bool) -> String {
        guard previous.isEmpty || (new.count > previous.count && new.hasPrefix(previous)) else {
            return new
        }
        let lines = new.components(separatedBy: "\n")
        return lines.map { regroup($0.uppercased(), isNDS: isNDS) }.joined(separator: "\n")
    }

    /// Splits an unbroken run of hex into the blocks its length implies.
    /// Lengths that are ambiguous are left exactly as typed.
    private static func regroup(_ line: String, isNDS: Bool) -> String {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty, compact.allSatisfy(\.isHexDigit) else { return line }
        switch compact.count {
        case 16:
            // Action Replay DS, GameShark GBA v3, Action Replay GBA.
            return split(compact, at: 8)
        case 12 where !isNDS:
            // CodeBreaker GBA: eight digits then four.
            return split(compact, at: 8)
        default:
            return line
        }
    }

    private static func split(_ s: String, at index: Int) -> String {
        let cut = s.index(s.startIndex, offsetBy: index)
        return String(s[..<cut]) + " " + String(s[cut...])
    }

    // MARK: - Validation

    /// The shape problem, if there is one we can name. `nil` means "hand it to
    /// the core", not "this code is valid".
    static func problem(in code: String, isNDS: Bool) -> Problem? {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if code.contains(where: { !allowed.contains($0) }) { return .invalidCharacter }

        // Only the DS format is unambiguous enough to check block by block. GBA
        // and Game Boy accept several shapes (GameShark, CodeBreaker, Action
        // Replay, Game Genie), so their block lengths are left to the core.
        guard isNDS else { return nil }
        for line in code.components(separatedBy: "\n") {
            let blocks = line.split(separator: " ").map(String.init)
            if blocks.isEmpty { continue }   // blank lines are fine
            guard blocks.count == 2, blocks.allSatisfy({ $0.count == 8 }) else {
                return .unpairedLine
            }
        }
        return nil
    }
}
