import AppKit
import Foundation
import SwiftUI

enum ManagementCapture {
    @MainActor
    static func run(path: String, page: ManagementPage, sheet: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: CommandLine.arguments.contains("--ui-dark") ? .darkAqua : .aqua)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipaSettingsPreview-\(UUID())")
        let suite = "ClipaSettingsPreview-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = APITokenStore.directoryOverride
        APITokenStore.directoryOverride = root
        defer {
            APITokenStore.directoryOverride = previous
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let settings = SettingsStore(defaults: defaults)
        settings.historyLimit = 5000
        settings.ignoredApps = ["com.apple.Terminal", "com.apple.mail"]
        let registry = WorkspaceStore(rootDirectory: root)
        _ = try? registry.createWorkspace(named: "工作")
        _ = try? registry.createWorkspace(named: "个人")
        let store = ClipStore(baseDirectory: root, settingsStore: settings)
        _ = store.replaceAllForTesting((1...12).map { NewClip(kind: .text, text: "界面演示 \($0)") })
        let tokens = APITokenStore()
        _ = try? tokens.create(label: "Cursor", scopes: [.searchMeta, .searchText],
                               expiresAt: Date().addingTimeInterval(30 * 86_400))
        _ = try? tokens.create(label: "本地脚本", scopes: [.searchMeta, .put])
        for index in (0..<6).reversed() {
            APIAuditLog.append(.init(at: Date().addingTimeInterval(Double(-index * 90)), token: index % 2 == 0 ? "Cursor" : "本地脚本",
                                    peer: index % 2 == 0 ? "/Applications/Cursor.app" : "/usr/bin/python3",
                                    verb: index % 2 == 0 ? "search" : "put", query: nil, hits: index + 1,
                                    denied: index == 3 ? "not_authorized" : nil), rootDirectory: root)
        }
        let model = ManagementModel(settings: settings, registry: registry, tokenStore: tokens, store: store,
                                    switchWorkspace: { _ in store }, changeAPI: { settings.apiControlEnabled = $0 },
                                    apiIsRunning: { settings.apiControlEnabled }, authenticate: { _ in false })
        let controller = ManagementWindowController(model: model, interactive: false)
        controller.show(page: page)
        if let sheet {
            switch sheet {
            case "workspace": model.present(.workspace(nil))
            case "rename": model.present(.workspace(registry.activeID))
            case "limit": model.present(.limit)
            case "token": model.present(.token)
            case "secret":
                model.present(.token)
                model.createToken(name: "新程序", scopes: [.searchMeta, .searchText], days: 30)
            case "clear": model.requestClear()
            default: break
            }
        }
        if CommandLine.arguments.contains("--ui-error") {
            model.report("保存未完成。输入内容已保留，请检查数据目录后重试。", error: true)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let window = controller.window else { exit(1) }
        let target = window.attachedSheet ?? window
        var captured = false
        if CGPreflightScreenCaptureAccess() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(target.windowNumber), path]
            if (try? process.run()) != nil {
                process.waitUntilExit()
                captured = process.terminationStatus == 0
            }
        }
        if !captured, let view = target.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            target.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
            if let data = rep.representation(using: .png, properties: [:]) {
                captured = (try? data.write(to: URL(fileURLWithPath: path))) != nil
            }
        }
        window.orderOut(nil)
        guard captured else { print("[SETTINGS-CAPTURE] failed"); exit(1) }
        print("[SETTINGS-CAPTURE] \(page.rawValue) \(sheet ?? "page") → \(path)")
    }
}
