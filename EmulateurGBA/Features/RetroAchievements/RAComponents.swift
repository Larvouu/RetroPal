//
//  RAComponents.swift
//  EmulateurGBA
//
//  Small shared RetroAchievements UI pieces used by more than one surface:
//  the section header carrying the official RA mark, and the "what is
//  RetroAchievements" explainer sheet (opened from every (i) button).
//

import SwiftUI

/// Section header with the official RA logo in front of the section title.
/// Optional (i) trailing button for surfaces that host the explainer sheet.
struct RASectionHeader: View {
    var title: String = "RetroAchievements"
    var onInfo: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image("RABrand")
                .resizable()
                .scaledToFit()
                .frame(height: 13)
                .accessibilityHidden(true)
            Text(title)
            if let onInfo {
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(String(localized: "ra.about.title",
                                                defaultValue: "About RetroAchievements")))
            }
        }
    }
}

/// One achievement row (badge, title, description, measured progress, rarity,
/// points, lock state) — the same rendering in the in-game dashboard and the
/// library profile's expanded games.
struct RAAchievementRow: View {
    let ach: RAAchievementInfo

    /// "12% of players" / "1.5% of players" (one decimal under 10%).
    static func rarityLabel(_ rarity: Double) -> String {
        let pct = rarity >= 10 ? String(format: "%.0f%%", rarity) : String(format: "%.1f%%", rarity)
        return String(format: String(localized: "ra.dashboard.rarity", defaultValue: "%@ of players"), pct)
    }

    var body: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(ach.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ach.unlocked ? .primary : .secondary)
                // Full description, always: a challenge you can't read is a
                // challenge you can't chase (was lineLimit(2) + "…").
                Text(ach.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = ach.measuredProgress, !ach.unlocked {
                    Text(progress)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                if ach.rarity > 0 {
                    Label(Self.rarityLabel(ach.rarity), systemImage: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(ach.points)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(ach.unlocked ? .primary : .secondary)
                if ach.unlocked {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.yellow)
                        .font(.footnote)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var badge: some View {
        // Raw square badge, exactly as RA serves it (locked rows use RA's own
        // locked artwork; no clipping, no extra fading).
        AsyncImage(url: ach.badgeURL.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Color.gray.opacity(0.15)
        }
        .frame(width: 44, height: 44)
    }
}

/// The compact badge wall, in the spirit of the retroachievements.org game
/// pages: every achievement as its badge in a tight grid. Locked badges use
/// RA's own locked artwork with NO extra fading (the art already reads as
/// locked). The caller decides what a tap does (share for unlocked, detail
/// sheet for locked).
struct RABadgeWall: View {
    let achievements: [RAAchievementInfo]
    let onTap: (RAAchievementInfo) -> Void

    static let columns = [GridItem(.adaptive(minimum: 40, maximum: 44), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 8) {
            ForEach(Array(achievements.enumerated()), id: \.offset) { _, ach in
                Button {
                    onTap(ach)
                } label: {
                    // Raw square badge, exactly as RA serves it (no clipping).
                    AsyncImage(url: ach.badgeURL.flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.gray.opacity(0.15)
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ach.title))
            }
        }
        .padding(.vertical, 4)
    }
}

/// The badge wall's loading shape: a grid of shimmering squares.
struct RABadgeWallSkeleton: View {
    var body: some View {
        LazyVGrid(columns: RABadgeWall.columns, spacing: 8) {
            ForEach(0..<12, id: \.self) { _ in
                SkeletonBox(cornerRadius: 7).frame(width: 40, height: 40)
            }
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}

/// The share + rows⇄wall action row shown under the header of both achievement
/// surfaces (profile page + game dashboard) — replaced the old toolbar buttons.
/// Rendered on the sheet/list background (the callers clear the row chrome).
struct RAActionsRow: View {
    let shareDisabled: Bool
    let onShare: () -> Void
    @Binding var wallLayout: Bool

    var body: some View {
        // Share first, the layout radio right beside it (one left-aligned
        // group, not pushed to opposite edges).
        HStack(spacing: 12) {
            Button(action: onShare) {
                Label {
                    Text(String(localized: "screenshot.share", defaultValue: "Share"))
                        .foregroundStyle(.primary)
                } icon: {
                    // The RA gold, tying the button to the surface it shares.
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.yellow)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(shareDisabled)
            .opacity(shareDisabled ? 0.4 : 1)
            .accessibilityLabel(Text(String(localized: "ra.share.progress",
                                            defaultValue: "Share your progress")))

            RALayoutRadio(wallLayout: $wallLayout)

            Spacer(minLength: 0)
        }
    }
}

/// Rows ⇄ badge wall as two GLUED rounded-square radio buttons; the selected
/// one reads as pressed (darker fill, primary ink).
struct RALayoutRadio: View {
    @Binding var wallLayout: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment("list.bullet", selected: !wallLayout) { wallLayout = false }
            segment("square.grid.3x3", selected: wallLayout) { wallLayout = true }
        }
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        .accessibilityLabel(Text(String(localized: "ra.layout.toggle",
                                        defaultValue: "Change achievements layout")))
    }

    private func segment(_ icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 44, height: 36)
                .background(selected ? Color(.systemFill) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

/// Full detail for one achievement, opened by tapping a locked badge in the
/// wall: badge as the hero, title, complete description, then the points it
/// awards and how many players have earned it (plus any measured progress).
/// A proper card, not a cramped row.
struct RABadgeDetailSheet: View {
    let ach: RAAchievementInfo

    private static let gold = Color(red: 0.98, green: 0.80, blue: 0.36)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AsyncImage(url: ach.badgeURL.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        Color.gray.opacity(0.15)
                        Image(systemName: "trophy")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .padding(.top, 28)

                VStack(spacing: 8) {
                    Text(ach.title)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(ach.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)

                if let progress = ach.measuredProgress {
                    chip {
                        Label(progress, systemImage: "chart.bar.fill")
                            .foregroundStyle(.tint)
                    }
                }

                HStack(spacing: 10) {
                    chip {
                        Label("\(ach.points) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))",
                              systemImage: "star.fill")
                            .foregroundStyle(Self.gold)
                    }
                    if ach.rarity > 0 {
                        chip {
                            Label(RAAchievementRow.rarityLabel(ach.rarity),
                                  systemImage: "person.2.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity)
        }
        // Compact by default (the content is a badge + a few lines; .medium
        // left a tall empty band), expandable for long descriptions.
        .presentationDetents([.fraction(0.45), .large])
        .presentationDragIndicator(.visible)
    }

    private func chip(@ViewBuilder content: () -> some View) -> some View {
        content()
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// The loading placeholder for an achievement row: the row's exact shape
/// (badge, two text lines, points) as shimmering blocks, so a fetch reads as
/// content-about-to-appear instead of a spinner in the void.
struct RAAchievementSkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBox(cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBox(cornerRadius: 4).frame(width: 150, height: 13)
                SkeletonBox(cornerRadius: 4).frame(width: 210, height: 10)
                SkeletonBox(cornerRadius: 4).frame(width: 70, height: 9)
            }
            Spacer(minLength: 4)
            SkeletonBox(cornerRadius: 4).frame(width: 24, height: 14)
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }
}

/// The explicit no-connection / load-failed state for an RA fetch: a short
/// explanation plus a retry button. Shown instead of content when the device
/// is offline or a load timed out (nothing ever loads forever).
struct RAOfflineRow: View {
    let isOffline: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(isOffline
                     ? String(localized: "ra.offline",
                              defaultValue: "No internet connection.")
                     : String(localized: "ra.load.failed",
                              defaultValue: "Achievements couldn't load. Check your connection and try again."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: isOffline ? "wifi.slash" : "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            Button(action: onRetry) {
                Text(String(localized: "ra.retry", defaultValue: "Try again"))
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

extension RAUnlockLogEntry {
    /// Bridge a locally logged unlock back to the share card's model.
    func asAchievementInfo() -> RAAchievementInfo {
        let info = RAAchievementInfo()
        info.title = title
        info.detail = detail
        info.points = points
        info.rarity = rarity
        info.badgeURL = badgeURL
        info.unlocked = true
        return info
    }
}

extension RAUnlock {
    /// Bridge a live unlock (HUD banner) to the share card's model.
    func asAchievementInfo() -> RAAchievementInfo {
        let info = RAAchievementInfo()
        info.title = title
        info.detail = detail
        info.points = points
        info.rarity = rarity
        info.badgeURL = badgeURL?.absoluteString
        info.unlocked = true
        return info
    }
}

/// The RetroAchievements explainer, for players who meet RA through Retro Pal:
/// what it is, and what softcore vs hardcore means. Presented as a medium
/// sheet from every RA (i) button (dashboard, Game Details, Library).
struct RAAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(String(localized: "ra.about.what",
                                defaultValue: "RetroAchievements is a free community project that adds achievements to classic games. You earn them by reaching milestones as you play, and they sync to your RetroAchievements profile."))
                    Text(String(localized: "ra.about.modes",
                                defaultValue: "You are earning in softcore, so you can use rewind, save states and slowdown and still keep every achievement. Hardcore is a pure, single-life challenge with those turned off. It arrives once Retro Pal has been on the App Store for six months, around December 2026."))
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Custom principal title: the default inline title truncates
                // long localizations ("À propos de RetroAchievements" -> "…").
                // This one shrinks instead, so the full text always shows on
                // one line.
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "ra.about.title", defaultValue: "About RetroAchievements"))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
