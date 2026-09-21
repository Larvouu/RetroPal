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
//    "boxart_heuristic" -> cover on disk, matched by serial/fuzzy
//    "ra"               -> the RetroAchievements game image, downloaded to
//                          disk once; it replaces a heuristic match or a
//                          no-match because RA identified the ACTUAL bytes
//                          (a base-named ROM hack gets its own art)
//    "none"             -> definitive no-match; screenshot stays
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
    /// bytes via hash) replaces this one when it becomes available.
    static let coverStateBoxArtHeuristic = "boxart_heuristic"
    /// The RetroAchievements game image, adopted as the persistent cover
    /// over a heuristic match or a no-match (RA identified the actual
    /// bytes, so it wins on hacks). On disk like any other cover: no
    /// network on display, stable offline, kept after an RA sign-out.
    /// Never adopted over a byte-exact CRC match or a custom cover.
    static let coverStateRA = "ra"
    static let coverStateNone = "none"
    /// The player CHOSE the downloaded box art (over an adopted RA image, or
    /// simply as a choice), from the cover chooser (2026-09-05). Like
    /// `custom`, a decision and not a verdict: no sweep, no adoption and no
    /// matching-rules bump overrides it. Only a missing file re-resolves.
    static let coverStateBoxArtChosen = "boxart_chosen"
    /// The player chose the living screenshot as the library cover. Same
    /// standing as `boxart_chosen`: nothing automatic overrides it, which is
    /// what tells it apart from `none`, the sweep's own "no match" verdict
    /// that RA adoption is allowed to upgrade.
    static let coverStateScreenshot = "screenshot"
    /// A cover the user picked themselves. Beats every automatic source,
    /// is never touched by sweeps or resolution-version resets, and is the
    /// answer for games no database covers (ROM hacks, homebrew).
    static let coverStateCustom = "custom"

    private static let host = URL(string: "https://thumbnails.libretro.com")!
    /// Which thumbnail directory each console's covers live in.
    ///
    /// It is also the gate for THIS path: a console missing from the map is
    /// stamped `none` without a lookup, whatever the bundled index holds. The
    /// Super Nintendo and the NES were missing from it from 1.2.5 until the
    /// PlayStation was added, so their 11,320 indexed names were never once
    /// queried and every download carried the data for nothing.
    ///
    /// They were NOT coverless, and the difference is worth being exact about,
    /// because getting it wrong once already hid the second half of the fix.
    /// RA adoption below is not gated by this map: a game RetroAchievements can
    /// identify gets its RA image, which looks like a cover and is one. So what
    /// those two consoles actually lacked was a cover for anyone NOT signed in
    /// to RA, for any game RA has no record of, and at IMPORT rather than after
    /// the first signed-in play.
    ///
    /// The names match `Tools/build_boxart_index.py`, which uses the same string
    /// for the DAT filename and for this directory, so a console indexed there
    /// can be fetched here.
    private static let systemDirectories: [ROMSystemType: String] = [
        .gb: "Nintendo - Game Boy",
        .gbc: "Nintendo - Game Boy Color",
        .gba: "Nintendo - Game Boy Advance",
        .nds: "Nintendo - Nintendo DS",
        .snes: "Nintendo - Super Nintendo Entertainment System",
        .nes: "Nintendo - Nintendo Entertainment System",
        .ps1: "Sony - PlayStation",
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
    /// Same once-per-launch semantics for RA cover adoption (its trigger,
    /// a terminal heuristic/none verdict plus an RA record, stays true
    /// forever, so without this an offline launch would retry every sweep).
    private var raAttemptedThisLaunch = Set<String>()

    /// Bump when the matching logic changes in a way that can OVERTURN old
    /// verdicts; the next sweep then resets every terminal state and
    /// re-resolves the whole library once. v2 = the ROM-hack rule (serial
    /// gated on filename consistency, header-echo titles dropped). v3 =
    /// verdicts split into exact ("boxart") vs heuristic
    /// ("boxart_heuristic") so the RA image can outrank the latter.
    /// v4 = the Super Nintendo, the NES and the PlayStation reached
    /// `systemDirectories` at last. Without this bump the fix would have been
    /// invisible on any library that already had them: a console the map did
    /// not list was stamped `none`, `none` is terminal, and terminal verdicts
    /// are never revisited. Adopted RA covers survive the reset by design, so
    /// a game already wearing RA art keeps it.
    private static let resolutionVersion = 4
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

    /// Where an adopted RA cover lives (separate file: the automatic
    /// <hash>.png it outranked, e.g. a heuristic match, may coexist).
    func raImageURL(forROMHash romHash: String) -> URL {
        directory.appendingPathComponent(romHash + "-ra").appendingPathExtension("png")
    }

    /// The game's local cover file by priority: the user-picked custom cover
    /// beats the adopted RA image (which BoxArtManager only grants over a
    /// heuristic match or a no-match — never over a byte-exact CRC match),
    /// which beats the downloaded one. nil when the game has no cover state.
    /// Single source of truth for every cover consumer (library rows, the
    /// slot-2 picker, the NDS dress slot-2 square).
    func coverFileURL(forROMHash romHash: String?, coverType: String?) -> URL? {
        guard let romHash else { return nil }
        switch coverType {
        case Self.coverStateCustom:
            return customImageURL(forROMHash: romHash)
        case Self.coverStateRA:
            return raImageURL(forROMHash: romHash)
        case Self.coverStateBoxArt, Self.coverStateBoxArtHeuristic, Self.coverStateBoxArtChosen:
            return imageURL(forROMHash: romHash)
        default:
            return nil
        }
    }

    // MARK: - The player's choice (main thread; called from the cover chooser)

    /// Whether the downloaded box art exists on disk for this game.
    func hasDownloadedArt(forROMHash romHash: String) -> Bool {
        FileManager.default.fileExists(atPath: imageURL(forROMHash: romHash).path)
    }

    /// Whether the RetroAchievements image exists on disk for this game.
    func hasRAArt(forROMHash romHash: String) -> Bool {
        FileManager.default.fileExists(atPath: raImageURL(forROMHash: romHash).path)
    }

    /// The RetroAchievements image this game could show, when RA has one and
    /// it is not the generic controller placeholder.
    func raArtURL(forROMHash romHash: String) -> URL? {
        guard let art = RAGameIndex.shared.record(forROMHash: romHash)?.boxArtURL,
              !art.hasSuffix("/000001.png") else { return nil }
        return URL(string: art)
    }

    /// The player picked one of the covers already on disk, or the
    /// screenshot. `state` is `boxart_chosen`, `ra` or `screenshot`.
    func choose(coverState state: String, for game: NSManagedObject) {
        game.setValue(state, forKey: "coverType")
        try? game.managedObjectContext?.save()
    }

    /// The player picked the RetroAchievements image. Present on disk, it is
    /// chosen at once; absent (the sweep never adopts over a byte-exact box
    /// art match, so a CRC-matched game has none), it is fetched once, then
    /// chosen. `completion(false)` means nothing could be fetched, which the
    /// caller must say out loud.
    func chooseRAArt(for game: NSManagedObject, completion: @escaping (Bool) -> Void) {
        guard let romHash = game.value(forKey: "romHash") as? String else { completion(false); return }
        if hasRAArt(forROMHash: romHash) {
            choose(coverState: Self.coverStateRA, for: game)
            completion(true)
            return
        }
        guard let url = raArtURL(forROMHash: romHash) else { completion(false); return }
        let target = raImageURL(forROMHash: romHash)
        workQueue.async { [weak self] in
            guard let self else { return }
            var written = false
            if case .image(let data) = self.fetch(url: url) {
                written = (try? data.write(to: target, options: .atomic)) != nil
            }
            DispatchQueue.main.async {
                if written { self.choose(coverState: Self.coverStateRA, for: game) }
                completion(written)
            }
        }
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
        try? FileManager.default.removeItem(at: raImageURL(forROMHash: romHash))
        game.setValue(Self.coverStatePlaceholder, forKey: "coverType")
        try? game.managedObjectContext?.save()
        // Let the next sweep re-resolve right away (this launch may already
        // have attempted the game before the custom cover was set).
        attemptedThisLaunch.remove(romHash)
        raAttemptedThisLaunch.remove(romHash)
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
                // Downloaded covers are <hash>.png, adopted RA covers are
                // <hash>-ra.png, user-picked ones are <hash>-custom.jpg;
                // all leave with their game.
                let stem = file.deletingPathExtension().lastPathComponent
                var romHash = stem
                for suffix in ["-custom", "-ra"] where stem.hasSuffix(suffix) {
                    romHash = String(stem.dropLast(suffix.count))
                }
                if !keep.contains(romHash) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }

        for game in games {
            guard game.coverState != Self.coverStateNone,
                  game.coverState != Self.coverStateCustom,
                  game.coverState != Self.coverStateRA,
                  game.coverState != Self.coverStateScreenshot,
                  !FileManager.default.fileExists(atPath: imageURL(forROMHash: game.romHash).path),
                  !inFlight.contains(game.romHash),
                  !attemptedThisLaunch.contains(game.romHash)
            else { continue }
            // "boxart" with no file on disk (restore to a new device) falls
            // through here and simply re-resolves.
            inFlight.insert(game.romHash)
            workQueue.async { [weak self] in self?.resolve(game) }
        }

        // RA cover adoption: a terminal heuristic match or no-match upgrades
        // to the RA game image once RA has identified the game's bytes (the
        // record arrives with the first signed-in play, so this typically
        // fires on the next library refresh). The image is downloaded ONCE
        // to disk and the game flips to "ra": the row then renders a local
        // file — no per-launch network, no flash against the old cover, and
        // it still shows offline. An "ra" game whose file is gone (restore
        // to a new device) re-downloads the same way. A byte-exact CRC match
        // or a custom cover is never overridden.
        for game in games {
            let overridable = game.coverState == Self.coverStateNone
                || game.coverState == Self.coverStateBoxArtHeuristic
            let fileMissing = !FileManager.default.fileExists(
                atPath: raImageURL(forROMHash: game.romHash).path)
            guard overridable || (game.coverState == Self.coverStateRA && fileMissing),
                  !inFlight.contains(game.romHash),
                  !raAttemptedThisLaunch.contains(game.romHash),
                  let art = RAGameIndex.shared.record(forROMHash: game.romHash)?.boxArtURL,
                  // Never RA's generic controller placeholder (games with no
                  // RA image, e.g. homebrew): the current cover stays.
                  !art.hasSuffix("/000001.png"),
                  let url = URL(string: art)
            else { continue }
            inFlight.insert(game.romHash)
            workQueue.async { [weak self] in self?.adoptRAArt(game, from: url) }
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
        // a matching-logic bump must never touch them. Adopted RA covers come
        // from RA's byte-hash identification, not our matching rules, so a
        // matching-logic bump can't overturn them either.
        request.predicate = NSPredicate(format: "coverType != %@ AND coverType != %@ AND coverType != %@ AND coverType != %@ AND coverType != %@",
                                        Self.coverStatePlaceholder, Self.coverStateCustom,
                                        Self.coverStateRA, Self.coverStateBoxArtChosen,
                                        Self.coverStateScreenshot)
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
        fetch(url: Self.thumbnailURL(stem: stem, systemDirectory: systemDirectory))
    }

    private func fetch(url: URL) -> FetchResult {
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
            guard let entity = (try? context.fetch(request))?.first else { return }
            let current = entity.value(forKey: "coverType") as? String
            // The user may have set a custom cover while this resolve was in
            // flight; their choice is never overwritten. An adopted RA cover
            // yields only to a byte-exact CRC match (defensive: inFlight
            // serializes resolve and adoption per game, so they can't race).
            guard current != Self.coverStateCustom,
                  current != Self.coverStateBoxArtChosen,
                  current != Self.coverStateScreenshot,
                  current != Self.coverStateRA || state == Self.coverStateBoxArt
            else { return }
            entity.setValue(state, forKey: "coverType")
            try? context.save()

            // `boxart_match` was removed 2026-08-27. It fired once per game per
            // user, so a fifty-game library sent fifty events, and the coverage
            // dashboard it fed was deliberately never built: there is no lever
            // to pull on the result. It was paying a volume cost for an answer
            // nobody reads. The build-on-complaint trigger in the analytics
            // plan is unchanged and needs no signal to fire.
        }
    }

    // MARK: - RA cover adoption (work queue, one game at a time)

    /// Downloads the RA game image to disk (skipped if a previous attempt
    /// already wrote it) and flips the game to "ra" on the main thread.
    /// Mirrors resolve()'s retry semantics: one attempt per launch, and a
    /// failed download just leaves the current cover; the next launch's
    /// sweep tries again (the trigger, a terminal heuristic/none verdict
    /// plus an RA record, stays true until adoption succeeds).
    private func adoptRAArt(_ game: GameInput, from url: URL) {
        let target = raImageURL(forROMHash: game.romHash)
        var adopted = FileManager.default.fileExists(atPath: target.path)
        if !adopted, case .image(let data) = fetch(url: url) {
            do {
                try data.write(to: target, options: .atomic)
                adopted = true
            } catch {}
        }
        DispatchQueue.main.async {
            self.inFlight.remove(game.romHash)
            self.raAttemptedThisLaunch.insert(game.romHash)
            guard adopted else { return }

            let context = PersistenceController.shared.container.viewContext
            let request = NSFetchRequest<NSManagedObject>(entityName: "GameEntity")
            request.predicate = NSPredicate(format: "romHash == %@", game.romHash)
            request.fetchLimit = 1
            guard let entity = (try? context.fetch(request))?.first else { return }
            // Only the states this adoption was allowed to beat; anything
            // set meanwhile (a custom cover, a CRC re-resolve) wins.
            switch entity.value(forKey: "coverType") as? String {
            case Self.coverStateNone, Self.coverStateBoxArtHeuristic:
                entity.setValue(Self.coverStateRA, forKey: "coverType")
                try? context.save()
            default:
                break
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
