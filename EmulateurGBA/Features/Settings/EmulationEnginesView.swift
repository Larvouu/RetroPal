//
//  EmulationEnginesView.swift
//  EmulateurGBA
//
//  What runs each console, on its own screen.
//
//  Replaces a single About row that read "mGBA / melonDS / MesenCE /
//  PCSX-ReARMed" on one line beside its label (five cores since the Nintendo
//  64's Mupen64Plus-Next). That worked at two cores,
//  truncated at four, and would have got worse with every console added, which
//  is the shape of problem a row cannot be styled out of.
//
//  So it becomes a link, and the space buys something the old row never said:
//  WHICH core runs WHICH console. That mapping exists nowhere else in the app.
//  The licences are here too, but they are not the point: Settings → General →
//  Legal Notice & Licenses remains the complete legal surface, with copyrights.
//  This screen is the plain-language answer to "what is actually emulating my
//  game", and it is the honest place to say which cores we patch (MesenCE and
//  Mupen64Plus-Next), which the GPL asks be stated.
//

import SwiftUI

struct EmulationEnginesView: View {
    private struct Engine: Identifiable {
        let name: String
        let licence: String
        let consoles: [PixelConsole]
        /// How many changes we make to it, stated where there are any: because
        /// the licence asks, and because "used without modification" was
        /// shipped as a falsehood about MesenCE until 2026-08-17. One change
        /// and several read differently, so the count picks the sentence.
        let patches: Int
        var id: String { name }
    }

    // Ordered the way the consoles arrived, which is also the order a
    // long-time user would recognise.
    private let engines: [Engine] = [
        Engine(name: "mGBA", licence: "MPL-2.0",
               consoles: [.gb, .gbc, .gba], patches: 0),
        Engine(name: "melonDS", licence: "GPL-3.0",
               consoles: [.nds], patches: 0),
        Engine(name: "MesenCE", licence: "GPL-3.0",
               consoles: [.snes, .nes], patches: 1),
        Engine(name: "PCSX-ReARMed", licence: "GPL-2.0 or later",
               consoles: [.ps1], patches: 0),
        // Five patches (`Vendor/n64-ios/patches`), and its picture drawn by
        // ParaLLEl-RDP through MoltenVK, which the Legal page names.
        Engine(name: "Mupen64Plus-Next", licence: "GPL-2.0 or later",
               consoles: [.n64], patches: 5),
    ]

    var body: some View {
        LandscapeListSwitch(title: NSLocalizedString("settings.core", comment: "")) {
            List {
                ForEach(engines) { engine in
                    Section {
                        ForEach(engine.consoles, id: \.self) { console in
                            HStack(spacing: 12) {
                                PixelConsoleIcon(console: console)
                                    .frame(width: 36, height: 36)
                                Text(console.label)
                                Spacer()
                            }
                        }
                    } header: {
                        // Core names are project names and stay unlocalized, the
                        // same rule the old row followed.
                        Text(engine.name)
                    } footer: {
                        Text(String(format: NSLocalizedString(
                            engine.patches > 1 ? "settings.engines.footer.patches"
                                : engine.patches == 1 ? "settings.engines.footer.patched"
                                : "settings.engines.footer", comment: ""),
                                    engine.licence))
                    }
                    .landscapeGlassRow()
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.core", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}
