//
//  ArchiveGameRules.swift
//  EmulateurGBA
//
//  Which GAMES an archive holds, from the names of its files and, for a few of
//  them, their bytes. ONE copy of the rules, read by both archive readers: the
//  app's own zip reader (`ZIPExtractor`) and the one for every other format
//  (`GameArchive`, libarchive). Moved here out of `ZIPExtractor` on 2026-10-27,
//  unchanged, when the second reader arrived: two copies of "a README is not a
//  game" is the shape in which one of them is fixed and the other is not.
//

import Foundation

enum ArchiveGameRules {

    /// Read from the parser's own list so a new console cannot be importable
    /// loose but invisible inside an archive.
    static let romExtensions: Set<String> = Set(ROMSystemType.allFileExtensions)

    /// Whether an entry name is one of the app's game or disc extensions.
    static func isGameFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return romExtensions.contains(where: { lower.hasSuffix(".\($0)") })
    }

    /// One file of the archive, as the rules see it.
    struct Entry {
        let name: String
        /// The uncompressed size, when the archive states it.
        let size: Int?
    }

    /// The games, from the archive's GAME files (already filtered by
    /// `isGameFile`, in archive order). `bytes` returns an entry's bytes, or
    /// enough of its start for the tests below (a Mega Drive header, 16.5 KB),
    /// or nil when it cannot be read; it is called only for `.md` and `.bin`
    /// entries no larger than a cartridge and for disc descriptors.
    ///
    /// **Cartridges win over disc parts when an archive holds both**, and that
    /// rule exists to protect archives that already work. The PlayStation
    /// brought generic extensions into the ROM list, `.bin` and `.iso` among
    /// them, and a cartridge archive that happens to carry a stray `.bin` beside
    /// its game would otherwise go from importing silently to asking the user
    /// which of two "games" they meant. An archive containing a cartridge is a
    /// cartridge archive; only one containing no cartridge at all is read as a
    /// disc. A Mega Drive `.bin` is a cartridge.
    ///
    /// Duplicate names are dropped: extraction is by name, so a malformed
    /// archive with two identical entry names could only ever yield the first
    /// one anyway.
    static func games(_ entries: [Entry], bytes: (String) -> Data?)
    -> (discs: [DiscNameGroup], cartridges: [String], gaps: [DiscNameGap]) {
        let markdown = markdownNames(entries, bytes: bytes)
        var seen = Set<String>()
        let names = entries.map(\.name).filter { !markdown.contains($0) && seen.insert($0).inserted }

        let megaDriveBins = megaDriveBinNames(entries, bytes: bytes)
        let cartridgeNames = names.filter { !isDiscPart($0) || megaDriveBins.contains($0) }
        if !cartridgeNames.isEmpty { return ([], cartridgeNames, []) }

        let grouping = DiscImportGrouper.groupNames(names) { name in
            bytes(name).flatMap { data in
                DiscImportGrouper.decodeDescriptor(data, ext: (name as NSString).pathExtension, among: names)
            }
        }
        return (grouping.discs, grouping.others, grouping.gaps)
    }

    /// The flat list of entry names to offer: the cartridges when there are
    /// any, else every name (the disc parts). `ZIPExtractor.romEntryNames`.
    static func entryNames(_ entries: [Entry], bytes: (String) -> Data?) -> [String] {
        let markdown = markdownNames(entries, bytes: bytes)
        var seen = Set<String>()
        let names = entries.map(\.name).filter { !markdown.contains($0) && seen.insert($0).inserted }
        let megaDriveBins = megaDriveBinNames(entries, bytes: bytes)
        let cartridges = names.filter { !isDiscPart($0) || megaDriveBins.contains($0) }
        return cartridges.isEmpty ? names : cartridges
    }

    static func isDiscPart(_ entryName: String) -> Bool {
        DiscImportGrouper.isDiscFile(entryName)
    }

    private static func ext(_ name: String) -> String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }

    /// The `.bin` entries that are Mega Drive cartridges rather than disc
    /// tracks: the same test as a loose file (`GBAROMParser.isMegaDriveBin`),
    /// on the decompressed header. Only an entry no larger than a cartridge
    /// is read, so an archive's PlayStation data track never is.
    static func megaDriveBinNames(_ entries: [Entry], bytes: (String) -> Data?) -> Set<String> {
        var names = Set<String>()
        for entry in entries
        where ext(entry.name) == "bin" && (entry.size ?? .max) <= GBAROMParser.megaDriveBinMaxBytes {
            guard let data = bytes(entry.name), GBAROMParser.isValidMDFile(data: data) else { continue }
            names.insert(entry.name)
        }
        return names
    }

    /// The `.md` entries that are Markdown rather than Mega Drive cartridges:
    /// the README an archive so often carries beside its game. `.md` is both
    /// formats' extension, so, as for `.bin` above, the bytes decide, with the
    /// loose file's own test (`GBAROMParser.isValidMDFile`). Left in, a README
    /// turned a one-game archive into a choice of two, and hid a disc entirely,
    /// since a "cartridge" wins over disc parts (audit 2026-10-12).
    static func markdownNames(_ entries: [Entry], bytes: (String) -> Data?) -> Set<String> {
        var names = Set<String>()
        for entry in entries where ext(entry.name) == "md" {
            // Larger than any cartridge: not one, and not worth reading.
            guard (entry.size ?? .max) <= GBAROMParser.megaDriveBinMaxBytes else {
                names.insert(entry.name); continue
            }
            guard let data = bytes(entry.name), GBAROMParser.isValidMDFile(data: data) else {
                names.insert(entry.name); continue
            }
        }
        return names
    }
}
