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
    @State private var activeGBAID: UUID?
    @State private var activeNDSID: UUID?
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
            EditorWrapper(preset: preset, isNDS: preset.systems.nds,
                onSave: { updatedPreset in
                    store.updatePreset(updatedPreset)
                    editingPreset = nil
                    reload()
                },
                onCancel: {
                    editingPreset = nil
                })
        }
    }

    // MARK: - Active Layout Section

    private var activeLayoutSection: some View {
        Section {
            HStack {
                Text("GBA / GB / GBC")
                Spacer()
                Picker("", selection: Binding(
                    get: { activeGBAID?.uuidString ?? "default" },
                    set: { val in
                        let id = val == "default" ? nil : UUID(uuidString: val)
                        store.setActivePreset(id, forNDS: false)
                        activeGBAID = id
                    }
                )) {
                    Text(NSLocalizedString("layout.default", comment: "")).tag("default")
                    ForEach(store.presetsForSystem(forNDS: false)) { preset in
                        Text(preset.name).tag(preset.id.uuidString)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Text("Nintendo DS")
                Spacer()
                Picker("", selection: Binding(
                    get: { activeNDSID?.uuidString ?? "default" },
                    set: { val in
                        let id = val == "default" ? nil : UUID(uuidString: val)
                        store.setActivePreset(id, forNDS: true)
                        activeNDSID = id
                    }
                )) {
                    Text(NSLocalizedString("layout.default", comment: "")).tag("default")
                    ForEach(store.presetsForSystem(forNDS: true)) { preset in
                        Text(preset.name).tag(preset.id.uuidString)
                    }
                }
                .pickerStyle(.menu)
            }
        } header: {
            Text(NSLocalizedString("layout.activeLayout", comment: ""))
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
                            systemTag(preset.systems.nds ? "NDS" : "GBA")
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

            if presets.count < ControlLayoutStore.maxPresets {
                Button {
                    newPresetName = ""
                    newPresetSystem = .gba
                    showNewPresetSheet = true
                } label: {
                    Label(NSLocalizedString("layout.newPreset", comment: ""),
                          systemImage: "plus.circle")
                }
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
                    ColoredSegmentedPicker(
                        segments: [("GBA / GB / GBC", PresetSystem.gba),
                                   ("Nintendo DS", PresetSystem.nds)],
                        selection: $newPresetSystem,
                        selectedColor: UIColor(red: 0.45, green: 0.2, blue: 0.85, alpha: 1)
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

    private func systemTag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(4)
    }

    private func reload() {
        presets = store.loadPresets()
        activeGBAID = store.activePresetID(forNDS: false)
        activeNDSID = store.activePresetID(forNDS: true)
    }

    private func createPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let systems = SystemApplicability(system: newPresetSystem)
        let preset = ControlPreset(name: name, systems: systems)
        store.addPreset(preset)

        // Auto-activate the new preset for its system — the user explicitly
        // chose to create a preset for GBA or NDS, so they almost certainly
        // want it to be the active one. Saves a second tap on "Set active".
        store.setActivePreset(preset.id, forNDS: newPresetSystem == .nds)

        reload()

        // Open editor immediately for the new preset
        editingPreset = store.loadPresets().first { $0.id == preset.id }
    }
}

// MARK: - Colored Segmented Picker

/// A segmented control whose selected segment carries a custom color.
/// SwiftUI's native segmented Picker does not expose the selected-segment
/// color, so this thin UIKit wrapper does.
private struct ColoredSegmentedPicker<Value: Equatable>: UIViewRepresentable {
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
    let isNDS: Bool
    let onSave: (ControlPreset) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> ControlLayoutEditorViewController {
        let vc = ControlLayoutEditorViewController(isNDS: isNDS, preset: preset)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: ControlLayoutEditorViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSave: onSave, onCancel: onCancel)
    }

    final class Coordinator: NSObject, ControlLayoutEditorDelegate {
        let onSave: (ControlPreset) -> Void
        let onCancel: () -> Void

        init(onSave: @escaping (ControlPreset) -> Void,
             onCancel: @escaping () -> Void) {
            self.onSave = onSave
            self.onCancel = onCancel
        }

        func editorDidSave(preset: ControlPreset) {
            onSave(preset)
        }

        func editorDidCancel() {
            onCancel()
        }
    }
}
