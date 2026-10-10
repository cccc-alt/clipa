import AppKit
import SwiftUI

/// The borderless panel the clipboard page lives in. It can take key focus
/// (unlike a plain borderless window) so the search field, the note editor and
/// the keyboard navigation all receive events.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns Clipa's one clipboard page: the floating panel (⌃⌘V)。
/// 窗口几何、滑入滑出动画、失焦收起都在这里；面板内全部功能见 `QuickStripView`。
@MainActor
final class QuickStripController: NSObject {
    /// Base window level of the clipboard overlay. Every other Clipa window
    /// (settings, alerts) is raised relative to it, so a dialog can never open
    /// underneath the popup and swallow clicks. NSPanel's `isFloatingPanel` may
    /// lower the live panel to `.floating`, so using `.statusBar` as the base
    /// covers both cases.
    nonisolated static let overlayLevel = NSWindow.Level.statusBar

    /// Measured from the reference screenshot: the popup spans the screen width
    /// minus a small margin on each side, and keeps the height the card strip
    /// always had — the added module chrome (filter menu, note
    /// editor, store-recovery card) lives in the same 340pt pane.
    nonisolated static let sideInset: CGFloat = 12
    /// 10% shorter than the 340pt the card strip was measured at: the panel is
    /// a quick-find drawer, and the freed height is spent on *bigger* card text
    /// rather than on more rows.
    nonisolated static let preferredHeight: CGFloat = 560
    /// How long the slide-out takes. Short on purpose: the strip travels its
    /// own height, and anything longer reads as sluggish for a clipboard.
    nonisolated static let slideDuration: TimeInterval = 0.22

    /// The one view model behind the page. Exposed because `AppDelegate` drives
    /// toasts, workspace rebinds and the menu bar through it.
    let viewModel: PanelViewModel
    private var panel: FloatingPanel!
    private var hosting: NSHostingView<QuickStripView>!
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    /// True while a system authentication prompt (Touch ID / password) is up.
    /// The prompt belongs to another process, so its clicks look exactly like
    /// "the user clicked away" and used to dismiss the popup mid-unlock. While
    /// this is set the outside-click monitor stands down.
    private var privateAuthenticationActive = false
    /// True while a menu-initiated modal alert is on screen; see
    /// `parkForOverlayAlert`.
    private var parkedForOverlayAlert = false
    /// Backing state for the slide-out animation. The window is moved by hand
    /// on a timer instead of by `NSAnimationContext`: a frame animation that
    /// never starts (the CLI probes run without a live window server session)
    /// or gets interrupted used to leave the window parked at the animation's
    /// starting offset, i.e. hanging off the bottom of the screen.
    private var slideTimer: Timer?
    private var slideFrom: NSRect = .zero
    private var slideTarget: NSRect = .zero
    private var slideStartedAt: CFTimeInterval = 0
    /// Invalidates a pending "the slide must be over by now" safety net.
    private var slideGeneration = 0
    /// Frame the strip rests at, kept so `hide()` can park the hidden window
    /// there instead of leaving it mid-slide.
    private var restingFrame: NSRect = .zero
    /// Every `show()` / `hide()` bumps this, and a hide completion only lands
    /// when its own generation is still current. Without it a ⌃V pressed
    /// during the 120 ms fade-out was ordered off screen by the *previous*
    /// hide's completion: the strip vanished and the next press re-opened it.
    private var visibilityGeneration = 0
    /// The fade-out finishes exactly once per generation, whether it is the
    /// animation's completion handler or the safety net that gets there first.
    private var hideCompletionGeneration = 0
    /// Who had focus before the panel took it, so `hide()` can hand it back.
    private var appToRestore: NSRunningApplication?
    /// True from the moment a fade-out starts until it lands, so `show()` can
    /// tell "already resting" apart from "on its way out".
    private var isFadingOut = false
    /// Display configuration changes while the panel is open. Never removed:
    /// the controller lives for the lifetime of the process, like the event
    /// monitors, and the closure holds `self` weakly.
    private var screenChangeObserver: NSObjectProtocol?

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        super.init()
        bindViewModel()
        observeScreenChanges()
        build()
    }

    /// Wires the callbacks the view model exposes to whoever owns the windows.
    /// These used to be bound by the removed main panel's controller.
    private func bindViewModel() {
        viewModel.onPark = { [weak self] in
            self?.hide()
        }
        viewModel.onPrivateAuthenticationStateChanged = { [weak self] active in
            self?.handlePrivateAuthenticationStateChanged(active)
        }
    }

    /// Keeps the popup on screen while a Touch ID / password prompt is up.
    ///
    /// The prompt runs in another process, so its clicks reach the outside-click
    /// monitor and used to dismiss the popup mid-unlock. On completion the popup
    /// comes back to the front, because macOS may have handed focus to the app
    /// the user was pasting into.
    private func handlePrivateAuthenticationStateChanged(_ active: Bool) {
        if active {
            privateAuthenticationActive = true
            if isVisible {
                panel.level = Self.overlayLevel
            }
            return
        }
        guard privateAuthenticationActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.privateAuthenticationActive = false
            guard self.isVisible else { return }
            self.panel.level = Self.overlayLevel
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    /// A display change — a resolution switch, a monitor plugged in or pulled
    /// out, the Dock moving — can leave the panel anchored to a screen that no
    /// longer exists. It only recomputed its frame on `show()`, so a panel that
    /// was already open could end up parked off the visible area entirely.
    private func observeScreenChanges() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reanchorAfterScreenChange()
            }
        }
    }

    private func reanchorAfterScreenChange() {
        guard isVisible, !isFadingOut, let target = targetFrame() else { return }
        stopSlide()
        restingFrame = target
        panel.setFrame(target, display: true)
    }

    /// Temporarily parks the popup below system alerts. Used while a
    /// menu-initiated `NSAlert` is modal, so the alert can never render behind
    /// the `.statusBar`-level popup.
    func parkForOverlayAlert() {
        guard isVisible else { return }
        parkedForOverlayAlert = true
        panel.level = .normal
    }

    func restoreAfterOverlayAlert() {
        guard isVisible else { return }
        parkedForOverlayAlert = false
        panel.level = Self.overlayLevel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Frame for a display, anchored to the **physical bottom edge** of that
    /// screen.
    ///
    /// Deliberately `screen.frame`, not `visibleFrame`: a Dock parked along the
    /// bottom raises `visibleFrame.minY` by its own height (measured here: 80pt
    /// on a 1440×900 display), which left the strip floating above the Dock and
    /// visibly nowhere near the bottom. The strip is a drawer that comes out of
    /// the screen's own bottom edge, so it covers whatever is docked there;
    /// `esc` / clicking outside puts it away again.
    ///
    /// Pure so the self-test can assert the anchor without needing a screen.
    nonisolated static func panelFrame(in screen: NSRect) -> NSRect {
        // P2 对齐（2026-10-04）：Spotlight 剪贴板面板的几何——
        // 宽 ≈ 640pt（窄屏收边），高 560，**水平居中 + 略高于垂直居中**
        // （实拍测得面板中心在屏幕高度 46% 自顶 = 54% 自底），不再是
        // 全宽贴底。
        let width = min(max(screen.width * 0.44, 480), 640)
        let height = min(
            preferredHeight,
            max(screen.height - 40, 180),
            screen.height
        )
        let x = min(
            max(screen.midX - width / 2, screen.minX),
            max(screen.maxX - width, screen.minX)
        )
        // 垂直：面板中心在屏幕高度 54% 处，两端夹紧保证不出屏。
        let y = min(
            max(screen.midY - height / 2 + screen.height * 0.04, screen.minY),
            max(screen.maxY - height, screen.minY)
        )
        // 取整：AppKit 会把窗口坐标归到整点——这里不先取整，"计算的静止位"
        // 与"窗口实际位置"就会差出小数（探针的相等断言会红）。
        return NSRect(
            x: x.rounded(),
            y: y.rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }

    /// Where the slide starts: 48pt below the resting frame — a short rise
    /// with the same hand-driven interpolation. The old full-screen climb was
    /// the bottom-docked era's language; a centered panel just floats up.
    nonisolated static func startFrame(for target: NSRect) -> NSRect {
        NSRect(
            x: target.minX,
            y: target.minY - 48,
            width: target.width,
            height: target.height
        )
    }

    /// Linear interpolation between two frames, used by the hand-driven slide.
    nonisolated static func interpolate(
        _ from: NSRect,
        _ to: NSRect,
        _ progress: CGFloat
    ) -> NSRect {
        NSRect(
            x: from.minX + (to.minX - from.minX) * progress,
            y: from.minY + (to.minY - from.minY) * progress,
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * progress
        )
    }

    private func build() {
        let rect = NSRect(
            origin: .zero,
            size: NSSize(width: 900, height: Self.preferredHeight)
        )
        let content = QuickStripView(vm: viewModel) { [weak self] in
            self?.hide()
        }
        let hosting = NSHostingView(rootView: content)
        self.hosting = hosting

        panel = FloatingPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.appearance = nil
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = Self.overlayLevel
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .transient
        ]
        panel.animationBehavior = .utilityWindow
    }

    var isVisible: Bool { panel.isVisible }
    var windowFrame: NSRect { panel.frame }
    /// Live window level. Exposed so the presentation probe can check that the
    /// strip really sits above the Dock instead of only trusting the constant.
    var windowLevel: Int { panel.level.rawValue }
    /// Live window, exposed so the presentation probe can click a card and
    /// type into the search field the way the user does.
    var contentWindow: NSWindow { panel }
    /// Test seam for ⌘↵: the presentation probe swaps this in to observe the
    /// key without running a real AI search. `nil` means "run it here", which
    /// is what the app does — the popup shows the AI plan chips itself now that
    /// there is no second surface to hand the query to.

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let target = targetFrame() else { return }
        // Re-assert the level *before* ordering in: AppKit lowers a floating
        // panel to `.floating` (measured: level 3) when it hits the screen. The
        // Dock lives at level 20, so a lowered strip whose bottom edge reaches
        // the screen's bottom would be drawn *under* the Dock icons — visible
        // proof that being on the bottom edge and being on top of the Dock are
        // two different things.
        panel.level = Self.overlayLevel
        // With nothing selected every card renders unhighlighted while ↵ still
        // copies the first one.
        if viewModel.selectedItem == nil, let first = viewModel.firstResultItem {
            viewModel.select(first)
        }
        visibilityGeneration &+= 1
        viewModel.activeSurface = .quickStrip
        viewModel.openTick += 1
        // Already open and settled: the hotkey doubles as a "bring it forward"
        // gesture, and re-running the slide made the panel dive off the bottom
        // edge and rise again for no reason. Focus is re-asserted either way.
        let alreadyResting = panel.isVisible
            && slideTimer == nil
            && !isFadingOut
            && panel.frame == target
        isFadingOut = false
        if alreadyResting {
            panel.alphaValue = 1
            panel.setFrame(target, display: false)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            startMonitors()
            return
        }
        let start = Self.startFrame(for: target)
        restingFrame = target
        panel.alphaValue = 1
        panel.setFrame(start, display: false)
        // Remember who had focus *before* the panel takes it. Activating Clipa
        // is what makes the search field typable, and it is also why the
        // activation has to be handed back on the way out.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            appToRestore = front
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startMonitors()
        startSlide(from: start, to: target)
    }

    /// Hides the panel.
    ///
    /// - Parameter restoreFocus: hands activation back to the app that was
    ///   frontmost before the panel opened. False for the one case where the
    ///   user has already moved on by themselves — clicking another app, which
    ///   makes that app frontmost and would be undone by activating the old one.
    func hide(restoreFocus: Bool = true) {
        guard isVisible else { return }
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        if viewModel.activeSurface == .quickStrip {
            viewModel.activeSurface = nil
        }
        // The note editor does not outlive the panel. It used to stay open
        // across a hide, so the next summon came up with the key router still
        // treating "editor open" as true: Return no longer copied and the
        // arrows no longer moved the selection, which reads as a broken
        // keyboard until the editor is dismissed by hand.
        viewModel.suspendNoteEditor()
        viewModel.previewID = nil
        isFadingOut = true
        stopMonitors()
        stopSlide()
        let resting = restingFrame == .zero ? panel.frame : restingFrame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.finishHide(
                    generation: generation,
                    resting: resting,
                    restoreFocus: restoreFocus
                )
            }
        }
        // Same reasoning as the slide-out's safety net: the monitors are already
        // gone, so an animation group that never completes would leave the panel
        // parked on screen at alpha 1 with no way to click it away.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.12 + 0.05
        ) { [weak self] in
            Task { @MainActor in
                self?.finishHide(
                    generation: generation,
                    resting: resting,
                    restoreFocus: restoreFocus
                )
            }
        }
    }

    /// Where the fade-out actually lands. Called from the animation's completion
    /// handler and from the safety net above; the generation guard makes the
    /// second caller a no-op.
    private func finishHide(
        generation: Int,
        resting: NSRect,
        restoreFocus: Bool
    ) {
        guard visibilityGeneration == generation,
              hideCompletionGeneration != generation else { return }
        hideCompletionGeneration = generation
        isFadingOut = false
        panel.orderOut(nil)
        // The window is hidden at the resting frame, never at whatever offset
        // the slide happened to be at when it was dismissed.
        panel.setFrame(resting, display: false)
        panel.alphaValue = 1
        if restoreFocus {
            activatePreviousApp()
        }
    }

    /// Gives activation back to the app the user was in.
    ///
    /// Without this the copy is on the pasteboard but Clipa is still the
    /// frontmost app, and Clipa has no Paste command — so ⌘V did nothing at all
    /// until the user clicked the target window first. That made "copy, then
    /// paste" look broken for the one workflow the app exists for.
    private func activatePreviousApp() {
        guard let app = appToRestore,
              !app.isTerminated,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            appToRestore = nil
            return
        }
        appToRestore = nil
        app.activate()
    }

    /// Screen the strip belongs on: the one the mouse is on.
    private func targetFrame() -> NSRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let screen else { return nil }
        return Self.panelFrame(in: screen.frame)
    }

    // MARK: - Slide-out from the bottom edge

    private func startSlide(from start: NSRect, to target: NSRect) {
        stopSlide()
        slideFrom = start
        slideTarget = target
        slideStartedAt = CACurrentMediaTime()
        slideGeneration &+= 1
        let generation = slideGeneration
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.stepSlide()
            }
        }
        // `.common` keeps the slide running while a key is held down or a menu
        // is tracking; the default mode would freeze it there.
        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer
        // Safety net: if the timer never gets to run (an unattended CLI run, a
        // stalled run loop), the strip would sit below the screen forever.
        // Snapping to the resting frame is the only acceptable failure mode.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.slideDuration + 0.05
        ) { [weak self] in
            Task { @MainActor in
                guard let self, self.slideGeneration == generation else {
                    return
                }
                self.panel.setFrame(self.slideTarget, display: true)
                self.stopSlide()
            }
        }
    }

    private func stepSlide() {
        let progress = CGFloat(
            (CACurrentMediaTime() - slideStartedAt) / Self.slideDuration
        )
        guard progress < 1 else {
            panel.setFrame(slideTarget, display: true)
            stopSlide()
            return
        }
        // Ease-out cubic: fast off the bottom edge, settling into place.
        let eased = 1 - pow(1 - max(progress, 0), 3)
        panel.setFrame(
            Self.interpolate(slideFrom, slideTarget, eased),
            display: true
        )
    }

    private func stopSlide() {
        slideGeneration &+= 1
        slideTimer?.invalidate()
        slideTimer = nil
    }

    // MARK: - Keys and outside clicks

    private func startMonitors() {
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                // A session auth prompt and a menu-initiated modal alert are
                // other processes' windows: their clicks must not dismiss the
                // popup out from under the user.
                Task { @MainActor [weak self] in
                    guard let self,
                          !self.privateAuthenticationActive,
                          !self.parkedForOverlayAlert else { return }
                    // The click already made that app frontmost; activating the
                    // previous one here would steal it straight back.
                    self.hide(restoreFocus: false)
                }
            }
        }
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func stopMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    /// True while the note editor is open, i.e. while the keyboard belongs to
    /// that field.
    private var isTextEditorOpen: Bool {
        viewModel.showNoteEditor
    }

    /// Returns true when the popup consumed the event.
    ///
    /// The shared routing rules (`PanelKeyRouter`) decide first, so Return and
    /// the arrows stay with the note editor while it is open and with an input
    /// method mid-composition — this monitor runs *before* the key
    /// reaches the focused field, so swallowing those keys here would save/copy
    /// a clip instead of typing into the editor. What the router does not own
    /// (esc, and the horizontal ←/→ pair) is handled below.
    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 1, event.modifierFlags.contains(.command), isTextEditorOpen, !isComposing {
            Task { await viewModel.saveNoteAsync() }
            return true
        }
        if event.keyCode == 16, event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.option, .control, .shift]).isEmpty,
           !isTextEditorOpen, !isComposing {
            if viewModel.previewID != nil { viewModel.previewID = nil }
            else { viewModel.openPreview() }
            return true
        }
        if viewModel.previewID != nil, !isTextEditorOpen,
           [UInt16(123), 124, 125, 126].contains(event.keyCode) { return false }
        let action = PanelKeyRouter(
            isTextEditorOpen: isTextEditorOpen,
            isComposingText: isComposing
        )
        .action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        )
        switch action {
        case .moveSelection(let offset):
            move(by: offset)
            return true
        case .copySelected:
            guard let item = selectedOrFirst() else { return false }
            Task {
                // Only dismiss on a copy that really happened: a cancelled
                // Touch ID prompt used to close the panel anyway, so the user
                // lost their place *and* ended up with nothing on the
                // pasteboard.
                if await viewModel.copyAsync(item) {
                    hide()
                }
            }
            return true
        case .passThrough:
            break
        }

        switch event.keyCode {
        case 53: // esc
            // An input method owns esc while its candidate list is up; taking
            // it here closed the whole popup when the user only meant to
            // dismiss the candidates.
            guard !isComposing else { return false }
            // While an editor is open, esc closes the editor — not the page the
            // user is working in.
            if isTextEditorOpen {
                viewModel.requestCloseNoteEditor()
                return true
            }
            if viewModel.previewID != nil { viewModel.previewID = nil; return true }
            hide()
            return true
        case 49: // Space: preview, unless it belongs to a search phrase or editor.
            guard !isComposing, !isTextEditorOpen,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !isSearchFieldEditing || viewModel.previewID != nil else { return false }
            if viewModel.previewID != nil { viewModel.previewID = nil }
            else { viewModel.openPreview() }
            return true
        case 123, 124: // ← / →
            guard !isComposing, !isTextEditorOpen else { return false }
            // Only bare arrows are card navigation: ⌥← / ⌘← belong to the
            // search field (previous word / start of line).
            guard !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.command)
            else { return false }
            // The search box owns the bare arrows while it has text in it. The
            // panel hands focus back to that field after every search, so taking
            // the arrows meant a typo could not be fixed with the caret — the
            // selected card moved instead, which reads as "the text field is
            // broken". With an empty box there is no caret to move, so the
            // arrows navigate cards as before.
            if isSearchFieldEditing { return false }
            move(by: event.keyCode == 123 ? -1 : 1)
            return true
        default:
            return false
        }
    }

    private var isComposing: Bool {
        guard let editor = panel.firstResponder as? NSTextView else {
            return false
        }
        return editor.hasMarkedText()
    }

    /// True while the search box has focus *and* text to edit. An empty box
    /// leaves the bare arrows free to navigate the cards.
    private var isSearchFieldEditing: Bool {
        guard panel.firstResponder is NSTextView else { return false }
        return !viewModel.query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }



    /// Index the next selection lands on, or nil when there is nothing to
    /// select. Pure so the self-test can pin both ends and the case where the
    /// stored selection sits outside the cards this page renders.
    nonisolated static func nextIndex(
        selectedIndex: Int?,
        count: Int,
        delta: Int
    ) -> Int? {
        guard count > 0 else { return nil }
        guard let selectedIndex else {
            // The selection is not among the cards here: enter from the matching
            // end instead of skipping the first card, which `(nil ?? 0) + 1`
            // used to do.
            return delta < 0 ? count - 1 : 0
        }
        return min(max(selectedIndex + delta, 0), count - 1)
    }

    private func move(by delta: Int) {
        // The full result set: the row only renders one page at a time, so the
        // target has to be inside the loaded window before the view is asked to
        // scroll to it. Without that call the selection walked off the loaded
        // page, no card was highlighted any more, and Return copied a card the
        // user could not see. `nextIndex` keeps the ends clamped (arrows do not
        // wrap here, unlike `PanelViewModel.moveSelection`).
        let ids = viewModel.navigationOrder
        guard !ids.isEmpty else { return }
        let current = viewModel.selectedID.flatMap { ids.firstIndex(of: $0) }
        guard var index = Self.nextIndex(
            selectedIndex: current,
            count: ids.count,
            delta: delta
        ) else { return }
        // The row the arrow landed on can already be gone: `navigationOrder` is
        // refreshed by a debounced search, so a capture landing in that window
        // leaves a stale id in the list. That used to swallow the key press
        // ("the arrows stop working for a moment"); step over the gap instead.
        for _ in 0..<4 {
            if let clip = viewModel.store.clip(id: ids[index]) {
                viewModel.ensureEntryVisible(clipID: ids[index])
                viewModel.select(clip)
                return
            }
            guard let stepped = Self.nextIndex(
                selectedIndex: index,
                count: ids.count,
                delta: delta
            ), stepped != index else { return }
            index = stepped
        }
    }

    private func selectedOrFirst() -> Clip? {
        if let selected = viewModel.selectedItem { return selected }
        guard let first = viewModel.navigationOrder.first else { return nil }
        return viewModel.store.clip(id: first)
    }
}
