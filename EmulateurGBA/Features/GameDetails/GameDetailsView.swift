//
//  GameDetailsView.swift
//  Retro Pal
//
//  Shows game info, save state slots, and launch options.
//

import SwiftUI
import PhotosUI

struct GameDetailsView: View {
    /// Observed so a rename updates the nav title and header text immediately
    /// while the user is still on this view. NSManagedObject conforms to
    /// ObservableObject via Combine, so @ObservedObject is the right wrapper.
    @ObservedObject var game: GameEntity
    let onPlay: (URL, Int?) -> Void  // (romURL, slotToLoad?)
    let onDelete: () -> Void

    /// Observed so the save-slots screen warns (instead of silently showing an
    /// empty list) when iCloud was the user's store but is momentarily unreachable.
    @ObservedObject private var iCloudSync = iCloudSaveSync.shared
    @ObservedObject private var ra = RetroAchievements.shared
    /// Observed so the RA section switches live between its states (resolving →
    /// eligible/unavailable, progress counts) as the index updates.
    @ObservedObject private var raIndex = RAGameIndex.shared

    @State private var showAchievements = false
    @State private var showRAInfo = false
    @State private var showRALogin = false

    @State private var slots: [SaveSlotInfo] = []
    @State private var autoSlot: SaveSlotInfo?
    /// Bumped on `.saveStatesDidChange` so the header cover re-reads the freshly
    /// written auto-save preview — its .id alone keys on lastPlayedAt, which is
    /// re-stamped at dismiss, before the async write lands.
    @State private var saveTick = 0
    @State private var showDeleteConfirm = false
    @State private var showNewGameConfirm = false
    @State private var showRenameAlert = false
    @State private var renameDraft = ""
    /// Photo picked as this game's custom cover (the library-wide answer
    /// for games no database covers: ROM hacks, homebrew).
    @State private var coverPickerItem: PhotosPickerItem? = nil
    /// The picked photo awaiting the square crop editor.
    @State private var pendingCover: PendingCover? = nil
    /// A failed cover save MUST notify (never a silent failure).
    @State private var showCoverError = false
    @State private var showSavePicker = false
    /// Drives the ROM-file picker for the save-preserving "Replace game file"
    /// recovery (fixes a corrupted/missing ROM without dropping save states).
    @State private var showROMPicker = false
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
                DocumentPickerView(contentTypes: DocumentPickerView.saveTypes) { urls in
                    guard let url = urls.first else { return }
                    handlePickedSave(url: url)
                }
            }
            .sheet(isPresented: $showROMPicker) {
                DocumentPickerView(contentTypes: DocumentPickerView.romTypes) { urls in
                    guard let url = urls.first else { return }
                    handleReplaceROM(url: url)
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
                        achievementsSection
                    }
                }
            } else {
                // Portrait: single scrolling list.
                List {
                    gameHeaderSection
                    launchButtonsSection
                    saveStatesSection
                    manageSection
                    achievementsSection
                }
            }
        }
        .sheet(isPresented: $showAchievements) {
            // The sheet opens instantly; it owns the display load (skeleton
            // while fetching, offline/retry state on failure).
            if let filename = game.romFilePath {
                RAAchievementsView(romURL: romsDir.appendingPathComponent(filename))
            }
        }
        .sheet(isPresented: $showRAInfo) { RAAboutSheet() }
        .sheet(isPresented: $showRALogin) { RALoginView() }
        .navigationTitle(game.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(verticalSizeClass == .compact ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(verticalSizeClass == .compact ? .visible : .automatic, for: .tabBar)
        .onAppear {
            refreshSlots()
            // Make sure this game's RA eligibility is known (resolves
            // credential-free; no-op once cached).
            if let filename = game.romFilePath, let romHash = game.romHash {
                ra.noteGame(.init(romHash: romHash, filename: filename,
                                  path: romsDir.appendingPathComponent(filename).path,
                                  title: game.title ?? ""))
            }
            Haptics.tap()  // gentle tick on opening a game's details (push only;
                           // this onAppear doesn't fire returning from gameplay)
        }
        // A save state changed on disk — either a local write just landed (the
        // auto-save on quit/background completes after this view re-appeared) or
        // iCloud pulled a remote save. Re-read the slots so the resume preview
        // reflects disk, without having to recreate the view.
        .onReceive(NotificationCenter.default.publisher(for: .saveStatesDidChange)) { _ in
            refreshSlots()
            saveTick &+= 1   // re-key the header cover so it re-reads the new preview
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
            Button(NSLocalizedString("details.newGame", comment: "")) {
                playFresh()
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("details.newGame.confirm.message", comment: ""))
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
        .alert(NSLocalizedString("details.cover.error", comment: ""), isPresented: $showCoverError) {}
        // Custom cover picked: decode off the picker's Task, then open the
        // square crop editor. An undecodable image alerts right away.
        .onChange(of: coverPickerItem) { item in
            guard let item else { return }
            coverPickerItem = nil
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let data, let image = UIImage(data: data) {
                        pendingCover = PendingCover(image: image)
                    } else {
                        showCoverError = true
                    }
                }
            }
        }
        // Full screen (not a sheet): the editor's pan gesture must never
        // fight a drag-to-dismiss.
        .fullScreenCover(item: $pendingCover) { pending in
            CoverCropView(image: pending.image) { cropped in
                if !BoxArtManager.shared.setCustomCover(cropped, for: game) {
                    showCoverError = true
                }
            }
        }
    }

    // MARK: - Sections

    /// RetroAchievements for this game, shown below everything. Four states:
    ///   • eligible + connected → open the dashboard (display-load, no running
    ///     game needed), with the user's progress as a caption
    ///   • eligible + not connected → a visible invite to connect, so the
    ///     feature is discoverable instead of hidden behind Settings
    ///   • resolved ineligible (no RA set for this ROM) → a small
    ///     "not available" note
    ///   • not resolved yet (fresh import, offline) → nothing, no flicker
    @ViewBuilder
    private var achievementsSection: some View {
        if ra.isEnabled, let filename = game.romFilePath {
            let record = raIndex.record(forFilename: filename)
            if let record, record.isEligible {
                Section {
                    if ra.isLoggedIn {
                        achievementsDashboardRow(filename: filename, record: record)
                    } else {
                        achievementsConnectRow
                    }
                } header: {
                    RASectionHeader(onInfo: { showRAInfo = true })
                }
            } else if record != nil || RAClient.consoleId(forROMPath: filename) == 0 {
                Section {
                } header: {
                    RASectionHeader(onInfo: { showRAInfo = true })
                } footer: {
                    Text(String(localized: "ra.details.unavailable",
                                defaultValue: "RetroAchievements is not available for this game."))
                }
            }
        }
    }

    /// The signed-in row: the dashboard on tap (the sheet opens instantly and
    /// loads itself). When counts are known, the caption + the gold progress
    /// bar + the points mirror the dashboard header the tap opens — all in the
    /// Label's TEXT column, so they align with the title, not with the icon.
    private func achievementsDashboardRow(filename: String, record: RAGameRecord) -> some View {
        Button {
            showAchievements = true
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(String(localized: "details.achievements", defaultValue: "View achievements"))
                            .foregroundStyle(.primary)
                        if record.refreshedAt != nil, record.total > 0 {
                            HStack {
                                Text(String(format: String(localized: "ra.dashboard.summary",
                                                           defaultValue: "%lld of %lld unlocked"),
                                            record.unlocked, record.total))
                                Spacer(minLength: 8)
                                if let earned = record.pointsEarned, let total = record.pointsTotal {
                                    Text("\(earned) / \(total) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                                        .monospacedDigit()
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            ProgressView(value: Double(record.unlocked), total: Double(record.total))
                                .tint(.yellow)
                        }
                    }
                } icon: {
                    Image(systemName: "trophy")
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The not-connected invite: this game HAS achievements; one line explains
    /// what that means, the button opens the sign-in sheet.
    private var achievementsConnectRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label(String(localized: "ra.details.invite.headline",
                             defaultValue: "Earn achievements in this game"),
                      systemImage: "trophy")
                Text(String(localized: "ra.details.invite.caption",
                            defaultValue: "This game has a RetroAchievements set: challenges to complete as you play, tracked with a free account."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                showRALogin = true
            } label: {
                Text(String(localized: "ra.connect", defaultValue: "Connect your account"))
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var gameHeaderSection: some View {
        Section {
            VStack(spacing: 12) {
                // The header ALWAYS shows the living screenshot — covers of
                // every kind (libretro, RA, custom) are library-only
                // (settled 2026-07-10, reverting an earlier attempt
                // at showing the custom cover here).
                GameCoverView(romFilePath: game.romFilePath)
                    // Re-instantiate the cover (re-reads the auto-save preview
                    // from disk) when the game is played (lastPlayedAt) AND when
                    // the auto-save write lands (saveTick, bumped on
                    // .saveStatesDidChange) — the write completes after
                    // lastPlayedAt is re-stamped at dismiss. Same as LibraryRow.
                    .id("\((game.lastPlayedAt ?? .distantPast).timeIntervalSinceReferenceDate)#\(saveTick)")
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
                    Haptics.tap()
                    playWithSlot(SaveStateManager.autoSaveSlotIndex)
                } label: {
                    Label(NSLocalizedString("details.continue", comment: ""), systemImage: "play.circle.fill")
                        .font(.headline)
                }
            }

            Button {
                Haptics.tap()
                if autoSlot?.exists == true {
                    showNewGameConfirm = true
                } else {
                    playFresh()
                }
            } label: {
                Label(autoSlot?.exists == true ? NSLocalizedString("details.newGame", comment: "") : NSLocalizedString("details.play", comment: ""), systemImage: "play.fill")
            }
        } footer: {
            Text(NSLocalizedString("details.launch.footer", comment: ""))
        }
    }

    /// Shown in place of the "no saves" empty state when the user had iCloud
    /// quick-saves but iCloud is momentarily unreachable, so an empty list is not
    /// mistaken for data loss (and the user is told not to reset / start over).
    private var iCloudUnavailableWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.icloud")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("details.iCloudUnavailable.title",
                                       comment: "iCloud quick-saves temporarily unavailable"))
                    .font(.subheadline).fontWeight(.semibold)
                Text(NSLocalizedString("details.iCloudUnavailable.body",
                                       comment: "Reassure saves are safe; tell the user not to reset or start over"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var saveStatesSection: some View {
        Section(NSLocalizedString("details.saveSlots", comment: "")) {
            if slots.allSatisfy({ !$0.exists }) {
                if iCloudSync.shouldWarnUnavailable {
                    iCloudUnavailableWarning
                } else {
                    Text(NSLocalizedString("details.noSaves", comment: "No save states yet."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(slots.filter { $0.exists }, id: \.slotIndex) { slot in
                    Button {
                        Haptics.tap()
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
                showROMPicker = true
            } label: {
                Label(NSLocalizedString("details.replaceROM", comment: ""), systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                renameDraft = game.title ?? ""
                showRenameAlert = true
            } label: {
                Label(NSLocalizedString("details.rename", comment: ""), systemImage: "pencil")
            }
            PhotosPicker(selection: $coverPickerItem, matching: .images) {
                Label(NSLocalizedString("details.cover.choose", comment: ""), systemImage: "photo")
            }
            if game.coverType == BoxArtManager.coverStateCustom {
                Button {
                    BoxArtManager.shared.removeCustomCover(for: game)
                } label: {
                    Label(NSLocalizedString("details.cover.remove", comment: ""), systemImage: "xmark.circle")
                }
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
    /// Save-preserving recovery: replace this game's ROM file in place (fixes a
    /// corrupted/missing file) while keeping its save states. The copy runs
    /// synchronously while the picker's security scope is still valid; the result
    /// alert is deferred until the picker sheet has dismissed.
    private func handleReplaceROM(url: URL) {
        // Run the replace synchronously while the picker's security scope is valid,
        // capturing the result as a closure to present once the sheet dismisses.
        let outcome: () -> Void
        do {
            try ROMImporter(context: viewContext).replaceROMFile(for: game, from: url)
            outcome = {
                saveInfo = SaveImportInfo(
                    title: NSLocalizedString("replaceROM.success.title", comment: ""),
                    message: NSLocalizedString("replaceROM.success.message", comment: ""))
            }
        } catch ROMImportError.differentGame {
            outcome = { showImportError(NSLocalizedString("replaceROM.error.differentGame", comment: "")) }
        } catch {
            outcome = { showImportError(NSLocalizedString("replaceROM.error.invalid", comment: "")) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: outcome)
    }

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

/// Identifiable wrapper so fullScreenCover(item:) can present the picked
/// photo in the crop editor (UIImage itself is not Identifiable).
private struct PendingCover: Identifiable {
    let id = UUID()
    let image: UIImage
}
