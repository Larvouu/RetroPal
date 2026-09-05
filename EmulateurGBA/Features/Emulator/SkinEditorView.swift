//
//  SkinEditorView.swift
//  EmulateurGBA
//
//  The full-screen editor for a CUSTOM skin (opened from the Skin picker's "Create" button, or
//  from a custom card's context menu to edit). The console renders full-screen behind the editor,
//  exactly as in game, and recolours LIVE as the user edits. A floating panel (hideable, shown by
//  default) carries one row per colour slot — a swatch that opens the system colour palette, plus a
//  "#" hex field — and the mandatory skin name + the Create / Save button.
//
//  GB/GBC only for now (the picker only offers Create there). See SkinPalette for the slot mapping.
//

import SwiftUI
import UIKit

struct SkinEditorView: View {
    let system: PresetSystem
    /// The real device safe-area insets, so the preview matches the in-game console exactly.
    let deviceInsets: UIEdgeInsets
    let gameImage: UIImage?
    /// nil = create a new skin; non-nil = edit this existing one.
    let editing: CustomSkin?
    /// Called after a successful save so the picker can refresh its list.
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var palette: SkinPalette
    @State private var name: String
    @State private var panelHidden = false
    /// The orientation mask in force before the editor opened (the game's lock), restored on exit.
    @State private var savedMask: UIInterfaceOrientationMask = .allButUpsideDown

    init(system: PresetSystem, deviceInsets: UIEdgeInsets,
         gameImage: UIImage?, editing: CustomSkin?, onSaved: @escaping () -> Void) {
        self.system = system
        self.deviceInsets = deviceInsets
        self.gameImage = gameImage
        self.editing = editing
        self.onSaved = onSaved
        _palette = State(initialValue: editing?.palette ?? .nostalgiaSeed(for: system))
        _name = State(initialValue: editing?.name ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty }

    var body: some View {
        // Portrait-only: the landscape editor reads poorly and the rotation is slow, so the page is
        // pinned portrait (the in-game landscape console still wears whatever colours are chosen).
        ZStack(alignment: .bottom) {
            // Live full-screen console preview (Nostalgia base + the live custom palette).
            SkinPreviewRepresentable(system: system, isLandscape: false,
                                     safeInsets: deviceInsets, gameImage: gameImage,
                                     customPalette: palette)
                .ignoresSafeArea()

            // The editing panel (drawn under the floating controls so they stay tappable over it).
            if !panelHidden {
                panel
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Floating top controls: close (left) + show/hide panel (right). Respect the safe area.
            VStack {
                HStack {
                    floatingButton(system: "xmark") { dismiss() }
                    Spacer()
                    floatingButton(system: panelHidden ? "eye" : "eye.slash") {
                        withAnimation(.easeInOut(duration: 0.2)) { panelHidden.toggle() }
                    }
                }
                Spacer()
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .onAppear { savedMask = AppOrientationLock.mask; setOrientation(.portrait) }
        .onDisappear { setOrientation(savedMask) }
    }

    /// Pin (or release) the device orientation, mirroring EmulatorViewController.applyOrientation:
    /// the AppDelegate reads `AppOrientationLock.mask`, and requestGeometryUpdate snaps the device.
    private func setOrientation(_ mask: UIInterfaceOrientationMask) {
        AppOrientationLock.mask = mask
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    // MARK: - Panel

    /// Compact card: the colour slots scroll inside a bounded area while the name + Create stay
    /// pinned, so the panel hugs the bottom ~⅓ shorter than the full list.
    private var panel: some View {
        panelCard.frame(maxWidth: .infinity)
    }

    private var panelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editing == nil
                 ? NSLocalizedString("skin.editor.title.create", comment: "")
                 : NSLocalizedString("skin.editor.title.edit", comment: ""))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)

            ScrollView {
                VStack(spacing: 8) { slotRows }
                    .padding(.trailing, 2)
            }
            .frame(maxHeight: 168)

            Divider().overlay(Color.white.opacity(0.15))

            TextField(NSLocalizedString("skin.editor.namePlaceholder", comment: ""), text: $name)
                .textInputAutocapitalization(.words)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // Cap the length so a card label stays on one readable line.
                .onChange(of: name) { newValue in
                    if newValue.count > CustomSkin.maxNameLength {
                        name = String(newValue.prefix(CustomSkin.maxNameLength))
                    }
                }

            saveButton
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    // MARK: - Per-console colour-slot rows

    private var slotRows: some View {
        ForEach(slots, id: \.0) { key, hex in
            SkinColorRow(title: NSLocalizedString(key, comment: "Custom-skin colour slot"), hex: hex)
        }
    }

    /// The ordered (localized-key, value-binding) slots for the current console.
    private var slots: [(String, Binding<UInt32>)] {
        switch system {
        case .snes:
            return [("skin.editor.body", snesBinding(\.bodyHex)),
                    ("skin.editor.surround", snesBinding(\.surroundHex)),
                    ("skin.editor.dpad", snesBinding(\.padHex)),
                    ("skin.editor.faceA", snesBinding(\.faceAHex)),
                    ("skin.editor.faceB", snesBinding(\.faceBHex)),
                    ("skin.editor.faceX", snesBinding(\.faceXHex)),
                    ("skin.editor.faceY", snesBinding(\.faceYHex))]
        // Four slots, and every label already exists: this console's A and B are ONE colour, so
        // it needs no per-letter keys the way the Super Nintendo did. `dpad` covers the cross and
        // the pills, which really are one near-black on the real pad.
        case .nes:
            return [("skin.editor.body", nesBinding(\.bodyHex)),
                    ("skin.editor.surround", nesBinding(\.surroundHex)),
                    ("skin.editor.dpad", nesBinding(\.padHex)),
                    ("skin.editor.abButtons", nesBinding(\.faceHex))]
        // FIVE slots since 2026-08-27, and the list below is the authority: an
        // older version of this note said three and outlived the change by a
        // commit. `dpad` still recolours most of this pad at once, which is the
        // hardware's own doing rather than a shortcut: the cross, the sticks,
        // all four shoulders, ANALOG, SELECT and START are one plastic on the
        // real machine. What the two newer slots add is the plastic BEHIND the
        // four faces and the INK printed on the pad, which are the two things
        // that were never that plastic.
        //
        // `face` is in the palette and is still not offered, for the original
        // reason: it holds the same value as `pad` and the editor writes it
        // from `pad`, so a skin cannot drift the two apart into a pad this
        // console never had.
        case .ps1:
            // Five, and no more. The four SYMBOLS are deliberately absent and
            // must stay absent: square, cross, circle and triangle are how a
            // player identifies a button. Everything else on this pad, the
            // seats, the plateaus, the engraved catches, DERIVES from these
            // five rather than adding a swatch of its own.
            return [("skin.editor.body", ps1Binding(\.bodyHex)),
                    ("skin.editor.surround", ps1Binding(\.surroundHex)),
                    ("skin.editor.dpad", ps1Binding(\.padHex)),
                    ("skin.editor.faceButtons", ps1Binding(\.diamondHex)),
                    ("skin.editor.printedText", ps1Binding(\.printHex))]
        case .gbc:
            return [("skin.editor.body", gbcBinding(\.bodyHex)),
                    ("skin.editor.surround", gbcBinding(\.surroundHex)),
                    ("skin.editor.dpad", gbcBinding(\.dpadHex)),
                    ("skin.editor.abButtons", gbcBinding(\.abButtonsHex)),
                    ("skin.editor.abLetters", gbcBinding(\.abLettersHex)),
                    ("skin.editor.smallButtons", gbcBinding(\.smallButtonsHex)),
                    ("skin.editor.menuIcons", gbcBinding(\.menuIconsHex)),
                    ("skin.editor.labels", gbcBinding(\.labelsHex)),
                    ("skin.editor.stripe", gbcBinding(\.stripeHex)),
                    ("skin.editor.printedText", gbcBinding(\.printedTextHex)),
                    ("skin.editor.led", gbcBinding(\.ledHex))]
        case .gba:
            return [("skin.editor.body", gbaBinding(\.bodyHex)),
                    ("skin.editor.surround", gbaBinding(\.surroundHex)),
                    ("skin.editor.buttons", gbaBinding(\.buttonsHex)),
                    ("skin.editor.letters", gbaBinding(\.lettersHex)),
                    ("skin.editor.menuButtons", gbaBinding(\.menuButtonsHex)),
                    ("skin.editor.menuIcons", gbaBinding(\.menuIconsHex)),
                    ("skin.editor.led", gbaBinding(\.ledHex))]
        case .nds:
            return [("skin.editor.body", ndsBinding(\.bodyHex)),
                    ("skin.editor.buttons", ndsBinding(\.buttonsHex)),
                    ("skin.editor.letters", ndsBinding(\.lettersHex)),
                    ("skin.editor.menuIcons", ndsBinding(\.iconsHex)),
                    ("skin.editor.led", ndsBinding(\.ledHex))]
        }
    }

    // One Binding<UInt32> per slot, reading/writing the matching enum case. The console always
    // matches `system` (the editor seeds the palette for that console), so the fallbacks are inert.
    private func gbcBinding(_ kp: WritableKeyPath<GBCSkinPalette, UInt32>) -> Binding<UInt32> {
        Binding(get: { if case .gbc(let p) = palette { return p[keyPath: kp] }; return 0 },
                set: { v in if case .gbc(var p) = palette { p[keyPath: kp] = v; palette = .gbc(p) } })
    }
    private func gbaBinding(_ kp: WritableKeyPath<GBASkinPalette, UInt32>) -> Binding<UInt32> {
        Binding(get: { if case .gba(let p) = palette { return p[keyPath: kp] }; return 0 },
                set: { v in if case .gba(var p) = palette { p[keyPath: kp] = v; palette = .gba(p) } })
    }
    private func ndsBinding(_ kp: WritableKeyPath<NDSSkinPalette, UInt32>) -> Binding<UInt32> {
        Binding(get: { if case .nds(let p) = palette { return p[keyPath: kp] }; return 0 },
                set: { v in if case .nds(var p) = palette { p[keyPath: kp] = v; palette = .nds(p) } })
    }

    private func snesBinding(_ kp: WritableKeyPath<SNESSkinPalette, UInt32>) -> Binding<UInt32> {
        Binding(get: { if case .snes(let p) = palette { return p[keyPath: kp] }; return 0 },
                set: { v in if case .snes(var p) = palette { p[keyPath: kp] = v; palette = .snes(p) } })
    }

    private func nesBinding(_ kp: WritableKeyPath<NESSkinPalette, UInt32>) -> Binding<UInt32> {
        Binding(get: { if case .nes(let p) = palette { return p[keyPath: kp] }; return 0 },
                set: { v in if case .nes(var p) = palette { p[keyPath: kp] = v; palette = .nes(p) } })
    }

    private func ps1Binding(_ kp: WritableKeyPath<PS1SkinPalette, UInt32>) -> Binding<UInt32> {
        Binding(get: { if case .ps1(let p) = palette { return p[keyPath: kp] }; return 0 },
                set: { v in
                    if case .ps1(var p) = palette {
                        p[keyPath: kp] = v
                        // `face` follows `pad`, always. They are one plastic on
                        // this pad, and letting a stored skin drift them apart
                        // would put a console on screen that never existed.
                        if kp == \PS1SkinPalette.padHex { p.faceHex = v }
                        palette = .ps1(p)
                    }
                })
    }

    private var saveButton: some View {
        Button { save() } label: {
            Text(editing == nil
                 ? NSLocalizedString("skin.editor.create", comment: "")
                 : NSLocalizedString("skin.editor.save", comment: ""))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(canSave
                            ? AnyShapeStyle(LinearGradient(colors: [.purple, .blue],
                                                           startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color.white.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!canSave)
    }

    private func floatingButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.headline).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func save() {
        guard canSave else { return }
        if var existing = editing {
            existing.name = trimmedName
            existing.palette = palette
            CustomSkinStore.shared.update(existing, system: system)
            Analytics.signal("custom_skin", ["action": "edited", "system": "\(system)"])
        } else {
            let skin = CustomSkin(name: trimmedName, system: system, palette: palette)
            CustomSkinStore.shared.add(skin, system: system)
            Analytics.signal("custom_skin", ["action": "created", "system": "\(system)"])
        }
        Analytics.signal("pro_feature_used", ["feature": "custom_skin"])
        onSaved()
        dismiss()
    }
}

// MARK: - One colour slot row

/// A swatch (opens the system colour palette) + a "#" hex field. Both edit the same 0xRRGGBB value
/// live: picking from the palette updates the hex text, and typing a valid 6-digit hex recolours.
private struct SkinColorRow: View {
    let title: String
    @Binding var hex: UInt32
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            ColorPicker(selection: Binding(get: { Color(rpHex: hex) },
                                           set: { hex = $0.rpHex }),
                        supportsOpacity: false) { EmptyView() }
                .labelsHidden()
                .frame(width: 28)

            Text(title).font(.subheadline).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 6)

            HStack(spacing: 1) {
                Text("#").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                TextField("", text: $text)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .keyboardType(.asciiCapable)
                    .multilineTextAlignment(.leading)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.white)
                    .frame(width: 62)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .onAppear { text = Self.format(hex) }
        // Palette picker changed the value → reflect it in the field (unless the user is typing).
        .onChange(of: hex) { newHex in if !focused { text = Self.format(newHex) } }
        // Typing: sanitize to <=6 hex chars; apply when a full 6-digit colour is entered.
        .onChange(of: text) { newText in
            let clean = String(newText.uppercased().filter(\.isHexDigit).prefix(6))
            if clean != newText { text = clean }
            if clean.count == 6, let v = UInt32(clean, radix: 16), v != hex { hex = v }
        }
        // Leaving the field snaps a partial entry back to the last valid colour.
        .onChange(of: focused) { isFocused in if !isFocused { text = Self.format(hex) } }
    }

    private static func format(_ hex: UInt32) -> String { String(format: "%06X", hex) }
}

// MARK: - SwiftUI helpers

extension Color {
    /// 0xRRGGBB → Color (via UIColor, sRGB).
    init(rpHex: UInt32) { self = Color(UIColor(rpHex: rpHex)) }

    /// This colour as 0xRRGGBB, clamped, alpha dropped.
    var rpHex: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return (c(r) << 16) | (c(g) << 8) | c(b)
    }
}

/// The gentle gold → purple "Pro temptation" treatment (faint fill + hairline gradient border +
/// soft purple glow, NO lock icon), mirroring the UIKit `GradientBackgroundView` used on the
/// non-Pro cheat button. Reused by the Skin picker's "Create a skin" button.
struct ProTemptBackground: ViewModifier {
    var cornerRadius: CGFloat = 12
    func body(content: Content) -> some View {
        let gold = Color(red: 1.0, green: 0.84, blue: 0.35)
        let purple = Color(red: 0.45, green: 0.2, blue: 0.85)
        content
            .background(LinearGradient(colors: [gold.opacity(0.12), purple.opacity(0.10)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(LinearGradient(colors: [gold.opacity(0.85), purple.opacity(0.85)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1.2))
            .shadow(color: purple.opacity(0.3), radius: 6)
    }
}

extension View {
    func proTemptBackground(cornerRadius: CGFloat = 12) -> some View {
        modifier(ProTemptBackground(cornerRadius: cornerRadius))
    }
}
