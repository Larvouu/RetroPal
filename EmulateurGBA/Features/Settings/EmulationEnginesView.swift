//
//  EmulationEnginesView.swift
//  EmulateurGBA
//
//  What runs each console, on its own screen.
//
//  Replaces a single About row that read "mGBA / melonDS / MesenCE /
//  PCSX-ReARMed" on one line beside its label. That worked at two cores,
//  truncated at four, and would have got worse with every console added, which
//  is the shape of problem a row cannot be styled out of.
//
//  So it becomes a link, and the space buys something the old row never said:
//  WHICH core runs WHICH console. That mapping exists nowhere else in the app.
//  The licences are here too, but they are not the point: Settings → General →
//  Legal Notice & Licenses remains the complete legal surface, with copyrights
//  and full texts. This screen is the plain-language answer to "what is
//  actually emulating my game", and it is the honest place to say that MesenCE
//  is the one core we patch, which GPL-3.0 asks be stated.
//

import SwiftUI

struct EmulationEnginesView: View {
    private struct Engine: Identifiable {
        let name: String
        let licence: String
        let consoles: [PixelConsole]
        /// Set only where it is true. Stated because the licence asks, and
        /// because "used without modification" was shipped as a falsehood
        /// about this exact core until 2026-08-17.
        let patched: Bool
        var id: String { name }
    }

    // Ordered the way the consoles arrived, which is also the order a
    // long-time user would recognise.
    private let engines: [Engine] = [
        Engine(name: "mGBA", licence: "MPL-2.0",
               consoles: [.gb, .gbc, .gba], patched: false),
        Engine(name: "melonDS", licence: "GPL-3.0",
               consoles: [.nds], patched: false),
        Engine(name: "MesenCE", licence: "GPL-3.0",
               consoles: [.snes, .nes], patched: true),
        Engine(name: "PCSX-ReARMed", licence: "GPL-2.0 or later",
               consoles: [.ps1], patched: false),
    ]

    var body: some View {
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
                    Text(engine.patched
                         ? String(format: NSLocalizedString("settings.engines.footer.patched", comment: ""),
                                  engine.licence)
                         : String(format: NSLocalizedString("settings.engines.footer", comment: ""),
                                  engine.licence))
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.core", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}
