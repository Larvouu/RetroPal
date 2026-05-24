//
//  GameDetailsView.swift
//  Retro Pal
//
//  Shows game info, save state slots, and launch options.
//

import SwiftUI

struct GameDetailsView: View {
    /// Observed so a rename updates the nav title and header text immediately
    /// while the user is still on this view. NSManagedObject conforms to
    /// ObservableObject via Combine, so @ObservedObject is the right wrapper.
    @ObservedObject var game: GameEntity
    let onPlay: (URL, Int?) -> Void  // (romURL, slotToLoad?)
    let onDelete: () -> Void

    @State private var slots: [SaveSlotInfo] = []
    @State private var autoSlot: SaveSlotInfo?
    @State private var showDeleteConfirm = false
    @State private var showNewGameConfirm = false
    @State private var showRenameAlert = false
    @State private var renameDraft = ""
    @State private var showSavePicker = false
    /// Single-OK info alert covering both the success and error outcomes of
    /// a save import (one alert binding instead of two stacked on the view).
    @State private var saveInfo: SaveImportInfo?
    /// Set when an imported save would overwrite an existing one; drives the
    /// overwrite-confirmation alert. The bytes are held here so confirming
    /// can replay the write with `overwriting: true`.
    @State private var pendingOverwrite: BatterySaveImporter.Pending?
    /// Set when the picked save's filename doesn't match this game's ROM,
    /// suggesting it belongs to a different game. Drives a warning dialog.
    @State private var pendingMismatch: BatterySaveImporter.Pending?

    /// Title + message for the post-import info alert.
    private struct SaveImportInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var romName: String {
        guard let path = game.romFilePath else { return "" }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private var romsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ROMs", isDirectory: true)
    }

    var body: some View {
        coreBody
            .sheet(isPresented: $showSavePicker) {
                DocumentPickerView(contentTypes: DocumentPickerView.saveTypes) { url in
                    handlePickedSave(url: url)
                }
            }
            .alert(
                saveInfo?.title ?? "",
                isPresented: Binding(
                    get: { saveInfo != nil },
                    set: { if !$0 { saveInfo = nil } }
                )
            ) {
                Button(NSLocalizedString("common.ok", comment: "")) { saveInfo = nil }
            } message: {
                Text(saveInfo?.message ?? "")
            }
            .alert(
                NSLocalizedString("saveImport.overwrite.title", comment: ""),
                isPresented: Binding(
                    get: { pendingOverwrite != nil },
                    set: { if !$0 { pendingOverwrite = nil } }
                )
            ) {
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {
                    pendingOverwrite = nil
                }
                Button(NSLocalizedString("saveImport.overwrite.confirm", comment: ""), role: .destructive) {
                    if let pending = pendingOverwrite {
                        applySave(pending, overwriting: true)
                    }
                    pendingOverwrite = nil
                }
            } message: {
                Text(String(format: NSLocalizedString("saveImport.overwrite.message", comment: ""),
                            game.title ?? ""))
            }
            .confirmationDialog(
                NSLocalizedString("saveImport.mismatch.title", comment: ""),
                isPresented: Binding(
                    get: { pendingMismatch != nil },
                    set: { if !$0 { pendingMismatch = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(NSLocalizedString("saveImport.mismatch.confirm", comment: ""), role: .destructive) {
                    let pending = pendingMismatch
                    pendingMismatch = nil
                    // Defer so the dialog finishes dismissing before a
                    // follow-up overwrite alert or success alert presents.
                    if let pending = pending {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            applySave(pending, overwriting: false)
                        }
                    }
                }
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {
                    pendingMismatch = nil
                }
            } message: {
                Text(String(format: NSLocalizedString("saveImport.mismatch.message", comment: ""),
                            game.title ?? ""))
            }
    }

    private var coreBody: some View {
        Group {
            if verticalSizeClass == .compact {
                // Landscape: game card on the left, everything else on the right.
                HStack(spacing: 0) {
                    List {
                        gameHeaderSection
                    }
                    List {
                        launchButtonsSection
                        saveStatesSection
                        manageSection
                    }
                }
            } else {
                // Portrait: single scrolling list.
                List {
                    gameHeaderSection
                    launchButtonsSection
                    saveStatesSection
                    manageSection
                }
            }
        }
        .navigationTitle(game.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(verticalSizeClass == .compact ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(verticalSizeClass == .compact ? .visible : .automatic, for: .tabBar)
        .onAppear { refreshSlots() }
        // When iCloud pulls a save from another device, the metadata
        // query posts this notification; refresh the slot list so the
        // new remote save shows up without the user navigating away.
        .onReceive(NotificationCenter.default.publisher(for: .iCloudSaveStatesDidChange)) { _ in
            refreshSlots()
        }
        // When the user quits a game, LibraryView re-stamps lastPlayedAt — we
        // listen to that change to re-fetch the save-state slots so the auto-
        // save indicator + slot previews reflect what was just written to disk.
        // (.onAppear doesn't fire when returning from a fullScreenCover.)
        .onChange(of: game.lastPlayedAt) { _ in refreshSlots() }
        .confirmationDialog(NSLocalizedString("details.delete.confirm", comment: ""), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(NSLocalizedString("details.delete", comment: ""), role: .destructive) {
                onDelete()
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
        }
        .confirmationDialog(NSLocalizedString("details.newGame.confirm.title", comment: ""), isPresented: $showNewGameConfirm, titleVisibility: .visible) {
            Button(NSLocalizedString("details.newGame", comment: ""), role: .destructive) {
                playFresh()
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
        }
        .alert(NSLocalizedString("details.rename.title", comment: ""), isPresented: $showRenameAlert) {
            TextField("", text: $renameDraft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("common.save", comment: "")) {
                commitRename()
            }
        }
    }

    // MARK: - Sections

    private var gameHeaderSection: some View {
        Section {
            VStack(spacing: 12) {
                GameCoverView(romFilePath: game.romFilePath)
                    // Re-instantiate the cover (which re-reads the auto-save
                    // preview from disk) whenever the game has just been
                    // played. Same trick as in LibraryRow.
                    .id(game.lastPlayedAt ?? .distantPast)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(game.title ?? "Unknown Game")
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                HStack(spacing: 16) {
                    if let playTime = gamePlayTimeFormatted {
                        Text(playTime)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if game.romSize > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: game.romSize, countStyle: .file))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var launchButtonsSection: some View {
        Section {
            if let auto = autoSlot, auto.exists {
                Button {
                    playWithSlot(SaveStateManager.autoSaveSlotIndex)
                } label: {
                    Label(NSLocalizedString("details.continue", comment: ""), systemImage: "play.circle.fill")
                        .font(.headline)
                }
            }

            Button {
                if autoSlot?.exists == true {
                    showNewGameConfirm = true
                } else {
                    playFresh()
                }
            } label: {
                Label(autoSlot?.exists == true ? NSLocalizedString("details.newGame", comment: "") : NSLocalizedString("details.play", comment: ""), systemImage: "play.fill")
            }
        }
    }

    private var saveStatesSection: some View {
        Section(NSLocalizedString("details.saveSlots", comment: "")) {
            if slots.allSatisfy({ !$0.exists }) {
                Text(NSLocalizedString("details.noSaves", comment: "No save states yet."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(slots.filter { $0.exists }, id: \.slotIndex) { slot in
                    Button {
                        playWithSlot(slot.slotIndex)
                    } label: {
                        HStack(spacing: 12) {
                            if let manager = saveStateManager,
                               let img = manager.loadPreviewImage(slot: slot.slotIndex) {
                                Image(uiImage: img)
                                    .resizable()
                                    .interpolation(.none)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 60)
                                    .cornerRadius(4)
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 60, height: 40)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: NSLocalizedString("overlay.slot", comment: ""), "\(slot.slotIndex)"))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                if let date = slot.date {
                                    Text(date, formatter: dateTimeFormatter)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Image(systemName: "arrow.right.circle")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
        }
    }

    /// Single management section. Import-save (the per-game battery-save
    /// import) and rename are non-destructive and sit above the destructive
    /// delete at the bottom.
    private var manageSection: some View {
        Section {
            Button {
                showSavePicker = true
            } label: {
                Label(NSLocalizedString("saveImport.title", comment: ""), systemImage: "square.and.arrow.down")
            }
            Button {
                renameDraft = game.title ?? ""
                showRenameAlert = true
            } label: {
                Label(NSLocalizedString("details.rename", comment: ""), systemImage: "pencil")
            }
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label(NSLocalizedString("details.delete", comment: ""), systemImage: "trash")
            }
        }
    }

    // MARK: - Battery-save import (this game)

    /// Picker callback. Reads + classifies the file immediately, while its
    /// security scope is still valid, then defers the result handling until
    /// the picker sheet has dismissed (so the result alert isn't dropped
    /// mid-transition).
    private func handlePickedSave(url: URL) {
        // `lastPathComponent` is pure string work, no file read, so it's
        // safe to capture without the security scope. Used for the
        // filename-vs-ROM mismatch heuristic below.
        let saveBasename = url.deletingPathExtension().lastPathComponent
        let result = BatterySaveImporter.prepare(url: url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            applyPrepared(result, saveBasename: saveBasename)
        }
    }

    private func applyPrepared(_ result: Result<BatterySaveImporter.Pending, BatterySaveImportError>,
                               saveBasename: String) {
        switch result {
        case .failure(let error):
            showImportError(error.errorDescription)
        case .success(let pending):
            // The picker is save-only, but a user could still pick a `.srm`
            // for a GBA game (or vice versa). Reject a save whose family
            // doesn't match THIS game.
            guard let sys = game.systemType,
                  pending.system.compatibleSystemTypes.contains(sys) else {
                showImportError(NSLocalizedString("saveImport.error.wrongSystem", comment: ""))
                return
            }
            // Emulators export saves under the ROM's filename, so a basename
            // that doesn't match this game's ROM suggests the save is for a
            // different game. Warn but allow override — alternate ROM dumps
            // and manual renames are legitimate, and raw saves carry no
            // game ID we could check instead.
            if saveBasename != romName {
                pendingMismatch = pending
            } else {
                applySave(pending, overwriting: false)
            }
        }
    }

    private func applySave(_ pending: BatterySaveImporter.Pending, overwriting: Bool) {
        do {
            try BatterySaveImporter.writeImport(data: pending.data,
                                                romBasename: romName,
                                                overwriting: overwriting)
            saveInfo = SaveImportInfo(
                title: NSLocalizedString("saveImport.success.title", comment: ""),
                message: String(format: NSLocalizedString("saveImport.success.message", comment: ""),
                                game.title ?? "")
            )
        } catch BatterySaveImportError.duplicateExists {
            pendingOverwrite = pending
        } catch let error as BatterySaveImportError {
            showImportError(error.errorDescription)
        } catch {
            showImportError(error.localizedDescription)
        }
    }

    private func showImportError(_ message: String?) {
        saveInfo = SaveImportInfo(
            title: NSLocalizedString("library.importError", comment: ""),
            message: message ?? ""
        )
    }

    /// Commit the rename to Core Data. Trims whitespace, rejects empty input,
    /// and no-ops when the title is unchanged. The Core Data save propagates
    /// to LibraryView automatically via @FetchRequest.
    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != game.title else { return }
        game.title = trimmed
        try? viewContext.save()
    }

    // MARK: - Helpers

    private var saveStateManager: SaveStateManager? {
        guard !romName.isEmpty else { return nil }
        return SaveStateManager(romName: romName)
    }

    private func refreshSlots() {
        guard let manager = saveStateManager else { return }
        slots = manager.allManualSlots()
        autoSlot = manager.autoSaveSlot()
    }

    private func playFresh() {
        guard let filename = game.romFilePath else { return }
        let url = romsDir.appendingPathComponent(filename)
        onPlay(url, nil)
    }

    private func playWithSlot(_ slot: Int) {
        guard let filename = game.romFilePath else { return }
        let url = romsDir.appendingPathComponent(filename)
        onPlay(url, slot)
    }

    /// Total cumulative play time for this game, formatted with the same
    /// "Xh Ymin" / "Ymin" style used in the library row. Returns nil if
    /// the game has < 60s tracked (matching LibraryView's threshold so
    /// brand-new ROMs don't show a noisy "0 min").
    private var gamePlayTimeFormatted: String? {
        guard !romName.isEmpty else { return nil }
        let seconds = PromptTracker.shared.gamePlayTime(romName: romName)
        guard seconds >= 60 else { return nil }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return String(format: NSLocalizedString("library.playTime", comment: ""), "\(hours)", "\(minutes)")
        } else {
            return String(format: NSLocalizedString("library.playTime.minutes", comment: ""), "\(minutes)")
        }
    }

    private var dateTimeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }
}
