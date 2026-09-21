//
//  SettingsView.swift
//  EmulateurGBA
//

import SwiftUI
import UIKit
import CoreData

struct SettingsView: View {
    @AppStorage("hapticsEnabled") private var hapticsEnabled: Bool = true
    /// In-game haptic strength, 1-6. 3 = the historical default feel; the sub-row
    /// only shows while haptics are ON. Read by TouchControlsView.fireHaptic.
    @AppStorage("hapticStrength") private var hapticStrength: Int = 3
    @AppStorage("useJoystick") private var useJoystick: Bool = false
    @AppStorage("showClipButton") private var showClipButton: Bool = true
    /// TV layout for the DS on an external display. Default matches
    /// ExternalDisplayManager's own default when the key is absent.
    @AppStorage(ExternalDisplayManager.ndsSideBySideKey)
    private var externalNDSSideBySide: Bool = true
    @ObservedObject private var proManager = ProManager.shared
    @ObservedObject private var controllers = ControllerManager.shared
    @ObservedObject private var iCloudSync = iCloudSaveSync.shared
    @State private var proSheetItem: ProSheetItem?
    /// Drives the slow gold-glow drift on the Pro card (gradient motion only,
    /// no position change). Disabled under Reduce Motion.
    @State private var proGlowShift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A phone on its side, or an iPad window (see `LandscapeSurface`).
    @LandscapeSurface private var isLandscape
    /// An iPad window: the list is capped to a readable width there.
    @TabletSurface private var isTablet
    @Environment(\.surfaceSafeAreaInsets) private var surfaceInsets
    /// The shell's tab selection, so the landscape bar can go back to the
    /// library (the system tab bar is hidden there).
    @Binding var selectedTab: AppTab
    /// Whether this is the showing tab; pauses the landscape ground otherwise.
    var isActiveTab: Bool = true
    /// An upright phone in a chosen look (2026-09-07): the same list, the
    /// same positions, on the ground with its rows on glass.
    @ObservedObject private var themeStore = LandscapeThemeStore.shared
    private var uprightLook: Bool {
        UprightLook.isActive(isLandscape: isLandscape, store: themeStore)
    }
    /// In landscape, and upright in a look, every section's rows sit on glass
    /// over the moving ground; nil keeps the system row background on the
    /// List. Rows that set their own background (the Pro card, the rating
    /// card, the Pro-gated rows) keep it in both.
    private var landscapeRowBackground: Color? {
        isLandscape || uprightLook ? Color.white.opacity(LandscapeChrome.cardFill) : nil
    }
    @State private var showRALogin = false
    @State private var showWhatsNew = false
    @State private var showRomGuide = false
    @State private var showSaveGuide = false
    @State private var showControllerGuide = false
    @State private var showAirPlayGuide = false
    @State private var showWidgetGuide = false
    /// Whether a television is connected right now, seeded from the manager so
    /// the row is right on the FIRST render (a TV plugged in before Settings
    /// opened posts nothing while it is open) and kept current by the manager's
    /// change notification.
    @State private var tvConnected = ExternalDisplayManager.shared.isTVConnected
    @State private var cheatCacheBytes: Int64 = 0
    @State private var cheatPrefetch: (done: Int, total: Int)?
    @State private var cheatPrefetchFailed = false
    /// How many library games already have their codes on disk. nil until
    /// counted. Drives the "nothing left to fetch" state, so the button is
    /// never offered when tapping it would do nothing — that dead tap read as
    /// a bug on device.
    @State private var cheatCoverage: (cached: Int, total: Int)?
    #if DEBUG
    @State private var debugTapCount = 0
    #endif
    #if DEBUG
    @AppStorage("debugForceEmptyState") private var debugForceEmptyState: Bool = false
    /// Store screenshots: a fake library of fifteen fictional games with
    /// bundled covers stands in for the real one, both ways up, and nothing
    /// plays (2026-09-10, see `LibraryPresentation`). The language beside it
    /// sets the app's own language override and relaunches, so the shelf,
    /// its bars and the demo titles all read in the chosen language.
    @AppStorage(LibraryPresentation.key) private var debugPresentationMode: Bool = false
    @AppStorage(LibraryPresentation.languageKey) private var debugPresentationLanguage: String = ""
    #endif
    #if DEBUG
    @State private var showClipHintPreview = false
    @State private var showShotHintPreview = false
    @State private var showRAGameCardPreview = false
    @State private var showRAOverviewCardPreview = false
    /// Plain game-frame placeholder so the screenshot-card hint preview can render
    /// a real card from a source frame.
    private static let debugGameFrame: CGImage = {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160))
        let img = r.image { ctx in
            UIColor(red: 0.12, green: 0.08, blue: 0.20, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        }
        return img.cgImage!
    }()
    #endif

    /// SF Symbol matching the iCloud state — filled when on, slash when off or
    /// unavailable, outline while still resolving.
    private var iCloudIcon: String {
        guard iCloudSync.syncEnabled else { return "icloud.slash" }
        switch iCloudSync.state {
        case .resolving:   return "icloud"
        case .available:   return "icloud.fill"
        case .unavailable: return "icloud.slash"
        }
    }

    /// Localized one-word status for the iCloud row. The user's opt-out takes
    /// precedence over the resolution state.
    private var iCloudStateLabel: String {
        guard iCloudSync.syncEnabled else {
            return NSLocalizedString("settings.sync.state.disabled", comment: "")
        }
        switch iCloudSync.state {
        case .resolving:   return NSLocalizedString("settings.sync.state.resolving", comment: "")
        case .available:   return NSLocalizedString("settings.sync.state.available", comment: "")
        case .unavailable: return NSLocalizedString("settings.sync.state.unavailable", comment: "")
        }
    }

    /// A Controls-section row label that, when a controller is connected, shows
    /// a small controller glyph at the trailing edge (right next to the disabled
    /// switch), signalling the row is disabled because the setting applies only
    /// to the on-screen touch controls. The Spacer pushes the glyph to sit
    /// beside the switch rather than next to the text.
    /// A Pro-locked settings row: a refined invitation, not a barrier. Gold
    /// accents (icon, title, trailing crown — never a lock) read as premium
    /// and tempting; tapping opens the Pro sheet at `context`. Shared by
    /// Customize Controls and Controller Remapping (one "make the controls
    /// yours" family, one sheet).

    private var airPlayProCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .font(.footnote)
                    .foregroundStyle(goldTitleGradient)
                Text(NSLocalizedString("guide.airplay.proNotice", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(goldTitleGradient)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                // Dismiss first, then present: a sheet raised from inside a
                // sheet mid-dismissal is the bug this defer exists to avoid
                // (same pattern as the save-import follow-ups).
                showAirPlayGuide = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    proSheetItem = ProSheetItem(context: .externalDisplay)
                }
            } label: {
                Text(NSLocalizedString("guide.airplay.proButton", comment: ""))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(ProPalette.gold.opacity(0.45), lineWidth: 1)
            )
            .foregroundStyle(goldTitleGradient)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    /// Pre-fetches cheats for every game in the library, using the same
    /// per-game path the browser uses, so anything already cached is counted
    /// instantly and never fetched twice.
    @MainActor
    private func prefetchCheats() async {
        cheatPrefetchFailed = false
        let targets = cheatTargets()
        guard !targets.isEmpty else { return }
        cheatPrefetch = (0, targets.count)
        do {
            try await CheatLibrary.shared.prefetch(games: targets) { done, total in
                cheatPrefetch = (done, total)
            }
        } catch {
            cheatPrefetchFailed = true
        }
        cheatPrefetch = nil
        cheatCacheBytes = CheatLibrary.shared.cacheSize()
        cheatCoverage = countCheatCoverage()
    }

    /// (already cached, total) across the library, using the same key the
    /// browser uses so the two can never disagree about what is covered.
    @MainActor
    private func countCheatCoverage() -> (cached: Int, total: Int) {
        let targets = cheatTargets()
        let cached = targets.filter {
            CheatLibrary.shared.isCached(title: $0.title, system: $0.system)
        }.count
        return (cached, targets.count)
    }

    /// Every library game as (ROM filename stem, console key) — the identity
    /// the cheat index matches on.
    @MainActor
    private func cheatTargets() -> [(title: String, system: String)] {
        let context = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<GameEntity>(entityName: "GameEntity")
        let games = (try? context.fetch(request)) ?? []
        return games.compactMap { game in
            guard let path = game.romFilePath else { return nil }
            let stem = BatterySaveImporter.romBasename(forStoredFilename: path)
            guard !stem.isEmpty else { return nil }
            return (stem, game.systemType ?? "gba")
        }
    }

    private func premiumLockedRow(label: String, icon: String,
                                  context: ProPromptContext) -> some View {
        Button {
            proSheetItem = ProSheetItem(context: context)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(goldTitleGradient)
                Text(label)
                    .foregroundStyle(goldTitleGradient)
                Spacer(minLength: 8)
                Image(systemName: "crown.fill")
                    .font(.footnote)
                    .foregroundStyle(goldTitleGradient)
                    .shadow(color: Color(red: 1.0, green: 0.84, blue: 0.35).opacity(0.5), radius: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(label), \(NSLocalizedString("pro.badge", comment: ""))")
        .listRowBackground(premiumRowBackground)
    }

    @ViewBuilder
    private func controlsRowLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
            if controllers.isConnected {
                Spacer()
                Image(systemName: "gamecontroller.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    var body: some View {
        Group {
            if isLandscape {
                landscapeBody
            } else {
                settingsList
                    .uprightLook(isActive: isActiveTab)
            }
        }
        // Landscape draws its own bar on the library's ground and hides the
        // system bars there and only there; the pages pushed from here keep
        // theirs. On an iPad the bar's library circle gives way to the
        // Library · Settings pill at the bottom, either way up (2026-09-08,
        // see `LandscapeChrome.tabPill`).
        .toolbar(isLandscape ? .hidden : .visible, for: .navigationBar)
        .toolbar(isLandscape ? .hidden : .visible, for: .tabBar)
        .navigationTitle(NSLocalizedString("settings.title", comment: ""))
        // A television can arrive or leave while this screen is open, and the
        // external-display row is a different row in each case.
        .onReceive(NotificationCenter.default.publisher(
            for: ExternalDisplayManager.didChangeNotification)) { _ in
            tvConnected = ExternalDisplayManager.shared.isTVConnected
        }
        .task {
            cheatCacheBytes = CheatLibrary.shared.cacheSize()
            cheatCoverage = countCheatCoverage()
        }
        // Presented at the List level (not inside the RA section) so a section
        // re-render can't dismiss it as it animates in.
        .sheet(isPresented: $showRALogin) { RALoginView() }
        .sheet(isPresented: $showWhatsNew) { WhatsNewSheet() }
        #if DEBUG
        // Lets the "Simulate RA unlock" debug button preview the in-game HUD here.
        // RAUnlockHUD ignores the safe area itself and positions the card by the
        // window top inset, so this preview matches the in-game placement.
        .overlay(alignment: .top) { RAUnlockHUD() }
        // Same for "Simulate RA progress": without this overlay the pill has
        // no host outside gameplay and the button looks dead.
        .overlay(alignment: .top) { RAProgressHUD() }
        .sheet(isPresented: $showClipHintPreview) {
            // Presented exactly like the real card (the view now self-configures its
            // fill, opaque background, and adaptive detents) — so this previews the
            // true presentation path, not a hand-built approximation.
            ClipShareView(model: ClipShareModel(), frameAspect: 1.5,
                          onClose: { showClipHintPreview = false },
                          hintText: NSLocalizedString("clip.hint", value: "You can save the last 6 seconds anytime.", comment: ""))
        }
        .sheet(isPresented: $showShotHintPreview) {
            ScreenshotShareView(gameFrame: Self.debugGameFrame, name: "Demo Game",
                                playTime: 3 * 3600 + 25 * 60,
                                system: .gbc,   // preview the GB/GBC console Pro card
                                onClose: { showShotHintPreview = false },
                                hintText: NSLocalizedString("screenshot.hint", value: "Capture your best moment, anytime.", comment: ""))
        }
        .sheet(isPresented: $showRAGameCardPreview) {
            // Verifies the badge grid shrinks a full Fire-Red-sized set (157)
            // onto the console screen; badges are generated, no network needed.
            RAGameCardDebugPreview(onClose: { showRAGameCardPreview = false })
        }
        .sheet(isPresented: $showRAOverviewCardPreview) {
            // The overview card's mosaic tier: 30 generated games, the first 4
            // fully completed (gold mastered strokes). No network needed.
            RAOverviewCardDebugPreview(onClose: { showRAOverviewCardPreview = false })
        }
        #endif
        .sheet(item: $proSheetItem) { item in
            ProUpgradeView(context: item.context)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showRomGuide) {
            HowToSheet(
                title: NSLocalizedString("guide.importRom.title", comment: ""),
                intro: NSLocalizedString("guide.importRom.intro", comment: ""),
                steps: [
                    DeviceWording.string("guide.importRom.step1"),
                    DeviceWording.string("guide.importRom.step2"),
                    NSLocalizedString("guide.importRom.step3", comment: ""),
                    NSLocalizedString("guide.importRom.step4", comment: "")
                ],
                footer: NSLocalizedString("guide.importRom.footer", comment: "")
            )
        }
        .sheet(isPresented: $showSaveGuide) {
            HowToSheet(
                title: NSLocalizedString("saveImport.title", comment: ""),
                intro: NSLocalizedString("guide.saveImport.intro", comment: ""),
                steps: [
                    NSLocalizedString("guide.saveImport.step1", comment: ""),
                    NSLocalizedString("guide.saveImport.step2", comment: ""),
                    NSLocalizedString("guide.saveImport.step3", comment: ""),
                    NSLocalizedString("guide.saveImport.step4", comment: "")
                ],
                footer: NSLocalizedString("guide.saveImport.footer", comment: "")
            )
        }
        .sheet(isPresented: $showWidgetGuide) {
            HowToSheet(
                title: NSLocalizedString("guide.widget.title", comment: ""),
                intro: NSLocalizedString("guide.widget.intro", comment: ""),
                steps: [
                    NSLocalizedString("guide.widget.step1", comment: ""),
                    NSLocalizedString("guide.widget.step2", comment: ""),
                    NSLocalizedString("guide.widget.step3", comment: ""),
                    NSLocalizedString("guide.widget.step4", comment: ""),
                    NSLocalizedString("guide.widget.step5", comment: "")
                ],
                footer: DeviceWording.string("guide.widget.footer")
            )
        }
        .sheet(isPresented: $showAirPlayGuide) {
            HowToSheet(
                title: NSLocalizedString("guide.airplay.title", comment: ""),
                intro: DeviceWording.string("guide.airplay.intro"),
                steps: [
                    DeviceWording.string("guide.airplay.step1"),
                    NSLocalizedString("guide.airplay.step2", comment: ""),
                    DeviceWording.string("guide.airplay.step3"),
                    DeviceWording.string("guide.airplay.step4"),
                    NSLocalizedString("guide.airplay.step5", comment: ""),
                    NSLocalizedString("guide.airplay.step6", comment: "")
                ],
                footer: NSLocalizedString("guide.airplay.footer", comment: "")
            ) {
                // Free users get the offer above the steps; Pro users get the
                // steps and nothing else to read.
                if !proManager.isPro { airPlayProCard }
            }
        }
        .sheet(isPresented: $showControllerGuide) {
            HowToSheet(
                title: NSLocalizedString("guide.controller.title", comment: ""),
                intro: nil,
                steps: [
                    NSLocalizedString("guide.controller.step1", comment: ""),
                    DeviceWording.string("guide.controller.step2"),
                    NSLocalizedString("guide.controller.step3", comment: "")
                ],
                // The keyboard bindings are by physical position, and nothing
                // on screen ever said which keys: a French player on AZERTY
                // had six letters to discover by trial. Each locale names the
                // keys as printed on its own keyboard. The iPad twin drops the
                // sentence about the touch controls hiding, which is phone-only.
                footer: NSLocalizedString("guide.controller.footer", comment: "")
                    + "\n\n" + DeviceWording.string("guide.controller.keyboard")
            ) {
                ControllerStatusView(isConnected: controllers.isConnected,
                                     name: controllers.controllerName)
            }
        }
    }

    /// Settings on its side, in the landscape library's language (decided on device,
    /// 2026-09-04): the same ground and margins, a bar of our own (the title,
    /// the controller badge, the way back to the library), and the SAME list
    /// underneath with its rows turned to glass. A form of forty rows is not
    /// rebuilt as cards: the list is the content, so it is kept, and only its
    /// chrome changes. The way back sits in the bar rather than at the bottom
    /// right as on the library, because a floating circle over a scrolling
    /// list would cover its last rows.
    private var landscapeBody: some View {
        let insets = LandscapeChrome.insets(surfaceInsets)
        return ZStack {
            LibraryLandscapeBackground(isPaused: !isActiveTab || reduceMotion, dimmed: true)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(NSLocalizedString("settings.title", comment: ""))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    ControllerStatusBadge(tint: .white)
                    // An iPad has the pill at the bottom for that (2026-09-08).
                    if !isTablet {
                        Button {
                            selectedTab = .library
                        } label: {
                            LandscapeChrome.circle(systemName: "books.vertical")
                        }
                        .accessibilityLabel(NSLocalizedString("tab.library", comment: ""))
                    }
                }
                .frame(height: 40)
                .padding(.horizontal, 24)
                .padding(.top, LandscapeChrome.barTopPadding(tablet: isTablet, insets: insets))
                // On an iPad the list is capped to a readable width and centred;
                // a phone keeps it edge to edge.
                settingsList
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: isTablet ? LandscapeChrome.tabletListMaxWidth : .infinity)
                    .padding(.leading, insets.left)
                    .padding(.trailing, insets.right)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isTablet {
                    LandscapeChrome.tabPill(selected: .settings, insets: insets) { tab in
                        selectedTab = tab
                    }
                }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var settingsList: some View {
        List {
            // Pro section
            Section {
                if proManager.isPro {
                    Label {
                        HStack {
                            Text(NSLocalizedString("pro.title", comment: ""))
                            Spacer()
                            Text(NSLocalizedString("pro.purchased", comment: ""))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        // The Pro crown badge (same metal emblem as the share cards)
                        // marks the purchased state, replacing the green checkmark.
                        Image(uiImage: ScreenshotCardRenderer.proCrownBadgeImage(side: 30))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 34, height: 34)
                    }
                } else {
                    proCard
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                // "Restaurer les achats" now lives inside the Pro sheet only.
            }
                .listRowBackground(landscapeRowBackground)

            Section(header: Text(NSLocalizedString("settings.controls", comment: "")),
                    footer: Text(controllers.isConnected
                                 ? NSLocalizedString("settings.controls.controllerActive.footer", comment: "")
                                 : NSLocalizedString("settings.controls.dpad.footer", comment: ""))) {
                Toggle(isOn: $hapticsEnabled) {
                    controlsRowLabel(NSLocalizedString("settings.haptics", comment: ""))
                }
                .disabled(controllers.isConnected)

                if hapticsEnabled {
                    // Strength sub-option, revealed by the toggle above. Six
                    // levels; 3 keeps the app's historical feel.
                    VStack(alignment: .leading, spacing: 8) {
                        controlsRowLabel(NSLocalizedString("settings.haptics.strength", comment: ""))
                        Picker(NSLocalizedString("settings.haptics.strength", comment: ""),
                               selection: $hapticStrength) {
                            ForEach(1...6, id: \.self) { level in
                                Text("\(level)").tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        // Answer the selection with the strength it picked, so
                        // the level is chosen by feel, not by number.
                        .onChange(of: hapticStrength) { level in
                            TouchControlsView.previewHaptic(level: level)
                        }
                    }
                    .disabled(controllers.isConnected)
                }

                Toggle(isOn: $useJoystick) {
                    controlsRowLabel(useJoystick
                         ? NSLocalizedString("settings.joystick", comment: "")
                         : NSLocalizedString("settings.dpad", comment: ""))
                }
                .disabled(controllers.isConnected)

                Toggle(isOn: $showClipButton) {
                    controlsRowLabel(NSLocalizedString("settings.clipButton", comment: ""))
                }
                .disabled(controllers.isConnected)

                // Customize stays tappable even with a controller connected: it
                // is a setup action for the touch layout (used when the
                // controller is later disconnected), not a live touch setting.
                if proManager.isPro {
                    NavigationLink {
                        ControlPresetsView()
                    } label: {
                        Label(NSLocalizedString("settings.customizeControls", comment: ""),
                              systemImage: "hand.draw")
                    }
                } else {
                    premiumLockedRow(label: NSLocalizedString("settings.customizeControls", comment: ""),
                                     icon: "hand.draw",
                                     context: .customizeControls)
                }
            }
                .listRowBackground(landscapeRowBackground)

            // Controller in its own section so the Bluetooth-pairing footer stays
            // attached to it (and the touch section's footer can speak to the
            // D-pad/Joystick choice).
            Section(footer: Text(NSLocalizedString("settings.controller.footer", comment: ""))) {
                Button {
                    showControllerGuide = true
                } label: {
                    HStack {
                        Label(NSLocalizedString("settings.controller.row", comment: ""),
                              systemImage: "gamecontroller")
                            .foregroundColor(.primary)
                        Spacer()
                        ControllerStatusView(isConnected: controllers.isConnected,
                                             name: controllers.controllerName,
                                             compact: true)
                    }
                }

                // Button remapping (Pro) — only offered while a pad is
                // actually connected (the guided flow needs its presses).
                // Same Pro treatment and the SAME Pro sheet as Customize
                // Controls: the two are one "make the controls yours" family.
                if controllers.isConnected {
                    if proManager.isPro {
                        NavigationLink {
                            ControllerRemapView()
                        } label: {
                            Label(NSLocalizedString("settings.remapController", comment: ""),
                                  systemImage: "arrow.triangle.swap")
                        }
                    } else {
                        premiumLockedRow(label: NSLocalizedString("settings.remapController", comment: ""),
                                         icon: "arrow.triangle.swap",
                                         context: .customizeControls)
                    }
                }

                // Keyboard keys (FREE, 1.3.1) — only while a keyboard is
                // attached, for the same reason: the flow needs its presses.
                // Free where the pad's remap is Pro because a Bluetooth pad iOS
                // sees as a keyboard is unplayable until its letters are bound
                // (the reasoning is in KeyboardMapping.swift).
                if controllers.isKeyboardAttached {
                    NavigationLink {
                        KeyboardRemapView()
                    } label: {
                        Label(NSLocalizedString("settings.remapKeyboard", comment: ""),
                              systemImage: "keyboard")
                    }
                }

                // Screen + Menu layout for controller play (Pro). Shown only
                // while the touch controls are out of the way (a pad, or a
                // keyboard on a phone), like the remap rows above: it is the
                // only moment the setting means anything, and the editor
                // previews the game as it renders WITH a controller.
                if controllers.hidesTouchControls {
                    if proManager.isPro {
                        NavigationLink {
                            ControllerLayoutView()
                        } label: {
                            Label(NSLocalizedString("settings.controllerLayout", comment: ""),
                                  systemImage: "rectangle.inset.filled")
                        }
                    } else {
                        premiumLockedRow(label: NSLocalizedString("settings.controllerLayout", comment: ""),
                                         icon: "rectangle.inset.filled",
                                         context: .customizeControls)
                    }
                }
            }
                .listRowBackground(landscapeRowBackground)

            // External display (Pro). Free users keep the passive mirroring iOS
            // already gives them: we only put a window on the TV for Pro, so
            // the gate adds an output instead of removing one.
            Section(header: Text(NSLocalizedString("settings.externalDisplay.section", comment: "")),
                    footer: Text(DeviceWording.string("settings.externalDisplay.footer"))) {
                if proManager.isPro {
                    // The DS screen arrangement is a choice ABOUT a television,
                    // so it only appears while there is one. With nothing
                    // connected the row answered a question nobody had asked and
                    // gave no hint that a TV was the missing part; it now says so
                    // and opens the guide that explains how to connect one.
                    if tvConnected {
                        Picker(NSLocalizedString("settings.externalDisplay.ndsLayout", comment: ""),
                               selection: $externalNDSSideBySide) {
                            Text(NSLocalizedString("settings.externalDisplay.sideBySide", comment: "")).tag(true)
                            Text(NSLocalizedString("settings.externalDisplay.stacked", comment: "")).tag(false)
                        }
                        // Inline, one option per row: the default menu style
                        // prints the chosen value on the label's row and clips
                        // it, and "L'un au-dessus de l'autre" (fr) is 25
                        // characters against 7 for "Stacked".
                        .pickerStyle(.inline)
                        .onChange(of: externalNDSSideBySide) { newValue in
                            // Push to a television that is already connected.
                            ExternalDisplayManager.shared.ndsSideBySide = newValue
                        }
                    } else {
                        Button {
                            showAirPlayGuide = true
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(NSLocalizedString("settings.externalDisplay.noTV", comment: ""))
                                            .foregroundColor(.primary)
                                        // What the tap does. The state alone
                                        // reads as a dead status line.
                                        Text(NSLocalizedString("settings.externalDisplay.noTV.caption", comment: ""))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "airplayvideo")
                                }
                                Spacer(minLength: 8)
                                // The row does something, so it says so. Without
                                // this it reads as a disabled status line.
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } else {
                    premiumLockedRow(label: NSLocalizedString("settings.externalDisplay.row", comment: ""),
                                     icon: "airplayvideo",
                                     context: .externalDisplay)
                }
            }
                .listRowBackground(landscapeRowBackground)

            // Console-specific settings live on the game's own page (the
            // Nintendo DS rows moved to a DS game's details in 1.3.1), so this
            // list does not grow a section per console.
            RetroAchievementsSection(onConnect: { showRALogin = true })
                .listRowBackground(landscapeRowBackground)

            // Cheat codes are Pro, so this section only means anything there.
            // The database itself is fetched a game at a time; this makes the
            // games someone actually OWNS available without a connection —
            // a dozen small files rather than the four thousand a whole-console
            // download would be.
            if proManager.isPro {
                Section(header: Text(NSLocalizedString("settings.cheatDB.section", comment: "")),
                        footer: Text(NSLocalizedString("settings.cheatDB.footer", comment: ""))) {
                    if let progress = cheatPrefetch {
                        // A determinate bar, not a spinner: the total is known
                        // up front, so hiding it would be a choice to tell the
                        // user less than we know.
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: Double(progress.done),
                                         total: Double(max(progress.total, 1)))
                            Text(String(format: NSLocalizedString("settings.cheatDB.progress", comment: ""),
                                        progress.done, progress.total))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else if let coverage = cheatCoverage,
                              coverage.total > 0, coverage.cached >= coverage.total {
                        // Everything is already on disk. Say so instead of
                        // offering a button whose tap does nothing.
                        Label(NSLocalizedString("settings.cheatDB.upToDate", comment: ""),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    } else if cheatCoverage?.total == 0 {
                        Text(NSLocalizedString("settings.cheatDB.noGames", comment: ""))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task { await prefetchCheats() }
                        } label: {
                            Label(NSLocalizedString("settings.cheatDB.download", comment: ""),
                                  systemImage: "arrow.down.circle")
                                .foregroundColor(.primary)
                        }
                    }

                    if cheatPrefetchFailed {
                        Text(NSLocalizedString("cheats.browse.offline", comment: ""))
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if cheatCacheBytes > 0 {
                        HStack {
                            Text(NSLocalizedString("settings.cheatDB.stored", comment: ""))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: cheatCacheBytes,
                                                           countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            CheatLibrary.shared.clearCache()
                            cheatCacheBytes = CheatLibrary.shared.cacheSize()
                            cheatCoverage = countCheatCoverage()
                        } label: {
                            Text(NSLocalizedString("settings.cheatDB.clear", comment: ""))
                        }
                    }
                }
                    .listRowBackground(landscapeRowBackground)
            }

            Section(NSLocalizedString("settings.guides.section", comment: "")) {
                Button {
                    showRomGuide = true
                } label: {
                    Label(NSLocalizedString("guide.importRom.title", comment: ""),
                          systemImage: "arrow.down.doc")
                        .foregroundColor(.primary)
                }
                Button {
                    showSaveGuide = true
                } label: {
                    Label(NSLocalizedString("saveImport.title", comment: ""),
                          systemImage: "square.and.arrow.down")
                        .foregroundColor(.primary)
                }
                // Deliberately a plain row for everyone, not a gold Pro row:
                // the steps are worth reading before deciding to buy, and the
                // Pro card inside the sheet does the asking.
                Button {
                    showAirPlayGuide = true
                } label: {
                    Label(NSLocalizedString("guide.airplay.title", comment: ""),
                          systemImage: "airplayvideo")
                        .foregroundColor(.primary)
                }
                // The widget is free and lives entirely outside the app, so a
                // guide is the only place it can be discovered from inside it.
                Button {
                    showWidgetGuide = true
                } label: {
                    Label(NSLocalizedString("guide.widget.title", comment: ""),
                          systemImage: "square.grid.2x2")
                        .foregroundColor(.primary)
                }
            }
                .listRowBackground(landscapeRowBackground)

            Section {
                Toggle(NSLocalizedString("settings.sync.toggle", comment: ""), isOn: Binding(
                    get: { iCloudSync.syncEnabled },
                    set: { iCloudSync.setSyncEnabled($0) }
                ))
                HStack {
                    Label("iCloud", systemImage: iCloudIcon)
                    Spacer()
                    Text(iCloudStateLabel)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(NSLocalizedString("settings.sync.section", comment: ""))
            } footer: {
                Text(DeviceWording.string("settings.sync.footer"))
            }
                .listRowBackground(landscapeRowBackground)

            Section(NSLocalizedString("settings.general", comment: "")) {
                NavigationLink(destination: LegalView()) {
                    Label(NSLocalizedString("settings.legal", comment: ""), systemImage: "doc.text")
                }
            }
                .listRowBackground(landscapeRowBackground)

            Section(NSLocalizedString("settings.about", comment: "")) {
                // Permanent home of the release notes: the launch sheet shows
                // once per update, this row keeps it reachable anytime.
                Button {
                    showWhatsNew = true
                } label: {
                    Label(NSLocalizedString("whatsnew.title", comment: ""), systemImage: "sparkles")
                }
                HStack {
                    Text(NSLocalizedString("settings.appLabel", comment: ""))
                    Spacer()
                    Text(NSLocalizedString("settings.app", comment: ""))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(NSLocalizedString("settings.version", comment: ""))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundStyle(.secondary)
                }
                #if DEBUG
                .onTapGesture {
                    debugTapCount += 1
                    if debugTapCount >= 7 {
                        debugTapCount = 0
                        proManager.debugTogglePro()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        debugTapCount = 0
                    }
                }
                #endif
                // Was a one-line value beside its label. Four core names did
                // not fit, and every future console makes it worse, so it
                // became a link to a screen that says which core runs which
                // console instead of just listing names.
                NavigationLink(destination: EmulationEnginesView()) {
                    Text(NSLocalizedString("settings.core", comment: ""))
                }
            }
                .listRowBackground(landscapeRowBackground)

            // The rating ask, on its own and last in a release build (the
            // debug sections below it exist only in debug builds). It used to
            // be one plain row inside About; it is now the warm-up card the
            // 1.2.5 review engine retired, reused as a settings card: the card
            // was withdrawn as an unsolicited prompt, and this is a row the
            // person opens Settings to find, which Apple's guidance allows.
            Section {
                rateCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
                .listRowBackground(landscapeRowBackground)

            #if DEBUG
            Section("Debug") {
                Button("What's New: reset seen version (re-arms the launch sheet)") {
                    WhatsNew.debugResetSeen()
                }
                Toggle("Force empty-state onboarding", isOn: $debugForceEmptyState)
                Toggle("Presentation mode (a fake library of demo games, nothing plays)", isOn: $debugPresentationMode)
                Picker("Presentation language (relaunches the app)", selection: $debugPresentationLanguage) {
                    Text("System").tag("")
                    ForEach(LibraryPresentation.languages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .onChange(of: debugPresentationLanguage) { code in
                    LibraryPresentation.applyLanguage(code)
                }
                Button(controllers.isConnected
                       ? "Fake controller: ON (tap to disconnect)"
                       : "Fake controller: OFF (tap to connect)") {
                    controllers.debugSetConnected(!controllers.isConnected)
                }
                // The keyboard row, its page and the phone-only hiding of the
                // touch controls; capture still needs a real key.
                Button(controllers.isKeyboardAttached
                       ? "Fake keyboard: ON (tap to detach)"
                       : "Fake keyboard: OFF (tap to attach)") {
                    controllers.debugSetKeyboardAttached(!controllers.isKeyboardAttached)
                }
                NavigationLink(destination: LayoutPreviewGallery()) {
                    Text("Layout preview (SE / Pro Max)")
                }
                NavigationLink(destination: SkinPreviewGallery()) {
                    Text("Skin preview (per console / orientation)")
                }
                NavigationLink(destination: OverlayMenuPreviewGallery()) {
                    Text("Pause menu preview (SE / Pro Max)")
                }
                NavigationLink(destination: BadgeGalleryView()) {
                    Text("Screenshot badges")
                }
                NavigationLink(destination: StatsCardPreviewGallery()) {
                    Text("Stats card preview (SE / Pro Max)")
                }
                NavigationLink(destination: StatsCardLandscapePreviewGallery()) {
                    Text("Stats card LANDSCAPE (SE / Pro Max)")
                }
                NavigationLink(destination: LibraryLandscapePreviewGallery()) {
                    Text("Library landscape preview (SE / Pro Max)")
                }
                Button("Clip card hint preview") { showClipHintPreview = true }
                Button("Screenshot card hint preview") { showShotHintPreview = true }
                Button("Simulate RA unlock (preview HUD)") {
                    RetroAchievements.shared.debugSimulateUnlock()
                }
                Button("Simulate RA progress (preview pill)") {
                    RetroAchievements.shared.debugSimulateProgress()
                }
                // The banner "Terminer une série, ou un jeu entier, a droit à son
                // propre moment à l'écran" describes. Tap twice: the second tap
                // uses a long title, which is the case the card's two lines are for.
                Button("Simulate RA game completed (banner, tap twice)") {
                    RetroAchievements.shared.debugSimulateCompletion(subset: false)
                }
                Button("Simulate RA set completed (banner, tap twice)") {
                    RetroAchievements.shared.debugSimulateCompletion(subset: true)
                }
                Button("RA game card (157 badges, Fire-Red-sized)") {
                    showRAGameCardPreview = true
                }
                Button("RA overview card (30 games, 4 completed)") {
                    showRAOverviewCardPreview = true
                }
            }
                .listRowBackground(landscapeRowBackground)

            Section("Debug — Pro Sheets") {
                debugProSheetButton("Speed moment (earned, 30 min)", context: .speedMoment(minutesAtFreeSpeed: 30))
                debugProSheetButton("Speed tapped (no stat)", context: .speedTapped)
                debugProSheetButton("Save slot full (earned)", context: .saveSlotFull)
                debugProSheetButton("Save slot tapped (no stat)", context: .saveSlotTapped)
                debugProSheetButton("Session milestone (60 min)", context: .sessionMilestone(totalMinutes: 60))
                debugProSheetButton("Rewind limit", context: .rewindLimit)
                debugProSheetButton("Cheat codes (4h on game)", context: .cheatCodes(gameName: "Pokemon Ruby"))
                debugProSheetButton("Cheat codes tapped", context: .cheatCodesTapped)
                debugProSheetButton("Tapped locked feature (generic)", context: .tappedLockedFeature)
                debugProSheetButton("Customize controls", context: .customizeControls)
                debugProSheetButton("Custom skins (create/edit/import)", context: .customSkins)
                debugProSheetButton("Video filters (Appearance ▸ Screen)", context: .videoFilters)
                debugProSheetButton("External display / AirPlay (Settings)", context: .externalDisplay)
            }
                .listRowBackground(landscapeRowBackground)

            // Every iPad surface at the three iPad sizes, both orientations,
            // reviewable from a phone (2026-09-05).
            Section("Debug iPad (mini / 11 / 13, both orientations)") {
                ForEach(TabletPreviewPage.allCases) { page in
                    NavigationLink(destination: TabletPreviewGallery(page: page)) {
                        Text(page.title)
                    }
                }
            }
                .listRowBackground(landscapeRowBackground)
            #endif

            Section {
                Text(NSLocalizedString("settings.disclaimer", comment: ""))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
                .listRowBackground(landscapeRowBackground)

        }
    }

    #if DEBUG
    private func debugProSheetButton(_ label: String, context: ProPromptContext) -> some View {
        Button(label) {
            proSheetItem = ProSheetItem(context: context)
        }
    }
    #endif

    /// The Pro upsell as a premium card (two rows tall) instead of a plain row:
    /// a dark neon-luxury card with a gold→purple bezel, a subtle gold corner
    /// glow + particle drift, and the same tap target as before (opens the Pro
    /// sheet). Gold is used as accents, never a fill.
    fileprivate var proCard: some View {
        Button {
            proSheetItem = ProSheetItem(context: .tappedLockedFeature)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(goldTitleGradient)
                    .shadow(color: Color(red: 1.0, green: 0.84, blue: 0.35).opacity(0.5), radius: 6)

                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("pro.title", comment: ""))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(goldTitleGradient)
                    Text(proCardSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(proCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.84, blue: 0.35).opacity(0.85),
                                Color(red: 0.45, green: 0.2, blue: 0.85).opacity(0.85)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.5)
            )
            .shadow(color: Color(red: 0.45, green: 0.2, blue: 0.85).opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .onAppear {
            guard !reduceMotion else { return }
            // Slow gold-glow drift across the top — a luxury light sweep, no
            // position motion.
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                proGlowShift = true
            }
        }
    }

    /// The rating card: the retired warm-up sheet's look (its night gradient,
    /// gold glow, five gold stars, a title and one sentence) at the size of
    /// two settings rows, with the section cells' corner radius so it reads
    /// as a row of this list rather than a floating card like the Pro one.
    /// Everything is centred, stars first: they fan along the top of a circle,
    /// the middle one highest and the outer ones leaning gently outwards, so
    /// the eye lands on the stars before the words. The whole card is the
    /// button and there is no separate call to action: the title names the
    /// act. It opens the App Store review composer straight away; unlike the
    /// in-app ask, this path has no Apple quota, so it must always be
    /// available to a motivated user. Static on purpose, as the sheet was: a
    /// rating ask converts on sincerity, not spectacle.
    private var rateCard: some View {
        let gold = Color(red: 1.0, green: 0.84, blue: 0.35)
        // Arc geometry: the drop below the middle star and the outward tilt,
        // per step away from the centre (0, 1, 2). Gentle by design.
        let drop: [CGFloat] = [0, 4, 14]
        let tilt: [Double] = [0, 5, 10]
        return Button {
            UIApplication.shared.open(
                URL(string: "itms-apps://apps.apple.com/app/id6769407672?action=write-review")!)
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { index in
                        let step = abs(index - 2)
                        // A star left of centre leans left, one right of
                        // centre leans right: both follow the arc outwards.
                        let direction: Double = index < 2 ? -1 : (index > 2 ? 1 : 0)
                        Image(systemName: "star.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [gold, Color(red: 0.9, green: 0.7, blue: 0.2)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: gold.opacity(0.5), radius: 8)
                            .rotationEffect(.degrees(direction * tilt[step]))
                            .offset(y: drop[step])
                    }
                }
                // The outer stars sit lower by the largest drop; keep that
                // room so they never run into the title.
                .padding(.bottom, drop[2])
                .accessibilityHidden(true)
                Text(NSLocalizedString("review.headline", comment: ""))
                    .font(.headline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Text(NSLocalizedString("review.body", comment: ""))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            // Two settings rows tall at least; the text decides the rest.
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.06, blue: 0.16),
                                 Color(red: 0.04, green: 0.03, blue: 0.10)],
                        startPoint: .top, endPoint: .bottom)
                    RadialGradient(
                        colors: [gold.opacity(0.25), Color.purple.opacity(0.15), .clear],
                        center: UnitPoint(x: 0.5, y: 0.2), startRadius: 5, endRadius: 200)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(NSLocalizedString("settings.rateApp", comment: "")))
    }

    /// Price-forward value line ("9,99 €, pour toujours" — the anti-subscription
    /// hook), falling back to the benefits CTA before the product loads.
    ///
    /// Deliberately still the LIFETIME price, even though the sheet now
    /// highlights the yearly plan. This card is the one surface whose whole
    /// line is "pay once and never again", and putting a subscription price on
    /// it would trade the position for a smaller number. The sheet is where the
    /// three plans are compared; this is a teaser, not a price list.
    private var proCardSubtitle: String {
        if let product = proManager.product {
            return String(format: NSLocalizedString("pro.forever", comment: ""), product.displayPrice)
        }
        return NSLocalizedString("pro.seeAllBenefits", comment: "")
    }

    private var proCardBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.06, blue: 0.18),
                         Color(red: 0.04, green: 0.02, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [Color(red: 1.0, green: 0.84, blue: 0.35).opacity(0.18), .clear],
                center: proGlowShift ? UnitPoint(x: 0.85, y: 0.18) : UnitPoint(x: 0.15, y: 0.10),
                startRadius: 4, endRadius: 180)
            ProParticlesView().opacity(0.5)
        }
    }

    fileprivate var goldTitleGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1.0, green: 0.88, blue: 0.4),
                Color(red: 0.9, green: 0.7, blue: 0.2)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Identifiable wrapper so the sheet can be presented via `.sheet(item:)`.
    /// Using item-based presentation avoids a SwiftUI race where the sheet
    /// content closure captures the old context state on the first show.
    struct ProSheetItem: Identifiable {
        let id = UUID()
        let context: ProPromptContext
    }

    /// Shared premium treatment for every Pro-gated row. Warm gold → purple
    /// gradient layered over the system row color, a matching gold→purple
    /// accent bar on the leading edge, and the same slow purple particle
    /// drift used by the pause overlay's Pro buttons (kept at 0.5 so the dust is
    /// a whisper, matching the top Pro card rather than competing with it).
    fileprivate var premiumRowBackground: some View {
        ZStack(alignment: .leading) {
            // Glass in landscape like every other row; the system row colour
            // upright (audit, 2026-09-05: these were the one opaque grey).
            landscapeRowBackground ?? Color(.secondarySystemGroupedBackground)
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.84, blue: 0.35).opacity(0.10),
                    Color(red: 0.45, green: 0.2, blue: 0.85).opacity(0.08)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            ProParticlesView().opacity(0.5)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.84, blue: 0.35),
                            Color(red: 0.45, green: 0.2, blue: 0.85)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 2)
        }
    }
}
