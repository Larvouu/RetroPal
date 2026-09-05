//
//  RADiscHashingTests.swift
//  EmulateurGBATests
//
//  Which PlayStation containers RetroAchievements can identify, and which it
//  cannot — held against the list of containers the app actually accepts.
//
//  The failure this exists to prevent is silent by construction. Adding a disc
//  extension to the importer is one line and obviously correct; the same
//  extension is then unknown to `consoleIdForROMPath:`, which answers 0, which
//  the app reads as "this console has no achievements". The game imports, boots,
//  plays, and quietly earns nothing. Nobody reports it, because nothing looks
//  broken.
//
//  So every accepted container must have a DECIDED answer here: either it hashes
//  as a PlayStation disc, or it is on the exception list below with its reason
//  written down.
//

import Testing
import Foundation
@testable import EmulateurGBA

struct RADiscHashingTests {

    /// The containers that deliberately do NOT hash, and why.
    ///
    /// `.pbp` is a repacked, re-encoded archive rather than a disc image: there
    /// is no track 1 for rc_hash to read SYSTEM.CNF from. It is accepted anyway,
    /// because refusing a player's game is worse than telling them the truth,
    /// and Game Details carries that truth in one line.
    ///
    /// ⚠ `.m3u` WAS ON THIS LIST AND CAME OFF IT ON 2026-08-27, and the reason it
    /// was here is worth keeping because it was half right. A playlist is a text
    /// file naming other files, and the disc it points at is indeed what gets
    /// hashed. But `consoleIdForROMPath:` is not asked in order to hash: it is
    /// asked BEFORE the load so `_regions` can be cached, and rcheevos validates
    /// every achievement's address during that load by calling back into our
    /// memory reader. With no regions the reader returns 0, and rcheevos reads a
    /// 0 as "no such address" and marks the achievement UNSUPPORTED. A game
    /// booted from a playlist therefore identified, listed its achievements, and
    /// could never unlock one.
    private static let deliberatelyUnhashable: Set<String> = ["pbp"]

    @Test func everyAcceptedDiscContainerHasADecidedAchievementAnswer() {
        for ext in ROMSystemType.discFileExtensions {
            let path = "/games/Some Game.\(ext)"
            let consoleId = RAClient.consoleId(forROMPath: path)
            if Self.deliberatelyUnhashable.contains(ext) {
                #expect(consoleId == 0,
                        Comment(rawValue: ".\(ext) is on the unhashable list but reports "
                                          + "console \(consoleId). If it can now be hashed, "
                                          + "take it off the list."))
            } else {
                #expect(consoleId == 12,
                        Comment(rawValue: ".\(ext) is accepted by the importer but "
                                          + "RetroAchievements answers \(consoleId) for it. A "
                                          + "game in this container would import, play, and "
                                          + "silently earn nothing."))
            }
        }
    }

    /// The caption and the hash have to agree about `.pbp`.
    ///
    /// Two separate pieces of code decide "this file cannot earn achievements"
    /// and "tell the player why". If they disagree, a player either sees an
    /// explanation for a game that works, or no explanation for one that does
    /// not — and the second is the state this whole caption exists to end.
    @Test func theCaptionAgreesWithTheHash() {
        for ext in ROMSystemType.discFileExtensions {
            let path = "/games/Some Game.\(ext)"
            let captioned = GameDetailsView.isUnhashableDiscContainer(path)
            let hashable = RAClient.consoleId(forROMPath: path) != 0
            if captioned {
                #expect(!hashable,
                        ".\(ext) is captioned as unhashable but hashes fine")
            }
        }
        #expect(GameDetailsView.isUnhashableDiscContainer("/games/Some Game.PBP"),
                "the caption must not be case-sensitive: Files hands back what the user typed")
    }

    /// Every accepted disc container must resolve to the PlayStation, and the
    /// resolution must not care about case.
    ///
    /// This is the mapping that picks which CORE runs a file. If `.cue` ever
    /// stopped answering `.ps1`, a disc would be handed to mGBA, which is a
    /// failure with no good symptom: the file is valid, the library row is
    /// right, and the game simply does not boot. Files hands back whatever the
    /// user's filesystem holds, so `.CUE` has to answer the same as `.cue`.
    @Test func everyDiscExtensionResolvesToThePlayStation() {
        for ext in ROMSystemType.discFileExtensions {
            #expect(ROMSystemType.from(fileExtension: ext) == .ps1,
                    Comment(rawValue: ".\(ext) is accepted as a disc but resolves to "
                                      + "\(String(describing: ROMSystemType.from(fileExtension: ext)))"))
            #expect(ROMSystemType.from(fileExtension: ext.uppercased()) == .ps1,
                    ".\(ext.uppercased()) must resolve like its lowercase form")
        }
    }

    /// A PLAYLIST MUST REPORT A CONSOLE, and this is the test for the reason
    /// rather than for the value.
    ///
    /// Multi-disc games are the ones that boot from a playlist, and since the
    /// importer started writing an `.m3u` for discs that arrive without one,
    /// that is most of them: Final Fantasy VII, VIII and IX, Metal Gear Solid,
    /// Chrono Cross. If this answer ever goes back to 0, every achievement in
    /// every one of those games goes UNSUPPORTED at load, silently, while the
    /// game still identifies and still lists its set.
    @Test func aPlaylistReportsItsConsoleSoAchievementsSurviveValidation() {
        #expect(RAClient.consoleId(forROMPath: "/games/Final Fantasy VII.m3u") == 12,
                "a playlist must resolve to the PlayStation before the load, or "
                + "rc_client_validate_addresses invalidates every memref")
        #expect(RAClient.consoleId(forROMPath: "/games/FF7.M3U") == 12,
                "and case must not change the answer: Files hands back what the user typed")
    }

    /// A cartridge must not be dragged into the PlayStation answer by a shared
    /// extension. `.bin` is the one to watch: it is a PlayStation data track
    /// here, and it is also the most generic extension in computing.
    @Test func cartridgeExtensionsKeepTheirOwnConsoles() {
        #expect(RAClient.consoleId(forROMPath: "/g/x.gba") != 12)
        #expect(RAClient.consoleId(forROMPath: "/g/x.nds") != 12)
        #expect(RAClient.consoleId(forROMPath: "/g/x.sfc") != 12)
        #expect(RAClient.consoleId(forROMPath: "/g/x.nes") != 12)
        #expect(RAClient.consoleId(forROMPath: "/g/x.gb") != 12)
    }
}
