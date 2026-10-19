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
        case .gba, .gbc, .nds, .gg, .psp: return 1   // one console, one player
        case .nes, .snes, .ps1, .md, .sms: return 2  // two controller ports
        case .n64: return 4               // four controller ports
        }
    }
}

/// "Play as Player 2", a choice per GAME on its page (asked by a player
/// 2026-10-12, to practise as player 2 in Street Fighter II, as Delta allows;
/// moved from Settings to the game's page the same day). Free, like
/// the second controller.
///
/// It is about the PERSON, not the input: whatever they play with is player 2.
/// The touch controls, or the controller in their hands (Settings ▸ Players'
/// first), and the second controller then plays player 1: the console's two
/// ports are swapped, nothing else. Only on a console with a second port.
enum PlayAsPlayerTwo {
    static func key(romBasename: String) -> String { "playAsP2_\(romBasename)" }

    static func isOn(romBasename: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(romBasename: romBasename))
    }

    /// Whether a game of this library console (`GameEntity.systemType`) can be
    /// played as Player 2: its console has a second port. The game's page asks
    /// it to show the row; the answer is the console's own `playerCount`.
    static func isOffered(systemType: String?) -> Bool {
        guard let raw = systemType, let system = ROMSystemType(rawValue: raw) else { return false }
        let family: PresetSystem
        switch system {
        case .gb, .gbc: family = .gbc
        case .gba:      family = .gba
        case .nds:      family = .nds
        case .snes:     family = .snes
        case .nes:      family = .nes
        case .ps1:      family = .ps1
        case .n64:      family = .n64
        case .md:       family = .md
        case .sms:      family = .sms
        case .gg:       family = .gg
        case .psp:      family = .psp
        }
        return family.playerCount > 1
    }

    /// The console port a player of the app's order plays (0-based). Ports 1
    /// and 2 swap while the choice is on, on a console that has a second;
    /// every other port, and every one-player console, is unchanged.
    static func port(forPlayer player: Int, system: PresetSystem, isOn: Bool) -> Int {
        guard isOn, system.playerCount > 1, player < 2 else { return player }
        return 1 - player
    }
}

extension ControllerManager {
    /// The most players any console takes, which is also how many controllers
    /// the app adopts at once. Derived from the consoles rather than stated, so
    /// a console with more ports raises it by existing.
    static let maxPlayers: Int = PresetSystem.allCases.map(\.playerCount).max() ?? 1
}
