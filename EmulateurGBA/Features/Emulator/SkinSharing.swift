//
//  SkinSharing.swift
//  EmulateurGBA
//
//  Share + import custom skins as `.retropalskin` files (versioned JSON, UTI com.retropal.skin).
//  Console-aware: the file carries the skin's `system` (gbc covers GB + GBC, gba, nds), so an
//  imported skin lands in the RIGHT per-console library and shows up when that console is played.
//  One device shares via the system sheet (AirDrop / Messages / Files…); the other opens the file
//  and Retro Pal imports it (validate → enforce the 6-per-console cap → add with a fresh id).
//

import UIKit
import UniformTypeIdentifiers

enum SkinSharing {
    static let fileExtension = "retropalskin"
    static let uti = "com.retropal.skin"
    /// The content type for the in-app file pickers (skin sheet's Import + the library picker).
    static let contentType: UTType =
        UTType(uti) ?? UTType(filenameExtension: fileExtension) ?? .json

    /// The result of importing a file, so callers can both message the user and refresh UI.
    enum ImportOutcome {
        case added(name: String, system: PresetSystem)
        case duplicate(name: String, system: PresetSystem)
        case full(system: PresetSystem)
        case failed
    }

    /// Versioned wrapper so the on-disk format can evolve without breaking older files.
    private struct Document: Codable {
        var format: String
        var version: Int
        var skin: CustomSkin
    }
    private static let formatTag = "retropalskin"
    private static let currentVersion = 1

    static func isSkinFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    // MARK: - Export

    /// Writes `<name>.retropalskin` to a temp file, or nil on failure.
    static func fileURL(for skin: CustomSkin) -> URL? {
        let doc = Document(format: formatTag, version: currentVersion, skin: skin)
        guard let data = try? JSONEncoder().encode(doc) else { return nil }
        let cleaned = skin.name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "skin" : cleaned
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base).\(fileExtension)")
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// Presents the system share sheet for a skin from the top-most view controller. Deferred to the
    /// next runloop so it doesn't race the context-menu dismissal that triggered it.
    static func share(_ skin: CustomSkin) {
        guard let url = fileURL(for: skin) else { return }
        DispatchQueue.main.async {
            guard let top = topViewController() else { return }
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            // iPhone-only, but set an anchor so it never crashes if ever run on iPad.
            vc.popoverPresentationController?.sourceView = top.view
            vc.popoverPresentationController?.sourceRect =
                CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            top.present(vc, animated: true)
        }
    }

    // MARK: - Import

    /// Imports a `.retropalskin` file, returning the outcome (no UI). Strict: the file must decode as
    /// the exact `{format, version, skin}` grammar, carry a known format + supported version, a valid
    /// console, a non-empty name, and in-range colours — anything else is `.failed`. A skin whose
    /// content (name + palette) already exists for that console is `.duplicate` (not re-added). The
    /// per-console cap blocks with `.full`. A fresh id is assigned so a genuine add never collides.
    static func importSkin(from url: URL) -> ImportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data),
              doc.format == formatTag,
              (1...currentVersion).contains(doc.version),
              let system = PresetSystem(rawValue: doc.skin.system),
              system.supportsCustomSkins,
              doc.skin.palette.system == system,   // the palette's console must match the declared one
              doc.skin.palette.isWithinHexRange else {
            return .failed
        }
        // Names are capped at creation; trim + clamp an imported one so it always fits.
        let name = String(doc.skin.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(CustomSkin.maxNameLength))
        guard !name.isEmpty else { return .failed }

        // Already imported? Same console + same name + same colours = the same skin (id is ignored,
        // since each import gets a fresh one). Don't add a second copy.
        let existing = CustomSkinStore.shared.skins(for: system)
        if existing.contains(where: { $0.name == name && $0.palette == doc.skin.palette }) {
            return .duplicate(name: name, system: system)
        }
        guard CustomSkinStore.shared.canAdd(system: system) else { return .full(system: system) }

        CustomSkinStore.shared.add(CustomSkin(name: name, system: system, palette: doc.skin.palette),
                                   system: system)
        Analytics.signal("custom_skin", ["action": "imported", "system": "\(system)"])
        return .added(name: name, system: system)
    }

    /// Shows the alert for an import outcome (top-most VC). Pair with `importSkin`.
    /// `onDismiss` fires when the user taps OK — the picker uses it to chain the
    /// custom-skins Pro sheet after a successful import (free users).
    static func present(_ outcome: ImportOutcome, onDismiss: (() -> Void)? = nil) {
        switch outcome {
        case .added(let name, let system):
            presentAlert("skin.import.success.title", "skin.import.success.message",
                         args: [name, system.shareLabel], onDismiss: onDismiss)
        case .duplicate(let name, let system):
            presentAlert("skin.import.duplicate.title", "skin.import.duplicate.message",
                         args: [name, system.shareLabel], onDismiss: onDismiss)
        case .full(let system):
            presentAlert("skin.import.full.title", "skin.import.full.message",
                         args: [system.shareLabel], onDismiss: onDismiss)
        case .failed:
            presentAlert("skin.import.failed.title", "skin.import.failed.message", onDismiss: onDismiss)
        }
    }

    /// Import + alert in one call (used by `.onOpenURL`, where no in-app UI needs refreshing).
    static func handleIncoming(_ url: URL) { present(importSkin(from: url)) }

    // MARK: - Helpers

    private static func presentAlert(_ titleKey: String, _ messageKey: String, args: [CVarArg] = [],
                                     onDismiss: (() -> Void)? = nil) {
        let title = NSLocalizedString(titleKey, comment: "")
        let format = NSLocalizedString(messageKey, comment: "")
        let message = args.isEmpty ? format : String(format: format, arguments: args)
        DispatchQueue.main.async {
            guard let top = topViewController() else { onDismiss?(); return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("common.ok", comment: ""),
                                          style: .default) { _ in onDismiss?() })
            top.present(alert, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

extension PresetSystem {
    /// A short, fixed (non-localized) console label for share/import messages. GB and GBC share one
    /// skin format, so there are 4 consoles but 3 skin types.
    var shareLabel: String {
        switch self {
        case .gba: return "GBA"
        case .gbc: return "GB / GBC"
        case .nds: return "Nintendo DS"
        case .snes: return "Super Nintendo"
        case .nes: return "NES"
        case .ps1: return "PlayStation"
        }
    }

    /// Whether custom skins can be created / rendered / imported for this console. Five skin
    /// formats across six consoles (GB and GBC share one), and since the NES dress landed every
    /// console has one. Kept as a gate rather than deleted: a console added later starts without
    /// a dress, and this is where it says it cannot store a skin it could not render.
    /// Every console has a dress now, so every console can store a skin.
    var supportsCustomSkins: Bool { true }
}
