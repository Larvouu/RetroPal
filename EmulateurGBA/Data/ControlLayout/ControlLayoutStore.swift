//
//  ControlLayoutStore.swift
//  EmulateurGBA
//
//  Persistence and resolution for control layout presets.
//  Stores presets as JSON in UserDefaults, following the cheats storage pattern.
//

import Foundation
import CoreGraphics

final class ControlLayoutStore {
    static let shared = ControlLayoutStore()

    private let presetsKey = "controlPresets"
    private let activeGBAKey = "activePresetGBA"
    private let activeGBCKey = "activePresetGBC"
    private let activeNDSKey = "activePresetNDS"
    private let activeSNESKey = "activePresetSNES"
    private let activeNESKey = "activePresetNES"

    private init() {}

    /// UserDefaults key holding the active-preset id for one system.
    private func activeKey(for system: PresetSystem) -> String {
        switch system {
        case .gba: return activeGBAKey
        case .gbc: return activeGBCKey
        case .nds: return activeNDSKey
        case .snes: return activeSNESKey
        case .nes: return activeNESKey
        }
    }

    // MARK: - Controller layout

    /// One stored layout per system, JSON in UserDefaults like the presets.
    /// Absent or pristine means "never customised", which resolves to exactly
    /// the geometry the app renders today.
    private func controllerKey(for system: PresetSystem) -> String {
        "controllerLayout_" + system.rawValue
    }

    func controllerLayout(system: PresetSystem) -> ControllerLayout? {
        guard let data = UserDefaults.standard.data(forKey: controllerKey(for: system)),
              let layout = try? JSONDecoder().decode(ControllerLayout.self, from: data)
        else { return nil }
        return layout
    }

    func saveControllerLayout(_ layout: ControllerLayout, system: PresetSystem) {
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: controllerKey(for: system))
        }
    }

    func resetControllerLayout(system: PresetSystem) {
        UserDefaults.standard.removeObject(forKey: controllerKey(for: system))
    }

    /// The layout to actually apply in game, or nil for "render as before".
    ///
    /// nil is returned for a free user, for a system that was never customised,
    /// and for a stored-but-pristine layout. That is the whole zero-regression
    /// guarantee: anyone who does not opt in reaches the untouched code path.
    /// A lapsed Pro subscriber falls back safely rather than losing the game
    /// behind an unusable layout.
    func activeControllerLayout(system: PresetSystem) -> ControllerLayout? {
        guard UserDefaults.standard.bool(forKey: "isPro"),
              let layout = controllerLayout(system: system),
              !layout.isPristine
        else { return nil }
        return layout
    }

    func hasControllerLayout(system: PresetSystem) -> Bool {
        guard let l = controllerLayout(system: system) else { return false }
        return !l.isPristine
    }

    // MARK: - Preset CRUD

    func loadPresets() -> [ControlPreset] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let presets = try? JSONDecoder().decode([ControlPreset].self, from: data)
        else { return [] }
        return presets
    }

    func savePresets(_ presets: [ControlPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
    }

    func addPreset(_ preset: ControlPreset) {
        var presets = loadPresets()
        presets.append(preset)
        savePresets(presets)
    }

    func updatePreset(_ preset: ControlPreset) {
        var presets = loadPresets()
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            savePresets(presets)
        }
    }

    func deletePreset(id: UUID) {
        var presets = loadPresets()
        presets.removeAll { $0.id == id }
        savePresets(presets)

        // Clear active references if this preset was active for any system.
        for system in [PresetSystem.gba, .gbc, .nds, .snes, .nes] where activePresetID(system: system) == id {
            setActivePreset(nil, system: system)
        }
    }

    // MARK: - Active Preset

    func activePresetID(system: PresetSystem) -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: activeKey(for: system)) else { return nil }
        return UUID(uuidString: str)
    }

    func setActivePreset(_ id: UUID?, system: PresetSystem) {
        UserDefaults.standard.set(id?.uuidString, forKey: activeKey(for: system))
    }

    /// Returns the active preset for the given system, or nil if "Default" is selected.
    func activePreset(system: PresetSystem) -> ControlPreset? {
        guard let id = activePresetID(system: system) else { return nil }
        return loadPresets().first { $0.id == id }
    }

    // (Layout resolution lives in PresetLayoutResolver — the store is pure
    // persistence. The old resolvedPreset merge was replaced when components
    // gained their own size/opacity and screens became part of the layout.)

    /// Convenience: returns presets that are applicable to the given system.
    func presetsForSystem(_ system: PresetSystem) -> [ControlPreset] {
        return loadPresets().filter { $0.systems.system == system }
    }
}
