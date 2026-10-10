import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    /// Clipa's one clipboard page: the floating panel (⌃⌘V).
    ///
    /// Built on first use instead of in `init`: `AppDelegate` itself is created
    /// before `applicationDidFinishLaunching`, so constructing the window in
    /// `init` used to hand it the default workspace's store before the launch
    /// code could pick the active one.
    private var quickStripStorage: QuickStripController?
    var quickStrip: QuickStripController {
        if let quickStripStorage { return quickStripStorage }
        let created = QuickStripController(viewModel: PanelViewModel())
        quickStripStorage = created
        return created
    }
    private var managementStorage: ManagementWindowController?
    private var onboardingStorage: OnboardingWindowController?
    private var runtimeStarted = false
    private var returnToSettingsAfterOnboarding = false
    private var management: ManagementWindowController {
        if let managementStorage { return managementStorage }
        let model = ManagementModel(
            settings: settings, registry: .shared, tokenStore: .shared, store: .shared,
            switchWorkspace: { [weak self] id in
                guard let self else { throw WorkflowError.message("应用正在退出。") }
                return try await self.performWorkspaceSwitch(id)
            },
            changeAPI: { [weak self] enabled in
                guard let self else { throw WorkflowError.message("应用正在退出。") }
                try self.setAPIEnabledChecked(enabled)
            },
            apiIsRunning: { APIControlServer.shared.isRunning }
        )
        model.onPreferencesChanged = { [weak self] in
            self?.refreshStatusIcon()
        }
        model.openClipboard = { [weak self] in
            self?.managementStorage?.window?.orderOut(nil)
            self?.quickStrip.show()
        }
        model.openOnboarding = { [weak self] in self?.showOnboarding(replaying: true) }
        let controller = ManagementWindowController(model: model)
        managementStorage = controller
        return controller
    }

    @discardableResult
    func showManagement(_ page: ManagementPage = .general, sheet: ManagementSheet? = nil) -> Bool {
        guard runtimeStarted else { showOnboarding(); return false }
        if let vm = quickStripStorage?.viewModel,
           vm.noteIsSaving || vm.copyingID != nil || vm.privateUnlockInFlight {
            vm.showToast("请等待当前保存、复制或身份验证完成")
            return false
        }
        quickStripStorage?.hide(restoreFocus: false)
        if onboardingStorage?.window?.isVisible == true {
            onboardingStorage?.window?.makeKeyAndOrderFront(nil)
            return false
        }
        let controller = management
        if controller.model.sheet != nil {
            controller.show(page: controller.model.page)
            return false
        }
        controller.show(page: page)
        if let sheet { controller.model.present(sheet) }
        return true
    }

    func retryHistoryFromPanel() {
        guard showManagement(.history) else { return }
        management.model.retryStore()
    }

    private func toggleClipboardPanel() {
        guard runtimeStarted else { showOnboarding(); return }
        if onboardingStorage?.window?.isVisible == true {
            onboardingStorage?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let controller = managementStorage, controller.model.sheet != nil {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        quickStrip.toggle()
    }

    @objc private func closeCurrentWindowAction() {
        if let guide = onboardingStorage, NSApp.keyWindow == guide.window {
            guide.window?.performClose(nil)
        } else if let center = managementStorage, center.window?.isVisible == true,
           NSApp.keyWindow == center.window || NSApp.keyWindow?.sheetParent == center.window {
            if center.model.sheet != nil {
                if center.model.preventsDismissal {
                    center.model.sheetError = "请先完成当前操作，或保存、撤销尚未保存的令牌。"
                } else { center.model.dismissSheet() }
            } else { center.window?.performClose(nil) }
        } else if quickStripStorage?.isVisible == true { quickStrip.hide() }
        else { NSApp.keyWindow?.performClose(nil) }
    }

    @objc private func showSettingsAction() { showManagement() }

    private func showOnboarding(replaying: Bool = false) {
        if let center = managementStorage, center.model.sheet != nil || center.model.isBusy {
            center.show(page: center.model.page)
            return
        }
        if let vm = quickStripStorage?.viewModel,
           vm.noteIsSaving || vm.copyingID != nil || vm.privateUnlockInFlight {
            vm.showToast("请等待当前操作完成后再打开新手引导")
            return
        }
        if onboardingStorage == nil {
            let controller = OnboardingWindowController(model: OnboardingModel(settings: settings))
            controller.onFinish = { [weak self] showClipboard in
                // Let the welcome window close before the first database/keychain access.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if !self.runtimeStarted { self.startRuntime() }
                    self.refreshStatusIcon()
                    if showClipboard {
                        if ClipStore.shared.availability.isReady { self.quickStrip.show() }
                        else { self.showManagement(.history) }
                    } else if self.returnToSettingsAfterOnboarding {
                        self.management.show(page: .general)
                    }
                }
            }
            onboardingStorage = controller
        }
        if onboardingStorage?.window?.isVisible != true {
            returnToSettingsAfterOnboarding = managementStorage?.window?.isVisible == true
            managementStorage?.window?.orderOut(nil)
            quickStripStorage?.hide(restoreFocus: false)
        }
        onboardingStorage?.show(replaying: replaying)
    }

    private func setAPIEnabledChecked(_ enabled: Bool) throws {
        if enabled {
            APIControlServer.shared.start(store: .shared, settings: settings)
            guard APIControlServer.shared.isRunning else {
                settings.apiControlEnabled = false
                throw WorkflowError.message(APIControlServer.shared.lastError ?? "本地接口无法启动，请重试。")
            }
            settings.apiControlEnabled = true
        } else {
            settings.apiControlEnabled = false
            APIControlServer.shared.stop()
        }
    }

    private func performWorkspaceSwitch(_ id: UUID) async throws -> ClipStore {
        let registry = WorkspaceStore.shared
        if let vm = quickStripStorage?.viewModel,
           vm.noteIsSaving || vm.copyingID != nil || vm.privateUnlockInFlight {
            throw WorkflowError.message("请等待当前保存、复制或身份验证完成后再切换工作区。")
        }
        guard let descriptor = registry.workspaces.first(where: { $0.id == id }) else {
            throw WorkflowError.message("工作区已不存在，请刷新后重试。")
        }
        let current = ClipStore.shared
        guard !current.isClearingHistory else { throw WorkflowError.message("历史正在清空，请完成后再切换。") }
        if id == registry.activeID, current.availability.isReady { return current }
        let directory = registry.baseDirectory(for: descriptor)
        guard descriptor.isDefault || FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkflowError.message("工作区目录不存在。请从废纸篓恢复，或切换到其他工作区。")
        }
        if id == registry.activeID, let stale = current.database { await stale.invalidate() }
        let next = await BackgroundStoreLoader.open(directory: directory, settings: settings)
        guard next.availability.isReady else {
            throw WorkflowError.message("无法打开「\(descriptor.name)」。请检查钥匙串与数据目录后重试；当前工作区未改变。")
        }
        try registry.setActive(id)
        ClipboardMonitor.shared.beginClearBarrier()
        ClipStore.replaceShared(with: next)
        APIControlServer.shared.rebind(store: next)
        applyActiveWorkspaceHistoryLimit()
        replacePanelAfterWorkspaceSwitch()
        managementStorage?.model.rebind(next)
        return next
    }

    private var statusItem: NSStatusItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var autoPauseObserver: NSObjectProtocol?
    private var captureRejectedObserver: NSObjectProtocol?
    private var storeAvailabilityCancellable: AnyCancellable?
    /// One alert per launch: the first failure is worth interrupting for, a
    /// repeated one is not.
    private var didAnnounceStoreFailure = false

    private let settings: SettingsStore

    override init() {
        settings = .shared
        super.init()
    }

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let center = managementStorage, center.model.preventsDismissal {
            center.show(page: center.model.page)
            center.model.report(center.model.issuedToken == nil ? "操作尚未完成，请稍候再退出。" : "请先保存令牌或撤销授权，再退出应用。", error: true)
            return .terminateCancel
        }
        if let vm = quickStripStorage?.viewModel {
            if vm.noteIsSaving || vm.copyingID != nil || vm.privateUnlockInFlight {
                quickStrip.show()
                vm.showToast("请等待保存、复制或验证完成后再退出")
                return .terminateCancel
            }
            if vm.hasAnyNoteDrafts {
                let alert = NSAlert()
                alert.messageText = "有未保存的备注草稿"
                alert.informativeText = "草稿只保留在当前运行期间。退出后无法恢复，已有历史不会改变。"
                alert.addButton(withTitle: "返回编辑")
                alert.addButton(withTitle: "放弃草稿并退出")
                alert.buttons.last?.hasDestructiveAction = true
                guard presentAboveCustomWindows(alert) == .alertSecondButtonReturn else {
                    quickStrip.show()
                    vm.resumeNoteDraft()
                    return .terminateCancel
                }
                vm.discardAllNoteDrafts()
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting the guide must never initialize the encrypted store.
        guard runtimeStarted else { return }
        // 使用统计的落盘节流（2026-10-03）需要退出补写，否则最多丢 30 秒计数。
        APITokenStore.shared.flushPendingUse()
        // 退出时把 socket 删掉：留一个"看起来还在"的地址，客户端会连一个没人接的
        // socket，报错信息也说不清是"没开"还是"应用没了"。
        APIControlServer.shared.stop()
        // Lets the next launch tell a clean exit from a crash, so an unclean
        // one can trigger the full FTS index verification.
        if let database = ClipStore.shared.database {
            _ = try? DatabaseSync.run(database) { db in
                try await db.markSessionCleanShutdown()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        if settings.onboardingCompletedVersion < OnboardingModel.currentVersion {
            showOnboarding()
        } else {
            startRuntime()
        }
    }

    private func startRuntime() {
        guard !runtimeStarted else { return }
        applyActiveWorkspaceAtLaunch()
        runtimeStarted = true
        settings.workspaceHistoryLimitWriter = { id, value in
            MainActor.assumeIsolated {
                WorkspaceStore.shared.setHistoryLimit(value, for: id)
            }
        }
        applyActiveWorkspaceHistoryLimit()
        ActiveAppTracker.shared.start()
        setupMonitor()
        scheduleBackgroundReclassification()
        scheduleLegacyImageImport()
        scheduleImageStorageMigration()
        // 私密图片补加密（2026-10-02）：加密引入前"设为私密"的条目，图片是
        // 明文落盘的——启动后台改写一次；失败只记日志，下次启动重试。
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
        // M1「只读导出」已于 2026-09-26 移除，但盘上可能还留着一份旧快照（明文，
        // 任何同 uid 进程都能读、不需要令牌、也不进审计）。删功能却把数据留在盘上，
        // 等于"关了但没关" —— 所以启动时清掉它。
        removeLegacyExportSnapshotIfPresent()
        // 控制面：只在开关打开时监听（默认关闭）。
        if settings.apiControlEnabled {
            APIControlServer.shared.start()
        }


        // Re-register the login item if the stored preference says it should
        // be on but the system record was never created (or was lost).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if let error = self.settings.reconcileLaunchAtLogin() {
                NSLog("Clipa launch-at-login sync: \(error)")
            }
        }

    }

    /// Reclassifies old rows in small batches shortly after launch. A row with
    /// a manual tag is skipped; interrupted runs resume on the next launch.
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

    /// v6 image files are imported into `image_blob` after launch instead of
    /// during database open, so a large legacy library never delays startup.
    private func scheduleLegacyImageImport() {
        Task { @MainActor in
            _ = await ClipStore.shared.importLegacyImagesAsync()
        }
    }

    /// v10 moves image bytes out of `clips` after launch: the move can involve
    /// gigabytes of blobs, and the whole-file compaction that follows it is
    /// not something startup should wait for.
    private func scheduleImageStorageMigration() {
        Task { @MainActor in
            _ = await ClipStore.shared.migrateImagesToOwnTableAsync()
        }
    }

    /// Keeps the menu-bar pause icon in sync when the history limit triggers
    /// the automatic pause.
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

    /// Explains an automatic pause (and its end) in the panel. The menu-bar
    /// tooltip and menu title carry the same information when the panel is
    /// closed, so a paused Clipa is never silent about why.
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

    /// Surfaces an unusable store instead of letting it look like an empty
    /// history: the menu-bar icon warns, the first launch explains, and the
    /// first dropped copy explains itself once.
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

    /// Split out because a workspace switch re-binds this to the new store
    /// while the notification observer above stays registered exactly once.
    private func observeStoreAvailability() {
        storeAvailabilityCancellable = ClipStore.shared.$availability
            .receive(on: DispatchQueue.main)
            .sink { [weak self] availability in
                guard let self else { return }
                self.refreshStatusIcon()
                self.announceStoreFailureIfNeeded(availability)
            }
    }

    private func announceStoreFailureIfNeeded(_ availability: ClipStoreAvailability) {
        if availability.isReady { didAnnounceStoreFailure = false; return }
        guard !didAnnounceStoreFailure else { return }
        didAnnounceStoreFailure = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !ClipStore.shared.availability.isReady else { return }
            self.showManagement(.history)
            self.management.model.report("历史暂时不可用。请在此重新连接，或检查数据目录。现有文件不会被清空。", error: true)
        }
    }

    // MARK: - Setup

    /// Menu-bar utilities have no visible main menu, but AppKit still routes
    /// editing key equivalents (⌘V / ⌘C / ⌘X / ⌘A / ⌘Z) through the main menu.
    /// Without it, paste/copy in any text field (API Key, search, notes) is a
    /// no-op even when the field has focus.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Clipa")
        applicationItem.submenu = applicationMenu
        let preferences = NSMenuItem(title: "设置…", action: #selector(showSettingsAction), keyEquivalent: ",")
        preferences.target = self
        applicationMenu.addItem(preferences)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Clipa", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        applicationMenu.addItem(quit)
        mainMenu.addItem(applicationItem)

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

        let windowMenu = NSMenu(title: "窗口")
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        let closeItem = NSMenuItem(title: "关闭窗口", action: #selector(closeCurrentWindowAction), keyEquivalent: "w")
        closeItem.target = self
        windowMenu.addItem(closeItem)
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
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
            self.toggleClipboardPanel()
        }
        if panelOK == nil {
            // Used to be a log line only: the hotkey simply did nothing, the
            // settings page still advertised it, and the user had no way to
            // learn that another app was holding the combination — or that the
            // menu bar icon still opens the panel.
            NSLog("Clipa panel hotkey (⌃⌘V) registration failed")
            quickStrip.viewModel.showToast(
                "⌃⌘V 注册失败（可能被其它应用占用），可点菜单栏图标打开面板"
            )
        }
    }

    // MARK: - Workspaces

    /// Makes sure `ClipStore.shared` points at the workspace the registry
    /// marked active.
    ///
    /// `ClipStore.shared` resolves the active workspace itself
    /// (`WorkspaceStore.activeBaseDirectoryOnDisk`), so this is normally a
    /// no-op. It still runs as a safety net: with an unreadable registry, or
    /// one that changed between the store being built and this call, the store
    /// can still be pointing at the wrong directory, and everything downstream
    /// (capture, search, the panel) must not.
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

    /// Points the live history limit at the active workspace's own value.
    ///
    /// Each workspace stores its own limit, so this runs at launch and after
    /// every switch. The default workspace keeps using the shared
    /// `UserDefaults` value — an existing install, and an older build, both
    /// see exactly what they saw before.
    private func applyActiveWorkspaceHistoryLimit() {
        let registry = WorkspaceStore.shared
        let active = registry.activeWorkspace
        settings.adoptHistoryLimit(
            registry.storedHistoryLimit(for: active.id)
                ?? settings.globalHistoryLimit,
            scope: active.isDefault ? .global : .workspace(active.id)
        )
        // A pause the *previous* workspace's limit started has to be
        // re-checked against this one: landing somewhere with room should keep
        // recording, and a pause the user asked for is left alone.
        ClipStore.shared.reconcileAutoPauseAfterHistoryChange()
    }

    /// The popup's view model and the availability subscription both captured
    /// the previous store.
    ///
    /// The window itself is kept: SwiftUI keeps its hosting view alive for the
    /// lifetime of the process, so building a second window would leave the
    /// previous workspace's history (103k rows ≈ 283MB) resident forever —
    /// measured with `heap`, which showed two live panels and two stores in a
    /// session whose active workspace was empty.
    private func replacePanelAfterWorkspaceSwitch() {
        // The page has to be pointed at the store the switch just installed.
        // Everything else here follows `ClipStore.shared` per use, but the view
        // model captured its store when the panel was first built and the panel
        // is deliberately reused (see the note above), so without this the page
        // keeps rendering — and editing — the workspace the user just left.
        // `PanelViewModel` also subscribes to `sharedReplacedNotification`, so
        // this call is explicit intent rather than the only thing keeping the
        // panel correct.
        quickStrip.viewModel.rebind(store: .shared)
        observeStoreAvailability()
        refreshStatusIcon()
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

    private func menuAction(
        _ title: String, symbol: String,
        action: Selector? = nil, shortcut: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
        item.target = self
        setMenuSymbol(symbol, on: item)
        return item
    }

    private func setMenuSymbol(_ symbol: String, on item: NSMenuItem) {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        item.image?.isTemplate = true
    }

    /// The status menu contains only daily entry points. Management lives in Settings.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 220
        menu.delegate = self

        // Describe the global shortcut without registering it twice.
        let open = menuAction("打开剪贴板", symbol: "list.clipboard", action: #selector(togglePanelAction))
        if #available(macOS 14.4, *) { open.subtitle = "⌃⌘V" }
        menu.addItem(open)
        menu.addItem(.separator())

        let launch = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLoginAction), keyEquivalent: "")
        launch.target = self
        launch.state = settings.launchAtLogin ? .on : .off
        launchAtLoginMenuItem = launch
        menu.addItem(launch)
        menu.addItem(menuAction("设置…", symbol: "gearshape", action: #selector(showSettingsAction), shortcut: ","))
        menu.addItem(menuAction("关于 Clipa…", symbol: "info.circle", action: #selector(showAboutAction)))
        menu.addItem(.separator())
        menu.addItem(menuAction("退出 Clipa", symbol: "power", action: #selector(quitAction), shortcut: "q"))
        return menu
    }

    @objc private func showAboutAction() {
        quickStripStorage?.hide(restoreFocus: false)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Clipa",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版",
            .credits: NSAttributedString(string: "轻巧的剪贴板历史工具\n文本、图片与文件，仅保存在本机。")
        ])
    }

    // MARK: - Actions

    @objc private func togglePanelAction() { toggleClipboardPanel() }

    /// Runs a modal alert above Clipa's own raised windows.
    ///
    /// The clipboard popup sits at `.statusBar` and the settings window one
    /// level above it while Clipa is active, so a default-level alert would be
    /// covered by whichever is on screen.
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

    /// Keep the status-bar icon in sync when pause state is toggled from the
    /// popup instead of the status-bar menu.
    func syncPauseState() {
        refreshStatusIcon()
    }

    /// Registers or unregisters the login item.
    ///
    /// The system can answer with "needs approval" or refuse outright (the app
    /// has to live in /Applications), and a silent no-op would look like a
    /// broken switch — so the outcome is always surfaced.
    @objc private func toggleLaunchAtLoginAction() {
        if !runtimeStarted || onboardingStorage?.window?.isVisible == true {
            showOnboarding()
            onboardingStorage?.model.navigate(to: .ready)
            return
        }
        let controller = management
        controller.model.setLaunchAtLogin(!settings.launchAtLogin)
        if controller.model.notice?.isError == true { showManagement(.general) }
    }

    /// 删掉 M1 时代留在盘上的导出快照（只读接口已于 2026-09-26 移除）。
    ///
    /// 不做这件事的话，"删掉的功能"会以一份 0600 明文 JSON 的形式继续躺在
    /// `~/Library/Application Support/Clipa/api-export.json` —— 读得到它的人不需要令牌、
    /// 也不会在审计里留下痕迹，正好抵消掉"控制面成为唯一合法读数路径"。
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

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    /// The live status menu, refreshed as it is when opened. Used by UI checks.
    func statusMenuSnapshot() -> NSMenu {
        let menu = buildMenu()
        menuWillOpen(menu)
        return menu
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        guard runtimeStarted else {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipa")
            button.toolTip = "Clipa：完成新手引导后开始使用"
            return
        }
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
    }

    /// Why recording is (not) running. An automatic pause has to be
    /// distinguishable from one the user asked for.
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
        launchAtLoginMenuItem?.state = settings.launchAtLogin ? .on : .off
        refreshStatusIcon()
    }
}
