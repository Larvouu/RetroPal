//
//  TranslationProbe.swift
//  EmulateurGBA
//
//  Drives the in-game translation feature. On each poll it reads the current
//  Gen 3 battle state from emulator RAM (via Gen3BattleReader), resolves
//  species and move IDs to localized names (via NameTable), and produces a
//  TranslationFrame: positioned species names for the on-screen overlay, plus
//  a debug text line (which still carries the move names in Phase 1).
//
//  Phase 1 of the in-game translation feature. The whole feature is `#if DEBUG`.
//
//    EmulatorSession ──▶ Gen3BattleReader ──▶ snapshot
//                              │
//          NameTable ◀─────────┘
//                │
//                ▼
//        TranslationFrame ──▶ BattleOverlayView (species) + debug label (moves)
//

import CoreGraphics

#if DEBUG

/// One poll's output: what the overlay should draw, and the debug text line.
struct TranslationFrame {
    /// Positioned species names for `BattleOverlayView`. Empty when not in a
    /// battle.
    let overlayItems: [BattleOverlayItem]
    /// Human-readable readout for the debug text label (species + move names).
    let debugText: String
}

final class TranslationProbe {

    private let profile: Gen3GameProfile
    private let reader: Gen3BattleReader
    private let names = NameTable()
    private let language = NameLanguage.current

    init(session: EmulatorSession, profile: Gen3GameProfile) {
        self.profile = profile
        self.reader = Gen3BattleReader(memory: session, profile: profile)
    }

    /// Read the battle once. Returns positioned overlay items (player + enemy
    /// species) and a debug text line, or an empty frame when not in a battle.
    func poll() -> TranslationFrame {
        guard let snapshot = reader.readBattle() else {
            return TranslationFrame(overlayItems: [],
                                    debugText: "translation: no battle data")
        }

        var overlay: [BattleOverlayItem] = []
        var lines: [String] = []

        for (index, battler) in snapshot.battlers.enumerated() {
            guard battler.species != 0 else { continue }   // empty slot
            let species = speciesLabel(battler.species)

            // Overlay: player (battler 0) and enemy (battler 1) only. Doubles
            // partners have no info-box anchor in Phase 1 — debug text only.
            if let anchor = nameAnchor(for: index) {
                overlay.append(BattleOverlayItem(text: species, gameAnchor: anchor))
            }

            let moves = battler.moves
                .filter { $0 != 0 }
                .map { moveLabel($0) }
                .joined(separator: ", ")
            let movePart = moves.isEmpty ? "" : "  [\(moves)]"
            lines.append("\(Self.role(for: index)): \(species)\(movePart)")
        }

        let debug = lines.isEmpty ? "translation: no battle data"
                                  : lines.joined(separator: "\n")
        return TranslationFrame(overlayItems: overlay, debugText: debug)
    }

    // MARK: - Helpers

    /// Game-pixel anchor for a battler's species name, or nil for slots with
    /// no info box in Phase 1 (doubles partners).
    private func nameAnchor(for battlerIndex: Int) -> CGPoint? {
        switch battlerIndex {
        case 0:  return profile.playerNameAnchor
        case 1:  return profile.enemyNameAnchor
        default: return nil
        }
    }

    /// Localized species name, or "#<id>" when the id is outside the dataset.
    private func speciesLabel(_ id: UInt16) -> String {
        names.speciesName(id: Int(id), language: language) ?? "#\(id)"
    }

    /// Localized move name, or "#<id>" when the id is outside the dataset.
    private func moveLabel(_ id: UInt16) -> String {
        names.moveName(id: Int(id), language: language) ?? "#\(id)"
    }

    private static func role(for battlerIndex: Int) -> String {
        switch battlerIndex {
        case 0:  return "P"    // player's active Pokémon
        case 1:  return "E"    // enemy's active Pokémon
        case 2:  return "P2"   // doubles: player partner
        case 3:  return "E2"   // doubles: enemy partner
        default: return "?"
        }
    }
}

#endif
