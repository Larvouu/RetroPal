//
//  ProUpgradeView.swift
//  EmulateurGBA
//
//  Orchestrator for the Pro upgrade sheet. Routes between portrait and
//  landscape layouts; branches landscape between contextual (9 triggered
//  sheets) and comparison (.tappedLockedFeature) treatments. Composes
//  reusable components from Features/Pro/Components/ so portrait and
//  landscape share a single source of truth for every visual atom.
//
//  Portrait: single scroll with crown → pitch → benefits → CTAs.
//  Landscape contextual: 2-column — hero left + mini-card grid right +
//    pinned CTA strip. sessionMilestone (no featured) → 5-card vertical
//    stack on the right instead of a 2×2 grid.
//  Landscape comparison: single-column paralleling portrait — slim
//    crown+title header + full-width table + pinned CTAs.
//

import SwiftUI
import StoreKit

struct ProUpgradeView: View {
    let context: ProPromptContext

    @ObservedObject private var proManager = ProManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showComparison: Bool = false

    init(context: ProPromptContext = .tappedLockedFeature) {
        self.context = context
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            ProPalette.bgGradient.ignoresSafeArea()

            if verticalSizeClass == .compact {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .sheet(isPresented: $showComparison) {
            // Nested comparison sheet (from "See all benefits" link).
            // Same view re-presented with the comparison context — inherits
            // whatever layout the device orientation demands.
            ProUpgradeView(context: .tappedLockedFeature)
                .presentationDetents([.large])
        }
        .onChange(of: proManager.isPro) { newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
            }
        }
    }

    // MARK: - Portrait layout (visual unchanged)

    private var portraitLayout: some View {
        ZStack {
            // Glow floats above the crown — original portrait treatment.
            GlowCircle(size: 280)
                .offset(y: -220)

            ScrollView {
                VStack(spacing: 20) {
                    AnimatedCrown()
                        .padding(.top, 32)

                    if context == .tappedLockedFeature {
                        comparisonContent
                    } else {
                        Text(headline)
                            .font(.title3.bold())
                            .foregroundStyle(ProPalette.crownGradient)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 28)

                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 28)

                        portraitBenefits
                    }

                    Spacer(minLength: 16)

                    ProCTAStrip(compact: false, onDismiss: { dismiss() })
                        .padding(.bottom, 8)

                    legalFooter
                        .padding(.bottom, 16)
                }
            }
        }
    }

    /// Featured MiniBenefitCard + caption-style other-benefits list +
    /// "See all benefits" link. Portrait-specific — landscape uses a 2×2
    /// grid of mini cards instead of the caption list.
    @ViewBuilder
    private var portraitBenefits: some View {
        VStack(spacing: 20) {
            if let featured = featuredBenefit {
                MiniBenefitCard(icon: featured.icon,
                                text: featured.text,
                                style: .featured)
                    .padding(.horizontal, 28)
            }

            // Subtle caption list — intentionally low-emphasis in portrait
            // (mini-card treatment is reserved for the featured card here;
            // landscape promotes everything to cards to use the extra
            // horizontal room). Portrait visual identical to pre-refactor.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(otherBenefits, id: \.text) { benefit in
                    HStack(spacing: 12) {
                        Image(systemName: benefit.icon)
                            .frame(width: 20)
                            .foregroundStyle(.white.opacity(0.4))
                            .font(.system(size: 13))
                        Text(benefit.text)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 32)

            Button {
                showComparison = true
            } label: {
                Text(NSLocalizedString("pro.seeAllBenefits", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .underline()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Landscape layout (branches on context)

    @ViewBuilder
    private var landscapeLayout: some View {
        if context == .tappedLockedFeature {
            landscapeComparisonLayout
        } else {
            landscapeContextualLayout
        }
    }

    /// Single-column flow paralleling portrait structure — slim header
    /// (inline crown + title) + full-width table + pinned CTAs.
    private var landscapeComparisonLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AnimatedCrown(size: 24)
                Text(NSLocalizedString("prompt.generic.title", comment: ""))
                    .font(.title3.bold())
                    .foregroundStyle(ProPalette.crownGradient)
            }
            .padding(.vertical, 10)

            ScrollView {
                comparisonTable(rowPadding: 4)
                    .padding(.bottom, 8)
            }

            Divider().background(Color.white.opacity(0.08))

            ProCTAStrip(compact: true, onDismiss: { dismiss() })
                .padding(.top, 8)
                .padding(.bottom, 4)

            legalFooter
                .padding(.bottom, 8)
        }
    }

    /// 2-column layout for the 9 contextual sheets. Left = hero, Right =
    /// benefit cards + pinned CTAs. sessionMilestone (nil featuredBenefit)
    /// swaps the 2×2 grid for a 5-card vertical stack on the right.
    private var landscapeContextualLayout: some View {
        HStack(spacing: 0) {
            LandscapeContextualHero(
                headline: headline,
                subtitle: subtitle,
                featuredIcon: featuredBenefit?.icon,
                featuredText: featuredBenefit?.text
            )
            .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                ScrollView {
                    if featuredBenefit == nil {
                        sessionMilestoneStack
                    } else {
                        contextualBenefitsGrid
                    }
                }
                .padding(.top, 40)
                .padding(.bottom, 8)

                Divider().background(Color.white.opacity(0.08))

                ProCTAStrip(compact: true, onDismiss: { dismiss() })
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                legalFooter
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Legal footer (App Store Guideline 3.1.2(c))

    /// Mandatory pair of links visible during the subscription purchase
    /// flow. Apple requires a functional Terms of Use (EULA) link and a
    /// functional Privacy Policy link inside the app whenever auto-renewable
    /// subscriptions are offered. Initial v1.0 submission was rejected for
    /// missing these links; this view satisfies the requirement.
    @ViewBuilder
    private var legalFooter: some View {
        HStack(spacing: 10) {
            Link(destination: termsURL) {
                Text(NSLocalizedString("pro.legal.terms", comment: ""))
                    .underline()
            }
            Text("·")
                .foregroundColor(.white.opacity(0.25))
            Link(destination: privacyURL) {
                Text(NSLocalizedString("pro.legal.privacy", comment: ""))
                    .underline()
            }
        }
        .font(.caption2)
        .foregroundColor(.white.opacity(0.55))
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    /// Locale-aware Terms URL. FR users land on the French CGU page; every
    /// other locale falls back to the English version on retropal.fr.
    private var termsURL: URL {
        let lang = Locale.current.language.languageCode?.identifier ?? "fr"
        let path = (lang == "fr") ? "/conditions" : "/en/terms"
        return URL(string: "https://retropal.fr\(path)")!
    }

    /// Locale-aware Privacy URL. Same fallback rule as termsURL.
    private var privacyURL: URL {
        let lang = Locale.current.language.languageCode?.identifier ?? "fr"
        let path = (lang == "fr") ? "/confidentialite" : "/en/privacy"
        return URL(string: "https://retropal.fr\(path)")!
    }

    /// 2×2 grid of mini benefit cards + "See all benefits" link.
    /// Used when a featured benefit is shown on the left (8 of 9 contextual).
    @ViewBuilder
    private var contextualBenefitsGrid: some View {
        VStack(spacing: 14) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8),
                          GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(otherBenefits, id: \.text) { benefit in
                    MiniBenefitCard(icon: benefit.icon,
                                    text: benefit.shortText,
                                    style: .mini)
                }
            }
            .padding(.horizontal, 16)

            Button {
                showComparison = true
            } label: {
                Text(NSLocalizedString("pro.seeAllBenefits", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .underline()
            }
        }
    }

    /// Single-column stack of all 5 benefit cards. Used for sessionMilestone
    /// where no featured benefit sits on the left (the hero is text-only).
    /// Uniform rhythm, no empty grid cells.
    @ViewBuilder
    private var sessionMilestoneStack: some View {
        VStack(spacing: 6) {
            ForEach(allBenefits, id: \.text) { benefit in
                MiniBenefitCard(icon: benefit.icon,
                                text: benefit.shortText,
                                style: .mini)
            }

            Button {
                showComparison = true
            } label: {
                Text(NSLocalizedString("pro.seeAllBenefits", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .underline()
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Contextual content resolution

    private var headline: String {
        switch context {
        case .speedMoment(let minutes):
            return String(format: NSLocalizedString("prompt.speed.title", comment: ""), "\(minutes)")
        case .speedTapped:
            return NSLocalizedString("prompt.speedTapped.title", comment: "")
        case .saveSlotFull:
            return NSLocalizedString("prompt.slots.title", comment: "")
        case .saveSlotTapped:
            return NSLocalizedString("prompt.slotsTapped.title", comment: "")
        case .sessionMilestone(let minutes):
            return String(format: NSLocalizedString("prompt.milestone.title", comment: ""), "\(minutes)")
        case .rewindLimit:
            return NSLocalizedString("prompt.rewind.title", comment: "")
        case .cheatCodes(let gameName):
            return String(format: NSLocalizedString("prompt.cheats.title", comment: ""), gameName)
        case .cheatCodesTapped:
            return NSLocalizedString("prompt.cheatsTapped.title", comment: "")
        case .tappedLockedFeature:
            return NSLocalizedString("prompt.generic.title", comment: "")
        case .customizeControls:
            return NSLocalizedString("prompt.controls.title", comment: "")
        }
    }

    private var subtitle: String {
        switch context {
        case .speedMoment:
            return NSLocalizedString("prompt.speed.subtitle", comment: "")
        case .speedTapped:
            return NSLocalizedString("prompt.speedTapped.subtitle", comment: "")
        case .saveSlotFull:
            return NSLocalizedString("prompt.slots.subtitle", comment: "")
        case .saveSlotTapped:
            return NSLocalizedString("prompt.slotsTapped.subtitle", comment: "")
        case .sessionMilestone:
            return NSLocalizedString("prompt.milestone.subtitle", comment: "")
        case .rewindLimit:
            return NSLocalizedString("prompt.rewind.subtitle", comment: "")
        case .cheatCodes:
            return NSLocalizedString("prompt.cheats.subtitle", comment: "")
        case .cheatCodesTapped:
            return NSLocalizedString("prompt.cheatsTapped.subtitle", comment: "")
        case .tappedLockedFeature:
            return NSLocalizedString("prompt.generic.subtitle", comment: "")
        case .customizeControls:
            return NSLocalizedString("prompt.controls.subtitle", comment: "")
        }
    }

    // MARK: - Benefit catalogue

    private struct Benefit: Hashable {
        let icon: String
        /// Full label with detail in parentheses — used in portrait's
        /// "other benefits" caption list and in the featured card on both
        /// orientations. Enough horizontal room to show all detail.
        let text: String
        /// Terse label with parentheticals stripped — used in the landscape
        /// 2×2 mini-card grid + sessionMilestone 5-card stack where card
        /// width is narrow. Avoids "…" truncation at Dynamic Type Large
        /// across German/Polish/Dutch.
        let shortText: String
    }

    private var allBenefits: [Benefit] {
        [
            Benefit(icon: "gauge.high",
                    text: NSLocalizedString("pro.benefit.speed", comment: ""),
                    shortText: NSLocalizedString("pro.benefit.speed.short", comment: "")),
            Benefit(icon: "tray.2",
                    text: NSLocalizedString("pro.benefit.slots", comment: ""),
                    shortText: NSLocalizedString("pro.benefit.slots.short", comment: "")),
            Benefit(icon: "backward.fill",
                    text: NSLocalizedString("pro.benefit.rewind", comment: ""),
                    shortText: NSLocalizedString("pro.benefit.rewind.short", comment: "")),
            Benefit(icon: "command",
                    text: NSLocalizedString("pro.benefit.cheats", comment: ""),
                    shortText: NSLocalizedString("pro.benefit.cheats.short", comment: "")),
            Benefit(icon: "hand.draw",
                    text: NSLocalizedString("pro.benefit.controls", comment: ""),
                    shortText: NSLocalizedString("pro.benefit.controls.short", comment: "")),
        ]
    }

    private var featuredBenefit: Benefit? {
        switch context {
        case .speedMoment, .speedTapped:       return allBenefits[0]
        case .saveSlotFull, .saveSlotTapped:   return allBenefits[1]
        case .rewindLimit:                     return allBenefits[2]
        case .cheatCodes, .cheatCodesTapped:   return allBenefits[3]
        case .customizeControls:               return allBenefits[4]
        case .sessionMilestone, .tappedLockedFeature:
            return nil
        }
    }

    private var otherBenefits: [Benefit] {
        if let featured = featuredBenefit {
            return allBenefits.filter { $0 != featured }
        }
        return allBenefits
    }

    // MARK: - Comparison table

    private struct ComparisonRow {
        enum Cell { case check, none, text(String) }
        let label: String
        let free: Cell
        let pro: Cell
    }

    private var sharedRows: [ComparisonRow] {
        [
            ComparisonRow(label: NSLocalizedString("pro.compare.row.noAds",       comment: ""), free: .check, pro: .check),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.allSystems",  comment: ""), free: .check, pro: .check),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.autoSave",    comment: ""), free: .check, pro: .check),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.iCloud",      comment: ""), free: .check, pro: .check),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.controllers", comment: ""), free: .check, pro: .check),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.screenshots", comment: ""), free: .check, pro: .check),
        ]
    }

    private var proRows: [ComparisonRow] {
        [
            ComparisonRow(label: NSLocalizedString("pro.compare.row.slots", comment: ""),
                          free: .text("2"), pro: .text("5")),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.speeds", comment: ""),
                          free: .text(NSLocalizedString("pro.compare.values.freeSpeeds", comment: "")),
                          pro: .text(NSLocalizedString("pro.compare.values.proSpeeds", comment: ""))),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.rewind", comment: ""),
                          free: .text("5s"), pro: .text("30s")),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.cheats", comment: ""),
                          free: .none, pro: .check),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.controls", comment: ""),
                          free: .none,
                          pro: .text(NSLocalizedString("pro.compare.values.proControls", comment: ""))),
        ]
    }

    /// Portrait comparison: gold title above the table.
    @ViewBuilder
    private var comparisonContent: some View {
        Text(NSLocalizedString("prompt.generic.title", comment: ""))
            .font(.title3.bold())
            .foregroundStyle(ProPalette.crownGradient)
            .padding(.horizontal, 28)

        comparisonTable(rowPadding: 6)
    }

    /// Free-vs-Pro table. Row vertical padding parameterizable so landscape
    /// can pass 4 (tighter) while portrait keeps 6.
    @ViewBuilder
    private func comparisonTable(rowPadding: CGFloat) -> some View {
        VStack(spacing: 10) {
            // Column headers
            HStack(spacing: 0) {
                Text("")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(NSLocalizedString("pro.compare.header.free", comment: ""))
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 80)
                Text(NSLocalizedString("pro.compare.header.pro", comment: ""))
                    .font(.caption.bold())
                    .foregroundStyle(ProPalette.crownGradient)
                    .frame(width: 80)
            }
            .padding(.bottom, 2)

            ForEach(sharedRows.indices, id: \.self) { i in
                comparisonRowView(sharedRows[i], rowPadding: rowPadding)
            }

            // "Pro adds" divider
            HStack(spacing: 10) {
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                Text(NSLocalizedString("pro.compare.sectionDivider", comment: ""))
                    .font(.caption2.bold())
                    .foregroundColor(.white.opacity(0.5))
                    .tracking(1)
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            }
            .padding(.vertical, 6)

            ForEach(proRows.indices, id: \.self) { i in
                comparisonRowView(proRows[i], rowPadding: rowPadding)
            }
        }
        .padding(.horizontal, 20)
    }

    private func comparisonRowView(_ row: ComparisonRow, rowPadding: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(row.label)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            comparisonCell(row.free, highlighted: false)
                .frame(width: 80)

            comparisonCell(row.pro, highlighted: true)
                .frame(width: 80)
        }
        .padding(.vertical, rowPadding)
    }

    @ViewBuilder
    private func comparisonCell(_ cell: ComparisonRow.Cell, highlighted: Bool) -> some View {
        switch cell {
        case .check:
            if highlighted {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ProPalette.crownGradient)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
            }
        case .none:
            Text("—")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.25))
        case .text(let value):
            if highlighted {
                Text(value)
                    .font(.caption.bold())
                    .foregroundStyle(ProPalette.crownGradient)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else {
                Text(value)
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.6))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
    }
}
