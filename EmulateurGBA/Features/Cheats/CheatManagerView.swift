//
//  CheatManagerView.swift
//  EmulateurGBA
//
//  Lets Pro users enter cheat codes (GameShark, CodeBreaker, Action Replay).
//  The app auto-detects the format. Codes stored per-game and auto-applied on load.
//  Auto-backup before first cheat to protect against corruption.
//

import SwiftUI

struct CheatManagerView: View {
    let romName: String
    let isNDS: Bool
    /// Real console key for the cheat index ("gb" / "gbc" / "gba" / "nds").
    /// Separate from `isNDS`, which only describes the input layout: GB and
    /// GBC have their own cheat sets and must not be searched as GBA.
    let systemKey: String
    let onAddCheat: (String) -> Bool
    let onClearCheats: () -> Void
    let onReapplyCheats: ([StoredCheat]) -> Void
    let onBackupSave: () -> Void
    let onRestoreBackup: () -> Bool
    let hasBackup: Bool
    /// Called when the user confirms "Restore pre-cheat save". The host
    /// is responsible for dismissing this sheet AND closing the overlay
    /// menu so the user lands back in the running game in one step.
    let onResume: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var codeInput: String = ""
    @State private var nameInput: String = ""
    @State private var cheats: [StoredCheat] = []
    @State private var showError = false
    /// Set when the shape check names the mistake; nil falls back to the
    /// core's generic "not recognised" message.
    @State private var codeProblem: CheatCodeFormatter.Problem?
    /// Previous field contents, so formatting can tell an append (safe to
    /// reformat) from a mid-string edit (never reformat, the caret would jump).
    @State private var lastCodeInput: String = ""
    @State private var showBrowser = false
    @State private var showHowTo = false
    @State private var hasBackedUp = false
    @State private var showOverflowActions = false
    @State private var showRestoreConfirm = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, code }

    struct StoredCheat: Identifiable, Codable {
        let id: UUID
        let code: String
        var name: String
        var enabled: Bool

        init(code: String, name: String = "", enabled: Bool = true) {
            self.id = UUID()
            self.code = code
            self.name = name
            self.enabled = enabled
        }
    }

    private var placeholderText: String {
        isNDS
            ? "e.g. 94000130 FCFF0000\n    62101D40 00000000"
            : "e.g. 82003884 0001"
    }

    private var formatHint: String {
        isNDS
            ? NSLocalizedString("cheats.hint.nds", comment: "")
            : NSLocalizedString("cheats.hint.gba", comment: "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Format hint
                    Text(formatHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Name field
                    TextField(NSLocalizedString("cheats.namePlaceholder", comment: ""), text: $nameInput)
                        .font(.subheadline)
                        .padding(12)
                        .background(Color(.systemGray6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(.systemGray4), lineWidth: 1)
                        )
                        .cornerRadius(10)
                        .focused($focusedField, equals: .name)

                    // Code editor
                    ZStack(alignment: .topLeading) {
                        if codeInput.isEmpty {
                            Text(placeholderText)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(Color(.placeholderText))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                        TextEditor(text: $codeInput)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .scrollContentBackground(.hidden)
                            .focused($focusedField, equals: .code)
                            .onChange(of: codeInput) { newValue in
                                let tidied = CheatCodeFormatter.formatted(
                                    newValue, previous: lastCodeInput, isNDS: isNDS)
                                lastCodeInput = tidied
                                if tidied != newValue { codeInput = tidied }
                                // Typing is how you fix a mistake, so clear the
                                // complaint as soon as the text changes.
                                if showError { showError = false; codeProblem = nil }
                            }
                    }
                    .frame(minHeight: 70, maxHeight: 100)
                    .background(Color(.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
                    .cornerRadius(10)

                    // Add button
                    Button {
                        addCheat()
                    } label: {
                        Label(NSLocalizedString("cheats.add", comment: ""), systemImage: "plus.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    // Error message — fully visible
                    if showError {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()
                        .padding(.top, 4)

                    // Browse the community database. Deliberately ABOVE the
                    // list and always present: anchoring it to the empty state
                    // would hide it the moment someone adds their first code,
                    // which is exactly when they want to look for more.
                    Button {
                        showBrowser = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                            Text(NSLocalizedString("cheats.browse.button", comment: ""))
                            Spacer(minLength: 0)
                            if CheatLibrary.shared.isCached(title: romName, system: systemKey) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.systemGray6))
                    )

                    // "Why is nothing happening?" gets an answer right where
                    // people ask it. Most games need a master code active
                    // before any other code does anything, and nothing in the
                    // app said so.
                    Button {
                        showHowTo = true
                    } label: {
                        Label(NSLocalizedString("guide.cheats.title", comment: ""),
                              systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    // Cheat list
                    if cheats.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "command")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text(NSLocalizedString("cheats.empty", comment: ""))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text(NSLocalizedString("cheats.findHint", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 24)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach($cheats) { $cheat in
                                cheatRow(cheat: $cheat)
                                if cheat.id != cheats.last?.id {
                                    Divider().padding(.leading, 48)
                                }
                            }
                        }
                    }

                    // Disclaimers
                    VStack(spacing: 6) {
                        Text(NSLocalizedString("cheats.permanenceWarning", comment: ""))
                            .font(.caption2)
                            .foregroundColor(Color(.tertiaryLabel))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(NSLocalizedString("cheats.hackDisclaimer", comment: ""))
                            .font(.caption2)
                            .foregroundColor(Color(.tertiaryLabel))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .onTapGesture {
                focusedField = nil
            }
            .sheet(isPresented: $showBrowser) {
                CheatBrowserSheet(romName: romName, system: systemKey) { code, name in
                    // Straight into the fields rather than applied blind: the
                    // player still sees it and still taps Add. The name comes
                    // along so the saved cheat reads "Infinite Health" instead
                    // of a wall of hex.
                    codeInput = code
                    lastCodeInput = code
                    if !name.isEmpty { nameInput = name }
                    showError = false
                    codeProblem = nil
                }
            }
            .sheet(isPresented: $showHowTo) {
                HowToSheet(
                    title: NSLocalizedString("guide.cheats.title", comment: ""),
                    intro: NSLocalizedString("guide.cheats.intro", comment: ""),
                    steps: [
                        NSLocalizedString("guide.cheats.step1", comment: ""),
                        NSLocalizedString("guide.cheats.step2", comment: ""),
                        NSLocalizedString("guide.cheats.step3", comment: ""),
                        NSLocalizedString("guide.cheats.step4", comment: ""),
                        NSLocalizedString("guide.cheats.step5", comment: ""),
                        NSLocalizedString("guide.cheats.step6", comment: "")
                    ],
                    footer: NSLocalizedString("guide.cheats.footer", comment: "")
            )
            }
            .navigationTitle(NSLocalizedString("overlay.cheats", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The "..." overflow opens a confirmation dialog (action
                // sheet) rather than a Menu popover. The action sheet
                // shows full text and wraps long localized labels
                // natively, which the popover Menu cannot. Hidden when
                // there is nothing to expose, so tapping never opens an
                // empty surface.
                if !cheats.isEmpty || hasBackup {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showOverflowActions = true
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("cheats.done", comment: "")) { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(NSLocalizedString("cheats.done", comment: "")) {
                        focusedField = nil
                    }
                }
            }
            .confirmationDialog(
                "",
                isPresented: $showOverflowActions,
                titleVisibility: .hidden
            ) {
                if !cheats.isEmpty {
                    Button(NSLocalizedString("cheats.clearAll", comment: ""), role: .destructive) {
                        cheats.removeAll()
                        onClearCheats()
                        saveCheats()
                    }
                }
                if hasBackup {
                    Button(NSLocalizedString("cheats.restore", comment: "")) {
                        // Second-step confirmation before the destructive
                        // action, same pattern as the slot save/load
                        // overwrite alerts in the overlay menu.
                        showRestoreConfirm = true
                    }
                }
            }
            .alert(
                NSLocalizedString("cheats.restore.confirm.title", comment: ""),
                isPresented: $showRestoreConfirm
            ) {
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
                Button(NSLocalizedString("cheats.restore.confirm.action", comment: ""), role: .destructive) {
                    // Restore + clear cheats + signal the host to dismiss
                    // the cheats sheet AND close the overlay menu, so the
                    // user lands directly back in the running game.
                    // Switch every code OFF rather than delete them: restoring
                    // undoes the SAVE, not the work of finding and entering the
                    // codes. Keeping them means one tap to try again instead of
                    // hunting them down a second time.
                    for index in cheats.indices { cheats[index].enabled = false }
                    onClearCheats()
                    saveCheats()
                    _ = onRestoreBackup()
                    onResume()
                }
            } message: {
                Text(NSLocalizedString("cheats.restore.confirm.message", comment: ""))
            }
            .onAppear { loadCheats() }
        }
    }

    // MARK: - Cheat Row

    @ViewBuilder
    private func cheatRow(cheat: Binding<StoredCheat>) -> some View {
        HStack(spacing: 12) {
            // Toggle
            Button {
                cheat.wrappedValue.enabled.toggle()
                saveCheats()
                reapplyAll()
                Analytics.signal("cheat", ["action": "toggled", "enabled": cheat.wrappedValue.enabled ? "true" : "false", "system": isNDS ? "nds" : "gba"])
            } label: {
                Image(systemName: cheat.wrappedValue.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(cheat.wrappedValue.enabled ? .green : .gray)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            // Name + code
            VStack(alignment: .leading, spacing: 2) {
                if !cheat.wrappedValue.name.isEmpty {
                    // NOT one line. libretro puts the instruction in the name
                    // ("Press SELECT to Restore Time", and far longer), so
                    // truncating it hides the only thing that explains what
                    // the code does. Clarity over brevity: grow the row.
                    Text(cheat.wrappedValue.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(cheat.wrappedValue.code)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }

            Spacer()

            // Delete button
            Button {
                if let idx = cheats.firstIndex(where: { $0.id == cheat.wrappedValue.id }) {
                    cheats.remove(at: idx)
                    saveCheats()
                    reapplyAll()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    /// Specific when the shape check can name the mistake, generic when only
    /// the core refused it.
    private var errorMessage: String {
        switch codeProblem {
        case .invalidCharacter:
            return NSLocalizedString("cheats.invalid.characters", comment: "")
        case .unpairedLine:
            return NSLocalizedString("cheats.invalid.pairs", comment: "")
        case nil:
            return isNDS
                ? NSLocalizedString("cheats.invalid.nds", comment: "")
                : NSLocalizedString("cheats.invalid.gba", comment: "")
        }
    }

    private func addCheat() {
        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }

        // Say why, when we can. The core still has the last word on everything
        // this check lets through.
        if let problem = CheatCodeFormatter.problem(in: code, isNDS: isNDS) {
            codeProblem = problem
            showError = true
            return
        }

        if !hasBackedUp {
            onBackupSave()
            hasBackedUp = true
        }

        let success = onAddCheat(code)
        if success {
            Analytics.signal("cheat", ["action": "added", "system": isNDS ? "nds" : "gba"])
            Analytics.signal("pro_feature_used", ["feature": "cheats"])
            let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            cheats.append(StoredCheat(code: code, name: name))
            codeInput = ""
            lastCodeInput = ""
            nameInput = ""
            showError = false
            codeProblem = nil
            focusedField = nil
            saveCheats()
        } else {
            codeProblem = nil   // the core refused a well-shaped code
            showError = true
        }
    }

    private func reapplyAll() {
        onClearCheats()
        let enabled = cheats.filter { $0.enabled }
        onReapplyCheats(enabled)
    }

    private var storageKey: String { "cheats_\(romName)" }

    private func saveCheats() {
        if let data = try? JSONEncoder().encode(cheats) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadCheats() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([StoredCheat].self, from: data)
        else { return }
        cheats = saved
    }
}
