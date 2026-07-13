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
    /// Cover image on disk (user-picked or downloaded — the caller resolves
    /// the priority), shown instead of the save-state preview when the file
    /// exists (a missing file falls back to the screenshot silently).
    var boxArtURL: URL? = nil
    /// Remote cover (the RetroAchievements game image, square): when given,
    /// it OUTRANKS the local file — the caller only passes it when RA's
    /// byte-level identification beats our heuristic match (base-named ROM
    /// hacks) or when there is no local cover at all. Loaded async; the
    /// local cover (else the screenshot) shows while loading and stays on
    /// failure.
    var remoteArtURL: URL? = nil
    /// Library-only harmonized sizing: the view sizes ITSELF to this fixed
    /// width (the width a GBA screenshot occupies in the row) and lets the
    /// height follow the image's own aspect ratio, capped at a square —
    /// GB/GBC screenshots and covers then span the same width as GBA
    /// instead of shrinking inside a 3:2 frame, and the cap keeps the one
    /// genuinely tall case (the NDS two-screen preview, 1.5x as tall as
    /// wide) from stretching the row. nil = the caller frames the view
    /// (Game Details keeps its height-based header layout).
    var fixedWidth: CGFloat? = nil

    var body: some View {
        if let remoteArtURL {
            AsyncImage(url: remoteArtURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    localArtContent
                }
            }
            // RA game images are square; frame(nil, nil) is a no-op.
            .frame(width: fixedWidth, height: fixedWidth)
            .accessibilityLabel("Game box art")
        } else {
            localArtContent
        }
    }

    /// The on-disk cover (user-picked or downloaded), else the screenshot
    /// chain. Also what shows under a still-loading or failed remote image.
    @ViewBuilder
    private var localArtContent: some View {
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
    /// controller placeholder. Also what shows under a still-loading or
    /// failed remote image.
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
        // Use URL API to strip any extension (.gba, .gb, .gbc) correctly
        let romName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
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
