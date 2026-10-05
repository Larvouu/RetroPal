//
//  MultiControllerTests.swift
//  EmulateurGBATests
//
//  Several controllers (1.3.3): the per-console player counts, the bridges'
//  per-player contract, and the roster rules of `ControllerManager` (player
//  order, reorder, release on disconnect, one-player consoles hearing player 1
//  alone), driven through the DEBUG simulated controllers, no hardware.
//
//  Serialized: every test here drives the one shared ControllerManager.
//  And on the main actor, where the app itself drives it: the manager
//  publishes to the views on screen and feeds the navigator, which reads the
//  window, so running these off the main thread made SwiftUI and the Main
//  Thread Checker warn (the log of 2026-09-27), about the tests, not the app.
//

import Testing
import GameController
@testable import EmulateurGBA

@MainActor
@Suite("Several controllers", .serialized)
struct MultiControllerTests {

    // MARK: - Declared once per console

    @Test
    func playerCounts_areTheConsolesOwnPorts() {
        #expect(PresetSystem.gba.playerCount == 1)
        #expect(PresetSystem.gbc.playerCount == 1)
        #expect(PresetSystem.nds.playerCount == 1)
        #expect(PresetSystem.nes.playerCount == 2)
        #expect(PresetSystem.snes.playerCount == 2)
        #expect(PresetSystem.ps1.playerCount == 2)
        #expect(PresetSystem.n64.playerCount == 4)
        #expect(ControllerManager.maxPlayers == 4)
    }

    /// Every console with more than one player must reach a bridge that can
    /// feed a second port. The mapping below mirrors `LibraryView.makeBridge`;
    /// a new multi-player console fails here until its bridge implements
    /// `setKeys:player:`.
    @Test
    func everyMultiPlayerConsole_hasABridgeThatFeedsPlayers() {
        let bridgeClass: [PresetSystem: AnyClass] = [
            .snes: MesenBridge.self, .nes: MesenBridge.self,
            .ps1: PCSXBridge.self, .n64: N64Bridge.self,
        ]
        let selector = #selector(EmulatorBridge.setKeys(_:player:))
        for system in PresetSystem.allCases where system.playerCount > 1 {
            guard let cls = bridgeClass[system] else {
                Issue.record("\(system) takes \(system.playerCount) players but has no bridge listed here")
                continue
            }
            #expect(cls.instancesRespond(to: selector), "\(system)'s bridge cannot feed player 2")
        }
    }

    // MARK: - Roster

    /// Start every roster test from no simulated pads and one heard player,
    /// and restore the handlers the app may have registered.
    private func withManager(_ body: (ControllerManager) -> Void) {
        let manager = ControllerManager.shared
        let buttons = manager.onButtonsChanged
        let back = manager.onBackRequested
        let count = manager.activePlayerCount
        let mapping = manager.activeMapping
        let system = manager.activeSystem
        let keyboardWasAttached = manager.isKeyboardAttached
        defer {
            manager.debugSetSimulatedControllers(0)
            if !keyboardWasAttached, manager.isKeyboardAttached { manager.debugSetKeyboardAttached(false) }
            manager.onButtonsChanged = buttons
            manager.onBackRequested = back
            manager.activePlayerCount = count
            manager.activeMapping = mapping
            manager.activeSystem = system
        }
        manager.debugSetSimulatedControllers(0)
        manager.activePlayerCount = 1
        body(manager)
    }

    /// Regression guard (moved from EmulateurGBATests): when a controller
    /// goes away, its player's mask must be reported as 0 so any button the
    /// player was holding (B during a boss fight, the stick pushed left in a
    /// runner) is released on the bridge side.
    @Test
    func disconnect_clearsHeldButtons() {
        withManager { manager in
            var received: [(Int, UInt32)] = []
            manager.onButtonsChanged = { received.append(($0, $1)) }
            manager.debugSetSimulatedControllers(1)
            manager.debugSetSimulatedControllers(0)
            #expect(received.contains { $0.0 == 0 && $0.1 == 0 },
                    "disconnect must dispatch mask=0 so held buttons release")
        }
    }

    @Test
    func simulatedControllers_areCappedAtFourPlayers() {
        withManager { manager in
            let real = manager.pads.filter { !$0.isSimulated }.count
            manager.debugSetSimulatedControllers(6)
            #expect(manager.pads.count == ControllerManager.maxPlayers)
            #expect(manager.pads.filter(\.isSimulated).count == ControllerManager.maxPlayers - real)
            #expect(manager.isConnected)
        }
    }

    @Test
    func movePad_reordersAndPlayerOneFollows() {
        withManager { manager in
            manager.debugSetSimulatedControllers(3)
            guard manager.pads.count >= 3 else { return }
            let third = manager.pads[2]
            manager.movePad(third.id, toPlayer: 0)
            #expect(manager.pads[0].id == third.id)
            #expect(manager.controllerName == third.name)
            #expect(manager.batteryLevel == third.batteryLevel)
            // Out-of-range targets clamp instead of trapping.
            manager.movePad(third.id, toPlayer: 99)
            #expect(manager.pads.last?.id == third.id)
        }
    }

    /// A one-player console hears player 1 alone; a two-player console hears
    /// players 1 and 2 and nobody else, however many pads are connected.
    @Test
    func onlyTheConsolesPlayersAreReported() {
        withManager { manager in
            manager.debugSetSimulatedControllers(4)
            var players = Set<Int>()
            manager.onButtonsChanged = { player, _ in players.insert(player) }
            manager.activePlayerCount = PresetSystem.snes.playerCount
            manager.movePad(manager.pads[3].id, toPlayer: 0)
            #expect(players == [0, 1])

            players = []
            manager.activePlayerCount = PresetSystem.gba.playerCount
            manager.movePad(manager.pads[3].id, toPlayer: 0)
            // Lowering the count releases player 2 (mask 0) and then reports
            // player 1 alone.
            #expect(players.isSubset(of: [0, 1]))
            players = []
            manager.movePad(manager.pads[2].id, toPlayer: 0)
            #expect(players == [0])
        }
    }

    // MARK: - Every kind of controller together (asked 2026-09-27)

    /// A keyboard, a USB-C pad and a Bluetooth pad: on a phone the keyboard is
    /// a player of its own, numbered with the pads in the order they came, and
    /// each one's input reaches its own player. (A USB-C pad without the full
    /// profile and a Bluetooth one differ only in how their buttons are READ,
    /// `ControllerInputSource.init(profile:)` against `init(_:)`, both tested
    /// in EmulateurGBATests; once read, the roster treats them alike, which is
    /// what the simulated pads stand in for here.)
    @Test
    func keyboardUSBAndBluetooth_areThreePlayers() {
        guard ControllerManager.keyboardIsAPlayer else { return }   // a phone
        withManager { manager in
            manager.activeMapping = nil
            manager.activeSystem = .n64
            manager.activePlayerCount = PresetSystem.n64.playerCount
            manager.debugSetKeyboardAttached(true)
            manager.debugSetSimulatedControllers(min(manager.pads.count + 2, ControllerManager.maxPlayers))
            guard let keyboard = manager.pads.firstIndex(where: { $0.kind == .keyboard }) else {
                Issue.record("the keyboard is not a player on a phone")
                return
            }
            let pads = manager.pads.enumerated().filter { $0.element.isSimulated }
            guard pads.count >= 2 else { return }   // every place taken by real pads

            var received: [(Int, UInt32)] = []
            manager.onButtonsChanged = { received.append(($0, $1)) }

            manager.debugSendKeyboardMask(GBAInput.a.rawValue)
            #expect(received.contains { $0.0 == keyboard && $0.1 == GBAInput.a.rawValue },
                    "the keyboard's A must reach the keyboard's player")

            var press = ControllerInputSource()
            press.faceA = true
            received = []
            manager.debugSendInput(press, fromPad: pads[0].element.id)
            #expect(received.contains { $0.0 == pads[0].offset && $0.1 & GBAInput.a.rawValue != 0 },
                    "the first pad's A must reach its own player")
            #expect(!received.contains { $0.0 == keyboard && $0.1 & GBAInput.a.rawValue == 0 },
                    "a pad's press must not release the keyboard's held A")
            received = []
            manager.debugSendInput(press, fromPad: pads[1].element.id)
            #expect(received.contains { $0.0 == pads[1].offset && $0.1 & GBAInput.a.rawValue != 0 },
                    "the second pad's A must reach its own player")
            manager.debugSendKeyboardMask(0)
        }
    }

    /// Player 1 alone plays the app's roles, whatever it is: the keyboard as
    /// player 1 goes back with its B, a pad further down does not.
    @Test
    func onlyPlayerOne_goesBack_evenWhenItIsTheKeyboard() {
        guard ControllerManager.keyboardIsAPlayer else { return }
        withManager { manager in
            manager.debugSetKeyboardAttached(true)
            manager.debugSetSimulatedControllers(min(manager.pads.count + 1, ControllerManager.maxPlayers))
            guard let keyboardID = manager.pads.first(where: { $0.kind == .keyboard })?.id,
                  let pad = manager.pads.first(where: { $0.isSimulated }) else { return }
            manager.movePad(keyboardID, toPlayer: 0)
            var backs = 0
            manager.onBackRequested = { backs += 1 }

            var east = ControllerInputSource()
            east.faceB = true
            manager.debugSendInput(east, fromPad: pad.id)
            #expect(backs == 0, "a pad that is not player 1 must not go back")

            manager.debugSendKeyboardMask(GBAInput.b.rawValue)
            #expect(backs == 1, "the keyboard as player 1 goes back with its B")
            manager.debugSendKeyboardMask(0)
        }
    }

    /// A two-player console hears no third player, whatever its kind.
    @Test
    func aThirdPlayer_isNotHeard_onATwoPlayerConsole() {
        withManager { manager in
            manager.activeMapping = nil
            manager.activeSystem = .snes
            manager.activePlayerCount = PresetSystem.snes.playerCount
            manager.debugSetSimulatedControllers(3)
            guard manager.pads.count >= 3, manager.pads[2].isSimulated else { return }
            var players = Set<Int>()
            manager.onButtonsChanged = { player, _ in players.insert(player) }
            var press = ControllerInputSource()
            press.faceA = true
            manager.debugSendInput(press, fromPad: manager.pads[2].id)
            #expect(!players.contains(2))
        }
    }

    /// The keyboard as the pad its mapping makes of it, for player 1's roles.
    @Test
    func keyboardMask_readsAsAPad() {
        let s = ControllerManager.snapshot(fromMask: GBAInput.up.rawValue | GBAInput.b.rawValue
                                           | GBAInput.start.rawValue | GBAInput.select.rawValue)
        #expect(s.up && !s.down && s.faceB && !s.faceA)
        #expect(ControllerManager.isMenuCombo(s), "Start+Select held on the keyboard opens the menu too")
    }

    // MARK: - Pure helpers

    @Test
    func menuCombo_isStartWithSelect() {
        var s = ControllerInputSource()
        s.menu = true
        #expect(!ControllerManager.isMenuCombo(s))
        s.hasOptions = true
        s.options = true
        #expect(ControllerManager.isMenuCombo(s))
        // A pad without Options: its Select is the left stick click.
        var noOptions = ControllerInputSource()
        noOptions.menu = true
        noOptions.leftStickClick = true
        #expect(ControllerManager.isMenuCombo(noOptions))
        // With Options present, L3 is not Select here.
        var withOptions = noOptions
        withOptions.hasOptions = true
        #expect(!ControllerManager.isMenuCombo(withOptions))
    }

    @Test
    func freshPress_firesOnlyOnANewPress() {
        var held = ControllerInputSource()
        held.faceA = true
        #expect(ControllerManager.hasFreshPress(held, since: nil))
        #expect(!ControllerManager.hasFreshPress(held, since: held))
        var more = held
        more.up = true
        #expect(ControllerManager.hasFreshPress(more, since: held))
        #expect(!ControllerManager.hasFreshPress(ControllerInputSource(), since: held))
    }
}
