//
//  Gen3GameDetector.swift
//  EmulateurGBA
//
//  Detects which Generation 3 GBA game family a loaded ROM belongs to, by
//  reading the 4-character game code from the ROM header.
//
//  The GBA ROM is mapped at 0x08000000; the game code lives at header offset
//  0xAC. Romhacks almost always keep their base game's header, so a FireRed
//  romhack reports `BPRE` and resolves to the FireRed/LeafGreen profile.
//

import Foundation

#if DEBUG

enum Gen3GameDetector {

    /// ROM header game-code address: ROM base 0x08000000 + header offset 0xAC.
    static let gameCodeAddress: UInt32 = 0x0800_00AC

    /// Read the ROM game code and return the matching profile, or nil for a
    /// non-Gen3 / unrecognized ROM (the translation feature then stays dormant).
    static func detect(memory: MemoryReading) -> Gen3GameProfile? {
        guard let code = gameCode(from: memory.readMemory32(gameCodeAddress)) else {
            return nil
        }
        switch code {
        case "BPRE", "BPGE":          // FireRed, LeafGreen
            return .fireRedLeafGreen
        case "AXVE", "AXPE":          // Ruby, Sapphire
            return .rubySapphire
        case "BPEE":                  // Emerald
            return .emerald
        default:
            return nil
        }
    }

    /// Decode a little-endian u32 into its 4 ASCII characters. The header byte
    /// at 0xAC is the first character, so the low byte of the word is char 0.
    /// Returns nil if any byte is outside the printable digit/uppercase range,
    /// i.e. not a real game code (non-GBA ROM, or memory not yet readable).
    static func gameCode(from raw: UInt32) -> String? {
        var chars: [Character] = []
        for shift: UInt32 in [0, 8, 16, 24] {
            let byte = UInt8((raw >> shift) & 0xFF)
            guard byte >= 0x30, byte <= 0x5A else { return nil }   // '0'..'Z'
            chars.append(Character(UnicodeScalar(byte)))
        }
        return String(chars)
    }
}

#endif
