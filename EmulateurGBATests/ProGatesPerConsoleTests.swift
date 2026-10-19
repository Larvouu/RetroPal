//
//  ProGatesPerConsoleTests.swift
//  EmulateurGBATests
//
//  "Is Pro the same on every console?" written down, one row per console.
//
//  The audit of 2026-10-10 (the six consoles since the PlayStation against the
//  six before it) found every Pro gate keyed on the `isPro` flag and nothing
//  else: no gate asks which console is running, so none can be skipped for a
//  new one. These tests hold that shape. A future gate that grows a
//  `switch system` with a default of "no Pro here" breaks a row below instead
//  of quietly costing a console its upsell.
//
//  The two things that DO differ by console, on purpose, are pinned as well:
//  custom skins and the console share card are not built for the Master
//  System, the Game Gear and the PSP. There, the Pro invitation that leads to
//  them must not exist either.
//
//  Each test that flips `isPro` puts the stored value back, whatever happens.
//

import Testing
import Foundation
import GameController
@testable import EmulateurGBA

// Main actor: `ConsoleChoiceList` is a SwiftUI view, as in EngineAndLegalCoverageTests.
@MainActor
@Suite("Pro gates, every console", .serialized)
struct ProGatesPerConsoleTests {

    /// The reference consoles (GBA, Game Boy and Game Boy Color as one layout
    /// family, DS, Super Nintendo, NES), and the six added since the
    /// PlayStation. Together they must be every console the app plays.
    private static let reference: [PresetSystem] = [.gba, .gbc, .nds, .snes, .nes]
    private static let added: [PresetSystem] = [.ps1, .n64, .md, .sms, .gg, .psp]

    /// Runs `body` with the Pro flag at `pro`, then restores what was stored.
    private func withPro(_ pro: Bool, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "isPro")
        defaults.set(pro, forKey: "isPro")
        defer {
            if let previous { defaults.set(previous, forKey: "isPro") } else { defaults.removeObject(forKey: "isPro") }
        }
        try body()
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProGates-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theAuditCoversEveryConsole() {
        #expect(Set(Self.reference + Self.added) == Set(PresetSystem.allCases),
                "a console is missing from the audit lists: \(PresetSystem.allCases)")
    }

    // MARK: - Save slots 3 to 5

    /// Two slots free, five with Pro, on every console: the lock is the slot
    /// number and the flag, never the game's console.
    @Test(arguments: PresetSystem.allCases)
    func saveSlotsLockTheSameWay(_ system: PresetSystem) {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SaveStateManager(romName: "progate-\(system.rawValue)", baseDir: dir)

        withPro(false) {
            let slots = manager.allManualSlotsWithLockState()
            #expect(slots.count == SaveStateManager.manualSlotCount, "\(system): \(slots.count) slots")
            #expect(slots.map { $0.isLocked } == [false, false, true, true, true],
                    "\(system) free slots lock as \(slots.map { $0.isLocked })")
        }
        withPro(true) {
            let slots = manager.allManualSlotsWithLockState()
            #expect(slots.allSatisfy { !$0.isLocked }, "\(system): a Pro slot stays locked")
        }
    }

    // MARK: - Rewind 5 s / 30 s

    /// The depth a tier reaches is one rule for every console, and the free
    /// tier never gets the long-press row (one depth, no choice).
    @Test(arguments: PresetSystem.allCases)
    func rewindTiersAreTheSame(_ system: PresetSystem) {
        #expect(RewindDepths.tapSeconds(isPro: false, playedSeconds: 600) == 5, "\(system) free tap")
        #expect(RewindDepths.tapSeconds(isPro: true, playedSeconds: 600) == 10, "\(system) Pro tap")
        #expect(RewindDepths.available(maxSeconds: 5, playedSeconds: 600).count <= 1, "\(system) free row")
        #expect(RewindDepths.available(maxSeconds: 30, playedSeconds: 600) == RewindDepths.steps, "\(system) Pro row")
    }

    // MARK: - Video filters

    /// A stored filter renders for Pro and never for a free player, whatever
    /// the console. The Screen tab that offers them is shown on every console
    /// (`EmulatorViewController.appearanceShowsTabs` is true).
    @Test(arguments: PresetSystem.allCases)
    func filtersAreProOnEveryConsole(_ system: PresetSystem) {
        let rom = "progate-filter-\(system.rawValue)-\(UUID().uuidString)"
        let key = VideoFilter.storageKey(forRomBasename: rom)
        UserDefaults.standard.set(VideoFilter.crt.rawValue, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        withPro(false) {
            #expect(VideoFilter.effective(forRomBasename: rom) == .none, "\(system): a free player got a filter")
        }
        withPro(true) {
            #expect(VideoFilter.effective(forRomBasename: rom) == .crt, "\(system): Pro lost the filter")
        }
    }

    // MARK: - Controller remap, controller layout, touch presets

    /// Every console is offered in the one console list the three Pro
    /// customisation screens choose from (touch presets, controller remap,
    /// controller-connected layout). A console missing there is three Pro
    /// features gone for it, which is how the PlayStation once lost them.
    @Test func everyConsoleIsOfferedForCustomControls() {
        #expect(ConsoleChoiceList.all == PresetSystem.allCases)
        for system in PresetSystem.allCases {
            #expect(!RemappableInput.available(on: system).isEmpty, "\(system) has nothing to remap")
            #expect(!ControlElement.elements(for: system).isEmpty, "\(system) has nothing to lay out")
            #expect(SystemApplicability(system: system).system == system,
                    "a \(system) preset reads back as another console")
        }
    }

    /// A stored pad mapping applies for Pro only, on every console.
    @Test(arguments: PresetSystem.allCases)
    func controllerRemapIsProOnEveryConsole(_ system: PresetSystem) {
        let previous = ControllerMappingStore.stored(for: system)
        defer {
            if let previous { ControllerMappingStore.save(previous, for: system) } else { ControllerMappingStore.reset(for: system) }
        }
        ControllerMappingStore.save(ControllerMapping.defaults(for: system), for: system)

        withPro(false) {
            #expect(ControllerMappingStore.effective(for: system) == nil, "\(system): a free player got a mapping")
        }
        withPro(true) {
            #expect(ControllerMappingStore.effective(for: system) != nil, "\(system): Pro lost the mapping")
        }
    }

    /// A moved controller layout applies for Pro only, on every console.
    @Test(arguments: PresetSystem.allCases)
    func controllerLayoutIsProOnEveryConsole(_ system: PresetSystem) {
        let store = ControlLayoutStore.shared
        let previous = store.controllerLayout(system: system)
        defer {
            if let previous { store.saveControllerLayout(previous, system: system) } else { store.resetControllerLayout(system: system) }
        }
        var moved = ControllerLayout()
        moved.portrait.buttons[ControllerLayout.element.rawValue] = ButtonLayout(centerX: 0.5, centerY: 0.5)
        store.saveControllerLayout(moved, system: system)

        withPro(false) {
            #expect(store.activeControllerLayout(system: system) == nil, "\(system): a free player got a layout")
        }
        withPro(true) {
            #expect(store.activeControllerLayout(system: system) != nil, "\(system): Pro lost the layout")
        }
    }

    /// The keyboard map is FREE (1.3.1, a keyboard-mode pad is unplayable
    /// without it), on every console alike: no Pro flag in its path.
    @Test(arguments: PresetSystem.allCases)
    func keyboardMapIsFreeOnEveryConsole(_ system: PresetSystem) {
        let previous = KeyboardMappingStore.stored(for: system)
        defer {
            if let previous { KeyboardMappingStore.save(previous, for: system) } else { KeyboardMappingStore.reset(for: system) }
        }
        var mapping = KeyboardMapping.builtIn
        mapping.bind(.spacebar, to: .start)
        KeyboardMappingStore.save(mapping, for: system)

        withPro(false) {
            #expect(KeyboardMappingStore.effective(for: system) == mapping, "\(system): the free keyboard map is gated")
        }
    }

    // MARK: - Cheats

    /// The cheat browser has a database folder for every console, so the Pro
    /// cheats screen is never an empty promise on one of them.
    @Test(arguments: PresetSystem.allCases)
    func everyConsoleHasACheatDatabase(_ system: PresetSystem) {
        // The cheat screen keys GB and GBC apart; the layout family is one.
        let keys = system == .gbc ? ["gb", "gbc"] : [system.rawValue]
        for key in keys {
            #expect(CheatIndex.shared.url(forCheatFile: "Probe", system: key) != nil,
                    "no cheat database for \(key)")
        }
    }

    // MARK: - What deliberately differs

    /// Custom skins: built for every console since 2026-10-11 (the Master
    /// System, the Game Gear and the PSP last). A console without them would
    /// show neither Create nor Import (`SkinPickerView.supportsCustom`) and
    /// refuse an imported file (`SkinSharing.importSkin`).
    @Test func customSkinsAreOfferedExactlyWhereTheyExist() {
        for system in PresetSystem.allCases {
            #expect(system.supportsCustomSkins, "\(system) custom skins: \(system.supportsCustomSkins)")
        }
    }

    /// The console share card: every console has one since 2026-10-11. The
    /// card-style picker is free on every console, so nothing Pro is offered
    /// there either way.
    @Test func consoleShareCardsExistExactlyWhereBuilt() {
        for system in PresetSystem.allCases {
            #expect(ScreenshotCardRenderer.hasConsoleCard(system),
                    "\(system) console card: \(ScreenshotCardRenderer.hasConsoleCard(system))")
        }
    }

    // MARK: - The sheet and its analytics

    /// Every trigger reports one fixed, anonymous id: the game's name never
    /// reaches `pro_sheet_shown`, and no trigger carries a console, so the
    /// same tap on any console files under the same id.
    @Test func everyTriggerHasAStableAnonymousID() {
        let contexts: [ProPromptContext] = [
            .speedMoment(minutesAtFreeSpeed: 31), .speedTapped, .saveSlotFull, .saveSlotTapped,
            .sessionMilestone(totalMinutes: 61), .rewindLimit, .cheatCodes(gameName: "Secret Game"),
            .cheatCodesTapped, .tappedLockedFeature, .customizeControls, .customSkins,
            .videoFilters, .externalDisplay,
        ]
        let ids = contexts.map { $0.analyticsID }
        #expect(Set(ids).count == contexts.count, "two triggers share an id: \(ids)")
        #expect(!ids.contains { $0.contains("Secret") }, "a game name leaked into an id: \(ids)")
        #expect(ProPromptContext.cheatCodes(gameName: "A").analyticsID
                == ProPromptContext.cheatCodes(gameName: "B").analyticsID)
    }

    /// The sheet's cheat line names the formats of every console's codes, not
    /// only the GameShark family: Game Genie is the NES's, the Super
    /// Nintendo's, the Master System's and the Game Gear's.
    @Test func theCheatBenefitNamesMoreThanOneFamily() {
        let bundle = Bundle(for: ROMImporter.self)
        for locale in shippedLocales {
            guard let path = bundle.path(forResource: "Localizable", ofType: "strings",
                                         inDirectory: nil, forLocalization: locale),
                  let table = NSDictionary(contentsOfFile: path) as? [String: String],
                  let line = table["pro.benefit.cheats"] else {
                Issue.record("no pro.benefit.cheats for \(locale)")
                continue
            }
            #expect(line.contains("Game Genie"), "\(locale): \(line)")
            #expect(line.contains("Action Replay"), "\(locale): \(line)")
        }
    }
}
