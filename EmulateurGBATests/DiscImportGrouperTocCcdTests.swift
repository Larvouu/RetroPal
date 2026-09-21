//
//  DiscImportGrouperTocCcdTests.swift
//  EmulateurGBATests
//
//  Two PlayStation container formats the grouper learned on 2026-09-03.
//
//  A cdrdao `.toc` names its tracks with FILE / DATAFILE / AUDIOFILE
//  statements and the core boots from it, so it groups exactly as a `.cue`
//  does. A CloneCD set is a `.ccd` descriptor beside a `.img` image (and a
//  `.sub`); the core boots the IMAGE and finds the descriptor by name, so the
//  `.ccd` is a sidecar of its image, and a `.ccd` picked without its image is
//  a gap that names the missing file rather than a silently dropped patch.
//

import Testing
import Foundation
@testable import EmulateurGBA

@Suite("DiscImportGrouper: .toc and .ccd")
struct DiscImportGrouperTocCcdTests {

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disc-toc-ccd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func write(_ name: String, in dir: URL, bytes: Int = 16, text: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        if let text {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try Data(repeating: 0xAB, count: bytes).write(to: url)
        }
        return url
    }

    private func names(_ urls: [URL]) -> Set<String> { Set(urls.map(\.lastPathComponent)) }

    private let toc = """
    CD_ROM_XA

    // Track 1
    TRACK MODE2_RAW
    NO COPY
    DATAFILE "Game (Track 01).bin" 0

    // Track 2
    TRACK AUDIO
    TWO_CHANNEL_AUDIO
    FILE "Game (Track 02).bin" 0 02:31:00
    """

    @Test("A .toc claims the tracks its DATAFILE and FILE lines name")
    func tocTracks() {
        let tracks = DiscImportGrouper.tocTracks(toc)
        #expect(tracks == ["Game (Track 01).bin", "Game (Track 02).bin"])
        #expect(DiscImportGrouper.tocTracks("AUDIOFILE \"song.wav\" 0").first == "song.wav")
        #expect(DiscImportGrouper.tocTracks(nil).isEmpty)
    }

    @Test("A .toc and its two tracks are ONE game, booting from the .toc")
    func tocSetIsOneGame() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let descriptor = try write("Game.toc", in: dir, text: toc)
        let track1 = try write("Game (Track 01).bin", in: dir, bytes: 4096)
        let track2 = try write("Game (Track 02).bin", in: dir, bytes: 2048)

        let (cartridges, discs, gaps) = DiscImportGrouper.group([track2, descriptor, track1])
        #expect(cartridges.isEmpty)
        #expect(gaps.isEmpty)
        #expect(discs.count == 1)
        #expect(discs.first?.boot == descriptor)
        #expect(names(discs.first?.members ?? []) == ["Game.toc", "Game (Track 01).bin", "Game (Track 02).bin"])
        print("[disc] .toc set → boot \(discs.first?.boot.lastPathComponent ?? "-"), \(discs.first?.members.count ?? 0) files")
    }

    @Test("A .toc whose track is missing is a gap naming that track")
    func tocMissingTrack() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let descriptor = try write("Game.toc", in: dir, text: toc)
        try write("Game (Track 01).bin", in: dir)

        let (_, discs, gaps) = DiscImportGrouper.group([descriptor, dir.appendingPathComponent("Game (Track 01).bin")])
        #expect(discs.isEmpty)
        #expect(gaps.count == 1)
        #expect(gaps.first?.missing == ["Game (Track 02).bin"])
    }

    @Test("A CloneCD set (.ccd + .img + .sub) is ONE game booting from the image, descriptor and subchannel aboard")
    func cloneCDSetIsOneGame() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ccd = try write("Game.ccd", in: dir, text: "[CloneCD]\nVersion=3\n")
        let img = try write("Game.img", in: dir, bytes: 4096)
        let sub = try write("Game.sub", in: dir, bytes: 96)

        let (cartridges, discs, gaps) = DiscImportGrouper.group([ccd, img, sub])
        #expect(cartridges.isEmpty)
        #expect(gaps.isEmpty)
        #expect(discs.count == 1)
        #expect(discs.first?.boot == img, "the core boots the image and reads the .ccd beside it")
        #expect(names(discs.first?.members ?? []) == ["Game.ccd", "Game.img", "Game.sub"])
        print("[disc] CloneCD set → boot \(discs.first?.boot.lastPathComponent ?? "-"), members \(names(discs.first?.members ?? []).sorted())")
    }

    @Test("A .ccd without its image is a gap that names the image, not a silent drop")
    func loneCloneCDDescriptor() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ccd = try write("Game.ccd", in: dir, text: "[CloneCD]\n")

        let (cartridges, discs, gaps) = DiscImportGrouper.group([ccd])
        #expect(cartridges.isEmpty)
        #expect(discs.isEmpty)
        #expect(gaps.count == 1)
        #expect(gaps.first?.missing == ["Game.img"])
    }

    @Test("A .ccd is a disc file to the importer, and .ccd is a sidecar, never a boot file")
    func extensionsAgree() {
        #expect(DiscImportGrouper.isDiscFile("Game.ccd"))
        #expect(ROMSystemType.discSidecarExtensions.contains("ccd"))
        #expect(!ROMSystemType.discFileExtensions.contains("ccd"))
        #expect(ROMSystemType.allFileExtensions.contains("ccd"))
        #expect(ROMSystemType.allFileExtensions.contains("toc"))
    }

    @Test("A playlist of .toc discs is one multi-disc game")
    func playlistOfTocs() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d1 = try write("Game (Disc 1).toc", in: dir, text: "DATAFILE \"Game (Disc 1).bin\" 0\n")
        let d2 = try write("Game (Disc 2).toc", in: dir, text: "DATAFILE \"Game (Disc 2).bin\" 0\n")
        let b1 = try write("Game (Disc 1).bin", in: dir, bytes: 512)
        let b2 = try write("Game (Disc 2).bin", in: dir, bytes: 512)
        let m3u = try write("Game.m3u", in: dir, text: "Game (Disc 1).toc\nGame (Disc 2).toc\n")

        let (_, discs, gaps) = DiscImportGrouper.group([b2, d2, m3u, b1, d1])
        #expect(gaps.isEmpty)
        #expect(discs.count == 1)
        #expect(discs.first?.boot == m3u)
        #expect(names(discs.first?.members ?? []) == ["Game.m3u", "Game (Disc 1).toc", "Game (Disc 2).toc", "Game (Disc 1).bin", "Game (Disc 2).bin"])
    }
}
