//
//  ArchiveImportTests.swift
//  EmulateurGBATests
//
//  The phone checks of 1.3.5 that a test can carry instead (his ask of
//  2026-10-30: "could tests make sure any of those points work, or at least
//  catch a bug?").
//
//  ARCHIVES. Every format the importer offers since 1.3.5 (`GameArchive`), one
//  tiny archive each, through `ROMImporter` exactly as a player's import goes:
//  the game must land in the library, and a password-protected archive must be
//  refused by name. The archives hold the tests' own synthetic Game Boy Advance
//  header (192 bytes, no game), built 2026-10-30 with 7-Zip, tar, gzip and xz
//  and embedded below as base64 so nothing binary enters the repository. Each
//  was first run on the host through the app's own GameArchiveReader.c over its
//  prelinked libarchive: every one listed and extracted 192 bytes, the
//  password one listed as encrypted and was refused (status 2). RAR cannot be
//  CREATED without RARLAB's own tool, so a .rar stays a check on the phone.
//
//  GAME MODE. The two Info.plist keys that turn it on (iOS 18 and iOS 26).
//  Lost in a project-file merge, the banner simply stops appearing and
//  nothing else says so.
//

import Testing
import Foundation
import CoreData
@testable import EmulateurGBA

@Suite("Archive import, every format", .serialized)
struct ArchiveImportTests {

    /// The archives, by the name each is written under. A lone .gz / .xz names
    /// its one file after itself (`RetroPalArchiveTest.gba.gz` gives
    /// `RetroPalArchiveTest.gba`), as the reader documents.
    static let archives: [(name: String, base64: String)] = [
        ("RetroPalArchiveTest.7z", "N3q8ryccAAQySgrkHwAAAAAAAAB6AAAAAAAAAApGqtXgAL8AF10AAG8YhMAMLYF3gDmffq+lROxEswZ2kwAAAQQGAAEJHwAHCwEAASEhAQAMgMAACAoBrpFi2QAABQEZCwAAAAAAAAAAAAAAETEAUgBlAHQAcgBvAFAAYQBsAEEAcgBjAGgAaQB2AGUAVABlAHMAdAAuAGcAYgBhAAAAGQIAABQKAQB804F+1WfdARUGAQAggKSBAAA="),
        ("RetroPalArchiveTest-lzma.zip", "UEsDBD8AAgAOAIeVXV2ukWLZJgAAAMAAAAAXAAAAUmV0cm9QYWxBcmNoaXZlVGVzdC5nYmEXAQUAXQAQAAAAAG8YhMAMLYF3gDmffq+lROxEswvGL////W1wAFBLAQI/Az8AAgAOAIeVXV2ukWLZJgAAAMAAAAAXACQAAAAAAAAAIICkgQAAAABSZXRyb1BhbEFyY2hpdmVUZXN0LmdiYQoAIAAAAAAAAQAYAHzTgX7VZ90BAAAAAAAAAAAAAAAAAAAAAFBLBQYAAAAAAQABAGkAAABbAAAAAAA="),
        ("RetroPalArchiveTest.tar.gz", "H4sIAAAAAAAAA+3OQQrCMBCF4RwlJ5Ckps26SMHupAb3UYIKQiCNHsXzGsSVoG4quvi/zRtmZvGGkFNc+VObdofjJbgw5tl+68WUVNEYc8/iOdW8zLqurLJaW1sLpY2uGiHVpC1eOI/ZJylFijG/+/t0x1e0w2LZbzrXrd1jc/1pHwAAAAAAAAAAAAAAAAD4FzdDG5cDACgAAA=="),
        ("RetroPalArchiveTest.tar.xz", "/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4Cf/AIddACkZSodGylUA4hACVDxcuYufE+7J7CxGuUtL7wdWFmGPduo2Gtc8VZHVQU/U3gleGyAiz0sZmuF7674M+rBMhS1vJt/HcxN6r7s/7bwGNHN18/PUoGvAsQl8s7+L6INj2S0SuW+2SSlPTUvx1c7LIZx1S2f0+Vv/05fbP3bUrydZb3nQASeFAAAAswuW9jleNBEAAaMBgFAAAKYGWOCxxGf7AgAAAAAEWVo="),
        ("RetroPalArchiveTest.gba.gz", "H4sIAAAAAAAAA2NgGNzAMcjZwzPMNcQ1OAQqMg3FPQCukWLZwAAAAA=="),
        ("RetroPalArchiveTest.gba.xz", "/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4AC/ABddAABvGITADC2Bd4A5n36vpUTsRLMGdpMAAADTa+zFKTan/wABM8ABAAAAYC4SELHEZ/sCAAAAAARZWg=="),
    ]

    /// The same game in a 7z named in Japanese and French (built 2026-10-29
    /// with 7-Zip). libarchive turns a 7z's names into the current locale's
    /// characters, and an app runs in the "C" locale: such a name did not
    /// convert and the archive was called damaged, until the reader took a
    /// UTF-8 locale for its own thread (audit, 2026-10-29). On the host this
    /// archive failed (status 1) before that fix and lists after it.
    static let nonASCII7z = "N3q8ryccAASwIzTeHwAAAAAAAABqAAAAAAAAAFAN3vLgAL8AF10AAG8YhMAMLYF3gDmffq+lROxEswZ2kwAAAQQGAAEJHwAHCwEAASEhAQAMgMAACAoBrpFi2QAABQEZCwAAAAAAAAAAAAAAESUA3TCxMOIw8zAgAMkAbQBlAHIAYQB1AGQAZQAuAGcAYgBhAAAAFAoBAIG/5NvgZ90BFQYBACCApIEAAA=="

    /// A Mega Drive cartridge (32 KB, "SEGA MEGA DRIVE" at 0x100, the shape
    /// `ImportFourConsolesTests` uses) gzipped alone, named in Japanese. A lone
    /// .gz states no size: its `.md` was taken for a README and the archive
    /// said to hold no game, until the reader learnt the size by reading it
    /// (audit, 2026-10-29; on the host: size -1 and no bytes before, 32,768
    /// after).
    static let megaDriveGz = "H4sIAAAAAAACA+3QVz8VAACGcRUVSYgGxSHRXkJbyjE7yhENRWkqlLRQIS0zhNLQoGG1i5as0KSMhllmexil/euiT+F5L577/ysh0b5nIzQ1Eoj+xVhsbicUtLsDuqvojDWysl+5YfvewwlXswsr3nyVVFAbOk4odnTx3LXvWMr1vOKXH350VdYcOcncbsnarYH74y+k339W9+WPbF9t3ami+SvW+4UeOnMlq6D8dWsn+f5DDIytHVZv3hlxNPlablH1++9dlDRGTDSzdVqzJSA67vyte09rP//u1mfgGMMZ85Z7+IYcPH0581FZY0vHHv0G60+ftXDVph3hsUlpd55UvWvr3FMwfILp7MVu3nuiTpy7ebe05tMvmd5ao6dYzl22zic45tSljIcvGpo7yKkO0ps2c4HzRv+wI4mpOY8r336TUlQfNt7EZpGr1+7I42dv5Je8+vhTuteAUZMt5ix13xZ04OTF2w+e1zfhx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48fP378+PHjx48f/3//X5oNe7wAgAAA"

    /// The same game in a 7z whose entry is protected by a password.
    static let passwordProtected7z = "N3q8ryccAARIOKhAIAAAAAAAAACKAAAAAAAAAKJFr5tkcSAhQ8/AGZjwbaX8MdYeFB6w0ng8PjSCvhouaa+nzQEEBgABCSAABwsBAAIkBvEHARJTD5KFha1SeFkJKwW5hTy0liUhIQEAAQAMH4DAAAgKAa6RYtkAAAUBGQARMQBSAGUAdAByAG8AUABhAGwAQQByAGMAaABpAHYAZQBUAGUAcwB0AC4AZwBiAGEAAAAZAgAAFAoBAHzTgX7VZ90BFQYBACCApIEAAA=="

    private func makeImporter() -> (ROMImporter, NSManagedObjectContext) {
        let context = PersistenceController(inMemory: true).container.viewContext
        return (ROMImporter(context: context), context)
    }

    private func write(_ base64: String, as name: String) throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try #require(Data(base64Encoded: base64), "fixture \(name) is not valid base64")
        let file = dir.appendingPathComponent(name)
        try data.write(to: file)
        return (dir, file)
    }

    @Test("A game in a .7z, an LZMA .zip, a .tar.gz, a .tar.xz, a lone .gz or .xz lands in the library",
          arguments: archives.map(\.name))
    func eachFormatImports(_ name: String) throws {
        let base64 = try #require(Self.archives.first { $0.name == name }?.base64)
        let (importer, context) = makeImporter()
        let (dir, file) = try write(base64, as: name)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(GameArchive.isArchive(file), "\(name) is not offered as an archive")
        _ = try importer.importROM(from: file, method: "picker")
        let games = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "GameEntity"))
        let path = games.first?.value(forKey: "romFilePath") as? String
        defer { if let path { try? FileManager.default.removeItem(at: importer.romURL(for: path)) } }

        #expect(games.count == 1, "\(name): \(games.count) games imported, not one")
        #expect(path?.hasSuffix(".gba") == true, "\(name): stored as \(path ?? "nothing")")
        // No copy of the game is left behind in tmp. (Whether it was MOVED
        // rather than copied, which is what saves a 4 GB 3DS game a third copy
        // of itself at the peak, is not visible after the fact: that one is
        // the code's, `ROMImporter.importEntry`.)
        // Extractions and the archive's copy live under the import scratch
        // since 2026-10-30 (`GameArchive.scratchRoot`), one folder each.
        let leftovers = ((try? FileManager.default.contentsOfDirectory(
            at: GameArchive.scratchRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { folder in
                ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                    .contains("RetroPalArchiveTest.gba")
            }
        #expect(leftovers.isEmpty, "\(name): the extracted game was left in tmp")
        if let path {
            let size = (try? FileManager.default.attributesOfItem(atPath: importer.romURL(for: path).path)[.size] as? Int) ?? 0
            #expect(size == 192, "\(name): the game came out at \(size) bytes, not its 192")
        }
        print("[archive] \(name) -> \(path ?? "-")")
    }

    @Test("A .7z whose game is named in Japanese and French imports, its name intact")
    func nonASCIINameImports() throws {
        let (importer, context) = makeImporter()
        let (dir, file) = try write(Self.nonASCII7z, as: "RetroPalArchiveTest-nonascii.7z")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try importer.importROM(from: file, method: "picker")
        let games = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "GameEntity"))
        let path = games.first?.value(forKey: "romFilePath") as? String
        defer { if let path { try? FileManager.default.removeItem(at: importer.romURL(for: path)) } }
        #expect(games.count == 1, "\(games.count) games imported, not one")
        let stored = path.map { ($0 as NSString).lastPathComponent.precomposedStringWithCanonicalMapping }
        #expect(stored?.hasPrefix("ポケモン Émeraude") == true, "stored as \(path ?? "nothing")")
        print("[archive] non-ASCII .7z -> \(path ?? "-")")
    }

    @Test("A lone .md.gz named in Japanese imports as a Mega Drive game, its name intact")
    func loneMegaDriveGzImports() throws {
        let (importer, context) = makeImporter()
        let (dir, file) = try write(Self.megaDriveGz, as: "ソニック.md.gz")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try importer.importROM(from: file, method: "picker")
        let games = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "GameEntity"))
        let path = games.first?.value(forKey: "romFilePath") as? String
        defer { if let path { try? FileManager.default.removeItem(at: importer.romURL(for: path)) } }
        #expect(games.count == 1, "\(games.count) games imported, not one")
        #expect(games.first?.value(forKey: "systemType") as? String == "md",
                "imported as \(games.first?.value(forKey: "systemType") as? String ?? "nothing")")
        let stored = path.map { ($0 as NSString).lastPathComponent.precomposedStringWithCanonicalMapping }
        #expect(stored == "ソニック.md", "stored as \(path ?? "nothing")")
        print("[archive] lone .md.gz -> \(path ?? "-")")
    }

    @Test("A password-protected .7z is refused as protected, and nothing is imported")
    func passwordArchiveIsRefused() throws {
        let (importer, context) = makeImporter()
        let (dir, file) = try write(Self.passwordProtected7z, as: "RetroPalArchiveTest-password.7z")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try importer.importROM(from: file, method: "picker")
            Issue.record("a password-protected archive must not import")
        } catch ROMImportError.archiveEncrypted {
            print("[archive] password .7z -> archiveEncrypted")
        }
        let games = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "GameEntity"))
        #expect(games.isEmpty, "a refused archive still left \(games.count) entries")
    }

    /// One volume of a split archive is said to be one (2026-10-30), by its
    /// name or, for a RAR named plainly, by its main header's volume flag. The
    /// headers are the first 64 bytes of libarchive's own test files
    /// (`Vendor/libarchive/libarchive/test`): a RAR 4 and a RAR 5 first
    /// volume, and a RAR 4 and a RAR 5 single archive.
    @Test("A split archive's volume is recognised by its name or its RAR header")
    func splitVolumesAreRecognised() throws {
        let rar4Volume = "UmFyIRoHAFpucxEBDQAAAAAAAACIrnQikEMA7RoAAI9OAAADkMq8BfNjIUAUMBkApIEAAExpYmFyY2hpdmVBZA=="
        let rar5Volume = "UmFyIRoHAQBVAEHPDAEFCAEHAQHv9oCAAOe75SpXAhMLgvYABODpCO2DAmpJBZWAFQE3aG9tZS9hbnRlay90ZQ=="
        let rar4Single = "UmFyIRoHAM+QcwAADQAAAAAAAACEUnQgkDIAFAAAABQAAAADQqLIvrd22j4UMAgApIEAAHRlc3QudHh0gAi3dg=="
        let rar5Single = "UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAA4MAZjLAIDC50ABJ0ApIMCtEOglYAAAQ5oZWxsb3dvcmxkLnR4dAoDEw=="
        func header(_ b64: String) throws -> [UInt8] { [UInt8](try #require(Data(base64Encoded: b64))) }
        #expect(GameArchive.rarHeaderSaysVolume(try header(rar4Volume)), "a RAR 4 volume read as a whole archive")
        #expect(GameArchive.rarHeaderSaysVolume(try header(rar5Volume)), "a RAR 5 volume read as a whole archive")
        #expect(!GameArchive.rarHeaderSaysVolume(try header(rar4Single)), "a RAR 4 archive read as a volume")
        #expect(!GameArchive.rarHeaderSaysVolume(try header(rar5Single)), "a RAR 5 archive read as a volume")

        for name in ["Game.part1.rar", "Game.part02.RAR", "Game.7z.001", "Game.zip.002"] {
            #expect(GameArchive.isSplitVolume(URL(fileURLWithPath: "/nowhere/\(name)")), "\(name) not seen as a volume")
        }
        // A RAR named plainly, read by its header; a .7z or a .zip is never
        // opened for it.
        let (dir, plain) = try write(rar5Volume, as: "Game.rar")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GameArchive.isSplitVolume(plain), "a RAR volume named Game.rar not recognised")
        #expect(!GameArchive.isSplitVolume(URL(fileURLWithPath: "/nowhere/Game.7z")))
        #expect(!GameArchive.isSplitVolume(URL(fileURLWithPath: "/nowhere/Part 1.zip")))

        let (importer, _) = makeImporter()
        #expect(throws: ROMImportError.self) { _ = try importer.importROM(from: plain, method: "picker") }
        do { _ = try importer.importROM(from: plain, method: "picker") } catch ROMImportError.archiveSplit {
        } catch { Issue.record("a split volume was refused as \(error), not as split") }
    }

    @Test("Two archives of the same name get their own copy, and what a killed import left is swept at launch")
    func scratchIsPerArchiveAndSwept() throws {
        let source = URL(fileURLWithPath: "/elsewhere/Games.7z")
        let first = try GameArchive.stagedCopyURL(for: source)
        let second = try GameArchive.stagedCopyURL(for: source)
        defer { GameArchive.discardStagedCopy(first); GameArchive.discardStagedCopy(second) }
        #expect(first != second, "two archives named Games.7z shared one copy")
        #expect(first.lastPathComponent == "Games.7z")

        let fm = FileManager.default
        let stale = try GameArchive.makeScratchFolder()
        let fresh = try GameArchive.makeScratchFolder()
        defer { try? fm.removeItem(at: stale); try? fm.removeItem(at: fresh) }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        GameArchive.sweepScratch()
        #expect(!fm.fileExists(atPath: stale.path), "an hour-old import scratch survived the launch sweep")
        #expect(fm.fileExists(atPath: fresh.path), "the sweep removed an import still running")
    }
}

@Suite("Game Mode")
struct GameModeTests {
    private var info: [String: Any] { Bundle(for: ROMImporter.self).infoDictionary ?? [:] }

    /// The two keys only. The category (`LSApplicationCategoryType`) is NOT in
    /// the built app, and this test's first run said so (2026-10-30): the
    /// project sets it as `INFOPLIST_KEY_LSApplicationCategoryType`, which
    /// Xcode reads only with `GENERATE_INFOPLIST_FILE = YES`, and the app
    /// target has its own Info.plist without it. Game Mode was confirmed on
    /// his iPhone on 2026-10-27 with exactly that build, so the two keys are
    /// what turn it on, and they are what this guards.
    @Test("The app declares Game Mode for iOS 18 and iOS 26")
    func gameModeIsDeclared() {
        #expect(info["GCSupportsGameMode"] as? Bool == true,
                "GCSupportsGameMode is gone from Info.plist: no Game Mode on iOS 18")
        #expect(info["LSSupportsGameMode"] as? Bool == true,
                "LSSupportsGameMode is gone from Info.plist: no Game Mode on iOS 26")
    }
}
