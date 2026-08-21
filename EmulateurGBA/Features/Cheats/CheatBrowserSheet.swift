//
//  CheatBrowserSheet.swift
//  EmulateurGBA
//
//  The community cheat database for the game being played. Tap a code and it
//  lands in the field, named, ready to add.
//
//  The game is identified from its own ROM filename and the codes are simply
//  shown: someone already playing Pokemon should not be asked to search for
//  Pokemon. Searching exists only as the fallback for a file named loosely
//  enough that we cannot recognise it, which measurement puts at a minority
//  of cases.
//
//  Master codes are pinned to the top with a warning, because most GBA and DS
//  games need one active before any other code does anything, and that single
//  fact is the difference between the feature working and appearing broken.
//

import SwiftUI

struct CheatBrowserSheet: View {
    let romName: String
    let system: String
    /// The cartridge game code, when the header has one (GBA and DS only).
    /// Used solely to reach another region's codes when this game's own title
    /// has no cheat file, which is the normal case outside English.
    let gameCode: String?
    /// Hands the tapped code and its name back to the manager's fields.
    let onPick: (_ code: String, _ name: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = CheatLibrary.shared

    @State private var entries: [CheatLibrary.Entry] = []
    @State private var isLoading = true
    @State private var didFail = false
    @State private var wasOffline = false
    /// Only ever shown when the game could not be identified, or when the user
    /// asks for it from the toolbar.
    @State private var isSearching = false
    @State private var query = ""
    @State private var searchResults: [String] = []
    /// Set when the codes on screen belong to another region's release of this
    /// same cartridge. Holds that release's title, which the banner names.
    @State private var regionalFallback: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if didFail {
                    failureState
                } else if isSearching {
                    searchList
                } else {
                    codeList
                }
            }
            .navigationTitle(NSLocalizedString("cheats.browse.title", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // "Not this game?" — the escape hatch, not the front door.
                    if !isLoading && !didFail && !entries.isEmpty {
                        Button {
                            beginSearch()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "")) { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(NSLocalizedString("common.done", comment: "")) { searchFocused = false }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - States

    private var failureState: some View {
        VStack(spacing: 12) {
            Image(systemName: wasOffline ? "wifi.slash" : "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(wasOffline
                 ? NSLocalizedString("cheats.browse.offline", comment: "")
                 : NSLocalizedString("cheats.browse.failed", comment: ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(NSLocalizedString("ra.retry", comment: "")) {
                Task { await load() }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The normal case: this game's codes, nothing else to do.
    @ViewBuilder
    private var codeList: some View {
        List {
            // Never let borrowed codes pass as this release's own. Sits above
            // the codes, not in a footer, because it changes how the list
            // should be read rather than annotating it.
            if let regionalFallback {
                Section {
                    Label {
                        Text(String(
                            format: NSLocalizedString("cheats.browse.otherRegion", comment: ""),
                            regionalFallback))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(entries) { entry in
                Section {
                    ForEach(sorted(entry.cheats)) { cheat in
                        row(cheat)
                    }
                } header: {
                    Text(entry.source)
                } footer: {
                    if entry.cheats.contains(where: { Self.isMasterCode($0.description) }) {
                        Text(NSLocalizedString("cheats.browse.masterHint", comment: ""))
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text(NSLocalizedString("cheats.browse.credit", comment: ""))
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func row(_ cheat: CheatLibrary.Cheat) -> some View {
        let isMaster = Self.isMasterCode(cheat.description)
        return Button {
            onPick(cheat.code, cheat.description)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if isMaster {
                    Image(systemName: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(cheat.description.isEmpty
                         ? NSLocalizedString("cheats.browse.unnamed", comment: "")
                         : cheat.description)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(cheat.code.replacingOccurrences(of: "\n", with: " · "))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Fallback only: the filename did not identify the game, or the user
    /// asked. Seeded with the ROM's own name and focused, ready to edit.
    @ViewBuilder
    private var searchList: some View {
        List {
            Section {
                TextField(NSLocalizedString("cheats.browse.searchPlaceholder", comment: ""),
                          text: $query)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { searchFocused = false }
                    .onChange(of: query) { newValue in
                        searchResults = newValue.count >= 2
                            ? CheatIndex.shared.search(newValue, system: system)
                            : []
                    }
            } header: {
                Text(NSLocalizedString("cheats.browse.notFound", comment: ""))
            }

            if !searchResults.isEmpty {
                Section(NSLocalizedString("cheats.browse.results", comment: "")) {
                    ForEach(searchResults, id: \.self) { stem in
                        Button {
                            searchFocused = false
                            Task { await loadSpecific(stem) }
                        } label: {
                            Text(stem).font(.subheadline).foregroundColor(.primary)
                        }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Helpers

    /// Master and enable codes first: without them the rest of the list does
    /// nothing on most GBA and DS games, so burying them is how the whole
    /// feature comes to look broken.
    private func sorted(_ cheats: [CheatLibrary.Cheat]) -> [CheatLibrary.Cheat] {
        let masters = cheats.filter { Self.isMasterCode($0.description) }
        guard !masters.isEmpty else { return cheats }
        return masters + cheats.filter { !Self.isMasterCode($0.description) }
    }

    /// libretro's own wording for the codes a game needs switched on first.
    static func isMasterCode(_ description: String) -> Bool {
        let d = description.lowercased()
        return d.contains("master code") || d.contains("enable code")
            || d.contains("must be on") || d.contains("anti dma")
    }

    private func beginSearch() {
        isSearching = true
        query = romName
        searchResults = CheatIndex.shared.search(romName, system: system)
        searchFocused = true
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        didFail = false
        regionalFallback = nil
        do {
            entries = try await library.entries(forTitle: romName, system: system)
            if entries.isEmpty { try await loadRegionalFallback() }
            // Could not recognise the file, and no other region has it either:
            // drop into search rather than a dead end, seeded with its own name.
            if entries.isEmpty { beginSearch() } else { isSearching = false }
        } catch {
            wasOffline = (error as? CheatLibrary.Failure) == .offline || !library.isOnline
            didFail = true
        }
        isLoading = false
    }

    /// The same cartridge, released elsewhere under another name.
    ///
    /// libretro keys its cheat files by title, and localized releases carry
    /// localized titles, so the French Pokemon Rouge Feu had no codes at all
    /// while the identical USA and German releases both did. That is not a
    /// missing-data problem, it is a naming one, and the cartridge game code
    /// resolves it exactly: `BPRF` and `BPRE` are the same game.
    ///
    /// Serving them is defensible and was verified on real codes rather than
    /// assumed: the species half of these encrypted codes is region
    /// independent and only the prefix is regional, so a foreign code often
    /// works and, when it does not, it fails the way any wrong code fails.
    /// What is NOT acceptable is doing it silently, so the banner names the
    /// release the codes came from and the player decides.
    ///
    /// Deliberately takes the FIRST region that has codes rather than merging
    /// every region's file. Merging would stack several games' worth of codes
    /// under headers the player cannot tell apart, and mixing codes from two
    /// regional dumps is exactly the way to produce the silent corruption this
    /// whole area is trying to eliminate.
    private func loadRegionalFallback() async throws {
        guard let gameCode,
              let romSystem = ROMSystemType(rawValue: system)
        else { return }
        let siblings = BoxArtIndex.shared.regionalSiblingNames(ofSerial: gameCode, system: romSystem)
        for title in siblings {
            // A title with no cheat file is ordinary and returns empty, so it
            // is simply the next candidate's turn. Being OFFLINE is not
            // ordinary and must not be swallowed: silently walking six titles
            // that all fail for the same reason would end in the search screen
            // when the honest answer is "no connection".
            let found = try await library.entries(forTitle: title, system: system)
            if !found.isEmpty {
                entries = found
                regionalFallback = title
                return
            }
        }
    }

    private func loadSpecific(_ stem: String) async {
        isLoading = true
        didFail = false
        // The user has chosen a game by hand, so any earlier borrowed-region
        // banner is about a different lookup and would now be describing codes
        // that are not on screen.
        regionalFallback = nil
        do {
            entries = try await library.entries(forTitle: stem, system: system)
            if !entries.isEmpty {
                isSearching = false
                query = ""
                searchResults = []
            }
        } catch {
            wasOffline = (error as? CheatLibrary.Failure) == .offline || !library.isOnline
            didFail = true
        }
        isLoading = false
    }
}
