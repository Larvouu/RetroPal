//
//  CheatEditSheet.swift
//  EmulateurGBA
//
//  Editing a cheat that is already saved.
//
//  The gap this closes was named by a 3-star review: a saved cheat could be
//  toggled or deleted and nothing else, so fixing one wrong character meant
//  deleting the entry and typing the whole code again.
//
//  WHY THERE IS NO LIVE FORMATTER HERE, unlike the add field. That formatter
//  exists to tidy a code as it is being typed, and it deliberately refuses to
//  reformat a mid-string edit because the caret would jump. Editing an existing
//  code is mid-string editing by definition, so every keystroke in this sheet is
//  the case the formatter already declines to touch. Validation therefore
//  happens once, on save, which is also where the core gets its say.
//

import SwiftUI

struct CheatEditSheet: View {
    let cheat: CheatManagerView.StoredCheat
    /// The console's code-shape sentence, the same one the add field shows.
    let formatHint: String
    let placeholderText: String
    /// Commits the edit. Returns nil on success, or the message to show when
    /// the shape check or the core refuses the code.
    let onSave: (String, String) -> String?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var code: String
    @State private var errorText: String?
    @FocusState private var codeFocused: Bool

    init(cheat: CheatManagerView.StoredCheat,
         formatHint: String,
         placeholderText: String,
         onSave: @escaping (String, String) -> String?) {
        self.cheat = cheat
        self.formatHint = formatHint
        self.placeholderText = placeholderText
        self.onSave = onSave
        _name = State(initialValue: cheat.name)
        _code = State(initialValue: cheat.code)
    }

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing to save when the code is empty, and nothing to save when neither
    /// field moved. The second half matters more than it looks: a code the core
    /// accepted once is re-offered to the core on every edit, so a no-op save
    /// would put a perfectly good cheat through a round trip for nothing.
    private var canSave: Bool {
        !trimmedCode.isEmpty
            && (trimmedCode != cheat.code
                || name.trimmingCharacters(in: .whitespacesAndNewlines) != cheat.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("cheats.namePlaceholder", comment: ""),
                              text: $name)
                        .autocorrectionDisabled()
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        // TextEditor has no placeholder of its own, and an
                        // empty code field with no example is the one state
                        // where a player cannot tell what shape is expected.
                        if code.isEmpty {
                            Text(placeholderText)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.5))
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $code)
                            .onChange(of: code) { _ in errorText = nil }
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .frame(minHeight: 96)
                            .focused($codeFocused)
                    }
                } footer: {
                    // Inline and red, the same way the add field reports a bad
                    // code. An alert here would cover the field the message is
                    // about, and this sheet's whole job is looking at that
                    // field.
                    VStack(alignment: .leading, spacing: 6) {
                        if let errorText {
                            Text(errorText)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(formatHint)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("cheats.edit.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "")) { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    /// The sheet stays open on refusal, with the code still in the field. The
    /// alternative is dismissing and losing what was typed, which for a code
    /// somebody has just corrected by hand is the worst possible response to
    /// "that is not quite right".
    private func save() {
        codeFocused = false
        if let message = onSave(name, code) {
            errorText = message
        } else {
            dismiss()
        }
    }
}
