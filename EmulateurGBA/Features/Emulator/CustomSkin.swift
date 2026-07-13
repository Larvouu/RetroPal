//
//  CustomSkin.swift
//  EmulateurGBA
//
//  A user-created skin: a named `SkinPalette` scoped to one console family. Custom skins live in a
//  per-console LIBRARY (CustomSkinStore) shared across every game of that console — create a GB/GBC
//  skin on one game and it appears in the picker for all GB/GBC games. The CHOICE of which skin a
//  given game wears stays per-game (SkinSelection in the `skin_<rom>` key), like the built-ins.
//
//  GB and GBC share the `.gbc` preset system, so their custom skins share one library (matching the
//  shared dress / layout family). The library is capped at 6 per console.
//

import Foundation

struct CustomSkin: Codable, Equatable, Identifiable {
    /// Max characters for a skin name, so a card label stays on one readable line. Enforced by the
    /// editor (input cap) and the importer (longer names are trimmed to fit).
    static let maxNameLength = 20

    let id: UUID
    var name: String
    /// The `PresetSystem.rawValue` this skin belongs to ("gbc" / "gba" / "nds").
    let system: String
    var palette: SkinPalette

    init(id: UUID = UUID(), name: String, system: PresetSystem, palette: SkinPalette) {
        self.id = id
        self.name = name
        self.system = system.rawValue
        self.palette = palette
    }
}

/// The per-console library of user-created skins (max 6 each), persisted as JSON in UserDefaults
/// under `customSkins_<system>`. Plain CRUD; callers re-read after a mutation.
final class CustomSkinStore {
    static let shared = CustomSkinStore()
    static let maxPerConsole = 6

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ system: PresetSystem) -> String { "customSkins_\(system.rawValue)" }

    /// All custom skins for a console, in creation order (oldest first). Empty on any decode failure.
    func skins(for system: PresetSystem) -> [CustomSkin] {
        guard let data = defaults.data(forKey: key(system)),
              let decoded = try? JSONDecoder().decode([CustomSkin].self, from: data) else { return [] }
        return decoded
    }

    func skin(id: UUID, system: PresetSystem) -> CustomSkin? {
        skins(for: system).first { $0.id == id }
    }

    /// Whether another skin can still be created for this console (under the 6 cap).
    func canAdd(system: PresetSystem) -> Bool {
        skins(for: system).count < Self.maxPerConsole
    }

    /// Appends a new skin if under the cap. Returns false (and stores nothing) when full.
    @discardableResult
    func add(_ skin: CustomSkin, system: PresetSystem) -> Bool {
        var all = skins(for: system)
        guard all.count < Self.maxPerConsole else { return false }
        all.append(skin)
        save(all, system: system)
        return true
    }

    /// Replaces an existing skin (matched by id) in place. No-op if the id is unknown.
    func update(_ skin: CustomSkin, system: PresetSystem) {
        var all = skins(for: system)
        guard let i = all.firstIndex(where: { $0.id == skin.id }) else { return }
        all[i] = skin
        save(all, system: system)
    }

    func delete(id: UUID, system: PresetSystem) {
        let all = skins(for: system).filter { $0.id != id }
        save(all, system: system)
    }

    private func save(_ skins: [CustomSkin], system: PresetSystem) {
        guard let data = try? JSONEncoder().encode(skins) else { return }
        defaults.set(data, forKey: key(system))
    }
}
