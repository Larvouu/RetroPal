//
//  CoverChooserSheet.swift
//  EmulateurGBA
//
//  "Choose cover" used to go straight to the photo library. The library
//  cover can come from four places, and only one of them is a photo
//  (decided on device, 2026-09-05): the box art from libretro's database, the
//  RetroAchievements game image, the player's own last quick-save
//  screenshot, or a photo of their choosing. This sheet lays the four out
//  with a preview each and a check on the one in use; a tap applies it and
//  closes. The photo option hands back to the page, which opens the picker
//  once this sheet is gone, so the crop editor never has to present over a
//  sheet.
//
//  Only covers that exist are offered: the box art when its file is on disk,
//  the RetroAchievements image when it is on disk or RA has one to fetch. The
//  screenshot and the photo are always there. What is offered is decided by
//  `BoxArtManager`, and the choice is written as an explicit state it never
//  overrides.
//

import SwiftUI
import CoreData

struct CoverChooserSheet: View {
    @ObservedObject var game: GameEntity
    /// The player wants a photo: the page presents the picker after this
    /// sheet is dismissed.
    let onPickPhoto: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var raBusy = false
    @State private var raFailed = false

    private var manager: BoxArtManager { BoxArtManager.shared }
    private var romHash: String? { game.romHash }

    private var hasBoxArt: Bool { romHash.map { manager.hasDownloadedArt(forROMHash: $0) } ?? false }
    private var hasRAOnDisk: Bool { romHash.map { manager.hasRAArt(forROMHash: $0) } ?? false }
    private var raFetchURL: URL? { romHash.flatMap { manager.raArtURL(forROMHash: $0) } }
    private var offersRA: Bool { hasRAOnDisk || raFetchURL != nil }

    private var isBoxArtChosen: Bool {
        [BoxArtManager.coverStateBoxArt, BoxArtManager.coverStateBoxArtHeuristic,
         BoxArtManager.coverStateBoxArtChosen].contains(game.coverType ?? "")
    }
    private var isRAChosen: Bool { game.coverType == BoxArtManager.coverStateRA }
    private var isCustomChosen: Bool { game.coverType == BoxArtManager.coverStateCustom }
    /// Every state that shows the screenshot in the library, the sweep's own
    /// "no match" included.
    private var isScreenshotChosen: Bool { !isBoxArtChosen && !isRAChosen && !isCustomChosen }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if hasBoxArt, let romHash {
                        row(title: NSLocalizedString("cover.choose.boxart", comment: ""),
                            chosen: isBoxArtChosen) {
                            fileThumbnail(manager.imageURL(forROMHash: romHash))
                        } action: {
                            manager.choose(coverState: BoxArtManager.coverStateBoxArtChosen, for: game)
                            dismiss()
                        }
                    }
                    if offersRA, let romHash {
                        row(title: NSLocalizedString("cover.choose.ra", comment: ""),
                            chosen: isRAChosen, busy: raBusy) {
                            if hasRAOnDisk {
                                fileThumbnail(manager.raImageURL(forROMHash: romHash))
                            } else {
                                remoteThumbnail(raFetchURL)
                            }
                        } action: {
                            raBusy = true
                            manager.chooseRAArt(for: game) { ok in
                                raBusy = false
                                if ok { dismiss() } else { raFailed = true }
                            }
                        }
                    }
                    row(title: NSLocalizedString("cover.choose.screenshot", comment: ""),
                        chosen: isScreenshotChosen) {
                        GameCoverView(romFilePath: game.romFilePath)
                            .frame(width: 56, height: 56)
                    } action: {
                        manager.choose(coverState: BoxArtManager.coverStateScreenshot, for: game)
                        dismiss()
                    }
                    row(title: NSLocalizedString("cover.choose.photo", comment: ""),
                        chosen: isCustomChosen) {
                        if isCustomChosen, let romHash {
                            fileThumbnail(manager.customImageURL(forROMHash: romHash))
                        } else {
                            thumbnailFrame {
                                Image(systemName: "photo")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } action: {
                        onPickPhoto()
                        dismiss()
                    }
                } footer: {
                    Text(NSLocalizedString("cover.choose.caption", comment: ""))
                }
            }
            .navigationTitle(NSLocalizedString("details.cover.choose", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "")) { dismiss() }
                }
            }
            // A fetch that failed must be said, never swallowed.
            .alert(NSLocalizedString("details.cover.error", comment: ""), isPresented: $raFailed) {}
        }
    }

    // MARK: - Rows

    private func row<Thumb: View>(title: String, chosen: Bool, busy: Bool = false,
                                  @ViewBuilder thumbnail: () -> Thumb,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                thumbnail()
                Text(title)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if busy {
                    ProgressView()
                } else if chosen {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private func thumbnailFrame<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.15))
            content()
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func fileThumbnail(_ url: URL) -> some View {
        thumbnailFrame {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
            }
        }
    }

    private func remoteThumbnail(_ url: URL?) -> some View {
        thumbnailFrame {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill().frame(width: 56, height: 56)
            } placeholder: {
                Image(systemName: "trophy")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
