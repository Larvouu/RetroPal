//
//  LegalView.swift
//  EmulateurGBA
//
//  Native inset-grouped List layout — matches Settings / GameDetails.
//  Each topic gets its own rounded card with a symbol-prefixed header.
//

import SwiftUI

struct LegalView: View {
    var body: some View {
        List {
            Section {
                Text(NSLocalizedString("legal.disclaimer", comment: ""))
                    .font(.body)
                    .listRowBackground(Color.yellow.opacity(0.12))
            } header: {
                sectionHeader("legal.importantNotice.title", systemImage: "exclamationmark.triangle")
            }

            Section {
                Text(NSLocalizedString("legal.aboutApp.description1", comment: ""))
                    .font(.body)
                Text(NSLocalizedString("legal.aboutApp.description2", comment: ""))
                    .font(.body)
            } header: {
                sectionHeader("legal.aboutApp.title", systemImage: "info.circle")
            }

            Section {
                Text(NSLocalizedString("legal.privacy.description", comment: ""))
                    .font(.body)
            } header: {
                sectionHeader("legal.privacy.title", systemImage: "lock.shield")
            }

            Section {
                licenseRow(
                    titleKey: "legal.retropal",
                    copyright: "Copyright (c) 2026 Retro Pal",
                    licenseKey: "legal.retropal.licenseLine",
                    descriptionKey: "legal.retropal.description"
                )
                licenseRow(
                    titleKey: "legal.mgba",
                    copyright: "Copyright (c) 2013-2024 Jeffrey Pfau",
                    licenseKey: "legal.mgba.licenseLine",
                    descriptionKey: "legal.mgba.description"
                )
                licenseRow(
                    titleKey: "legal.melonds",
                    copyright: "Copyright (c) 2016-2025 melonDS team",
                    licenseKey: "legal.melonds.licenseLine",
                    descriptionKey: "legal.melonds.description"
                )
                licenseRow(
                    titleKey: "legal.mesen",
                    // Verbatim from the project's own README, not paraphrased:
                    // an attribution is the one line that must be theirs.
                    copyright: "Copyright (C) 2014-2026 Sour, 2026 contributors",
                    licenseKey: "legal.mesen.licenseLine",
                    descriptionKey: "legal.mesen.description"
                )
                Text(NSLocalizedString("legal.compliance", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                sectionHeader("legal.licenses.title", systemImage: "doc.text")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(NSLocalizedString("legal.title", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helpers

    private func sectionHeader(_ titleKey: String, systemImage: String) -> some View {
        Label {
            Text(NSLocalizedString(titleKey, comment: ""))
        } icon: {
            Image(systemName: systemImage)
                .foregroundColor(.accentColor)
        }
        .textCase(nil)
    }

    private func licenseRow(
        titleKey: String,
        copyright: String,
        licenseKey: String,
        descriptionKey: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString(titleKey, comment: ""))
                .font(.subheadline)
                .fontWeight(.semibold)
            // Copyright notices stay in English by legal convention.
            Text(copyright)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(NSLocalizedString(licenseKey, comment: ""))
                .font(.caption)
                .foregroundColor(.secondary)
            Text(attributedMarkdown(descriptionKey))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Parse a localized string as inline Markdown so embedded link syntax
    /// (e.g. `[text](url)`) becomes a tappable link. `Text(String)` skips
    /// markdown parsing entirely, which is why bare URLs stopped working
    /// once we moved to NSLocalizedString.
    private func attributedMarkdown(_ key: String) -> AttributedString {
        let raw = NSLocalizedString(key, comment: "")
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: raw, options: options))
            ?? AttributedString(raw)
    }
}
