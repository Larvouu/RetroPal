//
//  AppShellView.swift
//  EmulateurGBA
//

import SwiftUI

struct AppShellView: View {
    @State private var selectedTab: AppTab = .library

    /// URL pending import via the Files → "Open in Retro Pal" flow. Set
    /// from .onOpenURL and consumed by LibraryView, which clears it back
    /// to nil once handled. Survives cold launch because SwiftUI delivers
    /// the URL after the first render pass — the binding-then-onChange
    /// chain inside LibraryView fires on first appearance.
    @State private var pendingOpenURL: URL?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView(pendingOpenURL: $pendingOpenURL)
            }
            .tabItem {
                Label(NSLocalizedString("tab.library", comment: ""), systemImage: "books.vertical")
            }
            .tag(AppTab.library)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(NSLocalizedString("tab.settings", comment: ""), systemImage: "gearshape")
            }
            .tag(AppTab.settings)
        }
        .task {
            await ProManager.shared.setup()
        }
        .onOpenURL { url in
            // Switch to the Library tab so LibraryView is the active responder
            // for the pending URL. The binding then fires onChange there.
            selectedTab = .library
            pendingOpenURL = url
        }
    }
}

enum AppTab: Hashable {
    case library
    case settings
}
