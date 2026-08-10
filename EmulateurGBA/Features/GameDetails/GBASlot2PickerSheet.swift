//
//  GBASlot2PickerSheet.swift
//  EmulateurGBA
//
//  Selection sheet for the NDS slot-2 GBA game (dual-slot): "Nothing
//  inserted" plus the GBA games in the library, checkmark on the current
//  pick. Presented by GameDetailsView for NDS games; picking a row selects
//  and dismisses.
//

import SwiftUI
import CoreData

struct GBASlot2PickerSheet: View {
    /// Stored ROM filename (`GameEntity.romFilePath`) of the current pick,
    /// nil when the slot is empty.
    let currentFilename: String?
    /// Called with the picked game's stored filename (nil = empty the slot).
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @FetchRequest(
        entity: GameEntity.entity(),
        sortDescriptors: [NSSortDescriptor(key: "title", ascending: true,
                                           selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))],
        predicate: NSPredicate(format: "systemType == %@", "gba")
    ) private var gbaGames: FetchedResults<GameEntity>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: NSLocalizedString("slot2.none", comment: ""), filename: nil, cover: nil)
                    ForEach(gbaGames) { game in
                        row(title: game.title ?? (game.romFilePath ?? ""),
                            filename: game.romFilePath,
                            cover: game)
                    }
                    if gbaGames.isEmpty {
                        Text(NSLocalizedString("slot2.empty", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    // The save note leads, raised out of the paragraph into a
                    // callout: it is the one line here whose absence costs a
                    // real transfer. `.textCase(nil)` because grouped headers
                    // uppercase by default, which mangles prose.
                    VStack(alignment: .leading, spacing: 10) {
                        InfoCallout(text: NSLocalizedString("slot2.saveNote", comment: ""))
                        Text(NSLocalizedString("slot2.caption", comment: ""))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .textCase(nil)
                    .padding(.bottom, 6)
                }
            }
            .navigationTitle(NSLocalizedString("slot2.row", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) { dismiss() }
                }
            }
        }
    }

    /// One selectable row. `cover` is the game entity for the box-art
    /// thumbnail (same cover chain as the library rows: cover file, else the
    /// save-state screenshot, else the placeholder); nil for the "None" row.
    private func row(title: String, filename: String?, cover: GameEntity?) -> some View {
        let isCurrent = filename == currentFilename
        return HStack(spacing: 12) {
            if let cover {
                GameCoverView(romFilePath: cover.romFilePath,
                              boxArtURL: BoxArtManager.shared.coverFileURL(
                                forROMHash: cover.romHash, coverType: cover.coverType),
                              fixedWidth: 40)
            }
            Text(title)
                .lineLimit(2)
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            onSelect(filename)
            dismiss()
        }
    }
}
