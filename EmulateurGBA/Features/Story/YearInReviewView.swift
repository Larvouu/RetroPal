//
//  YearInReviewView.swift
//  EmulateurGBA
//
//  The year in review (offered from December 1 through January 6): the player's
//  year told in full-screen slides they tap through, read from the days the
//  history keeps (`PlayStats.year`), so the first one covers the year from the
//  day 1.3.5 was installed, and says so.
//
//  REBUILT 2026-10-28 after the way Spotify Wrapped shares (his feedback: the
//  slides were the moment, the square card at the end a let-down):
//   - EVERY slide is shareable, and what is shared is the slide itself: one
//     view (`YearSlideContent`) draws the screen and the image, 9:16 (1080 x
//     1920), the shape of a story on Instagram or TikTok, where these go.
//   - One fact a slide, in big type, each slide on its own colour of the look.
//   - An identity slide, the player's profile for the year (the "listening
//     personality" of Wrapped), the line people post because it says who
//     they are.
//   - The last slide is the summary to post: the game of the year's cover
//     large, the top 5 beside the consoles, the hours, the profile.
//
//  MOTION (2026-10-28, his ask: premium, special): nothing on a slide just
//  appears. Its pieces arrive one after another on springs (rise, pop, flip,
//  grow), the hours count up, the game of the year's cover turns in, bars
//  grow, and the ground morphs from slide to slide (the slide's glow slides
//  to its new place while its colour crossfades, over the library's own
//  moving ground, `YearSlideBackground`). The
//  progress bars fill as in a story and the slide moves on by itself; a touch
//  holds it, a tap or a swipe moves, the summary waits. All of it lives in
//  the screen only (`yearAnimates`, false by default): a shared image is
//  always the finished slide. Under Reduce Motion, or with VoiceOver on, the
//  slides are still and wait for the player.
//

import SwiftUI
import CoreData

/// The slides, in order. A slide with nothing to say is left out.
enum YearSlide: Equatable {
    case intro, total, topGame, topGames, consoles, months, rhythm, profile, summary

    static func slides(for year: PlayStats.Year) -> [YearSlide] {
        var list: [YearSlide] = [.intro, .total]
        if year.games.first != nil { list.append(.topGame) }
        if year.games.count >= 2 { list.append(.topGames) }
        if !year.consoles.isEmpty { list.append(.consoles) }
        // The months: two with play, and never in the launch year (his call
        // of 10-29: the days were only recorded from October, so its months
        // would say little).
        if year.year != PlayStats.launchYear, year.months.filter({ $0 > 0 }).count >= 2 { list.append(.months) }
        if year.bestDay != nil || year.favouriteTimeOfDay != nil { list.append(.rhythm) }
        list.append(.profile)
        list.append(.summary)
        return list
    }
}

struct YearInReviewView: View {
    let year: PlayStats.Year
    let onClose: () -> Void

    @State private var index = 0
    @State private var covers: [String: UIImage] = [:]
    @State private var sharedImage: YearShareImage?
    /// A finger is on the screen: the story holds, as a story does.
    @State private var holding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AppStorage("isPro") private var isPro = false

    /// Seconds a slide stays before the next, when the story runs by itself.
    private static let slideDuration: Double = 7

    /// The story moves on by itself, except on the summary (the end, where
    /// the player shares), under Reduce Motion, and with VoiceOver on.
    private var autoAdvances: Bool { current != .summary && !reduceMotion && !voiceOver }

    private var slides: [YearSlide] { YearSlide.slides(for: year) }
    private var current: YearSlide { slides[min(index, slides.count - 1)] }
    private var profile: PlayStats.PlayerType { PlayStats.playerType(for: year) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                YearSlideBackground(slide: current, theme: LandscapeThemeStore.shared.theme, live: true)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    YearStoryProgress(count: slides.count, index: index,
                                      paused: holding || sharedImage != nil,
                                      autoAdvances: autoAdvances,
                                      duration: Self.slideDuration,
                                      onFinish: { go(1) })
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    HStack {
                        Text(verbatim: "\(year.year)")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        FocusableButton(shape: .capsule, action: onClose) {
                            LandscapeChrome.circle(systemName: "xmark")
                        }
                        .accessibilityLabel(NSLocalizedString("screenshot.dismiss", comment: ""))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    // The slide's content, the same view the shared image draws;
                    // tighter on a phone on its side.
                    YearSlideContent(slide: current, year: year, profile: profile, covers: covers,
                                     compact: geo.size.height < 560)
                        // A new identity a slide, so its pieces arrive anew;
                        // the slide itself only fades, its pieces do the rest.
                        .id(index)
                        .transition(.opacity)
                        .environment(\.yearAnimates, !reduceMotion)
                        .frame(maxWidth: 560, maxHeight: .infinity)
                        .padding(.horizontal, 24)
                    shareBar
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }
                // One gesture over the slide, clear of the bars: a finger down
                // holds the story; a quick tap moves (the left third back, the
                // rest forward), a swipe moves its way; a long hold moves
                // nothing.
                GeometryReader { inner in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(storyGesture(width: inner.size.width))
                }
                .padding(.top, 90)
                .padding(.bottom, 90)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .controllerBack(onClose)
        .accessibilityAction(named: Text(NSLocalizedString("story.year.next", comment: ""))) { go(1) }
        .task { covers = await Self.loadCovers(for: year) }
        .sheet(item: $sharedImage) { item in
            ActivityShareSheet(activityItems: item.items, cardType: "story_year") { sharedImage = nil }
        }
    }

    /// Share this slide (every one, as Wrapped does); on the summary, also Close.
    private var shareBar: some View {
        HStack(spacing: 12) {
            FocusableButton(shape: .capsule, isDefault: current == .summary) {
                share()
            } label: {
                Label(current == .summary
                        ? NSLocalizedString("story.year.shareSummary", comment: "")
                        : NSLocalizedString("story.year.shareSlide", comment: ""),
                      systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(current == .summary ? Color.black : Color.white)
                    .padding(.horizontal, 22)
                    .frame(height: 48)
                    .background(Capsule().fill(current == .summary ? Color.white : Color.white.opacity(0.18)))
            }
            if current == .summary {
                FocusableButton(shape: .capsule, action: onClose) {
                    Text(NSLocalizedString("screenshot.dismiss", comment: ""))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @State private var touchStart: Date?

    private func storyGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if touchStart == nil { touchStart = Date() }
                holding = true
            }
            .onEnded { value in
                let held = touchStart.map { Date().timeIntervalSince($0) } ?? 0
                touchStart = nil
                holding = false
                let dx = value.translation.width
                if abs(dx) > 50, abs(dx) > abs(value.translation.height) {
                    go(dx < 0 ? 1 : -1)
                } else if held < 0.3, abs(dx) < 12 {
                    go(value.location.x < width / 3 ? -1 : 1)
                }
            }
    }

    private func go(_ step: Int) {
        let next = index + step
        guard next >= 0 else { return }
        guard next < slides.count else {
            // Past the summary the story ends; it does not close by itself.
            if step > 0, current == .summary { return }
            onClose(); return
        }
        Haptics.tap()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { index = next }
    }

    /// The slide as a 1080 x 1920 image (360 x 640 points at x3): the same
    /// content and colour as the screen, with the year, the Retro Pal mark and
    /// the App Store line around it, and the crown for a Pro member.
    @MainActor private func share() {
        let renderer = ImageRenderer(content:
            YearSlideView(slide: current, year: year, profile: profile, covers: covers, isPro: isPro))
        renderer.scale = 3
        guard let image = renderer.uiImage else { return }
        let link = TrackedLinkItem(RetroPalShare.link(.card))
        let file = image.temporaryShareFileURL(name: "retropal-\(year.year)")
        sharedImage = YearShareImage(items: file.map { [$0, link] } ?? [image, link])
    }

    /// Every cover the slides show (the top 5), read before they are drawn:
    /// a shared image is one frame, nothing can load inside it.
    static func loadCovers(for year: PlayStats.Year) async -> [String: UIImage] {
        var result: [String: UIImage] = [:]
        for game in year.games.prefix(5) {
            let request = NSFetchRequest<GameEntity>(entityName: "GameEntity")
            request.predicate = NSPredicate(format: "romHash == %@", game.romHash)
            request.fetchLimit = 1
            guard let entity = try? PersistenceController.shared.container.viewContext.fetch(request).first
            else { continue }
            let filename = entity.romFilePath, coverType = entity.coverType, hash = game.romHash
            let image = await Task.detached(priority: .userInitiated) {
                LibraryLandscapeCover.load(filename: filename, romHash: hash, coverType: coverType,
                                           maxPixels: 600)?.image
            }.value
            if let image { result[hash] = image }
        }
        return result
    }
}

struct YearShareImage: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: - The shared image

/// One slide as a story image, 360 x 640 points: the slide's colour, the year
/// and the Retro Pal mark at the top, the content, the App Store line (and the
/// crown for a Pro member) at the bottom.
struct YearSlideView: View {
    let slide: YearSlide
    let year: PlayStats.Year
    let profile: PlayStats.PlayerType
    let covers: [String: UIImage]
    var isPro: Bool = false

    var body: some View {
        ZStack {
            YearSlideBackground(slide: slide, theme: LandscapeThemeStore.shared.theme)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let icon = UIImage(named: "SharingIcon") {
                        Image(uiImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Text(String(format: NSLocalizedString("story.year.cardTitle", comment: ""), "\(year.year)"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.top, 28)
                YearSlideContent(slide: slide, year: year, profile: profile, covers: covers, compact: false)
                    .frame(maxHeight: .infinity)
                HStack(spacing: 4) {
                    if isPro {
                        Image(uiImage: ScreenshotCardRenderer.proCrownBadgeImage(side: 14))
                    }
                    Text(NSLocalizedString("screenshot.footer", comment: ""))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .frame(width: 360, height: 640)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - A slide's colour

/// Each slide on the app's own ground, and on its own colour (2026-10-28, his
/// ask: the review's grounds like the main one, by look): the look's ground
/// as the library draws it, then one large glow of the slide's colour (the
/// accent or the highlight by turns, placed differently per slide, as
/// Wrapped changes colour every screen), then a film so the white type reads.
///
/// `live` (the screen): the library's own moving ground, `LibraryLandscape-
/// Background`, with every guard it was tuned with for heat (pre-rasterised
/// gradients on one 30 fps wall clock, no live blur, held still under Reduce
/// Motion and while a game runs); the slide's glow adds no clock of its own,
/// it only animates from one slide to the next (it slides to its new place
/// while the colours crossfade). The grounds under the review are held still
/// while it is up, so two never move at once. Not live (the shared image):
/// the same ground, still (`StoryCardGround`), the image being one frame, its
/// dust drawn at one moment (a particle layer cannot be in one frame).
/// Classic keeps its black, with a faint white glow so the slides differ.
struct YearSlideBackground: View {
    let slide: YearSlide
    let theme: LandscapeTheme
    var live: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spec: (x: CGFloat, y: CGFloat, accent: Bool) {
        switch slide {
        case .intro: return (0.5, 0.35, true)
        case .total: return (0.15, 0.2, false)
        case .topGame: return (0.5, 0.3, true)
        case .topGames: return (0.85, 0.15, false)
        case .consoles: return (0.2, 0.8, true)
        case .months: return (0.8, 0.85, false)
        case .rhythm: return (0.85, 0.2, true)
        case .profile: return (0.5, 0.5, false)
        case .summary: return (0.5, 0.15, true)
        }
    }

    var body: some View {
        ZStack {
            if live {
                LibraryLandscapeBackground(isPaused: reduceMotion)
            } else {
                StoryCardGround(theme: theme, film: false, dust: true)
            }
            GeometryReader { geo in
                let size = geo.size
                let r = max(size.width, size.height) * 0.7
                let strength = theme.isClassic ? 0.12 : 0.6
                ZStack {
                    glow(theme.isClassic ? .white : theme.accent, strength: strength, radius: r)
                        .opacity(spec.accent ? 1 : 0)
                    glow(theme.isClassic ? .white : theme.highlight, strength: strength, radius: r)
                        .opacity(spec.accent ? 0 : 1)
                }
                .blendMode(.plusLighter)
                .position(x: spec.x * size.width, y: spec.y * size.height)
                // The morph, on the slide only.
                .animation(.easeInOut(duration: 0.9), value: slide)
            }
            .allowsHitTesting(false)
            // A film, so the white type always reads over the glows.
            Color.black.opacity(0.22)
        }
        .clipped()
    }

    private func glow(_ color: Color, strength: Double, radius r: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: color.opacity(strength), location: 0),
                    .init(color: color.opacity(strength * 0.55), location: 0.3),
                    .init(color: color.opacity(strength * 0.18), location: 0.65),
                    .init(color: color.opacity(0), location: 1),
                ]),
                center: .center, startRadius: 0, endRadius: r))
            .frame(width: r * 2, height: r * 2)
    }
}

// MARK: - Motion

private struct YearAnimatesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The year's slides animate their pieces in: true on the screen (unless
    /// Reduce Motion), false everywhere else, so a shared image, which is one
    /// frame, is always the finished slide.
    var yearAnimates: Bool {
        get { self[YearAnimatesKey.self] }
        set { self[YearAnimatesKey.self] = newValue }
    }
}

/// How a piece arrives.
enum YearRevealStyle {
    /// Fades in rising a little: text, rows.
    case rise
    /// Springs up from small, a little past its size: badges, big numbers.
    case pop
    /// Turns in on its vertical axis: a cover.
    case flip
    /// Grows up from its base: a month's bar.
    case grow
    /// Grows from its left: a console's share.
    case growX
}

/// A piece of a slide arriving in its turn (`order`, about a tenth of a
/// second each) when the slide appears; shown at once when `yearAnimates`
/// is off.
private struct YearReveal: ViewModifier {
    let order: Double
    let style: YearRevealStyle
    @Environment(\.yearAnimates) private var animates
    @State private var shown = false

    func body(content: Content) -> some View {
        let on = !animates || shown
        content
            .opacity(on ? 1 : 0)
            .offset(y: style == .rise && !on ? 26 : 0)
            .scaleEffect(x: style == .growX && !on ? 0.02 : 1,
                         y: style == .grow && !on ? 0.02 : 1,
                         anchor: style == .grow ? .bottom : .leading)
            .scaleEffect(style == .pop && !on ? 0.4 : (style == .flip && !on ? 0.85 : 1))
            .rotation3DEffect(.degrees(style == .flip && !on ? 75 : 0),
                              axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .onAppear {
                guard animates, !shown else { return }
                let spring: Animation = style == .pop
                    ? .spring(response: 0.55, dampingFraction: 0.55)
                    : .spring(response: 0.6, dampingFraction: 0.82)
                withAnimation(spring.delay(0.18 + order * 0.11)) { shown = true }
            }
    }
}

extension View {
    func yearReveal(_ order: Double, _ style: YearRevealStyle = .rise) -> some View {
        modifier(YearReveal(order: order, style: style))
    }
}

/// Hours that count up to their value when the slide appears; the value
/// itself when `yearAnimates` is off.
struct YearCountUp: View {
    let seconds: Double
    var delay: Double = 0.3
    @Environment(\.yearAnimates) private var animates
    @State private var value: Double = 0
    @State private var started = false

    /// The count-up writes every frame in the final value's form ("147 h"
    /// counts up in whole hours, never "12 min" then "1 h 4 min"), and takes
    /// the final text's width, so centred digits never push sideways (his
    /// report of 10-29: it blinked).
    var body: some View {
        let style = RetroStoryFormat.durationStyle(seconds)
        // The final text in the counting form (minutes two digits), so the
        // reserved width is the counting text's own.
        Text(RetroStoryFormat.duration(seconds, style: style, padTo: seconds))
            .monospacedDigit()
            .hidden()
            .overlay(YearCountUpLabel(value: animates ? value : seconds, style: style, final: seconds))
            .onAppear {
                guard animates, !started else { return }
                started = true
                withAnimation(.easeOut(duration: 1.3).delay(delay)) { value = seconds }
            }
    }
}

/// The number SwiftUI interpolates frame by frame.
private struct YearCountUpLabel: View, Animatable {
    var value: Double
    let style: RetroStoryFormat.DurationStyle
    /// The value it counts to, whose width every frame keeps.
    let final: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        // The placeholder's frame, its font and its scale-to-fit (the caller's
        // modifiers reach both): it shrinks with it on a narrow screen.
        Text(RetroStoryFormat.duration(value, style: style, padTo: final))
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// The story's progress: a bar per slide, the current one filling while the
/// story runs by itself, then the next slide. Its own view with its own
/// clock, so the slides above are not redrawn thirty times a second.
struct YearStoryProgress: View {
    let count: Int
    let index: Int
    let paused: Bool
    let autoAdvances: Bool
    let duration: Double
    let onFinish: () -> Void

    @State private var elapsed: Double = 0
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(Color.white.opacity(0.9))
                            .frame(width: geo.size.width * fill(i))
                    }
                }
                .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
        .onReceive(tick) { _ in
            guard autoAdvances, !paused else { return }
            elapsed += 1.0 / 30.0
            if elapsed >= duration {
                elapsed = 0
                onFinish()
            }
        }
        .onChange(of: index) { _ in elapsed = 0 }
    }

    private func fill(_ i: Int) -> CGFloat {
        if i < index { return 1 }
        if i > index { return 0 }
        return autoAdvances ? CGFloat(min(1, elapsed / duration)) : 1
    }
}

// MARK: - A slide's content

/// What a slide says, drawn the same on the screen and in the shared image.
/// `compact` tightens it for a phone on its side.
struct YearSlideContent: View {
    let slide: YearSlide
    let year: PlayStats.Year
    let profile: PlayStats.PlayerType
    let covers: [String: UIImage]
    let compact: Bool

    var body: some View {
        switch slide {
        case .intro:
            centered {
                Image(systemName: "sparkles")
                    .font(.system(size: compact ? 36 : 54))
                    .foregroundStyle(.white)
                    .yearReveal(0, .pop)
                big(String(format: NSLocalizedString("story.year.intro", comment: ""), "\(year.year)"))
                    .yearReveal(2)
                // Since when the year's story runs: the first game played or
                // imported in the launch year, the first recorded day after.
                if let started = year.startedOn {
                    small(String(format: NSLocalizedString("story.year.recordedFrom", comment: ""),
                                 RetroStoryFormat.date(started)))
                        .yearReveal(4)
                }
            }
        case .total:
            centered {
                small(NSLocalizedString("story.year.total", comment: ""))
                    .yearReveal(0)
                YearCountUp(seconds: year.totalSeconds, delay: 0.35)
                    .font(.system(size: compact ? 44 : 64, weight: .heavy))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .yearReveal(1, .pop)
                // Days are dated, the launch year's earlier play is not: the
                // count says from when, so it never reads against the total.
                if year.daysPlayed > 0 {
                    small(year.undatedSeconds > 0
                          ? String(format: NSLocalizedString("story.year.daysSince", comment: ""),
                                   year.daysPlayed.formatted(), RetroStoryFormat.date(year.recordedFrom))
                          : "\(NSLocalizedString("story.activity.daysPlayed", comment: "")) \(year.daysPlayed.formatted())")
                        .yearReveal(8)
                }
            }
        case .topGame:
            if let game = year.games.first {
                centered {
                    small(NSLocalizedString("story.year.topGame", comment: ""))
                        .yearReveal(0)
                    cover(game, side: compact ? 110 : 200)
                        .yearReveal(1, .flip)
                    big(game.title)
                        .yearReveal(4)
                    ConsoleMark(systemType: game.system, width: 44, height: 30)
                        .yearReveal(5)
                    YearCountUp(seconds: game.seconds, delay: 0.8)
                        .font(.system(size: compact ? 26 : 32, weight: .heavy))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .yearReveal(6, .pop)
                }
            }
        case .topGames:
            VStack(alignment: .leading, spacing: compact ? 8 : 16) {
                Spacer(minLength: 0)
                small(NSLocalizedString("story.year.topGames", comment: ""))
                    .yearReveal(0)
                // From the fifth up to the first, the countdown Wrapped does,
                // the first arriving last and with a pop.
                ForEach(Array(year.games.prefix(5).enumerated()), id: \.offset) { i, game in
                    HStack(spacing: 14) {
                        Text("\(i + 1)")
                            .font(.system(size: compact ? 20 : 28, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 30)
                        cover(game, side: compact ? 36 : 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.title)
                                .font(.system(size: compact ? 14 : 17, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                            Text(RetroStoryFormat.duration(game.seconds))
                                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                    .yearReveal(Double(1 + 2 * (min(year.games.count, 5) - 1 - i)), i == 0 ? .pop : .rise)
                }
                if year.newGames > 0 {
                    small("\(NSLocalizedString("story.year.newGames", comment: "")) \(year.newGames.formatted())")
                        .yearReveal(12)
                }
                Spacer(minLength: 0)
            }
        case .consoles:
            VStack(alignment: .leading, spacing: compact ? 10 : 18) {
                Spacer(minLength: 0)
                small(NSLocalizedString("story.year.consoles", comment: ""))
                    .yearReveal(0)
                ForEach(Array(year.consoles.prefix(5).enumerated()), id: \.offset) { i, console in
                    HStack(spacing: 14) {
                        ConsoleMark(systemType: console.system, width: compact ? 40 : 56, height: compact ? 28 : 40)
                            .frame(width: compact ? 40 : 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SystemColor.name(console.system))
                                .font(.system(size: compact ? 14 : 17, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            bar(year.totalSeconds > 0 ? console.seconds / year.totalSeconds : 0)
                                .yearReveal(Double(2 + 2 * i), .growX)
                            Text(RetroStoryFormat.duration(console.seconds))
                                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .monospacedDigit()
                        }
                    }
                    .yearReveal(Double(1 + 2 * i))
                }
                Spacer(minLength: 0)
            }
        case .months:
            VStack(alignment: .leading, spacing: 18) {
                Spacer(minLength: 0)
                small(NSLocalizedString("story.year.months", comment: ""))
                    .yearReveal(0)
                monthChart.frame(height: compact ? 120 : 220)
                if let peak = year.months.indices.max(by: { year.months[$0] < year.months[$1] }) {
                    big(String(format: NSLocalizedString("story.year.peakMonth", comment: ""),
                               Calendar.current.standaloneMonthSymbols[peak]))
                        .yearReveal(14)
                }
                Spacer(minLength: 0)
            }
        case .rhythm:
            centered {
                if let best = year.bestDay {
                    small(NSLocalizedString("story.year.bestDay", comment: ""))
                        .yearReveal(0)
                    big(RetroStoryFormat.date(best.date))
                        .yearReveal(1)
                    YearCountUp(seconds: best.seconds, delay: 0.5)
                        .font(.system(size: compact ? 24 : 30, weight: .heavy))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .yearReveal(2, .pop)
                }
                if let time = year.favouriteTimeOfDay {
                    Label(RetroStoryActivity.label(time), systemImage: RetroStoryActivity.icon(time))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.top, compact ? 8 : 24)
                        .yearReveal(7)
                }
            }
        case .profile:
            // The reveal of who they are: a pause, the badge springs in, then
            // the name, then the line.
            centered {
                small(NSLocalizedString("story.year.profile", comment: ""))
                    .yearReveal(0)
                Image(uiImage: YearProfileBadge.image(for: profile, side: compact ? 60 : 110))
                    .yearReveal(3, .pop)
                huge(YearProfileBadge.name(profile))
                    .yearReveal(6)
                small(YearProfileBadge.line(profile, year: year))
                    .yearReveal(8)
            }
        case .summary:
            summary
        }
    }

    /// The summary to post (Wrapped's last card): the game of the year's cover
    /// large, then the top 5 beside the consoles, then the hours and the
    /// profile, each a block of its own.
    private var summary: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 18) {
            Spacer(minLength: 0)
            if let top = year.games.first {
                cover(top, side: compact ? 90 : 150)
                    .frame(maxWidth: .infinity)
                    .yearReveal(0, .flip)
            }
            // Games and consoles side by side, each row with its picture
            // (his ask of 10-29: the cover between the rank and the title,
            // the drawing before the console). The games take the wider
            // column (longer names); a name shrinks a little, then wraps to a
            // second line, never cut, on the narrowest phone as on an iPad.
            GeometryReader { geo in
                let gap: CGFloat = 14
                let gamesWidth = (geo.size.width - gap) * 0.58
                HStack(alignment: .top, spacing: gap) {
                    VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                        caption(NSLocalizedString("story.year.topGames", comment: ""))
                        ForEach(Array(year.games.prefix(5).enumerated()), id: \.offset) { i, game in
                            HStack(spacing: 6) {
                                Text("\(i + 1)")
                                    .font(.system(size: compact ? 11 : 13, weight: .heavy))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .monospacedDigit()
                                    .frame(width: 12, alignment: .trailing)
                                cover(game, side: compact ? 18 : 22)
                                Text(game.title)
                                    .font(.system(size: compact ? 11 : 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(width: gamesWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                        caption(NSLocalizedString("story.year.consoles", comment: ""))
                        ForEach(year.consoles.prefix(5)) { console in
                            HStack(spacing: 6) {
                                ConsoleMark(systemType: console.system,
                                            width: compact ? 18 : 22, height: compact ? 13 : 16)
                                    .frame(width: compact ? 18 : 22)
                                Text(SystemColor.name(console.system))
                                    .font(.system(size: compact ? 11 : 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: compact ? 150 : 205)
            .yearReveal(3)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    caption(NSLocalizedString("story.year.total", comment: ""))
                    Text(RetroStoryFormat.duration(year.totalSeconds))
                        .font(.system(size: compact ? 20 : 26, weight: .heavy))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    caption(NSLocalizedString("story.year.profile", comment: ""))
                    // The profile's badge before its name (his ask of 10-29).
                    HStack(spacing: 6) {
                        Image(uiImage: YearProfileBadge.image(for: profile, side: compact ? 16 : 20))
                            .accessibilityHidden(true)
                        Text(YearProfileBadge.name(profile))
                            .font(.system(size: compact ? 16 : 20, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .yearReveal(5)
            Spacer(minLength: 0)
        }
    }

    /// The months as bars (never in the launch year, whose days start late).
    private var monthChart: some View {
        let peak = max(year.months.max() ?? 1, 1)
        let symbols = Calendar.current.veryShortStandaloneMonthSymbols
        return GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<12, id: \.self) { m in
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(year.months[m] > 0 ? Color.white : Color.white.opacity(0.18))
                            .frame(height: max(4, (geo.size.height - 22) * CGFloat(year.months[m] / peak)))
                            .yearReveal(1 + Double(m) * 0.6, .grow)
                        Text(symbols.indices.contains(m) ? symbols[m] : "")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Pieces

    private func cover(_ game: PlayStats.GameStat, side: CGFloat) -> some View {
        Group {
            if let image = covers[game.romHash] {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    ConsoleMark(systemType: game.system, width: side * 0.6, height: side * 0.42)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .accessibilityHidden(true)
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white)
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: compact ? 10 : 18) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private func huge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: compact ? 44 : 64, weight: .heavy))
            .foregroundStyle(.white)
            .monospacedDigit()
            .lineLimit(2)
            .minimumScaleFactor(0.5)
    }

    private func big(_ text: String) -> some View {
        Text(text)
            .font(.system(size: compact ? 22 : 28, weight: .bold))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .minimumScaleFactor(0.7)
    }

    private func small(_ text: String) -> some View {
        Text(text)
            .font(.system(size: compact ? 13 : 16, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: compact ? 9 : 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - The profile

/// The player's profile for the year: its metal badge (the timeline's family),
/// its name, and its line.
enum YearProfileBadge {
    static func symbol(_ type: PlayStats.PlayerType) -> String {
        switch type {
        case .loyal: return "heart.fill"
        case .explorer: return "safari.fill"
        case .nightOwl: return "moon.stars.fill"
        case .regular: return "calendar.circle.fill"
        case .enthusiast: return "gamecontroller.fill"
        }
    }

    static func image(for type: PlayStats.PlayerType, side: CGFloat) -> UIImage {
        ScreenshotCardRenderer.metalBadgeImage(systemName: symbol(type), side: side)
    }

    static func name(_ type: PlayStats.PlayerType) -> String {
        switch type {
        case .loyal: return NSLocalizedString("story.profile.loyal", comment: "")
        case .explorer: return NSLocalizedString("story.profile.explorer", comment: "")
        case .nightOwl: return NSLocalizedString("story.profile.nightOwl", comment: "")
        case .regular: return NSLocalizedString("story.profile.regular", comment: "")
        case .enthusiast: return NSLocalizedString("story.profile.enthusiast", comment: "")
        }
    }

    static func line(_ type: PlayStats.PlayerType, year: PlayStats.Year) -> String {
        switch type {
        case .loyal:
            return String(format: NSLocalizedString("story.profile.loyal.line", comment: ""),
                          year.games.first?.title ?? "")
        case .explorer: return NSLocalizedString("story.profile.explorer.line", comment: "")
        case .nightOwl: return NSLocalizedString("story.profile.nightOwl.line", comment: "")
        case .regular: return NSLocalizedString("story.profile.regular.line", comment: "")
        case .enthusiast: return NSLocalizedString("story.profile.enthusiast.line", comment: "")
        }
    }
}
