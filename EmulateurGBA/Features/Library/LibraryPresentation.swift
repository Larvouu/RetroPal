//
//  LibraryPresentation.swift
//  EmulateurGBA
//
//  Settings ▸ Debug ▸ "Presentation mode" (2026-09-10): the library shows a
//  FAKE library, fifteen fictional games with bundled covers, in place of
//  whatever is really imported, both ways up, so a store screenshot can be
//  taken from the app itself with nothing to edit afterwards. The reason is
//  policy, not taste: the screenshots cannot promote Nintendo's games or
//  artwork, and a real library is full of them.
//
//  The fake games are real `GameEntity` objects, so every library surface
//  draws them through the code it draws real games with: rows, the rack's
//  tiles, the hero, the caption, the sort menu, search. They live in an
//  in-memory store built on the app's OWN managed object model (the same
//  model object, never a second load of it, which would make Core Data
//  claim the entity twice), so the library's fetch request never sees them
//  and nothing is ever written. While the mode is on, Play, the game page,
//  rename and delete do nothing.
//
//  Debug builds only: the flag has no setter in a release build, the read
//  answers false there, and the covers are excluded from Release builds by
//  `EXCLUDED_SOURCE_FILE_NAMES` (demo-*.jpg), so no release path or byte
//  changes.
//

import SwiftUI
import CoreData

enum LibraryPresentation {
    /// The `@AppStorage` key the library views observe.
    static let key = "debugPresentationMode"
    /// The chosen presentation language ("" = the system's), and the app's
    /// own language override it is applied through.
    static let languageKey = "debugPresentationLanguage"
    private static let appleLanguagesKey = "AppleLanguages"

    /// The fifteen languages the app ships, under their own names.
    struct Language: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let languages: [Language] = [
        Language(code: "en", name: "English"), Language(code: "fr", name: "Français"),
        Language(code: "de", name: "Deutsch"), Language(code: "es", name: "Español"),
        Language(code: "es-MX", name: "Español (México)"), Language(code: "it", name: "Italiano"),
        Language(code: "pt-BR", name: "Português (Brasil)"), Language(code: "pt-PT", name: "Português (Portugal)"),
        Language(code: "nl", name: "Nederlands"), Language(code: "sv", name: "Svenska"),
        Language(code: "pl", name: "Polski"), Language(code: "ro", name: "Română"),
        Language(code: "ja", name: "日本語"), Language(code: "ko", name: "한국어"),
        Language(code: "zh-Hant", name: "繁體中文"),
    ]

    /// Sets the app's language override to `code` ("" clears it) and quits,
    /// because iOS reads the override at launch and nowhere later: every
    /// string, every date and the demo titles then follow the choice on the
    /// next launch, which is the whole app in that language, not a theme of
    /// it. Debug builds only; the picker that calls this does not exist in a
    /// release build.
    static func applyLanguage(_ code: String) {
        #if DEBUG
        let defaults = UserDefaults.standard
        if code.isEmpty {
            defaults.removeObject(forKey: appleLanguagesKey)
        } else {
            defaults.set([code], forKey: appleLanguagesKey)
        }
        defaults.synchronize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
        #endif
    }

    /// The language the demo titles are read in: the override when one is
    /// set, else the app's first preferred language, mapped to our codes.
    static var titleLanguage: String {
        let preferred = (UserDefaults.standard.stringArray(forKey: appleLanguagesKey)?.first
                         ?? Locale.preferredLanguages.first ?? "en")
        for exact in ["pt-BR", "pt-PT", "es-MX", "zh-Hant"] where preferred.hasPrefix(exact) { return exact }
        if preferred.hasPrefix("zh") { return "zh-Hant" }
        let short = String(preferred.prefix(2))
        return titles[short] != nil ? short : "en"
    }

    /// Whether the mode is on. Views read their observed flag AND this, so a
    /// release build, which cannot set the flag, is also immune to a stray
    /// stored value.
    static func isOn(_ observedFlag: Bool) -> Bool {
        #if DEBUG
        return observedFlag
        #else
        return false
        #endif
    }

    /// One fictional game per bundled cover. The titles were invented from
    /// the pictures (2026-09-10) and exist in the fifteen languages (`titles`)
    /// so a Japanese shelf reads Japanese; `title` is the English one. The
    /// covers are `Resources/DemoLibrary/`, 640 points square, JPEG, 1.5 MB
    /// for the fifteen.
    struct Demo {
        let system: String
        let asset: String
        let title: String
    }

    /// The fifteen titles in the catalogue's order, per language. Invented
    /// names, kept clear of the real games' own words (no "Tekken", no
    /// "Mako" as the Japanese would write it).
    static let titles: [String: [String]] = [
        "en": ["Coral Tamers", "Tidewind Isles", "Apex Circuit", "Island Hopper", "Meadow Tamers", "Star Pilots", "Dusk Tamers", "Iron Fist Arena", "Bounce Kingdom", "Kart Rush", "Jungle Swing", "Mako City", "Ledge Runner", "Puppy Days", "Block Drop"],
        "fr": ["Dresseurs du Corail", "Îles de Marée", "Circuit Apex", "Saute-Îles", "Dresseurs des Prés", "Pilotes des Étoiles", "Dresseurs du Crépuscule", "Arène du Poing de Fer", "Royaume Rebond", "Kart Rush", "Liane Jungle", "Cité Mako", "Coureur des Corniches", "Jours de Chiot", "Chute de Blocs"],
        "de": ["Korallenzähmer", "Gezeiteninseln", "Apex-Rennstrecke", "Inselhüpfer", "Wiesenzähmer", "Sternenpiloten", "Dämmerungszähmer", "Eisenfaust-Arena", "Hüpfkönigreich", "Kart-Rausch", "Dschungelschwung", "Mako-Stadt", "Simsläufer", "Welpentage", "Blockfall"],
        "es": ["Domadores de Coral", "Islas de Marea", "Circuito Ápex", "Salta Islas", "Domadores del Prado", "Pilotos Estelares", "Domadores del Ocaso", "Arena Puño de Hierro", "Reino Rebote", "Kart Rush", "Liana de la Selva", "Ciudad Mako", "Corredor de Cornisas", "Días de Cachorro", "Caída de Bloques"],
        "es-MX": ["Domadores de Coral", "Islas de Marea", "Circuito Ápex", "Salta Islas", "Domadores del Prado", "Pilotos Estelares", "Domadores del Ocaso", "Arena Puño de Hierro", "Reino Rebote", "Kart Rush", "Liana de la Selva", "Ciudad Mako", "Corredor de Cornisas", "Días de Cachorro", "Caída de Bloques"],
        "it": ["Domatori di Corallo", "Isole di Marea", "Circuito Apex", "Salta Isole", "Domatori del Prato", "Piloti Stellari", "Domatori del Crepuscolo", "Arena Pugno di Ferro", "Regno Rimbalzo", "Kart Rush", "Liana della Giungla", "Città Mako", "Corsa sui Cornicioni", "Giorni da Cucciolo", "Caduta di Blocchi"],
        "pt-BR": ["Domadores de Coral", "Ilhas da Maré", "Circuito Ápice", "Pula-Ilhas", "Domadores do Prado", "Pilotos Estelares", "Domadores do Crepúsculo", "Arena Punho de Ferro", "Reino do Pulo", "Kart Rush", "Cipó da Selva", "Cidade Mako", "Corredor de Beirais", "Dias de Filhote", "Queda de Blocos"],
        "pt-PT": ["Domadores de Coral", "Ilhas da Maré", "Circuito Ápice", "Salta-Ilhas", "Domadores do Prado", "Pilotos das Estrelas", "Domadores do Crepúsculo", "Arena Punho de Ferro", "Reino do Salto", "Kart Rush", "Liana da Selva", "Cidade Mako", "Corredor de Cornijas", "Dias de Cachorro", "Queda de Blocos"],
        "nl": ["Koraaltemmers", "Getij-eilanden", "Apex Circuit", "Eilandspringer", "Weidetemmers", "Sterrenpiloten", "Schemertemmers", "IJzeren Vuist Arena", "Stuiterrijk", "Kart Rush", "Jungleslinger", "Mako-stad", "Richelrenner", "Puppydagen", "Blokkenval"],
        "sv": ["Korallstämjare", "Tidvattenöarna", "Apex Circuit", "Öhopparen", "Ängstämjare", "Stjärnpiloter", "Skymningstämjare", "Järnnävens Arena", "Studsriket", "Kart Rush", "Djungelsving", "Mako City", "Avsatslöparen", "Valpdagar", "Blockfall"],
        "pl": ["Poskramiacze Koralowców", "Wyspy Przypływu", "Tor Apex", "Skoczek Wyspowy", "Poskramiacze z Łąk", "Gwiezdni Piloci", "Poskramiacze Zmierzchu", "Arena Żelaznej Pięści", "Królestwo Skoków", "Kart Rush", "Huśtawka w Dżungli", "Miasto Mako", "Biegacz po Gzymsach", "Szczenięce Dni", "Spadające Bloki"],
        "ro": ["Îmblânzitorii Coralilor", "Insulele Mareei", "Circuitul Apex", "Săritorul Insulelor", "Îmblânzitorii Pajiștii", "Piloții Stelelor", "Îmblânzitorii Amurgului", "Arena Pumnului de Fier", "Regatul Săriturilor", "Kart Rush", "Liana Junglei", "Orașul Mako", "Alergătorul pe Cornișe", "Zile de Cățeluș", "Căderea Blocurilor"],
        "ja": ["コーラルテイマーズ", "潮風の島々", "アペックスサーキット", "アイランドホッパー", "草原テイマーズ", "スターパイロット", "夕暮れテイマーズ", "アイアンフィスト・アリーナ", "バウンス王国", "カートラッシュ", "ジャングルスウィング", "緑光の街", "レッジランナー", "子犬の日々", "ブロックドロップ"],
        "ko": ["코랄 테이머즈", "조수의 섬들", "에이펙스 서킷", "아일랜드 호퍼", "초원 테이머즈", "스타 파일럿", "황혼 테이머즈", "아이언 피스트 아레나", "바운스 왕국", "카트 러시", "정글 스윙", "마코 시티", "레지 러너", "강아지의 나날", "블록 드롭"],
        "zh-Hant": ["珊瑚馴獸師", "潮風群島", "頂點賽道", "跳島冒險", "草原馴獸師", "星際飛行員", "暮色馴獸師", "鋼拳競技場", "彈跳王國", "卡丁狂飆", "叢林盪索", "綠光之城", "岩架跑者", "小狗時光", "方塊墜落"],
    ]

    static let catalogue: [Demo] = [
        Demo(system: "gba", asset: "demo-gba-1", title: "Coral Tamers"),
        Demo(system: "nds", asset: "demo-nds-3", title: "Tidewind Isles"),
        Demo(system: "ps1", asset: "demo-ps1-1", title: "Apex Circuit"),
        Demo(system: "snes", asset: "demo-snes-2", title: "Island Hopper"),
        Demo(system: "gb", asset: "demo-gb-1", title: "Meadow Tamers"),
        Demo(system: "nes", asset: "demo-nes-1", title: "Star Pilots"),
        Demo(system: "gbc", asset: "demo-gbc-1", title: "Dusk Tamers"),
        Demo(system: "ps1", asset: "demo-ps1-3", title: "Iron Fist Arena"),
        Demo(system: "nds", asset: "demo-nds-1", title: "Bounce Kingdom"),
        Demo(system: "gba", asset: "demo-gba-2", title: "Kart Rush"),
        Demo(system: "snes", asset: "demo-snes-1", title: "Jungle Swing"),
        Demo(system: "ps1", asset: "demo-ps1-2", title: "Mako City"),
        Demo(system: "gbc", asset: "demo-gbc-3", title: "Ledge Runner"),
        Demo(system: "nds", asset: "demo-nds-2", title: "Puppy Days"),
        Demo(system: "gb", asset: "demo-gb-2", title: "Block Drop"),
    ]

    /// A demo game's stored path starts with this; nothing on disk does.
    static let pathPrefix = "demo/"

    /// Kept alive for the lifetime of the demo objects.
    private static var demoContainer: NSPersistentContainer?

    /// The fake library, created once on first use, in the catalogue's order
    /// (which is also its last-played order: the first was played an hour
    /// ago, then a little over a day apart, so the "played … ago" lines read
    /// as a library in use).
    static let games: [GameEntity] = {
        let model = PersistenceController.shared.container.managedObjectModel
        let container = NSPersistentContainer(name: "EmulateurGBA", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, _ in }
        demoContainer = container
        let context = container.viewContext
        let now = Date()
        let localized = titles[titleLanguage] ?? titles["en"]!
        return catalogue.enumerated().map { index, demo in
            let game = GameEntity(context: context)
            game.id = UUID()
            game.title = localized.indices.contains(index) ? localized[index] : demo.title
            game.systemType = demo.system
            game.romFilePath = pathPrefix + demo.asset
            game.romHash = "demo-" + demo.asset
            game.romSize = 0
            game.importedAt = now.addingTimeInterval(-Double(index + 1) * 86_400 * 3)
            game.lastPlayedAt = now.addingTimeInterval(-3_600 - Double(index) * 86_400 * 1.4)
            game.coverType = nil
            return game
        }
    }()

    private static var coverCache: [String: UIImage] = [:]

    /// The bundled cover of a demo game, nil for a real one.
    static func cover(forROMPath path: String?) -> UIImage? {
        guard let path, path.hasPrefix(pathPrefix) else { return nil }
        let asset = String(path.dropFirst(pathPrefix.count))
        if let cached = coverCache[asset] { return cached }
        guard let url = Bundle.main.url(forResource: asset, withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        coverCache[asset] = image
        return image
    }
}
