//
//  ZipROMPickerSheet.swift
//  EmulateurGBA
//
//  Selection sheet for a zip that contains several games: one row per ROM
//  entry, all selected by default (a collection zip is usually imported
//  whole), Cancel / Add (n) in the toolbar. Presented by LibraryView when
//  ROMImporter throws .zipNeedsSelection.
//

import SwiftUI

/// A multi-ROM zip staged by ROMImporter, awaiting the user's game picks.
/// `tempZipURL` is the importer's temp copy of the archive; it survives
/// until `importZIPSelection` consumes it or `discardZIPSelection` drops it.
struct ZipSelectionRequest: Identifiable {
    let id = UUID()
    let tempZipURL: URL
    /// Full entry names of the ROM files inside, in archive order.
    let entryNames: [String]
}

struct ZipROMPickerSheet: View {
    let entryNames: [String]
    /// Called with the picked entry names, in archive order.
    let onImport: ([String]) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<String>

    init(entryNames: [String], onImport: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.entryNames = entryNames
        self.onImport = onImport
        self.onCancel = onCancel
        _selected = State(initialValue: Set(entryNames))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(entryNames, id: \.self) { name in
                        row(for: name)
                    }
                } header: {
                    Text(NSLocalizedString("zipPicker.caption", comment: ""))
                }
            }
            .navigationTitle(NSLocalizedString("zipPicker.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(format: NSLocalizedString("zipPicker.add", comment: ""), selected.count)) {
                        onImport(entryNames.filter { selected.contains($0) })
                    }
                    .fontWeight(.semibold)
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    private func row(for name: String) -> some View {
        let isOn = selected.contains(name)
        return HStack(spacing: 12) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundColor(isOn ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(for: name))
                    .font(.body)
                    .lineLimit(2)
                Text(consoleLabel(for: name))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            if isOn { selected.remove(name) } else { selected.insert(name) }
        }
    }

    /// Filename cleaned the same way the library titles are, so the picker
    /// shows "Pokemon - FireRed Version", not "Pokemon - FireRed Version
    /// (USA, Europe) (Rev 1).gba".
    private func displayTitle(for name: String) -> String {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
        return ROMImporter.cleanGameTitle(stem)
    }

    /// Console tag from the extension (GBA / GB / GBC / NDS — proper nouns,
    /// not localized).
    private func consoleLabel(for name: String) -> String {
        URL(fileURLWithPath: name).pathExtension.uppercased()
    }
}
