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
    case dpad, btnA, btnB, btnL, btnR, btnStart, btnSelect, btnMenu
    // NDS additions
    case btnX, btnY, btnMic

    /// Elements present on GBA/GB/GBC.
    static let gbaElements: [ControlElement] = [.dpad, .btnA, .btnB, .btnL, .btnR, .btnStart, .btnSelect, .btnMenu]

    /// Elements present on NDS (all GBA + X/Y/Mic).
    static let ndsElements: [ControlElement] = allCases

    /// Human-readable name for display in the editor.
    var displayName: String {
        switch self {
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
        case .btnL:      return CGSize(width: 90, height: 44)
        case .btnR:      return CGSize(width: 90, height: 44)
        case .btnStart:  return CGSize(width: 64, height: 44)
        case .btnSelect: return CGSize(width: 64, height: 44)
        case .btnMenu:   return CGSize(width: 44, height: 44)
        case .btnMic:    return CGSize(width: 52, height: 36)
        }
    }

    /// Default size in landscape (some buttons change size).
    var defaultLandscapeSize: CGSize {
        switch self {
        case .dpad:      return CGSize(width: 143, height: 143)
        case .btnA:      return CGSize(width: 66, height: 66)
        case .btnB:      return CGSize(width: 59.4, height: 59.4)
        case .btnL:      return CGSize(width: 110, height: 38)
        case .btnR:      return CGSize(width: 110, height: 38)
        case .btnStart:  return CGSize(width: 56, height: 44)
        case .btnSelect: return CGSize(width: 56, height: 44)
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
        }
    }
}

/// Position and visibility for a single button in one orientation.
struct ButtonLayout: Codable, Equatable {
    /// Center X as fraction of container width (0.0–1.0).
    var centerX: CGFloat
    /// Center Y as fraction of container height (0.0–1.0).
    var centerY: CGFloat
    /// Whether this button is hidden. Menu button always forced visible at runtime.
    var isHidden: Bool

    init(centerX: CGFloat, centerY: CGFloat, isHidden: Bool = false) {
        self.centerX = centerX
        self.centerY = centerY
        self.isHidden = isHidden
    }
}

/// NDS screen size options.
enum NDSScreenSize: String, Codable, CaseIterable {
    case small, medium, large

    var scaleFactor: CGFloat {
        switch self {
        case .small: return 0.8
        case .medium: return 1.0
        case .large: return 1.2
        }
    }

    var displayName: String {
        switch self {
        case .small: return NSLocalizedString("layout.screenSize.small", comment: "")
        case .medium: return NSLocalizedString("layout.screenSize.medium", comment: "")
        case .large: return NSLocalizedString("layout.screenSize.large", comment: "")
        }
    }
}

/// One complete layout for one orientation.
struct OrientationLayout: Codable, Equatable {
    /// Button positions keyed by ControlElement.rawValue.
    var buttons: [String: ButtonLayout]
    /// NDS screen sizes (ignored for GBA).
    var ndsTopScreenSize: NDSScreenSize
    var ndsBottomScreenSize: NDSScreenSize
    init(buttons: [String: ButtonLayout] = [:],
         ndsTopScreenSize: NDSScreenSize = .medium,
         ndsBottomScreenSize: NDSScreenSize = .medium) {
        self.buttons = buttons
        self.ndsTopScreenSize = ndsTopScreenSize
        self.ndsBottomScreenSize = ndsBottomScreenSize
    }
}

/// Which system a preset applies to (one system per preset).
enum PresetSystem: String, Codable, Equatable {
    case gba  // includes GB/GBC
    case nds
}

/// Legacy wrapper — presets now use a single PresetSystem.
/// Kept as Codable bridge for backward compatibility.
struct SystemApplicability: Codable, Equatable {
    var gba: Bool
    var nds: Bool

    init(gba: Bool = false, nds: Bool = false) {
        self.gba = gba
        self.nds = nds
    }

    init(system: PresetSystem) {
        self.gba = (system == .gba)
        self.nds = (system == .nds)
    }

    var system: PresetSystem {
        nds ? .nds : .gba
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

    init(id: UUID = UUID(), name: String, systems: SystemApplicability,
         portrait: OrientationLayout = OrientationLayout(),
         landscape: OrientationLayout = OrientationLayout(),
         opacity: CGFloat = 0.25,
         scale: CGFloat = 1.0) {
        self.id = id
        self.name = name
        self.systems = systems
        self.portrait = portrait
        self.landscape = landscape
        self.opacity = opacity
        self.scale = scale
    }
}
