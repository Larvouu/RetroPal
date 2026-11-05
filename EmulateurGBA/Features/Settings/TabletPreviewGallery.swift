//
//  TabletPreviewGallery.swift
//  EmulateurGBA
//
//  DEBUG-only: every iPad surface at the three iPad sizes of the plan, both
//  orientations, reviewable on a phone. Reachable from Settings ▸ Debug iPad,
//  one row per page: the library and its welcome, a game's page, Settings, the
//  two RetroAchievements pages, the controller remap, a list page, the pause
//  menu, and the eleven in-game layouts with their dress, in the look picked
//  in the in-game pages' top bar (three skins, or a controller connected).
//
//  Same convention as the other galleries (2026-05-25): the REAL views, so the
//  preview cannot drift from the app. A SwiftUI page is hosted at the device's
//  point size with the iPad surface forced through the environment (the idiom,
//  the two size classes, the insets), which is exactly what the page reads on a
//  real iPad; the in-game pages go through the same representables the phone
//  galleries use, and the tablet family comes from the size alone. Scaled to
//  fit the phone's width by default, since a 13-inch window on its side is
//  1376 points; the zoom control shows it at half or full size in a scroller.
//
//  What this cannot show: heat, real multitouch, and how iPadOS draws sheets.
//

#if DEBUG
import SwiftUI
import UIKit
import CoreData

/// The three iPads of the plan, portrait points. The insets are the ones
/// every iPad with a home indicator has, in both orientations: a 24-point
/// status bar, a 20-point indicator, nothing at the sides. Verify on device.
struct TabletPreviewDevice: Identifiable {
    var id: String { name }
    let name: String
    let portrait: CGSize
    var landscape: CGSize { CGSize(width: portrait.height, height: portrait.width) }

    static let insets = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)

    static let all: [TabletPreviewDevice] = [
        TabletPreviewDevice(name: "iPad mini", portrait: CGSize(width: 744, height: 1133)),
        TabletPreviewDevice(name: "iPad 11-inch", portrait: CGSize(width: 834, height: 1210)),
        TabletPreviewDevice(name: "iPad 13-inch", portrait: CGSize(width: 1032, height: 1376)),
    ]
}

/// One row of the Debug iPad section.
enum TabletPreviewPage: String, CaseIterable, Identifiable {
    case library, libraryEmpty, gameDetails, settings, raDashboard, raGame
    case controllerRemap, listPage, pauseMenu
    case gameBoy, gba, nds, snes, nes, ps1, n64, md, sms, gg, psp, n3ds

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Library"
        case .libraryEmpty: return "Library, empty (welcome)"
        case .gameDetails: return "Game details (first game)"
        case .settings: return "Settings"
        case .raDashboard: return "RetroAchievements dashboard"
        case .raGame: return "RetroAchievements game page (first game)"
        case .controllerRemap: return "Controller remap"
        case .listPage: return "List page (Legal)"
        case .pauseMenu: return "Pause menu"
        case .gameBoy: return "In game: Game Boy and Game Boy Color"
        case .gba: return "In game: Game Boy Advance"
        case .nds: return "In game: Nintendo DS"
        case .snes: return "In game: Super Nintendo"
        case .nes: return "In game: NES"
        case .ps1: return "In game: PlayStation"
        case .n64: return "In game: Nintendo 64"
        case .md: return "In game: Mega Drive"
        case .sms: return "In game: Master System"
        case .gg: return "In game: Game Gear"
        case .psp: return "In game: PSP"
        case .n3ds: return "In game: Nintendo 3DS"
        }
    }

    /// The in-game family, for the twelve console rows.
    var previewSystem: PreviewSystem? {
        switch self {
        case .gameBoy: return .gbc
        case .gba: return .gba
        case .nds: return .nds
        case .snes: return .snes
        case .nes: return .nes
        case .ps1: return .ps1
        case .n64: return .n64
        case .md: return .md
        case .sms: return .sms
        case .gg: return .gg
        case .psp: return .psp
        case .n3ds: return .n3ds
        default: return nil
        }
    }
}

/// One page, three devices, two orientations.
struct TabletPreviewGallery: View {
    let page: TabletPreviewPage

    private enum Zoom: String, CaseIterable, Identifiable {
        case fit = "Fit", half = "50 %", full = "100 %"
        var id: String { rawValue }
        func scale(fitting fit: CGFloat) -> CGFloat {
            switch self {
            case .fit: return min(1, fit)
            case .half: return 0.5
            case .full: return 1
            }
        }
    }

    @State private var zoom: Zoom = .fit
    /// The in-game pages' look, shared with the iPhone gallery (`PreviewLookBar`).
    @AppStorage(PreviewLook.storageKey) private var look: PreviewLook = .nostalgia
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \GameEntity.lastPlayedAt, ascending: false)])
    private var games: FetchedResults<GameEntity>
    @State private var sortOrder: LibraryView.SortOrder = .lastPlayed
    @State private var searchText = ""

    private var romsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ROMs", isDirectory: true)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Picker("Zoom", selection: $zoom) {
                        ForEach(Zoom.allCases) { z in Text(z.rawValue).tag(z) }
                    }
                    .pickerStyle(.segmented)
                    ForEach(TabletPreviewDevice.all) { device in
                        tile(device: device, landscape: true, availableWidth: geo.size.width - 32)
                        tile(device: device, landscape: false, availableWidth: geo.size.width - 32)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        // A way back of our own: the hosted pages hide the navigation bar they
        // find (the landscape surfaces draw their own bar), and on the first
        // device pass that took this gallery's bar with it.
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Label("Back to Settings", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .padding(12)
        }
        // The in-game pages only: the other pages have no skin to pick.
        .safeAreaInset(edge: .top) {
            if page.previewSystem != nil {
                PreviewLookBar(look: $look)
            }
        }
    }

    private func tile(device: TabletPreviewDevice, landscape: Bool, availableWidth: CGFloat) -> some View {
        let size = landscape ? device.landscape : device.portrait
        // The proxy reports 0 on the first pass; clamp so the scale is never negative.
        let scale = zoom.scale(fitting: max(0, availableWidth) / size.width)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(device.name) · \(landscape ? "landscape" : "portrait") \(Int(size.width))×\(Int(size.height))")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
                content(landscape: landscape)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .border(Color.red.opacity(0.6))
                    // The iPad surface, as the page would read it on an iPad.
                    .environment(\.surfaceIdiom, .pad)
                    .environment(\.horizontalSizeClass, .regular)
                    .environment(\.verticalSizeClass, .regular)
                    .environment(\.surfaceSafeAreaInsets, TabletPreviewDevice.insets)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
            }
        }
    }

    /// The page. The SwiftUI pages that set toolbar modifiers sit in a stack
    /// of their own, so those modifiers reach that stack's bar and never this
    /// gallery's.
    @ViewBuilder
    private func content(landscape: Bool) -> some View {
        switch page {
        case .library:
            LibraryLandscapeView(
                games: Array(games),
                isImporting: false,
                sortOrder: $sortOrder,
                consoleFilter: .constant(""),
                consoles: [],
                searchText: $searchText,
                showsStats: true,
                showsRA: true,
                isActive: true,
                onPlay: { _, _ in },
                onOpenDetails: { _ in },
                onRename: { _ in },
                onDelete: { _ in },
                onImport: {},
                onStats: {},
                onRA: {},
                onSettings: {})
        case .libraryEmpty:
            LibraryEmptyLandscapeView(isActive: true, onImport: {}, onSettings: {})
        case .gameDetails:
            if let game = games.first {
                NavigationStack {
                    GameDetailsView(game: game, onPlay: { _, _ in }, onDelete: {})
                }
            } else {
                note("Import a game first: this page shows the library's first game.")
            }
        case .settings:
            NavigationStack {
                SettingsView(selectedTab: .constant(.settings), isActiveTab: true)
            }
        case .raDashboard:
            NavigationStack {
                RetroAchievementsView()
            }
        case .raGame:
            if let game = games.first, let filename = game.romFilePath {
                RAAchievementsView(romURL: romsDir.appendingPathComponent(filename))
            } else {
                note("Import a game first: this page shows the library's first game.")
            }
        case .controllerRemap:
            NavigationStack {
                ControllerRemapView()
            }
        case .listPage:
            NavigationStack {
                LegalView()
            }
        case .pauseMenu:
            OverlayMenuPreviewRepresentable(isNDS: false, safeInsets: TabletPreviewDevice.insets)
        case .gameBoy, .gba, .nds, .snes, .nes, .ps1, .n64, .md, .sms, .gg, .psp, .n3ds:
            InGameLayoutPreviewRepresentable(system: page.previewSystem ?? .gba,
                                             isLandscape: landscape,
                                             safeInsets: TabletPreviewDevice.insets,
                                             look: look)
                .id(look)
        }
    }

    private func note(_ text: String) -> some View {
        ZStack {
            Color.black
            Text(text)
                .font(.title2)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(40)
        }
    }
}

// MARK: - A game page for store screenshots

/// One console, in game, filling the real window (Settings ▸ Debug, at its
/// foot, 2026-10-31): the store screenshots are taken on the device itself,
/// iPhone or iPad, with no game on it. The controls, the dress and the screen's frame are the
/// game's own (`InGameLayoutPreviewView`, the code the galleries above draw
/// with, on the game's geometry and the game's factories); the screen is plain
/// black, to be replaced by the picture afterwards. It turns with the iPad.
///
/// A UIKit controller presented over everything, as the game is, so that the
/// system asks IT about the bars: they follow the game's rule
/// (`EmulatorViewController.updateSystemChrome`), shown upright on a device
/// with a home indicator, hidden on its side, the status bar's text white on
/// the black. MENU closes it.
final class StoreScreenshotGameController: UIViewController {
    private let system: PreviewSystem
    private let look: PreviewLook
    private var chromeHidden = true

    init(system: PreviewSystem, look: PreviewLook) {
        self.system = system
        self.look = look
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let page = InGameLayoutPreviewView(system: system, isLandscape: false, safeInsets: .zero,
                                           look: look, screenshot: true)
        page.onMenuTap = { [weak self] in self?.dismiss(animated: true) }
        view = page
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateChrome(for: view.bounds.size)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in self?.updateChrome(for: size) })
    }

    private func updateChrome(for size: CGSize) {
        let reservesTopBand = (view.window ?? Self.keyWindow)?.safeAreaInsets.bottom ?? 0 > 0
        let hidden = !(size.height >= size.width && reservesTopBand)
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    override var prefersStatusBarHidden: Bool { chromeHidden }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.keyWindow
    }

    /// Presents the page over whatever is on screen.
    static func present(system: PreviewSystem, look: PreviewLook) {
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(StoreScreenshotGameController(system: system, look: look), animated: true)
    }
}
#endif
