//
//  AppearanceView.swift
//  EmulateurGBA
//
//  The in-game Appearance sheet (pause menu ▸ Appearance) — the tabbed home of
//  everything visual, decided 2026-07-24 (no intermediate menu):
//
//    · Console tab — the existing SkinPickerView, unchanged (the dress).
//    · Screen tab  — what's INSIDE the screen: the DMG palette picker today,
//                    the video filters when they land (GB/GBC only until then,
//                    so GBA/NDS games keep the direct skin picker, no tabs).
//
//  Palette previews recolor the REAL captured game frame (nearest-shade
//  mapping from the palette active at open time), so each card shows "your
//  game in that palette" — the paused live screen behind the sheet keeps its
//  already-rendered colors and picks the new palette up on the next frame
//  (resume). CGB-mode games get an honest caption instead of a dead grid:
//  they define their own colors and the DMG override doesn't apply.
//

import SwiftUI

struct AppearanceView: View {
    let system: PresetSystem
    // Console tab (SkinPickerView passthrough).
    let skinCurrent: SkinSelection
    let lockedToInvisible: Bool
    let gameImage: UIImage?
    let realInsets: UIEdgeInsets
    let onSelectSkin: (SkinSelection) -> Void
    let onLibraryChanged: () -> Void
    // Screen tab.
    let showScreenTab: Bool
    /// GB/GBC games show the palette section (or its CGB caption).
    let showPaletteSection: Bool
    /// Whether the running game renders through the DMG palette (CGB games don't).
    let paletteApplicable: Bool
    /// The palette active when the sheet opened — recolor source for previews.
    let openPalette: GBPalette
    let initialPaletteID: String
    let onSelectPalette: (GBPalette) -> Void
    /// The stored filter choice (raw value) + the pick callback (Pro-gated in
    /// the tab; the VC re-checks via VideoFilter.effective anyway).
    let initialFilterID: String
    let onSelectFilter: (VideoFilter) -> Void

    @State private var tab: Int = 0

    private let background = Color(red: 0.06, green: 0.04, blue: 0.08)
    private let tabPurple = UIColor(red: 0.45, green: 0.2, blue: 0.85, alpha: 1)

    var body: some View {
        VStack(spacing: 0) {
            if showScreenTab {
                // One fixed sheet height for both tabs (the host sizes the
                // detent to the taller), so switching never resizes the sheet.
                ColoredSegmentedPicker(
                    segments: [
                        (NSLocalizedString("appearance.tab.console", comment: "Appearance sheet tab: the console dress"), 0),
                        (NSLocalizedString("appearance.tab.screen", comment: "Appearance sheet tab: the screen (palette, filters)"), 1),
                    ],
                    selection: $tab,
                    selectedColor: tabPurple)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            if showScreenTab && tab == 1 {
                ScreenAppearanceTab(showPaletteSection: showPaletteSection,
                                    paletteApplicable: paletteApplicable,
                                    openPalette: openPalette,
                                    gameFrame: gameImage?.cgImage,
                                    initialPaletteID: initialPaletteID,
                                    onSelect: onSelectPalette,
                                    isDualScreen: system == .nds,
                                    initialFilterID: initialFilterID,
                                    onSelectFilter: onSelectFilter)
            } else {
                SkinPickerView(system: system,
                               current: skinCurrent,
                               lockedToInvisible: lockedToInvisible,
                               gameImage: gameImage,
                               realInsets: realInsets,
                               onSelect: onSelectSkin,
                               onLibraryChanged: onLibraryChanged)
            }
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// The Screen tab: the display-filter grid (all consoles, Pro) and the grouped
/// DMG palette grid (GB/GBC; the CGB explainer for color games), with a pinned
/// OK. Selection applies IMMEDIATELY (like the skins), OK just closes. Free
/// users see every filter preview; tapping one opens the Pro sheet (tempt,
/// don't lock — no lock icons).
private struct ScreenAppearanceTab: View {
    let showPaletteSection: Bool
    let paletteApplicable: Bool
    let openPalette: GBPalette
    let gameFrame: CGImage?
    let initialPaletteID: String
    let onSelect: (GBPalette) -> Void
    /// NDS: the captured frame is the stacked dual-screen image (per-screen CRT).
    let isDualScreen: Bool
    let initialFilterID: String
    let onSelectFilter: (VideoFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pro = ProManager.shared
    @State private var selectedID: String = ""
    /// The filter shown in the big showcase — everyone can browse (free users
    /// preview without applying).
    @State private var previewedFilterID: String = ""
    /// The filter actually APPLIED (Pro; follows taps for Pro users).
    @State private var selectedFilterID: String = ""
    @State private var showProSheet = false
    /// Palette id → the captured frame recolored in that palette. Computed
    /// once off-main at appear; cards show the flat-stripe swatch meanwhile.
    @State private var previews: [String: UIImage] = [:]
    /// Filter id → the captured frame filtered through the real shader, at
    /// showcase resolution.
    @State private var filterPreviews: [String: UIImage] = [:]

    private let gold = Color(red: 0.91, green: 0.76, blue: 0.42)
    private let hPad: CGFloat = 16
    private let spacing: CGFloat = 12

    @Environment(\.verticalSizeClass) private var vSizeClass

    var body: some View {
        Group {
            if vSizeClass == .compact { landscapeLayout } else { portraitLayout }
        }
        .onAppear {
            if selectedID.isEmpty { selectedID = initialPaletteID }
            if selectedFilterID.isEmpty { selectedFilterID = initialFilterID }
            if previewedFilterID.isEmpty { previewedFilterID = initialFilterID }
        }
        .task(priority: .userInitiated) { await computePreviews() }
        .sheet(isPresented: $showProSheet) {
            ProUpgradeView(context: .videoFilters)
        }
    }

    /// Free user previewing a Pro effect → the gold Apply invitation shows.
    private var showApplyInvitation: Bool {
        !pro.isPro && previewedFilterID != VideoFilter.none.rawValue
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterSection
                if showPaletteSection {
                    if paletteApplicable {
                        paletteSection()
                    } else {
                        cgbCaption
                    }
                }
            }
            .padding(.horizontal, hPad)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    /// Portrait: the scroll above the pinned bottom row. When a free user
    /// previews a Pro filter, OK splits in two: OK keeps its plain "just
    /// close" meaning and the gold Apply invitation (→ Pro sheet) sits beside
    /// it — so OK never reads as "apply" (product call, 2026-07-24).
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            scrollContent
            HStack(spacing: 12) {
                okButton
                if showApplyInvitation {
                    applyFilterButton
                }
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, 16)
            .animation(.easeInOut(duration: 0.2), value: previewedFilterID)
        }
    }

    /// Landscape (spec of 2026-07-25): the showcase keeps the left
    /// side, big and centered; the right panel holds the CHOICES (chips +
    /// palettes) in a scroll, with OK pinned at its bottom — splitting
    /// vertically with the gold Apply invitation when a free user previews a
    /// Pro effect. Same 72/28 family split as the skin picker.
    private var landscapeLayout: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                VStack {
                    Spacer(minLength: 8)
                    filterShowcase
                        .padding(.horizontal, hPad)
                    Spacer(minLength: 8)
                }
                .frame(width: geo.size.width * 0.72)

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            filterHeader
                            filterChips(singleColumn: true)
                            if showPaletteSection {
                                if paletteApplicable {
                                    paletteSection(columns: 2)
                                } else {
                                    cgbCaption
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }
                    VStack(spacing: 8) {
                        if showApplyInvitation {
                            applyFilterButton
                        }
                        okButton
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                    .animation(.easeInOut(duration: 0.2), value: previewedFilterID)
                }
                .frame(width: geo.size.width * 0.28)
                .frame(maxHeight: .infinity)
                .background(Color.white.opacity(0.03))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                }
            }
        }
    }

    // MARK: - Filters (all consoles, Pro)

    /// ONE big showcase screen (the captured frame through the previewed
    /// filter, where a difference is actually visible) + compact name chips.
    /// Tapping a chip updates the showcase for EVERYONE; for Pro (and for
    /// None, which is free) it also applies. Free users previewing an effect
    /// get the gold Apply invitation → Pro sheet (crown, never a lock).
    /// Portrait stacks header/showcase/chips; landscape recomposes the same
    /// pieces (showcase left, chips in the right panel).
    @ViewBuilder private var filterSection: some View {
        filterHeader
        filterShowcase
        filterChips(singleColumn: false)
    }

    private var filterHeader: some View {
        HStack(spacing: 6) {
            Text(NSLocalizedString("filter.section", comment: "Screen tab section title: display filters"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
            if !pro.isPro {
                // The Pro marker is the crown, never a lock (settled doctrine).
                Image(systemName: "crown.fill")
                    .font(.caption2)
                    .foregroundStyle(gold)
                    .accessibilityLabel("Pro")
            }
        }
    }

    /// The chip grid: adaptive columns in portrait, one full-width chip per
    /// row in the narrow landscape panel.
    private func filterChips(singleColumn: Bool) -> some View {
        LazyVGrid(columns: singleColumn
                    ? [GridItem(.flexible())]
                    : [GridItem(.adaptive(minimum: 104), spacing: 8)],
                  spacing: 8) {
            ForEach(VideoFilter.allCases) { filter in
                filterChip(filter)
            }
        }
    }

    private var filterShowcase: some View {
        Group {
            if let img = filterPreviews[previewedFilterID] {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(previewedFilterID == VideoFilter.none.rawValue ? .none : .high)
                    .aspectRatio(contentMode: .fit)
            } else {
                SkeletonBox(cornerRadius: 10)
                    .aspectRatio(160.0 / 144.0, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 320)   // bounds the tall stacked NDS frame
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        .accessibilityLabel(Text(NSLocalizedString(
            (VideoFilter(rawValue: previewedFilterID) ?? .none).nameKey, comment: "")))
    }

    private func filterChip(_ filter: VideoFilter) -> some View {
        let previewed = filter.rawValue == previewedFilterID
        return Button {
            previewedFilterID = filter.rawValue
            // "None" stays free (it IS the current state); the effects apply
            // only for Pro — free users keep browsing the showcase.
            if pro.isPro || filter == .none {
                selectedFilterID = filter.rawValue
                onSelectFilter(filter)
            }
        } label: {
            Text(NSLocalizedString(filter.nameKey, comment: ""))
                .font(.subheadline.weight(previewed ? .semibold : .regular))
                .foregroundStyle(previewed ? gold : .white.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.6)
                // Fixed horizontal padding INSIDE the capsule: the text scales
                // before it can ever reach the rounded ends, whatever the
                // locale's name length.
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.white.opacity(previewed ? 0.12 : 0.06))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(previewed ? gold : Color.white.opacity(0.15),
                                                lineWidth: previewed ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(NSLocalizedString(filter.nameKey, comment: "")))
    }

    // MARK: - Palettes (GB/GBC)

    /// The grouped palette grids; `columns` narrows to 2 in the landscape
    /// right panel.
    @ViewBuilder private func paletteSection(columns gridColumns: Int = 3) -> some View {
        ForEach(GBPalettes.groups, id: \.titleKey) { group in
            Text(NSLocalizedString(group.titleKey, comment: ""))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                     count: gridColumns),
                      spacing: SkinSheetMetrics.rowGap) {
                ForEach(group.palettes) { palette in
                    paletteCard(palette)
                }
            }
        }
    }

    private func paletteCard(_ palette: GBPalette) -> some View {
        let selected = palette.id == selectedID
        return Button {
            selectedID = palette.id
            onSelect(palette)
        } label: {
            VStack(spacing: SkinSheetMetrics.cardLabelGap) {
                preview(for: palette)
                    .aspectRatio(160.0 / 144.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? gold : Color.white.opacity(0.2),
                                      lineWidth: selected ? 2 : 1))
                Text(verbatim: palette.name)
                    .font(.caption)
                    .foregroundStyle(selected ? gold : .white.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.name)
    }

    /// The recolored game frame when ready, else the 4-stripe swatch (also the
    /// permanent look when no frame was captured).
    @ViewBuilder private func preview(for palette: GBPalette) -> some View {
        if let img = previews[palette.id] {
            Image(uiImage: img)
                .resizable()
                .interpolation(.none)
        } else {
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { i in
                    Color(palette.shadeColor(i))
                }
            }
        }
    }

    /// CGB-mode games: explain instead of showing a dead grid.
    private var cgbCaption: some View {
        HStack(spacing: 10) {
            Image(systemName: "paintpalette")
                .foregroundStyle(.white.opacity(0.5))
            Text(NSLocalizedString("palette.cgb.caption", comment: "Shown for color games, whose own colors replace the palette choice"))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var okButton: some View {
        Button { dismiss() } label: {
            Text(verbatim: "OK")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(LinearGradient(colors: [.purple, .blue],
                                           startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// The gold Pro invitation beside OK (same treatment as Create-a-skin),
    /// shown to free users previewing a filter. Scales its label down before
    /// ever clipping, whatever the locale.
    private var applyFilterButton: some View {
        Button { showProSheet = true } label: {
            Text(NSLocalizedString("filter.apply", comment: "Pro invitation while previewing a filter"))
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .proTemptBackground(cornerRadius: 12)
        }
    }

    private func computePreviews() async {
        guard let frame = gameFrame else { return }
        let source = openPalette
        let wantPalettes = showPaletteSection && paletteApplicable && previews.isEmpty
        let wantFilters = filterPreviews.isEmpty
        let screens = isDualScreen ? 2 : 1
        let (palettes, filters) = await Task.detached(priority: .userInitiated)
        { () -> ([String: UIImage], [String: UIImage]) in
            var pal: [String: UIImage] = [:]
            if wantPalettes {
                for palette in GBPalettes.all {
                    if let img = GBPalettes.recolor(frame, from: source, to: palette) {
                        pal[palette.id] = img
                    }
                }
            }
            var fil: [String: UIImage] = [:]
            if wantFilters {
                // Showcase resolution: the big preview is where the difference
                // must actually be visible (the effect character is what
                // matters; exact density is the live screen's).
                let aspect = CGFloat(frame.width) / CGFloat(max(frame.height, 1))
                let target = CGSize(width: 800, height: 800 / max(aspect, 0.01))
                for filter in VideoFilter.allCases {
                    if let cg = VideoFilterRenderer.apply(filter, to: frame,
                                                          targetSize: target,
                                                          screenCount: screens) {
                        fil[filter.rawValue] = UIImage(cgImage: cg)
                    }
                }
            }
            return (pal, fil)
        }.value
        if wantPalettes { previews = palettes }
        if wantFilters { filterPreviews = filters }
    }
}
