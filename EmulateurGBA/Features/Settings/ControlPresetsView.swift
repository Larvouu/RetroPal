//
//  ControlPresetsView.swift
//  EmulateurGBA
//
//  Preset management and active layout selection for custom controls.
//

import SwiftUI
import UIKit

struct ControlPresetsView: View {
    @State private var presets: [ControlPreset] = []
    /// The active preset per console, keyed by console rather than one @State each: the three
    /// hardcoded properties are what limited the rows above to three consoles.
    @State private var activeIDs: [PresetSystem: UUID?] = [:]
    @State private var showNewPresetSheet = false
    @State private var editingPreset: ControlPreset?
    @State private var newPresetName = ""
    @State private var newPresetSystem: PresetSystem = .gba

    private let store = ControlLayoutStore.shared

    var body: some View {
        List {
            activeLayoutSection
            presetsSection
        }
        .navigationTitle(NSLocalizedString("settings.customizeControls", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .sheet(isPresented: $showNewPresetSheet) {
            newPresetSheet
        }
        .fullScreenCover(item: $editingPreset) { preset in
            EditorWrapper(preset: preset, system: preset.systems.system,
                onSave: { updatedPreset in
                    store.updatePreset(updatedPreset)
                    editingPreset = nil
                    reload()
                },
                onCancel: {
                    editingPreset = nil
                })
            // The editor canvas must span the WHOLE screen like the in-game
            // view does (the game's cover ignores the safe area too) — without
            // this, SwiftUI lays the editor out inside the safe areas, every
            // coordinate is computed against a shorter canvas, and the preview
            // no longer matches the game.
            .ignoresSafeArea()
        }
    }

    // MARK: - Active Layout Section

    private var activeLayoutSection: some View {
        Section {
            // One row per console, from the same list the new-preset sheet offers. It was three
            // hardcoded rows, so a preset could be MADE for the Super Nintendo (the sheet has
            // always offered it) and then never activated: the row that switches it on did not
            // exist. The same hole existed for the NES.
            ForEach(ConsoleChoiceList.all, id: \.self) { system in
                activeRow(label: system.shareLabel, system: system,
                          get: { activeIDs[system] ?? nil }, set: { activeIDs[system] = $0 })
            }
        } header: {
            Text(NSLocalizedString("layout.activeLayout", comment: ""))
        }
    }

    /// One "active preset" picker row for a system. `get`/`set` bind the matching
    /// @State id so the menu reflects and persists the choice.
    private func activeRow(label: String, system: PresetSystem,
                           get: @escaping () -> UUID?, set: @escaping (UUID?) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            Picker("", selection: Binding(
                get: { get()?.uuidString ?? "default" },
                set: { val in
                    let id = val == "default" ? nil : UUID(uuidString: val)
                    store.setActivePreset(id, system: system)
                    set(id)
                }
            )) {
                Text(NSLocalizedString("layout.default", comment: "")).tag("default")
                ForEach(store.presetsForSystem(system)) { preset in
                    Text(preset.name).tag(preset.id.uuidString)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Presets Section

    private var presetsSection: some View {
        Section {
            ForEach(presets) { preset in
                Button {
                    editingPreset = preset
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name)
                                .foregroundColor(.primary)
                                .font(.body)
                            systemTag(preset.systems.system)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    store.deletePreset(id: presets[index].id)
                }
                reload()
            }

            Button {
                newPresetName = ""
                newPresetSystem = .gba
                showNewPresetSheet = true
            } label: {
                Label(NSLocalizedString("layout.newPreset", comment: ""),
                      systemImage: "plus.circle")
            }
        } header: {
            Text(NSLocalizedString("layout.presets", comment: ""))
        } footer: {
            Text(NSLocalizedString("layout.presets.footer", comment: ""))
        }
    }

    // MARK: - New Preset Sheet

    private var newPresetSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField(NSLocalizedString("layout.newPreset.namePlaceholder", comment: ""), text: $newPresetName)
                }

                Section(NSLocalizedString("layout.newPreset.systems", comment: "")) {
                    ConsoleChoiceList(
                        systems: ConsoleChoiceList.all,
                        selection: $newPresetSystem,
                        tint: Color(red: 0.45, green: 0.2, blue: 0.85)
                    )
                }
            }
            .navigationTitle(NSLocalizedString("layout.newPreset.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) {
                        showNewPresetSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("layout.newPreset.create", comment: "")) {
                        createPreset()
                        showNewPresetSheet = false
                    }
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    /// Short uppercase tag for a preset's system, shown next to its name.
    private static func systemLabel(_ system: PresetSystem) -> String {
        switch system {
        case .gba: return "GBA"
        case .gbc: return "GB / GBC"
        case .nds: return "NDS"
        case .snes: return "SNES"
        case .nes: return "NES"
        }
    }

    /// The console tag, in the LIBRARY's badge: same type, same padding, same corner, and the
    /// same per-console colour from `SystemColor`. It was a grey semi-transparent pill, which
    /// made every preset's console look alike in a list whose whole job is telling them apart —
    /// and the library had already solved that, one screen away.
    ///
    /// The label stays this screen's ("GB / GBC" rather than the library's per-game "GB" or
    /// "GBC"), because a preset really does cover both, and the colour is `.gbc`'s either way.
    private func systemTag(_ system: PresetSystem) -> some View {
        Text(Self.systemLabel(system))
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(SystemColor.color(system.rawValue))
            .cornerRadius(4)
    }

    private func reload() {
        presets = store.loadPresets()
        for system in ConsoleChoiceList.all {
            activeIDs[system] = store.activePresetID(system: system)
        }
    }

    private func createPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let systems = SystemApplicability(system: newPresetSystem)
        // Seed the new preset's directional style from the current default
        // (the global Settings choice) so it starts matching what the user
        // already sees; it becomes independent of the default from here on.
        let preset = ControlPreset(name: name, systems: systems,
                                   useJoystick: UserDefaults.standard.bool(forKey: "useJoystick"))
        store.addPreset(preset)

        // Auto-activate the new preset for its system — the user explicitly
        // chose to create a preset for this system, so they almost certainly
        // want it to be the active one. Saves a second tap on "Set active".
        store.setActivePreset(preset.id, system: newPresetSystem)

        reload()

        // Open editor immediately for the new preset
        editingPreset = store.loadPresets().first { $0.id == preset.id }
    }
}

// MARK: - Console chooser

/// Pick one console from the full list.
///
/// This replaced a segmented control when the fifth and sixth consoles arrived.
/// Six segments cannot hold "Game Boy Advance" and "Super Nintendo" side by side,
/// and the answer to text that does not fit is a different control, never a
/// shorter name: these rows say each console in full and grow with the list.
struct ConsoleChoiceList: View {
    let systems: [PresetSystem]
    @Binding var selection: PresetSystem
    let tint: Color

    /// Every console, in the order the library already orders them.
    static let all: [PresetSystem] = [.gba, .gbc, .nds, .snes, .nes]

    /// Proper nouns, deliberately not localized, matching the names the rest of
    /// the app shows.
    static func name(_ system: PresetSystem) -> String {
        switch system {
        case .gba:  return "Game Boy Advance"
        case .gbc:  return "Game Boy / Color"
        case .nds:  return "Nintendo DS"
        case .snes: return "Super Nintendo"
        case .nes:  return "NES"
        }
    }

    var body: some View {
        ForEach(systems, id: \.self) { system in
            Button {
                selection = system
            } label: {
                HStack {
                    Text(Self.name(system)).foregroundColor(.primary)
                    Spacer()
                    if system == selection {
                        Image(systemName: "checkmark").foregroundColor(tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Colored Segmented Picker

/// A segmented control whose selected segment carries a custom color.
/// SwiftUI's native segmented Picker does not expose the selected-segment
/// color, so this thin UIKit wrapper does.
/// Internal (not private): also the tab bar of the in-game Appearance sheet.
struct ColoredSegmentedPicker<Value: Equatable>: UIViewRepresentable {
    let segments: [(label: String, value: Value)]
    @Binding var selection: Value
    let selectedColor: UIColor

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: segments.map { $0.label })
        control.selectedSegmentTintColor = selectedColor
        control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        control.selectedSegmentIndex = currentIndex
        let coordinator = context.coordinator
        control.addAction(UIAction { [weak coordinator] action in
            guard let coordinator,
                  let segmented = action.sender as? UISegmentedControl else { return }
            coordinator.select(index: segmented.selectedSegmentIndex)
        }, for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.selectedSegmentIndex != currentIndex {
            control.selectedSegmentIndex = currentIndex
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private var currentIndex: Int {
        segments.firstIndex { $0.value == selection } ?? 0
    }

    final class Coordinator {
        var parent: ColoredSegmentedPicker
        init(_ parent: ColoredSegmentedPicker) { self.parent = parent }
        func select(index: Int) {
            guard parent.segments.indices.contains(index) else { return }
            parent.selection = parent.segments[index].value
        }
    }
}

// MARK: - Editor UIKit Wrapper

private struct EditorWrapper: UIViewControllerRepresentable {
    let preset: ControlPreset
    let system: PresetSystem
    let onSave: (ControlPreset) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> ControlLayoutEditorViewController {
        Analytics.signal("controls_editor", ["action": "opened", "system": "\(system)"])
        Analytics.signal("pro_feature_used", ["feature": "custom_controls"])
        let vc = ControlLayoutEditorViewController(system: system, preset: preset)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: ControlLayoutEditorViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSave: onSave, onCancel: onCancel, system: system)
    }

    final class Coordinator: NSObject, ControlLayoutEditorDelegate {
        let onSave: (ControlPreset) -> Void
        let onCancel: () -> Void
        let system: PresetSystem

        init(onSave: @escaping (ControlPreset) -> Void,
             onCancel: @escaping () -> Void,
             system: PresetSystem) {
            self.onSave = onSave
            self.onCancel = onCancel
            self.system = system
        }

        func editorDidSave(preset: ControlPreset) {
            Analytics.signal("controls_editor", ["action": "preset_saved", "system": "\(system)"])
            onSave(preset)
        }

        func editorDidCancel() {
            onCancel()
        }
    }
}
