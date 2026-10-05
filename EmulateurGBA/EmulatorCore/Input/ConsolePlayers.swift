//
//  ConsolePlayers.swift
//  EmulateurGBA
//
//  How many players each console takes, declared ONCE, here.
//
//  The number is a fact about the hardware: how many controller ports the
//  console had without an adapter. It decides how many connected controllers a
//  game on that console hears. Player 1 always plays; players 2 to N are the
//  next controllers in the order Settings shows, and any controller beyond the
//  console's count is ignored while that console runs, exactly as a pad with no
//  port to plug into would be.
//
//  A future console states its number in `playerCount` and nothing else in the
//  input path changes: `ControllerManager` feeds that many players, and a bridge
//  whose console takes more than one implements `setKeys:player:` (a unit test
//  holds every multi-player console to that).
//

import Foundation

extension PresetSystem {
    /// The players this console's own ports took. Multitaps and four-player
    /// adapters (the NES Four Score, the SNES and PlayStation multitaps) were
    /// accessories, so they are not counted.
    var playerCount: Int {
        switch self {
        case .gba, .gbc, .nds: return 1   // one console, one player
        case .nes, .snes, .ps1: return 2  // two controller ports
        case .n64: return 4               // four controller ports
        }
    }
}

extension ControllerManager {
    /// The most players any console takes, which is also how many controllers
    /// the app adopts at once. Derived from the consoles rather than stated, so
    /// a console with more ports raises it by existing.
    static let maxPlayers: Int = PresetSystem.allCases.map(\.playerCount).max() ?? 1
}
