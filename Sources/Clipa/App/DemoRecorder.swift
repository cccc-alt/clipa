import AppKit
import SwiftUI

enum DemoRecorder {
    private static var attachedWindows: [NSWindow] = []

    @MainActor
    static func run(framesRoot: String) -> Int32 {
        try? FileManager.default.createDirectory(
            atPath: framesRoot,
            withIntermediateDirectories: true
        )
        recordSmartHistory(root: framesRoot + "/scene1")
        recordClassification(root: framesRoot + "/scene3")
        recordPrivacy(root: framesRoot + "/scene4")
        for window in attachedWindows {
            window.orderOut(nil)
        }
        attachedWindows.removeAll()
        print("DEMO-FRAMES \(framesRoot)")
        return 0
    }

    @MainActor
    private static func recordSmartHistory(root: String) {
        try? FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true
        )
        let store = makeStore()
        let vm = PanelViewModel(
            store: store,
            settings: store.settings
        )
        let hosting = makePanelHosting(vm: vm)
        attach(hosting)
        var frame = 0

        func snap(seconds: Double) {
            writeFrame(hosting: hosting, path: root + String(format: "/%04d.png", frame))
            frame += 1
            RunLoop.main.run(
                until: Date().addingTimeInterval(min(seconds, 0.4))
            )
        }

        snap(seconds: 0.8)
        insert(store: store, kind: .text, text: "本周完成核心功能迭代，修复 3 项关键缺陷", note: "周报素材", source: "微信")
        snap(seconds: 0.8)
        insert(store: store, kind: .text, text: "https://www.swift.org/documentation/", source: "Safari")
        snap(seconds: 0.8)
        insert(store: store, kind: .text, text: "func greet(name: String) -> String {\n    return \"你好，\\(name)\"\n}", note: "Swift 示例", source: "Xcode")
        snap(seconds: 0.8)
        insert(store: store, kind: .text, text: "name: Tom\nage: 18\ncity: Tokyo", source: "VS Code")
        snap(seconds: 0.8)

        snap(seconds: 2.0)
    }

    @MainActor
    private static func recordClassification(root: String) {
        try? FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true
        )
        let store = makeStore()
        let drafts: [(ClipKind, String, String)] = [
            (.text, "192.168.1.100", "终端"),
            (.text, "admin@example.com", "邮件"),
            (.text, "https://kubernetes.io/zh-cn/docs/", "浏览器"),
            (.text, #"{"name":"nginx","replicas":3}"#, "VS Code"),
            (.text, "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: nginx", "VS Code"),
            (.text, "# 网络配置说明\n\n- docker network ls\n- docker network inspect bridge", "备忘录"),
            (.text, "kubectl get pods -A", "终端")
        ]
        for draft in drafts {
            insert(
                store: store,
                kind: draft.0,
                text: draft.1,
                source: draft.2
            )
        }
        let vm = PanelViewModel(
            store: store,
            settings: store.settings
        )
        let hosting = makePanelHosting(vm: vm)
        attach(hosting)
        var frame = 0

        func snap(seconds: Double) {
            writeFrame(hosting: hosting, path: root + String(format: "/%04d.png", frame))
            frame += 1
            RunLoop.main.run(
                until: Date().addingTimeInterval(min(seconds, 0.4))
            )
        }

        snap(seconds: 0.6)
        for target in [SmartTag.yaml, .markdown, .json] {
            if let item = store.items.first(where: { $0.smartTag == target }) {
                vm.select(item)
                snap(seconds: 1.1)
            }
        }
    }

    @MainActor
    private static func recordPrivacy(root: String) {
        try? FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true
        )
        let store = makeStore()
        insert(store: store, kind: .text, text: "共享网盘账号与密码：clip-demo@example.com / correct-horse-battery-staple", note: "私密演示条目", source: "1Password")
        insert(store: store, kind: .text, text: "https://www.swift.org/documentation/", source: "Safari")
        insert(store: store, kind: .text, text: "func greet(name: String) -> String {\n    return \"你好\"\n}", source: "Xcode")
        let vm = PanelViewModel(
            store: store,
            settings: store.settings
        )
        let hosting = makePanelHosting(vm: vm)
        attach(hosting)
        var frame = 0

        func snap(seconds: Double) {
            writeFrame(hosting: hosting, path: root + String(format: "/%04d.png", frame))
            frame += 1
            RunLoop.main.run(
                until: Date().addingTimeInterval(min(seconds, 0.4))
            )
        }

        if let target = store.items.first(where: { $0.kind == .text }) {
            vm.select(target)
            snap(seconds: 1.4)
            vm.togglePrivate(target)
            snap(seconds: 2.8)
        } else {
            snap(seconds: 3.0)
        }
    }

    @MainActor
    private static func makePanelHosting(
        vm: PanelViewModel
    ) -> NSHostingView<QuickStripView> {
        let hosting = NSHostingView(rootView: QuickStripView(vm: vm))

        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: 1440 - QuickStripController.sideInset * 2,
            height: QuickStripController.preferredHeight
        )
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private static func makeStore() -> ClipStore {
        let dir = makeStoreDirectory()
        let suite = "ClipaDemoStore-\(UUID().uuidString)"
        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: suite)!,
        )
        return ClipStore(
            baseDirectory: dir,
            settingsStore: settings
        )
    }

    private static func makeStoreDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClipaDemoStore-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    private static func insert(
        store: ClipStore,
        kind: ClipKind,
        text: String,
        note: String = "",
        source: String
    ) {
        store.insert(
            NewClip(
                kind: kind,
                text: text,
                note: note,
                sourceApp: source,
                contentHash: ContentHasher.hash(text: text + UUID().uuidString)
            )
        )
    }

    @MainActor
    private static func writeFrame<Content: View>(
        hosting: NSHostingView<Content>,
        path: String
    ) {
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(
            in: hosting.bounds
        ) else {
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    @discardableResult
    private static func attach<Content: View>(
        _ hosting: NSHostingView<Content>
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.alphaValue = 0.01
        window.contentView = hosting
        window.orderFrontRegardless()
        attachedWindows.append(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        return window
    }
}
