//
//  WhatsNewSheet.swift
//  EmulateurGBA
//
//  Once-per-update release-notes sheet. Presents on the Library at the
//  first launch after an update (never on a fresh install, never over the
//  onboarding empty state), and stays reachable anytime from Settings →
//  About → "What's New". Content lives in Localizable.strings under the
//  stable whatsnew.s* keys, rewritten in place each release together with
//  the App Store release notes, rewritten in place every release.
//

import SwiftUI

/// One release's notes: sections of title + bullets, resolved from
/// Localizable.strings like any other UI copy.
struct WhatsNewContent {
    struct ContentSection {
        let titleKey: String
        let bulletKeys: [String]
        /// Asset names drawn side by side under this section's bullets, in the
        /// order the bullet names them. Empty for every section but one.
        ///
        /// These are the drawings the Appearance button already wears, so the
        /// console in the notes, the console in the picker and the console you
        /// hold are all the same machine.
        let artNames: [String]

        init(titleKey: String, bulletKeys: [String], artNames: [String] = []) {
            self.titleKey = titleKey
            self.bulletKeys = bulletKeys
            self.artNames = artNames
        }
    }

    /// The version these notes describe. The once-per-update gate compares
    /// the stored "last seen" value against THIS, not against the bundle
    /// version — so shipping a release without updating the notes fails
    /// silent (no sheet) instead of re-showing stale notes.
    let version: String
    /// A notice that sits ABOVE the sections, when a release has one.
    ///
    /// Not a section, and deliberately not dressed as one: a section says what
    /// the player just gained, and this says something about what the app is
    /// going to charge. Giving it its own slot means it can carry its own
    /// treatment, and can leave next release without renumbering six sections.
    ///
    /// Declared BEFORE `sections` on purpose: the memberwise initialiser takes
    /// its arguments in declaration order, so this is also the order the call
    /// site reads in, which is the order the sheet draws in.
    let noticeKey: String?
    let sections: [ContentSection]

    /// The CURRENT release's notes, and they are OPEN.
    ///
    /// The 1.3.0 train carries more than the PlayStation, and only the
    /// PlayStation is built. These three sections are true today and nothing
    /// here describes anything that is not; the rest of the train appends s4
    /// onward as it lands. **This release must not submit while these notes
    /// describe less than it ships** — the once-per-update gate compares
    /// against `version`, so stale notes fail silent rather than loudly.
    ///
    /// The 1.2.5 sections were removed rather than left in place. A leftover
    /// section is copy about a release the player already has, sitting in a
    /// sheet that only opens to say what is new, and it would ship the moment
    /// someone forgot to look.
    ///
    /// Ordered by what a player actually gains: the console first because it IS
    /// the release, then getting a game into it (a disc is the first thing this
    /// console does differently from every other one here), then the pad.
    ///
    /// ⚠ THE PRO NOTICE IS GONE, and its absence is a decision (decided on device,
    /// 2026-08-27). It announced a coming lifetime price rise, and by the time
    /// this sheet shows, that rise will have happened. The people who needed
    /// warning were warned in 1.2.5, which is what the notice was for. Telling
    /// somebody arriving today that it used to be cheaper is not a courtesy to
    /// them, it is an apology to nobody. Do not reinstate it, and do not
    /// replace it with a "prices have changed" line.
    static let current = WhatsNewContent(
        version: "1.3.0",
        noticeKey: nil,
        sections: [
            // The machine, carrying its art, for the same reason the two
            // machines did in 1.2.5: this is the section whose news is a THING
            // rather than a behaviour.
            // s1.b4 added 2026-08-30: the console's LOOK had no bullet at all,
            // and the dress plus the repaintable pad were a large part of this
            // build. 1.2.5 gave its two new consoles a whole section for the
            // same thing. It sits here rather than in s5 because it is about
            // THIS machine, while s5's moulded joystick is a change every
            // console gets.
            ContentSection(titleKey: "whatsnew.s1.title",
                           bulletKeys: ["whatsnew.s1.b1", "whatsnew.s1.b2",
                                        "whatsnew.s1.b3", "whatsnew.s1.b4"],
                           artNames: ["console-ps1"]),
            ContentSection(titleKey: "whatsnew.s2.title",
                           bulletKeys: ["whatsnew.s2.b1", "whatsnew.s2.b2",
                                        "whatsnew.s2.b3"]),
            ContentSection(titleKey: "whatsnew.s3.title",
                           bulletKeys: ["whatsnew.s3.b1", "whatsnew.s3.b2"]),
            // The things this train added that are not the PlayStation, in TWO
            // sections rather than one: cheats and controls were sharing a
            // heading and they are not the same subject, so a player scanning
            // for one was reading past the other.
            ContentSection(titleKey: "whatsnew.s4.title",
                           bulletKeys: ["whatsnew.s4.b1"]),
            ContentSection(titleKey: "whatsnew.s5.title",
                           bulletKeys: ["whatsnew.s5.b1", "whatsnew.s5.b2"]),
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
    @Environment(\.displayScale) private var displayScale
    /// The bullet type size, scaled by the reader's Dynamic Type setting. Drives
    /// the inline tag's own size, and its presence is also what makes the tag
    /// re-render when that setting changes.
    @ScaledMetric(relativeTo: .subheadline) private var tagPointSize: CGFloat = 15
    private let content = WhatsNewContent.current

    /// What the localized bullets carry where the Pro tag belongs.
    ///
    /// A token rather than a trailing word, because the tag is not a word: it can
    /// sit at the end of a sentence (the skin and controller-layout bullets) or in
    /// the middle of one (the rewind bullet says "thirty with X, on all six
    /// consoles"), and only the string knows which.
    ///
    /// ⚠ **EVERY MENTION OF RETRO PAL PRO IN THIS SHEET GOES THROUGH THIS
    /// TOKEN. Never write the product's name into a bullet as words** (decided on device,
    /// 2026-08-28). Two reasons, and the second is why it is a rule rather than
    /// a preference. The tag is how a player TELLS a Pro line from a free one at
    /// a glance, so a bullet that says the name in prose reads as an ordinary
    /// sentence and the gate disappears. And the adjustable-rewind bullet had
    /// already made the subtler mistake this prevents: written as "up to your 30
    /// with Pro" it sounded like everyone gets the feature and Pro merely gets
    /// longer, when the choice itself is the Pro part and a free player has no
    /// row at all. The standing rule is also written into the release checklist, beside the
    /// per-release obligation to rewrite these strings.
    private static let proToken = "{PRO}"
    /// The product's full name, deliberately not localized: it is a proper noun,
    /// and it is the same three words on every store in the world.
    static let proTagName = "Retro Pal Pro"

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

                if let noticeKey = content.noticeKey {
                    noticeView(noticeKey)
                }

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

    /// The notice: quiet, not a banner. It is information the reader is owed,
    /// not an announcement competing with the release, so it takes a soft filled
    /// card and secondary text rather than a tint or a badge. Deliberately no
    /// price and no button: this sheet is release notes, and the Pro sheet is
    /// where an offer belongs.
    ///
    /// No icon either, since 2026-08-19. An info glyph in front of a sentence
    /// that is already quiet and already in a card was the one part of this
    /// treatment that pointed AT itself, which is the opposite of what the
    /// restraint above is for.
    private func noticeView(_ key: String) -> some View {
        Text(NSLocalizedString(key, comment: ""))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func sectionView(_ section: WhatsNewContent.ContentSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(section.titleKey, comment: ""))
                .font(.headline)
            ForEach(section.bulletKeys, id: \.self) { key in
                let raw = NSLocalizedString(key, comment: "")
                HStack(alignment: .top, spacing: 10) {
                    Text("•")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.accentColor)
                    bulletText(raw)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        // The tag is an image, so VoiceOver would skip it and read
                        // a sentence with a hole where the product name was.
                        .accessibilityLabel(Self.plainText(raw))
                }
            }
            if !section.artNames.isEmpty {
                artRow(section.artNames)
            }
        }
    }

    /// One bullet, with the Pro tag dropped in wherever the string carries the
    /// token.
    ///
    /// The tag arrives as an IMAGE inside the `Text` run, and that is the point:
    /// a padded, rounded tag can only take part in the paragraph's own line
    /// breaking if it is part of the run. A sibling view in a stack could sit
    /// before the whole block or after it, never inside the sentence, and the
    /// rewind bullet needs it inside.
    ///
    /// Falls back to the words alone if the render fails, so the sentence is
    /// never left with a hole in it.
    private func bulletText(_ raw: String) -> Text {
        let parts = raw.components(separatedBy: Self.proToken)
        guard parts.count > 1, let tag = proTagImage else {
            return Text(Self.plainText(raw))
        }
        var result = Text(parts[0])
        for part in parts.dropFirst() {
            // If the tag ever reads as sitting too high on the line, the knob is
            // `.baselineOffset(_:)` on THIS Text and nothing else: an image
            // interpolated into a run hangs its bottom edge on the baseline, so a
            // capsule taller than the cap height rides above it by design. Left at
            // the natural default rather than nudged by a number nobody measured.
            result = result + Text("\(tag)") + Text(part)
        }
        return result
    }

    /// The bullet as words only: the VoiceOver reading, and the fallback.
    private static func plainText(_ raw: String) -> String {
        raw.replacingOccurrences(of: proToken, with: proTagName)
    }

    /// The tag, rendered at the bullet's own type size so it grows with the
    /// reader's Dynamic Type setting instead of staying a fixed sticker.
    ///
    /// Every colour in it is a literal rather than a semantic one, deliberately:
    /// `ImageRenderer` draws into a fresh environment that does not inherit the
    /// sheet's colour scheme, so a semantic colour here would render its light
    /// appearance and then sit on a dark sheet.
    private var proTagImage: Image? {
        let renderer = ImageRenderer(content: ProInlineTag(pointSize: tagPointSize))
        renderer.scale = displayScale
        guard let rendered = renderer.uiImage else { return nil }
        return Image(uiImage: rendered).renderingMode(.original)
    }

    /// The section's machines, sharing the width evenly and aligned on their
    /// BOTTOM edge, because the two drawings are different heights and hanging
    /// them from the top would leave one floating.
    ///
    /// Hidden from VoiceOver on purpose: the bullet above already names both
    /// consoles, so announcing them again is repetition, not information.
    private func artRow(_ names: [String]) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            ForEach(names, id: \.self) { name in
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
            }
        }
        .padding(.top, 6)
        .accessibilityHidden(true)
    }
}

/// The inline "Retro Pal Pro" tag: the crown the app uses for Pro everywhere,
/// and the product's full name, inside one capsule.
///
/// It replaces a bare trailing "Pro." that assumed the reader already knew what
/// Pro was. The crown and the words carry the same recipe as the Settings
/// premium rows (gold wash, gold border, gold gradient on the content), so the
/// tag reads as the same product mark rather than a new one invented for this
/// sheet.
///
/// Sized entirely in multiples of the surrounding text's point size, because it
/// is rendered to an image at whatever size that text currently is.
private struct ProInlineTag: View {
    let pointSize: CGFloat

    var body: some View {
        HStack(spacing: pointSize * 0.22) {
            Image(systemName: "crown.fill")
                .font(.system(size: pointSize * 0.70, weight: .semibold))
            Text(WhatsNewSheet.proTagName)
                .font(.system(size: pointSize * 0.82, weight: .semibold))
        }
        .foregroundStyle(ProPalette.crownGradient)
        .padding(.horizontal, pointSize * 0.40)
        .padding(.vertical, pointSize * 0.18)
        .background(Capsule().fill(ProPalette.gold.opacity(0.14)))
        .overlay(Capsule().strokeBorder(ProPalette.gold.opacity(0.45), lineWidth: 1))
    }
}
