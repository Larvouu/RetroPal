//
//  SaveTargetPickerSheet.swift
//  EmulateurGBA
//
//  A battery save opened from outside the app (Files' "Open in Retro Pal",
//  the share sheet, AirDrop) names no game: it is bare save RAM, and only its
//  file name hints at what it belongs to. When that name is exactly one
//  library game's ROM name, the library takes the save straight to that game.
//  Otherwise this sheet asks, listing only the games of the consoles the file
//  can belong to (by its size, `BatterySaveImporter.consoles(acceptingSaveOf:)`), the names
//  closest to the file's first. Picking a game hands the save to its Game
//  Details page, which writes it through the same import as its own
//  "Import Save" button: the "Save from a different game?" question first
//  (the names differ, or the sheet would not have been needed), then the
//  existing save kept as a backup on replace.
//

import SwiftUI
import CoreData

/// A save already read and classified, on its way to one game's page. The
/// bytes are held here because the file it came from may be gone by then (an
/// AirDrop copy in Inbox is removed as soon as it is read).
struct OpenedSave: Identifiable, Equatable {
    let id = UUID()
    let pending: BatterySaveImporter.Pending
    /// The file's name as it arrived, for the sheet's caption.
    let fileName: String

    static func == (lhs: OpenedSave, rhs: OpenedSave) -> Bool { lhs.id == rhs.id }

    /// The file name without its extension: what other emulators name a save
    /// after (the ROM's own name).
    var baseName: String { (fileName as NSString).deletingPathExtension }
}

struct SaveTargetPickerSheet: View {
    let save: OpenedSave
    /// The games the save can belong to, already ranked (see `ranked`).
    let candidates: [GameEntity]
    let onSelect: (GameEntity) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Where an opened save goes, decided from the library alone (pure, so
    /// the tests drive it): nowhere when no game of its consoles is in the
    /// library; straight to the one game whose ROM name the file carries;
    /// otherwise the chooser, closest names first. Two games with that same
    /// ROM name on two consoles of the family are a question, not a guess.
    enum Destination {
        case noGame
        case game(GameEntity)
        case choose([GameEntity])
    }

    static func destination(for save: OpenedSave, in library: [GameEntity]) -> Destination {
        let candidates = library.filter {
            save.pending.consoles.contains($0.systemType ?? "")
        }
        guard !candidates.isEmpty else { return .noGame }
        let sameName = candidates.filter {
            BatterySaveImporter.romBasename(forStoredFilename: $0.romFilePath ?? "") == save.baseName
        }
        if sameName.count == 1, let game = sameName.first { return .game(game) }
        return .choose(ranked(candidates, forSaveNamed: save.baseName))
    }

    /// The candidates, the ones whose title or ROM name is closest to the
    /// file's name first, then A to Z. Similarity is the box-art matcher's
    /// own (Dice over character pairs, accents and punctuation folded), so
    /// "Pokemon - Emerald Version (USA).sav" finds "Pokémon Emerald".
    static func ranked(_ games: [GameEntity], forSaveNamed saveName: String) -> [GameEntity] {
        let query = BoxArtIndex.bigrams(BoxArtIndex.normalized(
            BoxArtIndex.strippingParentheticals(saveName)))
        func score(_ game: GameEntity) -> Double {
            let rom = BatterySaveImporter.romBasename(forStoredFilename: game.romFilePath ?? "")
            let names = [game.title ?? "", rom]
            return names.map {
                BoxArtIndex.dice(query, BoxArtIndex.bigrams(BoxArtIndex.normalized(
                    BoxArtIndex.strippingParentheticals($0))))
            }.max() ?? 0
        }
        return games
            .map { (game: $0, score: score($0)) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return ($0.game.title ?? "").localizedCaseInsensitiveCompare($1.game.title ?? "") == .orderedAscending
            }
            .map(\.game)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates, id: \.objectID) { game in
                        Button {
                            Haptics.tap()
                            onSelect(game)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                GameCoverView(romFilePath: game.romFilePath,
                                              boxArtURL: BoxArtManager.shared.coverFileURL(
                                                forROMHash: game.romHash, coverType: game.coverType),
                                              fixedWidth: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(game.title ?? (game.romFilePath ?? ""))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(SystemColor.name(game.systemType ?? "gba"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    // `.textCase(nil)`: grouped headers uppercase by default,
                    // which mangles a sentence and a file name.
                    Text(String(format: NSLocalizedString("saveOpen.choose.caption", comment: ""),
                                save.fileName))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .textCase(nil)
                        .padding(.bottom, 6)
                }
            }
            .navigationTitle(NSLocalizedString("saveImport.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) { dismiss() }
                }
            }
        }
    }
}
