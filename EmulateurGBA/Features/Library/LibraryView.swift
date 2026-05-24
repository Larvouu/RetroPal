//
//  LibraryView.swift
//  EmulateurGBA
//

import SwiftUI
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

    @State private var showFilePicker = false
    @State private var launchRequest: LaunchRequest?
    @State private var importError: String?
    @State private var showImportError = false
    @State private var isImporting = false
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .lastPlayed
    @State private var renamingGame: GameEntity?
    @State private var renameDraft = ""
    /// True while the "saves are imported per-game" redirect popup is shown.
    /// Triggered when a `.sav`/`.srm` is picked from the library `+` — the
    /// actual import lives on the per-game screen.
    @State private var showSaveRedirect = false
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

        var displayName: String {
            switch self {
            case .lastPlayed: return NSLocalizedString("library.sort.lastPlayed", comment: "")
            case .alphabetical: return "A-Z"
            case .dateAdded: return NSLocalizedString("library.sort.dateAdded", comment: "")
            }
        }
    }

    private var filteredGames: [GameEntity] {
        let sorted: [GameEntity]
        switch sortOrder {
        case .lastPlayed:
            sorted = games.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .alphabetical:
            sorted = games.sorted { ($0.title ?? "") < ($1.title ?? "") }
        case .dateAdded:
            sorted = games.sorted { ($0.importedAt ?? .distantPast) > ($1.importedAt ?? .distantPast) }
        }
        if searchText.isEmpty { return sorted }
        return sorted.filter { ($0.title ?? "").localizedCaseInsensitiveContains(searchText) }
    }

    private var romsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ROMs", isDirectory: true)
    }

    var body: some View {
        // Split into stages via intermediate properties. Each stage is
        // typechecked independently — keeps total chain depth under the
        // SwiftUI type-checker's budget.
        bodyWithSaveImport
            .navigationDestination(isPresented: $showNavigateDestination) {
                navigationDestinationView
            }
            .onChange(of: pendingOpenURL) { url in
                guard let url = url else { return }
                pendingOpenURL = nil
                handleOpenedURL(url)
            }
            .overlay { importingOverlay }
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
                Button(NSLocalizedString("common.ok", comment: "")) { showSaveRedirect = false }
            } message: {
                Text(NSLocalizedString("saveImport.redirect.message", comment: ""))
            }
    }

    private var bodyCore: some View {
        Group {
            if showEmptyState {
                emptyState
            } else {
                gameList
            }
        }
        .navigationTitle(NSLocalizedString("library.title", comment: ""))
        .searchable(text: $searchText, prompt: NSLocalizedString("library.search", comment: ""))
        .toolbar { libraryToolbar }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView { url in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    dispatchPickedFile(url: url)
                }
            }
        }
        .fullScreenCover(item: $launchRequest, onDismiss: coverDidDismiss) { request in
            emulatorScreen(for: request)
        }
        .alert(NSLocalizedString("library.importError", comment: ""), isPresented: $showImportError) {
            Button(NSLocalizedString("common.ok", comment: "")) {}
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
            gameTitle: request.gameTitle
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
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text(NSLocalizedString("library.importing", comment: "Importing ROM..."))
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                .padding(30)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
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


    private var gameList: some View {
        List {
            ForEach(filteredGames, id: \.self) { game in
                LibraryRow(
                    game: game,
                    onPlay: { url, slot in playGame(game, url: url, slot: slot) },
                    onDelete: { deleteGame(game) },
                    onRename: {
                        renameDraft = game.title ?? ""
                        renamingGame = game
                    }
                )
            }
            .onDelete(perform: deleteGames)
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
    }

    // MARK: - Actions

    /// Routes a freshly-picked file by extension. `.sav`/`.srm` show the
    /// per-game redirect popup (battery saves are imported from a game's
    /// detail screen, where the target is unambiguous); everything else
    /// (`.gba`, `.gb`, `.gbc`, `.nds`, `.zip`) falls through to the ROM
    /// importer.
    private func dispatchPickedFile(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "sav" || ext == "srm" {
            showSaveRedirect = true
        } else {
            importROM(url: url)
        }
    }

    private func importROM(url: URL) {
        isImporting = true
        let context = PersistenceController.shared.container.newBackgroundContext()
        DispatchQueue.global(qos: .userInitiated).async {
            let importer = ROMImporter(context: context)
            do {
                let _ = try importer.importROM(from: url)
                DispatchQueue.main.async { isImporting = false }
            } catch let error as ROMImportError {
                DispatchQueue.main.async {
                    isImporting = false
                    if case .alreadyImported = error { return }
                    importError = error.errorDescription
                    showImportError = true
                }
            } catch {
                DispatchQueue.main.async {
                    isImporting = false
                    importError = error.localizedDescription
                    showImportError = true
                }
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
            gameTitle: game.title
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
                let result = try importer.findOrImport(at: url)
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
                DispatchQueue.main.async {
                    isImporting = false
                    importError = error.errorDescription
                    showImportError = true
                }
            } catch {
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
        viewContext.delete(game)
        try? viewContext.save()
    }

    private func deleteGames(at offsets: IndexSet) {
        for index in offsets {
            deleteGame(games[index])
        }
    }
}

// MARK: - Library Row

/// A single library row, wrapping the game in @ObservedObject so any mutation
/// (rename, replay timestamp, etc.) re-renders the row immediately — the
/// surrounding @FetchRequest only fires on collection changes, not on field
/// edits to existing entities.
private struct LibraryRow: View {
    @ObservedObject var game: GameEntity
    let onPlay: (URL, Int?) -> Void
    let onDelete: () -> Void
    let onRename: () -> Void

    var body: some View {
        NavigationLink {
            GameDetailsView(game: game, onPlay: onPlay, onDelete: onDelete)
        } label: {
            HStack(spacing: 12) {
                // .id keyed on lastPlayedAt forces a fresh GameCoverView (and
                // a fresh disk read of the auto-save preview) whenever the
                // game has just been played — otherwise SwiftUI sees the same
                // romFilePath input and skips re-evaluation.
                GameCoverView(romFilePath: game.romFilePath)
                    .id(game.lastPlayedAt ?? .distantPast)
                    .frame(width: 60, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(game.title ?? "Unknown")
                            .font(.headline)
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
            }
            .padding(.vertical, 4)
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
    }

    private func systemBadgeColor(_ systemType: String) -> Color {
        switch systemType {
        case "nds": return .blue
        case "gbc": return .purple
        case "gb": return .gray
        default: return .green
        }
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
        .zip,
    ]
    /// Battery saves only, used by the per-game "Import a save" button where
    /// the target game is already known.
    static let saveTypes: [UTType] = [
        UTType(filenameExtension: "sav") ?? .data,
        UTType(filenameExtension: "srm") ?? .data,
    ]

    var contentTypes: [UTType] = DocumentPickerView.romAndSaveTypes
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
