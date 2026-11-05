//
//  RetroStoryLandscapeView.swift
//  EmulateurGBA
//
//  The Retro story pages on their side (2026-10-28), in the landscape library's
//  language, laid out as the RetroAchievements page is: the look's ground, a
//  top bar of our own (back, title, controller badge, share), then a summary
//  column at the left and a scrolling column of glass cards at the right; on
//  an upright iPad the two stack in one scroll (`LandscapeChrome.isStacked`).
//
//  A LAYOUT, not a second page: `RetroStoryView` and `RetroStoryConsoleView`
//  keep their state, their sheets and their pushes, and hand this view their
//  sections as views. The rows are the upright page's own (`RetroStoryRows`),
//  so both orientations show the same thing.
//

import SwiftUI

/// The two-column landscape scaffold the story pages share.
struct RetroStoryLandscapeScaffold<Summary: View, Cards: View>: View {
    let title: String
    let backLabel: String
    let shareEnabled: Bool
    /// False while something covers the page (the year in review), which
    /// holds its ground still: two moving grounds at once is the heat the
    /// library's ground was tuned against.
    var isActive: Bool = true
    let onShare: () -> Void
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let cards: () -> Cards

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An iPad window: a wider summary column, a capped column of cards.
    @TabletSurface private var isTablet
    @Environment(\.surfaceSafeAreaInsets) private var surfaceInsets
    /// Observed so a theme change repaints this surface.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let insets = LandscapeChrome.insets(surfaceInsets)
            ZStack {
                LibraryLandscapeBackground(isPaused: reduceMotion || !isActive, dimmed: true)

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 24)
                        .padding(.top, LandscapeChrome.barTopPadding(tablet: isTablet, insets: insets))
                    Group {
                        if LandscapeChrome.isStacked(tablet: isTablet, size: size) {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 12) {
                                    summary()
                                    cards()
                                }
                                .frame(maxWidth: 720)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 8)
                            }
                        } else {
                            HStack(alignment: .top, spacing: 20) {
                                // The summary scrolls on its own when it is
                                // taller than a phone on its side.
                                ScrollView(.vertical, showsIndicators: false) {
                                    VStack(spacing: 12) { summary() }
                                        .padding(.bottom, 8)
                                }
                                .frame(width: isTablet ? 360 : 300)
                                ScrollView(.vertical, showsIndicators: false) {
                                    VStack(spacing: 12) { cards() }
                                        .padding(.bottom, 8)
                                }
                                .frame(maxWidth: isTablet ? 720 : .infinity)
                            }
                        }
                    }
                    .padding(.leading, 24 + insets.left)
                    .padding(.trailing, 24 + insets.right)
                    .padding(.top, 16)
                    .padding(.bottom, 22)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // B goes back, as the back button does (`ControllerNavigator`).
        .controllerBack { dismiss() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            FocusableButton(shape: .capsule) {
                dismiss()
            } label: {
                LandscapeChrome.circle(systemName: "chevron.left")
            }
            .accessibilityLabel(backLabel)
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            ControllerStatusBadge(tint: .white)
            FocusableButton(shape: .capsule, action: onShare) {
                LandscapeChrome.circle(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(NSLocalizedString("screenshot.share", comment: ""))
            .disabled(!shareEnabled)
            .opacity(shareEnabled ? 1 : 0.4)
        }
        .frame(height: 40)
    }
}

/// A glass card holding rows, with an optional title and footnote, the RA
/// page's card (`LandscapeChrome.card`) with hairlines between the rows.
struct RetroStoryLandscapeCard<Rows: View>: View {
    let title: String?
    var footnote: String? = nil
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        LandscapeChrome.card(title) {
            VStack(alignment: .leading, spacing: 10) {
                rows()
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A hairline inside a landscape card, between the most played and the rest.
struct RetroStoryDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}
