//
//  GameCoverView.swift
//  EmulateurGBA
//
//  Shows the latest save state preview as game cover art.
//  Falls back to a placeholder if no save exists.
//

import SwiftUI

struct GameCoverView: View {
    let romFilePath: String?

    var body: some View {
        if let image = loadLatestPreview() {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Game screenshot")
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray5))
                .overlay(
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16))
                )
                .accessibilityLabel("No screenshot available")
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
