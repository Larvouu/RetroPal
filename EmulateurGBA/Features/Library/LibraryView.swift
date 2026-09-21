//
//  LibraryView.swift
//  EmulateurGBA
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IdentifiableURL: Identifiable {
    let id: String
    let url: URL
    init(_ url: URL) {
        self.id = url.absoluteString
        self.url = url
    }
}

/// Wraps ROM URL + optional save slot to load.
struct LaunchRequest: Identifiable {
    let id = UUID().uuidString
    let url: URL
    let loadSlot: Int?
    let systemType: String
    /// User-facing display name (may differ from the ROM filename after rename).
    /// Threaded through to ScreenshotCardRenderer so the share card honors the
    /// renamed title instead of falling back to the on-disk filename.
    let gameTitle: String?
    /// File size recorded at import. Lets the emulator pre-flight the on-disk
    /// ROM (a missing/truncated file is the cause of the rare "won't load"
    /// black screen) and show an actionable message instead of a dead end.
    let expectedSize: Int64

    /// The emulator session, built ONCE when the game is launched.
    ///
    /// It used to be built inside the cover's content closure, which SwiftUI
    /// re-runs on every body evaluation: each pass constructed another core,
    /// handed it to a view that had already been made, and dropped it. That was
    /// invisible waste for three cores and fatal for the fourth. libretro has
    /// ONE global core instance, so PCSX-ReARMed cannot be built twice, and it
    /// said so by name the moment a PlayStation game reached a re-render.
    ///
    /// Carrying it on the request is what makes "one launch, one core" a fact
    /// about the type rather than a hope about how often SwiftUI re-renders.
    let session: EmulatorSession
}

struct LibraryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        entity: GameEntity.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \GameEntity.lastPlayedAt, ascending: false),
                          NSSortDescriptor(keyPath: \GameEntity.importedAt, ascending: false)]
    ) private var games: FetchedResults<GameEntity>
    /// Settings ▸ Debug ▸ Presentation mode (2026-09-10): the fake library
    /// stands in for the real one everywhere this page reads its games, and
    /// every action on a game is a no-op while it is on. See `LibraryPresentation`.
    @AppStorage(LibraryPresentation.key) private var presentationFlag = false
    private var presenting: Bool { LibraryPresentation.isOn(presentationFlag) }
    /// The games this page shows: the fetch, or the fake library.
    private var displayedGames: [GameEntity] {
        presenting ? LibraryPresentation.games : Array(games)
    }

    /// URL inbox for the Files → "Open in Retro Pal" flow. Set by
    /// AppShellView.onOpenURL; consumed (set back to nil) here once the
    /// import is dispatched. Binding-driven so cold-launch URLs still
    /// arrive correctly — the .onChange below fires on first render.
    @Binding var pendingOpenURL: URL?
    /// Game launch requested from a home-screen widget. Same binding-driven
    /// shape as `pendingOpenURL` so a cold launch still lands.
    @Binding var pendingPlayRequest: WidgetSharing.PlayRequest?
    /// The shell's tab selection. Landscape draws its own Library / Settings
    /// switch at the right edge (the system tab bar is hidden there), and it
    /// needs to move the shell to Settings.
    @Binding var selectedTab: AppTab
    /// Whether the Library is the selected tab (passed by AppShellView). Gates
    /// the screenshot-to-share detection so it never fires from the Settings tab.
    var isActiveTab: Bool = true

    /// Landscape on iPhone renders the games as one line of covers with the
    /// selected game centred (`LibraryLandscapeView`, since 1.3.1); portrait
    /// keeps the single-column List. An iPad window takes the line in both
    /// orientations (see `LandscapeSurface`).
    @LandscapeSurface private var isLandscape
    /// An upright PHONE takes the same surface, the hero and the List on
    /// glass, when the player picks a look from the palette beside the plus
    /// (2026-09-07); "Classic" in that picker is the List, and the default.
    /// An iPad window narrowed to a phone's width (windowed, Stage Manager)
    /// is an upright phone here too (decided on device, 2026-09-08): it used
    /// to keep the List whatever the look, which read as a forced Classic.
    /// An iPad window wide enough to be one shows the surface either way up.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    private var usesThemedPortrait: Bool {
        !isLandscape && !themeStore.portraitClassic
    }

    @State private var showFilePicker = false
    /// The two glass panels of the List's bar (2026-09-07): the sort and the
    /// look. They used to be system menus, and every switch between the List
    /// and a look left a stale menu interaction behind the bar that UIKit
    /// then tried to refresh ("updateVisibleMenuWithBlock while no context
    /// menu is visible", once more per switch). The panels are plain views.
    @State private var showSortPicker = false
    @State private var showThemePicker = false
    @State private var launchRequest: LaunchRequest?
    @State private var importError: String?
    @State private var showImportError = false
    /// Games the import skipped because they were already in the library. Not a
    /// failure, so not in `importError`: it gets its own calm notice at the end
    /// of the batch, through the same follow-up chain the other post-import
    /// sheets use.
    @State private var duplicateNotice: [String] = []
    @State private var showDuplicateNotice = false
    @State private var isImporting = false
    @State private var searchText = ""
    /// Persisted across launches: the chosen sort survives an app kill (the
    /// user gets the same library arrangement next open). RawRepresentable<String>
    /// enums are AppStorage-backed natively on iOS 16+.
    @AppStorage("library.sortOrder") private var sortOrder: SortOrder = .lastPlayed
    /// With the "By console" sort, the one console shown, "" for all of them
    /// (2026-09-07): the sort menu lists the consoles the library holds as a
    /// submenu so a player taps the one they are looking for.
    @AppStorage("library.consoleFilter") private var consoleFilter: String = ""
    /// Bottom-of-library stats block. Recomputed on appear, on save changes
    /// (returning from a game), and on add/delete — PromptTracker lives in
    /// UserDefaults, which SwiftUI can't observe, so we refresh explicitly.
    @State private var stats: LibraryStats?
    /// Presents the shareable retro-story card sheet (opened by tapping the
    /// stats area — no explicit share button, just responding to curiosity).
    @State private var showStoryShare = false
    /// Once-per-session guard for the library screenshot-to-share prompt,
    /// mirroring the in-game screenshot detection's session flag.
    @State private var hasShownStatsScreenshotThisSession = false
    /// RetroAchievements card below the stats. Observed so the card appears/
    /// disappears with eligibility and login state without a manual refresh.
    @ObservedObject private var ra = RetroAchievements.shared
    @ObservedObject private var raIndex = RAGameIndex.shared
    @State private var showRAProfile = false
    @State private var showRAInfo = false
    @State private var showRALogin = false
    /// A recent unlock tapped in the RA card; drives its share-card sheet.
    @State private var raShareUnlock: RAUnlockLogEntry?
    /// Push depth of Game Details over the library list (a row's NavigationLink
    /// bumps it on appear/disappear). Non-zero = the list is not the foreground.
    @State private var detailViewCount = 0
    @State private var renamingGame: GameEntity?
    @State private var renameDraft = ""
    /// True while the "saves are imported per-game" redirect popup is shown.
    /// Triggered when a `.sav`/`.srm` is picked from the library `+` — the
    /// actual import lives on the per-game screen.
    @State private var showSaveRedirect = false
    /// Follow-ups of a multi-file picker batch, presented strictly one at a
    /// time once the ROM imports finish: failure summary (if any) → zip
    /// pickers → save redirect (if a `.sav`/`.srm` was in the batch) → skin
    /// imports. See advanceBatchFollowUps().
    @State private var pendingSaveRedirectAfterBatch = false
    @State private var pendingSkinImports: [URL] = []
    /// Multi-ROM zips awaiting the user's picks (ROMImporter threw
    /// .zipNeedsSelection), presented one sheet at a time by
    /// advanceBatchFollowUps. presentedZipRequest mirrors the active sheet
    /// item so onDismiss (which fires after the item is already nil) still
    /// knows which request to import or clean up; confirmedZipEntryNames is
    /// set by the sheet's Add button just before dismissing (nil on Cancel
    /// and on swipe-down, both of which discard the staged zip).
    @State private var zipSelectionQueue: [ZipSelectionRequest] = []
    @State private var activeZipSelection: ZipSelectionRequest?
    @State private var presentedZipRequest: ZipSelectionRequest?
    @State private var confirmedZipEntryNames: [String]?
    /// Once-per-update What's New sheet (first launch after an update).
    /// The once-per-process flag keeps onAppear re-entries (tab switches,
    /// nav pops) from re-running the check.
    @State private var showWhatsNew = false
    @State private var didCheckWhatsNew = false
    /// The GameEntity currently behind the fullScreenCover. Captured at launch
    /// so we can bump lastPlayedAt again when the user exits — that re-stamp
    /// is what invalidates the cover image's .id() so it reloads the fresh
    /// auto-save preview from disk.
    @State private var currentlyPlayingGame: GameEntity?
    /// Target of a programmatic navigation push (Files-opened duplicate ROM
    /// lands on its existing Game Details view). Paired with
    /// showNavigateDestination because iOS 16's .navigationDestination
    /// takes isPresented, not item.
    @State private var navigateToGame: GameEntity?
    @State private var showNavigateDestination = false
    /// URL queued behind an in-progress game launchRequest. Picked up by
    /// coverDidDismiss once the fullScreenCover dismissal animation finishes.
    @State private var queuedURL: URL?
    /// Widget launch held while a game is still running; fired from
    /// coverDidDismiss, exactly like `queuedURL`.
    @State private var queuedPlayRequest: WidgetSharing.PlayRequest?
    // Session is created per launch with the appropriate bridge for the system type

    #if DEBUG
    /// Debug-only toggle from Settings → Debug → "Force empty-state onboarding".
    /// Lets the dev preview the welcome screen even with games imported.
    @AppStorage("debugForceEmptyState") private var debugForceEmptyState: Bool = false
    #endif

    enum SortOrder: String, CaseIterable {
        case lastPlayed = "lastPlayed"
        case alphabetical = "alphabetical"
        case dateAdded = "dateAdded"
        case byConsole = "byConsole"

        var displayName: String {
            switch self {
            case .lastPlayed: return NSLocalizedString("library.sort.lastPlayed", comment: "")
            case .alphabetical: return "A-Z"
            case .dateAdded: return NSLocalizedString("library.sort.dateAdded", comment: "")
            case .byConsole: return NSLocalizedString("library.sort.byConsole", comment: "")
            }
        }
    }

    /// Canonical console ordering, used only as a stable tiebreak when two
    /// consoles have identical play time (e.g. none played yet).
    private static let consoleFallbackOrder = ["gba", "gb", "gbc", "nds", "snes", "nes", "ps1"]

    private var filteredGames: [GameEntity] {
        let sorted: [GameEntity]
        switch sortOrder {
        case .lastPlayed:
            sorted = displayedGames.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .alphabetical:
            // `localizedStandardCompare` is the Finder ordering: case- and
            // diacritic-aware in the user's language. Plain `<` compares code
            // points, which filed "Pokémon Émeraude" after "Zelda" (É sorts
            // past Z) and every uppercase title before every lowercase one.
            // The widget's game picker already sorted this way; the library
            // did not, so the same collection read in two different orders.
            sorted = displayedGames.sorted { Self.titleOrdered($0, before: $1) }
        case .dateAdded:
            sorted = displayedGames.sorted { ($0.importedAt ?? .distantPast) > ($1.importedAt ?? .distantPast) }
        case .byConsole:
            let rank = consoleDisplayRank
            sorted = displayedGames.sorted { a, b in
                let ra = rank[a.systemType ?? "gba"] ?? Int.max
                let rb = rank[b.systemType ?? "gba"] ?? Int.max
                if ra != rb { return ra < rb }
                // Within one console, A-Z by title.
                return Self.titleOrdered(a, before: b)
            }
        }
        let narrowed = (sortOrder == .byConsole && !consoleFilter.isEmpty)
            ? sorted.filter { ($0.systemType ?? "gba") == consoleFilter }
            : sorted
        if searchText.isEmpty { return narrowed }
        // `localizedStandardContains` folds case, diacritics AND width, which
        // `localizedCaseInsensitiveContains` did not: "pokemon" could not
        // find "Pokémon", and a fullwidth query from a Japanese keyboard
        // matched nothing at all. Same folding the box-art matcher uses.
        return narrowed.filter { ($0.title ?? "").localizedStandardContains(searchText) }
    }

    /// The consoles the library holds, in the canonical order, for the sort
    /// menu's submenu. Read from every game, never from the narrowed list.
    private var consolesInLibrary: [String] {
        let present = Set(displayedGames.map { $0.systemType ?? "gba" })
        return Self.consoleFallbackOrder.filter { present.contains($0) }
    }

    private static func titleOrdered(_ a: GameEntity, before b: GameEntity) -> Bool {
        (a.title ?? "").localizedStandardCompare(b.title ?? "") == .orderedAscending
    }

    /// Per-console ordering for the "Par console" sort: consoles the user has
    /// played the MOST appear first (most total play time across that console's
    /// games), so the heaviest-used system tops the library. Consoles with equal
    /// (or zero) play time fall back to a stable canonical order. Returns a
    /// rank index per systemType raw value (0 = shown first).
    private var consoleDisplayRank: [String: Int] {
        var secondsPerConsole: [String: TimeInterval] = [:]
        for game in displayedGames {
            let system = game.systemType ?? "gba"
            let seconds = LibraryStats.romName(for: game.romFilePath)
                .map { PromptTracker.shared.gamePlayTime(romName: $0) } ?? 0
            secondsPerConsole[system, default: 0] += seconds
        }
        let ordered = secondsPerConsole.keys.sorted { a, b in
            let sa = secondsPerConsole[a] ?? 0
            let sb = secondsPerConsole[b] ?? 0
            if sa != sb { return sa > sb }
            let ia = Self.consoleFallbackOrder.firstIndex(of: a) ?? Int.max
            let ib = Self.consoleFallbackOrder.firstIndex(of: b) ?? Int.max
            return ia < ib
        }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
    }

    /// The display list split into per-console blocks for the "Par console" sort
    /// (each block separated by a small gap in both layouts, no section titles).
    /// Every other sort returns a single block, so layouts stay unchanged.
    /// Because `filteredGames` is already console-ranked then A-Z, a run-length
    /// pass over consecutive same-console games yields the blocks.
    private var gameGroups: [[GameEntity]] {
        let list = filteredGames
        guard sortOrder == .byConsole, !list.isEmpty else { return [list] }
        var groups: [[GameEntity]] = []
        var currentSystem: String?
        for game in list {
            let system = game.systemType ?? "gba"
            if system == currentSystem {
                groups[groups.count - 1].append(game)
            } else {
                groups.append([game])
                currentSystem = system
            }
        }
        return groups
    }

    private var romsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ROMs", isDirectory: true)
    }

    /// Recompute the bottom-of-library stats from the current games + PromptTracker.
    private func refreshStats() {
        let inputs = games.map {
            LibraryStats.GameInput(title: $0.title ?? "",
                                   romFilePath: $0.romFilePath,
                                   systemType: $0.systemType)
        }
        stats = LibraryStats.compute(games: inputs)
        // Keep the RA index in step with the library: resolves eligibility for
        // new imports (credential-free), drops records of deleted games, and
        // refreshes per-game progress (throttled).
        ra.syncLibraryGames(games.compactMap { game in
            guard let filename = game.romFilePath, let romHash = game.romHash else { return nil }
            return .init(romHash: romHash, filename: filename,
                         path: romsDir.appendingPathComponent(filename).path,
                         title: game.title ?? "")
        })
        // Same rhythm for box art: silently resolve covers for games still
        // pending, prune covers of deleted games. Terminal games are a
        // file-existence check each; nothing here touches the network unless
        // a game is still unresolved.
        BoxArtManager.shared.sweep(games: games.compactMap { game in
            guard let filename = game.romFilePath, let romHash = game.romHash else { return nil }
            return .init(romHash: romHash, filename: filename,
                         path: romsDir.appendingPathComponent(filename).path,
                         title: game.title ?? "",
                         system: game.systemType ?? "gba",
                         coverState: game.coverType)
        })
    }

    /// Screenshot-to-share for the library, mirroring the in-game screenshot
    /// detection: present the stats share card once per session — but only when
    /// the library list is the foreground (active tab, no game, no sheet up) and
    /// the stats panel is actually visible (its appearance condition is met).
    private func handleLibraryScreenshot() {
        // The List only: the condition below reads "the stats card is on
        // screen", and on the themed surface, either way up, the card is an
        // icon in the bar, so a screenshot of the line opened the story
        // sheet (audit, 2026-09-05).
        guard isActiveTab, !isLandscape, !usesThemedPortrait,
              detailViewCount == 0,
              launchRequest == nil,
              !showStoryShare, !showFilePicker, !showSaveRedirect,
              !showImportError, !showNavigateDestination, renamingGame == nil,
              activeZipSelection == nil, !showWhatsNew,
              searchText.isEmpty,
              let stats, stats.hasData,
              !hasShownStatsScreenshotThisSession else { return }
        hasShownStatsScreenshotThisSession = true
        showStoryShare = true
    }

    var body: some View {
        // Split into stages via intermediate properties. Each stage is
        // typechecked independently — keeps total chain depth under the
        // SwiftUI type-checker's budget.
        bodyWithSaveImport
            .navigationDestination(isPresented: $showNavigateDestination) {
                navigationDestinationView
            }
            .navigationDestination(isPresented: $showRAProfile) {
                RetroAchievementsView()
            }
            .onChange(of: pendingOpenURL) { url in
                guard let url = url else { return }
                pendingOpenURL = nil
                handleOpenedURL(url)
            }
            .onChange(of: pendingPlayRequest) { request in
                guard let request = request else { return }
                pendingPlayRequest = nil
                handlePlayRequest(request)
            }
            .overlay { importingOverlay }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                handleLibraryScreenshot()
            }
            .sheet(isPresented: $showRAInfo) { RAAboutSheet() }
            .sheet(isPresented: $showRALogin) { RALoginView() }
            .sheet(isPresented: $showWhatsNew) { WhatsNewSheet() }
            .onAppear(perform: checkWhatsNewPresentation)
            .sheet(item: $raShareUnlock) { entry in
                RAShareView(achievement: entry.asAchievementInfo(),
                            gameName: entry.gameTitle,
                            boxArtURL: entry.boxArtURL.flatMap(URL.init(string:)),
                            romFilename: raIndex.filename(forGameID: entry.gameID),
                            onClose: { raShareUnlock = nil })
            }
    }

    /// Wraps `bodyCore` with the redirect popup shown when a `.sav`/`.srm`
    /// is picked from the library `+`. Battery saves are imported per-game
    /// (Game Details → "Importer une sauvegarde"), so this points the user
    /// there instead of importing from the unscoped library entry.
    private var bodyWithSaveImport: some View {
        bodyCore
            .alert(
                NSLocalizedString("saveImport.title", comment: ""),
                isPresented: $showSaveRedirect
            ) {
                Button(NSLocalizedString("common.ok", comment: "")) {
                    showSaveRedirect = false
                    advanceBatchFollowUps()
                }
            } message: {
                Text(NSLocalizedString("saveImport.redirect.message", comment: ""))
            }
    }

    private var bodyCore: some View {
        Group {
            if showEmptyState, isLandscape {
                // The welcome on its side: the library's ground and bar, so a
                // new user turning the phone does not meet the one light page
                // of the tab. Its bar carries the import plus the system bar
                // used to.
                LibraryEmptyLandscapeView(isActive: isActiveTab,
                                          onImport: { showFilePicker = true },
                                          onSettings: { selectedTab = .settings })
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbar(.hidden, for: .tabBar)
            } else if showEmptyState, usesThemedPortrait {
                // The welcome upright in a chosen look: same ground and bar,
                // stacked; the tab bar stays as it does on the game list.
                LibraryEmptyLandscapeView(upright: true,
                                          isActive: isActiveTab,
                                          onImport: { showFilePicker = true },
                                          onSettings: { selectedTab = .settings })
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbarBackground(.visible, for: .tabBar)
                    .toolbarColorScheme(.dark, for: .tabBar)
            } else if showEmptyState {
                // Onboarding: no large title, no search bar — the whole
                // pitch (headline, consoles, steps, CTA) fits without
                // scrolling. The toolbar stays reachable.
                emptyState
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
            } else if isLandscape {
                // No title, no system search bar and no navigation bar at
                // all: the landscape surface draws its own top bar (sort,
                // search, import) and its own Settings circle, so the system
                // bars are hidden here and only here. Game Details and
                // portrait keep theirs. On an iPad, either way up, the
                // surface draws the Library · Settings pill at its bottom in
                // the circle's place (2026-09-08): the system tab bar would
                // stand at the TOP there, over the surface's own bar, and
                // cannot be moved (see `LandscapeChrome.tabPill`).
                gameList
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbar(.hidden, for: .tabBar)
            } else if usesThemedPortrait {
                // Upright in a look: the surface draws its own bar, so the
                // navigation bar goes; the TAB bar stays, dark to sit on the
                // ground, because portrait keeps its navigation model and
                // Settings is a tab.
                gameList
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbarBackground(.visible, for: .tabBar)
                    .toolbarColorScheme(.dark, for: .tabBar)
            } else {
                gameList
                    .navigationTitle(NSLocalizedString("library.title", comment: ""))
                    .searchable(text: $searchText, prompt: NSLocalizedString("library.search", comment: ""))
            }
        }
        .toolbar { libraryToolbar }
        .overlay { barPanels }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView(allowsMultipleSelection: true) { urls in
                // Stage the skeleton row the instant a ROM is picked, so the
                // wait is never blank. The 0.5s defer below only delays the work
                // (it lets the picker finish dismissing before any error alert
                // can present); the skeleton is already on screen by then.
                let nonROM: Set<String> = ["sav", "srm", "retropalskin"]
                if urls.contains(where: { !nonROM.contains($0.pathExtension.lowercased()) }) {
                    isImporting = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    processPickedBatch(urls: urls)
                }
            }
        }
        .sheet(item: $activeZipSelection, onDismiss: zipSheetDidDismiss) { request in
            ZipROMPickerSheet(entryNames: request.entryNames) { names in
                confirmedZipEntryNames = names
                activeZipSelection = nil
            } onCancel: {
                activeZipSelection = nil
            }
        }
        .fullScreenCover(item: $launchRequest, onDismiss: coverDidDismiss) { request in
            emulatorScreen(for: request)
        }
        .alert(NSLocalizedString("library.importError", comment: ""), isPresented: $showImportError) {
            Button(NSLocalizedString("common.ok", comment: "")) { advanceBatchFollowUps() }
        } message: {
            Text(importError ?? "")
        }
        // Its own alert, with its own title. Folding it into the error one would
        // put "Import failed" over a game that is sitting in the library working
        // perfectly.
        .alert(NSLocalizedString("import.duplicate.title", comment: ""), isPresented: $showDuplicateNotice) {
            Button(NSLocalizedString("common.ok", comment: "")) {
                duplicateNotice = []
                advanceBatchFollowUps()
            }
        } message: {
            Text(Self.duplicateMessage(duplicateNotice))
        }
    }

    /// Destination view for the programmatic pushes: the Files → "Open in
    /// Retro Pal" flow when the opened ROM already exists in the library, and
    /// the (i) button of the landscape surface.
    @ViewBuilder
    private var navigationDestinationView: some View {
        if let game = navigateToGame {
            GameDetailsView(
                game: game,
                onPlay: { url, slot in playGame(game, url: url, slot: slot) },
                onDelete: { deleteGame(game) }
            )
        }
    }

    // MARK: - Body Helpers
    // These are extracted to keep the body modifier chain short enough for
    // SwiftUI's type-checker. Each closure-bearing modifier (toolbar,
    // fullScreenCover, overlay) is compiled in isolation now.

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                showSortPicker = true
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel(sortOrder.displayName)
        }
        // Two items, not one HStack: iOS 26 draws one glass pill around a
        // whole item, and the badge is not a button (decided on device, 2026-09-04). The
        // badge is declared first so it sits left of the plus, and its shared
        // background is hidden on iOS 26 the way the RetroAchievements pages
        // hide the about button's.
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarTrailing) {
                ControllerStatusBadge(tint: .primary, compact: true)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                ControllerStatusBadge(tint: .primary, compact: true)
            }
        }
        // The look of the library, left of the plus (2026-09-07): the
        // five looks of the themed surface, which turn it on upright, and
        // "Classic", this List. This bar is only ever the upright one, on a
        // phone or in an iPad window narrowed to a phone's width, and both
        // take the look (2026-09-08; the narrow window used to keep the List
        // and hid this button).
        // On iOS 26 two adjacent items share one glass pill, and the
        // palette and the plus are two actions, not one: a fixed spacer
        // between them gives each its own pill (2026-09-07).
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarTrailing) { paletteButton }
            ToolbarSpacer(.fixed, placement: .navigationBarTrailing)
        } else {
            ToolbarItem(placement: .navigationBarTrailing) { paletteButton }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showFilePicker = true
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    /// The palette in the List's bar: opens the same look panel the themed
    /// surfaces use (Classic, the five looks, the hero switch once a look is
    /// on), so the List and the looks pick the look the same way.
    private var paletteButton: some View {
        Button {
            showThemePicker = true
        } label: {
            Image(systemName: "paintpalette")
        }
        .accessibilityLabel(themeStore.portraitClassic
                            ? NSLocalizedString("library.theme.classic", comment: "")
                            : themeStore.theme.name)
    }

    /// The two panels over whichever surface the page shows; only the
    /// List's bar sets their state, the themed bars keep their own.
    @ViewBuilder
    private var barPanels: some View {
        if showSortPicker {
            LibrarySortPicker(upright: true, sortOrder: $sortOrder, consoleFilter: $consoleFilter,
                              consoles: consolesInLibrary, onClose: { showSortPicker = false })
        }
        if showThemePicker {
            LandscapeThemePicker(offersClassic: true, onClose: { showThemePicker = false })
        }
    }

    /// The core that runs a given console. mGBA stays the default so a library
    /// row whose systemType is somehow unset still launches where it always did.
    private static func makeBridge(systemType: String?) -> any EmulatorBridge {
        switch systemType {
        case "nds":            return MelonDSBridge()
        case "snes", "nes":    return MesenBridge()
        case "ps1":            return PCSXBridge()
        default:               return MGBABridge()
        }
    }

    private func emulatorScreen(for request: LaunchRequest) -> some View {
        EmulatorScreen(
            romURL: request.url,
            session: request.session,
            loadSlot: request.loadSlot,
            gameTitle: request.gameTitle,
            expectedROMSize: request.expectedSize
        ) {
            // Re-stamp lastPlayedAt to "now" so the library row + cover image
            // invalidate. The auto-save preview was just written to disk by
            // EmulatorViewController.overlayDidTapQuit, and the row's cover
            // view is keyed on lastPlayedAt — bumping it forces a fresh disk
            // read instead of showing the old preview.
            if let played = currentlyPlayingGame {
                played.lastPlayedAt = Date()
                try? viewContext.save()
            }
            currentlyPlayingGame = nil
            launchRequest = nil
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var importingOverlay: some View {
        if isImporting {
            // Keep the interaction freeze (a transparent, hit-swallowing layer),
            // but show no modal spinner: the skeleton row at the top of the
            // library now communicates the wait instead.
            Color.black.opacity(0.001).ignoresSafeArea()
        }
    }

    /// True when the welcome/onboarding screen should be shown. Normally fires
    /// when the user has no games imported. Debug builds can also force it via
    /// the Settings → Debug toggle to preview the screen with games present.
    private var showEmptyState: Bool {
        #if DEBUG
        return displayedGames.isEmpty || debugForceEmptyState
        #else
        return displayedGames.isEmpty
        #endif
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 32)

                Text(NSLocalizedString("library.empty.title", comment: ""))
                    .font(.title2.bold())
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)

                Text(DeviceWording.string("library.empty.subtitle"))
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)

                // The four consoles, named — the same colored pixel-art strip
                // as retropal.fr, so a newcomer sees at a glance what plays here.
                ConsoleIconRow()
                    .padding(.horizontal, 24)
                    .padding(.top, 2)

                stepsCard
                    .padding(.horizontal, 24)
                    .padding(.top, 4)

                importCTA
                    .padding(.horizontal, 32)
                    .padding(.top, 4)

                Text(NSLocalizedString("library.empty.romHint", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                    .padding(.top, 4)

                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.75))
                    Text(NSLocalizedString("library.empty.legal", comment: ""))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.07))
                )
                .padding(.horizontal, 32)

                Spacer(minLength: 24)
            }
        }
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepRow(num: 1, text: DeviceWording.string("library.empty.step1"))
            stepRow(num: 2, text: NSLocalizedString("library.empty.step2", comment: ""))
            stepRow(num: 3, text: NSLocalizedString("library.empty.step3", comment: ""))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func stepRow(num: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(num)")
                .font(.subheadline.bold())
                .foregroundColor(.primary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.1))
                .clipShape(Circle())

            LibraryStepLabel(text: text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The shared call to action (`LibraryImportCTA`), also the welcome on its side's.
    private var importCTA: some View {
        LibraryImportCTA { showFilePicker = true }
    }


    /// The games surface. Portrait keeps the single-column List; landscape is
    /// the one-line carousel (`LibraryLandscapeView`). The shared data hooks +
    /// the story-share sheet + the rename alert live on the wrapper so both
    /// layouts get them without duplication.
    private var gameList: some View {
        gameListContent
            .onAppear { refreshStats() }
            .onReceive(NotificationCenter.default.publisher(for: .saveStatesDidChange)) { _ in
                refreshStats()
            }
            .onChange(of: games.count) { _ in refreshStats() }
            .sheet(isPresented: $showStoryShare) {
                if let stats {
                    RetroStoryShareView(stats: stats) { showStoryShare = false }
                }
            }
            .alert(
                NSLocalizedString("details.rename.title", comment: ""),
                isPresented: Binding(
                    get: { renamingGame != nil },
                    set: { if !$0 { renamingGame = nil } }
                )
            ) {
                TextField("", text: $renameDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(false)
                Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {
                    renamingGame = nil
                }
                Button(NSLocalizedString("common.save", comment: "")) {
                    commitRename()
                }
            }
    }

    @ViewBuilder
    private var gameListContent: some View {
        if isLandscape {
            themedSurface(upright: false)
        } else if usesThemedPortrait {
            themedSurface(upright: true)
        } else {
            portraitGameList
        }
    }

    /// Portrait: the original single-column List (swipe-to-delete, grouped style).
    private var portraitGameList: some View {
        gameList(settlingWith: nil)
    }

    /// The List itself. `proxy` is the themed surface's: with one, the List
    /// re-seats itself at its top once it is on screen (see
    /// `settleAtTop(_:)`); the Classic List keeps its bar and needs none.
    private func gameList(settlingWith proxy: ScrollViewProxy?) -> some View {
        List {
            // Games in their own section(s) so the group keeps its rounded corners
            // (the stats block below must not join this section, or the last
            // game row loses its rounded bottom). The "Par console" sort yields one
            // section per console — grouped-List section spacing IS the small gap
            // between blocks (no titles); every other sort is a single section.
            ForEach(Array(gameGroups.enumerated()), id: \.offset) { groupIndex, group in
                Section {
                    // While importing, a skeleton row at the top of the first block
                    // stands in for the game about to appear (the UI stays frozen
                    // via importingOverlay).
                    if isImporting && groupIndex == 0 {
                        LibrarySkeletonRow()
                    }
                    ForEach(group, id: \.self) { game in
                        LibraryRow(
                            game: game,
                            onPlay: { url, slot in playGame(game, url: url, slot: slot) },
                            onDelete: { deleteGame(game) },
                            onRename: {
                                guard !presenting else { return }
                                renameDraft = game.title ?? ""
                                renamingGame = game
                            },
                            detailViewCount: $detailViewCount
                        )
                    }
                    .onDelete { offsets in deleteGames(in: group, at: offsets) }
                }
                // Glass under a look (the scaffold's flag), the system row
                // background on the List; nothing changes in the rows.
                .landscapeGlassRow()
            }

            // "Retro story" stats card, anchored at the bottom after the games
            // (no positioning tricks — for a library worth showing stats, the
            // games scroll, so it's naturally a discovery). Hidden while
            // searching; appears once at least two games are played. In a
            // look the card and RetroAchievements are circles in the bar.
            if searchText.isEmpty, !usesThemedPortrait, !presenting, let stats, stats.hasData {
                Section {
                    LibraryStatsCard(stats: stats)   // library face
                        .contentShape(Rectangle())
                        .onTapGesture { Haptics.tap(); showStoryShare = true }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
                }
            }

            // RetroAchievements card below the stats: appears as soon as one
            // imported game has an RA set (as an invite when not connected),
            // and disappears with the last eligible game.
            if searchText.isEmpty, !usesThemedPortrait, !presenting, ra.isEnabled, raIndex.hasEligibleGame {
                Section {
                    raLibraryCard
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))
                }
            }
        }
        // Inside the `.id` below on purpose: a rebuilt List is a new view and
        // appears again, so every List this page creates gets seated.
        .onAppear {
            if let proxy { settleAtTop(proxy) }
        }
        // A new order or a new console rebuilds the List, so it opens at its
        // top as if the page had been reloaded (2026-09-07), the way the rack
        // on its side goes back to its first cover. The hero switch rebuilds
        // it too (device report, 2026-09-07): a List takes its top inset from
        // where it sits when it is CREATED, so one created with the hero off
        // kept a zero inset once the hero appeared above it, and the gap
        // between the two was gone until a sort or a relaunch rebuilt it.
        .id("\(sortOrder.rawValue)#\(consoleFilter)#\(themeStore.showsHero)")
    }

    /// The List as the upright surface shows it (2026-09-07): the same rows,
    /// the same swipe and links, its scroll background gone so the ground
    /// shows, its sections on glass. The bar above it carries the search.
    private var themedPortraitList: some View {
        ScrollViewReader { proxy in
            gameList(settlingWith: proxy)
                .scrollContentBackground(.hidden)
                .environment(\.landscapeGlassRows, true)
                // The space above the first section is OURS, not UIKit's (device
                // log, 2026-09-07): a grouped List reserves a default header
                // height above a first section with no header, 35 points, and a
                // List created while the Classic navigation bar is still going
                // away got none of it, so the rows sat 35 points closer to the
                // bar until the next rebuild. Reserve nothing, then pad.
                .environment(\.defaultMinListHeaderHeight, 0)
        }
    }

    /// Seats the themed List at its top, twice: the moment it is on screen,
    /// and again once the navigation bar's hide animation has run its course.
    ///
    /// The second device report of 2026-09-07 evening: with the hero on, the
    /// List first RESTS too low and snaps to the right height at the first
    /// scroll, and that height is the one every other state shows. A scroll
    /// view does that when its top inset shrank after it was laid out while
    /// its content offset stayed where the larger inset had put it: the
    /// empty band above the first row is that dead offset, and the first
    /// scroll clamps it away. The inset that shrinks here is the one the
    /// navigation bar lends the page while it is still going away at the
    /// moment the List is created, at launch and on every rebuild. Rather
    /// than guess at UIKit's timing once more, the List is told to show its
    /// first section at the top after the bar is gone, with no animation, so
    /// it rests where a scroll would have left it. Hero on or off, the same
    /// call; a List with no section (a search with no hit) has nothing to
    /// scroll to and is left alone.
    private func settleAtTop(_ proxy: ScrollViewProxy) {
        for delay in [0.0, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    // The sections are identified by their offset, so the first
                    // one is 0 under every sort, headers included.
                    proxy.scrollTo(0, anchor: .top)
                }
            }
        }
    }

    private var raLibraryCard: some View {
        RALibraryCard(
            onConnect: { showRALogin = true },
            onInfo: { showRAInfo = true },
            onOpenProfile: { showRAProfile = true },
            onShareUnlock: { raShareUnlock = $0 })
    }

    /// The themed surface: the line of covers on its side, or the rack on
    /// end upright. The library keeps deciding WHAT is on it (sort, search;
    /// the per-console blocks flatten, since a line has no sections, and the
    /// console badge on each tile keeps the grouping readable) and hands the
    /// surface everything it can trigger: play, details, rename, delete,
    /// import, the Retro story card, RetroAchievements, and the tab switch.
    /// Rename and delete live on the tile's long-press menu, as they did on
    /// the grid cards this replaced.
    private func themedSurface(upright: Bool) -> some View {
        LibraryLandscapeView(
            upright: upright,
            uprightList: upright ? { AnyView(themedPortraitList) } : nil,
            libraryCount: displayedGames.count,
            games: filteredGames,
            isImporting: isImporting,
            sortOrder: $sortOrder,
            consoleFilter: $consoleFilter,
            consoles: consolesInLibrary,
            searchText: $searchText,
            showsStats: searchText.isEmpty && !presenting && (stats?.hasData ?? false),
            showsRA: searchText.isEmpty && !presenting && ra.isEnabled && raIndex.hasEligibleGame,
            // Also paused while a page sits over the library (a game's page,
            // the RetroAchievements profile): the pushed page draws the same
            // ground from the same clock, so the one underneath can rest.
            isActive: isActiveTab && detailViewCount == 0 && !showNavigateDestination && !showRAProfile,
            onPlay: { game, slot in
                guard !presenting, let filename = game.romFilePath else { return }
                playGame(game, url: romsDir.appendingPathComponent(filename), slot: slot)
            },
            onOpenDetails: { game in
                guard !presenting else { return }
                navigateToGame = game
                showNavigateDestination = true
            },
            onRename: { game in
                guard !presenting else { return }
                renameDraft = game.title ?? ""
                renamingGame = game
            },
            onDelete: { game in deleteGame(game) },
            onImport: { showFilePicker = true },
            onStats: {
                Haptics.tap()
                showStoryShare = true
            },
            onRA: {
                Haptics.tap()
                if ra.isLoggedIn { showRAProfile = true } else { showRALogin = true }
            },
            onSettings: { selectedTab = .settings }
        )
    }

    /// Commit the rename from the library context-menu alert. Trims, rejects
    /// empty / unchanged input, then writes to Core Data — the @FetchRequest
    /// auto-refreshes the row, and GameDetailsView (if open) reads the same
    /// managed object.
    private func commitRename() {
        guard let game = renamingGame else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { renamingGame = nil }
        guard !trimmed.isEmpty, trimmed != game.title else { return }
        game.title = trimmed
        try? viewContext.save()
        // A rename changes a title without changing games.count, so refresh the
        // stats explicitly — otherwise a renamed game keeps its old name in the
        // ranking (library footer + the shareable card use the same `stats`).
        refreshStats()
    }

    // MARK: - Actions

    /// First launch after an update: present the What's New sheet, once.
    /// Runs once per process; the gate (WhatsNew.shouldPresentAtLaunch)
    /// stamps fresh installs silently. Suppressed while anything else owns
    /// the screen — an un-stamped suppression simply retries next launch.
    private func checkWhatsNewPresentation() {
        guard !didCheckWhatsNew else { return }
        didCheckWhatsNew = true
        guard isActiveTab, launchRequest == nil, pendingOpenURL == nil,
              WhatsNew.shouldPresentAtLaunch(libraryIsEmpty: games.isEmpty),
              !showEmptyState else { return }
        // Let the tab bar and navigation settle before presenting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Re-check: a Files-opened URL may have started an import or a
            // launch during the delay.
            guard launchRequest == nil, !isImporting, activeZipSelection == nil,
                  !showImportError else { return }
            WhatsNew.markSeen()
            showWhatsNew = true
        }
    }

    /// Routes a freshly-picked batch by extension. ROMs (`.gba`, `.gb`,
    /// `.gbc`, `.nds`, `.zip`) import serially in the background; a
    /// `.sav`/`.srm` queues the per-game redirect popup (battery saves are
    /// imported from a game's detail screen, where the target is
    /// unambiguous); `.retropalskin` files queue skin imports (own
    /// validation + alerts). Follow-ups present one at a time after the
    /// imports finish, via advanceBatchFollowUps().
    private func processPickedBatch(urls: [URL]) {
        var roms: [URL] = []
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "sav", "srm": pendingSaveRedirectAfterBatch = true
            case "retropalskin": pendingSkinImports.append(url)
            default: roms.append(url)
            }
        }
        guard !roms.isEmpty else {
            advanceBatchFollowUps()
            return
        }
        importROMs(urls: roms)
    }

    /// Serial batch import on one background context. Failures are collected
    /// and surfaced in ONE summary alert at the end, never one alert per
    /// file; already-imported files are silently skipped (their game is
    /// already in the library, same as the pre-batch picker behavior).
    private func importROMs(urls: [URL]) {
        isImporting = true
        let context = PersistenceController.shared.container.newBackgroundContext()
        DispatchQueue.global(qos: .userInitiated).async {
            let importer = ROMImporter(context: context)
            var failures: [(filename: String, reason: String)] = []
            var duplicates: [String] = []
            var selectionRequests: [ZipSelectionRequest] = []

            // Discs first, because they are the one console whose games are not
            // files: several picked files can be ONE game, and which ones is a
            // question only the descriptors can answer. Cartridges come back
            // untouched and in their original order.
            let (cartridges, discs, gaps) = DiscImportGrouper.group(urls)

            for gap in gaps {
                Analytics.signal("rom_import", ["result": "error", "errorType": "discMissingFiles", "method": "picker"])
                let error = ROMImportError.discMissingFiles(names: gap.missing)
                failures.append((gap.boot.lastPathComponent, error.errorDescription ?? ""))
            }

            for group in discs {
                do {
                    let _ = try importer.importDiscGroup(group, method: "picker")
                } catch let error as ROMImportError {
                    Analytics.signal("rom_import", ["result": "error", "errorType": error.analyticsID, "method": "picker"])
                    if case .alreadyImported = error {
                        duplicates.append(group.boot.lastPathComponent); continue
                    }
                    failures.append((group.boot.lastPathComponent, error.errorDescription ?? ""))
                } catch {
                    Analytics.signal("rom_import", ["result": "error", "errorType": "unknown", "method": "picker"])
                    failures.append((group.boot.lastPathComponent, error.localizedDescription))
                }
            }

            for url in cartridges {
                do {
                    let _ = try importer.importROM(from: url, method: "picker")
                } catch let error as ROMImportError {
                    // A zip with several games isn't a failure: queue its
                    // selection sheet (no error signal, no summary line).
                    if case .zipNeedsSelection(let tempZipURL, let entryNames) = error {
                        selectionRequests.append(ZipSelectionRequest(tempZipURL: tempZipURL, entryNames: entryNames))
                        continue
                    }
                    Analytics.signal("rom_import", ["result": "error", "errorType": error.analyticsID, "method": "picker"])
                    if case .alreadyImported = error {
                        duplicates.append(url.lastPathComponent); continue
                    }
                    failures.append((url.lastPathComponent, error.errorDescription ?? ""))
                } catch {
                    Analytics.signal("rom_import", ["result": "error", "errorType": "unknown", "method": "picker"])
                    failures.append((url.lastPathComponent, error.localizedDescription))
                }
            }
            DispatchQueue.main.async {
                isImporting = false
                zipSelectionQueue.append(contentsOf: selectionRequests)
                duplicateNotice = duplicates
                if failures.isEmpty {
                    advanceBatchFollowUps()
                } else {
                    // Counted in GAMES, not files. A `.cue` and its `.bin` are
                    // two picked files and one game, and "1 of 2 failed" would
                    // be describing something the person did not do.
                    let gameCount = cartridges.count + discs.count + gaps.count
                    importError = Self.batchErrorMessage(failures: failures, pickedCount: gameCount)
                    showImportError = true   // its OK button advances the follow-up chain
                }
            }
        }
    }

    /// onDismiss of the zip picker sheet. Runs the confirmed import, or (on
    /// Cancel / swipe-down) drops the staged temp zip; either way the
    /// follow-up chain continues.
    private func zipSheetDidDismiss() {
        guard let request = presentedZipRequest else { return }
        presentedZipRequest = nil
        guard let names = confirmedZipEntryNames else {
            ROMImporter.discardZIPSelection(tempZipURL: request.tempZipURL)
            advanceBatchFollowUps()
            return
        }
        confirmedZipEntryNames = nil
        importZipSelection(names: names, from: request)
    }

    /// Background import of the entries picked in the zip sheet; failures
    /// surface via the same one-summary-alert path as the file batch.
    private func importZipSelection(names: [String], from request: ZipSelectionRequest) {
        isImporting = true
        let context = PersistenceController.shared.container.newBackgroundContext()
        DispatchQueue.global(qos: .userInitiated).async {
            let importer = ROMImporter(context: context)
            let (failures, duplicates) = importer.importZIPSelection(entryNames: names,
                                                                      fromTempZip: request.tempZipURL)
            for failure in failures {
                Analytics.signal("rom_import", ["result": "error", "errorType": failure.analyticsID, "method": "zip"])
            }
            DispatchQueue.main.async {
                isImporting = false
                duplicateNotice = duplicates
                if failures.isEmpty {
                    advanceBatchFollowUps()
                } else {
                    importError = Self.batchErrorMessage(
                        failures: failures.map { (filename: $0.displayName, reason: $0.reason) },
                        pickedCount: names.count)
                    showImportError = true   // OK advances the follow-up chain
                }
            }
        }
    }

    /// One file picked and it failed → the plain reason, exactly the
    /// pre-batch alert. Several files picked → an intro line plus one
    /// bulleted "filename: reason" line per failed file.
    private static func batchErrorMessage(failures: [(filename: String, reason: String)], pickedCount: Int) -> String {
        if pickedCount == 1, let only = failures.first { return only.reason }
        let lines = failures.map {
            String(format: NSLocalizedString("import.error.batchLine", comment: ""), $0.filename, $0.reason)
        }
        return NSLocalizedString("import.error.batchIntro", comment: "") + "\n" + lines.joined(separator: "\n")
    }

    /// Presents the next queued batch follow-up, one at a time. The delay
    /// lets the previous alert finish dismissing first — presenting a new
    /// alert while another is mid-dismissal gets silently dropped.
    private func advanceBatchFollowUps() {
        if !zipSelectionQueue.isEmpty {
            let request = zipSelectionQueue.removeFirst()
            presentedZipRequest = request
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { activeZipSelection = request }
        } else if pendingSaveRedirectAfterBatch {
            pendingSaveRedirectAfterBatch = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showSaveRedirect = true }
        } else if !pendingSkinImports.isEmpty {
            let url = pendingSkinImports.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                SkinSharing.present(SkinSharing.importSkin(from: url)) { advanceBatchFollowUps() }
            }
        } else if !duplicateNotice.isEmpty {
            // Last in the chain: it is the quietest thing that can be said, and
            // anything else queued is more urgent than it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showDuplicateNotice = true }
        }
    }

    /// One game, its name; several, a list. Never a count, because "2 games were
    /// already imported" makes the player go and work out which two.
    private static func duplicateMessage(_ names: [String]) -> String {
        // The single-game sentence already exists and is already translated: it
        // is what the Files "open in Retro Pal" path says for the same thing.
        if names.count == 1 {
            return NSLocalizedString("import.error.alreadyImported", comment: "")
        }
        return NSLocalizedString("import.duplicate.bodySeveral", comment: "")
            + "\n" + names.map { "• " + $0 }.joined(separator: "\n")
    }

    /// Shared launch closure used by both the library row's onPlay (via
    /// `LibraryRow.onPlay`) and the programmatic-navigated `GameDetailsView`
    /// from the Files-URL duplicate flow. Re-detects systemType from the ROM
    /// header so a misclassified legacy import gets corrected before launch.
    private func playGame(_ game: GameEntity, url: URL, slot: Int?) {
        guard !presenting else { return }
        if let detected = GBAROMParser.detectSystemType(url: url),
           detected.rawValue != game.systemType {
            game.systemType = detected.rawValue
        }
        game.lastPlayedAt = Date()
        try? viewContext.save()
        currentlyPlayingGame = game
        // Hold widget publishing for the whole session: it must not spend I/O
        // inside the emulator's blocking auto-save window on backgrounding.
        WidgetSnapshotWriter.isGameLoaded = true
        let systemType = game.systemType ?? "gba"
        launchRequest = LaunchRequest(
            url: url, loadSlot: slot,
            systemType: systemType,
            gameTitle: game.title,
            expectedSize: game.romSize,
            session: EmulatorSession(bridge: Self.makeBridge(systemType: systemType))
        )
    }

    /// Entry point for a URL delivered via the Files / share-sheet / AirDrop
    /// "Open in Retro Pal" flow. If a game is currently running, we queue the
    /// URL and dismiss the cover; coverDidDismiss picks it up once the
    /// dismissal animation finishes. The auto-save that already ran when the
    /// user backgrounded to Files preserves their state.
    private func handleOpenedURL(_ url: URL) {
        if launchRequest != nil {
            queuedURL = url
            launchRequest = nil
        } else {
            processOpenedURL(url)
        }
    }

    /// Entry point for a home-screen widget tap. Mirrors `handleOpenedURL`:
    /// if a game is already running we dismiss it first and launch from
    /// coverDidDismiss, so the running game takes its normal quit path
    /// (auto-save included) instead of being swapped out underneath itself.
    private func handlePlayRequest(_ request: WidgetSharing.PlayRequest) {
        if launchRequest != nil {
            queuedPlayRequest = request
            launchRequest = nil
        } else {
            processPlayRequest(request)
        }
    }

    /// Resolves the widget's ROM filename back to a library game and launches
    /// it through the same path the Game Details slot cards use. A game that
    /// has since been deleted resolves to nothing: the app simply opens on the
    /// library, which is the honest outcome and matches the emulator's own
    /// fail-soft behavior for missing files.
    private func processPlayRequest(_ request: WidgetSharing.PlayRequest) {
        guard let game = games.first(where: { $0.romFilePath == request.romFilePath }) else { return }
        let url = romsDir.appendingPathComponent(request.romFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        playGame(game, url: url, slot: request.slot)
    }

    /// fullScreenCover onDismiss callback. Fires after the cover's dismissal
    /// animation completes — exactly the moment it's safe to present another
    /// cover or kick off the queued URL import.
    private func coverDidDismiss() {
        if let request = queuedPlayRequest {
            queuedPlayRequest = nil
            // Still playing, just a different game: publishing stays held.
            processPlayRequest(request)
            return
        }
        // The session is over, so publishing is safe again — and this is
        // exactly when what the widget shows has just changed (lastPlayedAt,
        // the auto-save, the screenshot used as cover).
        WidgetSnapshotWriter.isGameLoaded = false
        WidgetSnapshotWriter.refresh()
        if let url = queuedURL {
            queuedURL = nil
            processOpenedURL(url)
        }
    }

    /// Runs the hash-first import via ROMImporter.findOrImport. A duplicate
    /// (already in the library) triggers programmatic navigation to its
    /// GameDetailsView; a fresh import surfaces via @FetchRequest.
    private func processOpenedURL(_ url: URL) {
        isImporting = true
        let bgContext = PersistenceController.shared.container.newBackgroundContext()
        DispatchQueue.global(qos: .userInitiated).async {
            let importer = ROMImporter(context: bgContext)
            do {
                let result = try importer.findOrImport(at: url, method: "url")
                DispatchQueue.main.async {
                    isImporting = false
                    switch result {
                    case .imported:
                        break  // @FetchRequest will surface the new row.
                    case .existed(let objectID):
                        if let game = try? viewContext.existingObject(with: objectID) as? GameEntity {
                            navigateToGame = game
                            showNavigateDestination = true
                        }
                    }
                }
            } catch let error as ROMImportError {
                // A zip with several games: same selection sheet as the
                // picker flow (not an error, no signal).
                if case .zipNeedsSelection(let tempZipURL, let entryNames) = error {
                    DispatchQueue.main.async {
                        isImporting = false
                        zipSelectionQueue.append(ZipSelectionRequest(tempZipURL: tempZipURL, entryNames: entryNames))
                        advanceBatchFollowUps()
                    }
                    return
                }
                Analytics.signal("rom_import", ["result": "error", "errorType": error.analyticsID, "method": "url"])
                DispatchQueue.main.async {
                    isImporting = false
                    importError = error.errorDescription
                    showImportError = true
                }
            } catch {
                Analytics.signal("rom_import", ["result": "error", "errorType": "unknown", "method": "url"])
                DispatchQueue.main.async {
                    isImporting = false
                    importError = error.localizedDescription
                    showImportError = true
                }
            }
        }
    }

    private func deleteGame(_ game: GameEntity) {
        guard !presenting else { return }
        if let filename = game.romFilePath {
            let url = romsDir.appendingPathComponent(filename)
            // A disc game is a FOLDER, so deleting only the file the core is
            // pointed at would leave most of a gigabyte of orphaned tracks
            // behind, invisible in the library and impossible to reach from
            // inside the app. Cartridges have no folder and take the same line
            // they always did.
            if let folder = DiscStorage.gameFolder(forROMAt: url) {
                try? FileManager.default.removeItem(at: folder)
            } else {
                try? FileManager.default.removeItem(at: url)
            }

            // Delete the local save-states folder and the separate slot-0
            // auto-save tree (otherwise re-importing the same game would
            // resurface a stale resume). Both are keyed on the ROM BASENAME
            // (extension dropped) — the same derivation the loader and the
            // save importer use, whatever the console. iCloud copies are
            // deliberately left in place (sync never deletes; a re-import
            // gets its progress back).
            let canonicalRom = BatterySaveImporter.romBasename(forStoredFilename: filename)
            if !canonicalRom.isEmpty {
                try? FileManager.default.removeItem(
                    at: iCloudSaveSync.localSaveStatesRoot()
                        .appendingPathComponent(canonicalRom, isDirectory: true))
                try? FileManager.default.removeItem(at: SaveStateManager.localAutoSaveDir(romName: canonicalRom))
            }
        }
        viewContext.delete(game)
        try? viewContext.save()
    }

    /// Swipe-to-delete handler. Offsets are relative to the section's own block,
    /// so resolve them against that block, not the raw fetch list — otherwise a
    /// non-default sort (or an active search, or a console block) would map the
    /// swiped row to the wrong game.
    private func deleteGames(in group: [GameEntity], at offsets: IndexSet) {
        guard !presenting else { return }
        for index in offsets {
            deleteGame(group[index])
        }
    }
}

// MARK: - Library Row

/// A single library row, wrapping the game in @ObservedObject so any mutation
/// (rename, replay timestamp, etc.) re-renders the row immediately — the
/// surrounding @FetchRequest only fires on collection changes, not on field
/// edits to existing entities.
/// The library "retro story" panel with a static 3D tilt (the shareable card
/// keeps the continuous sway). Library palette (no purple, no logo/footer — just
/// the stats face), sized to its content. Tapping it still opens the share sheet
/// (the behavior lives in the Section, unchanged).
private struct LibraryStatsCard: View {
    let stats: LibraryStats

    var body: some View {
        // Flat, straight-on panel (the 3D tilt was removed 2026-07-06; any
        // motion stays on the shareable card).
        RetroStoryCardView(stats: stats)   // no branding: stats only, library colors
            .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
    }
}

/// Placeholder row shown at the top of the library while a ROM imports: the
/// real row's shape (cover + title + last-played + play-time) with shimmering
/// blocks instead of values, so the wait reads as content about to appear.
private struct LibrarySkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBox(cornerRadius: 8)
                .frame(width: 60, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBox(cornerRadius: 4).frame(width: 130, height: 15)
                SkeletonBox(cornerRadius: 4).frame(width: 90, height: 11)
                SkeletonBox(cornerRadius: 4).frame(width: 60, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityLabel(NSLocalizedString("library.importing", comment: "Importing ROM..."))
    }
}

private struct LibraryRow: View {
    /// Settings ▸ Debug ▸ Presentation mode: a demo game's row is not a
    /// link and draws its bundled cover (see `LibraryPresentation`).
    @AppStorage(LibraryPresentation.key) private var presentationFlag = false
    private var presenting: Bool { LibraryPresentation.isOn(presentationFlag) }
    @ObservedObject var game: GameEntity
    let onPlay: (URL, Int?) -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    /// Push depth of Game Details, owned by LibraryView; bumped while this row's
    /// detail view is on screen so the library screenshot prompt won't fire there.
    @Binding var detailViewCount: Int
    /// Bumped on `.saveStatesDidChange` so the cover re-reads the freshly
    /// written auto-save preview. lastPlayedAt alone refreshes the cover too
    /// early — it is re-stamped at dismiss, before the async write lands.
    @State private var saveTick = 0
    /// True inside the upright look (the List's rows sit on glass there):
    /// the console tag is the console's drawing rather than the lettered pill.
    @Environment(\.landscapeGlassRows) private var inLook

    /// Local cover file by priority: the user-picked custom cover beats the
    /// adopted RA image (which BoxArtManager only grants over a heuristic
    /// match or a no-match — never over a byte-exact CRC match), which
    /// beats the downloaded one; anything else falls through to the
    /// screenshot. Every branch is a file on disk: no network at display
    /// time, so the cover is stable across launches and offline.
    private var coverFileURL: URL? {
        BoxArtManager.shared.coverFileURL(forROMHash: game.romHash, coverType: game.coverType)
    }

    var body: some View {
        Group {
            if presenting {
                // A demo game has no page: the row is its label alone.
                rowLabel
            } else {
                NavigationLink {
                    GameDetailsView(game: game, onPlay: onPlay, onDelete: onDelete)
                        .onAppear { detailViewCount += 1 }
                        .onDisappear { detailViewCount -= 1 }
                } label: {
                    rowLabel
                }
            }
        }
        .contextMenu {
            Button {
                onRename()
            } label: {
                Label(NSLocalizedString("details.rename", comment: ""), systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(NSLocalizedString("details.delete", comment: ""), systemImage: "trash")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveStatesDidChange)) { _ in
            // The auto-save preview lands on disk after the cover already
            // refreshed on lastPlayedAt (re-stamped at dismiss, before the async
            // write completes). Bump the tick so the cover re-reads once it lands.
            saveTick &+= 1
        }
    }

    private var rowLabel: some View {
            HStack(spacing: 12) {
                // .id keyed on lastPlayedAt + saveTick forces a fresh
                // GameCoverView (a fresh disk read of the auto-save preview)
                // when the game is played AND when the auto-save write actually
                // lands (.saveStatesDidChange bumps saveTick) — the write
                // completes after lastPlayedAt is re-stamped at dismiss.
                // coverType joins the key so the row re-reads the cover the
                // moment BoxArtManager persists a downloaded one.
                // fixedWidth: every cover spans the width a GBA screenshot
                // occupies (GB/GBC/NDS and box art no longer shrink inside
                // a 3:2 frame); the view derives its own height from the
                // image's ratio, square-capped so rows don't stretch.
                if let demo = LibraryPresentation.cover(forROMPath: game.romFilePath) {
                    Image(uiImage: demo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    GameCoverView(romFilePath: game.romFilePath,
                                  boxArtURL: coverFileURL,
                                  fixedWidth: 60)
                        .id("\((game.lastPlayedAt ?? .distantPast).timeIntervalSinceReferenceDate)#\(saveTick)#\(game.coverType ?? "")")
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(game.title ?? NSLocalizedString("library.untitled", comment: ""))
                            .font(.headline)
                            // Explicit primary, so the label never takes the
                            // link tint.
                            .foregroundColor(.primary)
                        if let sys = game.systemType {
                            ConsoleTagBadge(systemType: sys, drawing: inLook)
                        }
                    }
                    if let lastPlayed = game.lastPlayedAt {
                        Text(lastPlayed, formatter: relativeDateFormatter)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    let playTime = gamePlayTime
                    if playTime >= 60 {
                        Text(formatPlayTime(playTime))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                // Fill the row so its whole width is tappable.
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }

    private var gamePlayTime: TimeInterval {
        guard let path = game.romFilePath else { return 0 }
        return PromptTracker.shared.gamePlayTime(
            romName: BatterySaveImporter.romBasename(forStoredFilename: path))
    }

    private func formatPlayTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return String(format: NSLocalizedString("library.playTime", comment: ""), "\(hours)", "\(minutes)")
        } else {
            return String(format: NSLocalizedString("library.playTime.minutes", comment: ""), "\(minutes)")
        }
    }

    private var relativeDateFormatter: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }
}

/// Document picker for ROM files and battery saves.
struct DocumentPickerView: UIViewControllerRepresentable {
    /// ROMs + battery saves + zip. The library `+` uses this full set:
    /// `.sav`/`.srm` stay selectable so they aren't greyed out, but the
    /// library routes a picked save to an explanatory redirect rather than
    /// importing it (the actual import lives on the per-game screen).
    static let romAndSaveTypes: [UTType] = romTypesWithoutZip + [
        UTType(filenameExtension: "sav") ?? .data,
        UTType(filenameExtension: "srm") ?? .data,
        UTType(filenameExtension: "retropalskin") ?? .data,   // silently accepted; routed to skin import
        .zip,
    ]

    /// One list, built from the parser's own extensions, so a console can never
    /// be importable in code while greyed out in the picker.
    ///
    /// **Never falls back to `.data`.** That fallback is the difference between
    /// "this one format is not selectable" and "the picker offers every file on
    /// the device", and the second is what a single unrecognised extension used
    /// to buy. It mattered little while every extension here was one we declare
    /// in our own Info.plist; the PlayStation adds several we deliberately do
    /// NOT declare (`.bin`, `.iso`, `.img` are far too generic to claim), so the
    /// fallback went from unreachable to likely.
    private static let romTypesWithoutZip: [UTType] =
        ROMSystemType.allFileExtensions.compactMap(romContentType)

    /// The content type for a ROM extension: the registered one when the system
    /// knows it, and otherwise a DYNAMIC type built from the extension itself.
    ///
    /// The second half is the part that matters and is not a guess:
    /// `UTType(tag:tagClass:conformingTo:)` is the API that mints a dynamic
    /// identifier for an unregistered tag, so an extension nothing has claimed
    /// still filters by that extension instead of disappearing or widening the
    /// picker. Returning nil is the last resort and costs only that one format.
    private static func romContentType(_ ext: String) -> UTType? {
        UTType(filenameExtension: ext)
            ?? UTType(tag: ext, tagClass: .filenameExtension, conformingTo: .data)
    }

    /// Battery saves only, used by the per-game "Import a save" button where
    /// the target game is already known.
    static let saveTypes: [UTType] = [
        UTType(filenameExtension: "sav") ?? .data,
        UTType(filenameExtension: "srm") ?? .data,
    ]
    /// ROM files only (no saves), used by the per-game "Replace game file"
    /// recovery on the Game Details screen.
    static let romTypes: [UTType] = romTypesWithoutZip + [.zip]

    var contentTypes: [UTType] = DocumentPickerView.romAndSaveTypes
    /// Multi-select is only for the library `+` (importing a collection in one
    /// trip). The per-game pickers (save import, replace-ROM recovery) stay
    /// single-select: their target is one specific game.
    var allowsMultipleSelection = false
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            onPick(urls)
        }
    }
}
