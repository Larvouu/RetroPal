//
//  DiscConsoleTests.swift
//  EmulateurGBATests
//
//  Which of the two disc consoles a disc image belongs to (2026-10-12). A
//  fan-translated Kingdom Hearts Birth by Sleep `.chd` imported as a
//  PlayStation game and could not start: every `.chd` was filed under the
//  PlayStation unread. Now a `.chd` is read like an `.iso` (`PSPDiscProbe`,
//  through the achievements' own disc reader): one holding 2048-byte sectors
//  whose volume says "PSP GAME" or carries PSP_GAME is the PSP's, a raw CD
//  track or a "PLAYSTATION" volume is the PlayStation's, and anything else is
//  UNDECIDED, which the importer asks the player about and records in the
//  game's folder, where every later reader finds it.
//
//  The CHDs are synthesised here, uncompressed, from libchdr's own v5 layout
//  (as Tools/disc-reader-test/make_chd.py does), so the tests carry no files
//  and run on a device as well as the simulator. Compressed ones written by
//  chdman (createdvd and createcd, from a PSP and a PlayStation image) were
//  run through the same C code on the Linux bench on 2026-10-12, a 1.5 GB
//  DVD image among them.
//

import Testing
import Foundation
import CoreData
@testable import EmulateurGBA

@Suite("Disc console")
struct DiscConsoleTests {

    // MARK: - Images

    /// An ISO 9660 image of 24 sectors whose volume (sector 16) names
    /// `systemID`, and whose root directory (sector 18) holds `rootEntry`.
    private func makeISO(systemID: String, rootEntry: String? = nil) -> Data {
        var bytes = [UInt8](repeating: 0, count: 24 * 2048)
        let pvd = 16 * 2048
        bytes[pvd] = 1
        for (i, b) in Array("CD001".utf8).enumerated() { bytes[pvd + 1 + i] = b }
        var system = Array(systemID.utf8).prefix(32).map { $0 }
        system += [UInt8](repeating: 0x20, count: 32 - system.count)
        for (i, b) in system.enumerated() { bytes[pvd + 8 + i] = b }
        let root = pvd + 156
        bytes[root] = 34
        bytes[root + 2] = 18          // extent, little-endian
        bytes[root + 11] = 0x08       // length 2048, little-endian
        if let name = rootEntry {
            let dir = 18 * 2048
            let nameBytes = Array(name.utf8)
            bytes[dir] = UInt8(33 + nameBytes.count + (nameBytes.count % 2 == 0 ? 1 : 0))
            bytes[dir + 32] = UInt8(nameBytes.count)
            for (i, b) in nameBytes.enumerated() { bytes[dir + 33 + i] = b }
        }
        return Data(bytes)
    }

    private enum CHDKind {
        /// `chdman createdvd`: 2048-byte units, the DVD tag. How a UMD becomes a `.chd`.
        case dvd
        /// `chdman createcd` from a plain `.iso`: MODE1, the 2048 bytes first in each frame.
        case cookedCD
        /// `chdman createcd` from a `.cue`: MODE1_RAW, 2352-byte sectors. Every PlayStation `.chd`.
        case rawCD
    }

    /// An uncompressed CHD v5 holding `iso`, laid out as libchdr reads one:
    /// a 124-byte header, a map of big-endian hunk indices (codec none), the
    /// hunks on a hunk boundary, then one metadata record.
    private func makeCHD(_ iso: Data, _ kind: CHDKind) -> Data {
        let sectors = iso.count / 2048
        func sector(_ i: Int) -> [UInt8] { Array(iso[(i * 2048)..<((i + 1) * 2048)]) }
        var units: [UInt8] = []
        let unitBytes: Int
        let tag: UInt32
        var meta: [UInt8]
        switch kind {
        case .dvd:
            unitBytes = 2048
            for i in 0..<sectors { units += sector(i) }
            tag = 0x4456_4420                                      // "DVD "
            meta = [0]
        case .cookedCD, .rawCD:
            unitBytes = 2448
            for i in 0..<sectors {
                if kind == .cookedCD {
                    units += sector(i) + [UInt8](repeating: 0, count: 400)
                } else {
                    let sync: [UInt8] = [0x00] + [UInt8](repeating: 0xFF, count: 10) + [0x00]
                    units += sync + [0, 2, UInt8(i & 0xFF), 1] + sector(i)
                    units += [UInt8](repeating: 0, count: 288 + 96)
                }
            }
            tag = 0x4348_5432                                      // "CHT2"
            let type = kind == .cookedCD ? "MODE1" : "MODE1_RAW"
            meta = Array("TRACK:1 TYPE:\(type) SUBTYPE:NONE FRAMES:\(sectors) PREGAP:0 PGTYPE:MODE1 PGSUB:NONE POSTGAP:0".utf8) + [0]
        }
        let hunkBytes = unitBytes * 8
        let hunks = (units.count + hunkBytes - 1) / hunkBytes
        units += [UInt8](repeating: 0, count: hunks * hunkBytes - units.count)
        let header = 124
        var dataOffset = header + hunks * 4
        let pad = (hunkBytes - dataOffset % hunkBytes) % hunkBytes
        dataOffset += pad
        let metaOffset = dataOffset + hunks * hunkBytes

        func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * (3 - $0))) & 0xFF) } }
        func be64(_ v: Int) -> [UInt8] { be32(0) + be32(v) }
        var out = [UInt8](repeating: 0, count: header)
        func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { out[offset + i] = b } }
        put(Array("MComprHD".utf8), at: 0)
        put(be32(header), at: 8)
        put(be32(5), at: 12)
        put(be64(kind == .dvd ? sectors * 2048 : hunks * hunkBytes), at: 32)   // logical bytes
        put(be64(header), at: 40)                                              // map
        put(be64(metaOffset), at: 48)                                          // metadata
        put(be32(hunkBytes), at: 56)
        put(be32(unitBytes), at: 60)
        let first = dataOffset / hunkBytes
        for i in 0..<hunks { out += be32(first + i) }
        out += [UInt8](repeating: 0, count: pad)
        out += units
        out += be32(Int(tag)) + be32(meta.count) + be64(0) + meta
        return Data(out)
    }

    private func temp(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("discconsole-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - What the bytes say

    @Test func aPSPDiscMadeIntoACHDIsThePSPs() throws {
        let iso = makeISO(systemID: "PSP GAME")
        #expect(ROMSystemType.resolve(url: try temp("UMD.chd", makeCHD(iso, .dvd))) == .psp)
        #expect(ROMSystemType.resolve(url: try temp("UMD.CHD", makeCHD(iso, .dvd))) == .psp)
        // Made from the `.iso` with createcd rather than createdvd: PPSSPP reads
        // it the same way, and so does the probe.
        #expect(ROMSystemType.resolve(url: try temp("UMD cd.chd", makeCHD(iso, .cookedCD))) == .psp)
        // A volume with another name that carries PSP_GAME, as PPSSPP accepts.
        let folder = makeISO(systemID: "UMD VIDEO", rootEntry: "PSP_GAME")
        #expect(ROMSystemType.resolve(url: try temp("Video.chd", makeCHD(folder, .dvd))) == .psp)
    }

    @Test func aPlayStationCHDStaysThePlayStations() throws {
        let iso = makeISO(systemID: "PLAYSTATION")
        // The ordinary one: a raw CD track, as every PlayStation `.chd` is.
        let raw = try temp("Disc.chd", makeCHD(iso, .rawCD))
        #expect(ROMSystemType.resolve(url: raw) == .ps1)
        #expect(!ROMSystemType.consoleIsUndecided(url: raw))
        // A PlayStation volume however it was packed.
        #expect(ROMSystemType.resolve(url: try temp("Cooked.chd", makeCHD(iso, .cookedCD))) == .ps1)
        #expect(ROMSystemType.resolve(url: try temp("Dvd.chd", makeCHD(iso, .dvd))) == .ps1)
        // Any raw CD track, whatever its volume says: a UMD is never one.
        let other = try temp("Other raw.chd", makeCHD(makeISO(systemID: "SOMETHING ELSE"), .rawCD))
        #expect(ROMSystemType.resolve(url: other) == .ps1)
        #expect(!ROMSystemType.consoleIsUndecided(url: other))
    }

    /// Neither "PLAYSTATION" nor PSP_GAME in a 2048-byte volume, or a file
    /// that cannot be read: the bytes do not say, so the importer asks.
    @Test func anImageThatNamesNeitherConsoleIsUndecided() throws {
        let iso = makeISO(systemID: "SOMETHING ELSE", rootEntry: "DATA")
        for url in [try temp("Odd.chd", makeCHD(iso, .dvd)),
                    try temp("Odd cd.chd", makeCHD(iso, .cookedCD)),
                    try temp("Odd.iso", iso),
                    try temp("Broken.chd", Data("MComprHD".utf8) + Data(count: 200))] {
            #expect(ROMSystemType.consoleIsUndecided(url: url), "an image that names neither console was decided")
            // Until the player answers, the extension's answer stands.
            #expect(ROMSystemType.resolve(url: url) == .ps1)
        }
        // A PSP or PlayStation image is never undecided.
        #expect(!ROMSystemType.consoleIsUndecided(url: try temp("P.iso", makeISO(systemID: "PSP GAME"))))
        #expect(!ROMSystemType.consoleIsUndecided(url: try temp("S.iso", makeISO(systemID: "PLAYSTATION"))))
        // A cartridge never is.
        #expect(!ROMSystemType.consoleIsUndecided(url: try temp("G.gba", Data(count: 256))))
    }

    /// The player's answer, written beside the image, decides from then on,
    /// for every reader: the importer, the session, the pad, the achievements.
    @Test func theRecordedChoiceDecidesAnUndecidedImage() throws {
        let image = try temp("Odd.chd", makeCHD(makeISO(systemID: "SOMETHING ELSE"), .dvd))
        let choice = image.deletingLastPathComponent().appendingPathComponent(ROMSystemType.consoleChoiceFileName)
        try Data("psp".utf8).write(to: choice)
        #expect(ROMSystemType.resolve(url: image) == .psp)
        // RetroAchievements' console numbers: PSP 41, PlayStation 12.
        #expect(RAClient.consoleId(forROMPath: image.path) == 41, "the achievements did not follow the recorded choice")
        try Data("ps1".utf8).write(to: choice)
        #expect(ROMSystemType.resolve(url: image) == .ps1)
        #expect(RAClient.consoleId(forROMPath: image.path) == 12)
        // A choice never overrides what the bytes DO say.
        let ps1 = choice.deletingLastPathComponent().appendingPathComponent("Real.chd")
        try makeCHD(makeISO(systemID: "PLAYSTATION"), .rawCD).write(to: ps1)
        try Data("psp".utf8).write(to: choice)
        #expect(ROMSystemType.resolve(url: ps1) == .ps1)
    }

    // MARK: - Import

    private func importer() -> (ROMImporter, NSManagedObjectContext) {
        let context = PersistenceController(inMemory: true).container.viewContext
        return (ROMImporter(context: context), context)
    }

    private func removeFolder(of id: NSManagedObjectID, _ importer: ROMImporter, _ context: NSManagedObjectContext) {
        guard let game = try? context.existingObject(with: id),
              let path = game.value(forKey: "romFilePath") as? String,
              let folder = DiscStorage.gameFolder(forROMAt: importer.romURL(for: path)) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The case that was reported: a PSP `.chd` imports as a PSP game, with
    /// no question asked.
    @Test func aPSPCHDImportsAsAPSPGameUnasked() throws {
        let (importer, context) = importer()
        var asked = false
        importer.askConsole = { _ in asked = true; return .ps1 }
        let url = try temp("Test UMD \(UUID().uuidString.prefix(6)).chd",
                           makeCHD(makeISO(systemID: "PSP GAME"), .dvd))
        let id = try importer.importROM(from: url, method: "picker")
        defer { removeFolder(of: id, importer, context) }
        #expect(try context.existingObject(with: id).value(forKey: "systemType") as? String == "psp")
        #expect(!asked, "a PSP image whose bytes say so was asked about")
    }

    @Test func aPlayStationCHDImportsAsAPlayStationGameUnasked() throws {
        let (importer, context) = importer()
        var asked = false
        importer.askConsole = { _ in asked = true; return .psp }
        let url = try temp("Test PS1 \(UUID().uuidString.prefix(6)).chd",
                           makeCHD(makeISO(systemID: "PLAYSTATION"), .rawCD))
        let id = try importer.importROM(from: url, method: "picker")
        defer { removeFolder(of: id, importer, context) }
        #expect(try context.existingObject(with: id).value(forKey: "systemType") as? String == "ps1")
        #expect(!asked, "a PlayStation image whose bytes say so was asked about")
    }

    /// Undecided: the player is asked once, with the file's name; the answer
    /// files the game, and is recorded so the core, the pad and the
    /// achievements read the same console.
    @Test func anUndecidedImageIsAskedAndTheAnswerHolds() throws {
        for answer in [ROMSystemType.psp, .ps1] {
            let (importer, context) = importer()
            var questions: [String] = []
            importer.askConsole = { name in questions.append(name); return answer }
            let name = "Test Odd \(UUID().uuidString.prefix(6)).chd"
            let url = try temp(name, makeCHD(makeISO(systemID: "SOMETHING ELSE"), .dvd))
            let id = try importer.importROM(from: url, method: "picker")
            defer { removeFolder(of: id, importer, context) }
            #expect(questions == [name])
            let game = try context.existingObject(with: id)
            #expect(game.value(forKey: "systemType") as? String == answer.rawValue)
            let path = try #require(game.value(forKey: "romFilePath") as? String)
            let installed = importer.romURL(for: path)
            #expect(ROMSystemType.resolve(url: installed) == answer, "the installed game reads another console")
            // The folder's recorded size includes the answer, so the launch
            // preflight does not call the game damaged.
            #expect(DiscStorage.installedSize(ofROMAt: installed) == game.value(forKey: "romSize") as? Int64)
        }
    }

    /// Cancel imports nothing: no entry, no folder, no error to show.
    @Test func cancellingTheQuestionImportsNothing() throws {
        let (importer, context) = importer()
        importer.askConsole = { _ in nil }
        let name = "Test Cancel \(UUID().uuidString.prefix(6))"
        let url = try temp(name + ".iso", makeISO(systemID: "SOMETHING ELSE"))
        do {
            _ = try importer.importROM(from: url, method: "picker")
            Issue.record("cancelling the question still imported the game")
        } catch ROMImportError.consoleChoiceCancelled {
            // expected
        } catch {
            Issue.record("cancelling threw \(error), not consoleChoiceCancelled")
        }
        #expect(ROMImportError.consoleChoiceCancelled.errorDescription == nil)
        let games = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "GameEntity"))
        #expect(games.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: importer.romURL(for: name).path))
    }

    /// No one to ask (the tests, a path with no screen): an undecided image
    /// imports as the PlayStation's, as every one did before.
    @Test func withNoOneToAskAnUndecidedImageIsThePlayStations() throws {
        let (importer, context) = importer()
        let url = try temp("Test Unasked \(UUID().uuidString.prefix(6)).chd",
                           makeCHD(makeISO(systemID: "SOMETHING ELSE"), .dvd))
        let id = try importer.importROM(from: url, method: "picker")
        defer { removeFolder(of: id, importer, context) }
        #expect(try context.existingObject(with: id).value(forKey: "systemType") as? String == "ps1")
    }

    // MARK: - The question

    @Test func theQuestionIsWrittenInEveryLanguage() {
        for key in ["import.console.title", "import.console.message"] {
            #expect(NSLocalizedString(key, comment: "") != key, "\(key)")
        }
        #expect(NSLocalizedString("import.console.message", comment: "").contains("%@"))
    }

    // MARK: - Other consoles' discs and misnamed cartridges (audit 2026-10-12)

    /// An ISO 9660 image of 40 sectors: volume (sector 16) naming `systemID`,
    /// root directory (sector 18) listing `files`, each file's bytes from
    /// sector 20 on, one sector apiece. Sector 0 opens with `sector0` when given.
    private func makeDisc(systemID: String, files: [(String, Data)], sector0: String? = nil) -> Data {
        var bytes = [UInt8](repeating: 0, count: 40 * 2048)
        if let sector0 { for (i, b) in Array(sector0.utf8).enumerated() { bytes[i] = b } }
        let pvd = 16 * 2048
        bytes[pvd] = 1
        for (i, b) in Array("CD001".utf8).enumerated() { bytes[pvd + 1 + i] = b }
        var system = Array(systemID.utf8).prefix(32).map { $0 }
        system += [UInt8](repeating: 0x20, count: 32 - system.count)
        for (i, b) in system.enumerated() { bytes[pvd + 8 + i] = b }
        bytes[pvd + 128] = 0x00; bytes[pvd + 129] = 0x08               // logical block 2048
        let root = pvd + 156
        bytes[root] = 34
        bytes[root + 2] = 18
        bytes[root + 11] = 0x08
        var at = 18 * 2048
        for (n, (name, data)) in files.enumerated() {
            let nameBytes = Array(name.utf8)
            let length = 33 + nameBytes.count + (nameBytes.count % 2 == 0 ? 1 : 0)
            let sector = 20 + n
            bytes[at] = UInt8(length)
            bytes[at + 2] = UInt8(sector)
            bytes[at + 10] = UInt8(data.count & 0xFF); bytes[at + 11] = UInt8((data.count >> 8) & 0xFF)
            bytes[at + 32] = UInt8(nameBytes.count)
            for (i, b) in nameBytes.enumerated() { bytes[at + 33 + i] = b }
            for (i, b) in data.prefix(2048).enumerated() { bytes[sector * 2048 + i] = b }
            at += length
        }
        return Data(bytes)
    }

    private var playStationDisc: Data {
        makeDisc(systemID: "PLAYSTATION", files: [("SYSTEM.CNF;1", Data("BOOT = cdrom:\\SLUS_000.01;1\r\n".utf8)),
                                                   ("SLUS_000.01;1", Data("PS-X EXE".utf8))])
    }

    @Test func otherConsolesDiscsAreRecognisedInEveryContainer() throws {
        let ps2 = makeDisc(systemID: "PLAYSTATION", files: [("SYSTEM.CNF;1", Data("BOOT2 = cdrom0:\\SLUS_200.01;1\r\nVER = 1.00\r\n".utf8))])
        let segaCD = makeDisc(systemID: "SEGA", files: [], sector0: "SEGADISCSYSTEM  ")
        let saturn = makeDisc(systemID: "SEGA SEGASATURN", files: [], sector0: "SEGA SEGASATURN ")
        for (name, disc) in [("PS2", ps2), ("Sega CD", segaCD), ("Saturn", saturn)] {
            #expect(RAClient.isOtherConsolesDisc(atPath: try temp("\(name).iso", disc).path), "\(name) .iso was taken for a PlayStation disc")
            #expect(RAClient.isOtherConsolesDisc(atPath: try temp("\(name).chd", makeCHD(disc, .cookedCD)).path), "\(name) .chd was taken for a PlayStation disc")
        }
        // A PlayStation disc, however it is packed, never is; nor is a disc
        // that cannot be read, which gets the benefit of the doubt.
        #expect(!RAClient.isOtherConsolesDisc(atPath: try temp("PS1.iso", playStationDisc).path))
        #expect(!RAClient.isOtherConsolesDisc(atPath: try temp("PS1.chd", makeCHD(playStationDisc, .rawCD)).path))
        #expect(!RAClient.isOtherConsolesDisc(atPath: try temp("Junk.iso", Data(count: 4096)).path))
        #expect(!RAClient.isOtherConsolesDisc(atPath: "/nonexistent/Game.cue"))
        // A disc that boots on both (BOOT and BOOT2) stays the PlayStation's.
        let both = makeDisc(systemID: "PLAYSTATION", files: [("SYSTEM.CNF;1", Data("BOOT2 = cdrom0:\\A;1\r\nBOOT = cdrom:\\B;1\r\n".utf8))])
        #expect(!RAClient.isOtherConsolesDisc(atPath: try temp("Both.iso", both).path))
    }

    @Test func anotherConsolesDiscIsRefusedAtImportWithoutAQuestion() throws {
        let (importer, context) = importer()
        var asked = false
        importer.askConsole = { _ in asked = true; return .ps1 }
        let ps2 = makeDisc(systemID: "PLAYSTATION", files: [("SYSTEM.CNF;1", Data("BOOT2 = cdrom0:\\SLUS_200.01;1\r\n".utf8))])
        let url = try temp("Test PS2 \(UUID().uuidString.prefix(6)).chd", makeCHD(ps2, .dvd))
        #expect(throws: ROMImportError.self) { _ = try importer.importROM(from: url, method: "picker") }
        // Its own reason, apart from a broken disc's, so demand can be read.
        #expect(ErrorTelemetry.importReason(for: ROMImportError.invalidROM, noted: importer.takeFailureCause())
                == .otherConsoleDisc)
        #expect(!asked)
        #expect(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "GameEntity")) == 0)
    }

    /// A cartridge whose bytes are another console's than its extension says
    /// is stored under the console's own, so the core, the pad and the
    /// achievements, which read the extension, agree with the library.
    @Test func aMisnamedCartridgeIsStoredUnderItsConsolesExtension() throws {
        var n64 = [UInt8](repeating: 0, count: 0x1000)
        n64[0] = 0x80; n64[1] = 0x37; n64[2] = 0x12; n64[3] = 0x40
        #expect(GBAROMParser.storedCartridgeName(for: try temp("Mario.gba", Data(n64))) == "Mario.z64")
        #expect(GBAROMParser.storedCartridgeName(for: try temp("Zelda.sfc", ImportFixtures.nesROM(seed: 3))) == "Zelda.nes")
        // Correctly named: untouched.
        #expect(GBAROMParser.storedCartridgeName(for: try temp("Game.gba", ImportFixtures.gbaROM())) == "Game.gba")
        #expect(GBAROMParser.storedCartridgeName(for: try temp("Mario.n64", Data(n64))) == "Mario.n64")
        // The Master System and the Game Gear are told apart by the extension
        // alone: never renamed.
        #expect(GBAROMParser.storedCartridgeName(for: try temp("Game.gg", ImportFixtures.nesROM(seed: 4))) == "Game.gg")
    }

    @Test func a32XOrPicoCartridgeIsNotAMegaDriveGame() {
        func header(_ system: String) -> Data {
            var b = [UInt8](repeating: 0x20, count: 0x400)
            for (i, c) in Array(system.utf8).enumerated() { b[0x100 + i] = c }
            return Data(b)
        }
        #expect(GBAROMParser.isValidMDFile(data: header("SEGA MEGA DRIVE")))
        #expect(GBAROMParser.isValidMDFile(data: header("SEGA GENESIS")))
        #expect(!GBAROMParser.isValidMDFile(data: header("SEGA 32X")))
        #expect(!GBAROMParser.isValidMDFile(data: header("SEGA PICO")))
    }

    /// The telemetry names a refused 32X cartridge as such, and a plain bad
    /// dump as before; both values pass the anonymity gate.
    @Test func aRefused32XCartridgeIsReportedAsAnotherConsole() throws {
        var bytes = [UInt8](repeating: 0x20, count: 0x400)
        for (i, c) in Array("SEGA 32X".utf8).enumerated() { bytes[0x100 + i] = c }
        #expect(ErrorTelemetry.invalidFileCause(try temp("Doom.md", Data(bytes))) == .otherConsoleCartridge)
        #expect(ErrorTelemetry.invalidFileCause(try temp("Bad.md", Data(count: 0x400))) == .invalidHeader)
        for reason in [ImportFailureReason.otherConsoleDisc, .otherConsoleCartridge] {
            #expect(Analytics.sanitized(["reason": reason.rawValue])["reason"] == reason.rawValue)
        }
        #expect(Analytics.sanitized(["result": "cancelled", "method": "url"]) == ["result": "cancelled", "method": "url"])
    }
}
