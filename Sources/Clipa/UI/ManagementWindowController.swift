import AppKit
import Combine
import SwiftUI

@MainActor
final class ManagementWindowController: NSWindowController, NSWindowDelegate {
    let model: ManagementModel
    private var subscriptions = Set<AnyCancellable>()

    init(model: ManagementModel, interactive: Bool = true) {
        self.model = model
        let hosting = NSHostingController(rootView: ManagementView(model: model).allowsHitTesting(interactive))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 640))
        window.minSize = NSSize(width: 740, height: 540)
        window.title = "Clipa 设置"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        if interactive {
            window.setFrameAutosaveName("ClipaManagementWindow")
            if !window.setFrameUsingName("ClipaManagementWindow") { window.center() }
        } else { window.center() }
        super.init(window: window)
        window.delegate = self
        model.$page.sink { [weak window] page in window?.title = page.title + " — Clipa" }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(page: ManagementPage) {
        if !model.preventsDismissal, model.sheet == nil { model.page = page }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.preventsDismissal else {
            model.sheetError = model.issuedToken == nil
                ? "操作正在进行，请稍候。"
                : "请先确认已保存令牌，或选择「撤销并关闭」。"
            return false
        }
        model.dismissSheet()
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if model.sheet == nil { model.refresh() }
    }
}
