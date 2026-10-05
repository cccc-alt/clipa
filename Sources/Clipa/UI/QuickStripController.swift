import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class QuickStripController: NSObject {

    nonisolated static let overlayLevel = NSWindow.Level.statusBar

    nonisolated static let sideInset: CGFloat = 12

    nonisolated static let preferredHeight: CGFloat = 560

    nonisolated static let slideDuration: TimeInterval = 0.22

    let viewModel: PanelViewModel
    private var panel: FloatingPanel!
    private var hosting: NSHostingView<QuickStripView>!
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?

    private var privateAuthenticationActive = false

    private var parkedForOverlayAlert = false

    private var slideTimer: Timer?
    private var slideFrom: NSRect = .zero
    private var slideTarget: NSRect = .zero
    private var slideStartedAt: CFTimeInterval = 0

    private var slideGeneration = 0

    private var restingFrame: NSRect = .zero

    private var visibilityGeneration = 0

    private var hideCompletionGeneration = 0

    private var appToRestore: NSRunningApplication?

    private var isFadingOut = false

    private var screenChangeObserver: NSObjectProtocol?

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        super.init()
        bindViewModel()
        observeScreenChanges()
        build()
    }

    private func bindViewModel() {
        viewModel.onPark = { [weak self] in
            self?.hide()
        }
        viewModel.onPrivateAuthenticationStateChanged = { [weak self] active in
            self?.handlePrivateAuthenticationStateChanged(active)
        }
    }

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

    nonisolated static func panelFrame(in screen: NSRect) -> NSRect {

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

        let y = min(
            max(screen.midY - height / 2 + screen.height * 0.04, screen.minY),
            max(screen.maxY - height, screen.minY)
        )

        return NSRect(
            x: x.rounded(),
            y: y.rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }

    nonisolated static func startFrame(for target: NSRect) -> NSRect {
        NSRect(
            x: target.minX,
            y: target.minY - 48,
            width: target.width,
            height: target.height
        )
    }

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

        panel.appearance = NSAppearance(named: .aqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
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

    var windowLevel: Int { panel.level.rawValue }

    var contentWindow: NSWindow { panel }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let target = targetFrame() else { return }

        panel.level = Self.overlayLevel

        if viewModel.selectedItem == nil, let first = viewModel.firstResultItem {
            viewModel.select(first)
        }
        visibilityGeneration &+= 1
        viewModel.activeSurface = .quickStrip
        viewModel.openTick += 1

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

        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            appToRestore = front
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startMonitors()
        startSlide(from: start, to: target)
    }

    func hide(restoreFocus: Bool = true) {
        guard isVisible else { return }
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        if viewModel.activeSurface == .quickStrip {
            viewModel.activeSurface = nil
        }

        viewModel.showNoteEditor = false
        isFadingOut = true
        stopMonitors()
        stopSlide()
        let resting = restingFrame == .zero ? panel.frame : restingFrame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
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

        panel.setFrame(resting, display: false)
        panel.alphaValue = 1
        if restoreFocus {
            activatePreviousApp()
        }
    }

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

    private func targetFrame() -> NSRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let screen else { return nil }
        return Self.panelFrame(in: screen.frame)
    }

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

        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer

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

    private func startMonitors() {
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in

                Task { @MainActor [weak self] in
                    guard let self,
                          !self.privateAuthenticationActive,
                          !self.parkedForOverlayAlert else { return }

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

    private var isTextEditorOpen: Bool {
        viewModel.showNoteEditor
    }

    private func handle(_ event: NSEvent) -> Bool {
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

                if await viewModel.copyAsync(item) {
                    hide()
                }
            }
            return true
        case .passThrough:
            break
        }

        switch event.keyCode {
        case 53:

            guard !isComposing else { return false }

            if isTextEditorOpen {
                viewModel.showNoteEditor = false
                return true
            }
            hide()
            return true
        case 123, 124:
            guard !isComposing, !isTextEditorOpen else { return false }

            guard !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.command)
            else { return false }

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

    private var isSearchFieldEditing: Bool {
        guard panel.firstResponder is NSTextView else { return false }
        return !viewModel.query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    nonisolated static func nextIndex(
        selectedIndex: Int?,
        count: Int,
        delta: Int
    ) -> Int? {
        guard count > 0 else { return nil }
        guard let selectedIndex else {

            return delta < 0 ? count - 1 : 0
        }
        return min(max(selectedIndex + delta, 0), count - 1)
    }

    private func move(by delta: Int) {

        let ids = viewModel.navigationOrder
        guard !ids.isEmpty else { return }
        let current = viewModel.selectedID.flatMap { ids.firstIndex(of: $0) }
        guard var index = Self.nextIndex(
            selectedIndex: current,
            count: ids.count,
            delta: delta
        ) else { return }

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
