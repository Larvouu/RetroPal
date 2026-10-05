//
//  NDSLidPreviewGallery.swift
//  EmulateurGBA
//
//  Settings ▸ Debug ▸ "DS lid closed": the DS with its lid closed from the
//  pause menu, message on its top screen, on the three phones the other
//  galleries use (SE, 14 Pro, 16 Pro Max) and the three iPads (mini, 11-inch,
//  13-inch), upright and on their side. Drawn by the real layout engine and
//  the game's own `NDSLidMessageView`, so it shows what plays.
//

#if DEBUG
import SwiftUI
import UIKit

struct NDSLidPreviewGallery: View {
    private struct Device: Identifiable {
        var id: String { name }
        let name: String
        let portrait: CGSize
        let portraitInsets: UIEdgeInsets
        let landscapeInsets: UIEdgeInsets
    }

    private let devices: [Device] = [
        Device(name: "iPhone SE", portrait: CGSize(width: 375, height: 667),
               portraitInsets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0),
               landscapeInsets: .zero),
        Device(name: "iPhone 14 Pro", portrait: CGSize(width: 393, height: 852),
               portraitInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
               landscapeInsets: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
        Device(name: "iPhone 16 Pro Max", portrait: CGSize(width: 440, height: 956),
               portraitInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
               landscapeInsets: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
    ] + TabletPreviewDevice.all.map {
        Device(name: $0.name, portrait: $0.portrait,
               portraitInsets: TabletPreviewDevice.insets, landscapeInsets: TabletPreviewDevice.insets)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(devices) { device in
                        tile(device, landscape: false, availableWidth: geo.size.width - 32)
                        tile(device, landscape: true, availableWidth: geo.size.width - 32)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("DS lid closed")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func tile(_ device: Device, landscape: Bool, availableWidth: CGFloat) -> some View {
        let size = landscape
            ? CGSize(width: device.portrait.height, height: device.portrait.width)
            : device.portrait
        let scale = min(1, max(0, availableWidth) / size.width)
        VStack(alignment: .leading, spacing: 6) {
            Text("\(device.name) · \(landscape ? "landscape" : "portrait") · \(Int(size.width))×\(Int(size.height))")
                .font(.caption)
                .foregroundStyle(.secondary)
            InGameLayoutPreviewRepresentable(system: .nds, isLandscape: landscape,
                                             safeInsets: landscape ? device.landscapeInsets : device.portraitInsets,
                                             showsLidMessage: true)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                .border(Color.white.opacity(0.3))
        }
    }
}
#endif
