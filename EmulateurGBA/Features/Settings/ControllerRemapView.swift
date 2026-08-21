//
//  ControllerRemapView.swift
//  EmulateurGBA
//
//  Controller button remapping (Pro) — the guided tap-then-press flow: tap a
//  console button row, then press the physical pad button to assign to it
//  (ControllerManager routes the press here through its capture mode). One
//  mapping per console family, global across games; the D-pad and stick are
//  not remappable (they always steer the console D-pad). Reached from
//  Settings ▸ Controller, only while a pad is connected.
//

import SwiftUI

struct ControllerRemapView: View {
    @ObservedObject private var controllers = ControllerManager.shared

    /// What a capture can bind: a console button or a shortcut verb.
    private enum CaptureTarget: Equatable {
        case input(RemappableInput)
        case action(RemapAction)
    }

    @State private var system: PresetSystem = .gba
    @State private var mapping: ControllerMapping = ControllerMappingStore.stored(for: .gba)
        ?? .defaults(for: .gba)
    /// The row currently waiting for a pad press (capture mode).
    @State private var capturing: CaptureTarget?

    private let gold = Color(red: 0.91, green: 0.76, blue: 0.42)

    var body: some View {
        List {
            Section {
                ConsoleChoiceList(
                    systems: ConsoleChoiceList.all,
                    selection: Binding(
                        get: { system },
                        set: { newSystem in
                            stopCapture()
                            system = newSystem
                            mapping = ControllerMappingStore.stored(for: newSystem)
                                ?? .defaults(for: newSystem)
                        }),
                    tint: Color(red: 0.45, green: 0.2, blue: 0.85)
                )
            }

            Section(footer: Text(NSLocalizedString("remap.footer", comment: "How the remap flow works + the D-pad exception"))) {
                if !controllers.isConnected {
                    // The pad left mid-screen: say so instead of dead rows.
                    Label(NSLocalizedString("remap.noController", comment: "Shown when the controller disconnects while remapping"),
                          systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                }
                ForEach(RemappableInput.available(on: system), id: \.self) { input in
                    bindingRow(label: input.displayName,
                               target: .input(input),
                               assigned: mapping.assignments[input])
                }
                Button(NSLocalizedString("remap.reset", comment: "Reset the mapping to defaults")) {
                    stopCapture()
                    ControllerMappingStore.reset(for: system)
                    mapping = .defaults(for: system)
                }
            }

            // Wave-2 shortcut verbs: UNBOUND by default — the correspondence
            // exists only once the user defines it.
            Section(header: Text(NSLocalizedString("remap.actions.header", comment: "Shortcut verbs section")),
                    footer: Text(NSLocalizedString("remap.actions.footer", comment: "Explains unbound-by-default + hold behavior + swipe to clear"))) {
                ForEach(RemapAction.allCases, id: \.self) { action in
                    bindingRow(label: NSLocalizedString(action.labelKey, comment: ""),
                               target: .action(action),
                               assigned: mapping.actions[action])
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.remapController", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stopCapture() }
        .onChange(of: controllers.isConnected) { connected in
            if !connected { stopCapture() }
        }
    }

    /// One binding row (console button or shortcut): tap → capture the next
    /// pad press; swipe → clear the binding. Physical names follow the
    /// connected pad's family (△ / LB / ZL…), generic GC names as fallback.
    private func bindingRow(label: String, target: CaptureTarget,
                            assigned: PhysicalButton?) -> some View {
        Button {
            if capturing == target {
                stopCapture()
            } else {
                startCapture(for: target)
            }
        } label: {
            HStack {
                Text(verbatim: label)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Spacer()
                if capturing == target {
                    Text(NSLocalizedString("remap.press", comment: "Waiting for a pad press"))
                        .font(.subheadline)
                        .foregroundStyle(gold)
                } else if let assigned {
                    Text(verbatim: assigned.displayName(for: controllers.controllerStyle))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "—")
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controllers.isConnected)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if assigned != nil {
                Button(role: .destructive) {
                    clear(target)
                } label: {
                    Text(NSLocalizedString("remap.clear", comment: "Clear one binding"))
                }
            }
        }
        .accessibilityLabel(Text(verbatim: "\(label): \(assigned?.displayName(for: controllers.controllerStyle) ?? "")"))
    }

    private func startCapture(for target: CaptureTarget) {
        capturing = target
        ControllerManager.shared.captureHandler = { physical in
            // Assign, persist, and end this capture (one press = one binding).
            switch target {
            case .input(let input): mapping.assignments[input] = physical
            case .action(let action): mapping.actions[action] = physical
            }
            ControllerMappingStore.save(mapping, for: system)
            stopCapture()
        }
    }

    private func clear(_ target: CaptureTarget) {
        stopCapture()
        switch target {
        case .input(let input): mapping.assignments.removeValue(forKey: input)
        case .action(let action): mapping.actions.removeValue(forKey: action)
        }
        ControllerMappingStore.save(mapping, for: system)
    }

    private func stopCapture() {
        capturing = nil
        ControllerManager.shared.captureHandler = nil
    }
}
