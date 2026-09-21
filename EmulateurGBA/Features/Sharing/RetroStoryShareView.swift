//
//  RetroStoryShareView.swift
//  EmulateurGBA
//
//  Opened by tapping the stats area in the library: renders the branded
//  "retro story" card to an image and offers Share / Save / Close, mirroring
//  the screenshot + clip share sheets.
//

import SwiftUI
import UIKit
import Photos

struct RetroStoryShareView: View {
    let stats: LibraryStats
    let onClose: () -> Void

    @State private var cardImage: UIImage?
    @State private var showShareSheet = false
    @State private var showPermissionDenied = false
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    // The stats card is Classic-only (no style picker — the console-dress styles
    // belong to the in-game screenshot/clip cards); isPro only drives the crown badge.
    @AppStorage("isPro") private var isPro = false

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        // Fill the whole sheet (incl. safe areas and any over-scroll stretch) so
        // the opaque background is never gapped by the transparent/glass sheet.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.06, green: 0.04, blue: 0.08).ignoresSafeArea())
        // Portrait keeps the content-fitted detent; landscape opens full screen
        // (mirrors how the generic Pro sheet uses `.large` in the wide space).
        .presentationDetents(verticalSizeClass == .compact ? [.large] : [.fraction(detentFraction)])
        .presentationDragIndicator(.visible)
        .photoPermissionDeniedAlert(isPresented: $showPermissionDenied)
        .saveErrorAlert(isPresented: $showSaveError, message: saveErrorMessage)
        .onAppear(perform: render)
        // Re-render when Pro is unlocked while the card is open (crown appears).
        .onChange(of: isPro) { _ in renderCard() }
    }

    // MARK: - Layouts

    /// Portrait: card on top, Share then Save/Close stacked below. Unchanged.
    private var portraitLayout: some View {
        VStack(spacing: 16) {
            cardPreview()

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

    /// Landscape: the card fills the left, the three actions sit in a right panel.
    /// This mirrors the generic Pro sheet's wide layout: same 72 / 28 split (the
    /// Pro comparison's two left columns are 0.40 + 0.32, its purchase panel 0.28),
    /// and the same panel treatment (faint surface + a leading hairline). The card
    /// preview is a fixed ~300pt square, so it stays fully visible without scrolling
    /// at every iPhone landscape height.
    private var landscapeLayout: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // Fit the square card to the available height so it never needs
            // scrolling (SE is tightest).
            let cardMaxW = max(120, min(w * 0.72 - 32, geo.size.height - 48))
            HStack(spacing: 0) {
                cardPreview(maxWidth: cardMaxW)
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

    private func cardPreview(maxWidth: CGFloat? = nil) -> some View {
        Group {
            if let cardImage {
                // Presentation only: a faux-3D isometric tilt that gently sways,
                // to make the card feel tactile and worth sharing. The shared/
                // saved image stays the clean front-facing card (see `render()`).
                IsometricCardPreview(reduceMotion: reduceMotion, maxWidth: maxWidth) {
                    Image(uiImage: cardImage).resizable()
                }
                .accessibilityLabel("Retro story card")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }

    @ViewBuilder private var shareButton: some View {
        if let cardImage {
            Button {
                showShareSheet = true
            } label: {
                Label(NSLocalizedString("screenshot.share", comment: ""), systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [Color.purple, Color.blue],
                                       startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            // Share the card image AND the tracked install link together (matches the
            // screenshot/clip cards). ShareLink carries only one item type, so we
            // bridge to UIActivityViewController via ActivityShareSheet.
            .sheet(isPresented: $showShareSheet) {
                ActivityShareSheet(activityItems: storyShareItems(), cardType: "story") {
                    showShareSheet = false
                }
            }
        }
    }

    private var saveButton: some View {
        Button { save() } label: {
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
    }

    /// Sheet height fitted to the content: the square card (sheet width minus the
    /// 12pt side padding) plus the button area, as a fraction of the screen.
    /// Portrait only; landscape uses `.large`.
    private var detentFraction: CGFloat {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let estimated = (w - 24) + 230   // tilted card + buttons
        return min(0.96, estimated / h)
    }

    /// First render (idempotent on appear).
    @MainActor private func render() {
        guard cardImage == nil else { return }
        renderCard()
    }

    /// Render the branded square card at the screenshot-card resolution
    /// (360pt × scale 3 = 1080×1080), so the share image is crisp. Always the
    /// Classic style (the view's default). Re-runnable: called again when Pro
    /// unlocks while open (the crown joins the card).
    @MainActor private func renderCard() {
        let renderer = ImageRenderer(content:
            RetroStoryCardView(stats: stats, includesBranding: true, isPro: isPro)
                .frame(width: 360))
        renderer.scale = 3
        cardImage = renderer.uiImage
    }

    /// Saves the card to Photos. Shows the permission-denied alert (with a Settings
    /// deep-link) if access is refused, a save-error alert on failure, and closes the
    /// card on success. Matches the clip + screenshot cards.
    private func save() {
        guard let image = cardImage else { return }
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            performSave(image)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    if status == .authorized || status == .limited {
                        performSave(image)
                    } else {
                        Analytics.signal("permission_denied", ["kind": "photos"]); showPermissionDenied = true
                    }
                }
            }
        default:
            Analytics.signal("permission_denied", ["kind": "photos"]); showPermissionDenied = true
        }
    }

    private func performSave(_ image: UIImage) {
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

    /// Items for the share sheet: the card as a temporary image FILE plus the tracked
    /// link. Sharing a media file (not a raw UIImage) is what makes Messages / Mail
    /// attach the image instead of dropping it in favor of the link. TrackedLinkItem
    /// still withholds the link from link-greedy apps so the image travels alone there.
    private func storyShareItems() -> [Any] {
        guard let cardImage else { return [] }
        let link = TrackedLinkItem(RetroPalShare.link(.card))
        return cardImage.temporaryShareFileURL(name: "retropal-story").map { [$0, link] } ?? [cardImage, link]
    }
}

/// The tracked install link that rides along with every shared card. The
/// watermark ("Made with Retro Pal") carries brand recall on link-stripping
/// platforms (Instagram, Snapchat, TikTok); this link is the one-tap install
/// path in Messages / Mail / DMs. `ct` distinguishes which card drove the
/// install in App Store Connect campaign analytics.
enum RetroPalShare {
    enum Source: String { case clip, card, screenshot }
    /// `https://retropal.fr/get?ct=...` — a tracked redirect we control. Pre-launch
    /// it forwards to the site; at launch it forwards to the App Store product page.
    static func link(_ source: Source) -> URL {
        URL(string: "https://retropal.fr/get?ct=\(source.rawValue)")!
    }
}

/// Wraps the tracked install link so it rides along ONLY with share targets that
/// reliably keep BOTH the media and the link (Messages, Mail, Copy, AirDrop).
/// Everywhere else — Snapchat, Messenger, Instagram, WhatsApp — the target is
/// link-greedy: it keeps only the URL and silently drops the image/clip. There
/// we withhold the link and let the media travel alone with its baked-in
/// "Made with Retro Pal" watermark. The media is the viral asset; the link must
/// never cannibalize it.
final class TrackedLinkItem: NSObject, UIActivityItemSource {
    private let url: URL
    private static let mediaSafe: Set<UIActivity.ActivityType> = [
        .message, .mail, .copyToPasteboard, .airDrop,
    ]
    init(_ url: URL) { self.url = url }
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }
    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        guard let activityType, Self.mediaSafe.contains(activityType) else { return nil }
        return url
    }
}

/// Minimal SwiftUI bridge to `UIActivityViewController`, so a SwiftUI share
/// button can share an image AND the tracked link together (`ShareLink` carries
/// only one item type). `onComplete` flips the presenting binding so the sheet
/// dismisses cleanly after the user shares or cancels.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var cardType: String = "unknown"
    /// The "share" signal's cardType mix reads as the share-card funnel; pass
    /// false for non-card shares (e.g. the save export) so they stay out of it
    /// (the TD signal set is frozen; no new params or values).
    var tracked: Bool = true
    var onComplete: (() -> Void)? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        // An iPad shows this as a popover wherever it is not the root of a sheet,
        // and a popover with no anchor is a crash. Anchored to its own view's
        // centre, the same insurance `SkinSharing` carries; inert on a phone.
        controller.popoverPresentationController?.sourceView = controller.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 0, height: 0)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if tracked {
                Analytics.signal("share", ["cardType": cardType, "completed": completed ? "true" : "false"])
            }
            onComplete?()
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension UIImage {
    /// Writes the image to a temporary PNG file and returns its URL. Sharing a media
    /// *file* (not a raw UIImage) is what makes Messages / Mail attach the image
    /// alongside the link. a raw UIImage paired with a URL gets dropped in favor of
    /// the link. Mirrors how the gameplay clip already shares an MP4 file.
    func temporaryShareFileURL(name: String) -> URL? {
        guard let data = pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

extension View {
    /// "Photo access required" alert with a deep-link to Settings, shown when the
    /// user refuses Photos access on Save. Shared by the clip + screenshot cards so
    /// the permission UX is identical (and matches the pre-refactor behavior).
    func photoPermissionDeniedAlert(isPresented: Binding<Bool>) -> some View {
        alert(NSLocalizedString("screenshot.permissionDenied.title", comment: ""), isPresented: isPresented) {
            Button(NSLocalizedString("screenshot.permissionDenied.settings", comment: "")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(NSLocalizedString("screenshot.permissionDenied.cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("screenshot.permissionDenied.message", comment: ""))
        }
    }

    /// "Save failed" alert, shown when writing the photo/video to the library fails.
    /// Shared by the clip + screenshot cards.
    func saveErrorAlert(isPresented: Binding<Bool>, message: String) -> some View {
        alert(NSLocalizedString("screenshot.saveError.title", comment: ""), isPresented: isPresented) {
            Button(NSLocalizedString("common.ok", comment: ""), role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

#if DEBUG
/// DEBUG: the stats share card in LANDSCAPE at the smallest (iPhone SE) and
/// largest (16 Pro Max) iPhone landscape sizes, to verify the card + buttons all
/// fit without scrolling. Reachable from Settings ▸ Debug. The red border marks
/// the exact device bounds — any content cut at it would be an overflow.
struct StatsCardLandscapePreviewGallery: View {
    private let devices: [(name: String, size: CGSize)] = [
        ("iPhone SE", CGSize(width: 667, height: 375)),
        ("iPhone 16 Pro Max", CGSize(width: 956, height: 440)),
    ]

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(devices, id: \.name) { device in
                        let scale = min(1, (geo.size.width - 32) / device.size.width)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(device.name) · landscape \(Int(device.size.width))×\(Int(device.size.height))")
                                .font(.caption).foregroundStyle(.secondary)
                            RetroStoryShareView(stats: Self.dummy, onClose: {})
                                .environment(\.verticalSizeClass, .compact)   // force landscape layout
                                .frame(width: device.size.width, height: device.size.height)
                                .clipped()
                                .border(Color.red.opacity(0.6))
                                .scaleEffect(scale, anchor: .topLeading)
                                .frame(width: device.size.width * scale,
                                       height: device.size.height * scale,
                                       alignment: .topLeading)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Stats card landscape")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let dummy = LibraryStats(
        totalSeconds: 47 * 3600 + 25 * 60,
        sessionCount: 92,
        libraryCount: 14,
        playedCount: 9,
        topGames: [
            .init(id: "1", title: "Pokémon Mystery Dungeon: Explorers", seconds: 31 * 3600),
            .init(id: "2", title: "Zelda: The Minish Cap", seconds: 12 * 3600 + 40 * 60),
            .init(id: "3", title: "Mario Kart Super Circuit", seconds: 5 * 3600 + 10 * 60),
        ],
        topConsoles: [
            .init(id: "gba", seconds: 38 * 3600),
            .init(id: "nds", seconds: 7 * 3600),
            .init(id: "gb", seconds: 2 * 3600 + 25 * 60),
        ])
}
#endif
