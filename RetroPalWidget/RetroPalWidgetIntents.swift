//
//  RetroPalWidgetIntents.swift
//  RetroPalWidget
//
//  Configuration for the widgets the user picks games for. iOS 17+ only:
//  modern widget configuration is AppIntentConfiguration, and the iOS 16
//  route would mean a SiriKit .intentdefinition file with code generation
//  attached. iOS 16 keeps the zero-configuration "Récents" widget instead,
//  so nobody is left with nothing.
//
//  NOTE on style: AppIntents extracts its metadata at COMPILE time, so
//  `title`, `typeDisplayRepresentation` and `caseDisplayRepresentations`
//  must be stored properties holding literals. They cannot be computed, and
//  the case map must list every case. That is why the slot names are five
//  separate string keys rather than one format string.
//
//  Everything here reads the App Group snapshot. No Core Data, no network.
//

import AppIntents
import Foundation

// MARK: - Slot choice

/// Which save the widget launches into.
///
/// Deliberately NO "new game" option. Starting fresh and then quitting
/// rewrites the auto-save, which is why Game Details asks for confirmation
/// before doing it. A widget cannot ask, and silently overwriting someone's
/// progress from the Home Screen is the exact failure our save-safety
/// promise exists to prevent.
@available(iOS 17.0, *)
enum WidgetSlotChoice: Int, AppEnum {
    case resume = 0
    case slot1 = 1
    case slot2 = 2
    case slot3 = 3
    case slot4 = 4
    case slot5 = 5

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "widget.slot.type")

    static var caseDisplayRepresentations: [WidgetSlotChoice: DisplayRepresentation] = [
        .resume: DisplayRepresentation(title: "widget.slot.resume"),
        .slot1: DisplayRepresentation(title: "widget.slot.1"),
        .slot2: DisplayRepresentation(title: "widget.slot.2"),
        .slot3: DisplayRepresentation(title: "widget.slot.3"),
        .slot4: DisplayRepresentation(title: "widget.slot.4"),
        .slot5: DisplayRepresentation(title: "widget.slot.5")
    ]

    /// Resolves to the slot the deep link should carry, given what the game
    /// actually has on disk. A slot the user picked and later deleted falls
    /// back to resuming rather than silently starting a new game over their
    /// progress.
    func resolved(for game: WidgetSharing.Game) -> Int? {
        switch self {
        case .resume:
            return game.resumeSlot
        default:
            return game.manualSlots.contains(rawValue) ? rawValue : game.resumeSlot
        }
    }
}

// MARK: - Game entity

@available(iOS 17.0, *)
struct GameAppEntity: AppEntity {
    /// The stored ROM filename, same identity the deep link uses.
    let id: String
    let title: String
    let consoleName: String

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "widget.entity.game")

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(consoleName)")
    }

    static var defaultQuery = GameEntityQuery()

    init(_ game: WidgetSharing.Game) {
        id = game.romFilePath
        title = game.title
        consoleName = game.consoleName
    }
}

@available(iOS 17.0, *)
struct GameEntityQuery: EntityQuery {
    /// No cover images in the picker rows on purpose: loading art for a whole
    /// library inside an intent query is how a widget gets killed for memory.
    func entities(for identifiers: [String]) async throws -> [GameAppEntity] {
        let wanted = Set(identifiers)
        return WidgetSharing.allGames()
            .filter { wanted.contains($0.romFilePath) }
            .map(GameAppEntity.init)
    }

    func suggestedEntities() async throws -> [GameAppEntity] {
        WidgetSharing.allGames().map(GameAppEntity.init)
    }
}

// MARK: - Configuration intents

@available(iOS 17.0, *)
struct SelectGameIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "widget.oneGame.name"
    static var description = IntentDescription("widget.oneGame.description")

    @Parameter(title: "widget.param.game")
    var game: GameAppEntity?

    @Parameter(title: "widget.param.slot", default: .resume)
    var slot: WidgetSlotChoice
}

/// Four games, each with its own slot. Parameters are declared in pairs and
/// carry no explicit ParameterSummary, so the edit sheet lists them in this
/// order: game, its slot, game, its slot. Every slot defaults to "Reprendre",
/// so anyone who does not care only touches the four game rows.
@available(iOS 17.0, *)
struct SelectGamesIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "widget.fourGames.name"
    static var description = IntentDescription("widget.fourGames.description")

    @Parameter(title: "widget.param.game1")
    var game1: GameAppEntity?
    @Parameter(title: "widget.param.slot1", default: .resume)
    var slot1: WidgetSlotChoice

    @Parameter(title: "widget.param.game2")
    var game2: GameAppEntity?
    @Parameter(title: "widget.param.slot2", default: .resume)
    var slot2: WidgetSlotChoice

    @Parameter(title: "widget.param.game3")
    var game3: GameAppEntity?
    @Parameter(title: "widget.param.slot3", default: .resume)
    var slot3: WidgetSlotChoice

    @Parameter(title: "widget.param.game4")
    var game4: GameAppEntity?
    @Parameter(title: "widget.param.slot4", default: .resume)
    var slot4: WidgetSlotChoice

    /// The configured pairs, in order, skipping empty rows so a widget with
    /// only two games chosen shows two tiles rather than two gaps.
    var pairs: [(entity: GameAppEntity, slot: WidgetSlotChoice)] {
        [(game1, slot1), (game2, slot2), (game3, slot3), (game4, slot4)]
            .compactMap { entity, slot in entity.map { ($0, slot) } }
    }
}
