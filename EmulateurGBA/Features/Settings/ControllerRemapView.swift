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
    /// A phone on its side, or an iPad window (see `LandscapeSurface`).
    @LandscapeSurface private var isLandscape
    /// An iPad window: a wider rail, a capped list.
    @TabletSurface private var isTablet
    /// An upright iPad: the console chooser goes back above the sections,
    /// the upright list's own shape (the scaffold decides).
    @Environment(\.landscapeStacked) private var isStacked
    /// Observed so a theme change repaints this surface.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared

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
        Group {
            if isLandscape {
                landscapeBody
            } else {
                List {
                    consoleSection
                    bindingsSection
                    actionsSection
                }
                .uprightLook()
            }
        }
        .navigationTitle(NSLocalizedString("settings.remapController", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stopCapture() }
        .onChange(of: controllers.isConnected) { connected in
            if !connected { stopCapture() }
        }
    }

    /// Two sides on its side (decided on device, 2026-09-04): the console on the left,
    /// as a rail where the chosen one is a filled row rather than a check
    /// mark, and the remapping on the right, the same two sections the
    /// upright list shows under the chooser.
    private var landscapeBody: some View {
        LandscapeListScaffold(title: NSLocalizedString("settings.remapController", comment: "")) {
            // On an iPad the rail widens a little and the list is capped, so the
            // pair sits in the middle of the window instead of spanning it;
            // upright, the chooser goes back above the sections.
            if isStacked {
                List {
                    consoleSection
                    bindingsSection
                    actionsSection
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    // The rail's top edge meets the list's first row: an inset-grouped
                    // list keeps its section-header top padding (22 points) above its
                    // first row, and at 12 the rail's card stood ten points higher on
                    // every device (reported on device, 2026-09-05).
                    consoleRail
                        .frame(width: isTablet ? 280 : 250)
                        .padding(.leading, 20)
                        .padding(.top, 22)
                    List {
                        bindingsSection
                        actionsSection
                    }
                    .frame(maxWidth: isTablet ? 700 : .infinity)
                }
            }
        }
    }

    private var consoleRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LandscapeChrome.card(nil) {
                ForEach(ConsoleChoiceList.all, id: \.self) { candidate in
                    let chosen = candidate == system
                    Button {
                        choose(candidate)
                    } label: {
                        HStack(spacing: 10) {
                            PixelConsoleIcon(console: PixelConsole(candidate))
                                .frame(width: 26, height: 26)
                                .accessibilityHidden(true)
                            Text(ConsoleChoiceList.name(candidate))
                                .font(.subheadline.weight(chosen ? .semibold : .regular))
                                .foregroundStyle(chosen ? Color.white : Color.white.opacity(0.7))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(chosen ? LibraryLandscapePalette.accent.opacity(0.85) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: ConsoleChoiceList.name(candidate)))
                    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// Switch console: end any capture in flight, then load that console's
    /// mapping. The one path both the upright chooser and the rail take.
    private func choose(_ candidate: PresetSystem) {
        stopCapture()
        system = candidate
        mapping = ControllerMappingStore.stored(for: candidate) ?? .defaults(for: candidate)
    }

    private var consoleSection: some View {
        Section {
            ConsoleChoiceList(
                systems: ConsoleChoiceList.all,
                selection: Binding(
                    get: { system },
                    set: { newSystem in choose(newSystem) }),
                tint: Color(red: 0.45, green: 0.2, blue: 0.85)
            )
        }
        .landscapeGlassRow()
    }

    private var bindingsSection: some View {
        Section(footer: Text(NSLocalizedString("remap.footer", comment: "How the remap flow works + the D-pad exception"))) {
            if !controllers.isConnected {
                // The pad left mid-screen: say so instead of dead rows.
                Label(NSLocalizedString("remap.noController", comment: "Shown when the controller disconnects while remapping"),
                      systemImage: "gamecontroller")
                    .foregroundStyle(.secondary)
            }
            ForEach(RemappableInput.available(on: system), id: \.self) { input in
                // The label is the CONSOLE's own mark, which on the
                // PlayStation is a symbol rather than a letter; the spoken
                // name is its word, because "◯" reads badly out loud.
                bindingRow(label: input.displayName(for: system),
                           accessibleLabel: input.accessibleName(for: system),
                           target: .input(input),
                           assigned: mapping.assignments[input])
            }
            Button(NSLocalizedString("remap.reset", comment: "Reset the mapping to defaults")) {
                stopCapture()
                ControllerMappingStore.reset(for: system)
                mapping = .defaults(for: system)
            }
        }
        .landscapeGlassRow()
    }

    private var actionsSection: some View {
        Section(header: Text(NSLocalizedString("remap.actions.header", comment: "Shortcut verbs section")),
                footer: Text(NSLocalizedString("remap.actions.footer", comment: "Explains unbound-by-default + hold behavior + swipe to clear"))) {
            ForEach(RemapAction.allCases, id: \.self) { action in
                bindingRow(label: NSLocalizedString(action.labelKey, comment: ""),
                           target: .action(action),
                           assigned: mapping.actions[action])
            }
        }
        .landscapeGlassRow()
    }


    /// One binding row (console button or shortcut): tap → capture the next
    /// pad press; swipe → clear the binding. Physical names follow the
    /// connected pad's family (△ / LB / ZL…), generic GC names as fallback.
    /// `accessibleLabel` is what VoiceOver says when the visible label is a
    /// symbol. It defaults to the label itself, which is right everywhere except
    /// the PlayStation's four faces.
    private func bindingRow(label: String, accessibleLabel: String? = nil,
                            target: CaptureTarget,
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
        .accessibilityLabel(Text(verbatim: "\(accessibleLabel ?? label): "
                                 + "\(assigned?.displayName(for: controllers.controllerStyle) ?? "")"))
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
