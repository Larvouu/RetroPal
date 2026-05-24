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
    static let maxPresets = 3

    private let presetsKey = "controlPresets"
    private let activeGBAKey = "activePresetGBA"
    private let activeNDSKey = "activePresetNDS"

    private init() {}

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
        guard presets.count < Self.maxPresets else { return }
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

        // Clear active references if this preset was active
        if activePresetID(forNDS: false) == id {
            setActivePreset(nil, forNDS: false)
        }
        if activePresetID(forNDS: true) == id {
            setActivePreset(nil, forNDS: true)
        }
    }

    // MARK: - Active Preset

    func activePresetID(forNDS: Bool) -> UUID? {
        let key = forNDS ? activeNDSKey : activeGBAKey
        guard let str = UserDefaults.standard.string(forKey: key) else { return nil }
        return UUID(uuidString: str)
    }

    func setActivePreset(_ id: UUID?, forNDS: Bool) {
        let key = forNDS ? activeNDSKey : activeGBAKey
        UserDefaults.standard.set(id?.uuidString, forKey: key)
    }

    /// Returns the active preset for the given system, or nil if "Default" is selected.
    func activePreset(forNDS: Bool) -> ControlPreset? {
        guard let id = activePresetID(forNDS: forNDS) else { return nil }
        return loadPresets().first { $0.id == id }
    }

    // MARK: - Resolved Layout

    /// Result of resolving an active preset: layout + per-preset opacity/scale.
    struct ResolvedPreset {
        let layout: OrientationLayout
        let opacity: CGFloat
        let scale: CGFloat
        /// True if the user actually customized button positions for this orientation.
        /// False means only non-button settings (screen size, opacity, scale) were changed.
        let hasCustomButtonPositions: Bool
    }

    /// Returns the resolved layout for the active preset, filling in missing buttons
    /// with defaults. Returns nil if no preset is active (use default layout).
    func resolvedPreset(forNDS: Bool, isLandscape: Bool, containerSize: CGSize) -> ResolvedPreset? {
        guard let preset = activePreset(forNDS: forNDS) else { return nil }

        let base = isLandscape ? preset.landscape : preset.portrait
        let hasCustomPositions = !base.buttons.isEmpty

        let defaults = ControlLayoutDefaults.defaultLayout(
            forNDS: forNDS, isLandscape: isLandscape, containerSize: containerSize)
        let elements = forNDS ? ControlElement.ndsElements : ControlElement.gbaElements

        // Merge: use preset value if present, otherwise fall back to default
        var merged = base
        for element in elements {
            if merged.buttons[element.rawValue] == nil {
                merged.buttons[element.rawValue] = defaults.buttons[element.rawValue]
            }
        }

        return ResolvedPreset(layout: merged, opacity: preset.opacity, scale: preset.scale,
                              hasCustomButtonPositions: hasCustomPositions)
    }

    /// Convenience: returns presets that are applicable to the given system.
    func presetsForSystem(forNDS: Bool) -> [ControlPreset] {
        return loadPresets().filter { forNDS ? $0.systems.nds : $0.systems.gba }
    }
}
