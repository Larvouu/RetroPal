//
//  HowToSheet.swift
//  EmulateurGBA
//
//  Reusable step-by-step help sheet used by the Settings "Guides" section
//  and the Controls controller row. Numbered-circle steps match the
//  empty-state onboarding style. An optional header slot carries live
//  status (e.g. the controller connection dot).
//

import SwiftUI

struct HowToSheet<Header: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let intro: String?
    let steps: [String]
    let footer: String?
    let header: () -> Header

    init(title: String,
         intro: String?,
         steps: [String],
         footer: String?,
         @ViewBuilder header: @escaping () -> Header) {
        self.title = title
        self.intro = intro
        self.steps = steps
        self.footer = footer
        self.header = header
    }

    var body: some View {
        // Deliberately NOT a NavigationStack. The inline navigation title had
        // to share the bar with a Done button, so longer guide titles
        // truncated with an ellipsis in several languages. Presenting the
        // title inside the scroll gives it the full width and the same weight
        // the What's New sheet uses, and the dismiss moves to the bottom
        // where it reads as "I have read this" rather than "close".
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let intro = intro {
                        Text(intro)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 28)

                header()

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        stepRow(num: index + 1, text: step)
                    }
                }

                if let footer = footer {
                    Text(footer)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Same confirm as the What's New sheet: purple to blue, the
                // app's standard "understood" button.
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
        // Opened fully: these are read-through guides, and a medium detent
        // meant every one of them started half-hidden.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// Numbered like a procedure, coloured like the What's New bullets: the
    /// number carries the accent so the eye can count steps at a glance.
    private func stepRow(num: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(num)")
                .font(.subheadline.weight(.bold))
                .foregroundColor(.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Circle())

            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }
}

/// Convenience initializer for guides that don't need a status header.
extension HowToSheet where Header == EmptyView {
    init(title: String, intro: String?, steps: [String], footer: String?) {
        self.init(title: title, intro: intro, steps: steps, footer: footer) { EmptyView() }
    }
}

/// Live controller-connection indicator: a colored dot plus the controller's
/// name (or a "not connected" label). Used both in the Settings Controls row
/// (compact) and as the header of the controller how-to sheet.
struct ControllerStatusView: View {
    let isConnected: Bool
    let name: String?
    /// Compact form for the Settings row: shows just the controller name
    /// (or "Aucune manette" when none). The full form, used in the how-to
    /// sheet header, spells out "Manette connectée : <name>" / "Aucune
    /// manette connectée".
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var label: String {
        if isConnected {
            let resolved = (name?.isEmpty == false) ? name! : NSLocalizedString("guide.controller.genericName", comment: "")
            return compact ? resolved
                           : String(format: NSLocalizedString("guide.controller.status.connected", comment: ""), resolved)
        } else {
            return NSLocalizedString(compact ? "guide.controller.status.none"
                                             : "guide.controller.status.disconnected", comment: "")
        }
    }
}
