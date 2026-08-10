//
//  WhatsNewSheet.swift
//  EmulateurGBA
//
//  Once-per-update release-notes sheet. Presents on the Library at the
//  first launch after an update (never on a fresh install, never over the
//  onboarding empty state), and stays reachable anytime from Settings →
//  About → "What's New". Content lives in Localizable.strings under the
//  stable whatsnew.s* keys, rewritten in place each release together with
//  the ASC What's New (standing obligation, see TODOS.md).
//

import SwiftUI

/// One release's notes: sections of title + bullets, resolved from
/// Localizable.strings like any other UI copy.
struct WhatsNewContent {
    struct ContentSection {
        let titleKey: String
        let bulletKeys: [String]
    }

    /// The version these notes describe. The once-per-update gate compares
    /// the stored "last seen" value against THIS, not against the bundle
    /// version — so shipping a release without updating the notes fails
    /// silent (no sheet) instead of re-showing stale notes.
    let version: String
    let sections: [ContentSection]

    /// The CURRENT release's notes (the open 1.2.4 train).
    ///
    /// Ordered by what a player actually gains, not by what was hard to build:
    /// the television first because it changes where you play, then how the
    /// games look, then the friction we removed, then the smaller things.
    static let current = WhatsNewContent(
        version: "1.2.4",
        sections: [
            ContentSection(titleKey: "whatsnew.s1.title",
                           bulletKeys: ["whatsnew.s1.b1", "whatsnew.s1.b2"]),
            ContentSection(titleKey: "whatsnew.s2.title",
                           bulletKeys: ["whatsnew.s2.b1", "whatsnew.s2.b2"]),
            ContentSection(titleKey: "whatsnew.s3.title",
                           bulletKeys: ["whatsnew.s3.b1", "whatsnew.s3.b2"]),
            ContentSection(titleKey: "whatsnew.s4.title",
                           bulletKeys: ["whatsnew.s4.b1", "whatsnew.s4.b2"]),
            ContentSection(titleKey: "whatsnew.s5.title",
                           bulletKeys: ["whatsnew.s5.b1", "whatsnew.s5.b2"]),
            ContentSection(titleKey: "whatsnew.s6.title",
                           bulletKeys: ["whatsnew.s6.b1", "whatsnew.s6.b2"]),
        ]
    )
}

/// Once-per-update gate for the launch presentation.
enum WhatsNew {
    private static let seenVersionKey = "whatsNewLastSeenVersion"

    /// True when the launch sheet should present: the current release's
    /// notes haven't been seen yet, and this isn't a fresh install. Fresh
    /// installs (nothing stored + empty library) stamp silently instead:
    /// nothing is "new" relative to install, and the user is mid-onboarding.
    static func shouldPresentAtLaunch(libraryIsEmpty: Bool) -> Bool {
        let seen = UserDefaults.standard.string(forKey: seenVersionKey)
        guard seen != WhatsNewContent.current.version else { return false }
        if seen == nil && libraryIsEmpty {
            markSeen()
            return false
        }
        return true
    }

    /// Stamped at presentation, not dismissal: a force-kill with the sheet
    /// up must not re-show it forever, and the Settings row keeps the notes
    /// reachable anytime.
    static func markSeen() {
        UserDefaults.standard.set(WhatsNewContent.current.version, forKey: seenVersionKey)
    }

    #if DEBUG
    /// Settings → Debug: re-arm the launch presentation for testing.
    static func debugResetSeen() {
        UserDefaults.standard.removeObject(forKey: seenVersionKey)
    }
    #endif
}

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let content = WhatsNewContent.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("whatsnew.title", comment: ""))
                        .font(.title2.weight(.bold))
                    Text(String(format: NSLocalizedString("whatsnew.version", comment: ""), content.version))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 28)

                ForEach(content.sections.indices, id: \.self) { index in
                    sectionView(content.sections[index])
                }

                Text(NSLocalizedString("whatsnew.footer", comment: ""))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Same treatment as the skin picker's OK button (purple→blue
                // gradient, radius 12) so the dismiss reads as the app's
                // standard confirm.
                Button {
                    dismiss()
                } label: {
                    Text(NSLocalizedString("whatsnew.dismiss", comment: ""))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(LinearGradient(colors: [.purple, .blue],
                                                   startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sectionView(_ section: WhatsNewContent.ContentSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(section.titleKey, comment: ""))
                .font(.headline)
            ForEach(section.bulletKeys, id: \.self) { key in
                HStack(alignment: .top, spacing: 10) {
                    Text("•")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.accentColor)
                    Text(NSLocalizedString(key, comment: ""))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
