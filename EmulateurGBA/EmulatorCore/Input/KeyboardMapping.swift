//
//  KeyboardMapping.swift
//  EmulateurGBA
//
//  Hardware keyboard remapping (1.3.1, FREE): which KEY drives which console
//  input, one mapping per console family like the pad's, global across games
//  (decided 2026-09-07: a keyboard is a controller and gets the controller's
//  model, so the two remap pages read the same way). The case that asked for
//  this is a Bluetooth gamepad that iOS only knows as a keyboard: the 8BitDo
//  Zero in its keyboard mode types one letter per button (a support mail,
//  2026-09-07).
//
//  The rule is the keyboard's own: one KEY drives one input, an input may
//  have several keys (both Shifts are Select in the built-in layout). That is
//  the reverse of the pad model, where two console inputs may share a button,
//  and it is what makes a capture unambiguous: pressing a key that is already
//  bound elsewhere MOVES it.
//
//  Free where pad remapping is Pro, on purpose: controller support has always
//  been free, and a keyboard-mode pad is unplayable until its letters are
//  bound, so gating this would make "controller support" paid for one class
//  of hardware.
//
//  Storage: one JSON per PresetSystem in UserDefaults. No stored mapping =
//  `builtIn`, the classic emulator layout by physical key position (arrows,
//  X/Z/S/A/Q/W, Return, Shift), plus the 8BitDo keyboard-mode letters, which
//  are disjoint from it, so that pad works with no setup at all. The built-in
//  layout is the same for every console; only the stored ones differ.
//

import Foundation
import GameController

/// Every console input a key can drive, directions included: a keyboard-mode
/// pad's D-pad is four letters, so unlike the pad model the directions must
/// be bindable. Raw values are the storage keys, and the button cases share
/// their raw values with `RemappableInput`, which is how `available(on:)`
/// borrows the pad's per-console list.
enum KeyboardInput: String, Codable, CaseIterable {
    case up, down, left, right
    case a, b, x, y, l, r, l2, r2, l3, r3, select, start

    var gbaInput: GBAInput {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        case .l: return .l
        case .r: return .r
        case .l2: return .l2
        case .r2: return .r2
        case .l3: return .l3
        case .r3: return .r3
        case .select: return .select
        case .start: return .start
        }
    }

    var isDirection: Bool {
        switch self {
        case .up, .down, .left, .right: return true
        default: return false
        }
    }

    static var directions: [KeyboardInput] { allCases.filter { $0.isDirection } }

    /// The buttons a console family actually has, the pad remap's own list
    /// (`RemappableInput.available(on:)`) read through the shared raw values.
    /// The built-in layout binds keys for every button regardless; a console
    /// without the button ignores the bit, as it does for a pad.
    static func buttons(on system: PresetSystem) -> [KeyboardInput] {
        RemappableInput.available(on: system).compactMap { KeyboardInput(rawValue: $0.rawValue) }
    }

    /// The row label: a direction is a localized word, a button is the
    /// console's own mark (universal, unlocalized), the same marks the pad
    /// remap rows use.
    var displayName: String {
        switch self {
        case .up: return NSLocalizedString("keyremap.direction.up", comment: "")
        case .down: return NSLocalizedString("keyremap.direction.down", comment: "")
        case .left: return NSLocalizedString("keyremap.direction.left", comment: "")
        case .right: return NSLocalizedString("keyremap.direction.right", comment: "")
        case .select: return "SELECT"
        case .start: return "START"
        default: return rawValue.uppercased()
        }
    }
}

/// The whole keyboard side of input: key → the console input it drives.
struct KeyboardMapping: Codable, Equatable {
    /// Keyed by `GCKeyCode.rawValue` (a USB HID usage, so a key counts by its
    /// POSITION and not by the letter printed on it, like every desktop
    /// emulator). Stored as Int because the key code type itself is not
    /// Codable.
    var keys: [Int: KeyboardInput]

    init(keys: [Int: KeyboardInput] = [:]) {
        self.keys = keys
    }

    func input(for code: GCKeyCode) -> KeyboardInput? {
        keys[Int(code.rawValue)]
    }

    /// Every key bound to `input`, in key-code order so a row reads the same
    /// way every time.
    func keyCodes(for input: KeyboardInput) -> [GCKeyCode] {
        keys.filter { $0.value == input }.keys.sorted().map { GCKeyCode(rawValue: $0) }
    }

    /// Bind one key. A key already bound to another input moves: one key,
    /// one input.
    mutating func bind(_ code: GCKeyCode, to input: KeyboardInput) {
        keys[Int(code.rawValue)] = input
    }

    /// Drop every key bound to `input`.
    mutating func clear(_ input: KeyboardInput) {
        keys = keys.filter { $0.value != input }
    }

    /// The bitmask for the keys currently down. Pure: `isPressed` answers for
    /// one key code, so the tests hand in a set and the manager hands in the
    /// live keyboard. Recomputed from every bound key rather than toggling one
    /// bit, so two keys on one input (both Shifts) release cleanly and a
    /// missed release cannot stick.
    static func mask(_ mapping: KeyboardMapping, isPressed: (GCKeyCode) -> Bool) -> UInt32 {
        var mask: UInt32 = 0
        for (raw, input) in mapping.keys where isPressed(GCKeyCode(rawValue: raw)) {
            mask |= input.gbaInput.rawValue
        }
        return mask
    }

    /// The layout with no stored mapping, and the reset target.
    ///
    /// First the classic emulator layout by physical position (the 1.2.4
    /// behaviour, byte for byte). Then the letters an 8BitDo pad types in its
    /// keyboard mode, verified for the first-generation Zero (its START+B
    /// mode) and the Zero 2: D-pad c d e f, A g, B j, X h, Y i, L k, R m,
    /// Select n, Start o. None of them collides with the classic keys, so the
    /// two layouts coexist and that pad works before anyone opens Settings.
    /// The Zero's second pairing mode (START+B+R, for a second player) types
    /// p q r a b s t u v w x y, five of which ARE classic keys, so it is left
    /// out; two players is not something the single-port bridge can carry
    /// yet in any case.
    static let builtIn: KeyboardMapping = {
        var mapping = KeyboardMapping()
        let layout: [(GCKeyCode, KeyboardInput)] = [
            (.upArrow, .up), (.downArrow, .down), (.leftArrow, .left), (.rightArrow, .right),
            (.keyX, .a), (.keyZ, .b), (.keyS, .x), (.keyA, .y),
            (.keyQ, .l), (.keyW, .r),
            (.returnOrEnter, .start), (.leftShift, .select), (.rightShift, .select),
            // 8BitDo keyboard mode.
            (.keyC, .up), (.keyD, .down), (.keyE, .left), (.keyF, .right),
            (.keyG, .a), (.keyJ, .b), (.keyH, .x), (.keyI, .y),
            (.keyK, .l), (.keyM, .r),
            (.keyN, .select), (.keyO, .start),
        ]
        for (code, input) in layout {
            mapping.bind(code, to: input)
        }
        return mapping
    }()
}

enum KeyboardMappingStore {

    private static func key(for system: PresetSystem) -> String {
        "keyboardMapping_\(system.rawValue)"
    }

    /// The user's stored mapping for that console, nil when never customized.
    static func stored(for system: PresetSystem) -> KeyboardMapping? {
        guard let data = UserDefaults.standard.data(forKey: key(for: system)) else { return nil }
        return try? JSONDecoder().decode(KeyboardMapping.self, from: data)
    }

    static func save(_ mapping: KeyboardMapping, for system: PresetSystem) {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        UserDefaults.standard.set(data, forKey: key(for: system))
    }

    static func reset(for system: PresetSystem) {
        UserDefaults.standard.removeObject(forKey: key(for: system))
    }

    /// The mapping actually applied to input for that console. No Pro gate:
    /// this is free.
    static func effective(for system: PresetSystem) -> KeyboardMapping {
        stored(for: system) ?? .builtIn
    }
}

/// What a key is called on a row. Letters, digits and punctuation are the
/// marks of a US keyboard, because the codes count by position (the same
/// caveat the controller guide states); the editing and modifier keys are the
/// glyphs Apple prints for them; Space is a word and is localized. Anything
/// outside the table asks the keyboard for its own name, then falls back to
/// the raw code so a row is never blank.
enum KeyboardKeyName {

    private static let names: [GCKeyCode: String] = [
        .keyA: "A", .keyB: "B", .keyC: "C", .keyD: "D", .keyE: "E", .keyF: "F", .keyG: "G",
        .keyH: "H", .keyI: "I", .keyJ: "J", .keyK: "K", .keyL: "L", .keyM: "M", .keyN: "N",
        .keyO: "O", .keyP: "P", .keyQ: "Q", .keyR: "R", .keyS: "S", .keyT: "T", .keyU: "U",
        .keyV: "V", .keyW: "W", .keyX: "X", .keyY: "Y", .keyZ: "Z",
        .one: "1", .two: "2", .three: "3", .four: "4", .five: "5",
        .six: "6", .seven: "7", .eight: "8", .nine: "9", .zero: "0",
        .upArrow: "↑", .downArrow: "↓", .leftArrow: "←", .rightArrow: "→",
        .returnOrEnter: "↩", .keypadEnter: "⌤", .tab: "⇥", .escape: "⎋", .capsLock: "⇪",
        .leftShift: "⇧", .rightShift: "⇧",
        .leftControl: "⌃", .rightControl: "⌃",
        .leftAlt: "⌥", .rightAlt: "⌥",
        .leftGUI: "⌘", .rightGUI: "⌘",
        .comma: ",", .period: ".", .slash: "/", .semicolon: ";", .quote: "'",
        .openBracket: "[", .closeBracket: "]", .backslash: "\\",
        .hyphen: "-", .equalSign: "=", .graveAccentAndTilde: "`",
    ]

    static func name(for code: GCKeyCode) -> String {
        if code == .spacebar { return NSLocalizedString("key.space", comment: "") }
        if let name = names[code] { return name }
        if let own = GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: code)?.localizedName,
           !own.isEmpty {
            return own
        }
        return "#\(code.rawValue)"
    }
}
