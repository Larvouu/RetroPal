//
//  OverlayMenuPreview.swift
//  EmulateurGBA
//
//  DEBUG-only visual preview of the in-game pause menu (OverlayMenuView), for
//  reviewing its layout across device sizes WITHOUT running a game or the
//  emulator core.
//
//  Reachable from Settings ▸ Debug ▸ Pause menu preview. It renders the menu at
//  the smallest and largest current iPhones (SE / 16 Pro Max), portrait and
//  landscape, for both the two-lockable-button and four-lockable-button shapes
//  of the menu (Rewind shows on every console since 1.2.5), each scaled
//  to fit. The menu is hosted in a view controller with the device's real
//  safe-area insets so the "does everything fit?" question is faithful (the Pro
//  Max insets alone eat ~90pt of height).
//
//  On-device only: the app target links the device-only melonDS static lib, so
//  the simulator/Xcode-canvas can't link the target. This runs on a real device
//  where the core links fine; no game is started here.
//

#if DEBUG
import UIKit
import SwiftUI

/// Hosts a real OverlayMenuView populated with dummy state, under a chosen set
/// of safe-area insets. The menu reads its portrait/landscape decision from its
/// own bounds, so the host view is simply pinned edge-to-edge.
private final class OverlayMenuPreviewController: UIViewController {
    private let isNDS: Bool
    private let insets: UIEdgeInsets
    private let menu = OverlayMenuView()

    init(isNDS: Bool, safeInsets: UIEdgeInsets) {
        self.isNDS = isNDS
        self.insets = safeInsets
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Simulate the device's safe area so the menu's top/bottom insets and
        // available height match the real thing.
        additionalSafeAreaInsets = insets
        view.backgroundColor = .black

        menu.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menu)
        NSLayoutConstraint.activate([
            menu.topAnchor.constraint(equalTo: view.topAnchor),
            menu.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            menu.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            menu.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        menu.rewindHidden = false   // rewind covers every console since 1.2.5
        // The real menu is handed `TouchControlsView.lockableLetters`; this
        // preview stands in for the two shapes it can take (the SNES matches
        // the DS's four).
        menu.setLockableButtons(isNDS ? ["A", "B", "X", "Y"] : ["A", "B"])
        menu.isHidden = false
        menu.setSoundEnabled(true)
        menu.setButtonLockEnabled(false)
        menu.setCurrentSpeed(1.0)
        menu.setOrientationMode(.auto)
        menu.updateSlots(Self.dummySlots())
        menu.refreshProState()
    }

    /// One filled slot, one empty, and the rest Pro-locked (the free-tier view),
    /// so the slots section shows every visual state. Preview URLs point at
    /// nonexistent files, so no thumbnail loads (loadPreview returns nil).
    private static func dummySlots() -> [(info: SaveSlotInfo, isLocked: Bool)] {
        let isPro = UserDefaults.standard.bool(forKey: "isPro")
        let tmp = FileManager.default.temporaryDirectory
        return (1...SaveStateManager.manualSlotCount).map { i in
            let locked = i > SaveStateManager.freeSlotCount && !isPro
            let exists = (i == 1)
            let info = SaveSlotInfo(
                slotIndex: i,
                isAutoSave: false,
                stateFileURL: tmp.appendingPathComponent("preview_slot\(i).state"),
                previewImageURL: tmp.appendingPathComponent("preview_slot\(i).png"),
                date: exists ? Date() : nil,
                exists: exists,
                isLocked: locked
            )
            return (info, locked)
        }
    }
}

private struct OverlayMenuPreviewRepresentable: UIViewControllerRepresentable {
    let isNDS: Bool
    let safeInsets: UIEdgeInsets
    func makeUIViewController(context: Context) -> OverlayMenuPreviewController {
        OverlayMenuPreviewController(isNDS: isNDS, safeInsets: safeInsets)
    }
    func updateUIViewController(_ vc: OverlayMenuPreviewController, context: Context) {}
}

/// On-device gallery: the pause menu at the smallest and largest iPhones, both
/// orientations, for GBA and NDS. Reachable from Settings ▸ Debug.
struct OverlayMenuPreviewGallery: View {
    private struct Device: Identifiable {
        var id: String { name }
        let name: String
        /// Portrait logical size in points.
        let portrait: CGSize
        let portraitInsets: UIEdgeInsets
        let landscapeInsets: UIEdgeInsets
    }

    private struct Config: Identifiable {
        var id: String { label }
        let label: String
        let isNDS: Bool
        let isLandscape: Bool
    }

    private let devices: [Device] = [
        Device(name: "iPhone SE",
               portrait: CGSize(width: 375, height: 667),
               portraitInsets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0),
               landscapeInsets: .zero),
        Device(name: "iPhone 16 Pro Max",
               portrait: CGSize(width: 440, height: 956),
               portraitInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
               landscapeInsets: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
    ]

    // The 4 device × orientation combos. GBA (Rewind shown) — the NDS menu is
    // identical except Rewind is hidden, so it isn't worth duplicating here.
    private let configs: [Config] = [
        Config(label: "portrait", isNDS: false, isLandscape: false),
        Config(label: "landscape", isNDS: false, isLandscape: true),
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
        .navigationTitle("Pause menu preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func tile(device: Device, cfg: Config, availableWidth: CGFloat) -> some View {
        let size = cfg.isLandscape
            ? CGSize(width: device.portrait.height, height: device.portrait.width)
            : device.portrait
        let insets = cfg.isLandscape ? device.landscapeInsets : device.portraitInsets
        let scale = min(1, availableWidth / size.width)

        VStack(alignment: .leading, spacing: 6) {
            Text("\(device.name) · \(cfg.label) · \(Int(size.width))×\(Int(size.height))")
                .font(.caption)
                .foregroundStyle(.secondary)
            OverlayMenuPreviewRepresentable(isNDS: cfg.isNDS, safeInsets: insets)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                .border(Color.white.opacity(0.3))
        }
    }
}
#endif
