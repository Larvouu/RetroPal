//
//  OpenFromFilesTests.swift
//  EmulateurGBATests
//
//  Opening a game or a save from outside the app (Files, the share sheet,
//  AirDrop), 2026-10-07.
//
//  What these hold in place:
//   - the Info.plist's claims: our own game types at Owner rank (we are the
//     default wherever we were installed first), the same games under the
//     other emulators' types at Alternate rank only (offered, never taking the
//     tap from the emulator that owns the type), saves imported at Default,
//     never Owner, and every type able to travel by AirDrop (public.content);
//   - a name for every document type and type description in all fifteen
//     languages (the Nintendo 64's was missing from 1.3.3 until this date);
//   - the pickers accepting the PlayStation memory card (.mcd), missing from
//     their types until this date though the importer took it;
//   - where an opened save goes (the consoles its size allows): the one game
//     whose ROM name it carries, else
//     the chooser with the closest names first, else "import the game first".
//

import Testing
import Foundation
import CoreData
import UniformTypeIdentifiers
import UIKit
@testable import EmulateurGBA

@Suite("Opening games and saves from Files")
struct OpenFromFilesTests {

    // MARK: - Info.plist

    private static let info = Bundle.main.infoDictionary ?? [:]
    private static var documentTypes: [[String: Any]] {
        info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    }

    private static func types(rank: String) -> Set<String> {
        Set(documentTypes
            .filter { ($0["LSHandlerRank"] as? String) == rank }
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
    }

    @Test("Our own game types are claimed at Owner rank")
    func ownGameTypesAreOwned() {
        let owned = Self.types(rank: "Owner")
        for console in ["gba", "gbc", "gb", "nds", "snes", "nes", "ps1", "n64", "md", "sms", "gg"] {
            #expect(owned.contains("com.retropal.rom.\(console)"),
                    "com.retropal.rom.\(console) is not claimed at Owner rank.")
        }
    }

    /// Every icon a document type names exists in the app. The Nintendo 64's
    /// entry named `DocIconN64` from 1.3.3 on and the icon was never made, so
    /// its files showed a blank page in Files (found 2026-10-08).
    @Test("Every document type's icon exists")
    func documentIconsExist() {
        for type in Self.documentTypes {
            for name in type["CFBundleTypeIconFiles"] as? [String] ?? [] {
                #expect(UIImage(named: name) != nil,
                        "\(name), named by \(type["CFBundleTypeName"] ?? "a document type"), is not in the app.")
            }
        }
    }

    @Test("Another emulator's type is only ever claimed at Alternate rank")
    func rivalTypesAreAlternateOnly() {
        let prefixes = ["com.rileytestut.", "public.aoshuang.", "com.provenance.", "com.retroarch.", "ppsspp."]
        let alternate = Self.types(rank: "Alternate")
        for rank in ["Owner", "Default", "None"] {
            let stolen = Self.types(rank: rank).filter { uti in prefixes.contains { uti.hasPrefix($0) } }
            #expect(stolen.isEmpty, "Another app's type claimed at \(rank) rank: \(stolen.sorted()).")
        }
        // The emulators a player is most likely to have first, on every
        // console both of them run.
        for uti in ["com.rileytestut.delta.game.gba", "com.rileytestut.delta.game.gbc",
                    "com.rileytestut.delta.game.ds", "com.rileytestut.delta.game.snes",
                    "com.rileytestut.delta.game.nes", "com.rileytestut.delta.game.n64",
                    "public.aoshuang.game.gba", "public.aoshuang.game.ps1", "public.aoshuang.game.n64",
                    "com.rileytestut.delta.game.genesis", "public.aoshuang.game.md",
                    "com.provenance.rom.genesis", "com.retroarch.md",
                    "public.aoshuang.game.ms", "public.aoshuang.game.gg",
                    "com.provenance.rom.mastersystem", "com.provenance.rom.gamegear",
                    "com.retroarch.sms",
                    "public.aoshuang.gamesave"] {
            #expect(alternate.contains(uti), "\(uti) is not offered at Alternate rank.")
        }
    }

    @Test("Saves are an imported type at Default rank, never Owner")
    func savesAreImportedAtDefault() {
        let imported = Self.info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []
        let save = imported.first { ($0["UTTypeIdentifier"] as? String) == "com.retropal.save" }
        #expect(save != nil, "com.retropal.save is not declared as an imported type.")
        let tags = (save?["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String] ?? []
        #expect(Set(tags) == ["sav", "srm", "mcd"])
        #expect(Self.types(rank: "Default").contains("com.retropal.save"))
        #expect(!Self.types(rank: "Owner").contains("com.retropal.save"))
        let exported = Self.info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        #expect(!exported.contains { ($0["UTTypeIdentifier"] as? String) == "com.retropal.save" },
                "A save type is exported: we do not own .sav, .srm or .mcd.")
    }

    /// `.md` is Markdown's extension too. We never EXPORT it (that would make
    /// every Markdown note on the phone a "Mega Drive ROM" with our icon and
    /// Retro Pal as its owner): it is an imported type, offered at Alternate.
    @Test("The Mega Drive's .md is imported at Alternate, never owned")
    func markdownsExtensionIsNeverOwned() {
        let exported = Self.info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        for type in exported {
            let tags = (type["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String] ?? []
            #expect(!tags.contains("md"), "\(type["UTTypeIdentifier"] ?? "a type") exports .md, Markdown's extension.")
        }
        let imported = Self.info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []
        let md = imported.first { ($0["UTTypeIdentifier"] as? String) == "com.retropal.rom.mdtext" }
        let tags = (md?["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String] ?? []
        #expect(tags == ["md"])
        #expect(Self.types(rank: "Alternate").contains("com.retropal.rom.mdtext"))
        for rank in ["Owner", "Default"] {
            #expect(!Self.types(rank: rank).contains("com.retropal.rom.mdtext"))
        }
    }

    @Test("Every game and save type can travel by AirDrop (public.content)")
    func typesConformToContent() {
        let declared = (Self.info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [])
            + (Self.info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? [])
        for type in declared {
            let id = type["UTTypeIdentifier"] as? String ?? ""
            guard id.hasPrefix("com.retropal.rom.") || id == "com.retropal.save" else { continue }
            let conforms = type["UTTypeConformsTo"] as? [String] ?? []
            #expect(conforms.contains("public.content"), "\(id) does not conform to public.content.")
        }
    }

    @Test("Every document type and type name is translated in all fifteen languages")
    func typeNamesAreLocalized() {
        let names = Set(Self.documentTypes.compactMap { $0["CFBundleTypeName"] as? String })
            .union(((Self.info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [])
                    + (Self.info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []))
                    .compactMap { $0["UTTypeDescription"] as? String })
        let locales = ["en", "fr", "de", "es", "es-MX", "it", "ja", "ko", "nl", "pl",
                       "pt-BR", "pt-PT", "ro", "sv", "zh-Hant"]
        for locale in locales {
            guard let path = Bundle.main.path(forResource: "InfoPlist", ofType: "strings",
                                              inDirectory: nil, forLocalization: locale),
                  let table = NSDictionary(contentsOfFile: path) as? [String: String] else {
                Issue.record("No InfoPlist.strings for \(locale).")
                continue
            }
            let missing = names.subtracting(table.keys)
            #expect(missing.isEmpty, "\(locale) has no name for \(missing.sorted()).")
        }
    }

    // MARK: - Pickers

    @Test("The save pickers accept .sav, .srm and the PlayStation's .mcd")
    func pickersAcceptMemoryCards() {
        for ext in ["sav", "srm", "mcd"] {
            guard let type = UTType(filenameExtension: ext) else {
                Issue.record("No type for .\(ext)."); continue
            }
            #expect(DocumentPickerView.saveTypes.contains { type.conforms(to: $0) },
                    "Game Details' Import Save picker greys out .\(ext).")
            #expect(DocumentPickerView.romAndSaveTypes.contains { type.conforms(to: $0) },
                    "The library's + picker greys out .\(ext).")
        }
    }

    // MARK: - Where an opened save goes

    private func game(_ title: String, rom: String, system: String,
                      in context: NSManagedObjectContext) -> GameEntity {
        let game = NSEntityDescription.insertNewObject(forEntityName: "GameEntity", into: context) as! GameEntity
        game.title = title
        game.romFilePath = rom
        game.systemType = system
        return game
    }

    /// A save as the importer hands it over: consoles from its size and its
    /// extension (`BatterySaveImporter.classify`).
    private func save(named fileName: String, byteCount: Int = 8192) -> OpenedSave {
        let ext = (fileName as NSString).pathExtension
        guard case .savable(let consoles, _) = BatterySaveImporter.classify(
            data: Data(repeating: 0x5A, count: byteCount), system: BatterySaveSystem.from(fileExtension: ext)!) else {
            fatalError("Test save of \(byteCount) bytes did not classify.")
        }
        return OpenedSave(pending: .init(data: Data(count: byteCount), consoles: consoles), fileName: fileName)
    }

    @Test("A save named after one game's ROM goes straight to that game")
    func exactNameGoesToTheGame() {
        let context = PersistenceController(inMemory: true).container.viewContext
        let emerald = game("Pokémon Emerald", rom: "Pokemon - Emerald Version (USA).gba", system: "gba", in: context)
        _ = game("Tetris", rom: "Tetris.gb", system: "gb", in: context)
        guard case .game(let target) = SaveTargetPickerSheet.destination(
            for: save(named: "Pokemon - Emerald Version (USA).sav"), in: [emerald]) else {
            Issue.record("An exact ROM name did not go straight to its game."); return
        }
        #expect(target == emerald)
    }

    @Test("Without an exact name, the chooser lists the family's games, closest name first")
    func otherwiseTheChooserRanks() {
        let context = PersistenceController(inMemory: true).container.viewContext
        let tetris = game("Tetris", rom: "Tetris.gb", system: "gb", in: context)
        let emerald = game("Pokémon Emerald", rom: "Pokemon Emerald.gba", system: "gba", in: context)
        let mario = game("Super Mario 64", rom: "Super Mario 64.z64", system: "n64", in: context)
        guard case .choose(let list) = SaveTargetPickerSheet.destination(
            for: save(named: "Pokemon - Emerald Version (USA).sav"), in: [tetris, emerald, mario]) else {
            Issue.record("A save with no exact match did not open the chooser."); return
        }
        // An 8 KB save is no N64 save (those are all 296,960 bytes): the N64
        // game is not offered.
        #expect(list == [emerald, tetris])
    }

    @Test("Two games with the save's name is a question, not a guess")
    func twoSameNamesAsk() {
        let context = PersistenceController(inMemory: true).container.viewContext
        let gb = game("Tetris", rom: "Tetris.gb", system: "gb", in: context)
        let gbc = game("Tetris DX", rom: "Tetris.gbc", system: "gbc", in: context)
        guard case .choose(let list) = SaveTargetPickerSheet.destination(
            for: save(named: "Tetris.sav"), in: [gb, gbc]) else {
            Issue.record("Two same-named games did not open the chooser."); return
        }
        #expect(Set(list) == [gb, gbc])
    }

    @Test("No game of the save's consoles: the player is told to import the game first")
    func noCompatibleGame() {
        let context = PersistenceController(inMemory: true).container.viewContext
        let mario = game("Super Mario 64", rom: "Super Mario 64.z64", system: "n64", in: context)
        guard case .noGame = SaveTargetPickerSheet.destination(for: save(named: "Zelda.sav"), in: [mario]) else {
            Issue.record("An 8 KB save was routed to a Nintendo 64 game."); return
        }
        guard case .noGame = SaveTargetPickerSheet.destination(for: save(named: "Zelda.sav"), in: []) else {
            Issue.record("A save with an empty library did not say so."); return
        }
    }
}
