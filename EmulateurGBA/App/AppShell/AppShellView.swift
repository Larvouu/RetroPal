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

    /// Game launch requested by a home-screen widget tap. Same
    /// binding-then-onChange shape as `pendingOpenURL` so it survives a cold
    /// launch, where SwiftUI delivers the URL after the first render pass.
    @State private var pendingPlayRequest: WidgetSharing.PlayRequest?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutDirection) private var layoutDirection
    /// The window's safe-area insets, measured here and handed to every
    /// surface that lays out against them (`surfaceSafeAreaInsets`,
    /// 2026-09-08): a surface that read the window itself was never told
    /// when a game gave the status bar back.
    @State private var surfaceInsets: UIEdgeInsets?

    private func uiInsets(_ edges: EdgeInsets) -> UIEdgeInsets {
        let rtl = layoutDirection == .rightToLeft
        return UIEdgeInsets(top: edges.top, left: rtl ? edges.trailing : edges.leading,
                            bottom: edges.bottom, right: rtl ? edges.leading : edges.trailing)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView(pendingOpenURL: $pendingOpenURL,
                            pendingPlayRequest: $pendingPlayRequest,
                            selectedTab: $selectedTab,
                            isActiveTab: selectedTab == .library)
            }
            .tabItem {
                Label(NSLocalizedString("tab.library", comment: ""), systemImage: "books.vertical")
            }
            .tag(AppTab.library)

            NavigationStack {
                SettingsView(selectedTab: $selectedTab,
                             isActiveTab: selectedTab == .settings)
            }
            .tabItem {
                Label(NSLocalizedString("tab.settings", comment: ""), systemImage: "gearshape")
            }
            .tag(AppTab.settings)
        }
        .task {
            await ProManager.shared.setup()
            // Seed the widget on a fresh install / first launch after update;
            // every later change is picked up when the app backgrounds.
            WidgetSnapshotWriter.refresh()
        }
        .onChange(of: scenePhase) { phase in
            // Publish on the way out: the user is heading to the Home Screen,
            // which is exactly when the widget is about to be read. Covers
            // every library mutation (import, delete, rename, cover) without
            // scattering refresh calls. No-op while a game is loaded — see
            // WidgetSnapshotWriter.isGameLoaded; the post-game refresh happens
            // when the emulator cover dismisses instead.
            if phase == .background { WidgetSnapshotWriter.refresh() }
        }
        .onOpenURL { url in
            // Our own scheme is checked FIRST. A widget tap is a launch
            // request, and the import path below would otherwise swallow it
            // as an unreadable ROM file.
            if WidgetSharing.isOurURL(url) {
                selectedTab = .library
                pendingPlayRequest = WidgetSharing.parsePlayURL(url)
                return
            }
            // A shared custom skin (.retropalskin) imports in place (no library routing).
            if SkinSharing.isSkinFile(url) {
                SkinSharing.handleIncoming(url)
                return
            }
            // Switch to the Library tab so LibraryView is the active responder
            // for the pending URL. The binding then fires onChange there.
            selectedTab = .library
            pendingOpenURL = url
        }
        .onChange(of: selectedTab) { _ in
            Haptics.tap()
        }
        // Measured from behind the tab view so nothing about its layout
        // changes. Until the first pass lands the value is nil and the
        // surfaces read the window, as they always did.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { surfaceInsets = uiInsets(geo.safeAreaInsets) }
                    .onChange(of: geo.safeAreaInsets) { edges in surfaceInsets = uiInsets(edges) }
            }
        )
        .environment(\.surfaceSafeAreaInsets, surfaceInsets)
    }
}

enum AppTab: Hashable {
    case library
    case settings
}
