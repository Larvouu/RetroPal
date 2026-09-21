//
//  RALoginView.swift
//  EmulateurGBA
//
//  The RetroAchievements sign-in sheet. The password is sent once to RA to mint
//  a token (RAClient persists only the token, in the Keychain). Free feature.
//

import SwiftUI

struct RALoginView: View {
    @ObservedObject private var ra = RetroAchievements.shared
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?
    /// The explainer, reachable before an account exists (2026-09-08): the
    /// classic library card carries an (i) beside its invite, but the
    /// landscape surface and the upright look go straight to this sheet,
    /// which offered no way to it.
    @State private var showAbout = false

    var body: some View {
        NavigationStack {
            LandscapeListSwitch(title: "RetroAchievements", leading: .cancel) {
                Form {
                    Section {
                        TextField(String(localized: "ra.login.username", defaultValue: "Username"), text: $username)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField(String(localized: "ra.login.password", defaultValue: "Password"), text: $password)
                            .textContentType(.password)
                    } footer: {
                        Text(String(localized: "ra.login.footer",
                                    defaultValue: "Sign in with your RetroAchievements account. Your password is sent once to RetroAchievements to sign in and is never stored on this device."))
                    }
                    .landscapeGlassRow()

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        .landscapeGlassRow()
                    }

                    if !ra.isOnline {
                        Section {
                            Label(String(localized: "ra.offline", defaultValue: "No internet connection."),
                                  systemImage: "wifi.slash")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .landscapeGlassRow()
                    }

                    Section {
                        Button {
                            signIn()
                        } label: {
                            HStack {
                                if isLoggingIn { ProgressView().padding(.trailing, 4) }
                                Text(String(localized: "ra.login.signIn", defaultValue: "Sign In"))
                            }
                        }
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty
                                  || password.isEmpty || isLoggingIn || !ra.isOnline)
                    }
                    .landscapeGlassRow()

                    Section {
                        Link(destination: URL(string: "https://retroachievements.org/createaccount.php")!) {
                            Text(String(localized: "ra.login.createAccount",
                                        defaultValue: "Create a RetroAchievements account"))
                                .font(.footnote)
                        }
                        Button {
                            showAbout = true
                        } label: {
                            Label(String(localized: "ra.about.title", defaultValue: "About RetroAchievements"),
                                  systemImage: "info.circle")
                                .font(.footnote)
                        }
                    }
                    .landscapeGlassRow()
                }
            }
            .navigationTitle("RetroAchievements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
            }
            .sheet(isPresented: $showAbout) { RAAboutSheet() }
        }
    }

    private func signIn() {
        isLoggingIn = true
        errorMessage = nil
        ra.login(username: username.trimmingCharacters(in: .whitespaces), password: password) { success, error in
            isLoggingIn = false
            if success {
                dismiss()
            } else {
                errorMessage = error ?? String(localized: "ra.error.login",
                                               defaultValue: "Login failed. Check your username and password.")
            }
        }
    }
}
