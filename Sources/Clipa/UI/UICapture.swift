import AppKit
import SwiftUI

enum UICapture {
    enum Scenario {
        case normal
        case privateLocked
        case classification

        case noteEditor

        case quickStrip

        case storeUnavailable

        case imageClip

        case emptyHistory
    }

    @MainActor
    static func capture(path: String, scenario: Scenario = .normal) {
        let captureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipaUICapture-\(UUID().uuidString)", isDirectory: true)
        if case .storeUnavailable = scenario {

            try? FileManager.default.createDirectory(
                at: captureDir,
                withIntermediateDirectories: true
            )
            let databaseURL = DatabaseManager.databaseURL(in: captureDir)
            let garbage = Data("not a sqlite database".utf8)
                + Data(repeating: 0, count: 4096)
            try? garbage.write(to: databaseURL)
        }
        let store = ClipStore(baseDirectory: captureDir)
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
        let inserted = store.replaceAllForTesting(drafts)

        let settingsSuite = "ClipaUICapture-\(UUID().uuidString)"
        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: settingsSuite)!,
        )
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
            if let first = inserted.first {
                vm.select(first)
            }
        case .imageClip:
            if let image = inserted.first(where: { $0.kind == .image }) {
                vm.select(image)
            } else if let first = inserted.first {
                vm.select(first)
            }
        }

        let paneSize = NSSize(
            width: 1440 - QuickStripController.sideInset * 2,
            height: QuickStripController.preferredHeight
        )
        let view = QuickStripView(vm: vm)
            .frame(width: paneSize.width, height: paneSize.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: paneSize)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("UICapture: 无法创建位图")
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("UICapture: 无法编码 PNG")
            exit(1)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("UICapture: 已写入 \(path)")
        } catch {
            print("UICapture: 写入失败 \(error)")
            exit(1)
        }

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
