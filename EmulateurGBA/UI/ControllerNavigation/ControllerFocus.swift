//
//  ControllerFocus.swift
//  EmulateurGBA
//
//  How a SwiftUI control joins controller navigation (see
//  `ControllerNavigator`). Three entry points, all declared where the control
//  is, so what A does is always what the control's own tap does:
//
//  - `FocusableButton { … } label: { … }`: a `Button` that the controller can
//    also press. The drop-in for the app's buttons; its action runs for both.
//  - `.controllerFocusable(action:)`: any other view (a row that pushes a page
//    through `navigationDestination`, a tap-gesture card), or a control whose
//    left/right changes a value (`onMove`).
//  - `.controllerToggle($isOn)`: a Toggle; A flips it.
//  - `.controllerBack { dismiss() }`: what B does on this page (pop it, close
//    the sheet). The front-most page's declaration wins.
//

import SwiftUI
import UIKit

/// The ring's outline for a control.
enum FocusShape: Equatable {
    /// A rounded rectangle of this corner radius, around the control.
    case rounded(CGFloat)
    /// Fully round ends: a pill, or a circle for a square control.
    case capsule
    /// The whole List row the control sits in (a Settings row), with the
    /// grouped list's corner radius.
    case cell
}

/// What a probe tells the navigator about its control. Rebuilt on every
/// SwiftUI update, so the closures always see the control's current state.
struct FocusConfig {
    var shape: FocusShape = .rounded(12)
    /// Where a screen's highlight starts (Play on a game's page, the rack).
    var isDefault = false
    var isEnabled = true
    /// The control sits on a light surface: the ring takes the accent there.
    var lightSurface = false
    var action: (() -> Void)?
    /// A direction the control consumes itself (true) before the navigator
    /// moves the highlight (false).
    var onMove: ((ControllerNavigator.Direction) -> Bool)?
    /// Set on a page's back declaration instead of a control's.
    var back: (() -> Void)?
    /// The panel this control belongs to (`controllerModalGroup`), nil for the
    /// page itself.
    var group: String?
    /// Set on a panel's marker instead of a control's: while the marker is
    /// reachable, only the controls of this group are.
    var modalGroup: String?
}

private struct ControllerFocusGroupKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The panel the views below belong to (see `controllerModalGroup`).
    var controllerFocusGroup: String? {
        get { self[ControllerFocusGroupKey.self] }
        set { self[ControllerFocusGroupKey.self] = newValue }
    }
}

/// The invisible UIKit view a navigable control carries. It registers with
/// the navigator while it is in a window and is measured where it stands.
final class FocusProbeView: UIView {
    var config = FocusConfig()
    /// Order of registration, the newest back declaration winning.
    var registrationOrder = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            ControllerNavigator.shared.register(self)
        } else {
            ControllerNavigator.shared.unregister(self)
        }
    }
}

private struct FocusProbe: UIViewRepresentable {
    let config: FocusConfig

    func makeUIView(context: Context) -> FocusProbeView {
        let view = FocusProbeView()
        view.config = config
        return view
    }

    func updateUIView(_ view: FocusProbeView, context: Context) {
        view.config = config
    }
}

private struct ControllerFocusModifier: ViewModifier {
    var shape: FocusShape
    var isDefault: Bool
    var action: (() -> Void)?
    var onMove: ((ControllerNavigator.Direction) -> Bool)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controllerFocusGroup) private var group

    func body(content: Content) -> some View {
        content.background(
            FocusProbe(config: FocusConfig(shape: shape,
                                           isDefault: isDefault,
                                           isEnabled: isEnabled,
                                           lightSurface: colorScheme == .light,
                                           action: action,
                                           onMove: onMove,
                                           group: group))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

private struct ControllerBackModifier: ViewModifier {
    let back: () -> Void
    @Environment(\.controllerFocusGroup) private var group

    func body(content: Content) -> some View {
        content.background(
            FocusProbe(config: FocusConfig(back: back, group: group))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

private struct ControllerModalGroupModifier: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content
            .environment(\.controllerFocusGroup, id)
            .background(
                FocusProbe(config: FocusConfig(modalGroup: id))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
    }
}

extension View {
    /// Make this view reachable with a controller; A runs `action` (pass the
    /// closure the view's own tap runs).
    func controllerFocusable(shape: FocusShape = .rounded(12),
                             isDefault: Bool = false,
                             onMove: ((ControllerNavigator.Direction) -> Bool)? = nil,
                             action: (() -> Void)?) -> some View {
        modifier(ControllerFocusModifier(shape: shape, isDefault: isDefault,
                                         action: action, onMove: onMove))
    }

    /// A Toggle a controller can flip with A.
    func controllerToggle(_ isOn: Binding<Bool>, shape: FocusShape = .cell) -> some View {
        controllerFocusable(shape: shape) { isOn.wrappedValue.toggle() }
    }

    /// What B does while this page is the front-most one.
    func controllerBack(_ back: @escaping () -> Void) -> some View {
        modifier(ControllerBackModifier(back: back))
    }

    /// A panel drawn over its page on the same screen (the library's sort and
    /// look panels, the play menu): while it is up, only its own controls are
    /// reachable. Put its closing on B with `controllerBack` inside it.
    func controllerModalGroup(_ id: String) -> some View {
        modifier(ControllerModalGroupModifier(id: id))
    }
}

/// A `Button` a controller can press too: the same action runs for a tap and
/// for A. Styles, labels and modifiers apply to it exactly as to a `Button`.
///
/// The label is built in `init`, as `Button` builds its own, so the label
/// closure does not escape: any closure a `Button` accepts works here, a
/// helper's own non-escaping `@ViewBuilder` parameter included (the first
/// version stored the closure and broke on exactly that, 2026-09-27).
struct FocusableButton<Label: View>: View {
    var role: ButtonRole?
    var shape: FocusShape
    var isDefault: Bool
    let action: () -> Void
    let label: Label

    init(role: ButtonRole? = nil,
         shape: FocusShape = .rounded(12),
         isDefault: Bool = false,
         action: @escaping () -> Void,
         @ViewBuilder label: () -> Label) {
        self.role = role
        self.shape = shape
        self.isDefault = isDefault
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(role: role, action: action) { label }
            .controllerFocusable(shape: shape, isDefault: isDefault, action: action)
    }
}

extension FocusableButton where Label == Text {
    /// The title form, like `Button("Title") { … }`.
    init(_ title: String, role: ButtonRole? = nil, shape: FocusShape = .rounded(12),
         isDefault: Bool = false, action: @escaping () -> Void) {
        self.init(role: role, shape: shape, isDefault: isDefault, action: action) { Text(title) }
    }
}
