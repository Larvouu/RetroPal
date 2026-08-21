//
//  ClipShareView.swift
//  EmulateurGBA
//
//  Preview sheet for a shareable gameplay clip — the motion counterpart to
//  ScreenshotShareView. The card chrome is drawn LIVE in SwiftUI over the raw
//  looping gameplay video, so a Pro user can toggle the Standard/Pro card style
//  instantly. The chrome'd MP4 is baked at the chosen style only when the user
//  taps Share / Save (model.exportFinalClip).
//

import SwiftUI
import AVFoundation
import Photos

struct ClipShareView: View {
    @ObservedObject var model: ClipShareModel
    /// Inner game-frame aspect (width / height) so the skeleton + bezel match the
    /// game type while the clip encodes (NDS ~0.67, GBA 1.5, GB/GBC ~1.1).
    let frameAspect: CGFloat
    /// Dismisses the card sheet (close button + after Save). Swipe-to-dismiss is
    /// handled by the presenting `.sheet`; the game resume is wired to its onDismiss.
    let onClose: () -> Void
    /// One-time first-open hint shown as a header (nil once dismissed).
    var hintText: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showShareSheet = false
    @State private var showPermissionDenied = false
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""
    /// True while the final chrome'd MP4 is being baked (after Share/Save tap).
    @State private var exporting = false
    /// The baked clip URL, set when an export finishes; drives the share sheet.
    @State private var exportedURL: URL?

    // The crown stays on the card whenever isPro, regardless of the chosen style.
    // The style choice is PER-GAME (the model carries the game's key + skin context).
    @AppStorage("isPro") private var isPro = false
    @AppStorage private var styleChoice: String

    init(model: ClipShareModel, frameAspect: CGFloat,
         onClose: @escaping () -> Void, hintText: String? = nil) {
        self.model = model
        self.frameAspect = frameAspect
        self.onClose = onClose
        self.hintText = hintText
        _styleChoice = AppStorage(wrappedValue: "", model.skinContext.styleKey)
    }

    private var effectiveStyle: ShareCardStyle {
        ShareCardStyle.effective(choice: styleChoice,
                                 skinAvailable: model.skinContext.skin != nil)
    }

    /// Preview ready = the raw gameplay clip has finished encoding.
    private var ready: Bool { model.gameplayURL != nil }

    /// The faux-thickness extrude colour for the 3/4 preview tilt — mirrors
    /// ScreenshotShareView.cardEdgeColors (the word-of-truth screenshot card): each
    /// console card extrudes in its own body colour (Nostalgia's per-console pairs,
    /// or the current skin's body for the "skin" style) so the edge reads as that
    /// console's plastic; the Classic card keeps the purple brand edge.
    private var cardEdgeColors: [Color] {
        if effectiveStyle == .skin, let skin = model.skinContext.skin {
            return skin.variant.cardExtrudeColors(for: model.system)
        }
        if model.system == .gbc && effectiveStyle == .nostalgia {
            return [Color(red: 0.66, green: 0.65, blue: 0.64), Color(red: 0.50, green: 0.49, blue: 0.48)]
        }
        if model.system == .gba && effectiveStyle == .nostalgia {
            // The GBA main body purple (#7558EB), so the extruded 3D edge reads as the console body.
            return [Color(red: 0.510, green: 0.410, blue: 0.950), Color(red: 0.380, green: 0.270, blue: 0.800)]
        }
        if model.system == .nds && effectiveStyle == .nostalgia {
            // The NDS main body grey (#C4C4C4), so the extruded 3D edge reads as the console body.
            return [Color(red: 0.820, green: 0.820, blue: 0.820), Color(red: 0.680, green: 0.680, blue: 0.680)]
        }
        return [Color(red: 0.22, green: 0.12, blue: 0.34), Color(red: 0.07, green: 0.04, blue: 0.13)]
    }

    /// The per-game style picker, fed the game's key + (when dressed) its skin option.
    private var stylePicker: some View {
        CardStylePicker(styleKey: model.skinContext.styleKey,
                        skinOption: model.skinContext.skin.map {
                            ($0.name, $0.variant.bodyColor(for: model.system))
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
        .presentationDetents(verticalSizeClass == .compact ? [.large] : [.fraction(detentFraction)])
        .presentationDragIndicator(.visible)
        .photoPermissionDeniedAlert(isPresented: $showPermissionDenied)
        .saveErrorAlert(isPresented: $showSaveError, message: saveErrorMessage)
        // Encode failed (rare): the skeleton card is still up, so surface it here and
        // close the card on OK (which resumes the game via the sheet's onDismiss).
        .alert(NSLocalizedString("clip.failed.title", value: "Couldn't create the clip", comment: ""),
               isPresented: $model.renderFailed) {
            Button(NSLocalizedString("common.ok", value: "OK", comment: "")) { onClose() }
        } message: {
            Text(NSLocalizedString("clip.failed.message", value: "Please try again.", comment: ""))
        }
    }

    /// Sheet height fitted to the square clip card + buttons (+ hint + picker), as a
    /// screen fraction. Portrait only; landscape uses `.large`.
    private var detentFraction: CGFloat {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let estimated = (w - 24) + 200 + (hintText != nil ? 52 : 0) + (isPro ? 50 : 0)
        return min(0.96, estimated / h)
    }

    /// One-time first-open hint header (also surfaced by the Debug previews).
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

    /// Portrait: card on top, the Standard/Pro picker, then Share + Save/Dismiss.
    private var portraitLayout: some View {
        VStack(spacing: 16) {
            cardPreview()
            // Hidden while exporting so the style can't be toggled mid-bake (the
            // export already captured the style — toggling would only mislead).
            stylePicker
                .opacity(exporting ? 0 : 1)
                .disabled(exporting)

            ZStack {
                VStack(spacing: 10) {
                    shareButton
                    HStack(spacing: 12) {
                        saveButton
                        closeButton
                    }
                }
                .opacity(ready && !exporting ? 1 : 0)
                .disabled(!ready || exporting)

                if !ready || exporting { ClipLoadingCaption().transition(.opacity) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .animation(.easeInOut(duration: 0.25), value: ready)
            .animation(.easeInOut(duration: 0.2), value: exporting)
        }
    }

    /// Landscape: the card (+ picker) fills the left, the three actions sit in a
    /// right panel (72 / 28 split). The square card fits every iPhone landscape
    /// height, reserving room for the picker, so nothing needs scrolling.
    private var landscapeLayout: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let pickerReserve: CGFloat = isPro ? 56 : 0
            let cardMaxW = max(120, min(w * 0.72 - 32, geo.size.height - 48 - pickerReserve))
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    cardPreview(maxWidth: cardMaxW)
                    stylePicker
                        .opacity(exporting ? 0 : 1)
                        .disabled(exporting)
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
                .opacity(ready && !exporting ? 1 : 0)
                .disabled(!ready || exporting)
                .padding(.horizontal, 12)
                .frame(width: w * 0.28)
                .frame(maxHeight: .infinity)
                .background(Color.white.opacity(0.03))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                }
                .overlay {
                    if !ready || exporting { ClipLoadingCaption().padding(.horizontal, 12).transition(.opacity) }
                }
                .animation(.easeInOut(duration: 0.25), value: ready)
                .animation(.easeInOut(duration: 0.2), value: exporting)
            }
        }
    }

    // MARK: - Pieces

    /// The live card: SwiftUI chrome (toggleable Standard/Pro) drawn over the looping
    /// gameplay video, in a light faux-3D tilt. While the raw clip encodes, the card
    /// shows the shimmering skeleton instead of the video. `maxWidth` fits landscape.
    private func cardPreview(maxWidth: CGFloat? = nil) -> some View {
        IsometricCardPreview(reduceMotion: reduceMotion, aspect: 1, maxWidth: maxWidth,
                             edgeColors: cardEdgeColors) {
            ClipCardView(frameAspect: frameAspect, style: effectiveStyle, isPro: isPro,
                         videoURL: model.gameplayURL, title: model.title, playTime: model.playTime,
                         system: model.system, skinVariant: model.skinContext.skin?.variant)
        }
        .accessibilityLabel("Gameplay clip preview")
    }

    private var shareButton: some View {
        Button {
            startExport { url in exportedURL = url; showShareSheet = true }
        } label: {
            Label(NSLocalizedString("screenshot.share", comment: ""), systemImage: "square.and.arrow.up")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(colors: [Color.purple, Color.blue],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel("Share clip")
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(activityItems: clipShareItems(), cardType: "clip") {
                showShareSheet = false
            }
        }
    }

    private var saveButton: some View {
        Button { saveClip() } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                Text(NSLocalizedString("screenshot.save", comment: ""))
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("Save to Photos")
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

    // MARK: - Export / Share / Save

    /// Bake the final chrome'd MP4 at the current style, then run `then` with its URL.
    /// Shows the "Preparing…" caption while encoding; surfaces an error on failure.
    private func startExport(_ then: @escaping (URL) -> Void) {
        guard !exporting, let export = model.exportFinalClip else { return }
        exporting = true
        export(effectiveStyle) { url in
            exporting = false
            guard let url else {
                saveErrorMessage = NSLocalizedString("screenshot.saveError.message", comment: "")
                showSaveError = true
                return
            }
            then(url)
        }
    }

    /// Items for the share sheet: the baked clip MP4 + the tracked link.
    private func clipShareItems() -> [Any] {
        guard let url = exportedURL else { return [] }
        return [url, TrackedLinkItem(RetroPalShare.link(.clip))]
    }

    /// Saves the clip MP4 to Photos: checks permission, bakes the final clip, then
    /// writes it. Shows the permission-denied alert (with a Settings deep-link) on
    /// refusal, a save-error alert on failure, and closes the card on success.
    private func saveClip() {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            startExport { performClipSave($0) }
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    if status == .authorized || status == .limited {
                        startExport { performClipSave($0) }
                    } else {
                        Analytics.signal("permission_denied", ["kind": "photos"]); showPermissionDenied = true
                    }
                }
            }
        default:
            Analytics.signal("permission_denied", ["kind": "photos"]); showPermissionDenied = true
        }
    }

    private func performClipSave(_ url: URL) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
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

/// The gentle-pulsing caption shown in the action-row space while the raw clip
/// encodes (below the card in portrait, in the right panel in landscape). Fades out
/// as the Share/Save/Close buttons fade in. Respects Reduce Motion (static, no pulse).
private struct ClipLoadingCaption: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text(NSLocalizedString("clip.loading",
                                   value: "Capturing the moment… one sec.",
                                   comment: "Caption under the clip card while the clip is being encoded"))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.7))
        .opacity(reduceMotion ? 0.85 : (pulsing ? 1.0 : 0.5))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Muted, infinitely-looping video preview (AVPlayerLooper + AVQueuePlayer).
struct LoopingClipView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> LoopingClipUIView { LoopingClipUIView(url: url) }
    func updateUIView(_ uiView: LoopingClipUIView, context: Context) { uiView.update(url: url) }
}

final class LoopingClipUIView: UIView {
    private let queuePlayer = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private var currentURL: URL?

    init(url: URL) {
        super.init(frame: .zero)
        backgroundColor = .black
        queuePlayer.isMuted = true
        playerLayer.player = queuePlayer
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        update(url: url)
        // Returning from another app (e.g. after sharing to Snapchat/Messenger) leaves the player
        // layer showing a frozen frame — backgrounding drops its contents and suspends playback.
        // Re-attach + restart from the top so the loop always resumes cleanly.
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartFromBeginning),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.play()
    }

    /// Re-attach the player to the layer (its contents are released on background, leaving a frozen
    /// frame) and replay the loop from the start.
    @objc private func restartFromBeginning() {
        guard currentURL != nil else { return }
        playerLayer.player = nil
        playerLayer.player = queuePlayer
        queuePlayer.seek(to: .zero)
        queuePlayer.play()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

/// Drives ClipShareView: starts with no preview clip (skeleton shown), gets
/// `gameplayURL` set once the raw gameplay clip finishes encoding (reveals the clip
/// + enables the buttons), and bakes the final chrome'd clip on demand via
/// `exportFinalClip` (called from Share / Save with the chosen style).
final class ClipShareModel: ObservableObject {
    /// Raw gameplay clip (no chrome) for the live preview.
    @Published var gameplayURL: URL?
    /// Set by the encoder on failure; ClipShareView surfaces an alert and closes.
    @Published var renderFailed = false
    /// Card text, set by the VC before presenting (read when the video appears).
    var title: String = ""
    var playTime: TimeInterval = 0
    /// The game's console (GB/GBC Pro renders the console card). Set by the VC.
    var system: PresetSystem = .gba
    /// Per-game style key + the game's skin (when Retro Pal / custom) for the
    /// "current skin" card option. Set by the VC; `.none` for the Debug preview.
    var skinContext: ShareCardSkinContext = .none
    /// Bake the final chrome'd MP4 at the given style (off-thread); callback on the
    /// main thread with the file URL (nil on failure). Set by the VC, which holds the
    /// captured frames + metadata.
    var exportFinalClip: ((ShareCardStyle, @escaping (URL?) -> Void) -> Void)?
}

/// The clip card drawn in SwiftUI: the same chrome as the exported MP4 (logo, neon
/// bezel, title + play-time line with the Pro crown, footer, edge + Pro gold wash),
/// with the looping gameplay video in the bezel. When `videoURL` is nil it shows the
/// shimmering loading skeleton instead. Proportions mirror GameplayClipRenderer's
/// 1080 card (k = side / 1080).
struct ClipCardView: View {
    let frameAspect: CGFloat
    /// Card visual style (gold-neon for `.nostalgia`).
    var style: ShareCardStyle = .retroPal
    /// Real Pro ownership — drives the crown, independent of `style`.
    var isPro: Bool = false
    /// Raw gameplay clip; when nil, the card shows the loading skeleton.
    var videoURL: URL? = nil
    var title: String = ""
    var playTime: TimeInterval = 0
    /// The game's console — the Nostalgia + current-skin styles render the console card, not the neon card.
    var system: PresetSystem = .gba
    /// The game's current dress (Retro Pal / custom), rendered when `style == .skin`.
    var skinVariant: DressVariant? = nil

    private let purple = Color(red: 0.6, green: 0.4, blue: 1.0)
    /// The saturated card purple used by the real card's Pro edge.
    private let edgePurple = Color(red: 0.45, green: 0.2, blue: 0.85)
    private var isNostalgiaStyle: Bool { style == .nostalgia }
    /// The console dress for the current style (nil = the neon Classic card).
    private var consoleVariant: DressVariant? {
        ScreenshotCardRenderer.consoleVariant(style: style, skinVariant: skinVariant)
    }

    var body: some View {
        if let consoleVariant { consoleFace(variant: consoleVariant) } else { neonCardBody }
    }

    /// Nostalgia / current-skin styles: the shared console-card chrome (built once, in the dress's
    /// palette) with the looping clip in the console's screen rect — the motion sibling of the
    /// screenshot console card. The layout + chrome are the matching console pair for the game's
    /// system.
    private func consoleFace(variant: DressVariant) -> some View {
        GeometryReader { geo in
            let k = geo.size.width / 1080
            let info = ScreenshotCardRenderer.GameInfo(name: title, playTimeSeconds: playTime, isPro: isPro)
            // Same console pair as the exported clip and the screenshot card, from the one
            // place that maps a console to its card. This view had its OWN copy of that mapping,
            // ending in "or else the Game Boy", which is why the Super Nintendo's clip PREVIEW
            // still wore a Game Boy after the exporter was fixed: there were three copies and
            // fixing one is indistinguishable from fixing the bug until you find the next.
            let pair = ScreenshotCardRenderer.consoleCard(
                system: system, gameFrame: nil, gameAspect: frameAspect, info: info, variant: variant)
            let layout = pair?.layout ?? GBCardLayout.make(side: 1080, gameNativeSize: CGSize(width: frameAspect, height: 1))
            let chrome = pair?.image
            ZStack(alignment: .topLeading) {
                if let chrome {
                    Image(uiImage: chrome).resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if layout.ndsScreens.count == 2 {
                    // NDS separated: the stacked clip split into the upper + lower screen rects.
                    clipScreen(layout.ndsScreens[0], half: .top, k: k)
                    clipScreen(layout.ndsScreens[1], half: .bottom, k: k)
                } else {
                    Group {
                        if let videoURL { LoopingClipView(url: videoURL) }
                        else { SkeletonBox(cornerRadius: 6 * k) }
                    }
                    .frame(width: layout.screen.width * k, height: layout.screen.height * k)
                    .clipShape(RoundedRectangle(cornerRadius: 6 * k, style: .continuous))
                    .offset(x: layout.screen.minX * k, y: layout.screen.minY * k)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private enum ScreenHalf { case top, bottom }

    /// One NDS screen of the separated clip: the stacked gameplay video sized to this screen's width
    /// (so the matching half exactly fills it), windowed to the top or bottom half, clipped to the
    /// screen rect, and offset into place. The export composites the split frames perfectly in sync;
    /// the two preview players can drift slightly over long playback (preview only).
    @ViewBuilder
    private func clipScreen(_ rect: CGRect, half: ScreenHalf, k: CGFloat) -> some View {
        Group {
            if let videoURL {
                LoopingClipView(url: videoURL)
                    // Full stacked video at this screen's width: its half == the screen's height.
                    .frame(width: rect.width * k, height: rect.width * k / max(frameAspect, 0.01))
                    // Window to the matching half (the taller video overflows and is clipped below).
                    .frame(width: rect.width * k, height: rect.height * k,
                           alignment: half == .top ? .top : .bottom)
            } else {
                SkeletonBox(cornerRadius: 6 * k)
                    .frame(width: rect.width * k, height: rect.height * k)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6 * k, style: .continuous))
        .offset(x: rect.minX * k, y: rect.minY * k)
    }

    private var neonCardBody: some View {
        GeometryReader { geo in
            let k = geo.size.width / 1080
            // Lay the game screen, name and play row at the SAME rect as the GB/GBC
            // Nostalgia console card (and the standard screenshot card), so toggling
            // Nostalgia <-> Classic never shifts the shared components, and the live
            // preview matches the exported clip (GameplayClipRenderer.compositeCard).
            let screen = ScreenshotCardRenderer.standardGameScreenRect(
                side: 1080, gameNativeSize: CGSize(width: frameAspect, height: 1))
            let bezelPad: CGFloat = 8
            let bezel = screen.insetBy(dx: -bezelPad, dy: -bezelPad)
            let infoTop = screen.maxY + bezelPad + 32

            ZStack(alignment: .topLeading) {
                // Full-size anchor so the ZStack fills `geo` and the topLeading offsets
                // below are measured from the card's top-left (not a centred sub-frame).
                Color.clear
                    .frame(width: geo.size.width, height: geo.size.height)

                // Retro Pal logo — the sole element above the game (Classic only).
                logo(k)
                    .frame(width: 56 * k, height: 56 * k)
                    .offset(x: (1080 - 56) / 2 * k, y: 64 * k)

                // Neon bezel around the game.
                RoundedRectangle(cornerRadius: 16 * k, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.06, blue: 0.12))
                    .overlay(RoundedRectangle(cornerRadius: 16 * k, style: .continuous)
                        .strokeBorder(purple.opacity(0.6), lineWidth: 1.5 * k))
                    .shadow(color: purple.opacity(0.4), radius: 14 * k)
                    .frame(width: bezel.width * k, height: bezel.height * k)
                    .offset(x: bezel.minX * k, y: bezel.minY * k)

                // The looping clip (or the loading skeleton) in the screen rect.
                gameArea(k: k)
                    .frame(width: screen.width * k, height: screen.height * k)
                    .clipShape(RoundedRectangle(cornerRadius: 12 * k, style: .continuous))
                    .offset(x: screen.minX * k, y: screen.minY * k)

                // Game name + play-time / crown / Pro-member row. Rendered through the SAME CG path
                // (ScreenshotCardRenderer.classicInfoImage -> drawGBInfoBlock) as the screenshot
                // card + the baked export, so the block is identical — size, position and colour —
                // across every SC (clip + screenshot, Nostalgia + Classic). Loading keeps skeleton
                // bars at the standard cursor (screen.maxY + 8 + 32).
                if videoURL != nil {
                    if let infoImg = ScreenshotCardRenderer.classicInfoImage(
                        side: 1080, screen: screen,
                        info: ScreenshotCardRenderer.GameInfo(name: title, playTimeSeconds: playTime, isPro: isPro)) {
                        Image(uiImage: infoImg).resizable()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else {
                    VStack(spacing: 8 * k) {
                        SkeletonBox(cornerRadius: 4).frame(width: 280 * k, height: 30 * k)
                        SkeletonBox(cornerRadius: 4).frame(width: 180 * k, height: 22 * k)
                    }
                    .frame(width: geo.size.width)
                    .offset(y: infoTop * k)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .bottom) {
                Text(NSLocalizedString("screenshot.footer", comment: ""))
                    .font(.system(size: 22 * k, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 64 * k)
            }
            .background(cardBackground)
            .overlay { if isNostalgiaStyle { proEdge } }
        }
    }

    /// The game area: the looping gameplay video when ready, else the loading box.
    @ViewBuilder private func gameArea(k: CGFloat) -> some View {
        if let videoURL {
            LoopingClipView(url: videoURL)
        } else {
            SkeletonBox(cornerRadius: 12 * k)
        }
    }


    /// Standard purple-dark gradient; Pro adds the faint warm gold wash from the top.
    private var cardBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.06, blue: 0.18),
                                    Color(red: 0.04, green: 0.02, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
            if isNostalgiaStyle {
                GeometryReader { g in
                    RadialGradient(colors: [ProPalette.gold.opacity(0.07), .clear],
                                   center: UnitPoint(x: 0.5, y: -0.05),
                                   startRadius: 0, endRadius: g.size.width * 1.05)
                }
            }
        }
    }

    /// The Pro card's single two-tone (gold → purple) edge, traced just inside the
    /// preview's rounded clip (corner 14) so it aligns with the card outline.
    private var proEdge: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .inset(by: 1)
            .stroke(LinearGradient(colors: [ProPalette.gold.opacity(0.40),
                                            edgePurple.opacity(0.40)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            .allowsHitTesting(false)
    }

    private func logo(_ k: CGFloat) -> some View {
        Group {
            if let icon = UIImage(named: "SharingIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 12 * k, style: .continuous))
            }
        }
    }
}
