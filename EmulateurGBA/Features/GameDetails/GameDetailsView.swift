//
//  GameDetailsView.swift
//  Retro Pal
//
//  Shows game info, save state slots, and launch options.
//

import SwiftUI
import PhotosUI
import CoreData

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
    /// Landscape opens the photo picker from a menu item rather than from a
    /// `PhotosPicker` view (a menu can hold buttons only), through the
    /// `.photosPicker` modifier below; portrait keeps its picker row.
    @State private var showCoverPicker = false
    /// The cover chooser (box art, RetroAchievements image, screenshot, or a
    /// photo), in both orientations; its photo option sets the flag, and the
    /// picker opens once the chooser is gone.
    @State private var showCoverChooser = false
    @State private var pickPhotoAfterChooser = false
    @State private var showSavePicker = false
    /// Drives the ROM-file picker for the save-preserving "Replace game file"
    /// recovery (fixes a corrupted/missing ROM without dropping save states).
    @State private var showROMPicker = false
    /// NDS dual-slot: drives the slot-2 GBA game picker sheet.
    @State private var showSlot2Picker = false
    /// Stored ROM filename of this NDS game's slot-2 GBA pick (nil = empty
    /// slot). Mirrors the `gbaSlot2_<rom>` default; kept in @State so the
    /// row refreshes on selection (UserDefaults is not observable).
    @State private var slot2Filename: String?

    // The Nintendo DS settings (moved here from Settings in 1.3.1, so the
    // settings list does not grow a section per console). The keys are read
    // straight from UserDefaults by the session (screen swap) and by the
    // melonDS bridge (clock, language), so this page only edits them.
    @AppStorage("ndsSwapScreens") private var ndsSwapScreens: Bool = false
    @AppStorage("ndsLanguage") private var ndsLanguage: String = "auto"
    @AppStorage("ndsClockManual") private var ndsClockManual: Bool = false
    /// Manual RTC date/time as seconds since 1970, read by MelonDSBridge.
    /// 0 means "never set" — the bridge then falls back to the device clock.
    @AppStorage("ndsManualClockEpoch") private var ndsManualClockEpoch: Double = 0
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
    /// Temp copy of this game's battery save awaiting the share sheet
    /// (export). Item-driven so the sheet always has its URL.
    @State private var exportedSave: ExportedSave?

    private struct ExportedSave: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// Title + message for the post-import info alert.
    private struct SaveImportInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(\.managedObjectContext) private var viewContext
    /// A phone on its side, or an iPad window (see `LandscapeSurface`).
    @LandscapeSurface private var isLandscape
    /// An upright phone in a chosen look (2026-09-07), for the two toggles:
    /// the page's tint goes white there and a white toggle reads as nothing,
    /// so they take the look's accent as the landscape card's do.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared
    private var uprightLook: Bool {
        UprightLook.isActive(isLandscape: isLandscape, store: themeStore)
    }

    /// Canonical basename, via the single source of truth. Deliberately NOT
    /// re-derived here: hand-rolled stripping is what once left GB/GBC/NDS
    /// save-state folders behind on delete (7181fc6), and export, import and
    /// the save path must always agree.
    private var romName: String {
        guard let path = game.romFilePath else { return "" }
        return BatterySaveImporter.romBasename(forStoredFilename: path)
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
            .sheet(item: $exportedSave) { export in
                // Untracked: the "share" signal's cardType mix belongs to the
                // share cards, and the TD signal set is frozen.
                ActivityShareSheet(activityItems: [export.url], tracked: false) {
                    exportedSave = nil
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
            if isLandscape {
                // Landscape: the library's dark ground, the screenshot on the
                // left, cards on the right, the file actions behind an
                // ellipsis. Its own file; this page stays the owner of every
                // state, sheet and alert and hands it closures.
                landscapeBody
            } else {
                // Portrait: single scrolling list. In a chosen look
                // (2026-09-07) the same list in the same order, on the
                // ground with its sections on glass; nothing moves.
                List {
                    gameHeaderSection.landscapeGlassRow()
                    launchButtonsSection.landscapeGlassRow()
                    saveStatesSection.landscapeGlassRow()
                    achievementsSection(.belowSlots).landscapeGlassRow()
                    slot2Section.landscapeGlassRow()
                    ndsSettingsSection.landscapeGlassRow()
                    manageSection.landscapeGlassRow()
                    achievementsSection(.bottom).landscapeGlassRow()
                }
                // White for the plain buttons and links: the default blue
                // does not read on the purple ground (2026-09-07).
                .uprightLook(tint: .white)
            }
        }
        // A sheet on a phone, the whole window on an iPad (`pagePresentation`).
        .pagePresentation(isPresented: $showAchievements) {
            // The sheet opens instantly; it owns the display load (skeleton
            // while fetching, offline/retry state on failure).
            if let filename = game.romFilePath {
                RAAchievementsView(romURL: romsDir.appendingPathComponent(filename))
            }
        }
        .sheet(isPresented: $showRAInfo) { RAAboutSheet() }
        .sheet(isPresented: $showRALogin) { RALoginView() }
        .sheet(isPresented: $showSlot2Picker) {
            GBASlot2PickerSheet(currentFilename: slot2Filename) { picked in
                if let picked {
                    UserDefaults.standard.set(picked, forKey: slot2Key)
                } else {
                    UserDefaults.standard.removeObject(forKey: slot2Key)
                }
                slot2Filename = picked
            }
        }
        .navigationTitle(game.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        // Landscape draws its own top bar (back, title, actions) on the
        // library's ground, so the system bars are hidden there and only
        // there; portrait keeps the bars it always had. ⚠ With the bar
        // hidden the edge-swipe back is not guaranteed; the glass chevron is
        // the way back.
        .toolbar(isLandscape ? .hidden : .visible, for: .navigationBar)
        .toolbar(isLandscape ? .hidden : .visible, for: .tabBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(.automatic, for: .tabBar)
        .onAppear {
            refreshSlots()
            slot2Filename = UserDefaults.standard.string(forKey: slot2Key)
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
        .photosPicker(isPresented: $showCoverPicker, selection: $coverPickerItem, matching: .images)
        .sheet(isPresented: $showCoverChooser, onDismiss: {
            // Presented only once the chooser has left, so the crop editor
            // that follows a pick has nothing to present over.
            if pickPhotoAfterChooser {
                pickPhotoAfterChooser = false
                showCoverPicker = true
            }
        }) {
            CoverChooserSheet(game: game, onPickPhoto: { pickPhotoAfterChooser = true })
        }
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

    // MARK: - Landscape

    /// The landscape layout, fed with this page's facts and one closure per
    /// action. Every closure does exactly what its portrait row does.
    private var landscapeBody: some View {
        GameDetailsLandscapeView(
            game: game,
            saveTick: saveTick,
            slots: slots,
            autoSlot: autoSlot,
            playTime: gamePlayTimeFormatted,
            romName: romName,
            raState: raState,
            slot2Game: game.systemType == "nds" ? slot2Game : nil,
            iCloudUnavailable: iCloudSync.shouldWarnUnavailable,
            ndsSwapScreens: $ndsSwapScreens,
            ndsClockManual: $ndsClockManual,
            ndsManualDate: ndsManualDate,
            ndsLanguage: $ndsLanguage,
            ndsAutoLanguageLabel: ndsAutoLanguageLabel,
            ndsLanguageAutonyms: Self.ndsLanguageAutonyms,
            actions: GameDetailsLandscapeActions(
                resume: {
                    Haptics.tap()
                    playWithSlot(SaveStateManager.autoSaveSlotIndex)
                },
                newGame: {
                    Haptics.tap()
                    if autoSlot?.exists == true {
                        showNewGameConfirm = true
                    } else {
                        playFresh()
                    }
                },
                playSlot: { slot in
                    Haptics.tap()
                    playWithSlot(slot)
                },
                openAchievements: { showAchievements = true },
                raInfo: { showRAInfo = true },
                pickSlot2: { showSlot2Picker = true },
                importSave: { showSavePicker = true },
                exportSave: { exportSave() },
                replaceROM: { showROMPicker = true },
                rename: {
                    renameDraft = game.title ?? ""
                    showRenameAlert = true
                },
                chooseCover: { showCoverChooser = true },
                removeCover: { BoxArtManager.shared.removeCustomCover(for: game) },
                delete: { showDeleteConfirm = true }))
    }

    // MARK: - Sections

    /// Where the RetroAchievements section sits on the page. Signed in, the
    /// dashboard row is part of playing the game and sits right under the save
    /// slots; the invite to connect and the "not available" note are not, and
    /// keep the bottom of the page.
    private enum RAPlacement { case belowSlots, bottom }

    /// RetroAchievements for this game. Four states:
    ///   • eligible + connected → open the dashboard (display-load, no running
    ///     game needed), with the user's progress as a caption; below the slots
    ///   • eligible + not connected → a visible invite to connect, so the
    ///     feature is discoverable instead of hidden behind Settings; bottom
    ///   • resolved ineligible (no RA set for this ROM), OR identified with an
    ///     EMPTY set → the same small "not available" note. A game RA knows and
    ///     has no achievements for used to get the full section and a dashboard
    ///     that opened on nothing, which is a worse answer than "not available"
    ///     dressed as a better one. `hasKnownEmptySet` is the shared predicate,
    ///     so this page and the RA profile cannot disagree about the same game.
    ///   • not resolved yet (fresh import, offline) → nothing, no flicker
    /// The four states above, decided ONCE for both layouts: portrait's
    /// sections and the landscape card read this and never re-derive it, so
    /// the two cannot disagree about the same game.
    private var raState: RADetailsState {
        guard ra.isEnabled, let filename = game.romFilePath else { return .hidden }
        let record = raIndex.record(forFilename: filename)
        if let record, record.isEligible, !record.hasKnownEmptySet {
            return ra.isLoggedIn ? .dashboard(record) : .invite
        }
        if record != nil || RAClient.consoleId(forROMPath: filename) == 0 {
            return .unavailable(isPBP: Self.isUnhashableDiscContainer(filename))
        }
        return .hidden
    }

    @ViewBuilder
    private func achievementsSection(_ placement: RAPlacement) -> some View {
        switch raState {
        case .hidden:
            EmptyView()
        case .dashboard(let record):
            if placement == .belowSlots, let filename = game.romFilePath {
                Section {
                    achievementsDashboardRow(filename: filename, record: record)
                } header: {
                    RASectionHeader(onInfo: { showRAInfo = true })
                }
            }
        case .invite:
            if placement == .bottom {
                Section {
                    achievementsConnectRow
                } header: {
                    RASectionHeader(onInfo: { showRAInfo = true })
                }
            }
        case .unavailable(let isPBP):
            if placement == .bottom {
                Section {
                } header: {
                    RASectionHeader(onInfo: { showRAInfo = true })
                } footer: {
                    // A `.pbp` is the one case where the reason is the FILE and
                    // not the game, and the one a player can act on: the same
                    // game as `.chd` earns achievements normally. "Not
                    // available" would be true and useless.
                    Text(isPBP
                         ? String(localized: "ra.details.unavailable.pbp",
                                  defaultValue: "RetroAchievements cannot read a .pbp file. The same game as .chd, or as .cue with its .bin, earns achievements normally.")
                         : String(localized: "ra.details.unavailable",
                                  defaultValue: "RetroAchievements is not available for this game."))
                }
            }
        }
    }

    /// Whether this game is a PlayStation container RetroAchievements cannot
    /// hash, which today means exactly one format.
    ///
    /// `.pbp` is a repacked, re-encoded archive rather than a disc image: there
    /// is no track 1 to read SYSTEM.CNF off, so rc_hash cannot identify it and
    /// never will. Every other container we accept is a disc image or names
    /// one, and the app's own reader opens `.chd` (see RADiscFileReader), so
    /// this is the whole list rather than a first entry in a growing one.
    static func isUnhashableDiscContainer(_ romFilePath: String) -> Bool {
        (romFilePath as NSString).pathExtension.lowercased() == "pbp"
    }

    /// The signed-in row: the dashboard on tap (the sheet opens instantly and
    /// loads itself). When counts are known, the caption + the gold progress
    /// bar + the points mirror the dashboard header the tap opens — all in the
    /// text column, so they align with the title, not with the picture.
    /// The picture is the game's RetroAchievements box art when RA has one
    /// (the same tile as the RA profile's game list), and the trophy glyph
    /// in a Label's icon column otherwise, as before.
    private func achievementsDashboardRow(filename: String, record: RAGameRecord) -> some View {
        Button {
            showAchievements = true
        } label: {
            HStack {
                if let boxArt = record.boxArtURL.flatMap(URL.init(string:)) {
                    HStack(spacing: 12) {
                        AsyncImage(url: boxArt) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ZStack {
                                Color.gray.opacity(0.15)
                                Image(systemName: "trophy")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        achievementsTextColumn(record: record)
                    }
                } else {
                    Label {
                        achievementsTextColumn(record: record)
                    } icon: {
                        Image(systemName: "trophy")
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func achievementsTextColumn(record: RAGameRecord) -> some View {
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
                        Text("\(earned.formatted()) / \(total.formatted()) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ProgressView(value: Double(record.unlocked), total: Double(record.total))
                    .tint(.yellow)
            }
        }
    }

    /// The not-connected invite: this game HAS achievements; one line explains
    /// what that means, the button opens the sign-in sheet.
    private var achievementsConnectRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 6 between the headline and its note: at 2 the two read as one
            // block (device, 2026-09-07). Same row in both looks.
            VStack(alignment: .leading, spacing: 6) {
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

                Text(game.title ?? NSLocalizedString("library.untitled", comment: ""))
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

    // MARK: - Slot 2 (NDS dual-slot)

    /// UserDefaults key holding this NDS game's slot-2 GBA pick (the GBA
    /// game's stored ROM filename). Read by EmulatorViewController at launch.
    private var slot2Key: String { "gbaSlot2_\(romName)" }

    /// Library entity of the current slot-2 pick, nil when the slot is empty
    /// or the picked GBA game has since been deleted (shown as an empty slot,
    /// same as the emulator's fail-soft behavior at boot).
    private var slot2Game: GameEntity? {
        guard let filename = slot2Filename else { return nil }
        let request = NSFetchRequest<GameEntity>(entityName: "GameEntity")
        request.predicate = NSPredicate(format: "romFilePath == %@", filename)
        request.fetchLimit = 1
        return (try? viewContext.fetch(request))?.first
    }

    /// NDS games only: pick a GBA game from the library to sit in slot 2,
    /// like on the original DS (Pal Park migration, cross-game bonuses).
    ///
    /// A filled slot answers on its OWN row rather than in the trailing
    /// position: the label is long in most locales and library titles are
    /// user-editable, so a trailing value truncates to a few characters.
    /// The full-width row also carries the cover, so the cart looks the same
    /// here, in the picker, and on the NDS dress.
    @ViewBuilder
    private var slot2Section: some View {
        if game.systemType == "nds" {
            let picked = slot2Game
            Section {
                Button {
                    showSlot2Picker = true
                } label: {
                    HStack {
                        Label(NSLocalizedString("slot2.row", comment: ""), systemImage: "rectangle.stack")
                        Spacer()
                        // An empty slot answers right here; a filled one is
                        // answered by the row below.
                        if picked == nil {
                            Text(NSLocalizedString("slot2.none", comment: ""))
                                .foregroundColor(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Color.secondary.opacity(0.7))
                    }
                }
                if let picked {
                    Button {
                        showSlot2Picker = true
                    } label: {
                        HStack(spacing: 12) {
                            GameCoverView(romFilePath: picked.romFilePath,
                                          boxArtURL: BoxArtManager.shared.coverFileURL(
                                            forROMHash: picked.romHash, coverType: picked.coverType),
                                          fixedWidth: 44)
                            Text(picked.title ?? (picked.romFilePath ?? ""))
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    // Plain so the title reads as content, like the picker's
                    // own rows, and not as a tinted link.
                    .buttonStyle(.plain)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    InfoCallout(text: NSLocalizedString("slot2.saveNote", comment: ""))
                    Text(NSLocalizedString("slot2.caption", comment: ""))
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Nintendo DS settings (moved here from Settings in 1.3.1)

    /// NDS firmware languages by index (0-6), shown as autonyms — the iOS
    /// language-picker convention, locale-independent (a language reads best
    /// in its own name). Order matches the firmware language enum the bridge
    /// uses, so the index doubles as the stored tag value.
    private static let ndsLanguageAutonyms = ["日本語", "English", "Français", "Deutsch", "Italiano", "Español", "中文"]

    /// Label for the picker's "auto" option, naming the language it will
    /// actually use on this device. The DS firmware only speaks these seven
    /// languages, so a device set to e.g. Slovenian truthfully resolves to
    /// "Auto (English)" (the firmware fallback), not a Slovenian the hardware
    /// can't produce. Pulled from the bridge so the label and the real
    /// behaviour can't drift apart.
    private var ndsAutoLanguageLabel: String {
        let index = Int(MelonDSBridge.autoResolvedNDSLanguageIndex())
        let name = Self.ndsLanguageAutonyms.indices.contains(index) ? Self.ndsLanguageAutonyms[index] : "English"
        return String(format: NSLocalizedString("settings.nds.language.auto", comment: ""), name)
    }

    /// Two-way bridge between the stored epoch (Double) and the DatePicker's
    /// Date. Shows "now" until the user picks a value, so the picker never
    /// opens on 1970.
    private var ndsManualDate: Binding<Date> {
        Binding(
            get: { ndsManualClockEpoch > 0 ? Date(timeIntervalSince1970: ndsManualClockEpoch) : Date() },
            set: { ndsManualClockEpoch = $0.timeIntervalSince1970 }
        )
    }

    /// The three DS settings, on a DS game's page. They are still app-wide
    /// (one default each, as in Settings), shown here because this is where a
    /// DS player looks for them; the game's own rows (save slots, slot 2) sit
    /// above and the file management below.
    @ViewBuilder
    private var ndsSettingsSection: some View {
        if game.systemType == "nds" {
            Section(header: Text("Nintendo DS"),
                    footer: Text(DeviceWording.string("settings.nds.language.footer"))) {
                Toggle(NSLocalizedString("settings.nds.swapScreens", comment: ""), isOn: $ndsSwapScreens)
                    .tint(uprightLook ? LibraryLandscapePalette.accent : nil)

                Toggle(NSLocalizedString("settings.nds.clock.manual", comment: ""), isOn: $ndsClockManual)
                    .tint(uprightLook ? LibraryLandscapePalette.accent : nil)
                if ndsClockManual {
                    DatePicker(NSLocalizedString("settings.nds.clock.pickerLabel", comment: ""),
                               selection: ndsManualDate)
                }

                // Language last, so the section footer (which describes game
                // language behaviour) sits directly under it.
                Picker(NSLocalizedString("settings.nds.language", comment: ""), selection: $ndsLanguage) {
                    Text(ndsAutoLanguageLabel).tag("auto")
                    ForEach(Array(Self.ndsLanguageAutonyms.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(String(index))
                    }
                }
            }
        }
    }

    /// Single management section. Import/export-save (the per-game battery
    /// save) and rename are non-destructive and sit above the destructive
    /// delete at the bottom.
    private var manageSection: some View {
        Section {
            Button {
                showSavePicker = true
            } label: {
                Label(NSLocalizedString("saveImport.title", comment: ""), systemImage: "square.and.arrow.down")
            }
            Button {
                exportSave()
            } label: {
                Label(NSLocalizedString("saveExport.title", comment: ""), systemImage: "square.and.arrow.up")
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
            Button {
                showCoverChooser = true
            } label: {
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

    // MARK: - Battery-save export (this game)

    /// Share this game's in-game battery save. The file is copied to a temp
    /// name other emulators expect for the system (.sav for GBA/GB/GBC/NES,
    /// .srm for NDS/SNES, .mcd for a PlayStation memory card — the same routing
    /// our own importer uses, so a round-trip export/import always works).
    /// No save yet -> explanatory alert.
    private func exportSave() {
        let source = BatterySaveImporter.savePath(forRomBasename: romName)
        guard FileManager.default.fileExists(atPath: source.path) else {
            saveInfo = SaveImportInfo(
                title: NSLocalizedString("saveExport.none.title", comment: ""),
                message: NSLocalizedString("saveExport.none.message", comment: ""))
            return
        }
        // The extension every other emulator expects for this console's save.
        // On disk we keep one canonical `.sav` per game whatever the console;
        // this only names the copy that leaves the app.
        // The PlayStation's file is a 128 KB memory card, not save RAM, and
        // `.mcd` is the name every PlayStation emulator reads. We also ACCEPT
        // `.srm` on the way in, because that is what libretro frontends write,
        // but a file leaving the app should carry the name that describes it.
        let ext: String
        switch game.systemType {
        case "nds", "snes": ext = "srm"
        case "ps1":         ext = "mcd"
        default:            ext = "sav"
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveExport", isDirectory: true)
        let dest = dir.appendingPathComponent("\(romName).\(ext)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: source, to: dest)
            exportedSave = ExportedSave(url: dest)
        } catch {
            // A failed export MUST notify (never a silent failure).
            saveInfo = SaveImportInfo(
                title: NSLocalizedString("saveExport.title", comment: ""),
                message: NSLocalizedString("saveExport.error.message", comment: ""))
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

/// RetroAchievements on a game's page, one of four states, decided by
/// `GameDetailsView.raState` and rendered by both layouts.
enum RADetailsState {
    /// Not resolved yet (fresh import, offline), or RA is off: show nothing.
    case hidden
    /// Eligible and signed in: the dashboard row with the record's progress.
    case dashboard(RAGameRecord)
    /// Eligible and not signed in: the invite to connect.
    case invite
    /// No set for this game, or a set RA cannot hash from this file.
    case unavailable(isPBP: Bool)
}
