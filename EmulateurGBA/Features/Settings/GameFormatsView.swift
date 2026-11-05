//
//  GameFormatsView.swift
//  EmulateurGBA
//
//  Which files make a game, console by console (1.3.5, asked 2026-10-31).
//
//  The welcome's first step and the "Add a game" guide used to list every
//  extension inline: fifteen in 1.0, twenty-three by the 3DS, plus the disc
//  combinations, which made the one sentence a new player must read the
//  hardest one to read. The steps now say only how to bring a game onto the
//  device, and a link under them opens this page.
//
//  Built like the Emulation Engines page (`EmulationEnginesView`): one
//  section per console with its drawing, on the same scaffold. The archives
//  come first because they are the format most downloads arrive in, and
//  because they apply to every console below them.
//
//  The extensions are not localized and are not written in the strings
//  files: they are read from the importer's own tables where one exists, so
//  this page cannot offer a format the importer refuses
//  (`GameFormatsCoverageTests`).
//

import SwiftUI

struct GameFormatsView: View {
    /// One console's row: what it accepts, and a caption only where a set of
    /// files (not one file) is the game, or the format has a condition.
    struct Entry: Identifiable {
        let console: PixelConsole
        /// The single-file formats, each one game.
        let extensions: [String]
        /// The localized caption key, or nil when the formats say it all.
        var noteKey: String? = nil
        var id: String { console.label }
    }

    /// In the welcome strip's order (`ConsoleIconRow.all`), so the page reads
    /// the way the player has just seen the consoles. Internal and static so
    /// the coverage test can hold it to the importer.
    static let entries: [Entry] = [
        Entry(console: .gb, extensions: ["gb"]),
        Entry(console: .gbc, extensions: ["gbc"]),
        Entry(console: .gba, extensions: ["gba"]),
        Entry(console: .nds, extensions: ["nds"]),
        Entry(console: .nes, extensions: ["nes"]),
        Entry(console: .snes, extensions: ["sfc", "smc"]),
        // A disc: one file, or a descriptor with the files it names, or a
        // playlist for a game on several discs.
        Entry(console: .ps1, extensions: ["chd", "pbp", "iso", "bin", "img", "mdf", "cbn"], noteKey: "formats.note.ps1"),
        Entry(console: .n64, extensions: ["z64", "n64", "v64"]),
        Entry(console: .md, extensions: ["md", "gen", "smd", "bin"]),
        Entry(console: .sms, extensions: ["sms"]),
        Entry(console: .gg, extensions: ["gg"]),
        Entry(console: .psp, extensions: ["iso", "cso", "chd", "pbp"]),
        // Decrypted only: the importer refuses an encrypted one by name.
        Entry(console: .n3ds, extensions: ["3ds", "cci", "cxi", "3dsx"], noteKey: "formats.note.n3ds"),
    ]

    /// The archive extensions as a player writes them: `.tar.gz` and `.tar.xz`
    /// are what they see, and `.tgz` / `.txz` are their short names.
    static let archiveNames: [String] = [".zip", ".7z", ".rar", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".gz", ".xz"]

    var body: some View {
        LandscapeListSwitch(title: NSLocalizedString("formats.title", comment: ""), leading: .cancel) {
            List {
                Section {
                    Text(NSLocalizedString("formats.intro", comment: ""))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .landscapeGlassRow()

                Section {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "archivebox")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                            .frame(width: 36, height: 36)
                        FormatList(names: Self.archiveNames)
                    }
                } header: {
                    Text(NSLocalizedString("formats.archives.header", comment: ""))
                } footer: {
                    Text(NSLocalizedString("formats.archives.footer", comment: ""))
                }
                .landscapeGlassRow()

                ForEach(Self.entries) { entry in
                    Section {
                        HStack(alignment: .center, spacing: 12) {
                            PixelConsoleIcon(console: entry.console)
                                .frame(width: 36, height: 36)
                            FormatList(names: entry.extensions.map { "." + $0 })
                        }
                    } header: {
                        Text(entry.console.label)
                    } footer: {
                        if let key = entry.noteKey {
                            Text(NSLocalizedString(key, comment: ""))
                        }
                    }
                    .landscapeGlassRow()
                }

                Section {
                    Text(NSLocalizedString("library.empty.legal", comment: ""))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .landscapeGlassRow()
            }
        }
        .navigationTitle(NSLocalizedString("formats.title", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A row of extensions that wraps as whole names (2026-10-31). One Text
/// with the names joined by spaces broke inside a name, ".img" ending one
/// line on its dot and starting the next on "img", and the lines it made
/// started at uneven indents. Each name is its own view here, never split,
/// and a name that does not fit opens the next line at the left edge.
private struct FormatList: View {
    let names: [String]

    var body: some View {
        FormatFlow(spacing: 14, lineSpacing: 6) {
            ForEach(names, id: \.self) { name in
                Text(verbatim: name)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        // Takes the row's remaining width, so the flow is always offered a
        // real width to wrap in (a stack measuring it with none would get
        // one long line back).
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays its views left to right and starts a new line, at the left edge,
/// when the next one would not fit the width offered.
private struct FormatFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading, proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty && needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// The page as a sheet, from the welcome and from the "Add a game" guide:
/// its own navigation stack so the upright title bar and its close button
/// exist, the scaffold drawing its own bar on its side.
struct GameFormatsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GameFormatsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("common.done", comment: "")) { dismiss() }
                    }
                }
        }
    }
}

/// The link under the steps: "(?) See the supported game formats". A plain
/// text button, small and secondary, so it never competes with "Add a game".
struct GameFormatsLink: View {
    let tint: Color
    let action: () -> Void

    var body: some View {
        FocusableButton(shape: .capsule, action: action) {
            Label(NSLocalizedString("formats.link", comment: ""), systemImage: "questionmark.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .contentShape(Capsule())
        }
    }
}
