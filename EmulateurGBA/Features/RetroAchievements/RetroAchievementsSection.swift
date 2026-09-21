//
//  RetroAchievementsSection.swift
//  EmulateurGBA
//
//  The RetroAchievements section shown in Settings: the master toggle, plus
//  either a "connect your account" entry or the signed-in account summary.
//  The cross-game profile dashboard link is added in Phase 5.
//

import SwiftUI

struct RetroAchievementsSection: View {
    @ObservedObject private var ra = RetroAchievements.shared
    /// Presenting the login sheet is delegated to the parent (SettingsView), so
    /// it lives at the stable List level and isn't dismissed by this section
    /// re-rendering on an `ra` change while the sheet animates in.
    let onConnect: () -> Void

    var body: some View {
        Section {
            Toggle(isOn: $ra.isEnabled) {
                Label(String(localized: "ra.settings.title", defaultValue: "RetroAchievements"),
                      systemImage: "trophy")
            }

            if ra.isEnabled {
                if ra.isLoggedIn {
                    HStack {
                        Text(ra.displayName ?? ra.username ?? "")
                        Spacer()
                        Text("\(ra.softcoreScore.formatted()) \(String(localized: "ra.pointsSuffix", defaultValue: "pts"))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button(role: .destructive) {
                        ra.logout()
                    } label: {
                        Text(String(localized: "ra.signOut", defaultValue: "Sign out"))
                    }
                } else {
                    Button {
                        onConnect()
                    } label: {
                        Label(String(localized: "ra.connect", defaultValue: "Connect your account"),
                              systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
        } header: {
            RASectionHeader()
        } footer: {
            Text(String(localized: "ra.settings.footer",
                        defaultValue: "Earn achievements in supported games. Free and optional, with your own RetroAchievements account."))
        }
    }
}
