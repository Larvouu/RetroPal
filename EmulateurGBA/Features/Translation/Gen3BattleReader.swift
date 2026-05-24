//
//  Gen3BattleReader.swift
//  EmulateurGBA
//
//  Reads the active battle state of a Generation 3 Pokémon game directly from
//  emulator RAM. The recognition step of the in-game translation feature:
//  instead of OCR-ing rendered pixels, it reads the game's own structured
//  `gBattleMons` array and returns plain species / move IDs.
//
//  Game-family-specific addresses come from a `Gen3GameProfile`; the
//  `BattlePokemon` struct layout is constant across all Gen 3 games.
//
//  Data flow:
//
//    EmulatorSession (MemoryReading)
//        │  readMemory16 / readMemory32
//        ▼
//    Gen3BattleReader.readBattle()
//        │  gBattleMons[0..3]: species @ +0x00, moves @ +0x0C..+0x12
//        ▼
//    Gen3BattleSnapshot  →  NameTable  →  TranslationProbe
//

import Foundation

#if DEBUG

/// Minimal memory-read surface needed by the translation feature.
/// `EmulatorSession` conforms to this (see bottom of file); a test can supply
/// a mock backed by a captured RAM buffer, keeping the readers unit-testable
/// without a live core.
protocol MemoryReading {
    func readMemory16(_ address: UInt32) -> UInt16
    func readMemory32(_ address: UInt32) -> UInt32
}

/// One battler slot's decoded state.
struct Gen3Battler {
    /// Species index (Gen 3 internal index). 0 means the slot held no valid
    /// species. See NameTable for the internal-index keying.
    let species: UInt16
    /// The four move-slot IDs. 0 means an empty slot.
    let moves: [UInt16]
}

/// The decoded battle, one entry per battler slot.
struct Gen3BattleSnapshot {
    /// Battler 0 = player's active Pokémon, 1 = opponent's active,
    /// 2 / 3 = doubles partners.
    let battlers: [Gen3Battler]
}

struct Gen3BattleReader {

    // MARK: - Gen 3 constant BattlePokemon layout
    //
    // The `struct BattlePokemon` layout is identical across all Gen 3 games.
    // Only the base addresses differ between games — those live in the
    // Gen3GameProfile. Confirmed on-device against FireRed US 1.0.

    /// sizeof(struct BattlePokemon).
    static let battlerStride: UInt32 = 0x58
    /// Offset of `species` within BattlePokemon.
    static let speciesOffset: UInt32 = 0x00
    /// Offset of `moves[0]` within BattlePokemon (4 × u16, contiguous).
    static let movesOffset: UInt32 = 0x0C
    /// Number of battler slots in `gBattleMons`.
    static let battlerCount = 4

    /// Valid Gen 3 species index range. Outside this = treated as "no data".
    static let speciesRange: ClosedRange<UInt16> = 1...411
    /// Valid Gen 3 move ID range. 0 is a legitimate "empty move slot".
    static let moveRange: ClosedRange<UInt16> = 0...354

    private let memory: MemoryReading
    private let profile: Gen3GameProfile

    init(memory: MemoryReading, profile: Gen3GameProfile) {
        self.memory = memory
        self.profile = profile
    }

    /// Read all battler slots. Returns `nil` when not in a battle, or when no
    /// slot holds a valid species (a wrong `gBattleMonsBase` looks the same and
    /// is equally safe — an empty overlay, never a crash).
    func readBattle() -> Gen3BattleSnapshot? {
        // When the profile has a verified gBattleStruct pointer, use it as the
        // in-battle gate: the engine NULLs it at battle end, so the readout
        // clears the instant a battle ends. Without it, the species-validity
        // check below still works during battle but keeps stale data after.
        if let structPtr = profile.gBattleStructPtr {
            guard memory.readMemory32(structPtr) != 0 else { return nil }
        }

        var battlers: [Gen3Battler] = []
        var anyValid = false

        for i in 0..<Self.battlerCount {
            let base = profile.gBattleMonsBase + UInt32(i) * Self.battlerStride

            let rawSpecies = memory.readMemory16(base + Self.speciesOffset)
            let validSpecies = Self.speciesRange.contains(rawSpecies)
            if validSpecies { anyValid = true }

            var moves: [UInt16] = []
            for m in 0..<4 {
                let raw = memory.readMemory16(base + Self.movesOffset + UInt32(m) * 2)
                moves.append(Self.moveRange.contains(raw) ? raw : 0)
            }

            battlers.append(Gen3Battler(species: validSpecies ? rawSpecies : 0,
                                        moves: moves))
        }

        return anyValid ? Gen3BattleSnapshot(battlers: battlers) : nil
    }
}

// `EmulatorSession` already exposes `readMemory16(_:)` and `readMemory32(_:)`
// with the matching signatures, so conformance needs no extra code.
extension EmulatorSession: MemoryReading {}

#endif
