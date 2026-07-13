//
//  CoverCropView.swift
//  EmulateurGBA
//
//  Square crop editor for the custom game cover: pinch to zoom, drag to
//  pan, the image always covers the square viewport (minimum zoom = fill,
//  offsets clamped to the edges) — the Instagram-profile-picture
//  interaction, square instead of round. Saving renders the visible square
//  as a 1024x1024 image and hands it to the caller.
//
//  All math runs in the UIImage's point space (image.size and draw(in:)
//  both account for EXIF orientation, so photos need no normalization).
//

import SwiftUI
import UIKit

struct CoverCropView: View {
    let image: UIImage
    /// Called with the cropped square on Save; the view dismisses itself.
    let onCrop: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAtGestureStart: CGSize = .zero

    private static let maxZoom: CGFloat = 4
    private static let outputSide: CGFloat = 1024

    var body: some View {
        GeometryReader { geo in
            let side = max(1, min(geo.size.width, geo.size.height) - 32)
            let base = fillScale(side: side)
            VStack {
                Spacer()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: image.size.width * base * zoom,
                           height: image.size.height * base * zoom)
                    .offset(offset)
                    .frame(width: side, height: side)
                    .clipped()
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(.white.opacity(0.7), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .gesture(dragGesture(side: side)
                        .simultaneously(with: zoomGesture(side: side)))
                Spacer()
                HStack {
                    Button(NSLocalizedString("common.cancel", comment: "")) {
                        dismiss()
                    }
                    Spacer()
                    Button(NSLocalizedString("common.save", comment: "")) {
                        onCrop(croppedImage(side: side))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: - Geometry

    /// Zoom-1 scale: the image exactly COVERS the square viewport.
    private func fillScale(side: CGFloat) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 1 }
        return max(side / image.size.width, side / image.size.height)
    }

    /// Keeps the viewport fully covered: the image edge can never be
    /// dragged inside the square.
    private func clampedOffset(_ proposed: CGSize, side: CGFloat, zoom: CGFloat) -> CGSize {
        let base = fillScale(side: side)
        let maxX = max(0, (image.size.width * base * zoom - side) / 2)
        let maxY = max(0, (image.size.height * base * zoom - side) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clampedOffset(
                    CGSize(width: offsetAtGestureStart.width + value.translation.width,
                           height: offsetAtGestureStart.height + value.translation.height),
                    side: side, zoom: zoom)
            }
            .onEnded { _ in offsetAtGestureStart = offset }
    }

    private func zoomGesture(side: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(zoomAtGestureStart * value, 1), Self.maxZoom)
                offset = clampedOffset(offset, side: side, zoom: zoom)
            }
            .onEnded { _ in
                zoomAtGestureStart = zoom
                offsetAtGestureStart = offset
            }
    }

    // MARK: - Crop

    /// Renders the square the user framed, at outputSide x outputSide.
    private func croppedImage(side: CGFloat) -> UIImage {
        let k = fillScale(side: side) * zoom
        let cropSide = side / k
        // The viewport center in image points (offset moves the image, so
        // the visible center moves the opposite way).
        let centerX = image.size.width / 2 - offset.width / k
        let centerY = image.size.height / 2 - offset.height / k
        var rect = CGRect(x: centerX - cropSide / 2, y: centerY - cropSide / 2,
                          width: cropSide, height: cropSide)
        // Defensive clamp (offsets are already edge-clamped).
        rect.origin.x = min(max(rect.origin.x, 0), max(0, image.size.width - rect.width))
        rect.origin.y = min(max(rect.origin.y, 0), max(0, image.size.height - rect.height))

        let scale = Self.outputSide / cropSide
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // outputSide is in pixels, not points
        return UIGraphicsImageRenderer(
            size: CGSize(width: Self.outputSide, height: Self.outputSide),
            format: format
        ).image { _ in
            image.draw(in: CGRect(x: -rect.minX * scale,
                                  y: -rect.minY * scale,
                                  width: image.size.width * scale,
                                  height: image.size.height * scale))
        }
    }
}
