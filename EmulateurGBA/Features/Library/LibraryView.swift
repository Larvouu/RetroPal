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
}

struct LibraryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        entity: GameEntity.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \GameEntity.lastPlayedAt, ascending: false),
                          NSSortDescriptor(keyPath: \GameEntity.importedAt, ascending: false)]
    ) private var games: FetchedResults<GameEntity>

    /// URL inbox for the Files → "Open in Retro Pal" flow. Set by
    /// AppShellView.onOpenURL; consumed (set back to nil) here once the
    /// import is dispatched. Binding-driven so cold-launch URLs still
    /// arrive correctly — the .onChange below fires on first render.
    @Binding var pendingOpenURL: URL?
    /// Whether the Library is the selected tab (passed by AppShellView). Gates
    /// the screenshot-to-share detection so it never fires from the Settings tab.
    var isActiveTab: Bool = true

    /// Landscape on iPhone is the only place the games render as a 2-column grid
    /// (there's horizontal room); portrait keeps the single-column List.
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var isLandscape: Bool { vSizeClass == .compact }

    /// Two equal, flexible columns for the landscape game grid.
    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    @State private var showFilePicker = false
    @State private var launchRequest: LaunchRequest?
    @State private var importError: String?
    @State private var showImportError = false
    @State private var isImporting = false
    @State private var searchText = ""
    /// Persisted across launches: the chosen sort survives an app kill (the
    /// user gets the same library arrangement next open). RawRepresentable<String>
    /// enums are AppStorage-backed natively on iOS 16+.
    @AppStorage("library.sortOrder") private var sortOrder: SortOrder = .lastPlayed
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
    private static let consoleFallbackOrder = ["gba", "gb", "gbc", "nds"]

    private var filteredGames: [GameEntity] {
        let sorted: [GameEntity]
        switch sortOrder {
        case .lastPlayed:
            sorted = games.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .alphabetical:
            sorted = games.sorted { ($0.title ?? "") < ($1.title ?? "") }
        case .dateAdded:
            sorted = games.sorted { ($0.importedAt ?? .distantPast) > ($1.importedAt ?? .distantPast) }
        case .byConsole:
            let rank = consoleDisplayRank
            sorted = games.sorted { a, b in
                let ra = rank[a.systemType ?? "gba"] ?? Int.max
                let rb = rank[b.systemType ?? "gba"] ?? Int.max
                if ra != rb { return ra < rb }
                // Within one console, A-Z by title.
                return (a.title ?? "") < (b.title ?? "")
            }
        }
        if searchText.isEmpty { return sorted }
        return sorted.filter { ($0.title ?? "").localizedCaseInsensitiveContains(searchText) }
    }

    /// Per-console ordering for the "Par console" sort: consoles the user has
    /// played the MOST appear first (most total play time across that console's
    /// games), so the heaviest-used system tops the library. Consoles with equal
    /// (or zero) play time fall back to a stable canonical order. Returns a
    /// rank index per systemType raw value (0 = shown first).
    private var consoleDisplayRank: [String: Int] {
        var secondsPerConsole: [String: TimeInterval] = [:]
        for game in games {
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
        guard isActiveTab,
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
            if showEmptyState {
                // Onboarding: no large title, no search bar — the whole
                // pitch (headline, consoles, steps, CTA) fits without
                // scrolling. The toolbar stays reachable.
                emptyState
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                gameList
                    .navigationTitle(NSLocalizedString("library.title", comment: ""))
                    .searchable(text: $searchText, prompt: NSLocalizedString("library.search", comment: ""))
            }
        }
        .toolbar { libraryToolbar }
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
    }

    /// Destination view for the programmatic Files → "Open in Retro Pal"
    /// flow when the opened ROM already exists in the library.
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
            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        HStack {
                            Text(order.displayName)
                            if sortOrder == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showFilePicker = true
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    private func emulatorScreen(for request: LaunchRequest) -> some View {
        let bridge: any EmulatorBridge = request.systemType == "nds" ? MelonDSBridge() : MGBABridge()
        return EmulatorScreen(
            romURL: request.url,
            session: EmulatorSession(bridge: bridge),
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
        return games.isEmpty || debugForceEmptyState
        #else
        return games.isEmpty
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

                Text(NSLocalizedString("library.empty.subtitle", comment: ""))
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
            stepRow(num: 1, text: NSLocalizedString("library.empty.step1", comment: ""))
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

            stepLabel(text: text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Step text with optional %@ placeholder replaced inline by the same SF
    /// Symbol that backs the toolbar's import button. Lets the user visually
    /// connect step 1 ("Tap %@ to add a game file") to the actual + button in
    /// the navigation bar, instead of staring at a plain "+" character.
    @ViewBuilder
    private func stepLabel(text: String) -> some View {
        if text.contains("%@") {
            let parts = text.components(separatedBy: "%@")
            let before = parts.first ?? ""
            let after = parts.dropFirst().joined(separator: "%@")
            Text(before)
                + Text(Image(systemName: "plus"))
                    .foregroundColor(.accentColor)
                    .fontWeight(.semibold)
                + Text(after)
        } else {
            Text(text)
        }
    }

    /// Import is a FREE action, not a Pro feature. Purple-dominant so it
    /// never pattern-matches to the app's gold "Pro" signal; a 1pt gold
    /// hairline at 40% opacity warms the edge just enough to keep the
    /// brand identity.
    private var importCTA: some View {
        Button {
            showFilePicker = true
        } label: {
            Label(NSLocalizedString("library.empty.button", comment: ""), systemImage: "plus")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.45, green: 0.2, blue: 0.85),
                            Color(red: 0.55, green: 0.3, blue: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            Color(red: 1.0, green: 0.84, blue: 0.35).opacity(0.4),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color(red: 0.45, green: 0.2, blue: 0.85).opacity(0.3), radius: 10)
        }
    }


    /// The games surface. Portrait keeps the single-column List; landscape (where
    /// there's horizontal room) switches to a 2-column grid of cards. The shared
    /// data hooks + the story-share sheet + the rename alert live on the wrapper
    /// so both layouts get them without duplication.
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
            landscapeGameGrid
        } else {
            portraitGameList
        }
    }

    /// Portrait: the original single-column List (swipe-to-delete, grouped style).
    private var portraitGameList: some View {
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
                                renameDraft = game.title ?? ""
                                renamingGame = game
                            },
                            detailViewCount: $detailViewCount
                        )
                    }
                    .onDelete { offsets in deleteGames(in: group, at: offsets) }
                }
            }

            // "Retro story" stats card, anchored at the bottom after the games
            // (no positioning tricks — for a library worth showing stats, the
            // games scroll, so it's naturally a discovery). Hidden while
            // searching; appears once at least two games are played.
            if searchText.isEmpty, let stats, stats.hasData {
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
            if searchText.isEmpty, ra.isEnabled, raIndex.hasEligibleGame {
                Section {
                    raLibraryCard
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))
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

    /// Landscape: a 2-column grid of game cards (reusing LibraryRow in its card
    /// variant). Delete/rename move to the per-card long-press menu (no swipe in
    /// a grid). The stats card spans full width below the grid, as in portrait.
    private var landscapeGameGrid: some View {
        ScrollView {
            VStack(spacing: 0) {
                // One grid per console block under the "Par console" sort; the
                // extra top padding on blocks after the first IS the small gap
                // between consoles (no titles). Every other sort is one block, so
                // the layout is unchanged.
                ForEach(Array(gameGroups.enumerated()), id: \.offset) { groupIndex, group in
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        if isImporting && groupIndex == 0 {
                            LibrarySkeletonRow()
                                .padding(.vertical, 10)
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(.secondarySystemGroupedBackground))
                                )
                        }
                        ForEach(group, id: \.self) { game in
                            LibraryRow(
                                game: game,
                                onPlay: { url, slot in playGame(game, url: url, slot: slot) },
                                onDelete: { deleteGame(game) },
                                onRename: {
                                    renameDraft = game.title ?? ""
                                    renamingGame = game
                                },
                                detailViewCount: $detailViewCount,
                                cardStyle: true
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, groupIndex == 0 ? 12 : 24)
                }

                if searchText.isEmpty, let stats, stats.hasData {
                    LibraryStatsCard(stats: stats)
                        .contentShape(Rectangle())
                        .onTapGesture { Haptics.tap(); showStoryShare = true }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                }

                if searchText.isEmpty, ra.isEnabled, raIndex.hasEligibleGame {
                    raLibraryCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
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
            var selectionRequests: [ZipSelectionRequest] = []
            for url in urls {
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
                    if case .alreadyImported = error { continue }
                    failures.append((url.lastPathComponent, error.errorDescription ?? ""))
                } catch {
                    Analytics.signal("rom_import", ["result": "error", "errorType": "unknown", "method": "picker"])
                    failures.append((url.lastPathComponent, error.localizedDescription))
                }
            }
            DispatchQueue.main.async {
                isImporting = false
                zipSelectionQueue.append(contentsOf: selectionRequests)
                if failures.isEmpty {
                    advanceBatchFollowUps()
                } else {
                    importError = Self.batchErrorMessage(failures: failures, pickedCount: urls.count)
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
            let failures = importer.importZIPSelection(entryNames: names, fromTempZip: request.tempZipURL)
            for failure in failures {
                Analytics.signal("rom_import", ["result": "error", "errorType": failure.analyticsID, "method": "zip"])
            }
            DispatchQueue.main.async {
                isImporting = false
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
        }
    }

    /// Shared launch closure used by both the library row's onPlay (via
    /// `LibraryRow.onPlay`) and the programmatic-navigated `GameDetailsView`
    /// from the Files-URL duplicate flow. Re-detects systemType from the ROM
    /// header so a misclassified legacy import gets corrected before launch.
    private func playGame(_ game: GameEntity, url: URL, slot: Int?) {
        if let detected = GBAROMParser.detectSystemType(url: url),
           detected.rawValue != game.systemType {
            game.systemType = detected.rawValue
        }
        game.lastPlayedAt = Date()
        try? viewContext.save()
        currentlyPlayingGame = game
        launchRequest = LaunchRequest(
            url: url, loadSlot: slot,
            systemType: game.systemType ?? "gba",
            gameTitle: game.title,
            expectedSize: game.romSize
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

    /// fullScreenCover onDismiss callback. Fires after the cover's dismissal
    /// animation completes — exactly the moment it's safe to present another
    /// cover or kick off the queued URL import.
    private func coverDidDismiss() {
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
        if let filename = game.romFilePath {
            let url = romsDir.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        // Delete save states folder
        let romName = (game.romFilePath ?? "").replacingOccurrences(of: ".gba", with: "")
        if !romName.isEmpty {
            let savesDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("SaveStates", isDirectory: true)
                .appendingPathComponent(romName, isDirectory: true)
            try? FileManager.default.removeItem(at: savesDir)
        }
        // The slot-0 auto-save lives in a separate local tree now
        // (SaveStateManager.localAutoSaveDir), so remove it explicitly too —
        // otherwise re-importing the same game would resurface a stale resume.
        if let filename = game.romFilePath {
            let canonicalRom = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            if !canonicalRom.isEmpty {
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
    @ObservedObject var game: GameEntity
    let onPlay: (URL, Int?) -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    /// Push depth of Game Details, owned by LibraryView; bumped while this row's
    /// detail view is on screen so the library screenshot prompt won't fire there.
    @Binding var detailViewCount: Int
    /// When true (landscape grid), the row draws itself as a self-contained card
    /// (own background + padding, fills its cell). In the List (false) the List
    /// supplies the row background/insets, so we add neither.
    var cardStyle: Bool = false

    /// Bumped on `.saveStatesDidChange` so the cover re-reads the freshly
    /// written auto-save preview. lastPlayedAt alone refreshes the cover too
    /// early — it is re-stamped at dismiss, before the async write lands.
    @State private var saveTick = 0

    /// Local cover file by priority: the user-picked custom cover beats the
    /// adopted RA image (which BoxArtManager only grants over a heuristic
    /// match or a no-match — never over a byte-exact CRC match), which
    /// beats the downloaded one; anything else falls through to the
    /// screenshot. Every branch is a file on disk: no network at display
    /// time, so the cover is stable across launches and offline.
    private var coverFileURL: URL? {
        guard let romHash = game.romHash else { return nil }
        switch game.coverType {
        case BoxArtManager.coverStateCustom:
            return BoxArtManager.shared.customImageURL(forROMHash: romHash)
        case BoxArtManager.coverStateRA:
            return BoxArtManager.shared.raImageURL(forROMHash: romHash)
        case BoxArtManager.coverStateBoxArt, BoxArtManager.coverStateBoxArtHeuristic:
            return BoxArtManager.shared.imageURL(forROMHash: romHash)
        default:
            return nil
        }
    }

    var body: some View {
        NavigationLink {
            GameDetailsView(game: game, onPlay: onPlay, onDelete: onDelete)
                .onAppear { detailViewCount += 1 }
                .onDisappear { detailViewCount -= 1 }
        } label: {
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
                GameCoverView(romFilePath: game.romFilePath,
                              boxArtURL: coverFileURL,
                              fixedWidth: cardStyle ? 80 : 60)
                    .id("\((game.lastPlayedAt ?? .distantPast).timeIntervalSinceReferenceDate)#\(saveTick)#\(game.coverType ?? "")")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(game.title ?? "Unknown")
                            .font(.headline)
                            // Explicit primary: a NavigationLink outside a List
                            // (the landscape grid) otherwise tints its label blue.
                            .foregroundColor(.primary)
                        if let sys = game.systemType {
                            Text(sys.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(systemBadgeColor(sys))
                                .cornerRadius(4)
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
                // Fill the cell so the grid card's whole width is tappable
                // (harmless in the List, where the row is already full-width).
                Spacer(minLength: 0)
            }
            .padding(.vertical, cardStyle ? 10 : 4)
            .padding(.horizontal, cardStyle ? 12 : 0)
            // In the grid, stretch to the row's height so two paired cards (one
            // with more metadata than the other) stay equal height.
            .frame(maxHeight: cardStyle ? .infinity : nil)
            .background {
                if cardStyle {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                }
            }
            .contentShape(Rectangle())
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

    private func systemBadgeColor(_ systemType: String) -> Color {
        SystemColor.color(systemType)
    }

    private var gamePlayTime: TimeInterval {
        guard let path = game.romFilePath else { return 0 }
        let romName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return PromptTracker.shared.gamePlayTime(romName: romName)
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
    static let romAndSaveTypes: [UTType] = [
        UTType(filenameExtension: "gba") ?? .data,
        UTType(filenameExtension: "gb") ?? .data,
        UTType(filenameExtension: "gbc") ?? .data,
        UTType(filenameExtension: "nds") ?? .data,
        UTType(filenameExtension: "sav") ?? .data,
        UTType(filenameExtension: "srm") ?? .data,
        UTType(filenameExtension: "retropalskin") ?? .data,   // silently accepted; routed to skin import
        .zip,
    ]
    /// Battery saves only, used by the per-game "Import a save" button where
    /// the target game is already known.
    static let saveTypes: [UTType] = [
        UTType(filenameExtension: "sav") ?? .data,
        UTType(filenameExtension: "srm") ?? .data,
    ]
    /// ROM files only (no saves), used by the per-game "Replace game file"
    /// recovery on the Game Details screen.
    static let romTypes: [UTType] = [
        UTType(filenameExtension: "gba") ?? .data,
        UTType(filenameExtension: "gb") ?? .data,
        UTType(filenameExtension: "gbc") ?? .data,
        UTType(filenameExtension: "nds") ?? .data,
        .zip,
    ]

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
