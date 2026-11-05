//
//  StoryBadgeUnlocks.swift
//  EmulateurGBA
//
//  A Retro story badge earned, announced (2026-10-29, his ask): a banner at
//  the top like a RetroAchievements unlock, its own look and its own sound
//  (`story-badge.wav`, `Tools/make-badge-sound.py`), the cover of the game
//  first when the badge is a game's.
//
//  Detection rides on `RetroStoryModel`, which recomputes the stats after
//  every banked stretch of play and every iCloud pull: the badges' ids are
//  compared with the ones already seen (kept per device). The first time,
//  every badge already earned is marked seen in silence, so updating to
//  1.3.5 does not fire a burst of old ones; and only a badge earned in the
//  last day is announced, so a badge earned on another device and arriving
//  through iCloud later is not announced as new.
//
//  The banner's life is the announcer's (audit of 10-30): queued in order,
//  shown once its cover is read, timed from the first host that shows it.
//  It was the view's `.task`, which a host leaving cancelled, and a
//  cancelled sleep returns at once: a badge earned as a game closed vanished
//  with the game's screen, and one arriving with no host on screen stayed
//  pending with its sound already played.
//

import SwiftUI
import AVFoundation
import Combine
import CoreData
import UIKit

/// The announcement: what the banner shows.
struct StoryBadgeUnlock: Identifiable, Equatable {
    let id = UUID()
    let milestone: PlayStats.Milestone
    /// The game's cover for a game's badge, read before the banner shows.
    let cover: UIImage?

    static func == (a: StoryBadgeUnlock, b: StoryBadgeUnlock) -> Bool { a.id == b.id }
}

@MainActor
final class StoryBadgeAnnouncer: ObservableObject {
    static let shared = StoryBadgeAnnouncer()

    /// The banner showing, nil when none.
    @Published var current: StoryBadgeUnlock?

    /// The badges waiting their turn, in the order they came. A game's badge
    /// is ready once its cover is read (off the main thread); one before it
    /// still loading holds the ones after, so the order is kept.
    private struct Entry {
        let id = UUID()
        let milestone: PlayStats.Milestone
        var unlock: StoryBadgeUnlock?
    }
    private var queue: [Entry] = []
    /// The short pause between two banners, so one does not replace the other
    /// in the same instant.
    private var resting = false
    /// The banner whose four seconds have started: once per banner, from the
    /// first host that shows it, however often it leaves and comes back.
    private var timedID: UUID?
    /// The running clock and when it ends. Paused while a RetroAchievements
    /// banner holds the band (`holdsBannerBand`): the badge is hidden then,
    /// so its time waits and resumes with what was left (his call of 10-30;
    /// it ran on unseen and the badge was cut short).
    private var clock: DispatchWorkItem?
    private var clockEnds: Date?
    private var remaining: TimeInterval = 0
    private var raBand: AnyCancellable?

    /// Ready ahead (his reports of 10-29: the first banner slid in and
    /// vanished, some came late). The audio player, the audio session, the
    /// haptic engine and every badge's metal picture are made here, once, off
    /// the main thread where they can be; nothing is created or decoded while
    /// a banner slides in.
    private let haptics = UINotificationFeedbackGenerator()

    private init() {
        haptics.prepare()
        // RA's own published state, never a view event: it cannot drift.
        raBand = RetroAchievements.shared.$holdsBannerBand
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] holds in
                Task { @MainActor in self?.raBandChanged(holds) }
            }
        let side = StoryBadgeBanner.iconSide
        DispatchQueue.global(qos: .utility).async {
            StoryBadgeSound.prepare()
            StoryBadge.prewarm(iconSide: side)
        }
    }

    private static let seenKey = "story.badges.seen"

    /// Two days, not one: a badge crossed by the days played is dated at the
    /// MIDNIGHT that starts its day (`PlayStats.milestones`), so one crossed at
    /// 23:00 and banked at 00:15 was already 24 h 15 old, and marked seen in
    /// silence (audit, 2026-10-29). Still short enough that a badge another
    /// device earned days ago, pulled from iCloud, is never announced here.
    nonisolated static let freshWindow: TimeInterval = 2 * 86_400
    private var seen: Set<String>? {
        get { UserDefaults.standard.stringArray(forKey: Self.seenKey).map(Set.init) }
        set { UserDefaults.standard.set(newValue.map { Array($0) }, forKey: Self.seenKey) }
    }

    /// Called with the latest milestones (`RetroStoryModel`).
    func check(_ milestones: [PlayStats.Milestone], now: Date = Date()) {
        let (fresh, known) = Self.newlyEarned(milestones, seen: seen, now: now)
        seen = known
        for milestone in fresh { announce(milestone) }
    }

    /// The decision, pure: which badges to announce, and the seen set after.
    /// No seen set yet (the first time): none, every badge marked seen. Then
    /// the ones not seen, earned within `freshWindow` and not `fromThePast`,
    /// oldest first.
    nonisolated static func newlyEarned(_ milestones: [PlayStats.Milestone], seen: Set<String>?,
                                        now: Date) -> (fresh: [PlayStats.Milestone], seen: Set<String>) {
        let ids = Set(milestones.map(\.id))
        guard let known = seen else { return ([], ids) }
        let fresh = milestones
            .filter { !known.contains($0.id) && !$0.fromThePast && now.timeIntervalSince($0.date) < freshWindow }
            .sorted { $0.date < $1.date }
        return (fresh, known.union(ids))
    }

    /// Queues the banner, as an unlock would (also the Debug preview's way
    /// in). A game's badge reads its cover first, off the main thread.
    func announce(_ milestone: PlayStats.Milestone) {
        let entry = Entry(milestone: milestone)
        queue.append(entry)
        guard let loadCover = Self.coverLoader(for: milestone) else {
            ready(entry.id, cover: nil)
            return
        }
        Task { [weak self] in
            let cover = await Task.detached(priority: .userInitiated) { loadCover() }.value
            self?.ready(entry.id, cover: cover)
        }
    }

    private func ready(_ id: UUID, cover: UIImage?) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].unlock = StoryBadgeUnlock(milestone: queue[index].milestone, cover: cover)
        advance()
    }

    /// The next banner, when none shows and the first in line is ready.
    private func advance() {
        guard current == nil, !resting, let unlock = queue.first?.unlock else { return }
        queue.removeFirst()
        current = unlock
    }

    /// A host shows the current banner (`StoryBadgeHUD`, `id` the banner it
    /// has on screen, nil when none). The first time a banner is shown, its
    /// sound, its haptic and its four seconds start, and then always run to
    /// the end. The clock is the announcer's, not the view's: a host leaving
    /// (the game closing, an RA banner taking the band) never ends the banner
    /// early nor leaves it stuck, and a badge earned while no host is on
    /// screen (Settings, a pushed page) waits for one, sound included.
    ///
    /// Reported by the HUD's own container, which is always there, when what
    /// it shows changes, not by the banner's `onAppear` (his reports of 10-29:
    /// banners that stayed for good, the second of two queued every time;
    /// the container's report fixed it, device-confirmed the same day). The
    /// one pause: while an RA banner holds the band (`raBandChanged`).
    func bannerShown(_ id: UUID?) {
        guard let id else { return }
        guard let unlock = current, unlock.id == id, timedID != id else { return }
        timedID = id
        // On the next turn, so nothing runs inside the banner's first frames.
        DispatchQueue.main.async { [haptics] in
            StoryBadgeSound.play()
            haptics.notificationOccurred(.success)
            haptics.prepare()
        }
        remaining = 4
        if !RetroAchievements.shared.holdsBannerBand { startClock(for: unlock) }
    }

    private func startClock(for unlock: StoryBadgeUnlock) {
        clock?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish(unlock) }
        clock = work
        clockEnds = Date().addingTimeInterval(remaining)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    /// An RA banner takes the band: the shown badge's time stops with what is
    /// left; the band is free again: it runs on from there.
    private func raBandChanged(_ holds: Bool) {
        guard let unlock = current, timedID == unlock.id else { return }
        if holds {
            guard let ends = clockEnds else { return }
            clock?.cancel()
            clock = nil
            clockEnds = nil
            remaining = max(0.5, ends.timeIntervalSinceNow)
        } else if clock == nil {
            startClock(for: unlock)
        }
    }

    private func finish(_ unlock: StoryBadgeUnlock) {
        guard current == unlock else { return }
        clock = nil
        clockEnds = nil
        current = nil
        resting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.resting = false
            self?.advance()
        }
    }

    /// How to read the cover of a game's badge: the library's row is read
    /// here, on the main thread; the returned work decodes the file, off it.
    /// nil for a badge of the whole story, or a game no longer in the library.
    private static func coverLoader(for milestone: PlayStats.Milestone) -> (@Sendable () -> UIImage?)? {
        guard let hash = StoryBadge.romHash(of: milestone.kind) else { return nil }
        let request = NSFetchRequest<GameEntity>(entityName: "GameEntity")
        request.predicate = NSPredicate(format: "romHash == %@", hash)
        request.fetchLimit = 1
        guard let game = try? PersistenceController.shared.container.viewContext.fetch(request).first else {
            return nil
        }
        // A demo game's cover is in the bundle (Presentation mode), as the tile reads it.
        if let demo = LibraryPresentation.cover(forROMPath: game.romFilePath) {
            return { demo.preparingForDisplay() ?? demo }
        }
        let filename = game.romFilePath
        let romHash = game.romHash
        let coverType = game.coverType
        let maxPixels = StoryBadgeBanner.iconSide * 3
        return {
            LibraryLandscapeCover.load(filename: filename, romHash: romHash,
                                       coverType: coverType, maxPixels: maxPixels)?.image
        }
    }
}

/// The badge sound: its own, not the RetroAchievements one. Follows the app's
/// audio rules (ambient, mixes with others, the silent switch silences it).
enum StoryBadgeSound {
    private static let player: AVAudioPlayer? = {
        guard let url = Bundle.main.url(forResource: "story-badge", withExtension: "wav"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        return player
    }()

    /// Loads the player and sets the session up ahead of the first unlock,
    /// off the main thread (the announcer's init).
    static func prepare() {
        _ = player
        configureSession()
    }

    /// The session is set once, in `prepare`: activating it is a round trip
    /// to the system's audio server, too slow for the banner's first frames.
    /// Set again only if the player could not start (the session was taken
    /// away, a call for one).
    static func play() {
        guard let player else { return }
        player.currentTime = 0
        if !player.play() {
            configureSession()
            player.play()
        }
    }

    private static func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: .mixWithOthers)
        try? session.setActive(true)
    }
}

/// The banner of a badge earned, at the top, as a RetroAchievements unlock is,
/// but its own: a see-through rounded rectangle of the look's glass and
/// accent with a gradient edge (the RA card is a
/// dark gold-edged card), the badge's picture (the game's cover first for a
/// game's badge), "New badge" above what it says, and a sheen of light that
/// crosses it once, the crown's metal catching the light. Never interactive;
/// four seconds, then the next one if two came at once.
struct StoryBadgeHUD: View {
    /// False while the host is out of sight but still in the hierarchy (the
    /// library under a game, or behind the Settings tab): a hidden host must
    /// not count as showing the banner, or its four seconds run unseen.
    var isActive: Bool = true
    @ObservedObject private var announcer = StoryBadgeAnnouncer.shared
    /// An RA unlock or mastery has the band first; the badge waits for it.
    @ObservedObject private var ra = RetroAchievements.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The top inset across windows, as the RA banner reads it.
    private var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .map { $0.safeAreaInsets.top }
            .max() ?? 0
    }

    /// The banner this host has on screen, nil when none.
    private var shownID: UUID? {
        isActive && !ra.holdsBannerBand ? announcer.current?.id : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if isActive, let unlock = announcer.current, !ra.holdsBannerBand {
                StoryBadgeBanner(unlock: unlock, sweeps: !reduceMotion)
                    .padding(.horizontal, 20)
                    .padding(.top, max(topInset, 12))
                    .id(unlock.id)
                    .transition(.move(edge: .top).combined(with: .scale(scale: 0.9)).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // In and out on the change, as the RA banner animates its own.
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: announcer.current)
        // Its time is the announcer's, from the first host that shows it,
        // reported by this container (always there) rather than by the
        // banner, whose own appearance SwiftUI did not always report.
        .onAppear { announcer.bannerShown(shownID) }
        .onChange(of: shownID) { id in announcer.bannerShown(id) }
    }
}

struct StoryBadgeBanner: View {
    let unlock: StoryBadgeUnlock
    var sweeps: Bool = true
    static let corner: CGFloat = 16
    /// The side of its picture, which the announcer draws and reads ahead.
    static let iconSide: CGFloat = 46
    @State private var sheen: CGFloat = -1

    var body: some View {
        HStack(spacing: 12) {
            StoryBadgeIcon(kind: unlock.milestone.kind, side: Self.iconSide, cover: unlock.cover)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("story.badge.new", comment: "").uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(LibraryLandscapePalette.highlight)
                Text(StoryBadge.title(unlock.milestone.kind))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.leading, 12)
        .padding(.trailing, 18)
        // A rounded rectangle (his ask of 10-29, less round than the
        // capsule), see-through: the look's ground faint, its accent fainter.
        .background(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(LibraryLandscapePalette.ground.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(LibraryLandscapePalette.accent.opacity(0.18)))
        )
        .overlay(
            // The sheen: a soft band of light crossing once.
            GeometryReader { geo in
                LinearGradient(colors: [.clear, .white.opacity(0.35), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.35)
                    .rotationEffect(.degrees(18))
                    .offset(x: sheen * geo.size.width)
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(LinearGradient(colors: [LibraryLandscapePalette.highlight.opacity(0.8),
                                                      LibraryLandscapePalette.accent.opacity(0.6)],
                                             startPoint: .leading, endPoint: .trailing),
                              lineWidth: 1.2)
        )
        .shadow(color: LibraryLandscapePalette.accent.opacity(0.45), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard sweeps else { return }
            withAnimation(.easeInOut(duration: 1.1).delay(0.35)) { sheen = 1.2 }
        }
    }
}
