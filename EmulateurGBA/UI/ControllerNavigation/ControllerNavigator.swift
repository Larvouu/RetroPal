//
//  ControllerNavigator.swift
//  EmulateurGBA
//
//  Moving around the app with a controller (1.3.3): player 1's D-pad or left
//  stick moves a highlight from one control to the next, A does what a tap
//  does, B goes back, L and R switch tabs. Everything a player does daily is
//  reachable this way (the library, a game's page, RetroAchievements, the
//  simple rows of Settings, the pause menu); the editors (layout, skins,
//  remapping) and text entry stay touch-only by decision (2026-09-27).
//
//  WHY OUR OWN ENGINE. iOS offers an app no focus system on the iPhone (UIKit's
//  focus engine is iPad, Mac and TV only) and the app runs from iOS 16, so the
//  navigation is built here, on public API only:
//
//  - Every navigable control carries a `FocusProbeView`, an invisible UIKit
//    view laid over it (`controllerFocusable` in SwiftUI; the pause menu's
//    buttons are found by walking its view tree). A probe registers itself
//    while it is in a window. Its frame is MEASURED when needed, never cached,
//    so scrolling, rotation and animation cost nothing to follow.
//  - A control is reachable when its probe is visible and belongs to the
//    front-most screen: the window's top presented view controller. A sheet
//    therefore hides the page under it, a pushed page is simply no longer in
//    the window, and the game's cover hides the library, with no bookkeeping.
//  - A direction picks the nearest control that way (the gap along the
//    direction, plus twice the sideways offset). Nothing that way on screen,
//    the scroll view around the highlight scrolls a step and the move is tried
//    again, which is how lazy lists reveal their next rows.
//  - A does what a tap does by calling the SAME closure the control's own tap
//    calls (declared at the call site), or `sendActions` for a UIKit button.
//    No touch is ever synthesized.
//
//  The highlight is one ring drawn above everything (`ControllerFocusRing`):
//  white with a glow in the look's accent on a dark surface, the accent itself
//  on a light one (the Classic list in light mode), decided 2026-09-27.
//  It shows at player 1's first press and hides at the first touch of the
//  screen, the way a console's own menus behave.
//

import GameController
import UIKit
// Lets `TouchSpyRecognizer` set its own state.
import UIKit.UIGestureRecognizerSubclass

final class ControllerNavigator {

    static let shared = ControllerNavigator()

    enum Direction: CaseIterable {
        case up, down, left, right
    }

    /// Player 1's navigation input, from `ControllerManager`.
    enum Input {
        case direction(Direction, pressed: Bool)
        case activate
        case back
        /// L (-1) or R (+1).
        case tab(Int)
    }

    // MARK: - State the app sets

    /// True while a game's screen is up. B then belongs to that screen (it
    /// resumes the game), and L/R do nothing.
    var gameScreenActive = false {
        didSet { if gameScreenActive != oldValue { refreshRingVisibility() } }
    }
    /// True while the game itself is being played (its screen is up, the
    /// pause menu closed and nothing presented over it): every press is the
    /// game's then, and the navigator stays out of the way.
    var gameOwnsInput = false {
        didSet {
            guard gameOwnsInput != oldValue else { return }
            if gameOwnsInput { stopRepeat() }
            refreshRingVisibility()
        }
    }
    /// Whether the game has the controller right now: it owns the input, and
    /// no app confirmation stands over it. The app's own dialog over a game
    /// being played (the Nintendo 64's lost picture) is answered like any
    /// other screen: the game is paused under it.
    private var gameHoldsInput: Bool {
        gameOwnsInput && !(topViewController is ControllerConfirmDialog)
    }

    /// Switches the app's tab, -1 (the one on the left) or +1 (on the right),
    /// and says whether there was one to switch to (installed by the app shell).
    var onSwitchTab: ((Int) -> Bool)?

    // MARK: - Registered probes

    private let probes = NSHashTable<FocusProbeView>.weakObjects()
    private let backHandlers = NSHashTable<FocusProbeView>.weakObjects()
    private let modalMarkers = NSHashTable<FocusProbeView>.weakObjects()
    /// UIKit subtrees whose buttons are navigable without a probe each (the
    /// pause menu), scanned live so rebuilt rows need nothing.
    private let uikitRoots = NSHashTable<UIView>.weakObjects()
    /// The button each UIKit root starts on (the pause menu's Resume).
    private let uikitDefaults = NSMapTable<UIView, UIView>.weakToWeakObjects()
    private var registrationCounter = 0

    /// The focused control, and the ones it replaced, most recent last, so
    /// coming back from a page puts the highlight back where it was.
    private weak var focused: UIView?
    private var history: [WeakView] = []

    /// Whether the highlight is showing (from player 1's first press to the
    /// next touch of the screen).
    private(set) var isShowing = false

    private let ring = ControllerFocusRing()
    private var repeatTimer: Timer?
    private var heldDirection: Direction?
    private var touchSpyInstalled = false

    private init() {}

    func register(_ probe: FocusProbeView) {
        registrationCounter += 1
        probe.registrationOrder = registrationCounter
        if probe.config.modalGroup != nil {
            modalMarkers.add(probe)
        } else if probe.config.back != nil {
            backHandlers.add(probe)
        } else {
            probes.add(probe)
        }
        // A control coming back into the window that was focused before it
        // left (the row a page was pushed from) takes the highlight back.
        if isShowing, focusIsLost, history.last?.view === probe {
            setFocus(probe, animated: false, reveal: false)
        }
    }

    func unregister(_ probe: FocusProbeView) {
        probes.remove(probe)
        backHandlers.remove(probe)
        modalMarkers.remove(probe)
        if focused === probe {
            history.append(WeakView(view: probe))
            if history.count > 12 { history.removeFirst() }
            focused = nil
        }
    }

    /// Make every enabled button under `root` navigable (UIKit screens),
    /// starting on `preferred` when the highlight arrives there.
    func registerUIKitRoot(_ root: UIView, preferred: UIView? = nil) {
        uikitRoots.add(root)
        if let preferred { uikitDefaults.setObject(preferred, forKey: root) }
    }

    // MARK: - Input

    func handle(_ input: Input) {
        // A system alert the app built with navigable actions answers first,
        // even over a game. It is only met when no controller was in hand as
        // it opened (with one, the app shows `ControllerConfirmDialog`, which
        // the ring reaches like any screen); the bold action it can move is
        // the best a system alert allows.
        if let alert = topAlert(), let actions = alert.navigableActions, !actions.isEmpty {
            handleAlert(alert, actions: actions, input: input)
            return
        }
        if gameHoldsInput {
            stopRepeat()
            // A card over the game being played (an achievement unlocked
            // mid-game, a screenshot) still closes on B: it declares its own
            // back, and the bare game declares none, so B there stays the
            // game's alone.
            if case .back = input { performBack() }
            return
        }
        installTouchSpyIfNeeded()
        switch input {
        case .direction(let direction, let pressed):
            if pressed {
                press(direction)
            } else if heldDirection == direction {
                stopRepeat()
            }
        case .activate:
            // Like a direction, the first press only shows the highlight: a
            // player who has not seen where it is must not trigger anything.
            let wasShowing = isShowing
            guard ensureShowing(), wasShowing else { return }
            activateFocused()
        case .back:
            // The front-most page's own back. On a game's screen B is first
            // the screen's (it closes what the screen presented, or resumes
            // the game from the pause menu, which declare no back of their
            // own); a card declared over it closes on B too (asked 2026-09-27).
            performBack()
        case .tab(let delta):
            _ = switchTab(delta)
        }
    }

    // MARK: - Moving

    private func press(_ direction: Direction) {
        stopRepeat()
        heldDirection = direction
        // The first press only shows where the highlight is. A screen with
        // nothing to reach (a page of text) scrolls instead.
        if !isShowing {
            if !ensureShowing() { scrollScreen(direction) }
        } else {
            move(direction, allowScroll: true)
        }
        // Holding repeats, after a pause, the way a console's menus do.
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
            guard let self, self.heldDirection == direction else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { [weak self] _ in
                guard let self, self.heldDirection == direction, !self.gameHoldsInput else {
                    self?.stopRepeat()
                    return
                }
                self.move(direction, allowScroll: true)
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        heldDirection = nil
    }

    private func move(_ direction: Direction, allowScroll: Bool) {
        guard ensureShowing(), let current = focused else {
            if allowScroll { scrollScreen(direction) }
            return
        }
        // A control that moves through its own content (the library's rack,
        // a choice of values) takes the direction first.
        if let probe = current as? FocusProbeView, let onMove = probe.config.onMove, onMove(direction) {
            return
        }
        let candidates = eligibleTargets().filter { $0 !== current }
        let from = frameInWindow(current)
        if let next = Self.nearest(from: from, direction: direction,
                                   among: candidates.map { ($0, frameInWindow($0)) }) {
            setFocus(next, animated: true)
            return
        }
        // Nothing further that way on a tab's own page: the tab on that side
        // (asked 2026-09-27). Right from the library is Settings, left from
        // Settings is the library, in either orientation, since the tab bar
        // itself is out of the highlight's reach (and hidden on its side).
        if direction == .left || direction == .right, isOnATabsRootPage,
           switchTab(direction == .right ? 1 : -1) {
            return
        }
        // Nothing that way yet: scroll a step and look again, for the rows a
        // lazy list has not built and the text a page shows between two
        // controls. The nearest scroll view around the highlight that can go
        // that way, else the screen's main one (the highlight may sit in a bar).
        guard allowScroll else { return }
        let scrolled = enclosingScrollViews(of: current).contains { Self.scroll($0, toward: direction) }
            || primaryScrollView().map { Self.scroll($0, toward: direction) } == true
        guard scrolled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.move(direction, allowScroll: false)
        }
    }

    /// Switch the app's tab (L and R, or the edge of a tab's page). Only on a
    /// tab's own page, never over a game or a sheet. True when it switched.
    private func switchTab(_ delta: Int) -> Bool {
        guard !gameScreenActive, !isShowingPresentedScreen,
              let onSwitchTab, onSwitchTab(delta) else { return false }
        // The page changes under the highlight: find it a new place once the
        // new tab is on screen (and remember this one for the way back).
        if let focused, history.last?.view !== focused { history.append(WeakView(view: focused)) }
        focused = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refocusIfNeeded()
        }
        return true
    }

    /// The highlight is on a tab's own page: no sheet, no panel, and no page
    /// pushed over it (a pushed page declares its way back).
    private var isOnATabsRootPage: Bool {
        !gameScreenActive && !isShowingPresentedScreen && activeModalGroup == nil
            && !backHandlers.allObjects.contains { isEligible($0, requireVisible: false) }
    }

    /// Scroll the front-most screen's main scroll view a step, for a page
    /// with nothing to reach.
    private func scrollScreen(_ direction: Direction) {
        guard let scrollView = primaryScrollView() else { return }
        _ = Self.scroll(scrollView, toward: direction)
    }

    /// The nearest frame in `direction`: the gap along the direction plus
    /// twice the sideways offset, the weighting that keeps a move in its lane.
    static func nearest<T>(from: CGRect, direction: Direction, among candidates: [(T, CGRect)]) -> T? {
        var best: (T, CGFloat)?
        for (item, frame) in candidates {
            let along: CGFloat
            let across: CGFloat
            switch direction {
            case .down:
                guard frame.midY > from.midY + 1, frame.minY > from.minY + 1 else { continue }
                along = max(0, frame.minY - from.maxY)
                across = gap(from.minX...from.maxX, frame.minX...frame.maxX)
            case .up:
                guard frame.midY < from.midY - 1, frame.maxY < from.maxY - 1 else { continue }
                along = max(0, from.minY - frame.maxY)
                across = gap(from.minX...from.maxX, frame.minX...frame.maxX)
            case .right:
                guard frame.midX > from.midX + 1, frame.minX > from.minX + 1 else { continue }
                along = max(0, frame.minX - from.maxX)
                across = gap(from.minY...from.maxY, frame.minY...frame.maxY)
            case .left:
                guard frame.midX < from.midX - 1, frame.maxX < from.maxX - 1 else { continue }
                along = max(0, from.minX - frame.maxX)
                across = gap(from.minY...from.maxY, frame.minY...frame.maxY)
            }
            // A tie-break on the centres, so of two rows touching the same
            // lane the one straight ahead wins.
            let centre: CGFloat
            switch direction {
            case .up, .down: centre = abs(frame.midX - from.midX)
            case .left, .right: centre = abs(frame.midY - from.midY)
            }
            let score = along + across * 2 + centre * 0.05
            if best == nil || score < best!.1 { best = (item, score) }
        }
        return best?.0
    }

    /// The distance between two intervals, 0 when they overlap.
    private static func gap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> CGFloat {
        if a.overlaps(b) { return 0 }
        return b.lowerBound > a.upperBound ? b.lowerBound - a.upperBound : a.lowerBound - b.upperBound
    }

    // MARK: - Focus

    /// Whether there is no reachable focused control right now.
    private var focusIsLost: Bool {
        guard let focused else { return true }
        return !isReachable(focused)
    }

    /// Eligible, and in the open panel when one is open (a control of the
    /// page behind a panel is visible but not reachable).
    private func isReachable(_ view: UIView) -> Bool {
        guard isEligible(view) else { return false }
        return (view as? FocusProbeView)?.config.group == activeModalGroup
    }

    /// Show the highlight if it is not showing, on the focused control or a
    /// sensible first one. False when this screen has nothing to reach.
    @discardableResult
    private func ensureShowing() -> Bool {
        if focusIsLost { pickFocus() }
        guard let focused else {
            isShowing = false
            ring.hide()
            return false
        }
        let wasShowing = isShowing
        isShowing = true
        // Idempotent; restarts the ring after a game hid it.
        ring.start(tracking: self)
        // Arriving on a screen does not scroll it: a sheet whose Done sits
        // below its text keeps its text in view until the player moves.
        if !wasShowing { setFocus(focused, animated: false, reveal: false) }
        return true
    }

    /// The control to focus when the old one is gone: the most recent one
    /// the highlight left that is reachable again, else the screen's default.
    private func pickFocus() {
        // The control being replaced is remembered (a panel opening over it,
        // a page pushed from it), so closing the panel or popping the page
        // brings the highlight back to it.
        if let old = focused, history.last?.view !== old { history.append(WeakView(view: old)) }
        if history.count > 12 { history.removeFirst(history.count - 12) }
        history.removeAll { $0.view == nil }
        if let index = history.lastIndex(where: { $0.view.map(isReachable) == true }) {
            focused = history[index].view
            history.remove(at: index)
            return
        }
        let targets = eligibleTargets()
        let window = keyWindow
        // A control that says it is where a screen starts (Play, the rack,
        // the first game), else the first one on screen in reading order.
        let onScreen = targets.filter { view in
            guard let window else { return true }
            return frameInWindow(view).intersects(window.bounds)
        }
        let pool = onScreen.isEmpty ? targets : onScreen
        for root in uikitRoots.allObjects {
            if let preferred = uikitDefaults.object(forKey: root), pool.contains(where: { $0 === preferred }) {
                focused = preferred
                return
            }
        }
        if let preferred = pool.filter({ ($0 as? FocusProbeView)?.config.isDefault == true })
            .min(by: { readingOrder(frameInWindow($0), frameInWindow($1)) }) {
            focused = preferred
            return
        }
        focused = pool.min(by: { readingOrder(frameInWindow($0), frameInWindow($1)) })
    }

    private func readingOrder(_ a: CGRect, _ b: CGRect) -> Bool {
        let rowA = (a.minY / 12).rounded(.down)
        let rowB = (b.minY / 12).rounded(.down)
        return rowA != rowB ? rowA < rowB : a.minX < b.minX
    }

    private func setFocus(_ view: UIView, animated: Bool, reveal shouldReveal: Bool = true) {
        focused = view
        if shouldReveal { reveal(view) }
        if isShowing { ring.moveTo(view, animated: animated) }
    }

    /// Called by the ring on every frame while it shows: find the highlight a
    /// new place when its control has gone (a page pushed or closed).
    func refocusIfNeeded() {
        guard isShowing, !gameHoldsInput, focusIsLost else { return }
        pickFocus()
        if let focused {
            ring.moveTo(focused, animated: true)
        }
    }

    /// The focused control, for the ring. Nil when it cannot be reached (the
    /// ring then hides until focus is found again).
    var trackedView: UIView? {
        guard isShowing, !gameHoldsInput, let focused, isReachable(focused) else { return nil }
        return focused
    }

    /// Whether the focused control sits on a light surface (the ring then
    /// takes the accent instead of white).
    var trackedViewIsOnLightSurface: Bool {
        (focused as? FocusProbeView)?.config.lightSurface ?? false
    }

    /// The ring's shape for the focused control.
    var trackedShape: FocusShape {
        if let probe = focused as? FocusProbeView { return probe.config.shape }
        if let button = focused as? UIButton {
            let radius = button.layer.cornerRadius
            return radius > 0 ? .rounded(radius) : .rounded(min(12, button.bounds.height / 2))
        }
        return .rounded(10)
    }

    /// The view whose frame the ring outlines: the list cell around a probe
    /// that asks for it, else the control itself.
    func outlinedView(for view: UIView) -> UIView {
        if let probe = view as? FocusProbeView, probe.config.shape == .cell {
            var ancestor = probe.superview
            while let current = ancestor {
                if current is UICollectionViewCell || current is UITableViewCell { return current }
                ancestor = current.superview
            }
        }
        return view
    }

    private func refreshRingVisibility() {
        if gameOwnsInput {
            ring.hide()
        } else if isShowing, let focused, isReachable(focused) {
            ring.start(tracking: self)
            ring.moveTo(focused, animated: false)
        }
    }

    // MARK: - Acting

    private func activateFocused() {
        guard let focused else { return }
        ring.pulse()
        if let probe = focused as? FocusProbeView {
            probe.config.action?()
        } else if let button = focused as? UIButton {
            button.sendActions(for: .touchUpInside)
        }
    }

    /// B: the front-most page's own "back" (a pushed page pops, a sheet
    /// closes), declared with `controllerBack`.
    private func performBack() {
        let group = activeModalGroup
        let handlers = backHandlers.allObjects.filter {
            isEligible($0, requireVisible: false) && (group == nil || $0.config.group == group)
        }
        guard let handler = handlers.max(by: { $0.registrationOrder < $1.registrationOrder }) else { return }
        handler.config.back?()
        focused = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.refocusIfNeeded()
        }
    }

    // MARK: - Alerts

    private func topAlert() -> UIAlertController? {
        topViewController as? UIAlertController
    }

    /// An alert the app built with `addNavigableAction`: the D-pad moves the
    /// alert's preferred (bold) action along its buttons, A performs it, B
    /// takes the cancel action. Everything through public API: the ring cannot
    /// reach inside the system's alert, the bold action is the highlight.
    private func handleAlert(_ alert: UIAlertController, actions: [NavigableAlertAction], input: Input) {
        stopRepeat()
        let current = actions.firstIndex { $0.action === alert.preferredAction }
        switch input {
        case .direction(let direction, let pressed):
            guard pressed else { return }
            let step = (direction == .down || direction == .right) ? 1 : -1
            let next = current.map { ($0 + step + actions.count) % actions.count }
                ?? actions.firstIndex { $0.action.style == .cancel } ?? 0
            alert.preferredAction = actions[next].action
        case .activate:
            guard let current else {
                // First press: show which action is chosen before acting.
                alert.preferredAction = (actions.first { $0.action.style == .cancel } ?? actions[0]).action
                return
            }
            perform(actions[current], in: alert)
        case .back:
            if let cancel = actions.first(where: { $0.action.style == .cancel }) {
                perform(cancel, in: alert)
            }
        case .tab:
            break
        }
    }

    private func perform(_ entry: NavigableAlertAction, in alert: UIAlertController) {
        let handler = entry.handler
        let action = entry.action
        alert.dismiss(animated: true) { handler?(action) }
    }

    // MARK: - Reachability

    /// The key window and its front-most screen, found once per pass (the
    /// run loop turn) rather than once per control: a pass asks about every
    /// registered control, and the answer cannot change inside it.
    private var cachedScreen: (window: UIWindow?, top: UIViewController?)?

    private func currentScreen() -> (window: UIWindow?, top: UIViewController?) {
        if let cachedScreen { return cachedScreen }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let screen = (window: window, top: top)
        cachedScreen = screen
        DispatchQueue.main.async { [weak self] in self?.cachedScreen = nil }
        return screen
    }

    private var keyWindow: UIWindow? { currentScreen().window }

    private var topViewController: UIViewController? { currentScreen().top }

    private var isShowingPresentedScreen: Bool {
        guard let root = keyWindow?.rootViewController, let top = topViewController else { return false }
        return top !== root
    }

    /// The panel open over the front-most screen, if any: the most recently
    /// shown one whose marker is reachable.
    private var activeModalGroup: String? {
        modalMarkers.allObjects
            .filter { isEligible($0, requireVisible: false) }
            .max { $0.registrationOrder < $1.registrationOrder }?
            .config.modalGroup
    }

    /// Every control reachable right now.
    private func eligibleTargets() -> [UIView] {
        if let group = activeModalGroup {
            return probes.allObjects.filter { $0.config.group == group && isEligible($0) }
        }
        var result: [UIView] = probes.allObjects.filter { $0.config.group == nil && isEligible($0) }
        for root in uikitRoots.allObjects where isEligible(root, requireVisible: true, requireEnabled: false) {
            collectButtons(in: root, into: &result)
        }
        return result
    }

    private func collectButtons(in view: UIView, into result: inout [UIView]) {
        for sub in view.subviews {
            if let button = sub as? UIButton {
                if isEligible(button) { result.append(button) }
                continue
            }
            collectButtons(in: sub, into: &result)
        }
    }

    /// Reachable: in the key window, inside the front-most screen, not hidden
    /// or transparent anywhere up its chain, enabled, and either on screen or
    /// inside a scroll view that can bring it there.
    private func isEligible(_ view: UIView, requireVisible: Bool = true, requireEnabled: Bool = true) -> Bool {
        guard let window = view.window, window === keyWindow,
              let top = topViewController, view.isDescendant(of: top.view) else { return false }
        if requireEnabled {
            if let probe = view as? FocusProbeView, !probe.config.isEnabled { return false }
            if let control = view as? UIControl, !control.isEnabled { return false }
        }
        guard requireVisible else { return true }
        var ancestor: UIView? = view
        while let current = ancestor, current !== window {
            if current.isHidden || current.alpha < 0.01 { return false }
            ancestor = current.superview
        }
        let frame = frameInWindow(view)
        guard frame.width > 1, frame.height > 1 else { return false }
        return frame.intersects(window.bounds) || enclosingScrollView(of: view) != nil
    }

    func frameInWindow(_ view: UIView) -> CGRect {
        let outlined = outlinedView(for: view)
        return outlined.convert(outlined.bounds, to: nil)
    }

    private func enclosingScrollView(of view: UIView) -> UIScrollView? {
        enclosingScrollViews(of: view).first
    }

    /// Every scrolling ancestor, innermost first (a row of slots inside a
    /// page that scrolls has two).
    private func enclosingScrollViews(of view: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled { result.append(scroll) }
            ancestor = current.superview
        }
        return result
    }

    /// The front-most screen's main scroll view: the largest visible one that
    /// has more content than it shows.
    private func primaryScrollView() -> UIScrollView? {
        guard let root = topViewController?.view else { return nil }
        var best: (UIScrollView, CGFloat)?
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled, scroll.window != nil,
               scroll.contentSize.height > scroll.bounds.height + 1 || scroll.contentSize.width > scroll.bounds.width + 1 {
                let area = scroll.bounds.width * scroll.bounds.height
                if best == nil || area > best!.1 { best = (scroll, area) }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return best?.0
    }

    /// Bring `view` fully into view, through every scroll view around it,
    /// innermost first, with a margin.
    private func reveal(_ view: UIView) {
        let outlined = outlinedView(for: view)
        for scrollView in enclosingScrollViews(of: outlined) {
            let rect = outlined.convert(outlined.bounds, to: scrollView).insetBy(dx: -12, dy: -28)
            let visible = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
            if !visible.contains(rect) {
                scrollView.scrollRectToVisible(rect, animated: true)
            }
        }
    }

    /// Scroll one step toward `direction`. False when already at that end.
    private static func scroll(_ scrollView: UIScrollView, toward direction: Direction) -> Bool {
        let insets = scrollView.adjustedContentInset
        var offset = scrollView.contentOffset
        let stepY = scrollView.bounds.height * 0.6
        let stepX = scrollView.bounds.width * 0.6
        let minY = -insets.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
        let minX = -insets.left
        let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + insets.right)
        switch direction {
        case .down: offset.y = min(maxY, offset.y + stepY)
        case .up: offset.y = max(minY, offset.y - stepY)
        case .right: offset.x = min(maxX, offset.x + stepX)
        case .left: offset.x = max(minX, offset.x - stepX)
        }
        guard offset != scrollView.contentOffset else { return false }
        scrollView.setContentOffset(offset, animated: true)
        return true
    }

    // MARK: - Touch hides the highlight

    private func installTouchSpyIfNeeded() {
        guard !touchSpyInstalled, let window = keyWindow else { return }
        touchSpyInstalled = true
        let spy = TouchSpyRecognizer { [weak self] in self?.touchDidBegin() }
        window.addGestureRecognizer(spy)
    }

    private func touchDidBegin() {
        guard isShowing else { return }
        isShowing = false
        stopRepeat()
        ring.hide()
    }

    private struct WeakView {
        weak var view: UIView?
    }
}

/// Notices a touch anywhere in the window and gets out of the way at once:
/// it never recognizes, never delays, never cancels, so every other touch
/// behaves exactly as before.
private final class TouchSpyRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let onTouch: () -> Void

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Alerts a controller can answer

/// One action of an alert built with `addNavigableAction`, with the handler
/// the navigator calls itself (a system alert's own handler cannot be run
/// from code).
struct NavigableAlertAction {
    let action: UIAlertAction
    let handler: ((UIAlertAction) -> Void)?
}

private var navigableActionsKey: UInt8 = 0

extension UIAlertController {
    /// Add an action that a controller can reach as well as a finger (see
    /// `ControllerNavigator.handleAlert`). Same arguments as `UIAlertAction`.
    func addNavigableAction(title: String?, style: UIAlertAction.Style,
                            handler: ((UIAlertAction) -> Void)? = nil) {
        let action = UIAlertAction(title: title, style: style, handler: handler)
        addAction(action)
        navigableActions = (navigableActions ?? []) + [NavigableAlertAction(action: action, handler: handler)]
    }

    fileprivate(set) var navigableActions: [NavigableAlertAction]? {
        get { objc_getAssociatedObject(self, &navigableActionsKey) as? [NavigableAlertAction] }
        set { objc_setAssociatedObject(self, &navigableActionsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - Presenting an alert a controller can answer

/// Presents a confirmation from the front-most screen that a controller can
/// answer as well as a finger: the app's own dialog while a controller is in
/// hand (`ControllerConfirmDialog`, where the ring shows the choice), the
/// system alert otherwise, exactly as before. Used for every confirmation in a
/// daily flow (the pause menu's save and load, a new game, a deletion).
enum ControllerAlert {
    struct Action {
        let title: String
        var style: UIAlertAction.Style = .default
        var handler: () -> Void = {}
    }

    /// A controller is in hand: a pad, a keyboard-mode pad on a phone, or the
    /// highlight already moving.
    static var controllerInHand: Bool {
        ControllerManager.shared.hidesTouchControls || ControllerNavigator.shared.isShowing
    }

    static func present(title: String?, message: String?, actions: [Action]) {
        let presented: UIViewController
        if controllerInHand {
            presented = ControllerConfirmDialog(
                title: title, message: message,
                actions: actions.map { .init(title: $0.title, style: $0.style, handler: $0.handler) })
        } else {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for action in actions {
                let handler = action.handler
                alert.addNavigableAction(title: action.title, style: action.style) { _ in handler() }
            }
            presented = alert
        }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(presented, animated: true)
    }
}
