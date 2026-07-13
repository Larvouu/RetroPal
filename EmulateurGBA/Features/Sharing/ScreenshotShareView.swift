//
//  ScreenshotShareView.swift
//  EmulateurGBA
//
//  Share sheet shown after system screenshot detection or pause menu Share button.
//  Renders the branded card from the source frame (so the Standard/Pro style can
//  be toggled live), with Share / Save / Dismiss buttons.
//

import SwiftUI
import Photos
import CoreGraphics

struct ScreenshotShareView: View {
    /// Source game frame + info — the card is rendered in-view so toggling the
    /// Standard/Pro style re-renders instantly (mirrors the stats card).
    let gameFrame: CGImage
    let name: String
    let playTime: TimeInterval
    /// The game's console — the Pro GB/GBC card renders as the console dress.
    var system: PresetSystem = .gba
    /// Per-game style key + the game's skin (when Retro Pal / custom) for the
    /// "current skin" card option. `.none` for the Debug preview (global key).
    var skinContext: ShareCardSkinContext = .none
    /// Dismisses the card sheet (close button + after Save). Swipe-to-dismiss is
    /// handled by the presenting `.sheet`; the game resume is wired to its onDismiss.
    let onClose: () -> Void
    /// One-time first-open hint shown as a header (nil once dismissed).
    var hintText: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var cardImage: UIImage?
    @State private var showShareSheet = false
    @State private var showPermissionDenied = false
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""

    // The crown stays on the card whenever isPro, regardless of the chosen style.
    // The style choice is PER-GAME (skinContext carries the game's key + skin).
    @AppStorage("isPro") private var isPro = false
    @AppStorage private var styleChoice: String

    init(gameFrame: CGImage, name: String, playTime: TimeInterval,
         system: PresetSystem = .gba, skinContext: ShareCardSkinContext = .none,
         onClose: @escaping () -> Void, hintText: String? = nil) {
        self.gameFrame = gameFrame
        self.name = name
        self.playTime = playTime
        self.system = system
        self.skinContext = skinContext
        self.onClose = onClose
        self.hintText = hintText
        _styleChoice = AppStorage(wrappedValue: "", skinContext.styleKey)
    }

    private var effectiveStyle: ShareCardStyle {
        ShareCardStyle.effective(choice: styleChoice, skinAvailable: skinContext.skin != nil)
    }

    /// The card is square (1080×1080), like the clip + stats cards.
    private let aspect: CGFloat = 1

    /// The faux-thickness edge colour for the 3/4 preview tilt: each console card extrudes in its
    /// own body colour so the edge reads as that console's plastic; the Classic card keeps the
    /// purple brand edge. Shared with the RA cards via ShareCardStyle.
    private var cardEdgeColors: [Color] {
        effectiveStyle.extrudeEdgeColors(system: system, skin: skinContext.skin)
    }

    /// The per-game style picker, fed the game's key + (when dressed) its skin option.
    private var stylePicker: some View {
        CardStylePicker(styleKey: skinContext.styleKey,
                        skinOption: skinContext.skin.map {
                            ($0.name, $0.variant.bodyColor(for: system))
                        })
    }

    var body: some View {
        VStack(spacing: 0) {
            hintHeader
            Group {
                if verticalSizeClass == .compact {
                    landscapeLayout
                } else {
                    portraitLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Fill the whole sheet (incl. safe areas) so the opaque background is never
        // gapped by the transparent/glass sheet — mirrors the stats card.
        .background(Color(red: 0.06, green: 0.04, blue: 0.08).ignoresSafeArea())
        // Portrait fits the content; landscape opens full screen. `.presentationDetents`
        // applied via the presenting SwiftUI `.sheet` is what gives full-screen AND
        // swipe-to-dismiss in landscape (a UIKit-presented sheet can't do both).
        .presentationDetents(verticalSizeClass == .compact ? [.large] : [.fraction(detentFraction)])
        .presentationDragIndicator(.visible)
        .photoPermissionDeniedAlert(isPresented: $showPermissionDenied)
        .saveErrorAlert(isPresented: $showSaveError, message: saveErrorMessage)
        .onAppear(perform: render)
        // Re-render when the style changes (Pro unlocked while open, or the
        // Standard/Pro picker toggled).
        .onChange(of: effectiveStyle) { _ in renderCard() }
    }

    /// Sheet height fitted to the square card + buttons (+ hint + picker), as a
    /// screen fraction. Portrait only; landscape uses `.large`.
    private var detentFraction: CGFloat {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let estimated = (w - 24) / max(aspect, 0.1) + 200
            + (hintText != nil ? 52 : 0) + (isPro ? 50 : 0)
        return min(0.96, estimated / h)
    }

    /// One-time first-open hint header (also surfaced by the Debug previews).
    /// Empty when `hintText` is nil, so the sheet is unchanged once dismissed.
    @ViewBuilder private var hintHeader: some View {
        if let hintText {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.footnote)
                Text(hintText)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08))
        }
    }

    // MARK: - Layouts

    /// Portrait: card on top, the style picker, then Share + Save/Dismiss.
    private var portraitLayout: some View {
        VStack(spacing: 16) {
            cardPreview()
            stylePicker

            VStack(spacing: 10) {
                shareButton
                HStack(spacing: 12) {
                    saveButton
                    closeButton
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    /// Landscape: the card (+ picker) fills the left, the three actions sit in a
    /// right panel (72 / 28 split). The card is fitted to the available height,
    /// reserving room for the picker, so it stays fully visible without scrolling.
    private var landscapeLayout: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pickerReserve: CGFloat = isPro ? 56 : 0
            let fitByHeight = (geo.size.height - 48 - pickerReserve) * aspect
            let fitByWidth = w * 0.72 - 32
            let cardMaxW = max(120, min(fitByWidth, fitByHeight))
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    cardPreview(maxWidth: cardMaxW)
                    stylePicker
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

    /// Card preview, as a light faux-3D tilt (presentation only; the shared/saved
    /// image stays the flat card). `maxWidth` fits the card in landscape.
    private func cardPreview(maxWidth: CGFloat? = nil) -> some View {
        Group {
            if let cardImage {
                IsometricCardPreview(reduceMotion: reduceMotion, aspect: aspect, maxWidth: maxWidth,
                                     edgeColors: cardEdgeColors) {
                    Image(uiImage: cardImage).resizable()
                }
                .accessibilityLabel("Game screenshot card")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }

    private var shareButton: some View {
        Button {
            showShareSheet = true
        } label: {
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
        .disabled(cardImage == nil)
        // Share the card image FILE + tracked link together (same as the stats card).
        // The card stays presented behind this nested sheet, so the game stays paused
        // until the user closes the card.
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(activityItems: screenshotShareItems(), cardType: "screenshot") {
                showShareSheet = false
            }
        }
    }

    private var saveButton: some View {
        Button { saveImage() } label: {
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
        .disabled(cardImage == nil)
    }

    private var closeButton: some View {
        Button(action: onClose) {
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

    // MARK: - Render

    /// First render (idempotent on appear).
    @MainActor private func render() {
        guard cardImage == nil else { return }
        renderCard()
    }

    /// Renders the branded square card from the source frame at the effective style.
    /// Re-runnable: called again whenever the style changes.
    @MainActor private func renderCard() {
        let info = ScreenshotCardRenderer.GameInfo(name: name, playTimeSeconds: playTime, isPro: isPro)
        cardImage = ScreenshotCardRenderer.render(gameFrame: gameFrame, info: info,
                                                  style: effectiveStyle, system: system,
                                                  skinVariant: skinContext.skin?.variant)
    }

    /// Items for the share sheet: the card as a temporary image FILE plus the tracked
    /// link. Sharing a media file (not a raw UIImage) is what makes Messages / Mail
    /// attach the image instead of dropping it for the link; TrackedLinkItem withholds
    /// the link from link-greedy apps so the image travels alone there.
    private func screenshotShareItems() -> [Any] {
        guard let cardImage else { return [] }
        let link = TrackedLinkItem(RetroPalShare.link(.screenshot))
        return cardImage.temporaryShareFileURL(name: "retropal-screenshot").map { [$0, link] } ?? [cardImage, link]
    }

    /// Saves the card image to Photos. Shows the permission-denied alert (with a
    /// Settings deep-link) if access is refused, a save-error alert on failure, and
    /// closes the card on success. Matches the clip card and the pre-refactor UX.
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
                        Analytics.signal("permission_denied", ["kind": "photos"]); showPermissionDenied = true
                    }
                }
            }
        default:
            Analytics.signal("permission_denied", ["kind": "photos"]); showPermissionDenied = true
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
