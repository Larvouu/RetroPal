//
//  ControllerLayoutView.swift
//  EmulateurGBA
//
//  Screens + Menu layout used while a physical controller is attached, one per
//  console. Deliberately separate from the touch presets: a touch preset places
//  the screens to leave room for the on-screen buttons, whereas with a
//  controller the buttons are gone and the screens want the whole display. One
//  object serving both goals would compromise at least one of them.
//
//  A console the player never customises is never stored, so it keeps rendering
//  exactly the geometry the app rendered before this screen existed.
//

import SwiftUI

struct ControllerLayoutView: View {
    @State private var editing: EditTarget?
    @State private var customised: Set<PresetSystem> = []

    private let store = ControlLayoutStore.shared

    /// Identifiable wrapper so `.fullScreenCover(item:)` can carry the console.
    private struct EditTarget: Identifiable {
        let system: PresetSystem
        var id: String { system.rawValue }
    }

    /// Every console the app plays, from the one list. It was [.gba, .gbc, .nds] and hardcoded,
    /// which is how the Super Nintendo ended up without a controller layout: the feature is
    /// console-agnostic (it moves screens and MENU, both of which every console has), so a
    /// console missing here was missing for no reason.
    private static let systems: [PresetSystem] = ConsoleChoiceList.all

    var body: some View {
        List {
            Section {
                ForEach(Self.systems, id: \.rawValue) { system in
                    Button {
                        editing = EditTarget(system: system)
                    } label: {
                        HStack {
                            Label(Self.name(system), systemImage: Self.icon(system))
                                .foregroundColor(.primary)
                            Spacer(minLength: 8)
                            if customised.contains(system) {
                                Text(NSLocalizedString("controllerLayout.customised", comment: ""))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                Text(NSLocalizedString("controllerLayout.footer", comment: ""))
            }

            if !customised.isEmpty {
                Section {
                    Button(role: .destructive) {
                        for system in Self.systems { store.resetControllerLayout(system: system) }
                        refresh()
                    } label: {
                        Label(NSLocalizedString("controllerLayout.resetAll", comment: ""),
                              systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text(NSLocalizedString("controllerLayout.reset.footer", comment: ""))
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.controllerLayout", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .fullScreenCover(item: $editing) { target in
            ControllerEditorWrapper(
                system: target.system,
                layout: store.controllerLayout(system: target.system) ?? ControllerLayout(),
                onSave: { layout in
                    // A layout the player reset back to the defaults is REMOVED
                    // rather than stored empty, so it returns to the untouched
                    // code path instead of resolving through the custom one.
                    if layout.isPristine {
                        store.resetControllerLayout(system: target.system)
                    } else {
                        store.saveControllerLayout(layout, system: target.system)
                    }
                    editing = nil
                    refresh()
                },
                onCancel: { editing = nil })
            .ignoresSafeArea()
        }
    }

    private func refresh() {
        customised = Set(Self.systems.filter { store.hasControllerLayout(system: $0) })
    }

    private static func name(_ system: PresetSystem) -> String { ConsoleChoiceList.name(system) }

    private static func icon(_ system: PresetSystem) -> String {
        system == .nds ? "rectangle.split.1x2" : "rectangle"
    }
}

// MARK: - Editor wrapper

/// Bridges the UIKit layout editor in controller mode. The editor speaks
/// `ControlPreset`, so a throwaway one carries the two `OrientationLayout`s in
/// and back out again; nothing about it is persisted as a preset.
private struct ControllerEditorWrapper: UIViewControllerRepresentable {
    let system: PresetSystem
    let layout: ControllerLayout
    let onSave: (ControllerLayout) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> ControlLayoutEditorViewController {
        Analytics.signal("controls_editor", ["action": "opened", "system": "\(system)"])
        Analytics.signal("pro_feature_used", ["feature": "custom_controls"])
        let carrier = ControlPreset(name: "",
                                    systems: SystemApplicability(system: system),
                                    portrait: layout.portrait,
                                    landscape: layout.landscape)
        let vc = ControlLayoutEditorViewController(system: system, preset: carrier,
                                                   controllerMode: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: ControlLayoutEditorViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSave: onSave, onCancel: onCancel, system: system)
    }

    final class Coordinator: NSObject, ControlLayoutEditorDelegate {
        let onSave: (ControllerLayout) -> Void
        let onCancel: () -> Void
        let system: PresetSystem

        init(onSave: @escaping (ControllerLayout) -> Void,
             onCancel: @escaping () -> Void,
             system: PresetSystem) {
            self.onSave = onSave
            self.onCancel = onCancel
            self.system = system
        }

        func editorDidSave(preset: ControlPreset) {
            // Reuses the EXISTING "preset_saved" value rather than adding a new
            // one: the signal set is frozen, and a controller-layout save is
            // still a layout save. The cost is that the two are not
            // distinguishable on the dashboard — reversible if that ever
            // matters more than the freeze.
            Analytics.signal("controls_editor", ["action": "preset_saved", "system": "\(system)"])
            onSave(ControllerLayout(portrait: preset.portrait, landscape: preset.landscape))
        }

        func editorDidCancel() { onCancel() }
    }
}
