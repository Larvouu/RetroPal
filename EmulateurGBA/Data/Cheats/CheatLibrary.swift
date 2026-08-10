//
//  CheatLibrary.swift
//  EmulateurGBA
//
//  The downloaded half of the cheat database: one game's codes, fetched from
//  libretro's CDN and kept on disk afterwards.
//
//  Design, and why it is not a bulk download. Bundling every code costs ~11 MB
//  and grows with each console; downloading a whole console means thousands of
//  requests. A single game's file has a median size of 0.6 KB (90th percentile
//  8.5 KB), so fetching per game is effectively free — and "make my library
//  available offline" is then just that same fetch run over the games someone
//  actually owns, which is a dozen files rather than four thousand.
//
//  Everything fetched is cached, so a game looked up once works offline
//  forever. A game with no codes caches a marker, so we never re-ask.
//
//  Codes come from libretro-database (CC BY-SA 4.0) and travel from their CDN
//  straight to the device; we redistribute none of them.
//

import Foundation
import Network

@MainActor
final class CheatLibrary: ObservableObject {
    static let shared = CheatLibrary()

    struct Entry: Identifiable, Hashable {
        /// The libretro file this came from, e.g.
        /// "Pokemon - Emerald Version (USA, Europe) (Code Breaker)".
        let source: String
        let cheats: [Cheat]
        var id: String { source }
    }

    struct Cheat: Identifiable, Hashable {
        let description: String
        /// Already laid out the way the cheat field expects.
        let code: String
        var id: String { description + code }
    }

    enum Failure: Error {
        case offline
        case unavailable
    }

    /// Live connectivity, so a lookup can fail fast into an honest "you are
    /// offline" rather than a spinner that dies. Same approach RA takes.
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    private let session: URLSession
    private let cacheDir: URL

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)

        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        cacheDir = support.appendingPathComponent("CheatDB", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir,
                                                 withIntermediateDirectories: true)
        excludeFromBackup(cacheDir)

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.retropal.cheatdb.net"))
    }

    // MARK: - Lookup

    /// Everything known for this game, cache first. Throws `.offline` only
    /// when something still had to be fetched and could not be.
    func entries(forTitle title: String, system: String) async throws -> [Entry] {
        let stems = CheatIndex.shared.candidates(forTitle: title, system: system)
        guard !stems.isEmpty else { return [] }

        var result: [Entry] = []
        var missedWhileOffline = false
        for stem in stems {
            if let cached = cachedText(for: stem, system: system) {
                if cached.isEmpty { continue }   // known-empty marker
                let cheats = Self.parse(cached)
                if !cheats.isEmpty { result.append(Entry(source: stem, cheats: cheats)) }
                continue
            }
            guard isOnline else { missedWhileOffline = true; continue }
            guard let text = try? await download(stem: stem, system: system) else { continue }
            let cheats = Self.parse(text)
            // Cache even an empty result: it is an answer, and re-asking every
            // time a sheet opens would be rude to their CDN and to the battery.
            store(cheats.isEmpty ? "" : text, for: stem, system: system)
            if !cheats.isEmpty { result.append(Entry(source: stem, cheats: cheats)) }
        }
        if result.isEmpty && missedWhileOffline { throw Failure.offline }
        return result
    }

    /// True when nothing about this game still needs fetching.
    ///
    /// A game the index does not know counts as covered, NOT as missing: there
    /// is nothing to download for it, ever. Returning false there meant any
    /// library holding one game without cheats — and only 506 of ~2300 GBA
    /// titles have any — could never reach "all downloaded", so the Settings
    /// row kept offering a button whose tap did nothing.
    func isCached(title: String, system: String) -> Bool {
        let stems = CheatIndex.shared.candidates(forTitle: title, system: system)
        guard !stems.isEmpty else { return true }
        return stems.allSatisfy { cachedText(for: $0, system: system) != nil }
    }

    // MARK: - Offline pre-fetch

    /// Fetches the codes for a whole library, so everything someone owns works
    /// without a connection. This is the "download for offline" feature, and it
    /// is deliberately scoped to their games: a dozen small files instead of
    /// the four thousand a whole-console download would mean.
    ///
    /// `progress` reports (done, total) on the main actor. Already-cached games
    /// are counted immediately and never re-fetched, so running it twice is
    /// nearly instant.
    func prefetch(games: [(title: String, system: String)],
                  progress: @MainActor @escaping (Int, Int) -> Void) async throws {
        let work = games.filter { !isCached(title: $0.title, system: $0.system) }
        let total = games.count
        var done = total - work.count
        progress(done, total)
        guard !work.isEmpty else { return }
        guard isOnline else { throw Failure.offline }

        for game in work {
            let stems = CheatIndex.shared.candidates(forTitle: game.title, system: game.system)
            for stem in stems where cachedText(for: stem, system: game.system) == nil {
                guard isOnline else { throw Failure.offline }
                if let text = try? await download(stem: stem, system: game.system) {
                    store(Self.parse(text).isEmpty ? "" : text, for: stem, system: game.system)
                }
            }
            done += 1
            progress(done, total)
        }
    }

    // MARK: - Cache management

    /// Bytes currently held, for the Settings row. Cheap: these are tiny files.
    func cacheSize() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    func clearCache() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for url in items { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Network

    private func download(stem: String, system: String) async throws -> String {
        guard let url = CheatIndex.shared.url(forCheatFile: stem, system: system) else {
            throw Failure.unavailable
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.unavailable
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw Failure.unavailable
        }
        return text
    }

    // MARK: - Disk

    private func cacheURL(for stem: String, system: String) -> URL {
        // The stems carry slashes and colons in a few titles, so the file name
        // is a hash rather than the stem itself.
        let key = "\(system)/\(stem)"
        return cacheDir.appendingPathComponent("\(Self.stableHash(key)).cht")
    }

    private func cachedText(for stem: String, system: String) -> String? {
        let url = cacheURL(for: stem, system: system)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func store(_ text: String, for stem: String, system: String) {
        // Atomic: a dropped connection must never leave a half-written file
        // that would then be read as a valid, truncated answer.
        try? Data(text.utf8).write(to: cacheURL(for: stem, system: system), options: .atomic)
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// FNV-1a. Stable across launches and platforms, unlike `hashValue`.
    private static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - Parsing

    /// Reads libretro's `.cht` format. Entries carrying a description and no
    /// code are category headers (common in the DS files) and are dropped.
    ///
    /// `nonisolated` because it is pure: the class is @MainActor for its
    /// @Published connectivity, but this touches none of that, and inheriting
    /// the isolation would force every caller — including the tests — onto the
    /// main actor for no reason.
    nonisolated static func parse(_ text: String) -> [Cheat] {
        var descriptions: [Int: String] = [:]
        var codes: [Int: String] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("cheat"),
                  let equals = line.firstIndex(of: "="),
                  let firstQuote = line[equals...].firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""),
                  firstQuote < lastQuote else { continue }

            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            guard let underscore = key.lastIndex(of: "_") else { continue }
            let field = String(key[key.index(after: underscore)...])
            let digits = key.dropFirst("cheat".count).prefix { $0.isNumber }
            guard let index = Int(digits) else { continue }

            let value = String(line[line.index(after: firstQuote)..<lastQuote])
            if field == "desc" { descriptions[index] = value }
            else if field == "code" { codes[index] = value }
        }

        return codes.keys.sorted().compactMap { index in
            let code = formatCode(codes[index] ?? "")
            guard !code.isEmpty else { return nil }
            return Cheat(description: descriptions[index] ?? "", code: code)
        }
    }

    /// libretro joins a code's words with '+'. Re-lay them the way the cheat
    /// field expects, so a tapped code arrives already correctly shaped.
    /// `nonisolated` for the same reason as `parse`: it is pure.
    nonisolated static func formatCode(_ raw: String) -> String {
        let tokens = raw.split(separator: "+").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }

        func isHex(_ s: String, _ n: Int) -> Bool {
            s.count == n && s.allSatisfy(\.isHexDigit)
        }
        let pairable = tokens.allSatisfy { isHex($0, 8) }
            || tokens.enumerated().allSatisfy { isHex($1, $0 % 2 == 0 ? 8 : 4) }
        guard pairable else { return tokens.joined(separator: "\n") }

        return stride(from: 0, to: tokens.count, by: 2).map {
            tokens[$0..<min($0 + 2, tokens.count)].joined(separator: " ")
        }.joined(separator: "\n")
    }
}
