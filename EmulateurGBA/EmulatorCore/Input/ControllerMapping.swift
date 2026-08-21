//
//  ControllerMapping.swift
//  EmulateurGBA
//
//  Controller button remapping (1.2.4, Pro — wave one): which PHYSICAL pad
//  button drives which CONSOLE input, per console family, global across games.
//  The D-pad and left stick always steer the console D-pad — direction
//  remapping serves nobody and doubles the UI, so wave one excludes it (wave
//  two, full inputs incl. app verbs, is a separate evaluation).
//
//  Storage: one mapping per PresetSystem in UserDefaults (JSON). No stored
//  mapping = the built-in behavior, byte-identical to pre-1.2.4 (including
//  the Select = Options OR L3 double source, which a custom mapping replaces
//  with its explicit assignments). The EFFECTIVE mapping is nil for non-Pro
//  (defense in depth: the UI gates entry, this gates a lapsed Pro too).
//

import Foundation

/// The remappable console inputs. Raw values are the storage keys.
enum RemappableInput: String, Codable, CaseIterable {
    case a, b, x, y, l, r, select, start

    var gbaInput: GBAInput {
        switch self {
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        case .l: return .l
        case .r: return .r
        case .select: return .select
        case .start: return .start
        }
    }

    /// Console-face label ("A", "SELECT", …) — universal, unlocalized.
    var displayName: String {
        switch self {
        case .select: return "SELECT"
        case .start: return "START"
        default: return rawValue.uppercased()
        }
    }

    /// The inputs a console family actually has (GB/GBC: no X/Y, no shoulders;
    /// GBA: no X/Y).
    static func available(on system: PresetSystem) -> [RemappableInput] {
        switch system {
        case .gbc: return [.a, .b, .select, .start]
        case .gba: return [.a, .b, .l, .r, .select, .start]
        case .nds: return [.a, .b, .x, .y, .l, .r, .select, .start]
        case .snes: return [.a, .b, .x, .y, .l, .r, .select, .start]
        case .nes: return [.a, .b, .select, .start]
        }
    }
}

/// The physical pad controls a mapping can bind (GCExtendedGamepad terms).
enum PhysicalButton: String, Codable, CaseIterable {
    case faceA, faceB, faceX, faceY
    case shoulderL, shoulderR
    case menu, options, leftStickClick
    case leftTrigger, rightTrigger, rightStickClick   // wave 2: L2/R2/R3

    /// Generic short label — the fallback when the pad's family is unknown.
    var displayName: String {
        switch self {
        case .faceA: return "A"
        case .faceB: return "B"
        case .faceX: return "X"
        case .faceY: return "Y"
        case .shoulderL: return "L"
        case .shoulderR: return "R"
        case .menu: return "Menu"
        case .options: return "Options"
        case .leftStickClick: return "L3"
        case .leftTrigger: return "L2"
        case .rightTrigger: return "R2"
        case .rightStickClick: return "R3"
        }
    }

    /// Pad-accurate label for the connected controller's family — what is
    /// actually printed on the button the user is holding (PlayStation glyphs,
    /// Xbox LB/RB/View, Switch's positionally-swapped letters), falling back
    /// to the generic GC names. Unlocalized: these are the buttons' own marks.
    func displayName(for style: ControllerStyle) -> String {
        switch style {
        case .playStation(let create):
            switch self {
            case .faceA: return "✕"
            case .faceB: return "◯"
            case .faceX: return "□"
            case .faceY: return "△"
            case .shoulderL: return "L1"
            case .shoulderR: return "R1"
            case .leftTrigger: return "L2"
            case .rightTrigger: return "R2"
            case .menu: return "Options"
            case .options: return create ? "Create" : "Share"
            case .leftStickClick: return "L3"
            case .rightStickClick: return "R3"
            }
        case .xbox:
            switch self {
            case .shoulderL: return "LB"
            case .shoulderR: return "RB"
            case .leftTrigger: return "LT"
            case .rightTrigger: return "RT"
            case .menu: return "Menu"
            case .options: return "View"
            case .leftStickClick: return "LS"
            case .rightStickClick: return "RS"
            default: return displayName
            }
        case .switchPro:
            // GCController maps by POSITION (buttonA = south); Switch letters
            // sit swapped relative to Xbox, so the labels swap back here.
            switch self {
            case .faceA: return "B"
            case .faceB: return "A"
            case .faceX: return "Y"
            case .faceY: return "X"
            case .leftTrigger: return "ZL"
            case .rightTrigger: return "ZR"
            case .menu: return "+"
            case .options: return "−"
            default: return displayName
            }
        case .generic:
            return displayName
        }
    }
}

/// The connected pad's vendor family, for pad-accurate button names in the
/// remap UI. Derived from GCController.productCategory by substring so new
/// category strings degrade to `.generic`, never crash.
enum ControllerStyle: Equatable {
    /// `create` = DualSense (its share button is printed "Create"; the
    /// DualShock 4's is "Share").
    case playStation(create: Bool)
    case xbox
    case switchPro
    case generic

    static func from(productCategory: String?) -> ControllerStyle {
        let category = productCategory?.lowercased() ?? ""
        if category.contains("dualsense") { return .playStation(create: true) }
        if category.contains("dualshock") { return .playStation(create: false) }
        if category.contains("xbox") { return .xbox }
        if category.contains("switch") { return .switchPro }
        return .generic
    }
}

/// App-verb shortcuts a pad button can trigger (wave 2). UNBOUND by default —
/// the correspondence exists only once the user defines it.
enum RemapAction: String, Codable, CaseIterable {
    case fastForward = "fast-forward"
    case screenshot
    case clip

    /// Localization key of the row label.
    var labelKey: String {
        switch self {
        case .fastForward: return "remap.action.fastForward"
        case .screenshot: return "remap.action.screenshot"
        case .clip: return "remap.action.clip"
        }
    }
}

/// One console family's mapping: console input → the physical button that
/// drives it. Two console inputs MAY share a physical button (a deliberate
/// user choice — e.g. one button pressing A+B); the remap UI shows every
/// assignment so nothing is hidden.
struct ControllerMapping: Codable, Equatable {
    var assignments: [RemappableInput: PhysicalButton]
    /// Wave-2 shortcut verbs, UNBOUND by default.
    var actions: [RemapAction: PhysicalButton]

    init(assignments: [RemappableInput: PhysicalButton],
         actions: [RemapAction: PhysicalButton] = [:]) {
        self.assignments = assignments
        self.actions = actions
    }

    /// Custom decode so mappings persisted before wave 2 (no `actions` key)
    /// keep loading; encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try container.decode([RemappableInput: PhysicalButton].self, forKey: .assignments)
        actions = try container.decodeIfPresent([RemapAction: PhysicalButton].self, forKey: .actions) ?? [:]
    }

    /// The built-in layout, as the guided UI's starting point and reset
    /// target. (Select maps to Options here; the built-in NO-mapping path
    /// additionally accepts L3 for pads without an Options button — a custom
    /// mapping is explicit and can bind L3 by hand.)
    static func defaults(for system: PresetSystem) -> ControllerMapping {
        var a: [RemappableInput: PhysicalButton] = [
            .a: .faceA, .b: .faceB, .select: .options, .start: .menu,
        ]
        for input in RemappableInput.available(on: system) {
            switch input {
            // Positional, matching the built-in mask: the NDS puts X north and
            // Y west; GC's faceX is west, faceY north — so they cross.
            case .x: a[.x] = .faceY
            case .y: a[.y] = .faceX
            case .l: a[.l] = .shoulderL
            case .r: a[.r] = .shoulderR
            default: break
            }
        }
        return ControllerMapping(assignments: a)
    }
}

enum ControllerMappingStore {

    private static func key(for system: PresetSystem) -> String {
        "controllerMapping_\(system.rawValue)"
    }

    /// The user's stored mapping, nil when never customized.
    static func stored(for system: PresetSystem) -> ControllerMapping? {
        guard let data = UserDefaults.standard.data(forKey: key(for: system)) else { return nil }
        return try? JSONDecoder().decode(ControllerMapping.self, from: data)
    }

    static func save(_ mapping: ControllerMapping, for system: PresetSystem) {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        UserDefaults.standard.set(data, forKey: key(for: system))
    }

    static func reset(for system: PresetSystem) {
        UserDefaults.standard.removeObject(forKey: key(for: system))
    }

    /// The mapping actually applied to input: the stored one for Pro, nil
    /// (built-in behavior) otherwise.
    static func effective(for system: PresetSystem) -> ControllerMapping? {
        guard UserDefaults.standard.bool(forKey: "isPro") else { return nil }
        return stored(for: system)
    }
}
