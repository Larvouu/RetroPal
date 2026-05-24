//
//  ScreenshotShareView.swift
//  EmulateurGBA
//
//  Share sheet shown after system screenshot detection or pause menu Share button.
//  Shows the branded card preview with Share / Save / Dismiss buttons.
//

import SwiftUI

struct ScreenshotShareView: View {
    let cardImage: UIImage
    let onShare: () -> Void
    let onSave: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Card preview
            Image(uiImage: cardImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .purple.opacity(0.3), radius: 16)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .accessibilityLabel("Game screenshot card")

            Spacer()

            // Action buttons
            VStack(spacing: 10) {
                Button(action: onShare) {
                    Label(NSLocalizedString("screenshot.share", comment: ""), systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color.purple, Color.blue],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Share screenshot")

                HStack(spacing: 12) {
                    Button(action: onSave) {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle")
                            Text(NSLocalizedString("screenshot.save", comment: ""))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Save to Photos")

                    Button(action: onDismiss) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark")
                            Text(NSLocalizedString("screenshot.dismiss", comment: ""))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .background(Color(red: 0.06, green: 0.04, blue: 0.08))
    }
}
