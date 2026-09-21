//
//  DiscImportGroup.swift
//  EmulateurGBA
//
//  Turning a pile of files into games, for the one console whose games are not
//  files.
//
//  Every console before the PlayStation imported one file per game, so the
//  picker's job was a loop. A disc is a filesystem, and the shapes it arrives
//  in are:
//
//    Game.chd                     one file, the format we lead with
//    Game.cue + Game.bin          a descriptor and its data, two files
//    Game.cue + 57 .bin           multi-track audio; Tomb Raider really is 58
//    Game.m3u + two .cue + .bin   a multi-disc game, five files or more
//    Game.cue + Game.sbi          a PAL disc with LibCrypt subchannel data
//
//  THE ALGORITHM WORKS ON NAMES, NOT ON FILES, and that is the shape of this
//  type. The first version knew only about URLs, which meant the ZIP importer
//  could not use it: a zip is a list of entries, not a list of files. So an
//  archive holding ONE game in fifty-eight parts was offered as fifty-eight
//  games, every one of them unplayable, which is exactly what a real Tomb
//  Raider archive did on device. The core below is therefore pure string work
//  with the descriptor text handed in, and both callers are thin wrappers over
//  it: one reads from disk, one reads from inside an archive.
//
//  WHY EVERY PART MUST BE PRESENT. On the picked-files path the app cannot read
//  a file the user did not choose: iOS grants access per picked URL, so a `.cue`
//  naming a `.bin` beside it gives us no way to reach that `.bin`. A group that
//  is missing a part is reported as a GAP, by name, rather than imported into
//  something that does not boot.
//

import Foundation

// MARK: - Results, by name

/// One game, as the names of the files that make it up.
struct DiscNameGroup {
    /// The name the emulator is pointed at: the `.m3u` if there is one, else
    /// the `.cue`, else the image itself.
    ///
    /// For a game assembled by `playlistDiscs` below this is the FIRST disc,
    /// because something has to identify the game before its playlist exists.
    let boot: String
    /// Every name belonging to the game, including `boot`.
    let members: [String]

    /// The discs of a multi-disc game that arrived WITHOUT a playlist, in disc
    /// order, as the names they will have once imported. Nil for every game
    /// that needs nothing written.
    ///
    /// The importer writes the `.m3u` from this after copying, and points the
    /// library entry at it. It is a list of names rather than a finished file
    /// because this type does no IO: it works on names, so that the same
    /// algorithm can group a picked batch and the inside of an archive.
    var playlistDiscs: [String]? = nil

    /// The game's name when the boot file's own name is not it. Set with
    /// `playlistDiscs`: the boot is "Final Fantasy VII (USA) (Disc 1)" and the
    /// game is "Final Fantasy VII (USA)".
    var name: String? = nil

    /// What the game is called, before the title cleaner runs.
    var displayName: String {
        name ?? ((boot as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// A game whose parts are not all present, carrying the names it looked for.
struct DiscNameGap {
    let boot: String
    let missing: [String]
}

// MARK: - Results, as files

/// One game assembled from picked file URLs.
struct DiscImportGroup {
    let boot: URL
    let members: [URL]
    /// See `DiscNameGroup.playlistDiscs`. The importer writes these lines into
    /// a `.m3u` inside the game's folder and boots from it.
    var playlistDiscs: [String]? = nil
    /// See `DiscNameGroup.name`.
    var name: String? = nil

    /// Name for the game's folder and its library entry, before cleaning.
    var displayName: String { name ?? boot.deletingPathExtension().lastPathComponent }

    /// The member used to identify the game: the largest one, which is the data
    /// track rather than the few hundred bytes of text that point at it.
    /// Hashing the `.cue` would give two different games the same identity
    /// whenever their descriptors happened to match.
    ///
    /// Reads file sizes, so it must be asked INSIDE a security scope for the
    /// picked URLs. `ROMImporter.importDiscGroup` opens every member's scope
    /// before touching this; outside one, every size reads as nil and the
    /// answer degrades to "the last member", which would be silently wrong.
    var identityFile: URL {
        members.max {
            (Self.byteSize($0) ?? 0) < (Self.byteSize($1) ?? 0)
        } ?? boot
    }

    private static func byteSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }
}

struct DiscImportGap {
    let boot: URL
    let missing: [String]
}

// MARK: - Where a disc game lives once imported

/// A disc game is a FOLDER, and several things need to agree about that: what
/// the game is called for saves, how big it is, and whether it is still intact.
/// One place says so, because the alternative is the same rule written three
/// times and drifting.
enum DiscStorage {
    /// The directory every game is imported into.
    static let romsFolderName = "ROMs"

    /// The folder that IS the game, or nil when the ROM is a cartridge sitting
    /// directly in `ROMs/`.
    static func gameFolder(forROMAt url: URL) -> URL? {
        let parent = url.deletingLastPathComponent()
        let name = parent.lastPathComponent
        guard !name.isEmpty, name != romsFolderName else { return nil }
        return parent
    }

    /// Total bytes the game occupies: every file in its folder for a disc, the
    /// file itself for a cartridge.
    ///
    /// This is what `GameEntity.romSize` stores and what the launch preflight
    /// compares. For a cartridge the two questions are the same one. For a disc
    /// they are not, and answering with the boot file would be absurd in both
    /// directions: a `.cue` is a few kilobytes, so Game Details would report a
    /// six-hundred-megabyte game as 7 KB, and the preflight would compare a
    /// number recorded from the data track against a number read from a text
    /// file and declare a perfectly good game damaged. That is exactly what it
    /// did on the first device run.
    ///
    /// Summing the folder is also a BETTER integrity check than the file alone.
    /// A disc's failure mode is one track going missing, which leaves the boot
    /// file intact and the game unplayable; a total catches it.
    static func installedSize(ofROMAt url: URL) -> Int64? {
        let fm = FileManager.default
        guard let folder = gameFolder(forROMAt: url) else {
            return (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64
        }
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        var total: Int64 = 0
        for name in names {
            let path = folder.appendingPathComponent(name).path
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}

// MARK: - The grouper

enum DiscImportGrouper {

    /// Files that attach to a game but can never be one. A lone `.sbi` is not a
    /// game and must not become a failed import; it is simply dropped.
    ///
    /// Read from `ROMSystemType` rather than restated here. That list also
    /// decides what the file pickers offer, and a console whose extensions are
    /// declared in two places is the shape that leaves one of them behind.
    static let sidecarExtensions = ROMSystemType.discSidecarExtensions

    /// Whether a name belongs to the disc world at all, part or sidecar.
    static func isDiscFile(_ name: String) -> Bool {
        let e = ext(name)
        return ROMSystemType.discFileExtensions.contains(e) || sidecarExtensions.contains(e)
    }

    // MARK: The algorithm

    /// Group a list of file names into games.
    ///
    /// - Parameters:
    ///   - names: every name in the batch, disc or not.
    ///   - descriptorText: the contents of a `.cue` or `.m3u`, by the exact name
    ///     given. Called ONLY for descriptors, so a caller that has to
    ///     decompress pays for a few hundred bytes of text and not for a disc.
    /// - Returns: the names that are not discs, in their original order; the
    ///   games; and the games missing parts.
    static func groupNames(_ names: [String],
                           descriptorText: (String) -> String?)
    -> (others: [String], discs: [DiscNameGroup], gaps: [DiscNameGap]) {

        var others: [String] = []
        var discNames: [String] = []
        for name in names {
            if isDiscFile(name) { discNames.append(name) } else { others.append(name) }
        }
        guard !discNames.isEmpty else { return (others, [], []) }

        // References inside a descriptor are BARE NAMES, while an archive entry
        // can carry a folder prefix, so both sides are keyed on the last path
        // component. Lowercased because a `.cue` written on Windows routinely
        // disagrees with the file's own capitalisation, and that must not cost
        // the user their game.
        var byKey: [String: String] = [:]
        for name in discNames { byKey[key(name)] = name }

        var claimed = Set<String>()
        var discs: [DiscNameGroup] = []
        var gaps: [DiscNameGap] = []

        func resolve(_ references: [String]) -> (found: [String], missing: [String]) {
            var found: [String] = []
            var missing: [String] = []
            for reference in references {
                if let name = byKey[key(reference)] { found.append(name) }
                else { missing.append(reference) }
            }
            return (found, missing)
        }

        func sidecars(for stems: Set<String>) -> [String] {
            discNames.filter {
                sidecarExtensions.contains(ext($0)) && stems.contains(stem($0))
            }
        }

        // Sorted so a batch always groups the same way, whatever order the
        // picker or the archive happened to list it in.
        let sorted = discNames.sorted()

        func close(boot: String, members: [String], missing: [String]) {
            let all = dedupe(members + sidecars(for: Set(members.map(stem))))
            all.forEach { claimed.insert($0) }
            if missing.isEmpty { discs.append(DiscNameGroup(boot: boot, members: all)) }
            else { gaps.append(DiscNameGap(boot: boot, missing: dedupe(missing))) }
        }

        // The two descriptor formats that name their tracks: a `.cue`, and a
        // cdrdao `.toc`, which the core also boots from.
        func tracks(of descriptor: String) -> [String] {
            ext(descriptor) == "toc" ? tocTracks(descriptorText(descriptor))
                                     : cueTracks(descriptorText(descriptor))
        }

        // --- 1. playlists first: they claim the descriptors they name --------
        for name in sorted where ext(name) == "m3u" {
            guard !claimed.contains(name) else { continue }
            let (descriptors, missingDescriptors) = resolve(lines(descriptorText(name)))
            var members = [name] + descriptors
            var missing = missingDescriptors
            for descriptor in descriptors where ext(descriptor) == "cue" || ext(descriptor) == "toc" {
                let (found, missingTracks) = resolve(tracks(of: descriptor))
                members += found
                missing += missingTracks
            }
            close(boot: name, members: members, missing: missing)
        }

        // --- 2. descriptors: they claim their tracks -------------------------
        for name in sorted where ext(name) == "cue" || ext(name) == "toc" {
            guard !claimed.contains(name) else { continue }
            let (found, missing) = resolve(tracks(of: name))
            close(boot: name, members: [name] + found, missing: missing)
        }

        // --- 3. whatever is left and can boot on its own ---------------------
        for name in sorted where !claimed.contains(name) {
            // A CloneCD descriptor is a sidecar of its image (the core boots the
            // `.img` and reads the `.ccd` beside it), so it rides along when the
            // image is here. Alone, it is not a harmless patch file: the person
            // has half a game, and the missing half is named.
            if ext(name) == "ccd" {
                if byKey[stem(name) + ".img"] == nil {
                    // The lookup is case-insensitive, but the name reaches the
                    // person in the error, so it keeps the file's own spelling.
                    let ownStem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
                    gaps.append(DiscNameGap(boot: name, missing: [ownStem + ".img"]))
                    claimed.insert(name)
                }
                continue
            }
            // A lone sidecar is dropped rather than failed: the person picked a
            // patch file, which is a harmless mistake and not a broken game.
            if sidecarExtensions.contains(ext(name)) { continue }
            close(boot: name, members: [name], missing: [])
        }

        return (others, mergeDiscsOfOneGame(discs), gaps)
    }

    // MARK: - Discs of one game that arrived without a playlist

    /// A disc token at the end of, or inside, a file's stem: `(Disc 2)`,
    /// `[CD2]`, `- Disk 2`, `(Disc 2 of 3)`.
    ///
    /// Deliberately narrow. Either the token is BRACKETED, which is how Redump
    /// and No-Intro write it and therefore how nearly every dump in the world is
    /// named, or it is preceded by a real separator and is the last thing in the
    /// name. A bare "cd2" in the middle of a title does not count, because the
    /// price of a false positive here is two unrelated games merged into one
    /// entry the player cannot separate.
    private static let discTokenPattern =
        "[\\(\\[]\\s*(?:disc|disk|cd)\\s*[ _.-]?\\s*(\\d{1,2})(?:\\s*of\\s*\\d{1,2})?\\s*[\\)\\]]"
        + "|[ _.-]+(?:disc|disk|cd)\\s*[ _.-]?\\s*(\\d{1,2})\\s*$"

    private static let discTokenRegex = try? NSRegularExpression(
        pattern: discTokenPattern, options: [.caseInsensitive])

    /// The disc number a name carries, and the name with that token taken out.
    /// Nil when the name carries no token, which is almost every game.
    static func discToken(inStem stem: String) -> (base: String, number: Int)? {
        guard let regex = discTokenRegex else { return nil }
        let full = NSRange(stem.startIndex..., in: stem)
        guard let match = regex.firstMatch(in: stem, options: [], range: full) else { return nil }
        var number: Int?
        for group in 1...2 where match.range(at: group).location != NSNotFound {
            if let r = Range(match.range(at: group), in: stem) { number = Int(stem[r]) }
        }
        guard let number, number > 0,
              let tokenRange = Range(match.range, in: stem) else { return nil }
        var base = stem
        base.replaceSubrange(tokenRange, with: " ")
        base = collapseSeparators(base)
        guard !base.isEmpty else { return nil }
        return (base, number)
    }

    /// Runs of spaces, underscores, dots and dashes become one space, and the
    /// ends are trimmed. So "FF7 (USA)  ()" and "FF7_(USA)" compare equal, which
    /// is what lets two files named by different tools still be one game.
    private static func collapseSeparators(_ text: String) -> String {
        var out = ""
        var pendingSeparator = false
        for character in text {
            if character == " " || character == "_" || character == "." || character == "-" {
                pendingSeparator = !out.isEmpty
            } else {
                if pendingSeparator { out.append(" ") }
                pendingSeparator = false
                out.append(character)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Fold the groups that are really the discs of ONE game into one game.
    ///
    /// ⚠ WHY THIS EXISTS. A `.chd` is a whole disc in a single file and carries
    /// no playlist, and `.chd` is the format the app leads with everywhere. So
    /// the likeliest way a multi-disc game arrives is three files with no `.m3u`
    /// between them, and until this pass existed that became THREE library
    /// entries. The player could still finish disc one. They could not carry on:
    /// a disc game's memory card and save states are filed under its FOLDER, so
    /// three entries meant three memory cards, and the save from disc one was
    /// not there when disc two started. The game was unfinishable without the
    /// player knowing to write an `.m3u` by hand.
    ///
    /// The rule is deliberately strict, because merging two games that are not
    /// one is worse than leaving three entries: every disc must carry a token,
    /// the names either side of that token must be IDENTICAL once separators are
    /// collapsed, the numbers must all differ, and there must be at least two of
    /// them. A playlist that already exists is never touched — those groups are
    /// closed by pass 1 and boot from a `.m3u`, which is excluded here.
    static func mergeDiscsOfOneGame(_ discs: [DiscNameGroup]) -> [DiscNameGroup] {
        // key -> the groups sharing it, with their disc numbers
        var buckets: [String: [(group: DiscNameGroup, number: Int, base: String)]] = [:]
        var order: [String] = []
        for group in discs {
            guard ext(group.boot) != "m3u",
                  let token = discToken(inStem: stem(group.boot)) else { continue }
            let key = token.base.lowercased()
            if buckets[key] == nil { order.append(key) }
            // The base is kept from the file's own stem rather than lowercased,
            // so the game keeps its capitals.
            let displayBase = discToken(inStem:
                ((group.boot as NSString).lastPathComponent as NSString)
                    .deletingPathExtension)?.base ?? token.base
            buckets[key, default: []].append((group, token.number, displayBase))
        }

        var merged: [String: DiscNameGroup] = [:]
        for key in order {
            guard let bucket = buckets[key], bucket.count > 1 else { continue }
            let numbers = bucket.map(\.number)
            guard Set(numbers).count == numbers.count else { continue }
            let ordered = bucket.sorted { $0.number < $1.number }

            // ⚠ MERGING PUTS THESE FILES IN ONE FOLDER, which is a way to break
            // a game that separate folders never had: two discs whose data
            // tracks are both called `track01.bin` would overwrite each other,
            // and disc two would read disc one's data.
            //
            // Today's callers make that hard to reach, because `groupNames`
            // resolves references by bare filename and so never hands the same
            // name to two groups. That is a property of the callers and not of
            // this function, and the symptom if it ever changed would be a game
            // that imports cleanly and plays the wrong disc, which is the worst
            // kind. So the invariant is checked here where it belongs.
            let allMembers = dedupe(ordered.flatMap { $0.group.members })
            let filenames = allMembers.map { ($0 as NSString).lastPathComponent.lowercased() }
            guard Set(filenames).count == filenames.count else { continue }

            merged[key] = DiscNameGroup(
                boot: ordered[0].group.boot,
                members: allMembers,
                playlistDiscs: ordered.map { ($0.group.boot as NSString).lastPathComponent },
                name: ordered[0].base)
        }
        guard !merged.isEmpty else { return discs }

        // Rebuilt in the original order, with each merged game taking the place
        // of its first disc, so a batch always comes back in a stable shape.
        var out: [DiscNameGroup] = []
        var emitted = Set<String>()
        for group in discs {
            let key = ext(group.boot) == "m3u" ? nil
                : discToken(inStem: stem(group.boot))?.base.lowercased()
            if let key, let game = merged[key] {
                if emitted.insert(key).inserted { out.append(game) }
            } else {
                out.append(group)
            }
        }
        return out
    }

    // MARK: Picked files

    /// Partition a picked batch of URLs. A thin wrapper over `groupNames`.
    static func group(_ urls: [URL]) -> (cartridges: [URL],
                                         discs: [DiscImportGroup],
                                         gaps: [DiscImportGap]) {
        // Keyed on the FULL path, not the filename: two picked files can share
        // a name and come from different folders, and collapsing them would
        // drop one of the person's games without saying so.
        var byPath: [String: URL] = [:]
        for url in urls { byPath[url.path] = url }

        let grouping = groupNames(urls.map(\.path)) { path in
            byPath[path].flatMap(readText)
        }

        let cartridges = grouping.others.compactMap { byPath[$0] }
        let discs = grouping.discs.map {
            DiscImportGroup(boot: byPath[$0.boot] ?? URL(fileURLWithPath: $0.boot),
                            members: $0.members.compactMap { byPath[$0] },
                            playlistDiscs: $0.playlistDiscs,
                            name: $0.name)
        }
        let gaps = grouping.gaps.map {
            DiscImportGap(boot: byPath[$0.boot] ?? URL(fileURLWithPath: $0.boot),
                          missing: $0.missing)
        }
        return (cartridges, discs, gaps)
    }

    // MARK: - Reading descriptors

    /// The data files a `.cue` points at, in order.
    ///
    /// Only `FILE` lines matter here; tracks, indexes and pregaps are the core's
    /// business. Both quoted and bare forms are accepted, because both occur in
    /// the wild and a `.cue` we refuse to parse costs the user a game over a
    /// syntax detail they did not choose.
    static func cueTracks(_ text: String?) -> [String] {
        guard let text else { return [] }
        var names: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // The keyword, then ANY whitespace: a tab after FILE is rare but
            // real, and refusing it would cost someone a game over a character
            // they cannot see.
            guard line.count > 4, line.prefix(4).uppercased() == "FILE",
                  line[line.index(line.startIndex, offsetBy: 4)].isWhitespace else { continue }
            let rest = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"") {
                let afterQuote = rest.dropFirst()
                if let end = afterQuote.firstIndex(of: "\"") {
                    names.append(String(afterQuote[..<end]))
                }
            } else if let space = rest.firstIndex(of: " ") {
                names.append(String(rest[..<space]))
            } else if !rest.isEmpty {
                names.append(rest)
            }
        }
        return names
    }

    /// The data files a cdrdao `.toc` points at, in order.
    ///
    /// The file references are `FILE`, `DATAFILE` and `AUDIOFILE` statements,
    /// each followed by a quoted name and then offsets and lengths the core
    /// deals with (`DATAFILE "track01.bin" 0`, `FILE "track02.bin" 0 03:00:00`).
    /// A `.toc` written by a Japanese Windows tool reaches here through the
    /// same decoder as a `.cue`.
    static func tocTracks(_ text: String?) -> [String] {
        guard let text else { return [] }
        var names: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let keyword = ["DATAFILE", "AUDIOFILE", "FILE"].first(where: {
                line.uppercased().hasPrefix($0)
            }) else { continue }
            let rest = String(line.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("\"") else { continue }
            let afterQuote = rest.dropFirst()
            if let end = afterQuote.firstIndex(of: "\"") {
                let name = String(afterQuote[..<end])
                if !name.isEmpty, !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    /// The discs a `.m3u` lists, in order. Blank lines and `#` comments skipped.
    static func lines(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Decode a descriptor's bytes. `.cue` files are old and frequently
    /// written by Windows tools in the machine's OEM codepage, and the text
    /// that matters is the `FILE` line naming the `.bin`: decoded wrong, it
    /// names a file that does not exist and the game is reported as missing
    /// its own discs. Straight to Latin-1 after UTF-8 did exactly that for
    /// every Japanese cue sheet. Same chain as ZIP entry names, so a disc
    /// extracted under a decoded name is found by its decoded descriptor.
    static func decode(_ data: Data) -> String? {
        LegacyTextEncoding.decode(data)
    }

    /// Reads a small text file from a picked URL. The security scope is opened
    /// here because this runs during GROUPING, before any import has begun.
    static func readText(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func readCueTracks(_ url: URL) -> [String] { cueTracks(readText(url)) }
    static func readPlaylist(_ url: URL) -> [String] { lines(readText(url)) }

    // MARK: - Name helpers

    private static func ext(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
    private static func key(_ name: String) -> String {
        (name as NSString).lastPathComponent.lowercased()
    }
    private static func stem(_ name: String) -> String {
        ((name as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
    }
    private static func dedupe(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }
}
