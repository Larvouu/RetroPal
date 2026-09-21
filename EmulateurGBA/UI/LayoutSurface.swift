//
//  LayoutSurface.swift
//  EmulateurGBA
//
//  Which surface a SwiftUI page shows: the upright one (a List, the system
//  bars) or the one built for a phone on its side (the library's rack, the
//  moving ground, glass cards, a bar of our own). The iPad joined on
//  2026-09-05 and takes the second surface in BOTH orientations, so the
//  question is no longer "is the height compact" alone.
//
//  Two facts decide it, and no iPhone satisfies the second:
//
//  - `verticalSizeClass == .compact`: a phone on its side, exactly the
//    condition every page read before the iPad existed. A phone's answer is
//    unchanged by anything in this file.
//  - `surfaceIdiom == .pad && horizontalSizeClass == .regular`: an iPad
//    window wide enough to be an iPad window. Narrower (Stage Manager, a
//    split) the width goes compact and the page falls back to the upright
//    surface, which is the size-agnostic answer iPadOS 26 requires now that
//    `UIRequiresFullScreen` is no longer honoured.
//
//  The idiom is an environment value rather than a device read so the debug
//  galleries can render the iPad surface on a phone by setting it, with the
//  two size classes, on the hosted view.
//

import SwiftUI
import UIKit

/// The device family a page believes it is on. Defaults to the real one;
/// the debug galleries override it.
enum SurfaceIdiom: Equatable {
    case phone
    case pad

    static let current: SurfaceIdiom =
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
}

private struct SurfaceIdiomKey: EnvironmentKey {
    static let defaultValue: SurfaceIdiom = .current
}

/// The safe-area insets a surface lays out against. Set by the app shell
/// from its own geometry (2026-09-08), and by a debug gallery per hosted
/// tile; nil only where no shell is above (a test, a preview), and then the
/// surfaces read the key window's. It is an environment value rather than a
/// window read at render time because a surface that reads the window is
/// never told when the window changes: a game hides the status bar, the
/// library re-renders as the game closes while the bar is still away, reads
/// a zero top inset, and then draws its bar over the returning status bar
/// on an iPad (his first pass). An environment value changing re-renders
/// every surface that reads it.
private struct SurfaceSafeAreaInsetsKey: EnvironmentKey {
    static let defaultValue: UIEdgeInsets? = nil
}

extension EnvironmentValues {
    var surfaceIdiom: SurfaceIdiom {
        get { self[SurfaceIdiomKey.self] }
        set { self[SurfaceIdiomKey.self] = newValue }
    }

    var surfaceSafeAreaInsets: UIEdgeInsets? {
        get { self[SurfaceSafeAreaInsetsKey.self] }
        set { self[SurfaceSafeAreaInsetsKey.self] = newValue }
    }
}

/// True on an iPad window wide enough to be one. The tablet-only sizes in
/// the landscape kit (wider columns, larger covers, a capped list) key on
/// this; a phone never reads true.
@propertyWrapper
struct TabletSurface: DynamicProperty {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.surfaceIdiom) private var idiom

    var wrappedValue: Bool {
        idiom == .pad && horizontalSizeClass == .regular
    }
}

/// True when a page shows the surface built for a phone on its side: a
/// compact height, or a tablet window. Replaces the `verticalSizeClass ==
/// .compact` read the pages made before the iPad; on a phone it is that
/// read, and nothing more.
@propertyWrapper
struct LandscapeSurface: DynamicProperty {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.surfaceIdiom) private var idiom

    var wrappedValue: Bool {
        verticalSizeClass == .compact || (idiom == .pad && horizontalSizeClass == .regular)
    }
}

// MARK: - A page that is a sheet on a phone and a screen on a tablet

/// The RetroAchievements game page is a sheet on a phone. On an iPad a sheet
/// is a form in the middle of the window, and a page that lays a badge wall
/// out across the width wants the whole window, so there it presents as a
/// full-screen cover instead. The page itself draws its own way back.
private struct PagePresentation<Page: View>: ViewModifier {
    @Environment(\.surfaceIdiom) private var idiom
    let isPresented: Binding<Bool>
    let page: () -> Page

    func body(content: Content) -> some View {
        Group {
            if idiom == .pad {
                content.fullScreenCover(isPresented: isPresented, content: page)
            } else {
                content.sheet(isPresented: isPresented, content: page)
            }
        }
    }
}

private struct ItemPagePresentation<Item: Identifiable, Page: View>: ViewModifier {
    @Environment(\.surfaceIdiom) private var idiom
    let item: Binding<Item?>
    let page: (Item) -> Page

    func body(content: Content) -> some View {
        Group {
            if idiom == .pad {
                content.fullScreenCover(item: item, content: page)
            } else {
                content.sheet(item: item, content: page)
            }
        }
    }
}

extension View {
    func pagePresentation<Page: View>(isPresented: Binding<Bool>,
                                      @ViewBuilder content: @escaping () -> Page) -> some View {
        modifier(PagePresentation(isPresented: isPresented, page: content))
    }

    func pagePresentation<Item: Identifiable, Page: View>(item: Binding<Item?>,
                                                          @ViewBuilder content: @escaping (Item) -> Page) -> some View {
        modifier(ItemPagePresentation(item: item, page: content))
    }
}

// MARK: - The device's name in a sentence

/// Fifteen strings name the device ("Play your retro games on iPhone", "keep
/// your iPhone as the controller"). Each has an `.ipad` twin, written per
/// language because the noun declines in some of them, and this picks the
/// twin on an iPad. The base key stays the literal the localisation test
/// scans for; the twin is pinned by name in the same test.
enum DeviceWording {
    static func string(_ key: String) -> String {
        let resolved = SurfaceIdiom.current == .pad ? key + ".ipad" : key
        return NSLocalizedString(resolved, comment: "")
    }
}
