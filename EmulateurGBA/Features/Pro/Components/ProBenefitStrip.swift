//
//  ProBenefitStrip.swift
//  EmulateurGBA
//
//  A low-emphasis, glanceable grid of Pro benefits (gold icon badge + short
//  label) shown beneath a contextual hero, so the full Pro bundle stays visible
//  — value-stacking to justify the price — without a text wall. Icon-forward,
//  flat (no bezel) so it reads as secondary to the hero card above it.
//
//  Laid out as rows of three (5 benefits → 3 + 2, the second row centred) so
//  every label gets enough width to show fully at ONE harmonised text size —
//  a single 5-up row forced uneven per-label shrinking and truncation.
//

import SwiftUI

struct ProBenefitStrip: View {
    struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
    }

    let items: [Item]
    private let gold = ProPalette.gold
    private let columns = 3

    private var rows: [[Item]] {
        stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0 ..< min($0 + columns, items.count)])
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row) { badge($0) }
                }
            }
        }
    }

    private func badge(_ item: Item) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(gold.opacity(0.12))
                Circle().strokeBorder(gold.opacity(0.35), lineWidth: 1)
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ProPalette.crownGradient)
            }
            .frame(width: 40, height: 40)

            Text(item.label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
