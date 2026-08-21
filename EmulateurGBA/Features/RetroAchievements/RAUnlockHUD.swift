//
//  RAUnlockHUD.swift
//  EmulateurGBA
//
//  Transient in-game celebration for a RetroAchievements unlock. Observes the
//  shared manager's `lastUnlock` and auto-dismisses after a few seconds. Pure
//  celebration: never interactive, never a Pro trigger.
//

import SwiftUI

struct RAUnlockHUD: View {
    @ObservedObject private var ra = RetroAchievements.shared

    private static let gold = LinearGradient(
        colors: [Color(red: 1.0, green: 0.90, blue: 0.55), Color(red: 0.95, green: 0.72, blue: 0.25)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Top safe-area inset, taken as the MAX across every window so we never
    /// pick a 0-inset auxiliary window. In portrait on notched / Dynamic Island
    /// devices this sits BELOW the Island + status bar (~59pt), so the HUD clears
    /// it; in landscape it's ~0 (the Island is on the side). Read live so a
    /// rotation is reflected.
    private var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .map { $0.safeAreaInsets.top }
            .max() ?? 0
    }

    /// Tapping the card opens that achievement's share card (set by the host).
    /// The unlock is handed over because the HUD auto-clears `lastUnlock`.
    var onTap: ((RAUnlock) -> Void)?

    init(onTap: ((RAUnlock) -> Void)? = nil) { self.onTap = onTap }

    var body: some View {
        // A VStack with a trailing Spacer: only the card is hit-testable, the
        // empty space below never intercepts gameplay touches while the HUD shows.
        VStack(spacing: 0) {
            if let unlock = ra.lastUnlock {
                card(unlock)
                    .padding(.horizontal, 20)
                    .padding(.top, max(topInset, 12))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?(unlock) }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: unlock.id) {
                        try? await Task.sleep(nanoseconds: 4_200_000_000)
                        withAnimation { ra.lastUnlock = nil }
                    }
            }
            // Mastery waits for the unlock banner to clear rather than shouting
            // over it. rc_client sends GAME_COMPLETED immediately after the
            // final achievement's TRIGGERED, so without this the two would
            // occupy the same position in the same instant and the bigger of
            // the two moments would be the one that got lost.
            if ra.lastUnlock == nil, let mastery = ra.lastMastery {
                masteryCard(mastery)
                    .padding(.horizontal, 20)
                    .padding(.top, max(topInset, 12))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: mastery.id) {
                        // Longer than an unlock's 4.2s: it is the rarer moment
                        // and there is no next banner queued behind it.
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        withAnimation { ra.lastMastery = nil }
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: ra.lastUnlock)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: ra.lastMastery)
    }

    /// Deliberately NOT tappable, unlike the unlock card. There is no share
    /// card for a mastery yet, and a tap that does nothing reads as broken.
    ///
    /// The banner says COMPLETED, not mastered, and the difference is the RA
    /// community's own: `rc_client` writes "mastered" for a hardcore finish and
    /// "completed" for a softcore one (`rc_client.c`, the achievement summary).
    /// Retro Pal is softcore only until hardcore ships, so "mastered" would
    /// credit the player with something they did not do, in the exact vocabulary
    /// they would notice. **When hardcore ships, this branches rather than
    /// reverts:** hardcore earns the other word.
    @ViewBuilder
    private func masteryCard(_ mastery: RAMastery) -> some View {
        HStack(spacing: 12) {
            Image(systemName: mastery.isSubset ? "rosette" : "crown.fill")
                .resizable().scaledToFit().padding(9)
                .foregroundStyle(Self.gold)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(mastery.isSubset
                     ? NSLocalizedString("ra.hud.subsetCompleted", comment: "")
                     : NSLocalizedString("ra.hud.gameCompleted", comment: ""))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Self.gold)
                Text(mastery.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if mastery.points > 0 {
                Text("\(mastery.points)")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Self.gold)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Self.gold, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private func card(_ unlock: RAUnlock) -> some View {
        HStack(spacing: 12) {
            badge(unlock)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "ra.hud.unlocked", defaultValue: "Achievement unlocked"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Self.gold)
                Text(unlock.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if unlock.points > 0 {
                Text("+\(unlock.points)")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Self.gold)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Self.gold.opacity(0.7), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private func badge(_ unlock: RAUnlock) -> some View {
        Group {
            if let url = unlock.badgeURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
            } else {
                Image(systemName: "trophy.fill")
                    .resizable().scaledToFit().padding(10)
                    .foregroundStyle(Self.gold)
            }
        }
        .frame(width: 46, height: 46)
    }
}
