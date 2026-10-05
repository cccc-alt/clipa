import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
/// App lifecycle, menu bar, hotkey, workspaces.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var quickStripStorage: QuickStripController?
    var quickStrip: QuickStripController {
        if let quickStripStorage { return quickStripStorage }
        let created = QuickStripController(viewModel: PanelViewModel())
        quickStripStorage = created
        return created
    }
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var storeWarningMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var secureEraseMenuItem: NSMenuItem?
    private var historyLimitMenuItem: NSMenuItem?
    private var autoPauseMenuItem: NSMenuItem?

    private var ignoreRulesMenuItem: NSMenuItem?

    private var apiControlToggleMenuItem: NSMenuItem?
    private var autoPauseObserver: NSObjectProtocol?
    private var captureRejectedObserver: NSObjectProtocol?
    private var storeAvailabilityCancellable: AnyCancellable?

    private var didAnnounceStoreFailure = false

    private var settings: SettingsStore { .shared }

    func applicationWillTerminate(_ notification: Notification) {

        APITokenStore.shared.flushPendingUse()

        APIControlServer.shared.stop()

        if let database = ClipStore.shared.database {
            _ = try? DatabaseSync.run(database) { db in
                try await db.markSessionCleanShutdown()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        applyActiveWorkspaceAtLaunch()
        settings.workspaceHistoryLimitWriter = { id, value in
            MainActor.assumeIsolated {
                WorkspaceStore.shared.setHistoryLimit(value, for: id)
            }
        }
        applyActiveWorkspaceHistoryLimit()
        setupMainMenu()
        setupStatusItem()
        ActiveAppTracker.shared.start()
        setupMonitor()
        scheduleBackgroundReclassification()
        scheduleLegacyImageImport()
        scheduleImageStorageMigration()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            ClipStore.shared.sealPrivateImagesIfNeeded()
        }
        if settings.autoPausedByLimit {
            let underLimit =
                settings.historyLimit == 0
                || ClipStore.shared.items.count < settings.historyLimit
            if underLimit {
                settings.pauseRecording = false
                settings.autoPausedByLimit = false
                syncPauseState()
            }
        }
        setupHotkey()
        observeAutoPause()
        observeStoreHealth()

        removeLegacyExportSnapshotIfPresent()

        if settings.apiControlEnabled {
            APIControlServer.shared.start()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if let error = self.settings.reconcileLaunchAtLogin() {
                NSLog("Clipa launch-at-login sync: \(error)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if !self.settings.didOnboard {
                self.settings.didOnboard = true
                self.quickStrip.show()
            }
        }
    }

    private func scheduleBackgroundReclassification() {
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            for _ in 0..<12 {
                if Task.isCancelled { return }
                let changed = await ClipStore.shared
                    .reclassifyPendingAsync(limit: 200)
                guard changed else { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func scheduleLegacyImageImport() {
        Task { @MainActor in
            _ = await ClipStore.shared.importLegacyImagesAsync()
        }
    }

    private func scheduleImageStorageMigration() {
        Task { @MainActor in
            _ = await ClipStore.shared.migrateImagesToOwnTableAsync()
        }
    }

    private func observeAutoPause() {
        autoPauseObserver = NotificationCenter.default.addObserver(
            forName: ClipStore.autoPauseStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncPauseState()
                self.announceAutoPauseIfVisible()
            }
        }
    }

    @MainActor
    private func announceAutoPauseIfVisible() {
        guard quickStrip.isVisible else { return }
        if settings.autoPausedByLimit, settings.pauseRecording {
            quickStrip.viewModel.showToast(
                "历史已达上限 \(settings.historyLimit) 条，已停止记录；"
                    + "删除旧条目后会自动恢复"
            )
        } else if !settings.pauseRecording {
            quickStrip.viewModel.showToast("历史已低于上限，已恢复记录")
        }
    }

    private func observeStoreHealth() {
        observeStoreAvailability()
        captureRejectedObserver = NotificationCenter.default.addObserver(
            forName: ClipStore.captureRejectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshStatusIcon()
                self.quickStrip.viewModel.showToast(
                    StoreUnavailableCopy.captureRejected
                )
            }
        }
    }

    private func observeStoreAvailability() {
        storeAvailabilityCancellable = ClipStore.shared.$availability
            .receive(on: DispatchQueue.main)
            .sink { [weak self] availability in
                guard let self else { return }
                self.refreshStatusIcon()
                self.updateStoreWarningMenuItem()
                self.announceStoreFailureIfNeeded(availability)
            }
    }

    private func announceStoreFailureIfNeeded(
        _ availability: ClipStoreAvailability
    ) {
        guard case .unavailable(let reason, let detail) = availability,
              !didAnnounceStoreFailure else { return }
        didAnnounceStoreFailure = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = StoreUnavailableCopy.title
            alert.informativeText = [
                StoreUnavailableCopy.reassurance,
                StoreUnavailableCopy.detail(for: reason),
                StoreUnavailableCopy.writePaused,
                detail.isEmpty ? nil : "诊断信息：\(detail)"
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            alert.addButton(withTitle: StoreUnavailableCopy.openDirectory)
            alert.addButton(withTitle: "稍后")
            if self.presentAboveCustomWindows(alert) == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [ClipStore.shared.dataDirectory]
                )
            }
        }
    }

    private func updateStoreWarningMenuItem() {
        guard let storeWarningMenuItem else { return }
        if case .unavailable = ClipStore.shared.availability {
            storeWarningMenuItem.isHidden = false
        } else {
            storeWarningMenuItem.isHidden = true
        }
    }

    @objc private func revealDataDirectoryAction() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [ClipStore.shared.dataDirectory]
        )
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    private func setupMonitor() {
        ClipboardMonitor.shared.onCapture = { item, captureEpoch in
            Task { @MainActor in
                _ = await ClipStore.shared.acceptCaptured(
                    item,
                    captureEpoch: captureEpoch
                )
            }
        }
        ClipboardMonitor.shared.start()
    }

    private func setupHotkey() {
        let panelOK = GlobalHotkey.shared.register(spec: .panelToggle) { [weak self] in
            guard let self else { return }
            self.quickStrip.toggle()
        }
        if panelOK == nil {

            NSLog("Clipa panel hotkey (⌃⌘V) registration failed")
            quickStrip.viewModel.showToast(
                "⌃⌘V 注册失败（可能被其它应用占用），可点菜单栏图标打开面板"
            )
        }
    }

    private func applyActiveWorkspaceAtLaunch() {
        let registry = WorkspaceStore.shared
        let active = registry.activeWorkspace
        let directory = registry.baseDirectory(for: active)
        guard ClipStore.shared.dataDirectory.standardizedFileURL
                != directory.standardizedFileURL
        else { return }
        let store = ClipStore(baseDirectory: directory)
        guard store.database != nil else { return }
        ClipStore.replaceShared(with: store)
    }

    private func applyActiveWorkspaceHistoryLimit() {
        let registry = WorkspaceStore.shared
        let active = registry.activeWorkspace
        settings.adoptHistoryLimit(
            registry.storedHistoryLimit(for: active.id)
                ?? settings.globalHistoryLimit,
            scope: active.isDefault ? .global : .workspace(active.id)
        )

        ClipStore.shared.reconcileAutoPauseAfterHistoryChange()
    }

    @objc private func switchWorkspaceAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        activateWorkspace(id: id)
    }

    private func activateWorkspace(id: UUID, silent: Bool = false) {
        let registry = WorkspaceStore.shared
        guard id != registry.activeID,
              let descriptor = registry.workspaces.first(where: {
                  $0.id == id
              }) else { return }
        let directory = registry.baseDirectory(for: descriptor)

        ClipboardMonitor.shared.beginClearBarrier()
        let next = ClipStore(baseDirectory: directory)
        guard next.database != nil else {
            quickStrip.viewModel.showToast(
                "工作区「\(descriptor.name)」无法打开"
            )
            return
        }
        try? registry.setActive(id)
        ClipStore.replaceShared(with: next)
        replacePanelAfterWorkspaceSwitch()
        applyActiveWorkspaceHistoryLimit()

        reloadWorkspaceMenu()
        if !silent {
            quickStrip.viewModel.showToast(
                "已切换到工作区「\(descriptor.name)」"
            )
        }
    }

    private func replacePanelAfterWorkspaceSwitch() {

        quickStrip.viewModel.rebind(store: .shared)
        observeStoreAvailability()
        refreshStatusIcon()
        updateStoreWarningMenuItem()
    }

    @objc private func newWorkspaceAction() {
        let alert = NSAlert()
        alert.messageText = "新建工作区"
        alert.informativeText =
            "每个工作区有独立的剪贴板历史、图片与搜索索引；"
            + "敏感内容检测、忽略应用等设置仍然共用。"
        let field = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 240, height: 24)
        )
        field.placeholderString = "工作区名称"
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn,
              let created = try? WorkspaceStore.shared.createWorkspace(
                  named: field.stringValue,

                  historyLimit: settings.historyLimit
              ) else { return }
        activateWorkspace(id: created.id)
    }

    @objc private func renameWorkspaceAction() {
        let registry = WorkspaceStore.shared
        let active = registry.activeWorkspace
        let alert = NSAlert()
        alert.messageText = "重命名当前工作区"
        let field = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 240, height: 24)
        )
        field.stringValue = active.name
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? registry.rename(active.id, to: field.stringValue)
        reloadWorkspaceMenu()
        quickStrip.viewModel.showToast(
            "工作区已重命名为「\(registry.activeWorkspace.name)」"
        )
    }

    @objc private func deleteWorkspaceAction() {
        let registry = WorkspaceStore.shared
        let active = registry.activeWorkspace
        guard registry.canDeleteWorkspaces, !active.isDefault else {
            quickStrip.viewModel.showToast("默认工作区不能删除")
            return
        }
        let rows = ClipStore.shared.items.count
        let alert = NSAlert()
        alert.messageText = "删除工作区「\(active.name)」？"
        alert.informativeText =
            "该工作区有 \(rows) 条记录，整个文件夹会被移到废纸篓"
            + "（可在废纸篓里恢复）。其它工作区不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let fallback = registry.workspaces.first(where: {
            $0.id != active.id
        }) {
            activateWorkspace(id: fallback.id, silent: true)
        }
        try? registry.delete(active.id)
        reloadWorkspaceMenu()
        quickStrip.viewModel.showToast(
            "工作区「\(active.name)」已移到废纸篓"
        )
    }

    @objc private func revealWorkspaceAction() {
        let registry = WorkspaceStore.shared
        let directory = registry.baseDirectory(for: registry.activeWorkspace)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func reloadWorkspaceMenu() {
        guard let statusItem else { return }
        statusItem.menu = buildMenu()
    }

    private func manualSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        return submenu
    }

    private func workspaceMenuItem() -> NSMenuItem {
        let registry = WorkspaceStore.shared
        let root = NSMenuItem(title: "工作区", action: nil, keyEquivalent: "")
        let submenu = manualSubmenu()

        for (index, workspace) in registry.workspaces.enumerated() {
            let item = NSMenuItem(
                title: workspace.name,
                action: #selector(switchWorkspaceAction(_:)),
                keyEquivalent: index < 9 ? "\(index + 1)" : ""
            )
            if index < 9 {
                item.keyEquivalentModifierMask = [.command, .control]
            }
            item.target = self
            item.representedObject = workspace.id
            item.state = workspace.id == registry.activeID ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        let create = NSMenuItem(
            title: "新建工作区…",
            action: #selector(newWorkspaceAction),
            keyEquivalent: ""
        )
        create.target = self
        submenu.addItem(create)

        let rename = NSMenuItem(
            title: "重命名当前工作区…",
            action: #selector(renameWorkspaceAction),
            keyEquivalent: ""
        )
        rename.target = self
        submenu.addItem(rename)

        let remove = NSMenuItem(
            title: "删除当前工作区…",
            action: #selector(deleteWorkspaceAction),
            keyEquivalent: ""
        )
        remove.target = self
        remove.isEnabled = registry.canDeleteWorkspaces
            && !registry.activeWorkspace.isDefault
        submenu.addItem(remove)

        let reveal = NSMenuItem(
            title: "在访达中显示当前工作区",
            action: #selector(revealWorkspaceAction),
            keyEquivalent: ""
        )
        reveal.target = self
        submenu.addItem(reveal)

        root.submenu = submenu
        return root
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let symbol = NSImage(
                systemSymbolName: settings.pauseRecording ? "pause.circle" : "doc.on.clipboard",
                accessibilityDescription: "Clipa"
            )
            button.image = symbol
            button.imagePosition = .imageOnly
            button.toolTip = "Clipa剪切板"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let togglePanel = NSMenuItem(
            title: "打开剪贴板面板",
            action: #selector(togglePanelAction),
            keyEquivalent: ""
        )
        togglePanel.target = self
        menu.addItem(togglePanel)

        let storeWarning = NSMenuItem(
            title: "⚠︎ 数据库不可用（历史未删除）· 打开数据目录",
            action: #selector(revealDataDirectoryAction),
            keyEquivalent: ""
        )
        storeWarning.target = self
        storeWarning.isHidden = true
        storeWarningMenuItem = storeWarning
        menu.addItem(storeWarning)

        menu.addItem(.separator())

        menu.addItem(workspaceMenuItem())

        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: "暂停记录",
            action: #selector(togglePauseAction),
            keyEquivalent: ""
        )
        pause.target = self
        pauseMenuItem = pause
        menu.addItem(pause)

        let ignoreRules = NSMenuItem(
            title: "忽略与跳过",
            action: nil,
            keyEquivalent: ""
        )
        ignoreRules.submenu = manualSubmenu()
        ignoreRulesMenuItem = ignoreRules
        menu.addItem(ignoreRules)

        let apiMenu = NSMenuItem(
            title: "本地接口",
            action: nil,
            keyEquivalent: ""
        )
        let apiSubmenu = manualSubmenu()
        apiMenu.submenu = apiSubmenu

        let apiControlToggle = NSMenuItem(
            title: "开启控制面",
            action: #selector(toggleAPIControlAction),
            keyEquivalent: ""
        )
        apiControlToggle.target = self
        apiControlToggleMenuItem = apiControlToggle
        apiSubmenu.addItem(apiControlToggle)

        apiSubmenu.addItem(.separator())

        let apiTokenNew = NSMenuItem(
            title: "新建令牌…",
            action: #selector(newAPITokenAction),
            keyEquivalent: ""
        )
        apiTokenNew.target = self
        apiSubmenu.addItem(apiTokenNew)

        let apiTokens = NSMenuItem(
            title: "已授权程序…",
            action: #selector(showAPITokensAction),
            keyEquivalent: ""
        )
        apiTokens.target = self
        apiSubmenu.addItem(apiTokens)

        let apiAudit = NSMenuItem(
            title: "最近调用…",
            action: #selector(showAPIAuditAction),
            keyEquivalent: ""
        )
        apiAudit.target = self
        apiSubmenu.addItem(apiAudit)

        menu.addItem(apiMenu)

        let clear = NSMenuItem(
            title: "清空历史",
            action: nil,
            keyEquivalent: ""
        )
        let clearMenu = manualSubmenu()
        clear.submenu = clearMenu

        let clearHistoryItem = NSMenuItem(
            title: "清空历史…",
            action: #selector(clearHistoryAction),
            keyEquivalent: ""
        )
        clearHistoryItem.target = self
        clearMenu.addItem(clearHistoryItem)

        clearMenu.addItem(.separator())

        let historyLimitItem = NSMenuItem(
            title: Self.historyLimitMenuTitle(limit: settings.historyLimit),
            action: #selector(changeHistoryLimitAction),
            keyEquivalent: ""
        )
        historyLimitItem.target = self
        clearMenu.addItem(historyLimitItem)
        historyLimitMenuItem = historyLimitItem

        let autoPauseItem = NSMenuItem(
            title: "达到上限时自动暂停记录",
            action: #selector(toggleAutoPauseAtLimitAction),
            keyEquivalent: ""
        )
        autoPauseItem.target = self
        clearMenu.addItem(autoPauseItem)
        autoPauseMenuItem = autoPauseItem

        clearMenu.addItem(.separator())

        let secureErase = NSMenuItem(
            title: "清空时安全擦除（较慢）",
            action: #selector(toggleSecureEraseAction),
            keyEquivalent: ""
        )
        secureErase.target = self
        secureEraseMenuItem = secureErase
        clearMenu.addItem(secureErase)

        menu.addItem(clear)

        let rebuildIndex = NSMenuItem(
            title: "重建搜索索引…",
            action: #selector(rebuildSearchIndexAction),
            keyEquivalent: ""
        )
        rebuildIndex.target = self
        menu.addItem(rebuildIndex)

        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(
            title: "开机自启",
            action: #selector(toggleLaunchAtLoginAction),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLoginMenuItem = launchAtLogin
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 Clipa",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func togglePanelAction() {
        quickStrip.toggle()
    }

    @objc private func togglePauseAction() {
        settings.pauseRecording.toggle()
        settings.autoPausedByLimit = false
        refreshStatusIcon()
    }

    @objc private func ignoreResolvedAppAction(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        guard IgnoreTargetActions.add(bundleID: bundleID, to: settings) else {
            return
        }
        quickStrip.viewModel.showToast(
            "已忽略 \(AppIdentityCache.shared.displayName(for: bundleID))"
        )
    }

    private struct SkipRule {
        let title: String
        let help: String
        let action: Selector
        let flag: KeyPath<SettingsStore, Bool>
    }

    private static let skipRules: [SkipRule] = [

        SkipRule(
            title: "跳过标记为机密的复制内容",
            help: "来源应用自己在剪贴板上打的“不要记录”标记"
                + "（org.nspasteboard.ConcealedType / TransientType），"
                + "不依赖应用名单",
            action: #selector(toggleSkipConfidentialAction),
            flag: \.skipConfidentialPasteboard
        ),
        SkipRule(
            title: "跳过疑似敏感内容",
            help: "命中内置敏感判定（API Key / Token / 私钥）的内容不再记录；"
                + "关闭时仍会记录，只是卡片上带 🔐 标记",
            action: #selector(toggleSkipSensitiveAction),
            flag: \.skipSensitive
        ),
        SkipRule(
            title: "跳过密码管理器复制的内容",
            help: "内置名单：1Password、Bitwarden、KeePassXC、LastPass、"
                + "Dashlane、Passwords.app、钥匙串访问",
            action: #selector(toggleIgnorePasswordManagersAction),
            flag: \.ignorePasswordManagers
        )
    ]

    @discardableResult
    func presentAboveCustomWindows(_ alert: NSAlert) -> NSApplication.ModalResponse {
        alert.window.level = NSWindow.Level(
            rawValue: QuickStripController.overlayLevel.rawValue + 2
        )
        quickStrip.parkForOverlayAlert()
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        quickStrip.restoreAfterOverlayAlert()
        return response
    }

    func syncPauseState() {
        refreshStatusIcon()
    }

    @objc private func rebuildSearchIndexAction() {
        guard let database = ClipStore.shared.database else {
            quickStrip.viewModel.showToast("数据库不可用，无法重建索引")
            return
        }
        quickStrip.viewModel.showToast("正在重建搜索索引…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let started = Date()
            let failure: Error?
            do {
                try DatabaseSync.run(database) { db in
                    try await db.rebuildFTS()
                }
                failure = nil
            } catch {
                failure = error
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    self.quickStrip.viewModel.showToast(
                        "搜索索引重建失败：\(failure.localizedDescription)"
                    )
                } else {
                    self.quickStrip.viewModel.showToast(
                        "搜索索引已重建（\(elapsed) ms）"
                    )
                }
            }
        }
    }

    static func historyLimitMenuTitle(limit: Int) -> String {
        limit == 0 ? "历史条数上限：不限制" : "历史条数上限：\(limit) 条"
    }

    @objc private func changeHistoryLimitAction() {
        let store = ClipStore.shared
        let alert = NSAlert()
        alert.messageText = "历史条数上限"
        alert.informativeText =
            "历史最多保留这么多条，达到上限后停止记录新内容；"
            + "调低上限会立即删除较早的条目。填 0 表示不限制。"
        let field = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 160, height: 24)
        )
        field.stringValue = String(settings.historyLimit)
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        guard presentAboveCustomWindows(alert) == .alertFirstButtonReturn
        else { return }
        guard let value = Int(
            field.stringValue.trimmingCharacters(in: .whitespaces)
        ), value >= 0, value <= 1_000_000 else {
            quickStrip.viewModel.showToast("请输入 0–1000000 的数字（0 = 不限制）")
            return
        }

        if let excess = SettingsStore.historyLimitDeletionCount(
            current: settings.historyLimit,
            requested: value,
            rowCount: store.items.count
        ) {
            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = "将删除较早的 \(excess) 条历史？"
            confirm.informativeText = "新上限是 "
                + (value == 0 ? "不限制" : "\(value) 条")
                + "，超出的 \(excess) 条会立即删除，此操作无法撤销。"
            confirm.addButton(withTitle: "删除")
            confirm.addButton(withTitle: "取消")
            confirm.buttons.first?.hasDestructiveAction = true
            guard presentAboveCustomWindows(confirm)
                == .alertFirstButtonReturn else { return }
        }
        settings.historyLimit = value
        store.applyHistoryLimitNow()
        quickStrip.viewModel.showToast(
            value == 0
                ? "历史条数上限已改为不限制"
                : "历史条数上限已改为 \(value) 条"
        )
    }

    @objc private func toggleAutoPauseAtLimitAction() {
        settings.autoPauseAtLimit.toggle()
    }

    @objc private func clearHistoryAction() {
        let store = ClipStore.shared
        guard !store.isClearingHistory else {
            quickStrip.viewModel.showToast("正在清空历史，请稍候")
            return
        }
        let summary = store.clearSummary
        guard summary.removable > 0 else {
            quickStrip.viewModel.showToast("没有可清空的历史")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空 \(summary.removable) 条历史？"
        var info = "将删除 \(summary.removable) 条。"
        if summary.requiresAuthentication {
            info += "其中包含 \(summary.privateCount) 条私密内容，"
                + "删除前需要系统验证。"
        } else {
            info += "此操作无法撤销。"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        let response = presentAboveCustomWindows(alert)
        if response == .alertFirstButtonReturn {
            if summary.requiresAuthentication {
                PrivacyGate.shared.requestAuthentication(
                    reason: "验证后清空包含私密内容的历史"
                ) { [weak self] ok in
                    guard let self else { return }
                    guard ok else {
                        self.quickStrip.viewModel.showToast(
                            "未清空：需要系统验证"
                        )
                        return
                    }
                    self.performClearHistory()
                }
            } else {
                performClearHistory()
            }
        }
    }

    private func performClearHistory() {
        Task { @MainActor in
            let result = await ClipStore.shared.clearAllAsync()
            switch result {
            case .cleared(let deleted):
                quickStrip.viewModel.showToast("已清空 \(deleted) 条")
            case .busy:
                quickStrip.viewModel.showToast(
                    "正在清空历史，请稍候"
                )
            case .failed:
                quickStrip.viewModel.showToast(
                    "清空失败，请重试"
                )
            }
        }
    }

    @objc private func toggleLaunchAtLoginAction() {
        let enable = !settings.launchAtLogin
        guard let message = settings.setLaunchAtLogin(enable) else {
            quickStrip.viewModel.showToast(
                enable ? "已开启开机自启" : "已关闭开机自启"
            )
            return
        }
        let alert = NSAlert()
        alert.messageText = enable ? "开机自启未完成" : "关闭开机自启失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        presentAboveCustomWindows(alert)
    }

    @objc private func toggleSkipConfidentialAction() {
        settings.skipConfidentialPasteboard.toggle()
    }

    @objc private func toggleSkipSensitiveAction() {
        settings.skipSensitive.toggle()
    }

    private func removeLegacyExportSnapshotIfPresent() {
        let url = ClipStore.defaultBaseDirectory()
            .appendingPathComponent("api-export.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            NSLog("Clipa removed legacy api-export.json (M1 export removed)")
        } catch {
            NSLog(
                "Clipa failed to remove legacy api-export.json: "
                    + error.localizedDescription
            )
        }
    }

    @objc private func toggleAPIControlAction() {
        settings.apiControlEnabled.toggle()
        if settings.apiControlEnabled {
            APIControlServer.shared.start()
            APITokenStore.shared.reload()
            if let error = APIControlServer.shared.lastError {
                quickStrip.viewModel.showToast("控制面未能启动：\(error)")
            } else if APITokenStore.shared.tokens.isEmpty {
                quickStrip.viewModel.showToast(
                    "控制面已开启，但还没有令牌：先用「新建令牌…」发一个"
                )
            } else {
                quickStrip.viewModel.showToast(
                    "控制面已开启：本机 socket，按令牌作用域放行"
                )
            }
        } else {
            APIControlServer.shared.stop()
            quickStrip.viewModel.showToast("控制面已关闭")
        }
    }

    @objc private func newAPITokenAction() {
        let alert = NSAlert()
        alert.messageText = "新建令牌"
        alert.informativeText = """
        这张令牌给 Cursor、Codex 等 AI 工具（MCP 接入）或命令行脚本\
        （clipa 命令）用——勾得越少，它能看的越少。\
        勾「正文开头」会自动带上元信息查询。
        """
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 252))
        let labelField = NSTextField(
            frame: NSRect(x: 0, y: 224, width: 360, height: 24)
        )
        labelField.placeholderString = "名字（例如 Claude Code）"
        container.addSubview(labelField)

        func groupHeader(_ text: String, at y: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 0, y: y, width: 360, height: 16)
            label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            container.addSubview(label)
        }

        var scopeButtons: [(APIToken.Scope, NSButton)] = []

        let readScopes: [APIToken.Scope] = [.searchMeta, .searchText, .readFull]
        let writeScopes: [APIToken.Scope] = [.copy, .put, .note, .delete]
        var y: CGFloat = 192
        groupHeader("读取（从上到下，看得越来越多）", at: y)
        y -= 22
        for scope in readScopes {
            let button = NSButton(
                checkboxWithTitle: scope.title,
                target: nil,
                action: nil
            )
            button.frame = NSRect(x: 0, y: y, width: 360, height: 20)
            button.state = (scope == .searchMeta || scope == .searchText)
                ? .on : .off
            container.addSubview(button)
            scopeButtons.append((scope, button))
            y -= 22
        }
        y -= 4
        groupHeader("写入（每一项单独授权）", at: y)
        y -= 22
        for scope in writeScopes {
            let button = NSButton(
                checkboxWithTitle: scope.title,
                target: nil,
                action: nil
            )
            button.frame = NSRect(x: 0, y: y, width: 360, height: 20)
            container.addSubview(button)
            scopeButtons.append((scope, button))
            y -= 22
        }
        alert.accessoryView = container
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        guard presentAboveCustomWindows(alert) == .alertFirstButtonReturn else {
            return
        }
        let label = labelField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var scopes = Set(scopeButtons.filter { $0.1.state == .on }.map(\.0))

        if scopes.contains(.searchText) {
            scopes.insert(.searchMeta)
        }
        let ordered = APIToken.Scope.allCases.filter { scopes.contains($0) }
        do {
            let created = try APITokenStore.shared.create(
                label: label.isEmpty ? "未命名" : label,
                scopes: ordered
            )
            showTokenSecret(created.secret, label: created.token.label)
        } catch {
            quickStrip.viewModel.showToast(
                "令牌保存失败：\(error.localizedDescription)"
            )
        }
    }

    private func showTokenSecret(_ secret: String, label: String) {
        let alert = NSAlert()
        alert.messageText = "令牌「\(label)」已创建"
        alert.informativeText = "令牌只显示这一次，请立即复制保存。"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 66))
        let field = NSTextField(frame: NSRect(x: 0, y: 34, width: 360, height: 24))
        field.stringValue = secret
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        container.addSubview(field)

        pendingTokenSecretForCopy = secret
        tokenConfigCopyButtons = [:]
        let cursorButton = NSButton(
            title: "复制 Cursor 配置",
            target: self,
            action: #selector(copyCursorMCPConfigAction)
        )
        cursorButton.bezelStyle = .rounded
        cursorButton.controlSize = .small
        cursorButton.frame = NSRect(x: 0, y: 4, width: 170, height: 26)
        container.addSubview(cursorButton)
        tokenConfigCopyButtons["cursor"] = cursorButton

        let codexButton = NSButton(
            title: "复制 Codex 配置",
            target: self,
            action: #selector(copyCodexMCPConfigAction)
        )
        codexButton.bezelStyle = .rounded
        codexButton.controlSize = .small
        codexButton.frame = NSRect(x: 190, y: 4, width: 170, height: 26)
        container.addSubview(codexButton)
        tokenConfigCopyButtons["codex"] = codexButton

        alert.accessoryView = container
        alert.addButton(withTitle: "好")
        _ = presentAboveCustomWindows(alert)
        pendingTokenSecretForCopy = nil
        tokenConfigCopyButtons = [:]
    }

    private var pendingTokenSecretForCopy: String?
    private var tokenConfigCopyButtons: [String: NSButton] = [:]

    @objc private func copyCursorMCPConfigAction() {
        copyTokenConfig("cursor")
    }

    @objc private func copyCodexMCPConfigAction() {
        copyTokenConfig("codex")
    }

    private func copyTokenConfig(_ kind: String) {
        guard let secret = pendingTokenSecretForCopy else { return }
        let helper = Bundle.main.bundlePath + "/Contents/Helpers/clipa-mcp"
        let config = kind == "cursor"
            ? APIMcp.cursorConfig(token: secret, helperPath: helper)
            : APIMcp.codexConfig(token: secret, helperPath: helper)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(config, forType: .string)
        tokenConfigCopyButtons[kind]?.title = "已复制 ✓"
    }

    @objc private func showAPITokensAction() {
        APITokenStore.shared.reload()
        let tokens = APITokenStore.shared.tokens
        let alert = NSAlert()
        alert.messageText = tokens.isEmpty
            ? "还没有授权任何程序"
            : "已授权的程序"
        alert.informativeText = tokens.isEmpty
            ? "用「新建令牌…」给一个程序（或 Agent）发一个令牌。"
            : tokens.map { token in

                "\(token.label)（\(token.id)） · \(token.scopeList)"
                    + "\n    用过 \(token.callCount) 次"
                    + (
                        token.lastUsedAt.map {
                            "，最后 \(quickStrip.viewModel.relativeTime(for: $0))"
                        } ?? "，尚未使用"
                    )
            }.joined(separator: "\n")
        var popup: NSPopUpButton?
        if !tokens.isEmpty {
            let button = NSPopUpButton(
                frame: NSRect(x: 0, y: 0, width: 300, height: 25)
            )
            button.addItems(withTitles: tokens.map(\.displayName))
            alert.accessoryView = button
            popup = button
        }
        alert.addButton(withTitle: "撤销所选")
        alert.addButton(withTitle: "撤销全部")
        alert.addButton(withTitle: "关闭")
        switch presentAboveCustomWindows(alert) {
        case .alertFirstButtonReturn:
            guard let popup, popup.indexOfSelectedItem >= 0,
                  popup.indexOfSelectedItem < tokens.count else { return }
            let revoked = tokens[popup.indexOfSelectedItem]
            APITokenStore.shared.revoke(id: revoked.id)
            quickStrip.viewModel.showToast("已撤销令牌「\(revoked.displayName)」")
        case .alertSecondButtonReturn:
            APITokenStore.shared.revokeAll()
            quickStrip.viewModel.showToast("已撤销全部令牌")
        default:
            break
        }
    }

    @objc private func showAPIAuditAction() {
        let entries = APIAuditLog.recent(
            15,
            rootDirectory: ClipStore.defaultBaseDirectory()
        )
        let alert = NSAlert()
        alert.messageText = entries.isEmpty
            ? "还没有调用记录"
            : "最近调用（新在前）"
        alert.informativeText = entries.isEmpty
            ? "打开控制面并让程序调用之后，这里会列出"
                + "「谁、什么时候、做了什么」。审计里不含正文。"
            : entries.map { entry in
                let outcome = entry.denied.map { "被拒：\($0)" }
                    ?? "命中 \(entry.hits ?? 0)"
                let time = Self.auditTimeFormatter.string(from: entry.at)
                let token = entry.token == "-" ? "（未知令牌）" : entry.token
                return "\(time)  \(token)  \(entry.verb)  \(outcome)"
            }.joined(separator: "\n")
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "清空记录")
        if presentAboveCustomWindows(alert) == .alertSecondButtonReturn {
            APIAuditLog.clear(rootDirectory: ClipStore.defaultBaseDirectory())
            quickStrip.viewModel.showToast("调用记录已清空")
        }
    }

    private static let auditTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    @objc private func toggleSecureEraseAction() {
        settings.secureEraseHistoryOnClear.toggle()
    }

    @objc private func toggleIgnorePasswordManagersAction() {
        settings.ignorePasswordManagers.toggle()
    }

    @objc private func removeIgnoredAppAction(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        let before = settings.ignoredApps.count
        settings.ignoredApps.removeAll {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }
        guard settings.ignoredApps.count < before else { return }
        let name = AppIdentityCache.shared.displayName(for: bundleID)
        let notice = IgnoreListNotice.removal(
            name: name,
            stillAutoIgnored: settings.autoIgnoredApps.contains(bundleID)
        )
        quickStrip.viewModel.showToast(
            notice.isWarning ? "⚠︎ " + notice.text : notice.text
        )
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    func statusMenuSnapshot() -> NSMenu {
        let menu = buildMenu()
        menuWillOpen(menu)
        return menu
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let unavailable = !ClipStore.shared.availability.isReady
        button.image = NSImage(
            systemSymbolName: unavailable
                ? "exclamationmark.triangle"
                : (settings.pauseRecording ? "pause.circle" : "doc.on.clipboard"),
            accessibilityDescription: "Clipa"
        )
        button.toolTip = unavailable
            ? "Clipa：数据库不可用，历史数据未删除"
            : pauseToolTip()
        pauseMenuItem?.state = settings.pauseRecording ? .on : .off
    }

    private func pauseToolTip() -> String {
        if settings.pauseRecording, settings.autoPausedByLimit {
            return "Clipa：历史已达上限，已停止记录（腾出空间后自动恢复）"
        }
        if settings.pauseRecording {
            return "Clipa：已暂停记录"
        }
        return "Clipa：正在记录剪贴内容"
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if settings.pauseRecording, settings.autoPausedByLimit {
            pauseMenuItem?.title = "恢复记录（历史已达上限）"
        } else {
            pauseMenuItem?.title = settings.pauseRecording ? "恢复记录" : "暂停记录"
        }
        pauseMenuItem?.state = settings.pauseRecording ? .on : .off
        launchAtLoginMenuItem?.state = settings.launchAtLogin ? .on : .off
        secureEraseMenuItem?.state =
            settings.secureEraseHistoryOnClear ? .on : .off
        historyLimitMenuItem?.title =
            Self.historyLimitMenuTitle(limit: settings.historyLimit)
        autoPauseMenuItem?.state =
            settings.autoPauseAtLimit ? .on : .off
        apiControlToggleMenuItem?.state = settings.apiControlEnabled ? .on : .off
        rebuildIgnoreRulesSubmenu()
        updateStoreWarningMenuItem()
        refreshStatusIcon()
    }

    private func rebuildIgnoreRulesSubmenu() {
        guard let submenu = ignoreRulesMenuItem?.submenu else { return }
        submenu.removeAllItems()

        submenu.addItem(ignoreTargetItem())
        submenu.addItem(.separator())

        for rule in Self.skipRules {
            let item = NSMenuItem(
                title: rule.title,
                action: rule.action,
                keyEquivalent: ""
            )
            item.target = self
            item.state = settings[keyPath: rule.flag] ? .on : .off
            item.toolTip = rule.help
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        addIgnoredAppItems(to: submenu)
    }

    private func ignoreTargetItem() -> NSMenuItem {
        let presentation = IgnoreTargetPresentation.make(
            resolution: IgnoreTargetActions.currentTarget(),
            isAlreadyIgnored: settings.ignoredApps.contains
        )
        let item = NSMenuItem(
            title: presentation.title,
            action: #selector(ignoreResolvedAppAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = presentation.isEnabled
        item.representedObject = presentation.bundleID
        item.toolTip = presentation.toolTip
        return item
    }

    private func addIgnoredAppItems(to submenu: NSMenu) {
        guard !settings.ignoredApps.isEmpty else {
            let empty = NSMenuItem(
                title: "（还没有手动忽略的应用）",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }
        for bundleID in settings.ignoredApps {
            let item = NSMenuItem(
                title: "不再忽略 \(AppIdentityCache.shared.displayName(for: bundleID))",
                action: #selector(removeIgnoredAppAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = bundleID

            item.toolTip = bundleID
            submenu.addItem(item)
        }
    }
}
