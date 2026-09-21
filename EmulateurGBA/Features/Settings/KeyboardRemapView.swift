//
//  KeyboardRemapView.swift
//  EmulateurGBA
//
//  Keyboard key remapping (free): the pad remap's guided tap-then-press flow,
//  for keys, with the pad's shape too: one mapping per console family, the
//  console chosen at the top upright and from a rail on its side. Tap a
//  console control row, then press the key to bind to it (ControllerManager
//  routes the press here through its key capture). The directions are rows
//  here, unlike the pad page, because the case this serves is a Bluetooth pad
//  iOS sees as a keyboard, whose D-pad is four letters. Reached from
//  Settings ▸ Controller, only while a keyboard is attached, since the flow
//  needs its presses.
//

import SwiftUI

struct KeyboardRemapView: View {
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

    @State private var system: PresetSystem = .gba
    @State private var mapping: KeyboardMapping = KeyboardMappingStore.effective(for: .gba)
    /// The row currently waiting for a key press (capture mode).
    @State private var capturing: KeyboardInput?

    private let gold = Color(red: 0.91, green: 0.76, blue: 0.42)

    var body: some View {
        Group {
            if isLandscape {
                landscapeBody
            } else {
                List {
                    consoleSection
                    directionsSection
                    buttonsSection
                }
                .uprightLook()
            }
        }
        .navigationTitle(NSLocalizedString("settings.remapKeyboard", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stopCapture() }
        .onChange(of: controllers.isKeyboardAttached) { attached in
            if !attached { stopCapture() }
        }
    }

    /// Two sides on its side, the pad page's arrangement: the console on the
    /// left as a rail where the chosen one is a filled row, the remapping on
    /// the right, the same two sections the upright list shows under the
    /// chooser.
    private var landscapeBody: some View {
        LandscapeListScaffold(title: NSLocalizedString("settings.remapKeyboard", comment: "")) {
            if isStacked {
                List {
                    consoleSection
                    directionsSection
                    buttonsSection
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    // 22 at the top so the rail's edge meets the list's first
                    // row (an inset-grouped list keeps that much header padding).
                    consoleRail
                        .frame(width: isTablet ? 280 : 250)
                        .padding(.leading, 20)
                        .padding(.top, 22)
                    List {
                        directionsSection
                        buttonsSection
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
        mapping = KeyboardMappingStore.effective(for: candidate)
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

    private var directionsSection: some View {
        Section(header: Text(NSLocalizedString("keyremap.directions.header", comment: ""))) {
            if !controllers.isKeyboardAttached {
                // The keyboard left mid-screen: say so instead of dead rows.
                Label(NSLocalizedString("keyremap.noKeyboard", comment: "Shown when no keyboard is attached while remapping"),
                      systemImage: "keyboard")
                    .foregroundStyle(.secondary)
            }
            ForEach(KeyboardInput.directions, id: \.self) { input in
                bindingRow(input)
            }
        }
        .landscapeGlassRow()
    }

    private var buttonsSection: some View {
        Section(header: Text(NSLocalizedString("keyremap.buttons.header", comment: "")),
                footer: Text(NSLocalizedString("keyremap.footer", comment: "How the key remap flow works: one key, one control"))) {
            // The console's own buttons, the pad page's list.
            ForEach(KeyboardInput.buttons(on: system), id: \.self) { input in
                bindingRow(input)
            }
            Button(NSLocalizedString("remap.reset", comment: "Reset the mapping to defaults")) {
                stopCapture()
                KeyboardMappingStore.reset(for: system)
                mapping = .builtIn
            }
        }
        .landscapeGlassRow()
    }

    /// One row: tap → capture the next key press; swipe → clear every key on
    /// the control. Several keys on one control read as "X · G".
    private func bindingRow(_ input: KeyboardInput) -> some View {
        let names = mapping.keyCodes(for: input).map(KeyboardKeyName.name(for:))
        return Button {
            if capturing == input {
                stopCapture()
            } else {
                startCapture(for: input)
            }
        } label: {
            HStack {
                Text(verbatim: input.displayName)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Spacer()
                if capturing == input {
                    Text(NSLocalizedString("keyremap.press", comment: "Waiting for a key press"))
                        .font(.subheadline)
                        .foregroundStyle(gold)
                } else if !names.isEmpty {
                    Text(verbatim: names.joined(separator: " · "))
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
        .disabled(!controllers.isKeyboardAttached)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !names.isEmpty {
                Button(role: .destructive) {
                    clear(input)
                } label: {
                    Text(NSLocalizedString("remap.clear", comment: "Clear one binding"))
                }
            }
        }
        .accessibilityLabel(Text(verbatim: "\(input.displayName): \(names.joined(separator: ", "))"))
    }

    private func startCapture(for input: KeyboardInput) {
        capturing = input
        ControllerManager.shared.keyboardCaptureHandler = { code in
            // Bind, persist, and end this capture (one press = one binding).
            // The game reads the store at its next session start, as it does
            // for the pad's mapping.
            mapping.bind(code, to: input)
            KeyboardMappingStore.save(mapping, for: system)
            stopCapture()
        }
    }

    private func clear(_ input: KeyboardInput) {
        stopCapture()
        mapping.clear(input)
        KeyboardMappingStore.save(mapping, for: system)
    }

    private func stopCapture() {
        capturing = nil
        ControllerManager.shared.keyboardCaptureHandler = nil
    }
}
