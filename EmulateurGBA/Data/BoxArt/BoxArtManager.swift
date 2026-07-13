//
//  BoxArtManager.swift
//  EmulateurGBA
//
//  Silent library box art: identifies every imported game against the
//  bundled BoxArtIndex and downloads its cover once from
//  thumbnails.libretro.com (the same community database Delta-class
//  emulators use). The cover replaces the save-state screenshot in the
//  LIBRARY list only; Game Details keeps the screenshot.
//
//  State lives in GameEntity.coverType (attribute existed since 1.0,
//  written but never read until now):
//    "placeholder"      -> not yet resolved (default; retried until terminal)
//    "boxart"           -> cover on disk, matched byte-exact by CRC32
//    "boxart_heuristic" -> cover on disk, matched by serial/fuzzy — the RA
//                          game image outranks it in the library display
//    "none"             -> definitive no-match; screenshot (or RA image)
//    "custom"           -> user-picked cover; beats everything, never reset
//  A transport failure (offline, timeout, 5xx) leaves "placeholder" so the
//  game is retried on a later sweep; only a definitive answer (a downloaded
//  cover, or 404s for every candidate) is persisted. Identification itself
//  (CRC32 / serial / fuzzy) is fully local, so offline sweeps cost nothing.
//
//  Threading mirrors RAGameIndex: all state mutations on the main thread,
//  file hashing + downloads on one serial utility queue, ONE download at a
//  time (politeness to the thumbnail server). The session deliberately does
//  NOT use waitsForConnectivity (the RA hang lesson): a request either runs
//  now or fails now, and the next sweep retries.
//

import Foundation
import CoreData
import UIKit

final class BoxArtManager {
    static let shared = BoxArtManager()

    /// One library game as the sweep sees it (value type: crosses queues).
    struct GameInput {
        let romHash: String
        let filename: String
        let path: String
        let title: String
        let system: String
        let coverState: String?
    }

    static let coverStatePlaceholder = "placeholder"
    /// Cover matched by CRC32: the file IS the retail dump, byte-exact.
    /// Nothing automatic outranks this cover (the real native box).
    static let coverStateBoxArt = "boxart"
    /// Cover matched by serial or fuzzy title: right for legit renamed or
    /// trimmed dumps, but a base-named ROM hack can land here wearing its
    /// base game's box. The RA game image (which identifies the ACTUAL
    /// bytes via hash) outranks this one in the library when available.
    static let coverStateBoxArtHeuristic = "boxart_heuristic"
    static let coverStateNone = "none"
    /// A cover the user picked themselves. Beats every automatic source,
    /// is never touched by sweeps or resolution-version resets, and is the
    /// answer for games no database covers (ROM hacks, homebrew).
    static let coverStateCustom = "custom"

    private static let host = URL(string: "https://thumbnails.libretro.com")!
    private static let systemDirectories: [ROMSystemType: String] = [
        .gb: "Nintendo - Game Boy",
        .gbc: "Nintendo - Game Boy Color",
        .gba: "Nintendo - Game Boy Advance",
        .nds: "Nintendo - Nintendo DS",
    ]
    /// Bound on HTTP tries per game: exact + serial + a couple of fuzzy
    /// runners-up. Beyond that, a wrong cover is likelier than a right one.
    private static let maxHTTPAttempts = 4
    private static let fuzzyCandidateLimit = 3

    private let workQueue = DispatchQueue(label: "boxart.match", qos: .utility)
    private let session: URLSession
    private let directory: URL

    /// Games being resolved right now / already attempted since launch, so a
    /// failing game can't loop within one session. Main-thread only.
    private var inFlight = Set<String>()
    private var attemptedThisLaunch = Set<String>()

    /// Bump when the matching logic changes in a way that can OVERTURN old
    /// verdicts; the next sweep then resets every terminal state and
    /// re-resolves the whole library once. v2 = the ROM-hack rule (serial
    /// gated on filename consistency, header-echo titles dropped). v3 =
    /// verdicts split into exact ("boxart") vs heuristic
    /// ("boxart_heuristic") so the RA image can outrank the latter.
    private static let resolutionVersion = 3
    private static let resolutionVersionKey = "boxArtResolutionVersion"

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        directory = support.appendingPathComponent("BoxArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    /// Where a game's cover lives once downloaded (keyed by the import hash:
    /// stable across renames, gone with the game).
    func imageURL(forROMHash romHash: String) -> URL {
        directory.appendingPathComponent(romHash).appendingPathExtension("png")
    }

    /// Where a user-picked cover lives (separate file: it must survive a
    /// re-download AND a resolution-version reset of the automatic one).
    func customImageURL(forROMHash romHash: String) -> URL {
        directory.appendingPathComponent(romHash + "-custom").appendingPathExtension("jpg")
    }

    // MARK: - Custom covers (main thread; called from Game Details)

    /// Persists a user-picked cover and flips the game to "custom".
    /// Returns false when the image can't be encoded or written — the
    /// caller MUST surface that to the user (never a silent failure).
    func setCustomCover(_ image: UIImage, for game: NSManagedObject) -> Bool {
        guard let romHash = game.value(forKey: "romHash") as? String,
              let data = Self.downscaled(image, maxDimension: 1024)
                  .jpegData(compressionQuality: 0.85)
        else { return false }
        do {
            try data.write(to: customImageURL(forROMHash: romHash), options: .atomic)
        } catch {
            return false
        }
        game.setValue(Self.coverStateCustom, forKey: "coverType")
        try? game.managedObjectContext?.save()
        return true
    }

    /// Deletes the user-picked cover and restores the automatic behavior by
    /// re-resolving from scratch ("placeholder" + the downloaded file
    /// dropped): the exact-vs-heuristic distinction of the old verdict is
    /// unknowable here, and one re-download beats guessing it. A true
    /// no-match just re-concludes "none" and the screenshot stays.
    func removeCustomCover(for game: NSManagedObject) {
        guard let romHash = game.value(forKey: "romHash") as? String else { return }
        try? FileManager.default.removeItem(at: customImageURL(forROMHash: romHash))
        try? FileManager.default.removeItem(at: imageURL(forROMHash: romHash))
        game.setValue(Self.coverStatePlaceholder, forKey: "coverType")
        try? game.managedObjectContext?.save()
        // Let the next sweep re-resolve right away (this launch may already
        // have attempted the game before the custom cover was set).
        attemptedThisLaunch.remove(romHash)
    }

    /// Longest side capped (covers never need more); keeps small images as-is.
    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - Sweep (main thread)

    /// Called with the COMPLETE library (same site as the RA index sync).
    /// Resolves every game still pending, one at a time; prunes covers of
    /// deleted games. Terminal games cost one file-existence check each.
    func sweep(games: [GameInput]) {
        resetVerdictsIfResolutionChanged()
        let keep = Set(games.map { $0.romHash })
        workQueue.async { [directory] in
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil)) ?? []
            for file in files {
                // Downloaded covers are <hash>.png, user-picked ones are
                // <hash>-custom.jpg; both leave with their game.
                let stem = file.deletingPathExtension().lastPathComponent
                let romHash = stem.hasSuffix("-custom") ? String(stem.dropLast("-custom".count)) : stem
                if !keep.contains(romHash) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }

        for game in games {
            guard game.coverState != Self.coverStateNone,
                  game.coverState != Self.coverStateCustom,
                  !FileManager.default.fileExists(atPath: imageURL(forROMHash: game.romHash).path),
                  !inFlight.contains(game.romHash),
                  !attemptedThisLaunch.contains(game.romHash)
            else { continue }
            // "boxart" with no file on disk (restore to a new device) falls
            // through here and simply re-resolves.
            inFlight.insert(game.romHash)
            workQueue.async { [weak self] in self?.resolve(game) }
        }
    }

    /// One-shot when resolutionVersion is newer than the stored one: every
    /// terminal verdict goes back to "placeholder" and its cached cover is
    /// deleted, so the normal sweep re-resolves the library under the new
    /// rules. Persisted BEFORE stamping the version, so a kill mid-way just
    /// repeats the (idempotent) reset. Main thread, viewContext.
    private func resetVerdictsIfResolutionChanged() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.resolutionVersionKey) < Self.resolutionVersion else { return }

        let context = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "GameEntity")
        // User-picked covers are the user's decision, not a verdict of ours:
        // a matching-logic bump must never touch them.
        request.predicate = NSPredicate(format: "coverType != %@ AND coverType != %@",
                                        Self.coverStatePlaceholder, Self.coverStateCustom)
        if let stale = try? context.fetch(request), !stale.isEmpty {
            for entity in stale {
                entity.setValue(Self.coverStatePlaceholder, forKey: "coverType")
                if let romHash = entity.value(forKey: "romHash") as? String {
                    try? FileManager.default.removeItem(at: imageURL(forROMHash: romHash))
                }
            }
            try? context.save()
        }
        defaults.set(Self.resolutionVersion, forKey: Self.resolutionVersionKey)
    }

    // MARK: - Resolution (work queue, one game at a time)

    private enum FetchResult {
        case image(Data)
        case notFound
        case transportFailure
    }

    private func resolve(_ game: GameInput) {
        guard let system = ROMSystemType(rawValue: game.system),
              let systemDirectory = Self.systemDirectories[system]
        else { finish(game, state: Self.coverStateNone, method: nil); return }

        guard BoxArtIndex.shared.isLoaded else {
            // Index missing/undecodable: no verdict of any kind (a broken
            // build must not permanently stamp the library "none").
            finish(game, state: nil, method: nil)
            return
        }

        let candidates = self.candidates(for: game, system: system)
        guard !candidates.isEmpty else {
            // Fully local verdict: not in the No-Intro namespace at all
            // (homebrew, ROM hack, bad dump). The screenshot is final.
            finish(game, state: Self.coverStateNone, method: nil)
            return
        }

        var attempts = 0
        for candidate in candidates {
            for stem in Self.stemVariants(candidate.stem) {
                guard attempts < Self.maxHTTPAttempts else { break }
                attempts += 1
                switch fetch(stem: stem, systemDirectory: systemDirectory) {
                case .image(let data):
                    let target = imageURL(forROMHash: game.romHash)
                    do {
                        try data.write(to: target, options: .atomic)
                    } catch {
                        finish(game, state: nil, method: nil)   // disk full etc.: retry later
                        return
                    }
                    finish(game,
                           state: candidate.method == "crc" ? Self.coverStateBoxArt
                                                            : Self.coverStateBoxArtHeuristic,
                           method: candidate.method)
                    return
                case .notFound:
                    continue
                case .transportFailure:
                    // Offline / timeout / server trouble: no verdict. Keep
                    // "placeholder" and let a later sweep retry.
                    finish(game, state: nil, method: nil)
                    return
                }
            }
        }
        finish(game, state: Self.coverStateNone, method: nil)
    }

    /// Identification, strongest tier first, deduplicated.
    private func candidates(for game: GameInput, system: ROMSystemType) -> [BoxArtCandidate] {
        let romURL = URL(fileURLWithPath: game.path)
        let filenameTitle = ROMImporter.cleanGameTitle(
            URL(fileURLWithPath: game.filename).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " "))
        // A library title that merely echoes the ROM header names the BASE
        // game for a ROM hack (patches keep the header), so it must not
        // drive identification. A title the user renamed in-app is their
        // declaration of what the game is — that one counts.
        let headerEcho = GBAROMParser.headerTitle(url: romURL, system: system)
            .map { ROMImporter.cleanGameTitle($0) == game.title } ?? false
        return Self.assembleCandidates(
            crcStem: Self.crc32(of: romURL).flatMap {
                BoxArtIndex.shared.exactName(crc32: $0, system: system)
            },
            serialStem: GBAROMParser.gameCode(url: romURL, system: system).flatMap {
                BoxArtIndex.shared.serialName($0, system: system)
            },
            filenameTitle: filenameTitle,
            userTitle: headerEcho ? nil : game.title,
            system: system,
            index: BoxArtIndex.shared)
    }

    /// Pure candidate assembly (internal: exercised directly by the tests).
    /// The hack rule lives here: a CRC match is byte-exact truth, but a
    /// serial names the BASE game even in a patched file, so without a CRC
    /// match it is accepted only when a user-chosen name (filename or
    /// in-app rename) agrees with it. Fuzzy queries use only those
    /// user-chosen names for the same reason. Failures point the safe way:
    /// a distinctly-named hack gets the screenshot, never the wrong cover.
    static func assembleCandidates(crcStem: String?, serialStem: String?,
                                   filenameTitle: String, userTitle: String?,
                                   system: ROMSystemType,
                                   index: BoxArtIndex) -> [BoxArtCandidate] {
        var identityTitles = [filenameTitle]
        if let userTitle, userTitle != filenameTitle { identityTitles.append(userTitle) }

        var result: [BoxArtCandidate] = []
        if let crcStem { result.append(BoxArtCandidate(stem: crcStem, method: "crc")) }
        if let serialStem, !result.contains(where: { $0.stem == serialStem }),
           crcStem != nil || identityTitles.contains(where: {
               BoxArtIndex.filenameIsConsistent($0, withStem: serialStem)
           }) {
            result.append(BoxArtCandidate(stem: serialStem, method: "serial"))
        }
        for stem in index.fuzzyCandidates(for: identityTitles,
                                          system: system,
                                          limit: fuzzyCandidateLimit)
        where !result.contains(where: { $0.stem == stem }) {
            result.append(BoxArtCandidate(stem: stem, method: "fuzzy"))
        }
        return result
    }

    /// The stem as-is, then (verified both ways on the live server) the same
    /// stem without its "(Rev N)" group — revision dumps whose base release
    /// is the one with a thumbnail are common.
    static func stemVariants(_ stem: String) -> [String] {
        let stripped = stem.replacingOccurrences(of: "\\s*\\(Rev[^)]*\\)", with: "",
                                                 options: .regularExpression)
        return stripped == stem ? [stem] : [stem, stripped]
    }

    static func thumbnailURL(stem: String, systemDirectory: String) -> URL {
        host.appendingPathComponent(systemDirectory)
            .appendingPathComponent("Named_Boxarts")
            .appendingPathComponent(stem + ".png")
    }

    private func fetch(stem: String, systemDirectory: String) -> FetchResult {
        let url = Self.thumbnailURL(stem: stem, systemDirectory: systemDirectory)
        var result: FetchResult = .transportFailure
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200, let data, data.count > 500,
                   UIImage(data: data) != nil {
                    result = .image(data)
                } else if http.statusCode == 404 {
                    result = .notFound
                }
                // Other statuses (5xx, 429, an HTML error page on 200)
                // stay .transportFailure: retry on a later sweep.
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }

    /// Persist the verdict on the main thread. `state` nil = no verdict
    /// (transport failure): only the in-flight guard is released.
    private func finish(_ game: GameInput, state: String?, method: String?) {
        DispatchQueue.main.async {
            self.inFlight.remove(game.romHash)
            self.attemptedThisLaunch.insert(game.romHash)
            guard let state else { return }

            let context = PersistenceController.shared.container.viewContext
            let request = NSFetchRequest<NSManagedObject>(entityName: "GameEntity")
            request.predicate = NSPredicate(format: "romHash == %@", game.romHash)
            request.fetchLimit = 1
            guard let entity = (try? context.fetch(request))?.first,
                  // The user may have set a custom cover while this resolve
                  // was in flight; their choice is never overwritten.
                  (entity.value(forKey: "coverType") as? String) != Self.coverStateCustom
            else { return }
            entity.setValue(state, forKey: "coverType")
            try? context.save()

            // One terminal signal per game ever (anonymous: outcome + tier +
            // console; never a title). Measures real-world match coverage.
            if state == Self.coverStateBoxArt || state == Self.coverStateBoxArtHeuristic,
               let method {
                Analytics.signal("boxart_match", ["result": "matched",
                                                  "method": method,
                                                  "system": game.system])
            } else if state == Self.coverStateNone {
                Analytics.signal("boxart_match", ["result": "no_match",
                                                  "system": game.system])
            }
        }
    }

    // MARK: - CRC32 (streamed; NDS ROMs can be 256 MB)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(of url: URL) -> UInt32? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var crc: UInt32 = 0xFFFF_FFFF
        var readAnything = false
        while true {
            let chunk = autoreleasepool { try? handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            readAnything = true
            chunk.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                for byte in buffer {
                    crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
                }
            }
        }
        return readAnything ? ~crc : nil
    }
}
