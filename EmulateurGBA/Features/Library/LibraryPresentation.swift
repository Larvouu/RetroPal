//
//  LibraryPresentation.swift
//  EmulateurGBA
//
//  Settings ▸ Debug ▸ "Presentation mode" (2026-09-10): the library shows a
//  FAKE library, thirty-three fictional games with bundled covers (three
//  per console, GB and GBC sharing three; the set redrawn 2026-10-14 after
//  App Review refused screenshots whose art evoked real games), in place of
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

    /// One fictional game per bundled cover. The English titles are the
    /// names the in-game screens were generated under (2026-10-14), each
    /// written natively in the fifteen languages (`titles`) so a Japanese
    /// shelf reads Japanese; `title` is the English one. The covers are
    /// `Resources/DemoLibrary/`, 640 points square, JPEG, 3.1 MB for the
    /// thirty-three, a square from the centre of each screen (the DS's top
    /// screen only).
    struct Demo {
        let system: String
        let asset: String
        let title: String
    }

    /// The titles in the catalogue's order, per language. Invented names,
    /// kept clear of real games' own words.
    static let titles: [String: [String]] = [
        "en": [
            "Moonwake Sailors",
            "Clockwork Canyon",
            "Canopy Run",
            "Mirelight",
            "Thornvale Chronicles",
            "Pocket Orchard",
            "Rustline Express",
            "Tidal Tumble",
            "Ember Peak",
            "Beacon Keeper",
            "Copperbell",
            "Lantern Moss",
            "Rainline Runner",
            "Silverkite Squadron",
            "Harbor Haulers",
            "Cloudhaven Drift",
            "Paperwing",
            "Kitebound Skies",
            "Glacier Mail",
            "Mossling Ranger",
            "Starlit Circus",
            "Acorn Hedge",
            "Tidepool Post",
            "Wildfern Lodge",
            "Coral Depths",
            "Stargazer Ranch",
            "Ashgrove Tactics",
            "Lumen Gardens",
            "Sundial Detectives",
            "Hollowmere Light",
            "Rooftop Parcel",
            "Sandglass Maze",
            "Starbarge",
        ],
        "fr": [
            "Marins du clair de lune",
            "Canyon mécanique",
            "Course des cimes",
            "Feu follet",
            "Chroniques de Valronce",
            "Mon petit verger",
            "Rouille Express",
            "Flipper des marées",
            "Pic des braises",
            "Le Gardien du phare",
            "Cloche de cuivre",
            "Mousse et lanterne",
            "Pluie de néon",
            "Escadrille d'argent",
            "Remorqueurs du port",
            "Au gré des nuages",
            "Aile de papier",
            "Vol libre",
            "Courrier des glaces",
            "Garde des moussillons",
            "Cirque des étoiles",
            "La Haie aux noisettes",
            "Poste des embruns",
            "Le Refuge des fougères",
            "Abysses de corail",
            "Ranch de la Belle Étoile",
            "Tactiques de la Frênaie",
            "Jardins de lumière",
            "Détectives du cadran solaire",
            "Lueur de Mornelac",
            "Colis sur les toits",
            "Le Dédale du sablier",
            "Barge stellaire",
        ],
        "de": [
            "Mondsegler",
            "Uhrwerk-Schlucht",
            "Wipfelsprint",
            "Irrlicht",
            "Die Chroniken von Dornental",
            "Mein kleiner Obstgarten",
            "Rost-Express",
            "Gezeiten-Flipper",
            "Glutgipfel",
            "Der Leuchtturmwärter",
            "Kupferglocke",
            "Laternenmoos",
            "Neonregen",
            "Staffel Silbermilan",
            "Hafenschlepper",
            "Fahrt nach Wolkenhafen",
            "Papierflügel",
            "Himmel der Drachenflieger",
            "Gletscherpost",
            "Mooslinghüter",
            "Sternenzirkus",
            "Haselhecke",
            "Post am Priel",
            "Hütte im Farnwald",
            "Korallentiefen",
            "Sternblick-Ranch",
            "Eschenhain-Taktik",
            "Lichtergärten",
            "Die Sonnenuhr-Detektive",
            "Das Licht von Hohlensee",
            "Paket über den Dächern",
            "Das Sanduhr-Labyrinth",
            "Sternenfrachter",
        ],
        "es": [
            "Navegantes de la luna",
            "Cañón de engranajes",
            "Carrera arbórea",
            "Fuego fatuo",
            "Crónicas de Valzarza",
            "Mi pequeño huerto",
            "El expreso oxidado",
            "Pinball de las mareas",
            "Pico de las brasas",
            "El guardián del faro",
            "Campana de cobre",
            "Musgo y farol",
            "Lluvia de neón",
            "Escuadrón Milano de Plata",
            "Remolcadores del puerto",
            "A la deriva entre nubes",
            "Ala de papel",
            "Cielos de ala delta",
            "Correo glaciar",
            "Guardabosques de musgo",
            "Circo de las estrellas",
            "Laberinto de bellotas",
            "Cartero del muelle",
            "Refugio de los helechos",
            "Abismos de coral",
            "Rancho bajo las estrellas",
            "Tácticas de Fresneda",
            "Jardines de luz",
            "Detectives del reloj de sol",
            "La luz de Hondolago",
            "Mensajero de los tejados",
            "El laberinto del reloj de arena",
            "Barcaza estelar",
        ],
        "es-MX": [
            "Navegantes de la luna",
            "Cañón de engranajes",
            "Carrera arbórea",
            "Fuego fatuo",
            "Crónicas de Valzarza",
            "Mi pequeña huerta",
            "El expreso oxidado",
            "Pinball de las mareas",
            "Pico de las brasas",
            "El guardián del faro",
            "Campana de cobre",
            "Musgo y farol",
            "Lluvia de neón",
            "Escuadrón Milano de Plata",
            "Remolcadores del puerto",
            "A la deriva entre nubes",
            "Ala de papel",
            "Cielos de ala delta",
            "Correo glaciar",
            "Guardabosques de musgo",
            "Circo de las estrellas",
            "Laberinto de bellotas",
            "Cartero del muelle",
            "Refugio de los helechos",
            "Abismos de coral",
            "Rancho bajo las estrellas",
            "Tácticas de Fresneda",
            "Jardines de luz",
            "Detectives del reloj de sol",
            "La luz de Hondolago",
            "Mensajero de los tejados",
            "El laberinto del reloj de arena",
            "Barcaza estelar",
        ],
        "it": [
            "Marinai della luna",
            "Canyon degli ingranaggi",
            "Corsa tra le fronde",
            "Fuoco fatuo",
            "Cronache di Valspina",
            "Il mio piccolo frutteto",
            "Ruggine Express",
            "Flipper delle maree",
            "Picco delle braci",
            "Il guardiano del faro",
            "Campana di rame",
            "Muschio e lanterna",
            "Pioggia al neon",
            "Squadriglia Nibbio d'Argento",
            "Rimorchiatori del porto",
            "Alla deriva tra le nuvole",
            "Ala di carta",
            "Cieli in deltaplano",
            "Posta dei ghiacciai",
            "Il guardiano dei muschietti",
            "Circo delle stelle",
            "La siepe delle ghiande",
            "Postino del molo",
            "Il rifugio delle felci",
            "Abissi di corallo",
            "Ranch sotto le stelle",
            "Tattiche di Frassineto",
            "Giardini di luce",
            "Detective della meridiana",
            "La luce di Lagocupo",
            "Pacchi sui tetti",
            "Il labirinto della clessidra",
            "Chiatta stellare",
        ],
        "pt-BR": [
            "Marinheiros da lua",
            "Cânion das engrenagens",
            "Corrida nas copas",
            "Fogo-fátuo",
            "Crônicas de Espinhal",
            "Meu pequeno pomar",
            "Expresso Ferrugem",
            "Pinball das marés",
            "Pico das brasas",
            "O guardião do farol",
            "Sino de cobre",
            "Musgo e lanterna",
            "Chuva de neon",
            "Esquadrilha Falcão de Prata",
            "Rebocadores do porto",
            "À deriva nas nuvens",
            "Asa de papel",
            "Céus de asa-delta",
            "Correio das geleiras",
            "O guarda dos musguinhos",
            "Circo das estrelas",
            "Labirinto das bolotas",
            "Carteiro do píer",
            "Refúgio das samambaias",
            "Abismos de coral",
            "Rancho sob as estrelas",
            "Táticas de Freixal",
            "Jardins de luz",
            "Detetives do relógio de sol",
            "A luz de Lagofundo",
            "Entrega nos telhados",
            "O labirinto da ampulheta",
            "Barcaça estelar",
        ],
        "pt-PT": [
            "Marinheiros da lua",
            "Desfiladeiro das engrenagens",
            "Corrida nas copas",
            "Fogo-fátuo",
            "Crónicas de Espinhal",
            "O meu pequeno pomar",
            "Expresso Ferrugem",
            "Flippers das marés",
            "Pico das brasas",
            "O guardião do farol",
            "Sino de cobre",
            "Musgo e lanterna",
            "Chuva de néon",
            "Esquadrilha Milhafre de Prata",
            "Rebocadores do porto",
            "À deriva nas nuvens",
            "Asa de papel",
            "Céus de asa-delta",
            "Correio dos glaciares",
            "O guarda dos musguinhos",
            "Circo das estrelas",
            "A sebe das bolotas",
            "Carteiro do cais",
            "Refúgio dos fetos",
            "Abismos de coral",
            "Rancho sob as estrelas",
            "Táticas de Freixal",
            "Jardins de luz",
            "Detetives do relógio de sol",
            "A luz de Lagofundo",
            "Entregas nos telhados",
            "O labirinto da ampulheta",
            "Barcaça estelar",
        ],
        "nl": [
            "Maanzeilers",
            "Uurwerkkloof",
            "Boomtoppenrace",
            "Dwaallicht",
            "De kronieken van Doorndal",
            "Mijn kleine boomgaard",
            "Roestexpress",
            "Getijdenflipper",
            "Sintelpiek",
            "De vuurtorenwachter",
            "Koperklok",
            "Lantaarnmos",
            "Neonregen",
            "Eskader Zilveren Wouw",
            "Havensleepers",
            "Wolkendrift",
            "Papieren vleugel",
            "Hemel vol deltavliegers",
            "Gletsjerpost",
            "De moslingwachter",
            "Sterrencircus",
            "Eikelhaag",
            "Post op de pier",
            "Hut in het varenwoud",
            "Koraaldiepten",
            "Sterrenkijkersranch",
            "Tactiek van Essenhof",
            "Tuinen van licht",
            "De zonnewijzerdetectives",
            "Het licht van Holmeer",
            "Pakketje over de daken",
            "Het zandloperdoolhof",
            "Sterrenaak",
        ],
        "sv": [
            "Månseglarna",
            "Urverkskanjonen",
            "Trädtoppsloppet",
            "Irrbloss",
            "Krönikan om Törndal",
            "Min lilla fruktträdgård",
            "Rostexpressen",
            "Tidvattenflipper",
            "Glödtoppen",
            "Fyrvaktaren",
            "Kopparklockan",
            "Lyktmossen",
            "Neonregn",
            "Eskader Silverglada",
            "Hamnbogserarna",
            "Molndrift",
            "Pappersvingen",
            "Hängglidarhimlen",
            "Glaciärposten",
            "Mosslingväktaren",
            "Stjärncirkusen",
            "Ekollonhäcken",
            "Bryggposten",
            "Ormbunksstugan",
            "Koralldjupen",
            "Stjärnskådarranchen",
            "Slaget om Asklunden",
            "Ljusträdgården",
            "Solursdetektiverna",
            "Ljuset vid Hålsjön",
            "Paket över taken",
            "Timglaslabyrinten",
            "Stjärnpråmen",
        ],
        "pl": [
            "Księżycowi żeglarze",
            "Kanion zębatek",
            "Bieg po koronach drzew",
            "Błędny ognik",
            "Kroniki Cierniodołu",
            "Mój mały sad",
            "Rdzawy ekspres",
            "Pinball przypływów",
            "Szczyt żaru",
            "Strażnik latarni",
            "Miedziany dzwon",
            "Mech i latarnia",
            "Neonowy deszcz",
            "Eskadra Srebrnej Kani",
            "Holowniki z portu",
            "Dryf wśród chmur",
            "Papierowe skrzydło",
            "Niebo lotniarzy",
            "Lodowcowa poczta",
            "Strażnik mchowików",
            "Gwiezdny cyrk",
            "Żołędziowy żywopłot",
            "Poczta na molo",
            "Chata wśród paproci",
            "Koralowe głębiny",
            "Ranczo pod gwiazdami",
            "Taktyka Jesionowego Gaju",
            "Ogrody światła",
            "Detektywi zegara słonecznego",
            "Światło mrocznej toni",
            "Paczka po dachach",
            "Labirynt klepsydry",
            "Gwiezdna barka",
        ],
        "ro": [
            "Marinarii lunii",
            "Canionul mecanic",
            "Cursa prin frunziș",
            "Focul rătăcitor",
            "Cronicile din Valea Spinilor",
            "Mica mea livadă",
            "Expresul ruginit",
            "Pinball-ul mareelor",
            "Vârful de jar",
            "Paznicul farului",
            "Clopotul de aramă",
            "Mușchi și felinar",
            "Ploaie de neon",
            "Escadrila Șoimul de Argint",
            "Remorcherele portului",
            "În derivă printre nori",
            "Aripa de hârtie",
            "Ceruri cu deltaplane",
            "Poșta ghețarilor",
            "Paznicul pădurii de mușchi",
            "Circul stelelor",
            "Labirintul de ghinde",
            "Poștașul de pe debarcader",
            "Cabana dintre ferigi",
            "Adâncurile de corali",
            "Ferma de sub stele",
            "Tactici în Frăsinet",
            "Grădinile luminii",
            "Detectivii cadranului solar",
            "Lumina din Lacul Adânc",
            "Colet pe acoperișuri",
            "Labirintul clepsidrei",
            "Barja stelară",
        ],
        "ja": [
            "月影の船乗り",
            "からくり渓谷",
            "こずえを駆けろ！",
            "沼灯り",
            "ソーンヴェイル戦記",
            "ポケット果樹園",
            "赤錆特急",
            "潮騒ピンボール",
            "灼熱の峰",
            "灯台守",
            "あかがねの鐘",
            "ランタンの森",
            "レインライン・ランナー",
            "銀鳶飛行隊",
            "みなとタグボート",
            "雲の港へ",
            "紙ひこうき",
            "浮島の空",
            "氷河の郵便屋さん",
            "コケモリ・レンジャー",
            "星空サーカス",
            "どんぐり迷路",
            "潮だまり郵便局",
            "シダの山小屋",
            "珊瑚の深淵",
            "星見の牧場",
            "アッシュグローブ・タクティクス",
            "灯りの庭",
            "日時計探偵団",
            "ホロウミアの灯",
            "屋根の上の宅配便",
            "砂時計の迷宮",
            "スターバージ",
        ],
        "ko": [
            "달빛 선원들",
            "태엽 협곡",
            "우듬지 질주",
            "도깨비불",
            "손베일 연대기",
            "나의 작은 과수원",
            "녹슨 특급열차",
            "파도 핀볼",
            "불씨 봉우리",
            "등대지기",
            "구리 종",
            "랜턴과 이끼 숲",
            "레인라인 러너",
            "은빛 솔개 비행대",
            "항구 예인선",
            "구름 항구로",
            "종이날개",
            "떠다니는 섬의 하늘",
            "빙하 우편배달부",
            "이끼요정 레인저",
            "별빛 서커스",
            "도토리 미로",
            "부둣가 우체부",
            "고사리 숲 산장",
            "산호의 심연",
            "별 보는 목장",
            "애시그로브 택틱스",
            "빛의 정원",
            "해시계 탐정단",
            "할로우미어의 등불",
            "지붕 위의 택배",
            "모래시계 미궁",
            "별의 바지선",
        ],
        "zh-Hant": [
            "月光航海者",
            "齒輪峽谷",
            "樹梢狂奔",
            "沼澤鬼火",
            "荊棘谷編年史",
            "口袋果園",
            "鏽軌特快",
            "潮汐彈珠台",
            "餘燼之峰",
            "燈塔看守人",
            "銅鐘塔",
            "提燈與苔林",
            "雨線疾行",
            "銀鳶飛行中隊",
            "港口拖船隊",
            "雲港漂流",
            "紙翼",
            "浮島滑翔",
            "冰河郵差",
            "苔靈遊俠",
            "星光馬戲團",
            "橡實迷宮",
            "碼頭郵差",
            "蕨林小屋",
            "珊瑚深淵",
            "觀星牧場",
            "梣林戰略",
            "流光花園",
            "日晷偵探團",
            "幽湖之光",
            "屋頂快遞",
            "沙漏迷宮",
            "星際駁船",
        ],
    ]

    static let catalogue: [Demo] = [
        Demo(system: "psp", asset: "demo-psp-moonwake-sailors", title: "Moonwake Sailors"),
        Demo(system: "md", asset: "demo-md-clockwork-canyon", title: "Clockwork Canyon"),
        Demo(system: "n64", asset: "demo-n64-canopy-run", title: "Canopy Run"),
        Demo(system: "gba", asset: "demo-gba-mirelight", title: "Mirelight"),
        Demo(system: "snes", asset: "demo-snes-thornvale-chronicles", title: "Thornvale Chronicles"),
        Demo(system: "nds", asset: "demo-nds-pocket-orchard", title: "Pocket Orchard"),
        Demo(system: "ps1", asset: "demo-ps1-rustline-express", title: "Rustline Express"),
        Demo(system: "gg", asset: "demo-gg-tidal-tumble", title: "Tidal Tumble"),
        Demo(system: "sms", asset: "demo-sms-ember-peak", title: "Ember Peak"),
        Demo(system: "nes", asset: "demo-nes-beacon-keeper", title: "Beacon Keeper"),
        Demo(system: "gbc", asset: "demo-gbc-copperbell", title: "Copperbell"),
        Demo(system: "gb", asset: "demo-gb-lantern-moss", title: "Lantern Moss"),
        Demo(system: "psp", asset: "demo-psp-rainline-runner", title: "Rainline Runner"),
        Demo(system: "md", asset: "demo-md-silverkite-squadron", title: "Silverkite Squadron"),
        Demo(system: "n64", asset: "demo-n64-harbor-haulers", title: "Harbor Haulers"),
        Demo(system: "gba", asset: "demo-gba-cloudhaven-drift", title: "Cloudhaven Drift"),
        Demo(system: "snes", asset: "demo-snes-paperwing", title: "Paperwing"),
        Demo(system: "nds", asset: "demo-nds-kitebound-skies", title: "Kitebound Skies"),
        Demo(system: "ps1", asset: "demo-ps1-glacier-mail", title: "Glacier Mail"),
        Demo(system: "gg", asset: "demo-gg-mossling-ranger", title: "Mossling Ranger"),
        Demo(system: "sms", asset: "demo-sms-starlit-circus", title: "Starlit Circus"),
        Demo(system: "nes", asset: "demo-nes-acorn-hedge", title: "Acorn Hedge"),
        Demo(system: "gb", asset: "demo-gb-tidepool-post", title: "Tidepool Post"),
        Demo(system: "psp", asset: "demo-psp-wildfern-lodge", title: "Wildfern Lodge"),
        Demo(system: "md", asset: "demo-md-coral-depths", title: "Coral Depths"),
        Demo(system: "n64", asset: "demo-n64-stargazer-ranch", title: "Stargazer Ranch"),
        Demo(system: "gba", asset: "demo-gba-ashgrove-tactics", title: "Ashgrove Tactics"),
        Demo(system: "snes", asset: "demo-snes-lumen-gardens", title: "Lumen Gardens"),
        Demo(system: "nds", asset: "demo-nds-sundial-detectives", title: "Sundial Detectives"),
        Demo(system: "ps1", asset: "demo-ps1-hollowmere-light", title: "Hollowmere Light"),
        Demo(system: "gg", asset: "demo-gg-rooftop-parcel", title: "Rooftop Parcel"),
        Demo(system: "sms", asset: "demo-sms-sandglass-maze", title: "Sandglass Maze"),
        Demo(system: "nes", asset: "demo-nes-starbarge", title: "Starbarge"),
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
