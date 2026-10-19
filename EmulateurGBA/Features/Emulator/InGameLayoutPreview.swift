//
//  InGameLayoutPreview.swift
//  EmulateurGBA
//
//  DEBUG-only visual preview of the in-game screen + on-screen controls,
//  for verifying component positions across device sizes WITHOUT running a game.
//
//  Two ways to view it:
//   1. PhonePreviewGallery — an on-device screen (Settings ▸ Debug iPhone, one
//      row per console) that renders the console on three iPhones, both
//      orientations, in the look picked in its top bar, scaled to fit. This
//      works on a real device, where the melonDS core links fine, so it needs
//      no simulator. The iPad rows (TabletPreviewGallery) share the bar.
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
    case gba, gbc, nds, snes, nes, ps1, n64, md, sms, gg, psp   // gbc = GB + GBC (identical controls + screen)

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
        case .n64: return .n64
        case .md: return .md
        case .sms: return .sms
        case .gg: return .gg
        case .psp: return .psp
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
        case .snes, .nes, .ps1, .n64, .md, .sms, .gg, .psp:
            return PresetLayoutResolver.displayAspect(layoutSystem)
        }
    }

    /// The Debug iPhone rows, in the order of the Debug iPad ones.
    static let galleryOrder: [PreviewSystem] = [.gbc, .gba, .nds, .snes, .nes, .ps1, .n64, .md, .sms, .gg, .psp]

    var consoleName: String {
        switch self {
        case .gba: return "Game Boy Advance"
        case .gbc: return "Game Boy and Game Boy Color"
        case .nds: return "Nintendo DS"
        case .snes: return "Super Nintendo"
        case .nes: return "NES"
        case .ps1: return "PlayStation"
        case .n64: return "Nintendo 64"
        case .md: return "Mega Drive"
        case .sms: return "Master System"
        case .gg: return "Game Gear"
        case .psp: return "PSP"
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
        case .n64: return "Nintendo 64 screen"
        case .md: return "Mega Drive screen"
        case .sms: return "Master System screen"
        case .gg: return "Game Gear screen"
        case .psp: return "PSP screen"
        }
    }
}

/// What the in-game galleries show, picked in their top bar: the three
/// built-in skins, and a controller connected (in Nostalgia, the default skin,
/// which a pad keeps: it hides the controls, not the dress).
enum PreviewLook: String, CaseIterable, Identifiable {
    case nostalgia, retroPal, invisible, controller

    var id: String { rawValue }
    /// Shared by the iPhone and iPad galleries, so the look survives moving
    /// from one console's page to the next.
    static let storageKey = "debugPreviewLook"

    var title: String {
        switch self {
        case .nostalgia: return "Nostalgia"
        case .retroPal: return "Retro Pal"
        case .invisible: return "Invisible"
        case .controller: return "Controller"
        }
    }
}

/// The galleries' top bar: the look every tile of the page is drawn in.
struct PreviewLookBar: View {
    @Binding var look: PreviewLook

    var body: some View {
        Picker("Look", selection: $look) {
            ForEach(PreviewLook.allCases) { look in
                Text(look.title).tag(look)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Lays out a magenta screen placeholder + the real touch controls for one
/// system/orientation, exactly the way EmulatorViewController does, using the
/// no-preset default layout and the given safe-area insets.
final class InGameLayoutPreviewView: UIView {
    private let system: PreviewSystem
    private let look: PreviewLook
    private var controllerConnected: Bool { look == .controller }
    /// The look as the game resolves it for this console
    /// (`EmulatorViewController.dressVariant`): the PSP's two looks are its
    /// own palettes, not the PlayStation's.
    private var previewVariant: DressVariant {
        let variant: DressVariant = look == .retroPal ? .retroPal : .nostalgia
        return system.layoutSystem == .psp ? ConsoleSkinView.pspVariant(variant) : variant
    }
    private let isNDS: Bool
    private let isLandscape: Bool
    private let insets: UIEdgeInsets
    private let consoleSkin = ConsoleSkinView()
    private let screen = UIView()
    private let screen2 = UIView()   // NDS-landscape right (touch) screen
    private let screenLabel = UILabel()
    private let controls: TouchControlsView
    private let hitboxOverlay = HitboxOverlayView()   // debug: button hitboxes over the dress
    /// The DS with its lid closed from the pause menu: the game's own message
    /// view, on the screen that shows the DS's top picture (Debug ▸ DS lid).
    private let lidMessage: NDSLidMessageView?

    init(system: PreviewSystem, isLandscape: Bool, safeInsets: UIEdgeInsets,
         look: PreviewLook = .nostalgia, showsLidMessage: Bool = false) {
        self.lidMessage = (showsLidMessage && system.isNDS) ? NDSLidMessageView() : nil
        self.system = system
        self.look = look
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
        // OPAQUE, as the game's picture is (`metalView`, above the dress): a
        // translucent one let the dress's frame show through it, which read as
        // the picture overflowing its frame where the game simply covers it
        // (device check 2026-10-11, SNES / Mega Drive / GBA with a pad).
        screen.backgroundColor = UIColor(red: 0.30, green: 0.05, blue: 0.30, alpha: 1)
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
        // A pad hides every control but MENU, as in the game
        // (`EmulatorViewController.updateControlsVisibility`).
        controls.controllerModeActive = controllerConnected
        addSubview(controls)

        // Debug overlay: outline each button's hitbox on top, so the dress (diagonal pills,
        // wells, labels) can be checked against the real touch rectangles.
        addSubview(hitboxOverlay)
        if let lidMessage { addSubview(lidMessage) }
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
            controllerConnected: controllerConnected, deviceScale: k)
        let containerFrame = EmulatorLayoutGeometry.controlsFrame(
            deviceSize: size, screenFrame: metalFrame,
            hasTouchScreen: isNDS, isLandscape: isLandscape)

        // Console dress behind the placeholder screen + controls (GB/GBC only).
        consoleSkin.frame = bounds
        consoleSkin.system = system.layoutSystem
        // The look the game itself resolves: the PSP's Nostalgia is its own
        // palette, not the PlayStation's (found 2026-10-11: this preview showed
        // the PlayStation's coloured symbols on the PSP).
        consoleSkin.variant = previewVariant
        consoleSkin.screenFrame = metalFrame
        consoleSkin.deviceScale = k
        consoleSkin.usesJoystick = UserDefaults.standard.bool(forKey: "useJoystick")
        consoleSkin.isHidden = !ConsoleSkinView.hasSkin(for: system.layoutSystem) || look == .invisible
        consoleSkin.controllerConnected = controllerConnected

        // The DS: the two screens exactly as the game renders them, each fitted
        // in the picture's frame at its own 4:3 (`ndsDefaultScreenRects`, the
        // split the game's renderer and its lid message use). The preview used
        // to derive them from the no-controller page, which with a pad squeezed
        // both screens to slivers (device check 2026-10-11).
        if isNDS {
            let rects = PresetLayoutResolver.ndsDefaultScreenRects(in: metalFrame, isLandscape: isLandscape)
            screen.frame = rects.top
            screen2.frame = rects.bottom
            screen2.isHidden = false
        } else {
            screen.frame = metalFrame
            screen2.isHidden = true
        }

        // Hand the NDS dress its two screen sub-frames (for the outlines + speakers + light), and
        // round the placeholder corners to match the skin's rim (Invisible keeps them square,
        // as the game does without the dress).
        if isNDS {
            consoleSkin.ndsScreens = [screen.frame, screen2.frame]
            let corner = consoleSkin.isHidden ? 0 : 2 * k
            for v in [screen, screen2] { v.layer.cornerRadius = corner; v.layer.masksToBounds = true }
        } else {
            consoleSkin.ndsScreens = []
            for v in [screen, screen2] { v.layer.cornerRadius = 0 }
        }

        controls.frame = containerFrame
        controls.layoutIfNeeded()
        // With a pad, MENU leaves the grown picture (one-picture consoles), from
        // the picture's frame in the controls' own space, as in the game.
        let controllerScreen: CGRect? = (controllerConnected && !isNDS)
            ? convert(metalFrame, to: controls) : nil
        controls.applyDefaultLayout(isLandscape: isLandscape, system: system.layoutSystem,
                                    deviceScale: k, safeLeftInset: insets.left,
                                    safeRightInset: insets.right,
                                    family: LayoutFamily.of(bounds.size),
                                    controllerScreen: controllerScreen)
        // Dress the buttons for the systems whose buttons have a dress, matching the skin.
        // NDS shows its body/screen dress before its buttons are dressed (later slice).
        controls.setDressed(look != .invisible && ConsoleSkinView.hasDressedControls(for: system.layoutSystem),
                            isLandscape: isLandscape, system: system.layoutSystem,
                            variant: previewVariant)

        // Feed the dress the resolved button frames (for decoration placement), and with a
        // pad the hidden ones too, which some decorations anchor to.
        controls.layoutIfNeeded()
        consoleSkin.buttonFrames = controls.visibleButtonFrames(in: consoleSkin)
        consoleSkin.allButtonFrames = controls.allButtonFrames(in: consoleSkin)

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
        // The Nintendo 64 rounds A, B, Z and its four C buttons instead, and
        // the Mega Drive its six faces.
        let hasDiamond: Set<PreviewSystem> = [.nds, .snes, .ps1, .psp]
        let round: Set<ControlElement> = hasDiamond.contains(system)
            ? [.btnA, .btnB, .btnX, .btnY]
            : system == .n64 ? [.btnA, .btnB, .btnL2, .btnCUp, .btnCDown, .btnCLeft, .btnCRight]
            : system == .md ? Set(ControlElement.mdFaces) : []
        hitboxOverlay.frames = bf.filter { !round.contains($0.key) }.map { $0.value }
        hitboxOverlay.roundFrames = bf.filter { round.contains($0.key) }.map { $0.value }

        // The lid message where the game puts it: the rendered top picture,
        // from the same split the renderer uses (the magenta bands above are
        // the screens' whole bands, the picture sits inside them).
        if let lidMessage {
            let rects = PresetLayoutResolver.ndsDefaultScreenRects(in: metalFrame, isLandscape: isLandscape)
            lidMessage.frame = NDSLidMessageView.topPictureRect(
                primary: rects.top, secondary: rects.bottom,
                swapped: UserDefaults.standard.bool(forKey: "ndsSwapScreens"))
        }
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
    var look: PreviewLook = .nostalgia
    var showsLidMessage: Bool = false
    /// Built once: a new look needs a new view, so a gallery that changes the
    /// look gives the tile a new identity (`.id(look)`).
    func makeUIView(context: Context) -> InGameLayoutPreviewView {
        InGameLayoutPreviewView(system: system, isLandscape: isLandscape, safeInsets: safeInsets,
                                look: look, showsLidMessage: showsLidMessage)
    }
    func updateUIView(_ uiView: InGameLayoutPreviewView, context: Context) {}
}

/// The three iPhones the galleries use: the smallest, the reference the
/// layout engine is drawn on (14 Pro, scale 1.0), the largest. Their real
/// insets in both orientations, which is what the game reads.
struct PhonePreviewDevice: Identifiable {
    var id: String { name }
    let name: String
    let portrait: CGSize
    let portraitInsets: UIEdgeInsets
    let landscapeInsets: UIEdgeInsets
    var landscape: CGSize { CGSize(width: portrait.height, height: portrait.width) }

    static let all: [PhonePreviewDevice] = [
        PhonePreviewDevice(name: "iPhone SE", portrait: CGSize(width: 375, height: 667),
                           portraitInsets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0),
                           landscapeInsets: .zero),
        PhonePreviewDevice(name: "iPhone 14 Pro", portrait: CGSize(width: 393, height: 852),
                           portraitInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                           landscapeInsets: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
        PhonePreviewDevice(name: "iPhone 16 Pro Max", portrait: CGSize(width: 440, height: 956),
                           portraitInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                           landscapeInsets: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
    ]
}

/// On-device gallery: one console on the three iPhones, upright and on its
/// side, in the look picked in the top bar, scaled to fit the screen width.
/// Reachable from Settings ▸ Debug iPhone, one row per console.
struct PhonePreviewGallery: View {
    let system: PreviewSystem
    @AppStorage(PreviewLook.storageKey) private var look: PreviewLook = .nostalgia

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(PhonePreviewDevice.all) { device in
                        tile(device, landscape: false, availableWidth: geo.size.width - 32)
                        tile(device, landscape: true, availableWidth: geo.size.width - 32)
                    }
                }
                .padding(16)
            }
        }
        .safeAreaInset(edge: .top) { PreviewLookBar(look: $look) }
        .navigationTitle(system.consoleName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func tile(_ device: PhonePreviewDevice, landscape: Bool, availableWidth: CGFloat) -> some View {
        let size = landscape ? device.landscape : device.portrait
        // Clamp to [0,1]: GeometryReader reports width 0 on the first pass, which
        // would make availableWidth negative and hand `.frame` a negative dimension.
        let scale = min(1, max(0, availableWidth) / size.width)

        VStack(alignment: .leading, spacing: 6) {
            Text("\(device.name) · \(landscape ? "landscape" : "portrait") · \(Int(size.width))×\(Int(size.height))")
                .font(.caption)
                .foregroundStyle(.secondary)
            InGameLayoutPreviewRepresentable(system: system, isLandscape: landscape,
                                             safeInsets: landscape ? device.landscapeInsets : device.portraitInsets,
                                             look: look)
                .id(look)
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
    NavigationStack { PhonePreviewGallery(system: .gba) }
}
#endif
