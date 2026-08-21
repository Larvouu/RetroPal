//
//  SkinPickerView.swift
//  EmulateurGBA
//
//  The in-game Skin picker sheet (opened from the pause menu ▸ Skin). The first row shows the three
//  built-in skins — Nostalgia, Retro Pal, Invisible — each a portrait iPhone preview rendering the
//  REAL controls (with the current game frame in the screen) under that skin for this game's
//  console. User CUSTOM skins follow, three per row, from the second row down (GB/GBC only for now).
//  Tapping a card applies it immediately (so closing keeps the choice); OK / Close just dismiss.
//
//  "Create a skin" sits beside OK (same width, the Pro-temptation gold→purple treatment) and opens
//  the full-screen editor. Custom cards offer Edit / Delete via a context menu. The library is
//  capped at 6 per console, so the grid is at most 3 rows (3 built-in + 6 custom).
//
//  Layout mirrors the share-card sheets: portrait stacks the previews above the OK / Create row
//  (with an X close in the nav bar); landscape splits previews on the left and the actions on the
//  right (no nav-bar X), so the previews get more room.
//
//  When a custom control preset is active for the console, the whole console is restricted to
//  Invisible (the dress can't track a custom layout): the dressed cards + Create are disabled and a
//  one-line caption explains why.
//

import SwiftUI
import UniformTypeIdentifiers

struct SkinPickerView: View {
    let system: PresetSystem
    /// True when a custom control preset is active for this console (dressed skins + Create disabled).
    let lockedToInvisible: Bool
    /// Current game frame, shown in each preview's screen (like the screenshot card).
    let gameImage: UIImage?
    /// The REAL device safe-area insets, forwarded to the editor's full-screen preview.
    let realInsets: UIEdgeInsets
    let onSelect: (SkinSelection) -> Void
    /// Tells the host the custom library changed (create / delete), so it can resize the sheet.
    let onLibraryChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var vSizeClass
    @State private var selected: SkinSelection
    @State private var customSkins: [CustomSkin]
    @State private var editor: EditorRequest?
    @State private var showImportInfo = false
    @State private var showSkinImporter = false
    @State private var showProSheet = false
    /// Create is a Pro feature: Pro users get the editor; free users get the upgrade sheet.
    @ObservedObject private var pro = ProManager.shared

    // iPhone 16 Pro Max portrait — the reference device each CARD preview is rendered at, then scaled.
    private let deviceSize = CGSize(width: 440, height: 956)
    private let deviceInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    // Dark backing matching the share-card sheets.
    private let background = Color(red: 0.06, green: 0.04, blue: 0.08)
    private let gold = Color(red: 0.91, green: 0.76, blue: 0.42)
    private let hPad: CGFloat = 16
    private let spacing: CGFloat = 12
    private let columns = 3

    init(system: PresetSystem, current: SkinSelection, lockedToInvisible: Bool,
         gameImage: UIImage?, realInsets: UIEdgeInsets,
         onSelect: @escaping (SkinSelection) -> Void, onLibraryChanged: @escaping () -> Void) {
        self.system = system
        self.lockedToInvisible = lockedToInvisible
        self.gameImage = gameImage
        self.realInsets = realInsets
        self.onSelect = onSelect
        self.onLibraryChanged = onLibraryChanged
        _selected = State(initialValue: lockedToInvisible ? .builtin(.invisible) : current)
        _customSkins = State(initialValue: CustomSkinStore.shared.skins(for: system))
    }

    /// Create/Import are hidden on a console with no dress to recolour (the NES today).
    private var supportsCustom: Bool { system.supportsCustomSkins }
    private var items: [PickerItem] {
        GameSkin.pickerOrder.map { PickerItem.builtin($0) } + customSkins.map { PickerItem.custom($0) }
    }

    var body: some View {
        // No nav bar: the sheet has no title and no top close button (portrait dismisses via OK or
        // the grabber; landscape uses the Close button in the right panel).
        GeometryReader { geo in
            Group {
                if vSizeClass == .compact { landscapeLayout(geo) }
                else { portraitLayout(geo) }
            }
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $editor) { req in
            SkinEditorView(system: system, deviceInsets: realInsets,
                           gameImage: gameImage, editing: req.skin,
                           onSaved: {
                               refreshLibrary()
                               // If the skin just edited is the one currently worn in-game,
                               // re-apply the (unchanged) selection so the host re-resolves the
                               // dress from the freshly saved palette and repaints the live game
                               // behind the sheet. Creating a skin, or editing a non-selected
                               // one, leaves the current dress untouched — only the picker
                               // previews refresh. (Re-apply is idempotent if nothing changed.)
                               if let edited = req.skin, selected == .custom(edited.id) {
                                   onSelect(selected)
                               }
                           })
        }
        .alert(NSLocalizedString("skin.importInfo.title", comment: "Explain where .retropalskin files come from"),
               isPresented: $showImportInfo) {
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("common.ok", comment: "")) { showSkinImporter = true }
        } message: {
            Text(NSLocalizedString("skin.importInfo.message", comment: ""))
        }
        .fileImporter(isPresented: $showSkinImporter, allowedContentTypes: [SkinSharing.contentType]) { result in
            guard case .success(let url) = result else { return }
            let outcome = SkinSharing.importSkin(from: url)
            // A successful import is the envy moment for a free user ("you just got a
            // custom skin, now create your own"): chain the custom-skins Pro sheet
            // right after the success alert's OK. Picker flow only, never for Pro.
            let upsell = !pro.isPro
            SkinSharing.present(outcome) {
                guard case .added = outcome, upsell else { return }
                // Let the alert's dismissal animation finish before presenting the sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showProSheet = true }
            }
            if case .added = outcome { refreshLibrary() }
        }
        .sheet(isPresented: $showProSheet) {
            ProUpgradeView(context: .customSkins)
                .presentationDetents([.large])
        }
    }

    // MARK: - Layouts

    /// Portrait: the card grid scrolls above the pinned OK / Create+Import actions. ≤2 rows show
    /// without scrolling; the grid takes whatever height is left under the actions (so a capped
    /// sheet keeps the actions visible and scrolls the grid instead).
    private func portraitLayout(_ geo: GeometryProxy) -> some View {
        let cardW = SkinSheetMetrics.cardWidth(containerWidth: geo.size.width)
        let gridBound = SkinSheetMetrics.portraitGridBound(sheetHeight: geo.size.height,
                                                           supportsCustom: supportsCustom,
                                                           locked: lockedToInvisible)
        return VStack(spacing: SkinSheetMetrics.sectionGap) {
            ScrollView { grid(cardW: cardW) }
                .frame(maxHeight: gridBound)
            if lockedToInvisible { captionView }
            actionRow.padding(.horizontal, 24)
        }
        .padding(.vertical, SkinSheetMetrics.topPad)
        .frame(maxWidth: .infinity)
    }

    /// Landscape: scrolling preview grid on the left, OK / Create / Import / Close on the right. The
    /// cards are sized so two rows of three are visible at a glance before scrolling.
    private func landscapeLayout(_ geo: GeometryProxy) -> some View {
        let leftW = geo.size.width * 0.72
        let cardW = SkinSheetMetrics.landscapeCardWidth(
            leftWidth: leftW, columnHeight: geo.size.height,
            rows: SkinSheetMetrics.visibleRows(itemCount: items.count), locked: lockedToInvisible)

        return HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    grid(cardW: cardW)
                    if lockedToInvisible { captionView }
                }
                .padding(.vertical, 8)
            }
            .frame(width: leftW)

            VStack(spacing: 12) {
                Spacer(minLength: 8)
                okButton
                if supportsCustom { createButton; importButton }
                closeButton
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(width: geo.size.width * 0.28)
            .frame(maxHeight: .infinity)
            .background(Color.white.opacity(0.03))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            }
        }
    }

    // MARK: - Grid

    private func grid(cardW: CGFloat) -> some View {
        let rows = stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0 ..< min($0 + columns, items.count)])
        }
        return VStack(spacing: 16) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row) { card(item: $0, width: cardW) }
                    // Pad a short last row so its cards stay left-aligned (not centre-spread).
                    if row.count < columns {
                        ForEach(0 ..< (columns - row.count), id: \.self) { _ in
                            Color.clear.frame(width: cardW, height: 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, hPad)
    }

    // MARK: - Pieces

    private var captionView: some View {
        Text(NSLocalizedString("skin.presetLock.caption", comment:
            "Why the dressed skins are unavailable while a custom control layout is active"))
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(.horizontal, hPad)
    }

    /// Portrait action area: OK on its own row; below it (GB/GBC) Create + Import, equal width.
    private var actionRow: some View {
        VStack(spacing: 12) {
            okButton
            if supportsCustom {
                HStack(spacing: 12) { createButton; importButton }
            }
        }
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

    /// "Create a skin" — a Pro feature. Pro users get a classic neutral button (like Close) that
    /// opens the editor; free users get the gold→purple Pro-temptation treatment (no lock icon) and a
    /// tap opens the generic Pro upgrade sheet. Pro is disabled only when at the cap / preset-locked.
    private var createButton: some View {
        let isPro = pro.isPro
        let blocked = isPro && (lockedToInvisible || customSkins.count >= CustomSkinStore.maxPerConsole)
        return Button {
            if isPro { editor = .create } else { showProSheet = true }
        } label: {
            createLabel(isPro: isPro)
        }
        .disabled(blocked)
        .opacity(blocked ? 0.4 : 1)
    }

    @ViewBuilder
    private func createLabel(isPro: Bool) -> some View {
        let text = Text(NSLocalizedString("skin.create", comment: "Open the custom-skin editor"))
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        if isPro {
            text.background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            text.proTemptBackground(cornerRadius: 12)
        }
    }

    /// "Import skin" — opens the explainer alert, then the Files picker. Classic neutral fill
    /// (same as the Close button), not the gold Pro treatment.
    private var importButton: some View {
        Button { showImportInfo = true } label: {
            Text(NSLocalizedString("skin.import", comment: "Import a custom skin from a file"))
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                Text(NSLocalizedString("screenshot.dismiss", comment: ""))
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func card(item: PickerItem, width: CGFloat) -> some View {
        let sel = item.selection
        let dressed = item.isDressed
        let disabled = lockedToInvisible && dressed
        let isSelected = (selected == sel) && !disabled
        let scale = width / deviceSize.width

        VStack(spacing: 8) {
            SkinPreviewRepresentable(system: system, skin: item.builtinSkin,
                                     safeInsets: deviceInsets, gameImage: gameImage,
                                     customPalette: item.palette)
                .frame(width: deviceSize.width, height: deviceSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: width, height: deviceSize.height * scale, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? gold : Color.white.opacity(0.12),
                                      lineWidth: isSelected ? 2.5 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(gold, .black.opacity(0.6))
                            .padding(6)
                    }
                }
                .opacity(disabled ? 0.35 : 1)

            Text(item.displayName)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? gold : .white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .allowsHitTesting(!disabled)
        .onTapGesture {
            guard !disabled else { return }
            selected = sel
            onSelect(sel)                                // apply now; OK / Close only dismiss
            Analytics.signal("skin_changed", ["variant": item.customSkin != nil ? "custom" : item.builtinSkin.rawValue, "system": "\(system)"])
        }
        .modifier(CustomCardMenu(item: item,
                                 isPro: pro.isPro,
                                 onEdit: { editor = .edit($0) },
                                 onEditLocked: { showProSheet = true },
                                 onDelete: { delete($0) }))
    }

    // MARK: - Library mutations

    private func refreshLibrary() {
        customSkins = CustomSkinStore.shared.skins(for: system)
        onLibraryChanged()
    }

    private func delete(_ skin: CustomSkin) {
        CustomSkinStore.shared.delete(id: skin.id, system: system)
        // If the deleted skin was selected, fall back to Nostalgia.
        if selected == .custom(skin.id) {
            selected = .builtin(.nostalgia)
            onSelect(.builtin(.nostalgia))
        }
        refreshLibrary()
    }
}

// MARK: - Picker item

enum PickerItem: Identifiable {
    case builtin(GameSkin)
    case custom(CustomSkin)

    var id: String {
        switch self {
        case .builtin(let s): return "builtin.\(s.rawValue)"
        case .custom(let c):  return "custom.\(c.id.uuidString)"
        }
    }
    var selection: SkinSelection {
        switch self {
        case .builtin(let s): return .builtin(s)
        case .custom(let c):  return .custom(c.id)
        }
    }
    /// The built-in skin to render; custom cards render Nostalgia + a palette override, so they
    /// pass `.nostalgia` here and supply `palette`.
    var builtinSkin: GameSkin {
        if case .builtin(let s) = self { return s }
        return .nostalgia
    }
    var palette: SkinPalette? {
        if case .custom(let c) = self { return c.palette }
        return nil
    }
    var isDressed: Bool { selection.isDressed }
    var displayName: String {
        switch self {
        case .builtin(let s): return s.displayName       // fixed English names
        case .custom(let c):  return c.name
        }
    }
    var customSkin: CustomSkin? {
        if case .custom(let c) = self { return c }
        return nil
    }
}

/// Editor presentation request (create vs edit), Identifiable for `.fullScreenCover(item:)`.
enum EditorRequest: Identifiable {
    case create
    case edit(CustomSkin)

    var id: String {
        switch self {
        case .create:        return "create"
        case .edit(let c):   return c.id.uuidString
        }
    }
    var skin: CustomSkin? {
        if case .edit(let c) = self { return c }
        return nil
    }
}

/// Attaches the Share / Edit / Delete context menu to custom cards only (built-in cards get
/// nothing). Editing is a Pro feature like creating: for a free user the Edit entry carries the
/// crown (context menus are system-rendered, so the crown icon is the premium marker available
/// here) and opens the custom-skins Pro sheet instead of the editor. Share + Delete stay free.
private struct CustomCardMenu: ViewModifier {
    let item: PickerItem
    let isPro: Bool
    let onEdit: (CustomSkin) -> Void
    let onEditLocked: () -> Void
    let onDelete: (CustomSkin) -> Void

    func body(content: Content) -> some View {
        if let skin = item.customSkin {
            content.contextMenu {
                Button { SkinSharing.share(skin); Analytics.signal("custom_skin", ["action": "shared", "system": "\(skin.system)"]) } label: {
                    Label(NSLocalizedString("skin.share", comment: "Share a custom skin"),
                          systemImage: "square.and.arrow.up")
                }
                Button { if isPro { onEdit(skin) } else { onEditLocked() } } label: {
                    Label(NSLocalizedString("skin.edit", comment: "Edit a custom skin"),
                          systemImage: isPro ? "paintbrush" : "crown.fill")
                }
                Button(role: .destructive) { onDelete(skin) } label: {
                    Label(NSLocalizedString("skin.delete", comment: "Delete a custom skin"),
                          systemImage: "trash")
                }
            }
        } else {
            content
        }
    }
}
