//
//  SettingsView.swift
//  EmulateurGBA
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("hapticsEnabled") private var hapticsEnabled: Bool = true
    @AppStorage("buttonLockEnabled") private var buttonLockEnabled: Bool = true
    @AppStorage("useJoystick") private var useJoystick: Bool = false
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
    @AppStorage("debugTranslationEnabled") private var debugTranslationEnabled: Bool = true
    #endif

    /// SF Symbol matching the iCloud state — filled when synced, slash
    /// when unavailable, outline while still resolving.
    private var iCloudIcon: String {
        switch iCloudSync.state {
        case .resolving:   return "icloud"
        case .available:   return "icloud.fill"
        case .unavailable: return "icloud.slash"
        }
    }

    /// Localized one-word status for the iCloud row.
    private var iCloudStateLabel: String {
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
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Button {
                        proSheetItem = ProSheetItem(context: .tappedLockedFeature)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(goldTitleGradient)
                                .shadow(color: Color(red: 0.45, green: 0.2, blue: 0.85).opacity(0.35), radius: 3)

                            Text(NSLocalizedString("pro.title", comment: ""))
                                .fontWeight(.semibold)
                                .foregroundStyle(goldTitleGradient)

                            Spacer()

                            if let product = proManager.product {
                                Text(product.displayPrice)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(premiumRowBackground)
                }

                Button(NSLocalizedString("settings.restore", comment: "")) {
                    Task { await proManager.restore() }
                }
                .font(.subheadline)
            }

            Section(header: Text(NSLocalizedString("settings.controls", comment: "")),
                    footer: Text(NSLocalizedString("settings.controller.footer", comment: ""))) {
                Toggle(NSLocalizedString("settings.haptics", comment: ""), isOn: $hapticsEnabled)

                Toggle(NSLocalizedString("settings.buttonLock", comment: ""), isOn: $buttonLockEnabled)
                    .disabled(controllers.isConnected)
                if controllers.isConnected {
                    Text(NSLocalizedString("settings.buttonLock.controllerNote", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle(isOn: $useJoystick) {
                    Text(useJoystick
                         ? NSLocalizedString("settings.joystick", comment: "")
                         : NSLocalizedString("settings.dpad", comment: ""))
                }

                if proManager.isPro {
                    NavigationLink {
                        ControlPresetsView()
                    } label: {
                        Label(NSLocalizedString("settings.customizeControls", comment: ""),
                              systemImage: "hand.draw")
                    }
                } else {
                    Button {
                        proSheetItem = ProSheetItem(context: .customizeControls)
                    } label: {
                        Label(NSLocalizedString("settings.customizeControls", comment: ""),
                              systemImage: "hand.draw")
                            .foregroundColor(.primary)
                    }
                    .accessibilityLabel("\(NSLocalizedString("settings.customizeControls", comment: "")), \(NSLocalizedString("pro.badge", comment: ""))")
                    .listRowBackground(premiumRowBackground)
                }

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

            Section(NSLocalizedString("settings.sync.section", comment: "")) {
                HStack {
                    Label("iCloud", systemImage: iCloudIcon)
                    Spacer()
                    Text(iCloudStateLabel)
                        .foregroundStyle(.secondary)
                }
            }

            Section(NSLocalizedString("settings.general", comment: "")) {
                NavigationLink(destination: LegalView()) {
                    Label(NSLocalizedString("settings.legal", comment: ""), systemImage: "doc.text")
                }
            }

            Section(NSLocalizedString("settings.about", comment: "")) {
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
            }

            #if DEBUG
            Section("Debug") {
                Button("Preview Review Card") {
                    showReviewPreview = true
                }
                Toggle("Force empty-state onboarding", isOn: $debugForceEmptyState)
                Toggle("Translation overlay", isOn: $debugTranslationEnabled)
                Button(controllers.isConnected
                       ? "Fake controller: ON (tap to disconnect)"
                       : "Fake controller: OFF (tap to connect)") {
                    controllers.debugSetConnected(!controllers.isConnected)
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
            }
            #endif

            Section {
                Text(NSLocalizedString("settings.disclaimer", comment: ""))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

        }
        .navigationTitle(NSLocalizedString("settings.title", comment: ""))
        #if DEBUG
        .sheet(isPresented: $showReviewPreview) {
            ReviewPromptView(onRate: { showReviewPreview = false }, onDismiss: { showReviewPreview = false })
                .presentationDetents([.medium])
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
    /// drift used by the pause overlay's Pro buttons.
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
            ProParticlesView()
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
