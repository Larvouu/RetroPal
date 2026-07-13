//
//  RAShareScaffold.swift
//  EmulateurGBA
//
//  The shared presentation chrome for every RetroAchievements share card
//  (single achievement, per-game progress, profile overview): the card
//  preview, an optional card-style picker slot, the Share / Save / Close
//  buttons, and the Photos-permission + save-error alerts — the same share
//  kit (ActivityShareSheet, TrackedLinkItem, alert helpers) as the
//  screenshot / clip / stats cards, including their portrait / landscape
//  split. The hosting view owns loading the images and rendering its card;
//  this scaffold owns everything after that.
//
//  `edgeColors` non-nil shows the card in the shared IsometricCardPreview
//  3/4 tilt (the achievement card, harmonized with screenshot / clip);
//  nil keeps the flat preview (the game / overview cards, until their own
//  redesign).
//

import SwiftUI
import Photos

struct RAShareScaffold<Picker: View>: View {
    /// The rendered card (nil while the host is still loading/rendering).
    let cardImage: UIImage?
    /// Base name of the temporary file handed to the share sheet.
    let shareFilename: String
    /// Anonymous analytics tag for the share signal (e.g. "achievement").
    let cardType: String
    /// Isometric-preview extruded-edge colours; nil = flat preview.
    var edgeColors: [Color]? = nil
    let onClose: () -> Void
    /// The card-style picker, shown between the preview and the buttons
    /// (EmptyView via the convenience init when a card has no styles).
    @ViewBuilder var picker: () -> Picker

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showShareSheet = false
    @State private var showPermissionDenied = false
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""

    init(cardImage: UIImage?, shareFilename: String, cardType: String,
         edgeColors: [Color]? = nil, onClose: @escaping () -> Void,
         @ViewBuilder picker: @escaping () -> Picker) {
        self.cardImage = cardImage
        self.shareFilename = shareFilename
        self.cardType = cardType
        self.edgeColors = edgeColors
        self.onClose = onClose
        self.picker = picker
    }

    private var hasPicker: Bool { Picker.self != EmptyView.self }

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.06, green: 0.04, blue: 0.08).ignoresSafeArea())
        // Portrait fits the content (mirrors the screenshot / clip sheets);
        // landscape opens full screen for the 72/28 split.
        .presentationDetents(verticalSizeClass == .compact ? [.large] : [.fraction(detentFraction)])
        .presentationDragIndicator(.visible)
        .photoPermissionDeniedAlert(isPresented: $showPermissionDenied)
        .saveErrorAlert(isPresented: $showSaveError, message: saveErrorMessage)
    }

    /// Sheet height fitted to the square card + buttons (+ picker), as a screen
    /// fraction — the same estimate the screenshot card sheet uses (aspect 1,
    /// no hint header). Portrait only; landscape uses `.large`.
    private var detentFraction: CGFloat {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let estimated = (w - 24) + 200 + (hasPicker ? 50 : 0)
        return min(0.96, estimated / h)
    }

    // MARK: - Layouts (mirror ScreenshotShareView)

    /// Portrait: card on top, the picker, then Share + Save/Close.
    private var portraitLayout: some View {
        VStack(spacing: 16) {
            cardPreview()
            picker()

            VStack(spacing: 10) {
                shareButton
                HStack(spacing: 12) { saveButton; closeButton }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    /// Landscape: the card (+ picker) fills the left, the three actions sit in
    /// a right panel (72 / 28 split). The card is fitted to the available
    /// height, reserving room for the picker, so it stays fully visible.
    private var landscapeLayout: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pickerReserve: CGFloat = hasPicker ? 56 : 0
            let fitByHeight = geo.size.height - 48 - pickerReserve
            let fitByWidth = w * 0.72 - 32
            let cardMaxW = max(120, min(fitByWidth, fitByHeight))
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    cardPreview(maxWidth: cardMaxW)
                    picker()
                }
                .frame(width: w * 0.72)
                .frame(maxHeight: .infinity)

                VStack(spacing: 12) {
                    Spacer(minLength: 8)
                    shareButton
                    saveButton
                    closeButton
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .frame(width: w * 0.28)
                .frame(maxHeight: .infinity)
                .background(Color.white.opacity(0.03))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                }
            }
        }
    }

    // MARK: - Pieces

    /// Card preview: the shared faux-3D tilt when `edgeColors` is set
    /// (presentation only; the shared/saved image stays the flat card),
    /// else the flat rounded image. `maxWidth` fits the card in landscape.
    private func cardPreview(maxWidth: CGFloat? = nil) -> some View {
        Group {
            if let cardImage {
                if let edgeColors {
                    IsometricCardPreview(reduceMotion: reduceMotion, aspect: 1, maxWidth: maxWidth,
                                         edgeColors: edgeColors) {
                        Image(uiImage: cardImage).resizable()
                    }
                } else {
                    Image(uiImage: cardImage)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 16)
                        .frame(maxWidth: maxWidth)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .accessibilityLabel(Text("RetroAchievements card"))
    }

    private var shareButton: some View {
        Button { showShareSheet = true } label: {
            Label(String(localized: "screenshot.share", defaultValue: "Share"),
                  systemImage: "square.and.arrow.up")
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(cardImage == nil)
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(activityItems: shareItems(), cardType: cardType) {
                showShareSheet = false
            }
        }
    }

    private var saveButton: some View {
        Button { saveImage() } label: {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle")
                Text(String(localized: "screenshot.save", defaultValue: "Save"))
            }
            .font(.subheadline).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(cardImage == nil)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                Text(String(localized: "screenshot.dismiss", defaultValue: "Close"))
            }
            .font(.subheadline).foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func shareItems() -> [Any] {
        guard let cardImage else { return [] }
        let link = TrackedLinkItem(RetroPalShare.link(.card))
        return cardImage.temporaryShareFileURL(name: shareFilename).map { [$0, link] }
            ?? [cardImage, link]
    }

    private func saveImage() {
        guard cardImage != nil else { return }
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            performImageSave()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    if status == .authorized || status == .limited {
                        performImageSave()
                    } else {
                        Analytics.signal("permission_denied", ["kind": "photos"])
                        showPermissionDenied = true
                    }
                }
            }
        default:
            Analytics.signal("permission_denied", ["kind": "photos"])
            showPermissionDenied = true
        }
    }

    private func performImageSave() {
        guard let image = cardImage else { return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    onClose()
                } else {
                    saveErrorMessage = error?.localizedDescription
                        ?? NSLocalizedString("screenshot.saveError.message", comment: "")
                    showSaveError = true
                }
            }
        }
    }
}

/// The picker-less form (the overview card, which has no style choice).
extension RAShareScaffold where Picker == EmptyView {
    init(cardImage: UIImage?, shareFilename: String, cardType: String,
         edgeColors: [Color]? = nil, onClose: @escaping () -> Void) {
        self.init(cardImage: cardImage, shareFilename: shareFilename, cardType: cardType,
                  edgeColors: edgeColors, onClose: onClose, picker: { EmptyView() })
    }
}
