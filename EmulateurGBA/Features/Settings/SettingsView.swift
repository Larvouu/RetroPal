//
//  SettingsView.swift
//  EmulateurGBA
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage("hapticsEnabled") private var hapticsEnabled: Bool = true
    @AppStorage("useJoystick") private var useJoystick: Bool = false
    @AppStorage("showClipButton") private var showClipButton: Bool = true
    @AppStorage("ndsSwapScreens") private var ndsSwapScreens: Bool = false
    @AppStorage("ndsLanguage") private var ndsLanguage: String = "auto"
    @AppStorage("ndsClockManual") private var ndsClockManual: Bool = false
    /// Manual RTC date/time as seconds since 1970, read by MelonDSBridge.
    /// 0 means "never set" — the bridge then falls back to the device clock.
    @AppStorage("ndsManualClockEpoch") private var ndsManualClockEpoch: Double = 0
    @ObservedObject private var proManager = ProManager.shared
    @ObservedObject private var controllers = ControllerManager.shared
    @ObservedObject private var iCloudSync = iCloudSaveSync.shared
    @State private var proSheetItem: ProSheetItem?
    /// Drives the slow gold-glow drift on the Pro card (gradient motion only,
    /// no position change). Disabled under Reduce Motion.
    @State private var proGlowShift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showRALogin = false
    @State private var showWhatsNew = false
    @State private var showRomGuide = false
    @State private var showSaveGuide = false
    @State private var showControllerGuide = false
    #if DEBUG
    @State private var showReviewPreview = false
    #endif
    #if DEBUG
    @State private var debugTapCount = 0
    #endif
    #if DEBUG
    @AppStorage("debugForceEmptyState") private var debugForceEmptyState: Bool = false
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

    /// NDS firmware languages by index (0-6), shown as autonyms — the iOS
    /// language-picker convention, locale-independent (a language reads best
    /// in its own name). Order matches the firmware language enum the bridge
    /// uses, so the index doubles as the stored tag value.
    private static let ndsLanguageAutonyms = ["日本語", "English", "Français", "Deutsch", "Italiano", "Español", "中文"]

    /// Label for the picker's "auto" option, naming the language it will
    /// actually use on this device. The DS firmware only speaks these seven
    /// languages, so a device set to e.g. Slovenian truthfully resolves to
    /// "Auto (English)" (the firmware fallback), not a Slovenian the hardware
    /// can't produce. Pulled from the bridge so the label and the real
    /// behaviour can't drift apart.
    private var ndsAutoLanguageLabel: String {
        let index = Int(MelonDSBridge.autoResolvedNDSLanguageIndex())
        let name = Self.ndsLanguageAutonyms.indices.contains(index) ? Self.ndsLanguageAutonyms[index] : "English"
        return String(format: NSLocalizedString("settings.nds.language.auto", comment: ""), name)
    }

    /// A Controls-section row label that, when a controller is connected, shows
    /// a small controller glyph at the trailing edge (right next to the disabled
    /// switch), signalling the row is disabled because the setting applies only
    /// to the on-screen touch controls. The Spacer pushes the glyph to sit
    /// beside the switch rather than next to the text.
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

    /// Two-way bridge between the stored epoch (Double) and the DatePicker's
    /// Date. Shows "now" until the user picks a value, so the picker never
    /// opens on 1970.
    private var ndsManualDate: Binding<Date> {
        Binding(
            get: { ndsManualClockEpoch > 0 ? Date(timeIntervalSince1970: ndsManualClockEpoch) : Date() },
            set: { ndsManualClockEpoch = $0.timeIntervalSince1970 }
        )
    }

    var body: some View {
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

            Section(header: Text(NSLocalizedString("settings.controls", comment: "")),
                    footer: Text(controllers.isConnected
                                 ? NSLocalizedString("settings.controls.controllerActive.footer", comment: "")
                                 : NSLocalizedString("settings.controls.dpad.footer", comment: ""))) {
                Toggle(isOn: $hapticsEnabled) {
                    controlsRowLabel(NSLocalizedString("settings.haptics", comment: ""))
                }
                .disabled(controllers.isConnected)

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
                    // Locked: a refined Pro invitation. Gold accents (the
                    // hand.draw icon, the title, a trailing crown) read as premium
                    // and tempting; the crown — not a lock — keeps it inviting
                    // rather than barring. Opens the Pro sheet, like the top card.
                    Button {
                        proSheetItem = ProSheetItem(context: .customizeControls)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.draw")
                                .font(.body)
                                .foregroundStyle(goldTitleGradient)
                            Text(NSLocalizedString("settings.customizeControls", comment: ""))
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
                    .accessibilityLabel("\(NSLocalizedString("settings.customizeControls", comment: "")), \(NSLocalizedString("pro.badge", comment: ""))")
                    .listRowBackground(premiumRowBackground)
                }
            }

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
            }

            Section(header: Text("Nintendo DS"),
                    footer: Text(NSLocalizedString("settings.nds.language.footer", comment: ""))) {
                Toggle(NSLocalizedString("settings.nds.swapScreens", comment: ""), isOn: $ndsSwapScreens)

                Toggle(NSLocalizedString("settings.nds.clock.manual", comment: ""), isOn: $ndsClockManual)
                if ndsClockManual {
                    DatePicker(NSLocalizedString("settings.nds.clock.pickerLabel", comment: ""),
                               selection: ndsManualDate)
                }

                // Language last, so the section footer (which describes game
                // language behaviour) sits directly under it.
                Picker(NSLocalizedString("settings.nds.language", comment: ""), selection: $ndsLanguage) {
                    Text(ndsAutoLanguageLabel).tag("auto")
                    ForEach(Array(Self.ndsLanguageAutonyms.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(String(index))
                    }
                }
            }

            RetroAchievementsSection(onConnect: { showRALogin = true })

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
            }

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
                Text(NSLocalizedString("settings.sync.footer", comment: ""))
            }

            Section(NSLocalizedString("settings.general", comment: "")) {
                NavigationLink(destination: LegalView()) {
                    Label(NSLocalizedString("settings.legal", comment: ""), systemImage: "doc.text")
                }
            }

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
                HStack {
                    Text(NSLocalizedString("settings.core", comment: ""))
                    Spacer()
                    Text("mGBA / melonDS")
                        .foregroundStyle(.secondary)
                }
                // Straight to the App Store review composer. Unlike the
                // in-app ask, this path has no Apple quota: it must always
                // be available to a motivated user.
                Button {
                    UIApplication.shared.open(
                        URL(string: "itms-apps://apps.apple.com/app/id6769407672?action=write-review")!)
                } label: {
                    Label(NSLocalizedString("settings.rateApp", comment: ""), systemImage: "star")
                }
            }

            #if DEBUG
            Section("Debug") {
                Button("Preview Review Card") {
                    showReviewPreview = true
                }
                Button("What's New: reset seen version (re-arms the launch sheet)") {
                    WhatsNew.debugResetSeen()
                }
                Toggle("Force empty-state onboarding", isOn: $debugForceEmptyState)
                Button(controllers.isConnected
                       ? "Fake controller: ON (tap to disconnect)"
                       : "Fake controller: OFF (tap to connect)") {
                    controllers.debugSetConnected(!controllers.isConnected)
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
                Button("Clip card hint preview") { showClipHintPreview = true }
                Button("Screenshot card hint preview") { showShotHintPreview = true }
                Button("Simulate RA unlock (preview HUD)") {
                    RetroAchievements.shared.debugSimulateUnlock()
                }
                Button("Simulate RA progress (preview pill)") {
                    RetroAchievements.shared.debugSimulateProgress()
                }
                Button("RA game card (157 badges, Fire-Red-sized)") {
                    showRAGameCardPreview = true
                }
                Button("RA overview card (30 games, 4 completed)") {
                    showRAOverviewCardPreview = true
                }
            }

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
            }
            #endif

            Section {
                Text(NSLocalizedString("settings.disclaimer", comment: ""))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

        }
        .navigationTitle(NSLocalizedString("settings.title", comment: ""))
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
        .sheet(isPresented: $showReviewPreview) {
            ReviewPromptView(onRate: { showReviewPreview = false }, onDismiss: { showReviewPreview = false })
                .presentationDetents([.medium])
        }
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
                    NSLocalizedString("guide.importRom.step1", comment: ""),
                    NSLocalizedString("guide.importRom.step2", comment: ""),
                    NSLocalizedString("guide.importRom.step3", comment: ""),
                    NSLocalizedString("guide.importRom.step4", comment: "")
                ],
                footer: NSLocalizedString("guide.importRom.footer", comment: "")
            )
            .presentationDetents([.medium, .large])
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
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showControllerGuide) {
            HowToSheet(
                title: NSLocalizedString("guide.controller.title", comment: ""),
                intro: nil,
                steps: [
                    NSLocalizedString("guide.controller.step1", comment: ""),
                    NSLocalizedString("guide.controller.step2", comment: ""),
                    NSLocalizedString("guide.controller.step3", comment: "")
                ],
                footer: NSLocalizedString("guide.controller.footer", comment: "")
            ) {
                ControllerStatusView(isConnected: controllers.isConnected,
                                     name: controllers.controllerName)
            }
            .presentationDetents([.medium, .large])
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

    /// Price-forward value line ("4,99 €, pour toujours" — the anti-subscription
    /// hook), falling back to the benefits CTA before the product loads.
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
            Color(.secondarySystemGroupedBackground)
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
