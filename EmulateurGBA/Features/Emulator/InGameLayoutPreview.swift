//
//  InGameLayoutPreview.swift
//  EmulateurGBA
//
//  DEBUG-only visual preview of the in-game screen + on-screen controls,
//  for verifying component positions across device sizes WITHOUT running a game.
//
//  Two ways to view it:
//   1. LayoutPreviewGallery — an on-device screen (Settings ▸ Debug ▸ Layout
//      preview) that renders every config for the smallest and largest iPhones,
//      scaled to fit. This works on a real device, where the melonDS core links
//      fine, so it needs no simulator.
//   2. The #Preview blocks below — Xcode canvas. These build for the simulator,
//      which currently can't link the device-only melonDS static lib, so they
//      only render once the core ships a simulator slice. The on-device gallery
//      is the supported path until then.
//
//  Everything drives the REAL TouchControlsView / NDSTouchControlsView and the
//  REAL EmulatorLayoutGeometry, so positions match the game exactly. The "screen"
//  is just a magenta placeholder — emulation never runs here.
//

#if DEBUG
import UIKit
import SwiftUI

/// The console being previewed. Carries the two things that actually differ per
/// system: the rendered-screen aspect ratio (so the magenta placeholder matches
/// the real Metal frame) and whether it's the dual-screen NDS (which drives the
/// NDSTouchControlsView + side-by-side landscape path). GB/GBC share the GBA
/// touch layout exactly — there is no per-console button gating in the app — so
/// they differ from GBA only in screen aspect (160×144 vs 240×160).
enum PreviewSystem: String {
    case gba, gbc, nds, snes, nes, ps1   // gbc = GB + GBC (identical controls + screen)

    var isNDS: Bool { self == .nds }

    /// The control/layout family this maps to (GB and GBC are one family).
    var layoutSystem: PresetSystem {
        switch self {
        case .gba: return .gba
        case .gbc: return .gbc
        case .nds: return .nds
        case .snes: return .snes
        case .nes: return .nes
        case .ps1: return .ps1
        }
    }

    /// Rendered game aspect (width / height), matching EmulatorSession.
    var gameAspect: CGFloat {
        switch self {
        case .gba: return 240.0 / 160.0
        case .gbc: return 160.0 / 144.0
        case .nds: return 256.0 / 384.0   // both screens stacked
        // Straight from the layout engine's own table, so this gallery cannot
        // show a shape the game does not draw.
        case .snes, .nes, .ps1: return PresetLayoutResolver.displayAspect(layoutSystem)
        }
    }

    var screenLabel: String {
        switch self {
        case .gba: return "GBA screen"
        case .gbc: return "GB/GBC screen"
        case .nds: return "NDS screen(s)"
        case .snes: return "SNES screen"
        case .nes: return "NES screen"
        case .ps1: return "PlayStation screen"
        }
    }
}

/// Lays out a magenta screen placeholder + the real touch controls for one
/// system/orientation, exactly the way EmulatorViewController does, using the
/// no-preset default layout and the given safe-area insets.
final class InGameLayoutPreviewView: UIView {
    private let system: PreviewSystem
    private let isNDS: Bool
    private let isLandscape: Bool
    private let insets: UIEdgeInsets
    private let consoleSkin = ConsoleSkinView()
    private let screen = UIView()
    private let screen2 = UIView()   // NDS-landscape right (touch) screen
    private let screenLabel = UILabel()
    private let controls: TouchControlsView
    private let hitboxOverlay = HitboxOverlayView()   // debug: button hitboxes over the dress

    init(system: PreviewSystem, isLandscape: Bool, safeInsets: UIEdgeInsets) {
        self.system = system
        self.isNDS = system.isNDS
        self.isLandscape = isLandscape
        self.insets = safeInsets
        // The same choice EmulatorViewController makes, from the same factory: the
        // X and Y views exist only on the subclasses that have those buttons.
        self.controls = TouchControlsView.make(for: system.layoutSystem)
        super.init(frame: .zero)

        backgroundColor = .black

        // Console dress behind everything (cosmetic). Configured in layoutSubviews.
        addSubview(consoleSkin)

        // The screen is a placeholder only — magenta so it's obvious which band
        // is the screen vs the controls area. Emulation never runs here.
        screen.backgroundColor = UIColor.magenta.withAlphaComponent(0.22)
        screen.layer.borderColor = UIColor.magenta.withAlphaComponent(0.7).cgColor
        screen.layer.borderWidth = 1
        addSubview(screen)

        // NDS landscape renders two screens side by side; this is the right (touch)
        // one. The gutters around the pair stay black, so the L/R bars must sit there.
        screen2.backgroundColor = screen.backgroundColor
        screen2.layer.borderColor = screen.layer.borderColor
        screen2.layer.borderWidth = 1
        screen2.isHidden = true
        addSubview(screen2)

        screenLabel.text = system.screenLabel
        screenLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        screenLabel.font = .systemFont(ofSize: 13, weight: .medium)
        screenLabel.textAlignment = .center
        screenLabel.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(screenLabel)
        NSLayoutConstraint.activate([
            screenLabel.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            screenLabel.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
        ])

        // The controls layer is framed manually here, exactly like the game.
        controls.translatesAutoresizingMaskIntoConstraints = true
        addSubview(controls)

        // Debug overlay: outline each button's hitbox on top, so the dress (diagonal pills,
        // wells, labels) can be checked against the real touch rectangles.
        addSubview(hitboxOverlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let k = EmulatorLayoutGeometry.deviceScale(for: size)
        let gameAspect = system.gameAspect
        let metalFrame = EmulatorLayoutGeometry.screenFrame(
            deviceSize: size, safeInsets: insets,
            hasTouchScreen: isNDS, isLandscape: isLandscape,
            gameAspect: gameAspect, system: system.layoutSystem,
            controllerConnected: false, deviceScale: k)
        let containerFrame = EmulatorLayoutGeometry.controlsFrame(
            deviceSize: size, screenFrame: metalFrame,
            hasTouchScreen: isNDS, isLandscape: isLandscape)

        // Console dress behind the placeholder screen + controls (GB/GBC only).
        consoleSkin.frame = bounds
        consoleSkin.system = system.layoutSystem
        consoleSkin.screenFrame = metalFrame
        consoleSkin.deviceScale = k
        consoleSkin.usesJoystick = UserDefaults.standard.bool(forKey: "useJoystick")
        consoleSkin.isHidden = !ConsoleSkinView.hasSkin(for: system.layoutSystem)

        // NDS landscape: draw the two real rendered screen rects (with their
        // letterbox gutters) instead of the full band, so the gutter the L/R bars
        // are fitted into is visible. Every other config fills its frame.
        if isNDS && isLandscape {
            let s = EmulatorLayoutGeometry.ndsLandscapeScreenRects(controlsContainer: containerFrame.size)
            screen.frame = CGRect(x: s.left.minX, y: metalFrame.minY,
                                  width: s.left.width, height: metalFrame.height)
            screen2.frame = CGRect(x: s.touch.minX, y: metalFrame.minY,
                                   width: s.touch.width, height: metalFrame.height)
            screen2.isHidden = false
        } else if isNDS {
            // Portrait: split the combined band into the two stacked screens so the per-screen
            // outlines, speakers and light all have real sub-frames to anchor to.
            let topRatio: CGFloat = 0.495, gapRatio: CGFloat = 0.01
            let topH = metalFrame.height * topRatio
            let gapH = metalFrame.height * gapRatio
            screen.frame = CGRect(x: metalFrame.minX, y: metalFrame.minY,
                                  width: metalFrame.width, height: topH)
            screen2.frame = CGRect(x: metalFrame.minX, y: metalFrame.minY + topH + gapH,
                                   width: metalFrame.width, height: metalFrame.height * (1 - topRatio - gapRatio))
            screen2.isHidden = false
        } else {
            screen.frame = metalFrame
            screen2.isHidden = true
        }

        // Hand the NDS dress its two screen sub-frames (for the outlines + speakers + light), and
        // round the placeholder corners to match the skin's rim.
        if isNDS {
            consoleSkin.ndsScreens = [screen.frame, screen2.frame]
            for v in [screen, screen2] { v.layer.cornerRadius = 2 * k; v.layer.masksToBounds = true }
        } else {
            consoleSkin.ndsScreens = []
            for v in [screen, screen2] { v.layer.cornerRadius = 0 }
        }

        controls.frame = containerFrame
        controls.layoutIfNeeded()
        controls.applyDefaultLayout(isLandscape: isLandscape, system: system.layoutSystem,
                                    deviceScale: k, safeLeftInset: insets.left,
                                    safeRightInset: insets.right,
                                    family: LayoutFamily.of(bounds.size))
        // Dress the buttons for the systems whose buttons have a dress, matching the skin.
        // NDS shows its body/screen dress before its buttons are dressed (later slice).
        controls.setDressed(ConsoleSkinView.hasDressedControls(for: system.layoutSystem),
                            isLandscape: isLandscape, system: system.layoutSystem)

        // Feed the dress the resolved button frames (for decoration placement).
        controls.layoutIfNeeded()
        consoleSkin.buttonFrames = controls.visibleButtonFrames(in: consoleSkin)

        // Mirror those frames into the debug overlay (dressed configs only).
        hitboxOverlay.frame = bounds
        hitboxOverlay.isHidden = !ConsoleSkinView.hasSkin(for: system.layoutSystem)
        let bf = controls.visibleButtonFrames(in: hitboxOverlay)
        // The consoles whose four faces are round-hitboxed, which is a question
        // about the PAD and not about the touchscreen: the DS, the Super
        // Nintendo and the PlayStation all set `roundHitbox` on their diamond.
        // Reading `isNDS` drew the Super Nintendo's circles as squares, so this
        // overlay was already describing that console wrongly before the
        // PlayStation arrived to make it matter twice.
        let hasDiamond: Set<PreviewSystem> = [.nds, .snes, .ps1]
        let round: Set<ControlElement> = hasDiamond.contains(system)
            ? [.btnA, .btnB, .btnX, .btnY] : []
        hitboxOverlay.frames = bf.filter { !round.contains($0.key) }.map { $0.value }
        hitboxOverlay.roundFrames = bf.filter { round.contains($0.key) }.map { $0.value }
    }
}

/// DEBUG: draws each button's hitbox as a thin outline, for checking the dress alignment.
private final class HitboxOverlayView: UIView {
    var frames: [CGRect] = [] { didSet { setNeedsDisplay() } }
    var roundFrames: [CGRect] = [] { didSet { setNeedsDisplay() } }   // drawn as inscribed circles

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor.systemGreen.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 2])
        for f in frames { ctx.stroke(f.insetBy(dx: 0.5, dy: 0.5)) }
        for f in roundFrames {   // inscribed circle = the actual round hit area
            let r = min(f.width, f.height) / 2
            ctx.strokeEllipse(in: CGRect(x: f.midX - r, y: f.midY - r, width: 2 * r, height: 2 * r))
        }
    }
}

struct InGameLayoutPreviewRepresentable: UIViewRepresentable {
    let system: PreviewSystem
    let isLandscape: Bool
    let safeInsets: UIEdgeInsets
    func makeUIView(context: Context) -> InGameLayoutPreviewView {
        InGameLayoutPreviewView(system: system, isLandscape: isLandscape, safeInsets: safeInsets)
    }
    func updateUIView(_ uiView: InGameLayoutPreviewView, context: Context) {}
}

/// On-device gallery: every config for the smallest and largest iPhones, scaled
/// to fit the screen width. Reachable from Settings ▸ Debug ▸ Layout preview.
struct LayoutPreviewGallery: View {
    private struct Device: Identifiable {
        var id: String { name }
        let name: String
        /// Portrait logical size in points.
        let portrait: CGSize
        /// Portrait safe-area insets (only top/bottom affect the layout engine;
        /// landscape uses .zero, which the engine ignores anyway).
        let portraitInsets: UIEdgeInsets
        /// Leading safe-area inset in landscape (the Dynamic Island side). 0 on phones
        /// without an island; drives the GB/GBC landscape D-pad clearance.
        let landscapeLeadingInset: CGFloat
    }

    private struct Config: Identifiable {
        var id: String { label }
        let label: String
        let system: PreviewSystem
        let isLandscape: Bool
    }

    // Smallest and largest current iPhones — the layout extremes.
    private let devices: [Device] = [
        Device(name: "iPhone SE", portrait: CGSize(width: 375, height: 667),
               portraitInsets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0),
               landscapeLeadingInset: 0),   // no island
        Device(name: "iPhone 16 Pro Max", portrait: CGSize(width: 440, height: 956),
               portraitInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
               landscapeLeadingInset: 59),  // Dynamic Island on the leading edge
    ]

    private let configs: [Config] = [
        Config(label: "GBA · portrait", system: .gba, isLandscape: false),
        Config(label: "GBA · landscape", system: .gba, isLandscape: true),
        Config(label: "GB/GBC · portrait", system: .gbc, isLandscape: false),
        Config(label: "GB/GBC · landscape", system: .gbc, isLandscape: true),
        Config(label: "NDS · portrait", system: .nds, isLandscape: false),
        Config(label: "NDS · landscape", system: .nds, isLandscape: true),
        Config(label: "SNES · portrait", system: .snes, isLandscape: false),
        Config(label: "SNES · landscape", system: .snes, isLandscape: true),
        Config(label: "NES · portrait", system: .nes, isLandscape: false),
        Config(label: "NES · landscape", system: .nes, isLandscape: true),
        Config(label: "PS1 · portrait", system: .ps1, isLandscape: false),
        Config(label: "PS1 · landscape", system: .ps1, isLandscape: true),
    ]

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(devices) { device in
                        ForEach(configs) { cfg in
                            tile(device: device, cfg: cfg, availableWidth: geo.size.width - 32)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Layout preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func tile(device: Device, cfg: Config, availableWidth: CGFloat) -> some View {
        let size = cfg.isLandscape
            ? CGSize(width: device.portrait.height, height: device.portrait.width)
            : device.portrait
        // Clamp to [0,1]: GeometryReader reports width 0 on the first pass, which
        // would make availableWidth negative and hand `.frame` a negative dimension.
        let scale = min(1, max(0, availableWidth) / size.width)
        // Landscape ignores top/bottom insets, but the leading inset (island side) is
        // fed in so the GB/GBC D-pad clearance shows in the preview.
        let insets = cfg.isLandscape
            ? UIEdgeInsets(top: 0, left: device.landscapeLeadingInset, bottom: 0, right: 0)
            : device.portraitInsets

        VStack(alignment: .leading, spacing: 6) {
            Text("\(device.name) · \(cfg.label) · \(Int(size.width))×\(Int(size.height))")
                .font(.caption)
                .foregroundStyle(.secondary)
            InGameLayoutPreviewRepresentable(system: cfg.system, isLandscape: cfg.isLandscape, safeInsets: insets)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                .border(Color.white.opacity(0.3))
        }
    }
}

// Xcode canvas (needs a melonDS simulator slice to render — see file header).
#Preview("SE · GBA portrait") {
    InGameLayoutPreviewRepresentable(system: .gba, isLandscape: false,
                                     safeInsets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0))
        .frame(width: 375, height: 667)
}

#Preview("SE · GB/GBC portrait") {
    InGameLayoutPreviewRepresentable(system: .gbc, isLandscape: false,
                                     safeInsets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0))
        .frame(width: 375, height: 667)
}

#Preview("SE · NDS landscape") {
    InGameLayoutPreviewRepresentable(system: .nds, isLandscape: true, safeInsets: .zero)
        .frame(width: 667, height: 375)
}

#Preview("Gallery") {
    NavigationStack { LayoutPreviewGallery() }
}
#endif
