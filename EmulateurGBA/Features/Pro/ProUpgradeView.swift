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
//  Landscape contextual: 2-column — the "everything else" benefit list on
//    the left, the compact Free→Pro hero + headline on the right with the
//    price pinned right/bottom. sessionMilestone → full bundle card left.
//  Landscape comparison: 3-column — the always-included baseline (Free==Pro)
//    in a neutral card, what Pro adds in the neon card, and a purchase panel
//    (brand + price) on the right.
//

import SwiftUI
import StoreKit

struct ProUpgradeView: View {
    let context: ProPromptContext
    private let isNested: Bool

    @ObservedObject private var proManager = ProManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showComparison: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(context: ProPromptContext = .tappedLockedFeature, isNested: Bool = false) {
        self.context = context
        self.isNested = isNested
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
            ProUpgradeView(context: .tappedLockedFeature, isNested: true)
                .presentationDetents([.large])
        }
        .onChange(of: proManager.isPro) { newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
            }
        }
        .onAppear {
            guard !isNested else { return }   // skip the "see all benefits" drill-down
            proManager.activeTrigger = context
            Analytics.signal("pro_sheet_shown", ["trigger": context.analyticsID])
        }
    }

    // MARK: - Portrait layout

    /// Every contextual trigger with a single featured benefit gets the card-led
    /// treatment (a Free→Pro hero + the bundle strip). sessionMilestone (no
    /// featured benefit) and the deliberate .tappedLockedFeature comparison keep
    /// the comparison table in a card; sessionMilestone → a full-bundle card.
    @ViewBuilder
    private var portraitLayout: some View {
        if heroConfig != nil {
            contextualCardPortrait
        } else if context == .tappedLockedFeature {
            comparisonCardPortrait
        } else {
            sessionMilestonePortrait
        }
    }

    /// Card-led contextual sheet: a Free→Pro hero card for the triggered
    /// benefit, the earned headline, the "everything else" bundle strip (two
    /// rows of badges since the skins benefit), the CTA strip, and the
    /// (mandatory) legal footer. Compact metrics throughout so everything
    /// stays visible without scrolling down to SE-class heights; the
    /// ScrollView remains as a safety net (large Dynamic Type).
    ///
    /// The stack stretches to the full sheet height (GeometryReader) so the
    /// two flexible spacers can absorb the slack on tall sheets: the CTA
    /// block lands in the bottom thumb zone and the hero group sits visually
    /// balanced instead of hugging the top with dead space below. On short
    /// heights the spacers collapse to their minimums and the ScrollView
    /// takes over, exactly as before.
    private var contextualCardPortrait: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 14) {
                    Spacer(minLength: 16)

                    if let hero = heroConfig {
                        ProFeatureHeroCard(reduceMotion: reduceMotion,
                                           icon: hero.icon, title: hero.title,
                                           freeLabel: hero.free, proLabel: hero.pro)
                            .padding(.horizontal, 24)
                    }

                    VStack(spacing: 8) {
                        Text(headline)
                            .font(.title3.bold())
                            .foregroundStyle(ProPalette.crownGradient)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 28)

                    // Everything else Pro unlocks — a glanceable icon strip so the
                    // full bundle stays visible (value-stacking to justify the
                    // price) without bringing back a text wall.
                    VStack(spacing: 8) {
                        Text(NSLocalizedString("pro.compare.sectionDivider", comment: ""))
                            .font(.caption2.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.4))
                        ProBenefitStrip(items: otherBenefits.map {
                            ProBenefitStrip.Item(icon: $0.icon, label: $0.shortText)
                        })
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 8)

                    ProCTAStrip(compact: false, onDismiss: { dismiss() })

                    Button {
                        showComparison = true
                    } label: {
                        Text(NSLocalizedString("pro.seeAllBenefits", comment: ""))
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                            .underline()
                    }

                    legalFooter
                        .padding(.bottom, 10)
                }
                .frame(width: geo.size.width)
                .frame(minHeight: geo.size.height)
            }
        }
    }

    // MARK: - Comparison sheet (deliberate "see all Pro" — high intent)

    /// The full Free-vs-Pro table wrapped in a premium card. This is the
    /// analytical surface, so the table IS the right content; the card frame
    /// just brings it into the same visual language. Static (no motion) — a
    /// dense table is for reading, not spectacle.
    /// Compact metrics throughout (row padding 3, row spacing 4, tighter card +
    /// section paddings) so the full table, CTA and legal footer fit the portrait
    /// sheet without scrolling; the ScrollView stays as a safety net for the
    /// smallest devices / large Dynamic Type.
    private var comparisonCardPortrait: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Header slightly smaller than before (headline + a 22pt crown)
                // in exchange for more air around it, keeping the no-scroll fit.
                HStack(spacing: 8) {
                    AnimatedCrown(size: 22)
                    Text(NSLocalizedString("prompt.generic.title", comment: ""))
                        .font(.headline)
                        .foregroundStyle(ProPalette.crownGradient)
                }
                .padding(.top, 24)
                .padding(.bottom, 6)

                comparisonTable(rowPadding: 3, rowSpacing: 4)
                    .padding(.vertical, 12)
                    .background(proCardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(proCardBorder)
                    .shadow(color: Color(red: 0.45, green: 0.2, blue: 0.85).opacity(0.35), radius: 14, y: 6)
                    .padding(.horizontal, 16)

                Spacer(minLength: 4)

                ProCTAStrip(compact: false, onDismiss: { dismiss() })
                    .padding(.bottom, 4)

                legalFooter
                    .padding(.bottom, 10)
            }
        }
    }

    // MARK: - Session-milestone sheet (no single feature — sell the whole bundle)

    /// A "you've played a while" moment where the whole bundle is the pitch, so
    /// the hero is a premium card listing every benefit under the milestone
    /// headline.
    private var sessionMilestonePortrait: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text(headline)
                        .font(.title3.bold())
                        .foregroundStyle(ProPalette.crownGradient)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 28)
                .padding(.horizontal, 28)

                bundleCard()
                    .padding(.horizontal, 24)

                Spacer(minLength: 12)

                ProCTAStrip(compact: false, onDismiss: { dismiss() })
                    .padding(.bottom, 8)

                legalFooter
                    .padding(.bottom, 16)
            }
        }
    }

    /// Premium card listing the full Pro bundle (every benefit as a gold icon +
    /// label). Used by the session-milestone sheet (no single benefit to hero).
    ///
    /// `dense: true` is the narrow-column variant (landscape comparison): a
    /// tighter purple glow and smaller benefit rows so labels wrap to fewer
    /// lines in a ~1/3-width column.
    /// `fillHeight: true` stretches the card to its host's full height with the
    /// content centered — used so the comparison columns can be the same height.
    private func bundleCard(dense: Bool = false, fillHeight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: dense ? 10 : 14) {
            Text(NSLocalizedString("pro.compare.sectionDivider", comment: ""))
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .center)

            benefitRows(allBenefits, compact: dense)
        }
        .padding(.vertical, dense ? 14 : 22)
        .padding(.horizontal, dense ? 16 : 22)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .center)
        .background(proCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(proCardBorder)
        .shadow(color: Color(red: 0.45, green: 0.2, blue: 0.85).opacity(dense ? 0.22 : 0.35),
                radius: dense ? 7 : 14, y: dense ? 4 : 6)
    }

    /// Vertical list of benefits (gold icon badge + label). Shared by the
    /// bundle card and the landscape "everything else" column. `compact`
    /// shrinks the icon and text so labels fit a narrow column in fewer lines.
    @ViewBuilder
    private func benefitRows(_ benefits: [Benefit], compact: Bool = false) -> some View {
        // Compact metrics tightened 2026-07-25 (spacing 9→7, badge 26→24):
        // the 7th benefit (video filters) has to fit the landscape card
        // heights where 6 fitted before.
        //
        // 2026-07-27, on device: with the 8th benefit the landscape card
        // scrolled instead of fitting. The cause was not spacing — `compact`
        // was rendering `text`, the full label with its parentheticals, in the
        // narrowest column in the app. `shortText` exists precisely for this
        // ("Codes triche (GameShark / Action Replay)" becomes "Codes de
        // triche"), so the wrapped lines were self-inflicted.
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            ForEach(benefits, id: \.text) { benefit in
                HStack(spacing: compact ? 10 : 12) {
                    ZStack {
                        Circle().fill(ProPalette.gold.opacity(0.12))
                        Circle().strokeBorder(ProPalette.gold.opacity(0.35), lineWidth: 1)
                        Image(systemName: benefit.icon)
                            .font(.system(size: compact ? 12 : 15, weight: .medium))
                            .foregroundStyle(ProPalette.crownGradient)
                    }
                    .frame(width: compact ? 24 : 34, height: compact ? 24 : 34)

                    Text(compact ? benefit.shortText : benefit.text)
                        .font(compact ? .footnote : .subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Shared premium card chrome

    private var proCardSurface: some View {
        LinearGradient(
            colors: [Color(red: 0.12, green: 0.08, blue: 0.22),
                     Color(red: 0.05, green: 0.03, blue: 0.11)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var proCardBorder: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                LinearGradient(colors: [ProPalette.gold.opacity(0.85),
                                        Color(red: 0.55, green: 0.3, blue: 1.0).opacity(0.85)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.5)
    }

    /// A restrained, near-goldless border for the "neutral" surfaces (e.g. the
    /// Free-vs-Pro comparison column) so the gold reads as a deliberate accent
    /// reserved for the Pro side, not a default.
    private var neutralCardBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
    }

    // MARK: - Landscape layout (branches on context)

    @ViewBuilder
    private var landscapeLayout: some View {
        if heroConfig != nil {
            landscapeContextualCard
        } else if context == .tappedLockedFeature {
            landscapeComparisonCard
        } else {
            landscapeMilestoneCard
        }
    }

    /// Single-benefit landscape: the "everything else" rows + see-all on the
    /// LEFT; the Free→Pro hero card (compact) + its headline on the RIGHT, with
    /// the price pinned right/bottom. The left list is vertically centered; the
    /// right column shows the card and both texts without scrolling.
    private var landscapeContextualCard: some View {
        HStack(spacing: 0) {
            // LEFT — everything else Pro unlocks. Compact rows (the 7th
            // benefit, video filters, made this 6 rows — full-size rows
            // outgrew the landscape height) inside a centering scroll: the
            // list is centered when it fits and SCROLLS instead of clipping
            // if it ever outgrows the height again (2026-07-25).
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(NSLocalizedString("pro.compare.sectionDivider", comment: ""))
                            .font(.caption2.weight(.bold)).tracking(1.2)
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .center)
                        benefitRows(otherBenefits, compact: true)

                        Button {
                            showComparison = true
                        } label: {
                            Text(NSLocalizedString("pro.seeAllBenefits", comment: ""))
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.5))
                                .underline()
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(minHeight: geo.size.height)   // centers when it fits
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // RIGHT — the triggered Free→Pro hero + headline (no scroll), price below.
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    if let hero = heroConfig {
                        ProFeatureHeroCard(reduceMotion: reduceMotion, compact: true,
                                           icon: hero.icon, title: hero.title,
                                           freeLabel: hero.free, proLabel: hero.pro)
                    }
                    VStack(spacing: 6) {
                        Text(headline)
                            .font(.headline)
                            .foregroundStyle(ProPalette.crownGradient)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)

                Spacer(minLength: 12)

                Divider().background(Color.white.opacity(0.08))
                ProCTAStrip(compact: true, onDismiss: { dismiss() })
                    .padding(.top, 8).padding(.bottom, 4)
                legalFooter.padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Milestone landscape: the full-bundle card on the LEFT, the milestone
    /// headline on the RIGHT with the price pinned right/bottom.
    private var landscapeMilestoneCard: some View {
        HStack(spacing: 0) {
            // LEFT — the whole bundle is the pitch.
            ScrollView {
                bundleCard()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity)

            // RIGHT — milestone headline (no scroll), price below.
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text(headline)
                        .font(.title3.bold())
                        .foregroundStyle(ProPalette.crownGradient)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)

                Spacer(minLength: 12)

                Divider().background(Color.white.opacity(0.08))
                ProCTAStrip(compact: true, onDismiss: { dismiss() })
                    .padding(.top, 8).padding(.bottom, 4)
                legalFooter.padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Comparison landscape: a dedicated three-column layout for the wide space.
    /// 1) the always-included baseline (rows identical for Free and Pro) in a
    /// neutral card; 2) what Pro adds, in the full neon-luxury card; 3) the
    /// purchase panel (brand + price), which carries the sheet identity so the
    /// two tables can self-explain via their own headers.
    private var landscapeComparisonCard: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                // Columns 1 & 2 — the same height (fixedSize on the row hugs the
                // taller card; both fill it), the pair floated to the vertical
                // center — inside a scroll since 2026-07-25: the bundle card
                // grew to 7 rows (video filters) and a hugged pair taller than
                // the sheet was CLIPPING top and bottom. Centered when it
                // fits, scrolls instead of clipping when it doesn't.
                ScrollView {
                    HStack(spacing: 0) {
                        // Widths follow the CONTENT, corrected 2026-07-27 on
                        // device. The baseline card holds 5 rows of short
                        // labels plus two fixed 44pt cells and has vertical
                        // room to spare; the bundle holds 8 rows of prose and
                        // is the one that overflows. It had the NARROWER
                        // column, which forced the wrapping that made it tall.
                        baselineColumnCard
                            .padding(.leading, 14)
                            .padding(.trailing, 6)
                            .frame(width: w * 0.32)

                        bundleCard(dense: true, fillHeight: true)
                            .padding(.leading, 6)
                            .padding(.trailing, 14)
                            .frame(width: w * 0.40)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 14)
                    .frame(minHeight: geo.size.height)   // centers when it fits
                }
                .frame(width: w * 0.72)

                // Column 3 — the purchase panel: centered identity + price CTA +
                // legal links. A faint surface + leading hairline make it read as
                // a deliberate panel on the right.
                VStack(spacing: 14) {
                    VStack(spacing: 8) {
                        AnimatedCrown(size: 30)
                        Text(NSLocalizedString("prompt.generic.title", comment: ""))
                            .font(.title3.bold())
                            .foregroundStyle(ProPalette.crownGradient)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 22)

                    Spacer(minLength: 8)

                    ProCTAStrip(compact: true, onDismiss: { dismiss() })

                    legalLinksStacked

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .frame(width: w * 0.28)
                .frame(maxHeight: .infinity)
                .background(Color.white.opacity(0.03))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                }
            }
        }
    }

    /// Column 1 of the landscape comparison: the always-included baseline in a
    /// neutral card, content vertically centered and filling the shared height.
    /// Compact metrics (2026-07-25): both landscape cards must FIT the
    /// smallest landscape sheet height with the 7-benefit bundle beside them —
    /// same row padding the portrait table uses, tighter row gaps.
    private var baselineColumnCard: some View {
        comparisonTable(rowPadding: 3, includePro: false, cellWidth: 44,
                        hPadding: 10, rowSpacing: 6)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(proCardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(neutralCardBorder)
    }

    /// Terms + Privacy stacked vertically (one above the other) for the slim
    /// landscape-comparison price column. Same links as `legalFooter`, just
    /// laid out for a narrow width.
    private var legalLinksStacked: some View {
        VStack(spacing: 4) {
            Link(destination: termsURL) {
                Text(NSLocalizedString("pro.legal.terms", comment: "")).underline()
            }
            Link(destination: privacyURL) {
                Text(NSLocalizedString("pro.legal.privacy", comment: "")).underline()
            }
        }
        .font(.caption2)
        .foregroundColor(.white.opacity(0.55))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
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
        case .customSkins:
            return NSLocalizedString("prompt.skins.title", comment: "")
        case .videoFilters:
            return NSLocalizedString("prompt.filters.title", comment: "")
        case .externalDisplay:
            return NSLocalizedString("prompt.externalDisplay.title", comment: "")
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
        case .customSkins:
            return NSLocalizedString("prompt.skins.subtitle", comment: "")
        case .videoFilters:
            return NSLocalizedString("prompt.filters.subtitle", comment: "")
        case .externalDisplay:
            return NSLocalizedString("prompt.externalDisplay.subtitle", comment: "")
        }
    }

    /// Per-context hero: icon, title, and the concrete Free→Pro values for the
    /// triggered benefit. `nil` for contexts with no single featured benefit
    /// (sessionMilestone, tappedLockedFeature) — those keep the comparison table.
    /// Values mirror the comparison table so the two never disagree.
    private var heroConfig: (icon: String, title: String, free: String?, pro: String)? {
        switch context {
        case .speedMoment, .speedTapped:
            return ("gauge.high",
                    NSLocalizedString("pro.benefit.speed.short", comment: ""),
                    NSLocalizedString("pro.compare.values.freeSpeeds", comment: ""),
                    NSLocalizedString("pro.compare.values.proSpeeds", comment: ""))
        case .saveSlotFull, .saveSlotTapped:
            return ("tray.2",
                    NSLocalizedString("pro.benefit.slots.short", comment: ""),
                    "2", "5")
        case .rewindLimit:
            return ("backward.fill",
                    NSLocalizedString("pro.benefit.rewind.short", comment: ""),
                    "5s", "30s")
        case .cheatCodes, .cheatCodesTapped:
            return ("command",
                    NSLocalizedString("pro.benefit.cheats.short", comment: ""),
                    nil, "✓")
        case .customizeControls:
            return ("hand.draw",
                    NSLocalizedString("pro.benefit.controls.short", comment: ""),
                    nil, "✓")
        case .customSkins:
            // Creation is the binary unlock — lock on the Free side, like the
            // cheats / controls heroes (importing stays free, but the hero
            // sells creation only; settled after the Import→Create try).
            return ("paintbrush",
                    NSLocalizedString("pro.benefit.skins.short", comment: ""),
                    nil, "✓")
        case .videoFilters:
            return ("tv",
                    NSLocalizedString("pro.benefit.filters.short", comment: ""),
                    nil, "✓")
        case .externalDisplay:
            return ("airplayvideo",
                    NSLocalizedString("pro.benefit.externalDisplay.short", comment: ""),
                    nil, "✓")
        case .sessionMilestone, .tappedLockedFeature:
            return nil
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
            Benefit(icon: "paintbrush",
                    text: NSLocalizedString("pro.benefit.skins", comment: ""),
                    shortText: NSLocalizedString("pro.benefit.skins.short", comment: "")),
            Benefit(icon: "tv",
                    text: NSLocalizedString("pro.benefit.filters", comment: ""),
                    shortText: NSLocalizedString("pro.benefit.filters.short", comment: "")),
            Benefit(icon: "airplayvideo",
                    text: NSLocalizedString("pro.benefit.externalDisplay", comment: ""),
                    shortText: NSLocalizedString("pro.benefit.externalDisplay.short", comment: "")),
        ]
    }

    private var featuredBenefit: Benefit? {
        switch context {
        case .speedMoment, .speedTapped:       return allBenefits[0]
        case .saveSlotFull, .saveSlotTapped:   return allBenefits[1]
        case .rewindLimit:                     return allBenefits[2]
        case .cheatCodes, .cheatCodesTapped:   return allBenefits[3]
        case .customizeControls:               return allBenefits[4]
        case .customSkins:                     return allBenefits[5]
        case .videoFilters:                    return allBenefits[6]
        case .externalDisplay:                 return allBenefits[7]
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
                          free: .none, pro: .check),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.skins", comment: ""),
                          free: .none, pro: .check),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.filters", comment: ""),
                          free: .none, pro: .check),
            ComparisonRow(label: NSLocalizedString("pro.compare.row.externalDisplay", comment: ""),
                          free: .none, pro: .check),
        ]
    }

    /// Free-vs-Pro table. Row vertical padding parameterizable so landscape
    /// can pass 4 (tighter) while portrait keeps 6.
    @ViewBuilder
    /// `includePro: false` renders only the rows that are identical between Free
    /// and Pro (the always-included baseline) — used by the landscape comparison
    /// column 1, where the Pro-only upgrades live in their own neon card instead.
    /// `cellWidth` / `hPadding` shrink the Free/Pro value columns and the table
    /// margins for narrow hosts (the landscape comparison column 1, where those
    /// columns only ever hold a checkmark) so the row labels get the room.
    /// `rowSpacing` is the gap between rows — the portrait comparison passes a
    /// tighter value so the full table fits the sheet without scrolling.
    private func comparisonTable(rowPadding: CGFloat,
                                 includePro: Bool = true,
                                 cellWidth: CGFloat = 80,
                                 hPadding: CGFloat = 20,
                                 rowSpacing: CGFloat = 10) -> some View {
        VStack(spacing: rowSpacing) {
            // Column headers — shrink the title font when the columns are narrow.
            HStack(spacing: 0) {
                Text("")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(NSLocalizedString("pro.compare.header.free", comment: ""))
                    .font((cellWidth < 60 ? Font.caption2 : Font.caption).bold())
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: cellWidth)
                Text(NSLocalizedString("pro.compare.header.pro", comment: ""))
                    .font((cellWidth < 60 ? Font.caption2 : Font.caption).bold())
                    .foregroundStyle(ProPalette.crownGradient)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: cellWidth)
            }
            .padding(.bottom, 2)

            ForEach(sharedRows.indices, id: \.self) { i in
                comparisonRowView(sharedRows[i], rowPadding: rowPadding, cellWidth: cellWidth)
            }

            if includePro {
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
                    comparisonRowView(proRows[i], rowPadding: rowPadding, cellWidth: cellWidth)
                }
            }
        }
        .padding(.horizontal, hPadding)
    }

    private func comparisonRowView(_ row: ComparisonRow, rowPadding: CGFloat,
                                   cellWidth: CGFloat = 80) -> some View {
        HStack(spacing: 0) {
            Text(row.label)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            comparisonCell(row.free, highlighted: false)
                .frame(width: cellWidth)

            comparisonCell(row.pro, highlighted: true)
                .frame(width: cellWidth)
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
