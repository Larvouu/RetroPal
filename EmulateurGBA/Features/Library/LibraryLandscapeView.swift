//
//  LibraryLandscapeView.swift
//  EmulateurGBA
//
//  The library in landscape: one line of covers with the selected game in the
//  centre of the screen, the way a console home screen presents its games.
//
//  Portrait keeps its List by default. Since 2026-09-07 the same view also
//  serves a phone held UPRIGHT when the player picks one of the looks from the
//  palette button beside the library's plus (`upright: true`): the same bar
//  in two rows, then a HERO, the last game played with its cover, its two
//  stats, Play and (i), then the library's own List at its usual density on
//  glass rows (handed in by the library as `uprightList`). A rack standing on
//  end was tried first the same day and dropped: portrait is where a game is
//  FOUND, and one readable cover in place of six readable rows was a step
//  back. "Classic" in that picker is the List. An iPad shows this surface
//  either way up already. The view's own state (the selected game, a drag
//  in progress) starts fresh on every rotation, and the chosen game is
//  re-found from its stored path.
//
//  Three things are deliberate:
//
//  - The line does NOT scroll freely. A drag moves it under the finger, and a
//    release always lands on a notch: one game exactly centred. The arithmetic
//    (which notch, from where, with what fling) lives in
//    `LibraryCarouselGeometry`, a pure value, so the tests can pin it without
//    a phone. iOS 17's paging scroll targets are not available at iOS 16, so
//    the gesture is ours.
//  - Tapping a cover SELECTS it (the line moves to centre it). Playing is the
//    Play button under the line, which opens the same slot choice Game
//    Details offers, and the (i) beside it opens Game Details itself. Two
//    taps to the slot you want, exactly as in portrait.
//  - Safe areas are ignored on purpose (decided on device, 2026-09-04): the surface is
//    edge to edge, and the top bar and the ends of the line may sit behind
//    the Dynamic Island.
//
//  Colours: the surface is always dark, whatever the system appearance, so the
//  white type and the glow read the same everywhere. The two brand hues are
//  the GBA body purple (#7558EB, the app's own console dress) and a saturated
//  light blue (#6FD3FF) chosen against it; the website's near-white paper blue
//  would not glow on a dark ground.
//

import SwiftUI
import UIKit
import CoreData

// MARK: - Geometry (pure, tested)

/// The maths of the carousel, kept free of views so `LibraryCarouselGeometryTests`
/// can pin it. Offsets are in points of FINGER TRAVEL, measured from the
/// position where the FIRST item sits centred: index 0 is offset 0, and every
/// further item is one `stride` to the left (a more negative offset).
///
/// The line is a CD rack (decided on device, 2026-09-04): the centred cover faces the
/// player, its first neighbours sit one `stride` away turned towards it, and
/// every cover beyond is stacked `stackStride` further, still turned, so a
/// dozen covers fit where five did flat. Where a cover stands, how far it is
/// turned and how big it is are all functions of its DISTANCE from the
/// centre, in notches, which is continuous during a drag.
struct LibraryCarouselGeometry: Equatable {
    /// Side of one square tile, at rest.
    let itemSide: CGFloat
    /// Number of items in the line.
    let count: Int

    /// Finger travel per notch, and the distance from the centred cover to
    /// the centre of its first neighbour. Close to a side: the centred cover
    /// stands apart, its neighbours a little away from it (decided on device,
    /// 2026-09-04, third review: 0.95).
    var stride: CGFloat { itemSide * 0.95 }
    /// Distance between two stacked covers beyond the first neighbour. A
    /// cover turned by the stack angle shows about cos(58°) of its width, so
    /// at 0.4 the stacked covers overlap a little, like boxes in a rack
    /// (third device review, 2026-09-04).
    var stackStride: CGFloat { itemSide * 0.4 }
    /// The turn of a stacked cover, in degrees, applied with the sign of the
    /// cover's side. ⚠ NEGATIVE, and the sign was settled on the device, not
    /// on paper (decided on device, 2026-09-04): the first cut derived +58 from Core
    /// Animation's Y rotation and the covers turned the wrong way on the
    /// phone. One constant, so the sign is one edit.
    static let stackAngle: Double = -58
    /// How much the centred cover grows.
    static let selectedScale: CGFloat = 1.15

    /// Keeps an index inside the line. An empty line answers 0 so callers can
    /// index nothing safely.
    func clamp(_ index: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    /// The offset that centres `index`.
    func offset(forIndex index: Int) -> CGFloat {
        -CGFloat(clamp(index)) * stride
    }

    /// The offset of the first notch (index 0) and of the last one, the two
    /// bounds a drag is rubber-banded against.
    var maxOffset: CGFloat { 0 }
    var minOffset: CGFloat { offset(forIndex: max(count - 1, 0)) }

    /// Where the centre is, in notches, for any offset: 1.5 means half way
    /// between the second and third items.
    func progress(forOffset offset: CGFloat) -> CGFloat {
        guard stride > 0 else { return 0 }
        return -offset / stride
    }

    /// The item nearest the centre for any offset, clamped to the line. This
    /// is what the finger "feels" during a drag (the haptic tick fires when it
    /// changes) and what the selection ring follows live.
    func nearestIndex(forOffset offset: CGFloat) -> Int {
        guard count > 0, stride > 0 else { return 0 }
        return clamp(Int(progress(forOffset: offset).rounded()))
    }

    /// Where a release lands. `projectedOffset` is where the drag would stop on
    /// its own (SwiftUI's `predictedEndTranslation`, applied to the offset), so
    /// a flick carries past the item under the finger and a slow release does
    /// not. The landing is then snapped to the nearest notch, and never more
    /// than `maxFlingItems` past the item the finger released on: a hard flick
    /// steps a few games, it does not throw the line to its end.
    func targetIndex(releasedAt offset: CGFloat,
                     projectedOffset: CGFloat,
                     maxFlingItems: Int = 3) -> Int {
        guard count > 0, stride > 0 else { return 0 }
        let from = nearestIndex(forOffset: offset)
        let projected = Int(progress(forOffset: projectedOffset).rounded())
        let bounded = min(max(projected, from - maxFlingItems), from + maxFlingItems)
        return clamp(bounded)
    }

    /// The drag translation to apply for a raw finger translation, damped
    /// once the line is pulled past either end so the ends feel like ends.
    /// `base` is the resting offset the drag started from.
    func rubberBandedTranslation(_ translation: CGFloat, base: CGFloat,
                                 resistance: CGFloat = 0.35) -> CGFloat {
        let raw = base + translation
        if raw > maxOffset {
            return (maxOffset - base) + (raw - maxOffset) * resistance
        }
        if raw < minOffset {
            return (minOffset - base) + (raw - minOffset) * resistance
        }
        return translation
    }

    /// Horizontal centre of a cover `distance` notches from the centre
    /// (negative on the left): one stride to the first neighbour, then one
    /// stack stride per cover.
    func x(forDistance distance: CGFloat) -> CGFloat {
        let away = abs(distance)
        let sign: CGFloat = distance < 0 ? -1 : 1
        if away <= 1 { return sign * away * stride }
        return sign * (stride + (away - 1) * stackStride)
    }

    /// The turn of a cover `distance` notches from the centre, in degrees:
    /// none at the centre, the full stack angle from the first neighbour on.
    func angle(forDistance distance: CGFloat) -> Double {
        Double(max(-1, min(1, distance))) * Self.stackAngle
    }

    /// The size of a cover `distance` notches from the centre: the selected
    /// scale at the centre, 1 from the first neighbour on.
    func scale(forDistance distance: CGFloat) -> CGFloat {
        1 + (Self.selectedScale - 1) * max(0, 1 - abs(distance))
    }

    /// Tiles further than this many notches from the centred one are not
    /// drawn (an empty place holds their spot), which keeps a large library
    /// from decoding every cover on rotation. Counted in stacked covers from
    /// the first neighbour to the screen's edge, plus two of margin.
    func visibleRadius(forWidth width: CGFloat) -> Int {
        guard stackStride > 0 else { return 1 }
        let beyondFirst = max(0, width / 2 - stride)
        return Int((beyondFirst / stackStride).rounded(.up)) + 2
    }
}

// MARK: - Theme and palette

/// The five looks of the landscape surfaces (decided on device, 2026-09-05): the
/// original purple and light blue, a near-black neutral, and three
/// variations that keep the same construction (a dark ground, two glows, a
/// two-colour accent on every button and ring) in other hues. Landscape
/// only: portrait is untouched by the choice. The names are proper names,
/// unlocalized like the console names, and are also the accessibility text.
enum LandscapeTheme: String, CaseIterable, Identifiable {
    /// The GBA body purple #7558EB and a saturated light blue #6FD3FF, the
    /// look the surfaces were designed in.
    case aurora
    /// Almost dark, neutral: greys, and glows kept faint on purpose.
    case graphite
    /// Rose and coral.
    case ember
    /// Green and light green.
    case meadow
    /// Orange and gold.
    case sunset

    var id: String { rawValue }

    var name: String {
        switch self {
        case .aurora:   return "Aurora"
        case .graphite: return "Graphite"
        case .ember:    return "Ember"
        case .meadow:   return "Meadow"
        case .sunset:   return "Sunset"
        }
    }

    /// The main accent: the ring, the first colour of every gradient, the
    /// first glow.
    var accentRGB: (r: Double, g: Double, b: Double) {
        switch self {
        case .aurora:   return (0.459, 0.345, 0.922)
        case .graphite: return (0.42, 0.44, 0.56)
        case .ember:    return (0.878, 0.290, 0.416)
        case .meadow:   return (0.184, 0.702, 0.416)
        case .sunset:   return (0.941, 0.478, 0.165)
        }
    }

    /// The light accent: the second colour of every gradient, the tint of
    /// the fields, the second glow.
    var highlightRGB: (r: Double, g: Double, b: Double) {
        switch self {
        case .aurora:   return (0.435, 0.827, 1.0)
        case .graphite: return (0.86, 0.87, 0.93)
        case .ember:    return (1.0, 0.620, 0.541)
        case .meadow:   return (0.718, 0.949, 0.478)
        case .sunset:   return (1.0, 0.820, 0.400)
        }
    }

    /// The ground everything sits on.
    var groundRGB: (r: Double, g: Double, b: Double) {
        switch self {
        case .aurora:   return (0.05, 0.04, 0.10)
        case .graphite: return (0.04, 0.04, 0.05)
        case .ember:    return (0.10, 0.03, 0.05)
        case .meadow:   return (0.03, 0.08, 0.05)
        case .sunset:   return (0.10, 0.05, 0.02)
        }
    }

    /// How strong the glows and the dust are, 1 for the coloured looks and
    /// low for the neutral one, which is meant to stay almost dark.
    var glow: Double { self == .graphite ? 0.5 : 1 }

    var accent: Color { Color(red: accentRGB.r, green: accentRGB.g, blue: accentRGB.b) }
    var highlight: Color { Color(red: highlightRGB.r, green: highlightRGB.g, blue: highlightRGB.b) }
    var ground: Color { Color(red: groundRGB.r, green: groundRGB.g, blue: groundRGB.b) }
    var accentUIColor: UIColor { UIColor(red: accentRGB.r, green: accentRGB.g, blue: accentRGB.b, alpha: 1) }
    var highlightUIColor: UIColor { UIColor(red: highlightRGB.r, green: highlightRGB.g, blue: highlightRGB.b, alpha: 1) }
}

/// The chosen theme, persisted, and the one object every landscape surface
/// observes so a change in the picker repaints them all at once.
///
/// Since 2026-09-07 it also holds whether an upright phone (or an iPad
/// window narrowed to a phone's width, since 2026-09-08) shows the List
/// ("Classic", the default, so nothing changes until a look is picked) or the
/// themed surface in the chosen look. The look itself is ONE value for both
/// orientations: picking Ember upright makes the landscape Ember too, and
/// picking Classic leaves the landscape look as it was.
final class LandscapeThemeStore: ObservableObject {
    static let shared = LandscapeThemeStore()
    private static let key = "landscape.theme"
    private static let classicKey = "library.portrait.classic"
    private static let heroKey = "library.hero.shown"
    /// Stamped once the 1.3.1 default has been applied. **Every user, old or
    /// new, lands on Aurora upright at the first launch of 1.3.1** (2026-09-07):
    /// whatever a pre-release build had stored is replaced once, and from
    /// then on the choice is the player's. Bump the stamp to re-apply.
    private static let defaultStampKey = "library.look.defaultApplied"
    private static let defaultStamp = "1.3.1"

    @Published var theme: LandscapeTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }

    /// True while the upright surface (a phone, or an iPad window at a
    /// phone's width) keeps the List.
    @Published var portraitClassic: Bool {
        didSet { UserDefaults.standard.set(portraitClassic, forKey: Self.classicKey) }
    }

    /// Whether the upright library shows the last game played above its List.
    @Published var showsHero: Bool {
        didSet { UserDefaults.standard.set(showsHero, forKey: Self.heroKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.defaultStampKey) != Self.defaultStamp {
            defaults.set(LandscapeTheme.aurora.rawValue, forKey: Self.key)
            defaults.set(false, forKey: Self.classicKey)
            defaults.set(Self.defaultStamp, forKey: Self.defaultStampKey)
        }
        theme = LandscapeTheme(rawValue: defaults.string(forKey: Self.key) ?? "") ?? .aurora
        portraitClassic = defaults.object(forKey: Self.classicKey) as? Bool ?? false
        showsHero = defaults.object(forKey: Self.heroKey) as? Bool ?? true
    }
}

/// The current theme's colours, under the role names the surfaces use. Read
/// at render time; a surface that observes `LandscapeThemeStore` re-renders
/// when the theme changes and picks the new values up here.
enum LibraryLandscapePalette {
    private static var theme: LandscapeTheme { LandscapeThemeStore.shared.theme }

    /// The main accent (the purple of the original look).
    static var accent: Color { theme.accent }
    /// The light accent (the light blue of the original look).
    static var highlight: Color { theme.highlight }
    /// The ground everything sits on.
    static var ground: Color { theme.ground }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, highlight], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Chrome shared by the landscape surfaces

/// The controls of the landscape library and the landscape game page: glass
/// circles and glass capsules on the dark ground.
enum LandscapeChrome {
    /// The opacities of everything that sits on the ground, raised together
    /// on 2026-09-07: at 0.08 a card let a glow through and its grey type
    /// lost against it. One place, so the controls, the cards and the list
    /// rows always agree.
    static let glassFill: Double = 0.24
    static let glassStroke: Double = 0.30
    static let cardFill: Double = 0.18
    static let cardStroke: Double = 0.22
    /// The light black film between the ground and a page's content
    /// (2026-09-07): everywhere but the rack of covers, which carries its
    /// own contrast. Low on purpose; the cards do the rest.
    static let groundFilm: Double = 0.4

    /// A translucent fill, NOT a material. A material samples and blurs what
    /// is behind it on every frame the backdrop changes, and the ground here
    /// never stops moving, so six of them were six full backdrop blurs per
    /// frame: measurable heat on an iPhone 14 Pro (2026-09-04). A plain fill
    /// costs nothing.
    static func glass<S: InsettableShape>(_ shape: S) -> some View {
        shape
            .fill(Color.white.opacity(glassFill))
            .overlay(shape.strokeBorder(Color.white.opacity(glassStroke), lineWidth: 1))
    }

    /// A 40-point glass circle around one symbol.
    static func circle(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(glass(Circle()))
            .contentShape(Circle())
    }

    /// The Library · Settings pill an iPad shows at the bottom of the library,
    /// of its welcome and of Settings, in BOTH orientations (decided on
    /// device, 2026-09-08). It mirrors the iPhone's upright tab bar, icon over
    /// label in a glass capsule, because the SYSTEM tab bar cannot be asked to
    /// sit there: since iPadOS 18 it stands at the top of the window, over the
    /// surface's own bar, and Apple gives no API to move it (the one private
    /// default that did, `UseFloatingTabBar`, stopped working in iOS 26.4). So
    /// the system tab bar stays hidden on the iPad surface and this pill takes
    /// the place the circles had; a phone on its side keeps the circles.
    /// Drawn as a bottom safe-area inset, so the content above makes room for
    /// it; it clears the home indicator by `insets.bottom`. Plain fills, no
    /// material, for the same reason as every other glass here.
    static func tabPill(selected: AppTab, insets: UIEdgeInsets,
                        onSelect: @escaping (AppTab) -> Void) -> some View {
        HStack(spacing: 4) {
            tabPillItem(systemName: "books.vertical",
                        title: NSLocalizedString("tab.library", comment: ""),
                        selected: selected == .library) { onSelect(.library) }
            tabPillItem(systemName: "gearshape",
                        title: NSLocalizedString("tab.settings", comment: ""),
                        selected: selected == .settings) { onSelect(.settings) }
        }
        .padding(4)
        .background(glass(Capsule()))
        .padding(.top, 10)
        .padding(.bottom, insets.bottom + 10)
    }

    /// One item of the pill: the symbol over its name, the chosen one on a
    /// lighter capsule. The item grows with its name (rule 8: a long
    /// language widens the primitive, the name is never cut).
    private static func tabPillItem(systemName: String, title: String,
                                    selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.72))
            .padding(.horizontal, 14)
            .frame(minWidth: 104)
            .frame(height: 50)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.18 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// A glass card: an optional small uppercase title, then the content.
    static func card<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(cardFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(cardStroke), lineWidth: 1)
        )
    }

    /// The key window's safe-area insets, read from UIKit. A landscape
    /// surface ignores the safe area to run edge to edge, and a
    /// `GeometryReader` inside such a view reports the insets it ignores as
    /// zero (found on an iPhone 14 Pro, 2026-09-04: the screenshot sat behind
    /// the Dynamic Island). The window still knows them; in landscape both
    /// sides carry the island's inset.
    static var windowSafeAreaInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window?.safeAreaInsets ?? .zero
    }

    /// The insets a surface lays out against: the shell's measured ones
    /// (`\.surfaceSafeAreaInsets`, which a debug gallery overrides per tile
    /// when it renders an iPad on a phone), the key window's where no shell
    /// is above.
    static func insets(_ surface: UIEdgeInsets?) -> UIEdgeInsets {
        surface ?? windowSafeAreaInsets
    }

    /// The gap above the bar. A phone on its side shows no status bar and
    /// keeps its 26 points; an iPad shows one in both orientations, and so
    /// does an upright phone, so the bar clears it by ten points.
    static func barTopPadding(tablet: Bool, upright: Bool = false, insets: UIEdgeInsets) -> CGFloat {
        tablet || upright ? insets.top + 10 : 26
    }

    /// The gap under a bottom-corner circle. On an iPad it clears the home
    /// indicator; a phone on its side keeps its 14.
    static func cornerBottomPadding(tablet: Bool, insets: UIEdgeInsets) -> CGFloat {
        tablet ? insets.bottom + 8 : 14
    }

    /// A List on an iPad is capped to this and centred (2026-09-05): a
    /// settings row stretched across 1376 points puts its toggle a hand's
    /// width from its label.
    static let tabletListMaxWidth: CGFloat = 760

    /// Whether a two-column page stacks its columns (decided on device,
    /// 2026-09-05): an upright iPad puts the left column above the right one
    /// in a single scroll; on its side, and on every phone, the two stand
    /// side by side.
    static func isStacked(tablet: Bool, size: CGSize) -> Bool {
        tablet && size.height > size.width
    }
}

/// The scaffold's answer to `isStacked`, for a list page that has no window
/// geometry of its own (the controller remap reads it).
private struct LandscapeStackedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var landscapeStacked: Bool {
        get { self[LandscapeStackedKey.self] }
        set { self[LandscapeStackedKey.self] = newValue }
    }
}

// MARK: - A list on its side

/// Set by `LandscapeListScaffold` on the list it hosts. `landscapeGlassRow()`
/// reads it, so a section marked once sits on glass in landscape and keeps
/// the system row background in portrait, with no state in the page.
private struct LandscapeGlassRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var landscapeGlassRows: Bool {
        get { self[LandscapeGlassRowsKey.self] }
        set { self[LandscapeGlassRowsKey.self] = newValue }
    }
}

private struct LandscapeGlassRowModifier: ViewModifier {
    @Environment(\.landscapeGlassRows) private var glass

    func body(content: Content) -> some View {
        content.listRowBackground(glass ? Color.white.opacity(LandscapeChrome.cardFill) : nil)
    }
}

extension View {
    /// On a section (or one row): glass in landscape under a
    /// `LandscapeListScaffold`, the system background everywhere else. A row
    /// that sets its own background keeps it.
    func landscapeGlassRow() -> some View {
        modifier(LandscapeGlassRowModifier())
    }
}

/// A pushed list page, or a sheet's form, on its side: the ground, a bar of
/// our own (the way back or a Cancel, the title, the controller badge), then
/// the list itself with its scroll background hidden and its marked sections
/// on glass, inside the safe area. Hides the system bars in landscape. The
/// list is the content and is passed through untouched; only its chrome
/// changes, the same way Settings was done.
struct LandscapeListScaffold<Content: View>: View {
    enum Leading { case back, cancel, none }

    let title: String
    var leading: Leading = .back
    @ViewBuilder let content: () -> Content
    /// Observed so a theme change repaints this surface.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An iPad window: the list is capped to a readable width.
    @TabletSurface private var isTablet
    @Environment(\.surfaceSafeAreaInsets) private var surfaceInsets

    var body: some View {
        let insets = LandscapeChrome.insets(surfaceInsets)
        return GeometryReader { geo in
        ZStack {
            LibraryLandscapeBackground(isPaused: reduceMotion, dimmed: true)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    switch leading {
                    case .back:
                        Button {
                            dismiss()
                        } label: {
                            LandscapeChrome.circle(systemName: "chevron.left")
                        }
                        .accessibilityLabel(NSLocalizedString("tab.settings", comment: ""))
                    case .cancel:
                        Button {
                            dismiss()
                        } label: {
                            Text(NSLocalizedString("common.cancel", comment: ""))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .frame(height: 40)
                                .background(LandscapeChrome.glass(Capsule()))
                        }
                    case .none:
                        EmptyView()
                    }
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    ControllerStatusBadge(tint: .white)
                }
                .frame(height: 40)
                .padding(.horizontal, 24)
                .padding(.top, LandscapeChrome.barTopPadding(tablet: isTablet, insets: insets))
                content()
                    .scrollContentBackground(.hidden)
                    .environment(\.landscapeGlassRows, true)
                    .environment(\.landscapeStacked, LandscapeChrome.isStacked(tablet: isTablet, size: geo.size))
                    .frame(maxWidth: isTablet ? LandscapeChrome.tabletListMaxWidth : .infinity)
                    .padding(.leading, insets.left)
                    .padding(.trailing, insets.right)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Whether an upright page shows the chosen look (2026-09-07): not a
/// landscape surface, and the List not chosen back in the palette. That is a
/// phone upright, or an iPad window narrowed to a phone's width (windowed,
/// Stage Manager): until 2026-09-08 the narrow window kept the List whatever
/// the look, which read on the device as a forced Classic. Read at render
/// time by the recipe below; a page that needs the fact for its own
/// decisions observes the store and reads the same two things.
enum UprightLook {
    static func isActive(isLandscape: Bool, store: LandscapeThemeStore) -> Bool {
        !isLandscape && !store.portraitClassic
    }
}

/// The upright phone in a chosen look, applied to a page's List or Form
/// where it stands (2026-09-07). Unlike the iPad, NOTHING moves: the page
/// keeps its layout, its system bars and its links; only the ground under it
/// and the dress of its content change. The scroll background goes so the
/// moving ground shows, the marked sections sit on glass (the same flag the
/// landscape scaffold sets, so `landscapeGlassRow()` answers both), the
/// subtree renders dark, and the bars take the dark scheme so their type
/// reads on the ground. On the List, or on the landscape surface (a phone
/// on its side, an iPad window wide enough to be one), the page is returned
/// untouched.
private struct UprightLookModifier: ViewModifier {
    /// Pauses the ground (the library's tab while another shows).
    let isActive: Bool
    /// The tint of the page's plain buttons and links in the look, nil for
    /// the system's. The game page passes white: the default blue does not
    /// read on the purple ground (2026-09-07).
    let tint: Color?
    @LandscapeSurface private var isLandscape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Observed so a change of look, or Classic chosen back, repaints the page.
    @ObservedObject private var store = LandscapeThemeStore.shared

    func body(content: Content) -> some View {
        if UprightLook.isActive(isLandscape: isLandscape, store: store) {
            content
                .scrollContentBackground(.hidden)
                .background(LibraryLandscapeBackground(isPaused: !isActive || reduceMotion, dimmed: true))
                .environment(\.landscapeGlassRows, true)
                .environment(\.colorScheme, .dark)
                .tint(tint)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarColorScheme(.dark, for: .tabBar)
        } else {
            content
        }
    }
}

extension View {
    /// The upright look on a page's List or Form (see `UprightLookModifier`).
    func uprightLook(isActive: Bool = true, tint: Color? = nil) -> some View {
        modifier(UprightLookModifier(isActive: isActive, tint: tint))
    }
}

/// The two-line switch a list page makes: the scaffold on its side, the
/// list as it always was upright, in the chosen look if there is one. Wraps
/// the list where it stands, so the page keeps its title, its modifiers and
/// its sheets untouched.
struct LandscapeListSwitch<Content: View>: View {
    let title: String
    var leading: LandscapeListScaffold<Content>.Leading = .back
    @ViewBuilder let content: () -> Content

    /// A phone on its side, or an iPad window (see `LandscapeSurface`).
    @LandscapeSurface private var isLandscape

    var body: some View {
        if isLandscape {
            LandscapeListScaffold(title: title, leading: leading, content: content)
        } else {
            content()
                .uprightLook()
        }
    }
}

// MARK: - The welcome, on its side

/// The library's import call to action. Import is a FREE action, not a Pro
/// feature: purple-dominant so it never pattern-matches to the app's gold
/// "Pro" signal; a 1pt gold hairline at 40 % opacity warms the edge just
/// enough to keep the brand identity. Shared by the upright welcome and the
/// one on its side.
struct LibraryImportCTA: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
}

/// Step text with an optional %@ placeholder replaced inline by the same SF
/// Symbol that backs the import button, so "Tap %@ to add a game file" shows
/// the actual plus rather than a plain "+" character.
struct LibraryStepLabel: View {
    let text: String
    /// The plus symbol's colour: the accent upright, the sky blue on the
    /// dark ground.
    var symbolTint: Color = .accentColor

    var body: some View {
        if text.contains("%@") {
            let parts = text.components(separatedBy: "%@")
            let before = parts.first ?? ""
            let after = parts.dropFirst().joined(separator: "%@")
            Text(before)
                + Text(Image(systemName: "plus"))
                    .foregroundColor(symbolTint)
                    .fontWeight(.semibold)
                + Text(after)
        } else {
            Text(text)
        }
    }
}

/// The welcome screen on its side (the library with no game yet): the
/// library's ground and bar, the pitch on the left (headline, one line, the
/// seven consoles) and the three steps, the call to action and the two notes
/// on the right. Same strings, same order as the upright welcome.
struct LibraryEmptyLandscapeView: View {
    /// An upright phone in a chosen look (2026-09-07): the pitch above the
    /// steps as on an iPad, the bar under the status bar, the palette in the
    /// bar so the List can be chosen back from here too.
    var upright: Bool = false
    let isActive: Bool
    let onImport: () -> Void
    let onSettings: () -> Void
    /// Observed so a theme change repaints this surface.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An iPad window: the two columns are capped and centred, and the
    /// Library · Settings pill stands at the bottom instead of the Settings
    /// circle (2026-09-08, see `LandscapeChrome.tabPill`).
    @TabletSurface private var isTablet
    @Environment(\.surfaceSafeAreaInsets) private var surfaceInsets
    @State private var showThemePicker = false

    var body: some View {
        let insets = LandscapeChrome.insets(surfaceInsets)
        return GeometryReader { geo in
        ZStack {
            LibraryLandscapeBackground(isPaused: !isActive || reduceMotion, dimmed: upright)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer(minLength: 8)
                    ControllerStatusBadge(tint: .white)
                    Button {
                        Haptics.tap()
                        showThemePicker = true
                    } label: {
                        LandscapeChrome.circle(systemName: "paintpalette")
                    }
                    .accessibilityLabel(themeStore.theme.name)
                    Button(action: onImport) {
                        LandscapeChrome.circle(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("guide.importRom.title", comment: ""))
                }
                .frame(height: 40)
                .padding(.horizontal, 24)
                .padding(.top, LandscapeChrome.barTopPadding(tablet: isTablet, upright: upright, insets: insets))

                Group {
                    if isTablet || upright {
                        // An iPad, either way up (decided on device, 2026-09-05): the
                        // pitch above the steps as the upright phone shows them, the
                        // whole block centred vertically when it fits the window,
                        // one scroll when it does not.
                        ViewThatFits(in: .vertical) {
                            VStack(spacing: 24) {
                                pitchColumn
                                stepsColumn
                            }
                            .frame(maxWidth: 620)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 24) {
                                    pitchColumn
                                    stepsColumn
                                }
                                .frame(maxWidth: 620)
                                .frame(maxWidth: .infinity)
                                // Room under the last note for the Settings circle.
                                .padding(.bottom, 56)
                            }
                        }
                    } else {
                        HStack(alignment: .center, spacing: 24) {
                            pitchColumn
                                .frame(maxWidth: .infinity)
                            ScrollView(.vertical, showsIndicators: false) {
                                stepsColumn
                                    // Room under the last note for the Settings circle.
                                    .padding(.bottom, 56)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        // On an iPad the pair is capped and centred; a phone fills the width.
                        .frame(maxWidth: isTablet ? 960 : .infinity)
                    }
                }
                .padding(.leading, 24 + insets.left)
                .padding(.trailing, 24 + insets.right)
                .padding(.top, 12)
                .padding(.bottom, 22)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isTablet {
                    LandscapeChrome.tabPill(selected: .library, insets: insets) { tab in
                        if tab == .settings { onSettings() }
                    }
                }
            }

            // Upright the tab bar stays and Settings is a tab, so no circle;
            // an iPad has the pill at the bottom for it (2026-09-08).
            if !upright && !isTablet {
                Button(action: onSettings) {
                    LandscapeChrome.circle(systemName: "gearshape")
                }
                .accessibilityLabel(NSLocalizedString("tab.settings", comment: ""))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 20)
                .padding(.bottom, LandscapeChrome.cornerBottomPadding(tablet: isTablet, insets: insets))
            }

            if showThemePicker {
                LandscapeThemePicker(offersClassic: upright, onClose: { showThemePicker = false })
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea(edges: upright ? .top : .all)
        .environment(\.colorScheme, .dark)
    }

    /// The headline, the one line and the seven consoles.
    private var pitchColumn: some View {
        VStack(spacing: 14) {
            Text(NSLocalizedString("library.empty.title", comment: ""))
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(DeviceWording.string("library.empty.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ConsoleIconRow()
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
    }

    /// The three steps, the call to action and the two notes.
    private var stepsColumn: some View {
        VStack(spacing: 12) {
            LandscapeChrome.card(nil) {
                stepRow(1, DeviceWording.string("library.empty.step1"))
                stepRow(2, NSLocalizedString("library.empty.step2", comment: ""))
                stepRow(3, NSLocalizedString("library.empty.step3", comment: ""))
            }
            LibraryImportCTA(action: onImport)
            Text(NSLocalizedString("library.empty.romHint", comment: ""))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(.orange.opacity(0.85))
                Text(NSLocalizedString("library.empty.legal", comment: ""))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.12))
            )
        }
    }

    private func stepRow(_ num: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(num)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.15))
                .clipShape(Circle())
            LibraryStepLabel(text: text, symbolTint: LibraryLandscapePalette.highlight)
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - The view

struct LibraryLandscapeView: View {
    /// An upright phone in a chosen look (2026-09-07): the bar in two rows
    /// under the status bar, the hero, then `uprightList` down to the tab
    /// bar, which stays (portrait keeps its navigation model, Settings is a
    /// tab, so no Settings circle here). Everything else is the landscape
    /// surface as it is.
    var upright: Bool = false
    /// The library's List, at its own density, for the upright surface. The
    /// library builds it because the rows are its own (their navigation link,
    /// their swipe to delete, the rename); this view only dresses the page.
    var uprightList: (() -> AnyView)? = nil
    /// How many games the library holds in all, before the search and the
    /// console filter (2026-09-07): with exactly ONE, the upright hero is the
    /// whole page and the List under it is not shown, so a player who has
    /// just imported his first game sees that game once, as the hero, and
    /// not again as the only row. Nil (the debug gallery) reads `games.count`.
    var libraryCount: Int? = nil
    /// The games, ALREADY in the library's sort order and search-filtered:
    /// this view shows a line, it does not decide what is on it.
    let games: [GameEntity]
    /// A skeleton tile leads the line while an import runs.
    let isImporting: Bool
    @Binding var sortOrder: LibraryView.SortOrder
    /// The console the "By console" sort narrows to, "" for all of them
    /// (2026-09-07); `consoles` are the ones the library holds, in order.
    @Binding var consoleFilter: String
    let consoles: [String]
    @Binding var searchText: String
    /// Whether the top bar offers the Retro story card and the RetroAchievements
    /// entry (the portrait cards' conditions, decided by the library).
    let showsStats: Bool
    let showsRA: Bool
    /// False while another tab is showing, which pauses the background.
    let isActive: Bool
    /// slot nil = start from the title screen; otherwise the slot to load.
    let onPlay: (GameEntity, Int?) -> Void
    let onOpenDetails: (GameEntity) -> Void
    let onRename: (GameEntity) -> Void
    let onDelete: (GameEntity) -> Void
    let onImport: () -> Void
    let onStats: () -> Void
    let onRA: () -> Void
    let onSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An iPad window: larger tiles, a wider search field, a bar that clears
    /// the status bar, and the Library · Settings pill at the bottom instead
    /// of the Settings circle (2026-09-08, see `LandscapeChrome.tabPill`).
    @TabletSurface private var isTablet
    @Environment(\.surfaceSafeAreaInsets) private var surfaceInsets

    @State private var selectedIndex = 0
    /// Observed so a theme change repaints this surface.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared
    /// The selected GAME, beside its index. The line re-sorts under the
    /// player's feet: Play stamps the game as last played before the cover
    /// opens, and under the default sort that moves it to the front, so the
    /// index the finger chose now names its neighbour. The identity is what
    /// was chosen; the index is re-found from it whenever the line changes.
    @State private var selectedID: String?
    /// The chosen game's stored path, kept across rotations and app kills
    /// (decided on device, 2026-09-05): under any sort but last-played, the game a
    /// player keeps coming back to would otherwise have to be scrolled to on
    /// every launch. The path is the identity that survives a reinstall of
    /// the store; the object id does not.
    @AppStorage("library.landscape.selectedGame") private var storedSelection: String = ""
    /// The finger's contribution while a drag is in progress, zero at rest.
    @State private var dragOffset: CGFloat = 0
    /// The notch last announced by a haptic tick during the current drag.
    @State private var tickedIndex: Int?
    @State private var playMenu: LibraryPlayMenuModel?
    @State private var showThemePicker = false
    @State private var showSortPicker = false
    @State private var newGameConfirm: GameEntity?
    @State private var saveTick = 0

    private let selectionHaptic = UISelectionFeedbackGenerator()

    /// One entry per tile: the skeleton first while importing, then the games.
    private struct Item: Identifiable {
        let id: String
        let game: GameEntity?
    }

    private var items: [Item] {
        var list: [Item] = []
        if isImporting { list.append(Item(id: "importing", game: nil)) }
        for game in games {
            list.append(Item(id: game.objectID.uriRepresentation().absoluteString, game: game))
        }
        return list
    }

    /// The line's identities in order, the value the re-sort watcher keys on.
    private var itemIDs: [String] { items.map(\.id) }

    /// Re-finds the chosen game after the line changed under it (a re-sort,
    /// a deletion, an import landing in front). Gone: the nearest index stays.
    private func realignSelection(to ids: [String]) {
        if let selectedID, let found = ids.firstIndex(of: selectedID) {
            selectedIndex = found
        } else {
            selectedIndex = min(selectedIndex, max(ids.count - 1, 0))
            selectedID = ids.indices.contains(selectedIndex) ? ids[selectedIndex] : nil
        }
    }

    private var selectedGame: GameEntity? {
        let list = items
        guard list.indices.contains(selectedIndex) else { return nil }
        return list[selectedIndex].game
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let side = isTablet ? Self.tabletTileSide(for: size) : Self.tileSide(forHeight: size.height)
            let geometry = LibraryCarouselGeometry(itemSide: side, count: items.count)
            // The library ignores the insets on a phone on its side on
            // purpose (header); an iPad shows a status bar in both
            // orientations and an upright phone shows one too, and the bar
            // clears it.
            let insets = LandscapeChrome.insets(surfaceInsets)
            ZStack {
                LibraryLandscapeBackground(isPaused: !isActive || reduceMotion, dimmed: upright)

                // Left and right run edge to edge; top and bottom keep a
                // margin (decided on device, 2026-09-04). The line, the caption and the
                // buttons share what is left between the two spacers. Upright,
                // the hero and the List take the height under the bar, and
                // the bottom is the tab bar's (the safe area is kept there).
                VStack(spacing: 0) {
                    if upright {
                        uprightTopBar
                            .padding(.horizontal, 24)
                            .padding(.top, LandscapeChrome.barTopPadding(tablet: isTablet, upright: true, insets: insets))
                        // The gaps, settled 2026-09-07 evening: the bar has no
                        // bottom padding of its own (two 40-point rows in a
                        // 90-point frame), the hero carries the SAME margin
                        // above and below itself, and the List adds nothing
                        // under a hero; without one, the List takes that
                        // margin so its distance to the search field is the
                        // hero's. One number, three places.
                        if themeStore.showsHero {
                            uprightHero
                                .padding(.horizontal, 24)
                                .padding(.vertical, Self.uprightGap)
                        }
                        if let uprightList, showsUprightList {
                            uprightList()
                                .padding(.top, themeStore.showsHero ? 0 : Self.uprightGap)
                        } else {
                            Spacer(minLength: 0)
                        }
                    } else {
                        topBar
                            .padding(.horizontal, 24)
                            .padding(.top, LandscapeChrome.barTopPadding(tablet: isTablet, insets: insets))
                        Spacer(minLength: 6)
                        carousel(geometry: geometry, width: size.width,
                                 height: side * LibraryCarouselGeometry.selectedScale + 8)
                        caption
                            .frame(height: 44)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                        // Settings stands at the right end of this row, level with
                        // Play and (i) and under the bar's plus (2026-09-07). The row
                        // spans the width so the overlay's trailing edge is the
                        // screen's, 24 points in like the bar's.
                        actionRow
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .trailing) {
                                // An iPad has the pill at the bottom for
                                // that (2026-09-08).
                                if !isTablet {
                                    settingsButton.padding(.trailing, 24)
                                }
                            }
                            .padding(.top, 6)
                        Spacer(minLength: 6)
                    }
                }
                .padding(.bottom, upright ? 0 : 22)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isTablet {
                        LandscapeChrome.tabPill(selected: .library, insets: insets) { tab in
                            if tab == .settings { onSettings() }
                        }
                    }
                }

                if let playMenu {
                    LibraryPlayMenu(model: playMenu,
                                    onPick: { slot in pick(slot: slot, for: playMenu.game) },
                                    onClose: { self.playMenu = nil })
                }
                if showThemePicker {
                    LandscapeThemePicker(offersClassic: upright, onClose: { showThemePicker = false })
                }
                if showSortPicker {
                    LibrarySortPicker(upright: upright, sortOrder: $sortOrder, consoleFilter: $consoleFilter,
                                      consoles: consoles, onClose: { showSortPicker = false })
                }
            }
            .frame(width: size.width, height: size.height)
        }
        // Upright the bottom edge is the tab bar's and is kept, so the List
        // scrolls clear of it; on its side the surface runs edge to edge.
        .ignoresSafeArea(edges: upright ? .top : .all)
        // Scoped to this subtree, NOT `preferredColorScheme`, which would
        // reach the whole window and darken Settings and Game Details too:
        // the materials and the system controls here read as dark whatever
        // the phone's appearance, because the ground under them always is.
        .environment(\.colorScheme, .dark)
        .onChange(of: sortOrder) { _ in
            selectedIndex = 0
            selectedID = itemIDs.first
            dragOffset = 0
        }
        .onChange(of: consoleFilter) { _ in
            selectedIndex = 0
            selectedID = itemIDs.first
            dragOffset = 0
        }
        .onChange(of: itemIDs) { ids in
            realignSelection(to: ids)
        }
        .onAppear {
            guard selectedID == nil else { return }
            let list = items
            // Under the last-played sort the chosen game IS the game played
            // last, whichever orientation played it: the first of the line,
            // which is also the upright hero's game. The stored path serves
            // the OTHER sorts only, as its note always said; reading it here
            // too made the rack open on a cover picked another day while the
            // hero showed the game played this morning (2026-09-07).
            if sortOrder == .lastPlayed {
                selectedID = list.first?.id
            } else if !storedSelection.isEmpty,
               let index = list.firstIndex(where: { $0.game?.romFilePath == storedSelection }) {
                selectedIndex = index
                selectedID = list[index].id
            } else {
                selectedID = list.first?.id
            }
        }
        .onChange(of: selectedID) { id in
            guard let id, let path = items.first(where: { $0.id == id })?.game?.romFilePath else { return }
            storedSelection = path
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveStatesDidChange)) { _ in
            saveTick &+= 1
        }
        .alert(NSLocalizedString("details.newGame.confirm.title", comment: ""),
               isPresented: Binding(get: { newGameConfirm != nil },
                                    set: { if !$0 { newGameConfirm = nil } })) {
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) { newGameConfirm = nil }
            Button(NSLocalizedString("details.newGame", comment: "")) {
                if let game = newGameConfirm { onPlay(game, nil) }
                newGameConfirm = nil
            }
        } message: {
            Text(NSLocalizedString("details.newGame.confirm.message", comment: ""))
        }
    }

    /// The tile side from the screen height: everything else on the surface
    /// (the two margins, top bar, caption, buttons, the spacers' minimum)
    /// takes a fixed 210 points, and the centred tile grows by the selected
    /// scale, so this is what is left. Capped so a Pro Max does not turn a
    /// cover into a poster; floored so a search with the keyboard up still
    /// draws something. A quarter smaller than the first cut, to buy the
    /// margins (decided on device, 2026-09-04).
    static func tileSide(forHeight height: CGFloat) -> CGFloat {
        let available = (height - 210) / LibraryCarouselGeometry.selectedScale
        // The 0.9 is the second review's "ten percent smaller", applied after
        // the bounds so both ends move with it.
        return min(max(available, 100), 165) * 0.9
    }

    /// The tile side on an iPad (2026-09-05), from BOTH sides of the window:
    /// the height as on a phone, with a taller chrome budget for the bar's
    /// status-bar clearance, and the width too, because an upright iPad mini
    /// is 744 points wide and a rack of 300-point covers would show one and
    /// two halves. The cap nearly doubles the phone's: a 148-point cover on a
    /// 1376-point window is a stamp.
    static let tabletTileCap: CGFloat = 300
    static func tabletTileSide(for size: CGSize) -> CGFloat {
        let byHeight = (size.height - 260) / LibraryCarouselGeometry.selectedScale
        let byWidth = size.width / 3.2
        return min(max(min(byHeight, byWidth), 160), tabletTileCap)
    }

    // MARK: Top bar

    /// The bar on an upright phone: the same controls in two rows, because
    /// a 390-point width does not hold a sort circle, a search field and five
    /// circles. Sort at the left and the palette, the story card,
    /// RetroAchievements and the plus at the right on the first line, as the
    /// List's own bar has them; the search field on the second line, at the
    /// left, with the controller badge at its right (2026-09-07).
    private var uprightTopBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                sortButton
                Spacer(minLength: 8)
                barTrailingButtons
            }
            HStack(spacing: 10) {
                searchField
                    .frame(maxWidth: 300)
                Spacer(minLength: 8)
                ControllerStatusBadge(tint: .white)
            }
        }
        .frame(height: 90)
    }

    /// Opens the sort panel (2026-09-07). A system menu with the console
    /// submenu grew taller than a phone on its side and was pushed back up by
    /// the system after opening, a visible jump; the panel lays itself out
    /// for the screen instead, and can show the consoles' drawings and a
    /// highlighted row, which a menu cannot.
    private var sortButton: some View {
        Button {
            Haptics.tap()
            showSortPicker = true
        } label: {
            LandscapeChrome.circle(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(sortOrder.displayName)
    }

    /// The look of every landscape surface, chosen here, left of the Retro
    /// story card (decided on device, 2026-09-05); then the card, the trophy and the plus.
    @ViewBuilder
    private var barTrailingButtons: some View {
        Button {
            Haptics.tap()
            showThemePicker = true
        } label: {
            LandscapeChrome.circle(systemName: "paintpalette")
        }
        .accessibilityLabel(themeStore.theme.name)

        if showsStats {
            Button(action: onStats) { LandscapeChrome.circle(systemName: "chart.bar.xaxis") }
                .accessibilityLabel(NSLocalizedString("library.stats.title", comment: ""))
        }
        if showsRA {
            Button(action: onRA) { LandscapeChrome.circle(systemName: "trophy") }
                .accessibilityLabel("RetroAchievements")
        }
        Button(action: onImport) { LandscapeChrome.circle(systemName: "plus") }
            .accessibilityLabel(NSLocalizedString("guide.importRom.title", comment: ""))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            sortButton

            searchField
                .frame(maxWidth: isTablet ? 360 : 300)

            Spacer(minLength: 8)

            ControllerStatusBadge(tint: .white)

            barTrailingButtons
        }
        .frame(height: 40)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.85))
            TextField(NSLocalizedString("library.search", comment: ""), text: $searchText)
                .foregroundStyle(.white)
                .tint(LibraryLandscapePalette.highlight)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.78))
                }
                .accessibilityLabel(NSLocalizedString("common.cancel", comment: ""))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(LandscapeChrome.glass(Capsule()))
    }


    // MARK: The line

    private func carousel(geometry: LibraryCarouselGeometry, width: CGFloat, height: CGFloat) -> some View {
        let base = geometry.offset(forIndex: selectedIndex)
        let offset = base + dragOffset
        let progress = geometry.progress(forOffset: offset)
        let live = geometry.nearestIndex(forOffset: offset)
        let radius = geometry.visibleRadius(forWidth: width)
        let list = items

        // Every cover is placed from its distance to the centre, so the
        // rack re-shapes continuously under the finger; the modifiers are
        // all animatable, so the spring to a notch moves, turns and scales
        // each cover along the way. Nearer covers draw above further ones.
        return ZStack {
            // The selected cover's glow, as ONE layer that never moves: a
            // blurred gradient square at the centre, behind everything. A
            // shadow on the cover itself was re-rendered on every frame of
            // the spring, and on a 3D-transformed layer at that; this is
            // rasterised once and composited.
            RoundedRectangle(cornerRadius: geometry.itemSide * 0.11, style: .continuous)
                .fill(LibraryLandscapePalette.accentGradient)
                .frame(width: geometry.itemSide * LibraryCarouselGeometry.selectedScale,
                       height: geometry.itemSide * LibraryCarouselGeometry.selectedScale)
                .blur(radius: 22)
                .opacity(list.isEmpty ? 0 : 0.6)
                .zIndex(-1000)
                .allowsHitTesting(false)
            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                if abs(index - live) <= radius {
                    let distance = CGFloat(index) - progress
                    tile(item, index: index, side: geometry.itemSide, isSelected: index == live)
                        .scaleEffect(geometry.scale(forDistance: distance))
                        .rotation3DEffect(.degrees(geometry.angle(forDistance: distance)),
                                          axis: (x: 0, y: 1, z: 0),
                                          perspective: 0.7)
                        .offset(x: geometry.x(forDistance: distance))
                        .zIndex(Double(-abs(distance)))
                }
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .local)
                .onChanged { value in
                    if playMenu != nil || showThemePicker || showSortPicker { return }
                    dragOffset = geometry.rubberBandedTranslation(value.translation.width, base: base)
                    let under = geometry.nearestIndex(forOffset: base + dragOffset)
                    if under != tickedIndex {
                        tickedIndex = under
                        selectionHaptic.selectionChanged()
                    }
                }
                .onEnded { value in
                    if playMenu != nil || showThemePicker || showSortPicker { return }
                    let released = base + value.translation.width
                    let projected = base + value.predictedEndTranslation.width
                    let target = geometry.targetIndex(releasedAt: released, projectedOffset: projected)
                    tickedIndex = nil
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                        selectedIndex = target
                        selectedID = list.indices.contains(target) ? list[target].id : nil
                        dragOffset = 0
                    }
                }
        )
    }

    // MARK: The hero (upright)

    /// The cover side of the hero, and the height of its card.
    static let heroCoverSide: CGFloat = 120

    /// The one vertical gap of the upright page: above and below the hero,
    /// or above the List when there is no hero.
    static let uprightGap: CGFloat = 14

    /// Whether the List shows under the hero: always, except when the hero
    /// is on and the whole library is that one game. While an import runs
    /// the List comes back whatever the count, for its skeleton row: that
    /// row is the upright surface's only sign of the wait, and hidden with
    /// the List a second game imported into a library of one showed nothing
    /// until it appeared (2026-09-08).
    private var showsUprightList: Bool {
        guard themeStore.showsHero, heroGame != nil else { return true }
        if isImporting { return true }
        return (libraryCount ?? games.count) != 1
    }

    /// Upright, the game to put first is the one played LAST, whatever the
    /// sort: the hero is "continue", the way a console home shows the last
    /// game before the shelf. With nothing played yet, the first of the list.
    private var heroGame: GameEntity? {
        let played = games.filter { $0.lastPlayedAt != nil }
        return played.max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) } ?? games.first
    }

    /// One glass card: the cover with its ring on the left; on the right the
    /// title with the row's console tag, "played 2 days ago" and the play
    /// time on their own lines as the rows show them (2026-09-07: one joined
    /// line was cropped, and a "Last played" label lied while a search
    /// narrowed the hero to the games found, which is kept on purpose), then
    /// Play and (i). The same Play the line offers (the slot choice when a
    /// save exists), the same (i). Under it the library's List does the finding.
    @ViewBuilder
    private var uprightHero: some View {
        if let game = heroGame {
            HStack(alignment: .top, spacing: 14) {
                LibraryLandscapeTile(game: game, side: Self.heroCoverSide, isSelected: true,
                                     saveTick: saveTick, showsConsoleTag: false)
                    .onTapGesture {
                        Haptics.tap()
                        onOpenDetails(game)
                    }
                    // Rename and delete on a long press, as on the rack's
                    // covers and the rows (2026-09-07).
                    .contextMenu {
                        Button {
                            onRename(game)
                        } label: {
                            Label(NSLocalizedString("details.rename", comment: ""), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            onDelete(game)
                        } label: {
                            Label(NSLocalizedString("details.delete", comment: ""), systemImage: "trash")
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(game.title ?? NSLocalizedString("library.untitled", comment: ""))
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        if let system = game.systemType {
                            ConsoleTagBadge(systemType: system, drawing: true)
                        }
                    }
                    if let ago = Self.playedAgoLine(for: game) {
                        Text(ago)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    if let time = Self.playTimeLine(for: game) {
                        Text(time)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    heroActions(game)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.heroCoverSide)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(LandscapeChrome.cardFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(LandscapeChrome.cardStroke), lineWidth: 1)
            )
            .id(game.objectID)
            .animation(.easeOut(duration: 0.18), value: game.objectID)
        }
    }

    /// Play and (i) at the hero's size: a shorter capsule and a 40-point circle.
    private func heroActions(_ game: GameEntity) -> some View {
        HStack(spacing: 10) {
            Button {
                Haptics.tap()
                playTapped(game)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text(NSLocalizedString("details.play", comment: ""))
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Capsule().fill(LibraryLandscapePalette.accentGradient))
                .shadow(color: LibraryLandscapePalette.accent.opacity(0.55), radius: 12, y: 3)
            }
            Button {
                Haptics.tap()
                onOpenDetails(game)
            } label: {
                Image(systemName: "info")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(LandscapeChrome.glass(Circle()))
                    .contentShape(Circle())
            }
            .accessibilityLabel(game.title ?? "")
        }
    }

    @ViewBuilder
    private func tile(_ item: Item, index: Int, side: CGFloat, isSelected: Bool) -> some View {
        if let game = item.game {
            LibraryLandscapeTile(game: game, side: side, isSelected: isSelected, saveTick: saveTick)
                .onTapGesture { select(index) }
                .contextMenu {
                    Button {
                        onRename(game)
                    } label: {
                        Label(NSLocalizedString("details.rename", comment: ""), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete(game)
                    } label: {
                        Label(NSLocalizedString("details.delete", comment: ""), systemImage: "trash")
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            SkeletonBox(cornerRadius: side * 0.11)
                .frame(width: side, height: side)
                .accessibilityLabel(NSLocalizedString("library.importing", comment: ""))
        }
    }

    private func select(_ index: Int) {
        guard index != selectedIndex else { return }
        Haptics.tap()
        let list = items
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
            selectedIndex = index
            selectedID = list.indices.contains(index) ? list[index].id : nil
            dragOffset = 0
        }
    }

    // MARK: Caption and actions

    /// Title and the two times, under the centred game only. The tiles carry
    /// no text, so the line stays a line.
    @ViewBuilder
    private var caption: some View {
        if let game = selectedGame {
            VStack(spacing: 3) {
                Text(game.title ?? NSLocalizedString("library.untitled", comment: ""))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                let meta = Self.metaLine(for: game)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .id(game.objectID)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.18), value: game.objectID)
        } else {
            Color.clear
        }
    }

    /// "Played 2 days ago · 3h 12m played", each half only when it exists.
    /// Same keys and thresholds as the portrait row.
    static func metaLine(for game: GameEntity) -> String {
        [playedAgoLine(for: game), playTimeLine(for: game)].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Played 2 days ago", or nil when never played.
    static func playedAgoLine(for game: GameEntity) -> String? {
        guard let lastPlayed = game.lastPlayedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let ago = formatter.localizedString(for: lastPlayed, relativeTo: Date())
        return String(format: NSLocalizedString("library.played.ago", comment: ""), ago)
    }

    /// "3h 12m played", or nil under a minute.
    static func playTimeLine(for game: GameEntity) -> String? {
        guard let path = game.romFilePath else { return nil }
        let seconds = PromptTracker.shared.gamePlayTime(
            romName: BatterySaveImporter.romBasename(forStoredFilename: path))
        guard seconds >= 60 else { return nil }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return String(format: NSLocalizedString("library.playTime", comment: ""), "\(hours)", "\(minutes)")
        }
        return String(format: NSLocalizedString("library.playTime.minutes", comment: ""), "\(minutes)")
    }

    @ViewBuilder
    private var actionRow: some View {
        if let game = selectedGame {
            HStack(spacing: 12) {
                Button {
                    Haptics.tap()
                    playTapped(game)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(NSLocalizedString("details.play", comment: ""))
                            .fontWeight(.semibold)
                    }
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .frame(height: 44)
                    .background(
                        Capsule().fill(LibraryLandscapePalette.accentGradient)
                    )
                    .shadow(color: LibraryLandscapePalette.accent.opacity(0.55), radius: 14, y: 4)
                }

                Button {
                    Haptics.tap()
                    onOpenDetails(game)
                } label: {
                    Image(systemName: "info")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(LandscapeChrome.glass(Circle()))
                        .contentShape(Circle())
                }
                .accessibilityLabel(game.title ?? "")
            }
        } else {
            Color.clear.frame(height: 44)
        }
    }

    /// Play with no quick-save anywhere starts the game at once; with one, the
    /// slot choice opens, the same list Game Details shows.
    private func playTapped(_ game: GameEntity) {
        guard let path = game.romFilePath else { return }
        let romName = BatterySaveImporter.romBasename(forStoredFilename: path)
        guard !romName.isEmpty else {
            onPlay(game, nil)
            return
        }
        let model = LibraryPlayMenuModel(game: game, manager: SaveStateManager(romName: romName))
        if model.rows.isEmpty {
            onPlay(game, nil)
        } else {
            playMenu = model
        }
    }

    private func pick(slot: Int?, for game: GameEntity) {
        playMenu = nil
        if let slot {
            onPlay(game, slot)
        } else {
            // Same guard as Game Details: a fresh start with a session to
            // resume asks first.
            newGameConfirm = game
        }
    }

    // MARK: Settings

    /// Settings, at the right end of the Play row, level with Play and (i)
    /// and under the bar's plus (2026-09-07; it used to sit in the bottom
    /// corner). No Library half: this screen IS the library (decided on device, 2026-09-04).
    private var settingsButton: some View {
        Button(action: onSettings) {
            LandscapeChrome.circle(systemName: "gearshape")
        }
        .accessibilityLabel(NSLocalizedString("tab.settings", comment: ""))
    }
}

// MARK: - One tile

/// A square cover: the box art (user-picked, RetroAchievements or downloaded,
/// in the library's own priority) else the newest quick-save screenshot,
/// filled and centre-cropped to the square. The portrait row keeps each
/// image's own ratio inside a square cap; this view crops instead, so the
/// line reads as one line (decided on device, 2026-09-04).
///
/// Small artwork is the exception. A RetroAchievements cover is the game's
/// BADGE, 96 pixels square by the service's own standard (measured 2026-09-04
/// on media.retroachievements.org; rc_client exposes no larger image and the
/// box art proper needs a web API key we do not hold), and 96 pixels stretched
/// over a 140-point square on a 3x screen is a fourfold upscale that reads as
/// blur. Such an image is drawn the way small album art is: crisp at a size
/// its pixels can carry, over a blurred and darkened copy of itself filling
/// the square.
struct LibraryLandscapeTile: View {
    @ObservedObject var game: GameEntity
    let side: CGFloat
    let isSelected: Bool
    /// Bumped by the parent when a quick-save lands, so the screenshot re-reads.
    let saveTick: Int
    /// The console's drawing in the corner; the upright hero says the console
    /// beside its title instead (2026-09-07).
    var showsConsoleTag: Bool = true
    /// Observed so a theme change repaints this surface.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    @Environment(\.displayScale) private var displayScale
    @State private var image: LibraryLandscapeCover?

    private var radius: CGFloat { side * 0.11 }

    private var loadKey: String {
        "\((game.lastPlayedAt ?? .distantPast).timeIntervalSinceReferenceDate)#\(saveTick)#\(game.coverType ?? "")"
    }

    /// Artwork whose pixels cover less than half the square's pixels gets the
    /// backdrop treatment. Screenshots never do: they are pixel art and are
    /// drawn without interpolation, which is their look.
    private func isSmallArtwork(_ cover: LibraryLandscapeCover) -> Bool {
        guard !cover.isPixelArt else { return false }
        let longest = max(cover.image.size.width, cover.image.size.height) * cover.image.scale
        return longest < side * displayScale * 0.5
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white.opacity(0.07))
            if let image {
                if isSmallArtwork(image), let backdrop = image.backdrop {
                    // The backdrop was blurred ONCE at load (a tiny
                    // downscale, see `LibraryLandscapeCover`); a live
                    // `.blur` here was re-filtered on every animated frame.
                    Image(uiImage: backdrop)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                        .overlay(Color.black.opacity(0.28))
                    Image(uiImage: image.image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side * 0.6, height: side * 0.6)
                        .clipShape(RoundedRectangle(cornerRadius: side * 0.05, style: .continuous))
                } else {
                    Image(uiImage: image.image)
                        .resizable()
                        .interpolation(image.isPixelArt ? .none : .medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                }
            } else {
                Image(systemName: "gamecontroller")
                    .font(.system(size: side * 0.3, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(alignment: .topLeading) {
            // The console's own drawing, the one the stats card and the
            // website use, very small, on a near-opaque dark pill so it reads
            // on any art.
            if showsConsoleTag, let system = game.systemType {
                Image("console-\(system)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: side * 0.1, height: side * 0.075)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.black.opacity(0.8))
                    )
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LibraryLandscapePalette.accentGradient,
                              lineWidth: isSelected ? 3 : 0)
        )
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .accessibilityLabel(game.title ?? NSLocalizedString("library.untitled", comment: ""))
        .task(id: loadKey) {
            // Read the managed object on the main actor, decode on a
            // background task with plain values only.
            let filename = game.romFilePath
            let hash = game.romHash
            let coverType = game.coverType
            // A demo game's cover is in the bundle (Presentation mode).
            if let demo = LibraryPresentation.cover(forROMPath: filename) {
                image = LibraryLandscapeCover(image: demo, isPixelArt: false)
                return
            }
            let maxPixels = side * LibraryCarouselGeometry.selectedScale * displayScale
            let loaded = await Task.detached(priority: .userInitiated) {
                LibraryLandscapeCover.load(filename: filename, romHash: hash, coverType: coverType,
                                           maxPixels: maxPixels)
            }.value
            image = loaded
        }
    }
}

/// The decoded cover and whether it is pixel art (a quick-save screenshot,
/// drawn without interpolation like everywhere else) or artwork.
struct LibraryLandscapeCover {
    let image: UIImage
    let isPixelArt: Bool
    /// For artwork only: the same image shrunk to a few pixels, which is a
    /// blur for free once it is drawn large with interpolation. Made at load,
    /// off the main thread, so the tile never runs a filter.
    let backdrop: UIImage?

    init(image: UIImage, isPixelArt: Bool) {
        self.image = image
        self.isPixelArt = isPixelArt
        self.backdrop = isPixelArt ? nil : Self.shrunk(image, to: 10)
    }

    private static func shrunk(_ image: UIImage, to pixels: CGFloat) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: pixels, height: pixels)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Artwork no larger than the square it will fill, in pixels, drawn once
    /// here so it is DECODED here too. A cover file is up to 1024 pixels a
    /// side; kept at that size, fifteen drawn tiles held tens of megabytes
    /// and the decode ran on the main thread at first draw (audit,
    /// 2026-09-05). Screenshots are pixel art a few hundred pixels wide and
    /// pass through untouched.
    static func fitted(_ image: UIImage, maxPixels: CGFloat) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > 0 else { return image }
        let factor = min(1, maxPixels / longest)
        let target = CGSize(width: (pixelSize.width * factor).rounded(), height: (pixelSize.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// The same chain as `GameCoverView`: cover file on disk, else the
    /// auto-save preview, else the newest manual slot's. Every branch is a
    /// local file. `maxPixels` is the square's pixel side, the size artwork
    /// is decoded to.
    static func load(filename: String?, romHash: String?, coverType: String?,
                     maxPixels: CGFloat) -> LibraryLandscapeCover? {
        if let url = BoxArtManager.shared.coverFileURL(forROMHash: romHash, coverType: coverType),
           let art = UIImage(contentsOfFile: url.path) {
            return LibraryLandscapeCover(image: fitted(art, maxPixels: maxPixels), isPixelArt: false)
        }
        guard let filename else { return nil }
        let romName = BatterySaveImporter.romBasename(forStoredFilename: filename)
        guard !romName.isEmpty else { return nil }
        let manager = SaveStateManager(romName: romName)
        if let shot = manager.loadPreviewImage(slot: SaveStateManager.autoSaveSlotIndex) {
            return LibraryLandscapeCover(image: shot, isPixelArt: true)
        }
        let newest = manager.allManualSlots()
            .filter { $0.exists }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .first
        if let newest, let shot = manager.loadPreviewImage(slot: newest.slotIndex) {
            return LibraryLandscapeCover(image: shot, isPixelArt: true)
        }
        return nil
    }
}

// MARK: - The play menu

/// What the Play button offers for one game: resume the session (the auto
/// slot), each quick-save that exists, then a fresh start. Built when the
/// button is tapped, from the same manager Game Details reads.
struct LibraryPlayMenuModel {
    struct Row: Identifiable {
        /// nil = start from the title screen.
        let slot: Int?
        let title: String
        let subtitle: String?
        let preview: UIImage?
        var id: String { slot.map { String($0) } ?? "fresh" }
    }

    let game: GameEntity
    let rows: [Row]

    init(game: GameEntity, manager: SaveStateManager) {
        self.game = game
        var rows: [Row] = []
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let auto = manager.autoSaveSlot()
        if auto.exists {
            rows.append(Row(slot: auto.slotIndex,
                            title: NSLocalizedString("details.continue", comment: ""),
                            subtitle: auto.date.map { formatter.string(from: $0) },
                            preview: manager.loadPreviewImage(slot: auto.slotIndex)))
        }
        for slot in manager.allManualSlots() where slot.exists {
            rows.append(Row(slot: slot.slotIndex,
                            title: String(format: NSLocalizedString("overlay.slot", comment: ""), "\(slot.slotIndex)"),
                            subtitle: slot.date.map { formatter.string(from: $0) },
                            preview: manager.loadPreviewImage(slot: slot.slotIndex)))
        }
        // Only offered beside a save: with nothing to load, Play starts the
        // game directly and this list never opens.
        if !rows.isEmpty {
            rows.append(Row(slot: nil,
                            title: NSLocalizedString("details.newGame", comment: ""),
                            subtitle: nil,
                            preview: nil))
        }
        self.rows = rows
    }
}

/// The slot choice, a small dark panel over the surface. Each row is the Game
/// Details quick-save row at a smaller size: preview, name, date, arrow.
struct LibraryPlayMenu: View {
    let model: LibraryPlayMenuModel
    let onPick: (Int?) -> Void
    let onClose: () -> Void
    /// Observed so a theme change repaints this surface.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
                .accessibilityLabel(NSLocalizedString("common.cancel", comment: ""))

            VStack(spacing: 0) {
                Text(model.game.title ?? NSLocalizedString("library.untitled", comment: ""))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().overlay(Color.white.opacity(0.12))
                    }
                    Button {
                        Haptics.tap()
                        onPick(row.slot)
                    } label: {
                        HStack(spacing: 12) {
                            if let preview = row.preview {
                                Image(uiImage: preview)
                                    .resizable()
                                    .interpolation(.none)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 48, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            } else {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                                    .frame(width: 48, height: 36)
                                    .overlay(
                                        Image(systemName: row.slot == nil ? "play.fill" : "square.dashed")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.78))
                                    )
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if let subtitle = row.subtitle {
                                    Text(subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.78))
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(LibraryLandscapePalette.highlight)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                    }
                }
                Color.clear.frame(height: 6)
            }
            .frame(width: 340)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.08, blue: 0.16).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        }
        .transition(.opacity)
    }
}

// MARK: - The sort panel

/// The sort panel of every library bar (2026-09-07): the three plain
/// orders and "All consoles", then one row per console the library holds,
/// its drawing before its name. The chosen row is highlighted, no check.
/// One column upright; two on a phone on its side, orders left and consoles
/// right, so the panel never outgrows the screen the way the system menu did.
struct LibrarySortPicker: View {
    let upright: Bool
    @Binding var sortOrder: LibraryView.SortOrder
    @Binding var consoleFilter: String
    let consoles: [String]
    let onClose: () -> Void

    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
                .accessibilityLabel(NSLocalizedString("common.cancel", comment: ""))

            Group {
                if upright {
                    VStack(spacing: 4) {
                        orders
                        Divider().overlay(Color.white.opacity(0.12)).padding(.vertical, 4)
                        consoleRows
                    }
                    .frame(width: 280)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 4) { orders }
                            .frame(width: 220)
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                        VStack(spacing: 4) { consoleRows }
                            .frame(width: 240)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.10).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        }
        .transition(.opacity)
    }

    /// Last played, A-Z, date added, then every console together.
    @ViewBuilder
    private var orders: some View {
        ForEach(LibraryView.SortOrder.allCases.filter { $0 != .byConsole }, id: \.self) { order in
            row(selected: sortOrder == order) {
                sortOrder = order
                consoleFilter = ""
            } label: {
                Text(order.displayName)
            }
        }
        row(selected: sortOrder == .byConsole && consoleFilter.isEmpty) {
            sortOrder = .byConsole
            consoleFilter = ""
        } label: {
            Text(NSLocalizedString("library.sort.allConsoles", comment: ""))
        }
    }

    /// One row per console in the library, its drawing then its name.
    @ViewBuilder
    private var consoleRows: some View {
        ForEach(consoles, id: \.self) { console in
            row(selected: sortOrder == .byConsole && consoleFilter == console) {
                sortOrder = .byConsole
                consoleFilter = console
            } label: {
                HStack(spacing: 10) {
                    Image("console-\(console)")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 18)
                        .accessibilityHidden(true)
                    Text(SystemColor.name(console))
                }
            }
        }
    }

    /// A row: its label at the left, the glass highlight when chosen.
    private func row<Content: View>(selected: Bool, action: @escaping () -> Void,
                                    @ViewBuilder label: () -> Content) -> some View {
        Button {
            Haptics.tap()
            action()
            onClose()
        } label: {
            HStack {
                label()
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.white.opacity(LandscapeChrome.cardFill) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - The theme picker

/// The five looks as rows: a swatch of the look's ground, accent and
/// highlight, the name, a check on the current one. Tapping a row applies it
/// at once, everywhere in landscape, and closes the panel.
///
/// On an upright phone (`offersClassic`, 2026-09-07) a "Classic" row leads
/// the list: the List the library always had. Picking it keeps the landscape
/// look as it is; picking a look below it turns the upright surface on in
/// that look, for both orientations.
struct LandscapeThemePicker: View {
    var offersClassic: Bool = false
    let onClose: () -> Void

    @ObservedObject private var store = LandscapeThemeStore.shared

    /// The check sits on Classic while the upright phone shows the List, and
    /// on the look otherwise; on a phone on its side, always on the look.
    private var classicChecked: Bool { offersClassic && store.portraitClassic }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
                .accessibilityLabel(NSLocalizedString("common.cancel", comment: ""))

            VStack(spacing: 0) {
                if offersClassic {
                    let name = NSLocalizedString("library.theme.classic", comment: "")
                    Button {
                        Haptics.tap()
                        store.portraitClassic = true
                        onClose()
                    } label: {
                        HStack(spacing: 12) {
                            classicSwatch
                            Text(name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                            Spacer(minLength: 8)
                            if classicChecked {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(classicChecked ? [.isButton, .isSelected] : .isButton)
                    Divider().overlay(Color.white.opacity(0.12))
                }
                ForEach(Array(LandscapeTheme.allCases.enumerated()), id: \.element) { index, theme in
                    if index > 0 {
                        Divider().overlay(Color.white.opacity(0.12))
                    }
                    let checked = store.theme == theme && !classicChecked
                    Button {
                        Haptics.tap()
                        store.theme = theme
                        if offersClassic { store.portraitClassic = false }
                        onClose()
                    } label: {
                        HStack(spacing: 12) {
                            swatch(theme)
                            Text(theme.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                            Spacer(minLength: 8)
                            if checked {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(theme.highlight)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(theme.name)
                    .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
                }
                if offersClassic, !store.portraitClassic {
                    // The last game played above the List, on or off
                    // (2026-09-07); the upright phone only, the rack has no
                    // hero, and Classic has none either, so the row hides
                    // with it.
                    Divider().overlay(Color.white.opacity(0.12))
                    Toggle(isOn: $store.showsHero) {
                        Text(NSLocalizedString("library.hero.toggle", comment: ""))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }
                    .tint(store.theme.accent)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                }
                Color.clear.frame(height: 6)
            }
            .padding(.top, 6)
            .frame(width: 280)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.10).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        }
        .transition(.opacity)
    }

    /// The List's swatch: the system's light ground with a grey ring, the
    /// one look that is not a dark one.
    private var classicSwatch: some View {
        Circle()
            .fill(Color(white: 0.95))
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(Color(white: 0.6), lineWidth: 4))
            .accessibilityHidden(true)
    }

    /// The look in one circle: its ground, with its two accents as the ring.
    private func swatch(_ theme: LandscapeTheme) -> some View {
        Circle()
            .fill(theme.ground)
            .frame(width: 30, height: 30)
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(colors: [theme.accent, theme.highlight],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 4)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Background

/// The moving ground: four glows of the two brand hues drifting slowly,
/// under a slow particle drift, over a film of grain. Paused under Reduce
/// Motion (a still frame) and when the surface is not showing.
///
/// ONE CLOCK FOR EVERY COPY (decided on device, 2026-09-04): every landscape surface
/// draws its own ground, and a push used to start a fresh one from its rest
/// positions, a visible jump. The glows' positions are now a function of the
/// wall clock, so any two copies show the same frame at the same instant and
/// a push, a pop or a sheet changes nothing on the ground; the particle
/// emitter starts pre-populated by Core Animation's default, so it does not
/// fade in either.
///
/// HOW IT MOVES MATTERS MORE THAN HOW IT LOOKS, on the phone's heat. The
/// first cut redrew a full-screen canvas of four radial gradients thirty
/// times a second, and an iPhone 14 Pro warmed up sitting on this screen.
/// Each glow is now its own layer, rasterised ONCE, and only its position
/// changes: the clock ticks at 30 frames a second, and each tick moves four
/// finished textures, which is the cheapest thing a GPU does. The path is a
/// slow cosine back-and-forth between two points per glow, with four
/// different periods, so the picture never repeats.
///
/// Two things keep the glows from looking like a smear. Each is a radial
/// gradient with a bright core and a falloff that eases out through four
/// stops rather than fading linearly, which is what reads as a light rather
/// than a stain. And a static grain, tiled at one pixel per point over the
/// whole ground at a few percent, breaks the banding an 8-bit gradient shows
/// across a wide dark falloff: the eye reads the dither as texture.
struct LibraryLandscapeBackground: View {
    let isPaused: Bool
    /// Under a page of content (a list, cards, a sheet, the upright library)
    /// the ground carries a light black film (2026-09-07): the glows stayed
    /// pretty and got in the way of grey type. The rack of covers keeps the
    /// full ground, its covers carry their own contrast.
    var dimmed: Bool = false

    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    private struct Blob: Identifiable {
        enum Role { case accent, highlight }

        let id: Int
        let role: Role
        /// The two ends of its travel, as fractions of the size.
        let from: CGPoint
        let to: CGPoint
        /// Seconds from one end to the other.
        let period: Double
        /// Radius as a fraction of the height.
        let radius: CGFloat
        let opacity: Double

        /// Where the glow is at wall-clock time `t`: a cosine ease from
        /// `from` to `to` and back, one round trip every two periods.
        func position(at t: Double) -> CGPoint {
            let u = (1 - cos(t / (period * 2) * 2 * .pi)) / 2
            return CGPoint(x: from.x + (to.x - from.x) * u,
                           y: from.y + (to.y - from.y) * u)
        }
    }

    private static let blobs: [Blob] = [
        Blob(id: 0, role: .accent,
             from: CGPoint(x: 0.12, y: 0.20), to: CGPoint(x: 0.34, y: 0.55),
             period: 31, radius: 0.55, opacity: 0.7),
        Blob(id: 1, role: .highlight,
             from: CGPoint(x: 0.88, y: 0.85), to: CGPoint(x: 0.66, y: 0.55),
             period: 41, radius: 0.5, opacity: 0.5),
        Blob(id: 2, role: .accent,
             from: CGPoint(x: 0.92, y: 0.05), to: CGPoint(x: 0.74, y: 0.28),
             period: 47, radius: 0.42, opacity: 0.5),
        Blob(id: 3, role: .highlight,
             from: CGPoint(x: 0.18, y: 0.95), to: CGPoint(x: 0.42, y: 0.80),
             period: 37, radius: 0.38, opacity: 0.4),
    ]

    var body: some View {
        let theme = themeStore.theme
        return GeometryReader { geo in
            let size = geo.size
            ZStack {
                theme.ground
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    // The glows scale with the SHORT side. On a phone this ground
                    // is only ever drawn on its side, where the short side is the
                    // height it always scaled with; on an upright iPad the height
                    // is the long side, and a glow 0.55 of 1376 points is a
                    // sunrise, not a glow.
                    let base = min(size.width, size.height)
                    ForEach(Self.blobs) { blob in
                        let r = blob.radius * base
                        let at = blob.position(at: t)
                        let color = blob.role == .accent ? theme.accent : theme.highlight
                        let strength = blob.opacity * theme.glow
                        Circle()
                            .fill(RadialGradient(
                                gradient: Gradient(stops: [
                                    .init(color: color.opacity(strength), location: 0),
                                    .init(color: color.opacity(strength * 0.55), location: 0.28),
                                    .init(color: color.opacity(strength * 0.18), location: 0.6),
                                    .init(color: color.opacity(0), location: 1),
                                ]),
                                center: .center, startRadius: 0, endRadius: r))
                            .frame(width: r * 2, height: r * 2)
                            .blendMode(.plusLighter)
                            .position(x: at.x * size.width, y: at.y * size.height)
                    }
                }
                Image(uiImage: Self.grain)
                    .resizable(resizingMode: .tile)
                    .interpolation(.none)
                    .opacity(0.05)
                LibraryLandscapeParticlesView(isPaused: isPaused, theme: theme)
                if dimmed {
                    Color.black.opacity(LandscapeChrome.groundFilm)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// A 96 by 96 field of random grey, built once. Tiled at one pixel per
    /// point on purpose: at screen resolution it would be too fine to break
    /// the bands.
    private static let grain: UIImage = {
        let n = 96
        var bytes = [UInt8](repeating: 0, count: n * n)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { return UIImage() }
        return UIImage(cgImage: cg)
    }()
}

/// The dust: the Pro surfaces' emitter, re-tuned for a full screen and the
/// two brand hues. Its own layer rather than a parameter on
/// `ParticleEmitterView`, so the Pro rows keep exactly the drift they have.
struct LibraryLandscapeParticlesView: UIViewRepresentable {
    let isPaused: Bool
    let theme: LandscapeTheme

    func makeUIView(context: Context) -> LibraryLandscapeParticleLayerView {
        let view = LibraryLandscapeParticleLayerView()
        view.apply(theme)
        return view
    }

    func updateUIView(_ uiView: LibraryLandscapeParticleLayerView, context: Context) {
        uiView.setPaused(isPaused)
        uiView.apply(theme)
    }
}

final class LibraryLandscapeParticleLayerView: UIView {
    private let emitter = CAEmitterLayer()
    private var appliedTheme: LandscapeTheme?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        emitter.emitterShape = .rectangle
        emitter.emitterMode = .volume
        emitter.renderMode = .additive
        layer.addSublayer(emitter)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The dust in the theme's two hues, at the theme's strength; rebuilt
    /// only when the theme actually changes.
    func apply(_ theme: LandscapeTheme) {
        guard theme != appliedTheme else { return }
        appliedTheme = theme
        let sprite = Self.sprite

        func cell(color: UIColor, birthRate: Float, scale: CGFloat, lifetime: Float) -> CAEmitterCell {
            let c = CAEmitterCell()
            c.contents = sprite.cgImage
            c.birthRate = birthRate
            c.lifetime = lifetime
            c.lifetimeRange = lifetime * 0.3
            c.velocity = 6
            c.velocityRange = 4
            c.emissionRange = .pi * 2
            c.scale = scale
            c.scaleRange = scale * 0.5
            c.scaleSpeed = scale * 0.02
            c.alphaSpeed = -0.6 / lifetime   // fades to nothing over its life
            c.color = color.cgColor
            return c
        }

        let alpha = CGFloat(0.6 * theme.glow)
        let accent = theme.accentUIColor.withAlphaComponent(alpha)
        let highlight = theme.highlightUIColor.withAlphaComponent(alpha)

        emitter.emitterCells = [
            cell(color: accent, birthRate: 5, scale: 0.35, lifetime: 12),   // dust
            cell(color: highlight, birthRate: 3, scale: 0.35, lifetime: 12),
            cell(color: accent, birthRate: 0.6, scale: 1.6, lifetime: 16),  // a few soft motes
            cell(color: highlight, birthRate: 0.4, scale: 1.6, lifetime: 16),
        ]
    }

    private var paused = false

    func setPaused(_ paused: Bool) {
        self.paused = paused
        updateBirthRate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        emitter.emitterSize = bounds.size
        updateBirthRate()
    }

    /// The cells' birth rates are absolute, so the same dust spread over an
    /// iPad's window would be a third as dense. The layer's own rate scales
    /// with the area, against the largest phone, which never exceeds one.
    private static let phoneReferenceArea: CGFloat = 956 * 440

    private func updateBirthRate() {
        guard !paused else { emitter.birthRate = 0; return }
        let area = bounds.width * bounds.height
        emitter.birthRate = Float(max(1, area / Self.phoneReferenceArea))
    }

    private static let sprite: UIImage = {
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor.white.cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }()
}

// MARK: - Debug gallery

#if DEBUG
/// Settings ▸ Debug ▸ "Library landscape preview": the real library rendered at
/// the two extreme phone sizes, scaled to fit, so the surface can be checked
/// without turning the phone or owning both. Sort is as fetched (last played
/// first) and the search field filters by title, which is enough to see the
/// line, the caption and the buttons at both sizes. Everything else is a
/// no-op: nothing here plays, imports or deletes.
struct LibraryLandscapePreviewGallery: View {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \GameEntity.lastPlayedAt, ascending: false)])
    private var games: FetchedResults<GameEntity>
    @State private var sortOrder: LibraryView.SortOrder = .lastPlayed
    @State private var searchText = ""

    private let devices: [(name: String, size: CGSize)] = [
        ("iPhone SE", CGSize(width: 667, height: 375)),
        ("iPhone 16 Pro Max", CGSize(width: 956, height: 440)),
    ]

    private var shown: [GameEntity] {
        let all = Array(games)
        guard !searchText.isEmpty else { return all }
        return all.filter { ($0.title ?? "").localizedStandardContains(searchText) }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(devices, id: \.name) { device in
                        let scale = min(1, (geo.size.width - 32) / device.size.width)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(device.name) · landscape \(Int(device.size.width))×\(Int(device.size.height))")
                                .font(.caption).foregroundStyle(.secondary)
                            LibraryLandscapeView(
                                games: shown,
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
                            .frame(width: device.size.width, height: device.size.height)
                            .clipped()
                            .border(Color.red.opacity(0.6))
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: device.size.width * scale,
                                   height: device.size.height * scale,
                                   alignment: .topLeading)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Library landscape")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
