//
//  Gen3GameProfile.swift
//  EmulateurGBA
//
//  Per-base-game data the translation feature needs for a Generation 3 GBA
//  game: the EWRAM addresses of the battle structures, and the battle-UI
//  coordinates where species names are drawn.
//
//  Romhacks keep their base game's ROM header, so a FireRed romhack reports
//  the `BPRE` game code and correctly resolves to `.fireRedLeafGreen`.
//
//  Address confidence:
//   - FireRed / LeafGreen: VERIFIED (Complete FireRed Upgrade BPRE.ld, and
//     confirmed on-device 2026-05-16).
//   - Ruby / Sapphire and Emerald: starting hypotheses, marked VERIFY. A wrong
//     address produces out-of-range species which the reader range-validates
//     into an empty overlay — visibly wrong, never a crash.
//

import CoreGraphics

#if DEBUG

struct Gen3GameProfile {

    enum Family {
        case fireRedLeafGreen
        case rubySapphire
        case emerald
    }

    let family: Family

    /// Address of `gBattleMons[0]` in EWRAM.
    let gBattleMonsBase: UInt32

    /// Address of the `gBattleStruct` pointer in EWRAM, or nil when not yet
    /// verified for this family. When nil, `Gen3BattleReader` falls back to a
    /// species-validity gate: the readout still works during a battle, but is
    /// not cleared the instant the battle ends.
    let gBattleStructPtr: UInt32?

    /// Top-left anchor, in game pixels (240x160 space), of the enemy and player
    /// species-name text in the battle info boxes. VERIFY on-device and nudge.
    let enemyNameAnchor: CGPoint
    let playerNameAnchor: CGPoint

    // MARK: - Built-in profiles

    /// FireRed / LeafGreen (game codes BPRE, BPGE — one shared build).
    /// Battle addresses VERIFIED.
    static let fireRedLeafGreen = Gen3GameProfile(
        family: .fireRedLeafGreen,
        gBattleMonsBase: 0x0202_3BE4,
        gBattleStructPtr: 0x0202_3FE8,
        enemyNameAnchor: CGPoint(x: 13, y: 19),    // VERIFY on-device
        playerNameAnchor: CGPoint(x: 139, y: 73)   // VERIFY on-device
    )

    /// Ruby / Sapphire (game codes AXVE, AXPE — one shared build).
    /// gBattleMonsBase is a hypothesis; gBattleStructPtr left nil until verified.
    static let rubySapphire = Gen3GameProfile(
        family: .rubySapphire,
        gBattleMonsBase: 0x0202_4A80,              // VERIFY on-device
        gBattleStructPtr: nil,                     // VERIFY then fill in
        enemyNameAnchor: CGPoint(x: 13, y: 19),    // VERIFY on-device
        playerNameAnchor: CGPoint(x: 139, y: 73)   // VERIFY on-device
    )

    /// Emerald (game code BPEE).
    /// gBattleMonsBase is a hypothesis; gBattleStructPtr left nil until verified.
    static let emerald = Gen3GameProfile(
        family: .emerald,
        gBattleMonsBase: 0x0202_4084,              // VERIFY on-device
        gBattleStructPtr: nil,                     // VERIFY then fill in
        enemyNameAnchor: CGPoint(x: 13, y: 19),    // VERIFY on-device
        playerNameAnchor: CGPoint(x: 139, y: 73)   // VERIFY on-device
    )
}

#endif
