//
//  ControlLayoutModels.swift
//  EmulateurGBA
//
//  Data models for custom control layouts and presets.
//

import CoreGraphics

/// Identifies every movable element in the controls overlay.
enum ControlElement: String, Codable, CaseIterable {
    // GBA base buttons
    case dpad, btnA, btnB, btnL, btnR, btnStart, btnSelect, btnMenu, btnClip
    // NDS additions
    case btnX, btnY, btnMic
    // PlayStation additions: the second pair of shoulders, and the pad's own
    // ANALOG switch. The first new elements since the DS. Appended, never
    // reordered: the raw values are what a saved preset stores.
    case btnL2, btnR2, btnMode
    // The two analog sticks. Separate elements rather than one, because they do
    // unrelated jobs: the left one moves the character, the right one moves the
    // camera, and a player repositioning one has no reason to want the other to
    // follow. They sit BESIDE the cross rather than replacing it, as on the pad.
    case stickLeft, stickRight
    // The stick CLICKS, as buttons of their own rather than as a tap on the
    // stick. A stick is DRAGGED, and a control that is dragged cannot also
    // report a press without one becoming the other's accident. These sit
    // beside their stick and answer only to a deliberate hold.
    case btnL3, btnR3

    /// Elements present on GBA (full Game Boy Advance button set, incl. L/R).
    static let gbaElements: [ControlElement] = [.dpad, .btnA, .btnB, .btnL, .btnR, .btnStart, .btnSelect, .btnMenu, .btnClip]

    /// Elements present on GB / GBC: the GBA set minus the L/R shoulder buttons,
    /// which GB/GBC hardware does not have.
    static let gbcElements: [ControlElement] = [.dpad, .btnA, .btnB, .btnStart, .btnSelect, .btnMenu, .btnClip]

    /// Elements present on NDS (all GBA + X/Y/Mic).
    ///
    /// No longer `allCases`: that was true while the DS had every element there
    /// was, and the PlayStation's second shoulder pair ended it. Spelled out so
    /// adding an element to another console can never silently appear on the DS.
    static let ndsElements: [ControlElement] =
        [.dpad, .btnA, .btnB, .btnL, .btnR, .btnStart, .btnSelect, .btnMenu, .btnClip,
         .btnX, .btnY, .btnMic]

    /// Elements present on the SNES: the DS set without the microphone. The pad is
    /// the same shape — four face buttons in a diamond plus two shoulders — which
    /// is why no new element had to be invented for it.
    static let snesElements: [ControlElement] = ndsElements.filter { $0 != .btnMic }

    /// Elements present on the PlayStation: the SNES set plus L2 and R2.
    ///
    /// The widest pad the app carries, and the first that needed a new element.
    /// The two sticks ARE here: they are drawn on the glass and dragged with a
    /// thumb, so they are laid out like any other control. (An earlier draft of
    /// this list left them out on the theory that a stick could only arrive from
    /// a physical pad; the comment outlived the decision by several rounds.)
    static let ps1Elements: [ControlElement] =
        snesElements + [.btnL2, .btnR2, .btnMode, .stickLeft, .stickRight,
                        .btnL3, .btnR3]

    /// The element set for a given system — the single source of truth used by the
    /// store, the in-game controls, and the editor so they never drift apart.
    static func elements(for system: PresetSystem) -> [ControlElement] {
        switch system {
        case .nds: return ndsElements
        case .gba: return gbaElements
        case .gbc: return gbcElements
        case .snes: return snesElements
        // The NES pad is the Game Boy's exactly: D-pad, two buttons, Start and
        // Select. It shares the set rather than declaring an identical one.
        case .nes: return gbcElements
        case .ps1: return ps1Elements
        }
    }

    /// Human-readable name for display in the editor.
    var displayName: String {
        switch self {
        // Named for the button they PRESS, not the stick they sit beside: a
        // player moving "L3" in the editor is placing the click, and the stick
        // is a separate element they can place separately.
        case .btnL3: return "L3"
        case .btnR3: return "R3"
        case .dpad: return "D-Pad"
        case .btnA: return "A"
        case .btnB: return "B"
        case .btnL: return "L"
        case .btnR: return "R"
        case .btnStart: return "Start"
        case .btnSelect: return "Select"
        case .btnMenu: return "Menu"
        case .btnX: return "X"
        case .btnY: return "Y"
        case .btnMic: return "Mic"
        case .btnClip: return "Clip"
        case .btnL2: return "L2"
        case .btnR2: return "R2"
        case .btnMode: return "Mode"
        case .stickLeft: return "Left Stick"
        case .stickRight: return "Right Stick"
        }
    }

    /// The name the CONSOLE prints on that control, which is what the editor has
    /// to show.
    ///
    /// `displayName` above stays generic: it is what a control is called in code
    /// and on every console that prints nothing different. The PlayStation prints
    /// three of them differently, and the editor was showing the generic name for
    /// all three -- a player customising the pad read "L", "R" and "Mode" while
    /// the game under it reads L1, R1 and ANALOG. `PS1TouchControlsView` sets
    /// those three titles for the game; this is the same answer for the editor,
    /// in one place so the two cannot drift again. ANALOG in particular is a
    /// settled decision (2026-08-24): it is the word Sony silkscreens, and the
    /// What's New string was corrected to it while this one was missed.
    func displayName(for system: PresetSystem) -> String {
        guard system == .ps1 else { return displayName }
        switch self {
        case .btnL: return "L1"
        case .btnR: return "R1"
        case .btnMode: return "ANALOG"
        default: return displayName
        }
    }

    /// Default width in points (before controlScale is applied).
    var defaultSize: CGSize {
        switch self {
        case .dpad:      return CGSize(width: 165, height: 165)
        case .btnA:      return CGSize(width: 72.6, height: 72.6)
        case .btnB:      return CGSize(width: 63.8, height: 63.8)
        case .btnX:      return CGSize(width: 63.8, height: 63.8)
        case .btnY:      return CGSize(width: 63.8, height: 63.8)
        case .btnL:      return CGSize(width: 90, height: 35.2)   // GBA portrait: 20% thinner (was 44)
        case .btnR:      return CGSize(width: 90, height: 35.2)   // NDS portrait keeps its own 70x36
        // The PlayStation's second shoulder pair is the same bar as the first.
        // How four of them fit is a LAYOUT answer and it changed: they are one
        // line of four across, paid for by `ps1PortraitShoulderWidth` (55) and
        // `ps1PortraitShoulderHeightScale`, rather than the stacked pairs an
        // earlier round drew. The pair-to-pair equality below is what both
        // arrangements need, so it stays.
        case .btnL2:     return CGSize(width: 90, height: 35.2)
        case .btnR2:     return CGSize(width: 90, height: 35.2)
        // The pad prints ANALOG between SELECT and START, so it takes that row's
        // shape: a small pill. 52 rather than SELECT's 64, and NOT because the
        // word is shorter -- both are six characters, and at 10pt the label needs
        // about 40. It is narrower because the row now holds three controls where
        // it held two, and every point it takes comes off the lanes either side
        // of that row, which is where the two sticks live. At 64 those lanes drop
        // under a stick's own width on the narrowest phone.
        case .btnMode:   return CGSize(width: 52, height: 44)
        // Smaller than the cross (165) on purpose, and the number is not a taste:
        // in portrait a stick has to fit the lane between the page edge and the
        // SELECT · ANALOG · START row, and on the narrowest phone that lane is
        // about 94pt. 90 clears it on every device the app runs on with a margin
        // each side. A stick is aimed with the tip of a thumb rather than rolled
        // under it, so it can afford to be the smaller control.
        case .stickLeft, .stickRight: return CGSize(width: 90, height: 90)
        // Small on purpose. They are HELD rather than tapped, so they do not
        // need a thumb's whole landing area, and every point they take comes
        // off the fullest page the app draws.
        case .btnL3, .btnR3: return CGSize(width: 40, height: 40)
        case .btnStart:  return CGSize(width: 64, height: 44)
        case .btnSelect: return CGSize(width: 64, height: 44)
        case .btnMenu:   return CGSize(width: 44, height: 44)
        case .btnMic:    return CGSize(width: 52, height: 36)
        case .btnClip:   return CGSize(width: 44, height: 44)
        }
    }

    /// Default size in landscape (some buttons change size).
    var defaultLandscapeSize: CGSize {
        switch self {
        case .dpad:      return CGSize(width: 160, height: 160)   // testing
        case .btnA:      return CGSize(width: 66, height: 66)
        case .btnB:      return CGSize(width: 59.4, height: 59.4)
        case .btnL:      return CGSize(width: 110, height: 38)
        case .btnR:      return CGSize(width: 110, height: 38)
        // The PlayStation's second pair is the SAME BAR as the first, here too.
        // Without these two cases they fell through to `defaultSize` and came
        // back 35.2 tall against L1/R1's 38, so the two bars of one pair -- drawn
        // side by side on one line by `ControlLayoutDefaults.ps1` -- rendered at
        // different heights. A pair has to read as one control.
        case .btnL2:     return CGSize(width: 110, height: 38)
        case .btnR2:     return CGSize(width: 110, height: 38)
        // Start/Select/Menu/Clip form the under-the-screen bottom row; 38 tall (like
        // L/R) so the row clears the top-aligned game without overlap (testing).
        case .btnStart:  return CGSize(width: 56, height: 38)
        case .btnSelect: return CGSize(width: 56, height: 38)
        case .btnMenu:   return CGSize(width: 44, height: 38)
        case .btnClip:   return CGSize(width: 44, height: 38)
        // ANALOG joins that same under-the-screen row in landscape, so it takes
        // the row's height rather than its own portrait one. A 44pt button in a
        // 38pt row is the one that looks broken.
        case .btnMode:   return CGSize(width: 52, height: 38)
        default:         return defaultSize
        }
    }

    /// NDS portrait overrides.
    var defaultNDSPortraitSize: CGSize {
        switch self {
        case .dpad:      return CGSize(width: 159.5, height: 159.5)
        case .btnA:      return CGSize(width: 63.8, height: 63.8)
        case .btnB:      return CGSize(width: 63.8, height: 63.8)
        case .btnL:      return CGSize(width: 70, height: 36)
        case .btnR:      return CGSize(width: 70, height: 36)
        case .btnStart:  return CGSize(width: 52, height: 36)
        case .btnSelect: return CGSize(width: 52, height: 36)
        case .btnMenu:   return CGSize(width: 36, height: 36)
        case .btnMic:    return CGSize(width: 52, height: 36)
        case .btnClip:   return CGSize(width: 52, height: 36)
        default:         return defaultSize
        }
    }

    /// NDS landscape overrides.
    var defaultNDSLandscapeSize: CGSize {
        switch self {
        case .dpad:      return CGSize(width: 148.5, height: 148.5)
        case .btnA:      return CGSize(width: 63.8, height: 63.8)
        case .btnB:      return CGSize(width: 63.8, height: 63.8)
        case .btnX:      return CGSize(width: 63.8, height: 63.8)
        case .btnY:      return CGSize(width: 63.8, height: 63.8)
        case .btnL:      return CGSize(width: 40, height: 100)
        case .btnR:      return CGSize(width: 40, height: 100)
        case .btnStart:  return CGSize(width: 52, height: 36)
        case .btnSelect: return CGSize(width: 52, height: 36)
        case .btnMenu:   return CGSize(width: 36, height: 36)
        case .btnMic:    return CGSize(width: 52, height: 36)
        case .btnClip:   return CGSize(width: 36, height: 36)   // mirrors Menu (testing)
        // Landscape shoulders are vertical bars on the DS; the PlayStation's
        // second pair matches its first. (The DS never draws these two; the
        // entry exists so the pair can never answer differently from L/R.)
        case .btnL2:     return CGSize(width: 40, height: 100)
        case .btnR2:     return CGSize(width: 40, height: 100)
        case .btnMode:   return CGSize(width: 44, height: 36)
        case .stickLeft, .stickRight: return CGSize(width: 90, height: 90)
        case .btnL3, .btnR3: return CGSize(width: 40, height: 40)
        }
    }
}

/// Position, visibility, and per-component size/opacity for a single button in
/// one orientation.
struct ButtonLayout: Codable, Equatable {
    /// Center X as fraction of the layout space width (0.0–1.0). Layout space is
    /// the full view for `OrientationLayout.space == 2`, the legacy controls
    /// container for `space == 1`.
    var centerX: CGFloat
    /// Center Y as fraction of the layout space height (0.0–1.0).
    var centerY: CGFloat
    /// Whether this button is hidden. Menu and Clip are always forced visible
    /// at resolve time (they are action triggers, not game inputs).
    var isHidden: Bool
    /// Per-component visual scale (applied as a transform on top of the
    /// device-scaled base size). nil = fall back to the preset's legacy global
    /// `scale` (presets saved before components carried their own).
    var scale: CGFloat?
    /// Per-component alpha (0.1–1.0). nil = fall back to the preset's legacy
    /// global `opacity` (which used the historical ×2 effective-alpha mapping).
    var opacity: CGFloat?

    init(centerX: CGFloat, centerY: CGFloat, isHidden: Bool = false,
         scale: CGFloat? = nil, opacity: CGFloat? = nil) {
        self.centerX = centerX
        self.centerY = centerY
        self.isHidden = isHidden
        self.scale = scale
        self.opacity = opacity
    }
}

/// Identifies a game screen as a movable/resizable layout component.
/// GBA + GB/GBC have one (`main`); NDS has two (`top`, `bottom` — in landscape
/// they render left/right but keep their physical identity).
enum ScreenComponent: String, Codable, CaseIterable {
    case main, top, bottom

    /// The screen set for a system — single source of truth, like
    /// `ControlElement.elements(for:)`.
    static func components(for system: PresetSystem) -> [ScreenComponent] {
        system == .nds ? [.top, .bottom] : [.main]
    }
}

/// Position, size, and opacity for one game screen in one orientation.
/// Screens can never be hidden (a game must stay visible); buttons are the
/// only hideable components. Coordinates are normalized to the FULL view
/// (screens only exist in `space == 2` layouts). `scale` multiplies the
/// system's default screen size for this device + orientation, preserving the
/// display aspect.
struct ScreenLayout: Codable, Equatable {
    var centerX: CGFloat
    var centerY: CGFloat
    var scale: CGFloat
    var opacity: CGFloat

    init(centerX: CGFloat, centerY: CGFloat, scale: CGFloat = 1.0,
         opacity: CGFloat = 1.0) {
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
        self.opacity = opacity
    }
}

/// One complete layout for one orientation.
struct OrientationLayout: Codable, Equatable {
    /// Coordinate space of the normalized positions in this layout.
    /// 1 = legacy (buttons normalized to the controls container below the
    /// screen; no screens stored) — every preset saved before screens became
    /// components. 2 = full-view space (buttons AND screens normalized to the
    /// whole view). `PresetLayoutResolver` converts 1 → 2 at resolve time.
    static let legacySpace = 1
    static let fullViewSpace = 2

    var space: Int
    /// Button positions keyed by ControlElement.rawValue.
    var buttons: [String: ButtonLayout]
    /// Screen positions keyed by ScreenComponent.rawValue (space == 2 only).
    var screens: [String: ScreenLayout]

    init(buttons: [String: ButtonLayout] = [:],
         screens: [String: ScreenLayout] = [:],
         space: Int = OrientationLayout.fullViewSpace) {
        self.buttons = buttons
        self.screens = screens
        self.space = space
    }

    private enum CodingKeys: String, CodingKey { case space, buttons, screens }

    /// Custom decode so layouts saved before `space`/`screens` existed still
    /// load: a missing `space` marks the layout as legacy (controls-container
    /// coordinates), instead of failing the decode and silently wiping the
    /// preset. The old `ndsTopScreenSize`/`ndsBottomScreenSize` keys are
    /// deliberately ignored — that S/M/L split feature was removed when screens
    /// became freely movable components. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        space = try c.decodeIfPresent(Int.self, forKey: .space) ?? OrientationLayout.legacySpace
        buttons = try c.decodeIfPresent([String: ButtonLayout].self, forKey: .buttons) ?? [:]
        screens = try c.decodeIfPresent([String: ScreenLayout].self, forKey: .screens) ?? [:]
    }
}

/// Which system a preset applies to (one system per preset).
/// Screens + Menu layout used ONLY while a physical controller is connected.
///
/// Deliberately a separate object from `ControlPreset`, not a flag on one: a
/// touch preset places the screens to leave room for the on-screen buttons,
/// whereas with a controller the screens want the whole display. One object
/// serving both goals would always be a compromise for at least one of them.
///
/// Nothing here can be hidden, and no code enforces that because nothing has
/// to: `ScreenLayout` screens are never hideable (a game must stay visible),
/// and `ButtonLayout.isHidden` is already ignored for Menu at resolve time.
/// The editor simply offers no hide affordance.
///
/// An empty layout means "never customised", which resolves to exactly the
/// geometry the app renders today. That is what makes the feature zero-
/// regression for anyone who never opens it.
struct ControllerLayout: Codable, Equatable {
    var portrait: OrientationLayout
    var landscape: OrientationLayout

    init(portrait: OrientationLayout = OrientationLayout(),
         landscape: OrientationLayout = OrientationLayout()) {
        self.portrait = portrait
        self.landscape = landscape
    }

    /// True when the user has not moved anything yet, in either orientation.
    var isPristine: Bool {
        portrait.screens.isEmpty && portrait.buttons.isEmpty
            && landscape.screens.isEmpty && landscape.buttons.isEmpty
    }

    func layout(isLandscape: Bool) -> OrientationLayout { isLandscape ? landscape : portrait }

    mutating func setLayout(_ layout: OrientationLayout, isLandscape: Bool) {
        if isLandscape { landscape = layout } else { portrait = layout }
    }

    /// The only components this layout ever carries.
    static func components(for system: PresetSystem) -> [ScreenComponent] {
        ScreenComponent.components(for: system)
    }
    static let element: ControlElement = .btnMenu
}

enum PresetSystem: String, Codable, Equatable, CaseIterable {
    case gba   // Game Boy Advance
    case gbc   // Game Boy + Game Boy Color (one shared layout family)
    case nds   // Nintendo DS
    case snes  // Super Nintendo
    case nes   // NES
    case ps1   // PlayStation
}

/// Per-system applicability flags for a preset (one system per preset in the UI,
/// but stored as flags so old data keeps decoding). Acts as the Codable bridge to
/// the single `PresetSystem` the rest of the app uses.
struct SystemApplicability: Codable, Equatable {
    var gba: Bool
    var gbc: Bool
    var nds: Bool
    var snes: Bool
    var nes: Bool
    var ps1: Bool

    init(gba: Bool = false, gbc: Bool = false, nds: Bool = false,
         snes: Bool = false, nes: Bool = false, ps1: Bool = false) {
        self.gba = gba
        self.gbc = gbc
        self.nds = nds
        self.snes = snes
        self.nes = nes
        self.ps1 = ps1
    }

    init(system: PresetSystem) {
        self.gba = (system == .gba)
        self.gbc = (system == .gbc)
        self.nds = (system == .nds)
        self.snes = (system == .snes)
        self.nes = (system == .nes)
        self.ps1 = (system == .ps1)
    }

    /// Resolution order is PS1, NES, SNES, NDS, then GBC, then GBA (the
    /// default). A preset saved before a flag existed simply does not carry it,
    /// so it keeps resolving exactly where it did before.
    var system: PresetSystem {
        if ps1 { return .ps1 }
        if nes { return .nes }
        if snes { return .snes }
        if nds { return .nds }
        if gbc { return .gbc }
        return .gba
    }

    private enum CodingKeys: String, CodingKey { case gba, gbc, nds, snes, nes, ps1 }

    /// Decode each flag independently so a preset stored before `gbc`, `snes` or
    /// `nes` existed still loads instead of failing the whole array decode, which
    /// would silently wipe every saved preset. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gba = try c.decodeIfPresent(Bool.self, forKey: .gba) ?? false
        gbc = try c.decodeIfPresent(Bool.self, forKey: .gbc) ?? false
        nds = try c.decodeIfPresent(Bool.self, forKey: .nds) ?? false
        snes = try c.decodeIfPresent(Bool.self, forKey: .snes) ?? false
        nes = try c.decodeIfPresent(Bool.self, forKey: .nes) ?? false
        ps1 = try c.decodeIfPresent(Bool.self, forKey: .ps1) ?? false
    }
}

/// A complete control layout preset.
struct ControlPreset: Identifiable, Codable {
    let id: UUID
    var name: String
    var systems: SystemApplicability
    var portrait: OrientationLayout
    var landscape: OrientationLayout
    /// Button opacity (0.05–0.6). Per-preset, not global.
    var opacity: CGFloat
    /// Button scale (0.7–1.3). Per-preset, not global.
    var scale: CGFloat
    /// Directional control type. Per-preset, not global: the Settings toggle
    /// drives only the built-in default layout, while each preset carries its
    /// own choice (false = cross D-pad, true = joystick).
    var useJoystick: Bool

    init(id: UUID = UUID(), name: String, systems: SystemApplicability,
         portrait: OrientationLayout = OrientationLayout(),
         landscape: OrientationLayout = OrientationLayout(),
         opacity: CGFloat = 0.25,
         scale: CGFloat = 1.0,
         useJoystick: Bool = false) {
        self.id = id
        self.name = name
        self.systems = systems
        self.portrait = portrait
        self.landscape = landscape
        self.opacity = opacity
        self.scale = scale
        self.useJoystick = useJoystick
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, systems, portrait, landscape, opacity, scale, useJoystick
    }

    /// Custom decode so presets saved before these fields existed still load
    /// (a missing key falls back to the default instead of failing the whole
    /// decode, which would otherwise silently drop the preset). Encoding stays
    /// synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        systems = try c.decode(SystemApplicability.self, forKey: .systems)
        portrait = try c.decode(OrientationLayout.self, forKey: .portrait)
        landscape = try c.decode(OrientationLayout.self, forKey: .landscape)
        opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 0.25
        scale = try c.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1.0
        useJoystick = try c.decodeIfPresent(Bool.self, forKey: .useJoystick) ?? false
    }
}
