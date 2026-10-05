//
//  GameDetailsLandscapeView.swift
//  EmulateurGBA
//
//  A game's page on its side, in the landscape library's language: the same
//  dark moving ground, the same margins, glass circles in a top bar of our
//  own, and the content as cards (decided on device, 2026-09-04). Portrait keeps its
//  List and is untouched.
//
//  This is a LAYOUT, not a second page. `GameDetailsView` still owns every
//  piece of state, every sheet, alert and dialog, the save import and export,
//  the rename, the cover picker and the delete; it hands this view the facts
//  it displays and one closure per action. Nothing here decides anything.
//
//  What it shows, left to right, inside the safe area (in landscape that is
//  the Dynamic Island's side; the two bar buttons keep the screen's corners,
//  since neither can meet it): the living screenshot in a ringed, glowing
//  square (the cover of every kind stays library-only, settled 2026-07-10),
//  the title under it, then play time and file size; then a scrolling column
//  of cards: Play (resume the session, start from the title screen), the
//  quick-save slots as a row of preview chips, RetroAchievements when the
//  account is connected and the game has a set (the invite and the "not
//  available" note stay portrait's), and for a DS game the slot 2 and the DS
//  settings. Everything that manages the file (import and export the save,
//  replace the file, rename, cover, delete) sits behind the ellipsis in the
//  top bar, where it is one tap away without taking a card. This positioning
//  was tried against a three-column one on the device and kept (decided on device,
//  2026-09-04).
//

import SwiftUI
import CoreData

/// What the page can do, as closures, so the layout can trigger an action
/// without owning its state.
struct GameDetailsLandscapeActions {
    let resume: () -> Void
    let newGame: () -> Void
    let playSlot: (Int) -> Void
    let openAchievements: () -> Void
    let raInfo: () -> Void
    let pickSlot2: () -> Void
    let importSave: () -> Void
    let exportSave: () -> Void
    let replaceROM: () -> Void
    let rename: () -> Void
    let chooseCover: () -> Void
    let removeCover: () -> Void
    let delete: () -> Void
}

struct GameDetailsLandscapeView: View {
    @ObservedObject var game: GameEntity
    /// Bumped by the page when a quick-save lands, so the screenshot and the
    /// slot previews re-read.
    let saveTick: Int
    let slots: [SaveSlotInfo]
    let autoSlot: SaveSlotInfo?
    /// Already formatted by the page, nil under a minute.
    let playTime: String?
    let romName: String
    let raState: RADetailsState
    let slot2Game: GameEntity?
    let iCloudUnavailable: Bool
    @Binding var ndsSwapScreens: Bool
    @Binding var ndsClockManual: Bool
    let ndsManualDate: Binding<Date>
    @Binding var ndsLanguage: String
    let ndsAutoLanguageLabel: String
    let ndsLanguageAutonyms: [String]
    let actions: GameDetailsLandscapeActions

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// An iPad window: a larger square, a capped column of cards.
    @TabletSurface private var isTablet
    @Environment(\.surfaceSafeAreaInsets) private var surfaceInsets
    /// Observed so a theme change repaints this surface.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared

    @State private var cover: LibraryLandscapeCover?
    /// The "…" panel of file actions is open.
    @State private var showsFileActions = false
    @State private var previews: [Int: UIImage] = [:]

    private var isNDS: Bool { game.systemType == "nds" }

    private var existingSlots: [SaveSlotInfo] { slots.filter { $0.exists } }

    private var coverKey: String {
        "\((game.lastPlayedAt ?? .distantPast).timeIntervalSinceReferenceDate)#\(saveTick)"
    }

    private var previewsKey: String {
        coverKey + "#" + existingSlots.map { "\($0.slotIndex)" }.joined(separator: ",")
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // From the window, not the proxy: inside a view that ignores the
            // safe area the proxy reports zero, which put the screenshot
            // behind the island on a 14 Pro.
            let insets = LandscapeChrome.insets(surfaceInsets)
            let side = isTablet ? Self.tabletCoverSide(forHeight: size.height)
                                : Self.coverSide(forHeight: size.height)
            ZStack {
                LibraryLandscapeBackground(isPaused: reduceMotion, dimmed: true)

                VStack(spacing: 0) {
                    // The bar keeps the two corners: neither button can meet
                    // the island. The content below lives inside the safe
                    // area, so nothing sits behind it.
                    topBar
                        .padding(.horizontal, 24)
                        .padding(.top, LandscapeChrome.barTopPadding(tablet: isTablet, insets: insets))
                    // On an iPad the cards are capped to a readable width, so the
                    // square and the column sit together in the middle of the
                    // window instead of the column stretching to the far edge;
                    // upright, the square stands above the cards in one scroll.
                    Group {
                        if LandscapeChrome.isStacked(tablet: isTablet, size: size) {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 20) {
                                    coverColumn(side: side)
                                    cardsColumn
                                        .frame(maxWidth: 620)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 8)
                            }
                        } else if isTablet {
                            // An iPad on its side (decided on device, 2026-09-05): the
                            // square and the cards as one block, centred vertically
                            // when the block fits the window, scrolling when not.
                            ViewThatFits(in: .vertical) {
                                HStack(alignment: .top, spacing: 24) {
                                    coverColumn(side: side)
                                    cardsColumn
                                        .frame(maxWidth: 620)
                                }
                                .frame(maxHeight: .infinity, alignment: .center)
                                HStack(alignment: .top, spacing: 24) {
                                    coverColumn(side: side)
                                    ScrollView(.vertical, showsIndicators: false) {
                                        cardsColumn
                                            .padding(.bottom, 8)
                                    }
                                    .frame(maxWidth: 620)
                                }
                            }
                        } else {
                            HStack(alignment: .top, spacing: 24) {
                                coverColumn(side: side)
                                ScrollView(.vertical, showsIndicators: false) {
                                    cardsColumn
                                        .padding(.bottom, 8)
                                }
                            }
                        }
                    }
                    .padding(.leading, 24 + insets.left)
                    .padding(.trailing, 24 + insets.right)
                    .padding(.top, 16)
                    .padding(.bottom, 22)
                }

                if showsFileActions {
                    GameFileActionsPanel(entries: fileActionEntries,
                                         onClose: { showsFileActions = false })
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        // Scoped, like the library's: the ground is always dark, so the
        // controls here read as dark whatever the phone's appearance.
        .environment(\.colorScheme, .dark)
        .task(id: coverKey) {
            let filename = game.romFilePath
            // The square's cap in pixels (the side itself lives in the
            // geometry closure above): never smaller than what is drawn.
            let maxPixels = (isTablet ? Self.tabletCoverCap : 200) * displayScale
            // No hash and no cover type on purpose: the page shows the living
            // screenshot, never the library cover.
            let loaded = await Task.detached(priority: .userInitiated) {
                LibraryLandscapeCover.load(filename: filename, romHash: nil, coverType: nil,
                                           maxPixels: maxPixels)
            }.value
            cover = loaded
        }
        .task(id: previewsKey) {
            let name = romName
            let indices = existingSlots.map(\.slotIndex)
            guard !name.isEmpty else { return }
            let loaded = await Task.detached(priority: .userInitiated) { () -> [Int: UIImage] in
                let manager = SaveStateManager(romName: name)
                var out: [Int: UIImage] = [:]
                for index in indices {
                    if let image = manager.loadPreviewImage(slot: index) { out[index] = image }
                }
                return out
            }.value
            previews = loaded
        }
    }

    /// The square on the left, from the screen height: the top bar, the two
    /// margins, the title on two lines and the caption under it take 170
    /// points, and the square is capped so it stays a picture, not a poster.
    static func coverSide(forHeight height: CGFloat) -> CGFloat {
        min(max(height - 170, 120), 200)
    }

    /// The same square on an iPad (2026-09-05): the chrome budget grows with
    /// the taller bar clearance, and the cap nearly doubles, because a
    /// 200-point square on a 1032-point-tall window reads as a thumbnail.
    static let tabletCoverCap: CGFloat = 380
    static func tabletCoverSide(forHeight height: CGFloat) -> CGFloat {
        min(max(height - 260, 200), tabletCoverCap)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            FocusableButton(shape: .capsule) {
                dismiss()
            } label: {
                LandscapeChrome.circle(systemName: "chevron.left")
            }
            .accessibilityLabel(NSLocalizedString("tab.library", comment: ""))

            Spacer(minLength: 8)

            ControllerStatusBadge(tint: .white)

            // The game's file actions, in a panel of the library's kind rather
            // than a system menu (2026-09-27): a controller cannot open a
            // system menu, and every other bar of these pages already opens
            // panels (the sort and look ones since 2026-09-07).
            FocusableButton(shape: .capsule) {
                Haptics.tap()
                showsFileActions = true
            } label: {
                LandscapeChrome.circle(systemName: "ellipsis")
            }
        }
        .frame(height: 40)
    }

    /// The file actions, in the order the system menu had them, delete last.
    private var fileActionEntries: [GameFileActionsPanel.Entry] {
        var entries: [GameFileActionsPanel.Entry] = [
            .init(titleKey: "saveImport.title", systemImage: "square.and.arrow.down", action: actions.importSave),
            .init(titleKey: "saveExport.title", systemImage: "square.and.arrow.up", action: actions.exportSave),
            .init(titleKey: "details.replaceROM", systemImage: "arrow.triangle.2.circlepath", action: actions.replaceROM),
            .init(titleKey: "details.rename", systemImage: "pencil", action: actions.rename),
            .init(titleKey: "details.cover.choose", systemImage: "photo", action: actions.chooseCover),
        ]
        if game.coverType == BoxArtManager.coverStateCustom {
            entries.append(.init(titleKey: "details.cover.remove", systemImage: "xmark.circle",
                                 action: actions.removeCover))
        }
        entries.append(.init(titleKey: "details.delete", systemImage: "trash",
                             isDestructive: true, action: actions.delete))
        return entries
    }

    // MARK: - The cover column

    /// The cards, in the page's order.
    private var cardsColumn: some View {
        VStack(spacing: 12) {
            playCard
            slotsCard
            achievementsCard
            if isNDS {
                slot2Card
                ndsSettingsCard
            }
        }
    }

    private func coverColumn(side: CGFloat) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.11, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                if let cover {
                    // Fit, not fill: this is the player's own screen, and a
                    // DS screenshot is taller than wide. The square is the
                    // frame, the picture keeps its shape inside it.
                    Image(uiImage: cover.image)
                        .resizable()
                        .interpolation(cover.isPixelArt ? .none : .medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side - 16, height: side - 16)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: side * 0.3, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.11, style: .continuous)
                    .strokeBorder(LibraryLandscapePalette.accentGradient, lineWidth: 3)
            )
            // One static blurred layer, as the library's glow: rasterised
            // once, never re-filtered.
            .background(
                RoundedRectangle(cornerRadius: side * 0.11, style: .continuous)
                    .fill(LibraryLandscapePalette.accentGradient)
                    .blur(radius: 22)
                    .opacity(0.55)
            )
            .accessibilityHidden(true)

            // The title lives here, under the picture, not in the bar
            // (decided on device, 2026-09-04).
            Text(game.title ?? NSLocalizedString("library.untitled", comment: ""))
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            HStack(spacing: 10) {
                if let playTime {
                    Text(playTime)
                }
                if game.romSize > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: game.romSize, countStyle: .file))
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
        }
        .frame(width: side)
    }

    // MARK: - Cards

    /// Resume the session when there is one, else Play; and beside it, when
    /// there is a session, the start from the title screen (which the page
    /// confirms, as in portrait). Same footer as portrait, because "your
    /// in-game save is loaded from the game's own menu" is the one thing
    /// this card has to explain.
    private var playCard: some View {
        LandscapeChrome.card(nil) {
            let hasSession = autoSlot?.exists == true
            // The title-screen start comes FIRST and the resume LAST (decided on
            // device, 2026-09-05): on a device on its side the right thumb is
            // the one on the buttons, and the resume is the main action, so it
            // is the one nearest that thumb.
            HStack(spacing: 10) {
                if hasSession {
                    // Portrait's icon for the same action, so the two layouts
                    // name it the same way.
                    FocusableButton(shape: .capsule, action: actions.newGame) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text(NSLocalizedString("details.newGame", comment: ""))
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(LandscapeChrome.glass(Capsule()))
                    }
                }

                // Where a controller's highlight starts on this page.
                FocusableButton(shape: .capsule, isDefault: true) {
                    if hasSession { actions.resume() } else { actions.newGame() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: hasSession ? "play.circle.fill" : "play.fill")
                        Text(hasSession
                             ? NSLocalizedString("details.continue", comment: "")
                             : NSLocalizedString("details.play", comment: ""))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .background(Capsule().fill(LibraryLandscapePalette.accentGradient))
                }
            }
            Text(NSLocalizedString("details.launch.footer", comment: ""))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The quick-save slots as chips in a row: preview, name, date. Tapping
    /// one plays from it, as the portrait rows do.
    private var slotsCard: some View {
        LandscapeChrome.card(NSLocalizedString("details.saveSlots", comment: "")) {
            if existingSlots.isEmpty {
                if iCloudUnavailable {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("details.iCloudUnavailable.title", comment: ""))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(NSLocalizedString("details.iCloudUnavailable.body", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text(NSLocalizedString("details.noSaves", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(existingSlots, id: \.slotIndex) { slot in
                            slotChip(slot)
                        }
                    }
                }
            }
        }
    }

    private func slotChip(_ slot: SaveSlotInfo) -> some View {
        FocusableButton(shape: .rounded(10)) {
            actions.playSlot(slot.slotIndex)
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let image = previews[slot.slotIndex] {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(LandscapeChrome.cardFill))
                    }
                }
                .frame(width: 96, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(String(format: NSLocalizedString("overlay.slot", comment: ""), "\(slot.slotIndex)"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                if let date = slot.date {
                    Text(date, formatter: Self.dateTimeFormatter)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// RetroAchievements, only when the account is connected and the game has
    /// a set (decided on device, 2026-09-04): the invite and the "not available" note
    /// are portrait's.
    @ViewBuilder
    private var achievementsCard: some View {
        switch raState {
        case .hidden, .invite, .unavailable:
            EmptyView()
        case .dashboard(let record):
            LandscapeChrome.card(nil) {
                RASectionHeader(onInfo: actions.raInfo)
                FocusableButton(action: actions.openAchievements) {
                    HStack(spacing: 12) {
                        if let boxArt = record.boxArtURL.flatMap(URL.init(string:)) {
                            AsyncImage(url: boxArt) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                ZStack {
                                    Color.white.opacity(LandscapeChrome.cardFill)
                                    Image(systemName: "trophy")
                                        .font(.footnote)
                                        .foregroundStyle(.white.opacity(0.78))
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: "trophy")
                                .foregroundStyle(.yellow)
                                .frame(width: 44, height: 44)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(String(localized: "details.achievements", defaultValue: "View achievements"))
                                .foregroundStyle(.white)
                            if record.refreshedAt != nil, record.total > 0 {
                                HStack {
                                    Text(String(format: String(localized: "ra.dashboard.summary",
                                                               defaultValue: "%lld of %lld unlocked"),
                                                record.unlocked, record.total))
                                    Spacer(minLength: 8)
                                    if let earned = record.pointsEarned, let total = record.pointsTotal {
                                        Text("\(earned.formatted()) / \(total.formatted()) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                                            .monospacedDigit()
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.78))
                                ProgressView(value: Double(record.unlocked), total: Double(record.total))
                                    .tint(.yellow)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The GBA game in slot 2 of a DS game, with the two notes portrait
    /// carries as its footer.
    private var slot2Card: some View {
        LandscapeChrome.card(NSLocalizedString("slot2.row", comment: "")) {
            Button(action: actions.pickSlot2) {
                HStack(spacing: 12) {
                    if let picked = slot2Game {
                        GameCoverView(romFilePath: picked.romFilePath,
                                      boxArtURL: BoxArtManager.shared.coverFileURL(
                                        forROMHash: picked.romHash, coverType: picked.coverType),
                                      fixedWidth: 44)
                        Text(picked.title ?? (picked.romFilePath ?? ""))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    } else {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.white.opacity(0.85))
                        Text(NSLocalizedString("slot2.none", comment: ""))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            InfoCallout(text: NSLocalizedString("slot2.saveNote", comment: ""))
            Text(NSLocalizedString("slot2.caption", comment: ""))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The three DS settings, the same three app-wide defaults portrait
    /// shows, with the language footer under the picker.
    private var ndsSettingsCard: some View {
        LandscapeChrome.card("Nintendo DS") {
            Toggle(NSLocalizedString("settings.nds.swapScreens", comment: ""), isOn: $ndsSwapScreens)
                .tint(LibraryLandscapePalette.accent)
                .controllerToggle($ndsSwapScreens, shape: .rounded(8))
            Toggle(NSLocalizedString("settings.nds.clock.manual", comment: ""), isOn: $ndsClockManual)
                .tint(LibraryLandscapePalette.accent)
                .controllerToggle($ndsClockManual, shape: .rounded(8))
            if ndsClockManual {
                DatePicker(NSLocalizedString("settings.nds.clock.pickerLabel", comment: ""),
                           selection: ndsManualDate)
                    .tint(.white)
            }
            Picker(NSLocalizedString("settings.nds.language", comment: ""), selection: $ndsLanguage) {
                Text(ndsAutoLanguageLabel).tag("auto")
                ForEach(Array(ndsLanguageAutonyms.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(String(index))
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            Text(DeviceWording.string("settings.nds.language.footer"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
    }
}


/// The game page's file actions on its side (2026-09-27): the library's panel
/// shape (a dimmed page, a dark card, rows), which a finger and a controller
/// both reach. Choosing a row closes the panel and runs the action, exactly as
/// the system menu it replaces did.
struct GameFileActionsPanel: View {
    struct Entry: Identifiable {
        let titleKey: String
        let systemImage: String
        var isDestructive = false
        let action: () -> Void
        var id: String { titleKey }
    }

    let entries: [Entry]
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
                .accessibilityLabel(NSLocalizedString("common.cancel", comment: ""))

            // Scrolls only when the rows outgrow the page (a small phone on
            // its side, a long language): the rows are never cut to fit.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView(.vertical, showsIndicators: false) { rows }
            }
            .padding(.vertical, 6)
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.10).opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            .padding(.vertical, 16)
            // While open, a controller reaches the rows alone; B closes it.
            .controllerBack(onClose)
            .controllerModalGroup("details.fileActions")
        }
        .transition(.opacity)
    }

    private var rows: some View {
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().overlay(Color.white.opacity(0.12))
                    }
                    FocusableButton(shape: .rounded(10), isDefault: index == 0) {
                        Haptics.tap()
                        onClose()
                        entry.action()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 24)
                            Text(NSLocalizedString(entry.titleKey, comment: ""))
                                .font(.subheadline.weight(.medium))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                        }
                        .foregroundStyle(entry.isDestructive ? Color.red : Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                    }
                }
            }
    }
}
