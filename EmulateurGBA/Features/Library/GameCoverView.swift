//
//  GameCoverView.swift
//  EmulateurGBA
//
//  Shows the latest save state preview as game cover art.
//  Falls back to a placeholder if no save exists.
//  The library passes boxArtURL to show the game's downloaded cover
//  instead; Game Details never does, so it keeps the screenshot.
//

import SwiftUI

struct GameCoverView: View {
    let romFilePath: String?
    /// Cover image on disk (user-picked, adopted RA image, or downloaded —
    /// the caller resolves the priority), shown instead of the save-state
    /// preview when the file exists (a missing file falls back to the
    /// screenshot silently).
    var boxArtURL: URL? = nil
    /// Library-only harmonized sizing: the view sizes ITSELF to this fixed
    /// width (the width a GBA screenshot occupies in the row) and lets the
    /// height follow the image's own aspect ratio, capped at a square —
    /// GB/GBC screenshots and covers then span the same width as GBA
    /// instead of shrinking inside a 3:2 frame, and the cap keeps the one
    /// genuinely tall case (the NDS two-screen preview, 1.5x as tall as
    /// wide) from stretching the row. nil = the caller frames the view
    /// (Game Details keeps its height-based header layout).
    var fixedWidth: CGFloat? = nil

    // The on-disk cover (user-picked, RA, or downloaded), else the
    // screenshot chain. Always a local file: no async phase, no flash.
    var body: some View {
        if let boxArtURL, let boxArt = UIImage(contentsOfFile: boxArtURL.path) {
            // No .interpolation(.none) here: covers are photographic
            // artwork, not pixel art like the screenshots below.
            harmonized(Image(uiImage: boxArt)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8)),
                       imageSize: boxArt.size)
                .accessibilityLabel("Game box art")
        } else {
            fallbackContent
        }
    }

    /// The pre-box-art behavior: latest save-state preview, else the
    /// controller placeholder.
    @ViewBuilder
    private var fallbackContent: some View {
        if let image = loadLatestPreview() {
            harmonized(Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8)),
                       imageSize: image.size)
                .accessibilityLabel("Game screenshot")
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray5))
                .overlay(
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16))
                )
                // In harmonized mode the empty placeholder keeps the
                // classic GBA 3:2 footprint; frame(nil, nil) is a no-op.
                .frame(width: fixedWidth, height: fixedWidth.map { $0 * 2 / 3 })
                .accessibilityLabel("No screenshot available")
        }
    }

    /// Applies the harmonized frame (fixed width, ratio-driven height,
    /// square cap); passthrough when the caller does its own framing.
    @ViewBuilder
    private func harmonized<Content: View>(_ content: Content, imageSize: CGSize) -> some View {
        if let width = fixedWidth, imageSize.width > 0 {
            content.frame(width: width,
                          height: min(width * imageSize.height / imageSize.width, width))
        } else {
            content
        }
    }

    private func loadLatestPreview() -> UIImage? {
        guard let filename = romFilePath else { return nil }
        // The game's storage key, from the one function that answers it. It was
        // "the filename without its extension", which is right for a cartridge
        // and wrong for a disc: that game lives in a FOLDER and its save states
        // are filed under the folder, so this looked for previews under a name
        // nothing had ever written.
        let romName = BatterySaveImporter.romBasename(forStoredFilename: filename)
        guard !romName.isEmpty else { return nil }

        let manager = SaveStateManager(romName: romName)

        // Try auto-save first (most recent), then manual slots newest first
        if let img = manager.loadPreviewImage(slot: SaveStateManager.autoSaveSlotIndex) {
            return img
        }

        let slots = manager.allManualSlots()
            .filter { $0.exists }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        if let newest = slots.first {
            return manager.loadPreviewImage(slot: newest.slotIndex)
        }

        return nil
    }
}
