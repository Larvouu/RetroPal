//
//  RAProgressHUD.swift
//  EmulateurGBA
//
//  Transient in-game pill for a MEASURED achievement progressing (e.g. one
//  more of the 151 caught): the achievement's badge + "42/151". Discreet
//  sibling of RAUnlockHUD — smaller, trailing-aligned so it never covers the
//  centered unlock banner, never interactive, auto-dismissing. Show/hide is
//  driven by rc_client's progress-indicator events, with a local timeout as a
//  safety net (a pause stops the frame loop, so the hide event may never come).
//

import SwiftUI

struct RAProgressHUD: View {
    @ObservedObject private var ra = RetroAchievements.shared

    private static let gold = LinearGradient(
        colors: [Color(red: 1.0, green: 0.90, blue: 0.55), Color(red: 0.95, green: 0.72, blue: 0.25)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Same max-across-windows top inset as RAUnlockHUD (clears the Dynamic
    /// Island in portrait, ~0 in landscape).
    private var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .map { $0.safeAreaInsets.top }
            .max() ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            if let indicator = ra.progressIndicator {
                HStack {
                    Spacer(minLength: 0)
                    pill(indicator)
                }
                .padding(.trailing, 16)
                // Sits below the unlock banner's band so a chained unlock +
                // progress never collide.
                .padding(.top, max(topInset, 12) + 74)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .task(id: indicator.id) {
                    // Safety net: rc_client hides after ~2s of frames; if the
                    // game gets paused meanwhile, clear locally.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { ra.progressIndicator = nil }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: ra.progressIndicator)
    }

    private func pill(_ indicator: RAProgressIndicator) -> some View {
        HStack(spacing: 8) {
            badge(indicator)
            VStack(alignment: .leading, spacing: 1) {
                Text(indicator.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(indicator.progress)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Self.gold)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(Self.gold.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .frame(maxWidth: 240, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func badge(_ indicator: RAProgressIndicator) -> some View {
        Group {
            if let url = indicator.badgeURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
            } else {
                Image(systemName: "chart.bar.fill")
                    .resizable().scaledToFit().padding(6)
                    .foregroundStyle(Self.gold)
            }
        }
        .frame(width: 26, height: 26)
    }
}

/// Transient in-game capsule for the RA tracking state: "achievements paused"
/// when the set could not load (offline launch — never silent), and the brief
/// "achievements active" when the automatic retry brings tracking back.
/// LEADING-aligned in the progress pill's band, so the two never collide.
struct RASessionNoticeHUD: View {
    @ObservedObject private var ra = RetroAchievements.shared

    private var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .map { $0.safeAreaInsets.top }
            .max() ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = ra.sessionNotice {
                HStack {
                    capsule(notice)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                // The progress pill's band (below the unlock banner).
                .padding(.top, max(topInset, 12) + 74)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .task(id: notice.id) {
                    // The pause notice lingers a little longer than the
                    // celebration ones; both self-clear.
                    try? await Task.sleep(nanoseconds: notice.resumed ? 3_000_000_000 : 5_000_000_000)
                    withAnimation { ra.sessionNotice = nil }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: ra.sessionNotice)
    }

    private func capsule(_ notice: RASessionNotice) -> some View {
        HStack(spacing: 7) {
            Image(systemName: notice.resumed ? "trophy.fill" : "wifi.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(notice.resumed
                                 ? Color(red: 0.98, green: 0.80, blue: 0.36)
                                 : Color.white.opacity(0.75))
            Text(notice.resumed
                 ? String(localized: "ra.session.resumed", defaultValue: "Achievements active")
                 : String(localized: "ra.session.offline",
                          defaultValue: "Achievements paused while offline. They resume automatically."))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .frame(maxWidth: 250, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
