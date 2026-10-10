import AppKit
import SwiftUI

enum UICapture {
    enum Scenario {
        case normal
        case privateLocked
        case classification
        /// The floating note editor that replaced the right-hand pane's inline
        /// editor when the preview module was removed.
        case noteEditor
        /// 面板 + 标准夹具集。独立 case 便于与参考截图对比布局。
        case quickStrip
        /// Popup rendering when the database cannot be opened at all.
        case storeUnavailable
        /// A card that shows a screenshot, so the picture preview's sharpness
        /// can be checked at the real card size.
        case imageClip
        /// The empty-history state, where the theme's cast (No-Face and the
        /// cloud sprites) lives. No fixtures at all, so the panel has to render
        /// its "nothing here yet" page.
        case emptyHistory
    }

    @MainActor
    static func capture(path: String, scenario: Scenario = .normal) {
        let captureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipaUICapture-\(UUID().uuidString)", isDirectory: true)
        if case .storeUnavailable = scenario {
            // Occupy the database path with a file that is not a database, so
            // the store enters its recovery state exactly as it would in the
            // field.
            try? FileManager.default.createDirectory(
                at: captureDir,
                withIntermediateDirectories: true
            )
            let databaseURL = DatabaseManager.databaseURL(in: captureDir)
            let garbage = Data("not a sqlite database".utf8)
                + Data(repeating: 0, count: 4096)
            try? garbage.write(to: databaseURL)
        }
        let settingsSuite = "ClipaUICaptureSettings-\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: settingsSuite)!)
        settings.pauseRecording = CommandLine.arguments.contains("--ui-paused")
        let store = ClipStore(baseDirectory: captureDir, settingsStore: settings)
        var drafts: [NewClip]
        switch scenario {
        case .storeUnavailable:
            drafts = []
        case .emptyHistory:
            drafts = []
        case .imageClip:
            drafts = []
            if let png = Self.makeScreenshotFixture() {
                drafts.append(
                    NewClip(
                        kind: .image,
                        text: "",
                        imageData: png,
                        imageFormat: "public.png",
                        sourceApp: "预览",
                        contentHash: ContentHasher.hash(data: png)
                    )
                )
            }
            drafts.append(
                NewClip(
                    kind: .text,
                    text: "docker compose 网络配置示例",
                    sourceApp: "终端",
                    contentHash: ContentHasher.hash(text: "image-fixture-text")
                )
            )
        case .normal:
            drafts = [
                NewClip(
                    kind: .text,
                    text: "func greet(name: String) -> String {\n    return \"你好，\\(name)\"\n}",
                    note: "Swift 示例，用于面板代码预览",
                    sourceApp: "Xcode",
                    contentHash: ContentHasher.hash(text: "func greet")
                ),
                NewClip(
                    kind: .text,
                    text: "https://www.swift.org/documentation/",
                    sourceApp: "Safari"
                ),
                NewClip(
                    kind: .text,
                    text: "本周完成核心功能迭代，修复 3 项关键缺陷，整体稳定性明显提升。",
                    note: "周报素材",
                    sourceApp: "微信"
                )
            ]
        case .privateLocked:
            drafts = [
                NewClip(
                    kind: .text,
                    text: "func greet(name: String) -> String {\n    return \"你好，\\(name)\"\n}",
                    note: "Swift 示例，用于面板代码预览",
                    sourceApp: "Xcode",
                    contentHash: ContentHasher.hash(text: "func greet")
                ),
                NewClip(
                    kind: .text,
                    text: "https://www.swift.org/documentation/",
                    sourceApp: "Safari"
                ),
                NewClip(
                    kind: .text,
                    text: "本周完成核心功能迭代，修复 3 项关键缺陷，整体稳定性明显提升。",
                    note: "周报素材",
                    sourceApp: "微信"
                )
            ]
            drafts.append(
                NewClip(
                    kind: .text,
                    text: "共享网盘账号与密码：clip-demo@example.com / correct-horse-battery-staple",
                    note: "私密演示条目",
                    sourceApp: "1Password",
                    isPrivate: true,
                    contentHash: ContentHasher.hash(text: "private-demo")
                )
            )
        case .noteEditor, .quickStrip:
            drafts = [
                NewClip(
                    kind: .text,
                    text: #"{"name":"nginx","replicas":3,"env":"production"}"#,
                    note: "本周部署的 nginx 配置",
                    sourceApp: "VS Code",
                    contentHash: ContentHasher.hash(text: "nginx-json")
                ),
                NewClip(
                    kind: .text,
                    text: """
                    apiVersion: apps/v1
                    kind: Deployment
                    metadata:
                      name: nginx
                    spec:
                      replicas: 3
                    """,
                    note: "Kubernetes Deployment",
                    sourceApp: "VS Code",
                    contentHash: ContentHasher.hash(text: "nginx-yaml")
                ),
                NewClip(
                    kind: .text,
                    text: "https://kubernetes.io/zh-cn/docs/concepts/workloads/controllers/deployment/",
                    sourceApp: "浏览器",
                    contentHash: ContentHasher.hash(text: "k8s-doc")
                )
            ]
        case .classification:
            drafts = [
                NewClip(
                    kind: .text,
                    text: "192.168.1.100",
                    sourceApp: "终端",
                    contentHash: ContentHasher.hash(text: "ip-demo")
                ),
                NewClip(
                    kind: .text,
                    text: "admin@example.com",
                    sourceApp: "邮件",
                    contentHash: ContentHasher.hash(text: "email-demo")
                ),
                NewClip(
                    kind: .text,
                    text: "https://kubernetes.io/zh-cn/docs/",
                    sourceApp: "浏览器",
                    contentHash: ContentHasher.hash(text: "url-demo")
                ),
                NewClip(
                    kind: .text,
                    text: #"{"name":"nginx","replicas":3,"env":"production"}"#,
                    sourceApp: "VS Code",
                    contentHash: ContentHasher.hash(text: "json-demo")
                ),
                NewClip(
                    kind: .text,
                    text: """
                    apiVersion: apps/v1
                    kind: Deployment
                    metadata:
                      name: nginx
                    spec:
                      replicas: 3
                    """,
                    sourceApp: "VS Code",
                    contentHash: ContentHasher.hash(text: "yaml-demo")
                ),
                NewClip(
                    kind: .text,
                    text: """
                    # 网络配置说明

                    - docker network ls
                    - docker network inspect bridge
                    """,
                    sourceApp: "备忘录",
                    contentHash: ContentHasher.hash(text: "md-demo")
                ),
                NewClip(
                    kind: .text,
                    text: "kubectl get pods -A",
                    sourceApp: "终端",
                    contentHash: ContentHasher.hash(text: "cmd-demo")
                )
            ]
        }
        if case .quickStrip = scenario {
            drafts = [
                NewClip(kind: .text, text: "演示私密内容", note: "仅供测试", sourceApp: "备忘录", isPrivate: true),
                NewClip(kind: .text, text: "https://developer.apple.com/design/", sourceApp: "Safari", sourceBundle: "com.apple.Safari"),
                NewClip(kind: .text, text: "设计评审：统一导航层级，减少重复操作，完善键盘交互。", note: "周三产品评审", sourceApp: "备忘录", sourceBundle: "com.apple.Notes"),
                NewClip(kind: .file, text: "设计方案.pdf", fileURLs: [URL(fileURLWithPath: "/tmp/ClipaPreview/设计方案.pdf")], sourceApp: "访达", sourceBundle: "com.apple.finder"),
                NewClip(kind: .text, text: #"{"theme": "system", "language": "zh-CN"}"#, sourceApp: "Xcode", sourceBundle: "com.apple.dt.Xcode"),
                NewClip(kind: .text, text: "swift build -c release", note: "正式版本编译命令", sourceApp: "终端", sourceBundle: "com.apple.Terminal"),
                NewClip(kind: .text, text: "让每一次复制，都能轻松找回。", sourceApp: "备忘录", sourceBundle: "com.apple.Notes")
            ]
            if let png = Self.makeScreenshotFixture() {
                drafts.insert(NewClip(kind: .image, text: "", imageData: png, imageFormat: "public.png", sourceApp: "预览", sourceBundle: "com.apple.Preview"), at: 3)
            }
        }
        let inserted = store.replaceAllForTesting(drafts)

        let vm = PanelViewModel(store: store, settings: settings)
        switch scenario {
        case .storeUnavailable:
            break
        case .emptyHistory:
            break
        case .normal:
            if let yaml = inserted.first(where: { $0.smartTag == .yaml }) {
                vm.select(yaml)
            } else if let first = inserted.first {
                vm.select(first)
            }
        case .privateLocked:
            if let locked = inserted.first(where: { $0.isPrivate }) {
                vm.select(locked)
            } else if let first = inserted.first {
                vm.select(first)
            }
        case .classification:
            if let yaml = inserted.first(where: { $0.smartTag == .yaml }) {
                vm.select(yaml)
            } else if let first = inserted.first {
                vm.select(first)
            }
        case .noteEditor:
            // The editor floats above the list now; this render is what proves
            // it is still reachable after the preview pane was removed.
            if let noted = inserted.first(where: { $0.hasNote }) {
                vm.select(noted)
                vm.openNoteEditor(noted)
            } else if let first = inserted.first {
                vm.select(first)
                vm.openNoteEditor(first)
            }

        case .quickStrip:
            vm.refreshSearch()
            vm.toast = nil
            print("UICapture: quickStrip rows=\(vm.clips.count)")
            if let first = vm.firstResultItem { vm.select(first) }
        case .imageClip:
            if let image = inserted.first(where: { $0.kind == .image }) {
                vm.select(image)
            } else if let first = inserted.first {
                vm.select(first)
            }
        }

        if let queryFlag = CommandLine.arguments.firstIndex(of: "--ui-query"),
           queryFlag + 1 < CommandLine.arguments.count {
            vm.query = CommandLine.arguments[queryFlag + 1]
            vm.refreshSearch()
        }
        if CommandLine.arguments.contains("--ui-preview") { vm.openPreview() }
        if CommandLine.arguments.contains("--ui-collection"), let db = store.database,
           let id = try? DatabaseSync.run(db, { db in
               let id = try await db.saveCollection(name: "项目参考")
               let clips = try await db.loadRecentClips(limit: 3)
               try await db.changeCollectionMembers(id: id, clips: clips.filter { !$0.isPrivate }.map(\.id), adding: true)
               return id
           }) {
            vm.selectCollection(id)
        }
        if CommandLine.arguments.contains("--ui-note-error") {
            vm.openNoteEditor(vm.firstResultItem)
            vm.noteDraft = "这是一条尚未保存的备注草稿"
            vm.noteError = "保存失败。草稿已保留，请重试。"
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let appearance = NSAppearance(named: CommandLine.arguments.contains("--ui-dark") ? .darkAqua : .aqua)
        app.appearance = appearance
        let paneSize = QuickStripController.panelFrame(in: NSRect(x: 0, y: 0, width: 1440, height: 900)).size
        let view = QuickStripView(vm: vm, forceOpaqueSurface: CommandLine.arguments.contains("--ui-reduce-transparency"))
            .frame(width: paneSize.width, height: paneSize.height)
        let hosting = NSHostingView(rootView: view)
        let window = FloatingPanel(contentRect: NSRect(origin: .zero, size: paneSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = hosting
        window.center()
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        let data: Data
        do {
            if captureWindow(number: window.windowNumber, path: path),
               let screenshot = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                data = screenshot
            } else {
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    fatalError("UICapture: 无法创建位图")
                }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    fatalError("UICapture: 无法编码 PNG")
                }
                data = png
                try data.write(to: URL(fileURLWithPath: path))
            }
            print("UICapture: 已写入 \(path)")
        } catch {
            print("UICapture: 写入失败 \(error)")
            exit(1)
        }
        window.orderOut(nil)
        UserDefaults.standard.removePersistentDomain(forName: settingsSuite)

        // Objective render check: count non-transparent pixels.
        var opaque = 0
        var total = 0
        if let rep = NSBitmapImageRep(data: data) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                    total += 1
                    if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                        opaque += 1
                    }
                }
            }
        }
        let ratio = total == 0 ? 0 : Double(opaque) / Double(total)
        print(String(format: "UICapture: 渲染像素占比 %.1f%%（%d/%d 采样）", ratio * 100, opaque, total))
        try? FileManager.default.removeItem(at: captureDir)
        if ratio < 0.6 {
            print("UICapture: 渲染内容过少，疑似空白界面")
            exit(1)
        }
    }

    private static func captureWindow(number: Int, path: String) -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(number), path]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
            return hasVisiblePixels(data)
        } catch { return false }
    }

    private static func hasVisiblePixels(_ data: Data) -> Bool {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return false }
        var visible = 0
        var total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 16) {
                total += 1
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { visible += 1 }
            }
        }
        return total > 0 && Double(visible) / Double(total) > 0.25
    }

    @MainActor
    static func captureMenu(path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: CommandLine.arguments.contains("--ui-dark") ? .darkAqua : .aqua)
        _ = ClipStore.shared.replaceAllForTesting((1...8).map {
            NewClip(kind: .text, text: "菜单预览条目 \($0)")
        })
        let delegate = AppDelegate()
        let menu = delegate.statusMenuSnapshot()
        menu.appearance = app.appearance
        app.activate(ignoringOtherApps: true)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var captured = false
        let capture: @MainActor @Sendable () -> Void = {
                let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) }
                for info in own where (info[kCGWindowLayer as String] as? Int ?? 0) > 0 {
                    guard let number = info[kCGWindowNumber as String] as? Int else { continue }
                    if captureWindow(number: number, path: path) {
                        captured = true
                        break
                    }
                }
                if !captured {
                    let views = app.windows.filter { $0.isVisible && $0.level.rawValue > 0 }
                    for window in views {
                        guard let view = window.contentView,
                              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                        window.effectiveAppearance.performAsCurrentDrawingAppearance {
                            view.cacheDisplay(in: view.bounds, to: rep)
                        }
                        if let data = rep.representation(using: .png, properties: [:]), hasVisiblePixels(data),
                           (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                            captured = true
                            break
                        }
                    }
                    print("UICapture: native menu windows=\(views.map { String(describing: type(of: $0)) + String(describing: $0.frame.size) })")
                }
                menu.cancelTracking()
        }
        let timer = Timer(timeInterval: 0.7, repeats: false) { _ in
            MainActor.assumeIsolated { capture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        _ = withExtendedLifetime(delegate) {
            menu.popUp(positioning: nil, at: NSPoint(x: screen.minX + 80, y: screen.maxY - 80), in: nil)
        }
        if !captured {
            print("UICapture: 原生菜单截图失败")
            exit(1)
        }
        print("UICapture: 原生菜单已写入 \(path)")
    }

    /// A screenshot-shaped fixture: light background, coloured bars, "text"
    /// lines and one-pixel hairlines. The hairlines are the point — they are
    /// what goes soft first when a card decodes its image too small.
    private static func makeScreenshotFixture() -> Data? {
        let width = 1600
        let height = 1000
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Title bar + accent bars.
        context.setFillColor(CGColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 90, width: width, height: 90))
        for index in 0..<6 {
            context.setFillColor(
                CGColor(
                    red: 0.35 + Double(index) * 0.09,
                    green: 0.55,
                    blue: 0.85 - Double(index) * 0.07,
                    alpha: 1
                )
            )
            context.fill(
                CGRect(
                    x: 60,
                    y: height - 220 - index * 70,
                    width: 220 + index * 130,
                    height: 34
                )
            )
        }
        // "Text": dark hairlines of decreasing thickness.
        for index in 0..<40 {
            let thickness = index % 3 == 0 ? 2 : 1
            context.setFillColor(
                CGColor(red: 0.15, green: 0.16, blue: 0.20, alpha: 1)
            )
            context.fill(
                CGRect(
                    x: 60,
                    y: 120 + CGFloat(index) * 16,
                    width: CGFloat(300 + (index * 37) % 900),
                    height: CGFloat(thickness)
                )
            )
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

}
