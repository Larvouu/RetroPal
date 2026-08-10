//
//  InfoCallout.swift
//  EmulateurGBA
//
//  A discreet inline note: a glyph plus a short line inside a translucent
//  block. Louder than a section footer (which the eye scans past), quieter
//  than an alert (which taxes every user for something that matters in one
//  moment only). For procedural guidance the reader must find when they go
//  looking for it — the slot-2 "save in-game first, not a quick save" line
//  being the first case: missing it costs a real transfer.
//
//  Same visual language as the empty-library legal note (icon + tinted
//  rounded block, caption text, secondary color); neutral rather than
//  orange, because this is guidance and not a hazard.
//

import SwiftUI

struct InfoCallout: View {
    let text: String
    /// Defaults to the warning glyph; pass another symbol for neutral notes.
    var systemImage: String = "exclamationmark.triangle"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundColor(.secondary)
                // Optical alignment with the first line of text.
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                // Long translations wrap instead of truncating.
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                // .primary keeps this a white veil in the app's dark scheme
                // without assuming the scheme of whatever presents it.
                .fill(Color.primary.opacity(0.07))
        )
        .accessibilityElement(children: .combine)
    }
}
