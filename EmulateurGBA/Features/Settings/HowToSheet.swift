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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header()

                    if let intro = intro {
                        Text(intro)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            stepRow(num: index + 1, text: step)
                        }
                    }

                    if let footer = footer {
                        Text(footer)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }

                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "")) { dismiss() }
                }
            }
        }
    }

    private func stepRow(num: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(num)")
                .font(.subheadline.bold())
                .foregroundColor(.primary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.1))
                .clipShape(Circle())

            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 3)
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
                .lineLimit(1)
                .truncationMode(.tail)
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
