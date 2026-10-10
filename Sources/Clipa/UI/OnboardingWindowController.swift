import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel
    var onFinish: (Bool) -> Void = { _ in }

    init(model: OnboardingModel) {
        self.model = model
        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Clipa 新手引导"
        window.setContentSize(NSSize(width: 680, height: 580))
        window.minSize = NSSize(width: 640, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak self] openClipboard in
            self?.window?.orderOut(nil)
            self?.onFinish(openClipboard)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(replaying: Bool = false) {
        if window?.isVisible != true { model.begin(replaying: replaying) }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.skip()
        return true
    }
}
