import AppKit
import Combine
import Foundation

enum ManagementPage: String, CaseIterable, Identifiable {
    case general, workspaces, privacy, history, integrations, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .workspaces: return "工作区"
        case .privacy: return "隐私与过滤"
        case .history: return "历史与存储"
        case .integrations: return "应用集成"
        case .activity: return "调用记录"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .workspaces: return "square.stack.3d.up"
        case .privacy: return "hand.raised"
        case .history: return "internaldrive"
        case .integrations: return "puzzlepiece.extension"
        case .activity: return "clock.arrow.circlepath"
        }
    }
    var detail: String {
        switch self {
        case .general: return "记录、启动与日常使用"
        case .workspaces: return "为不同场景保留独立的剪贴板历史"
        case .privacy: return "决定哪些内容可以进入历史"
        case .history: return "管理当前工作区的容量与数据状态"
        case .integrations: return "控制其他本机程序的访问权限"
        case .activity: return "查看哪个程序在何时使用了本地接口"
        }
    }
}

struct ManagementNotice {
    let message: String
    var isError = false
}

struct ManagementConfirmation {
    enum Action {
        case clearHistory(UUID)
        case limit(UUID, Int)
        case deleteWorkspace(UUID)
        case revoke(String)
        case revokeAll
        case clearAudit
    }
    let title: String
    let detail: String
    let button: String
    let action: Action
}

enum ManagementSheet {
    case workspace(UUID?)
    case limit
    case token
    case secret
    case confirmation(ManagementConfirmation)
}

enum WorkflowError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

enum WorkflowValidation {
    static func workspaceName(_ input: String, existing: [WorkspaceDescriptor], excluding: UUID? = nil) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "请输入工作区名称。" }
        if name.count > 40 { return "名称最多 40 个字。" }
        if name.rangeOfCharacter(from: .controlCharacters) != nil { return "名称不能包含换行或控制字符。" }
        if existing.contains(where: { $0.id != excluding && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return "已有同名工作区，请换一个名称。"
        }
        return nil
    }

    static func historyLimit(_ input: String) -> Int? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let limit = Int(value), (1...1_000_000).contains(limit) else { return nil }
        return limit
    }

    static func tokenName(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "请输入使用此令牌的程序名称。" }
        if name.count > 60 { return "名称最多 60 个字。" }
        if name.rangeOfCharacter(from: .controlCharacters) != nil { return "名称不能包含换行或控制字符。" }
        return nil
    }
}

/// One coordinator for every settings workflow. UI state changes only after
/// successful persistence; confirmations carry the workspace they describe.
@MainActor
final class ManagementModel: ObservableObject {
    let settings: SettingsStore
    let registry: WorkspaceStore
    let tokenStore: APITokenStore
    @Published private(set) var store: ClipStore
    @Published var page: ManagementPage = .general {
        didSet { if page != oldValue { notice = nil } }
    }
    @Published var sheet: ManagementSheet?
    @Published var notice: ManagementNotice?
    @Published var sheetError: String?
    @Published private(set) var busy: String?
    @Published private(set) var audit: [APIAuditLog.Entry] = []
    @Published private(set) var auditError: String?
    @Published var auditQuery = ""
    @Published var auditDeniedOnly = false
    @Published var ignoredQuery = ""
    @Published private(set) var issuedToken: (token: APIToken, secret: String)?
    @Published var secretRevealed = false
    @Published var secretSaved = false
    @Published var copyFeedback: String?

    let switchWorkspace: (UUID) async throws -> ClipStore
    let changeAPI: (Bool) throws -> Void
    let apiIsRunning: () -> Bool
    let authenticate: (String) async -> Bool
    var onPreferencesChanged: () -> Void = {}
    var openClipboard: () -> Void = {}
    var openOnboarding: () -> Void = {}
    private var subscriptions = Set<AnyCancellable>()
    private var storeSubscription: AnyCancellable?

    init(settings: SettingsStore, registry: WorkspaceStore, tokenStore: APITokenStore,
         store: ClipStore, switchWorkspace: @escaping (UUID) async throws -> ClipStore,
         changeAPI: @escaping (Bool) throws -> Void, apiIsRunning: @escaping () -> Bool,
         authenticate: @escaping (String) async -> Bool = { reason in
             await withCheckedContinuation { completion in
                 PrivacyGate.shared.requestAuthentication(reason: reason) { completion.resume(returning: $0) }
             }
         }) {
        self.settings = settings
        self.registry = registry
        self.tokenStore = tokenStore
        self.store = store
        self.switchWorkspace = switchWorkspace
        self.changeAPI = changeAPI
        self.apiIsRunning = apiIsRunning
        self.authenticate = authenticate
        for publisher in [settings.objectWillChange.eraseToAnyPublisher(),
                          registry.objectWillChange.eraseToAnyPublisher(),
                          tokenStore.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        bindStore()
    }

    var isBusy: Bool { busy != nil }
    var preventsDismissal: Bool { isBusy || issuedToken != nil }
    var workspaceName: String { registry.activeWorkspace.name }
    var storeError: String? {
        guard case .unavailable(_, let detail) = store.availability else { return nil }
        return detail.isEmpty ? "历史暂时无法读取，请重试或检查数据目录。" : detail
    }

    func rebind(_ next: ClipStore) {
        guard store !== next else { return }
        storeSubscription = nil
        store = next
        bindStore()
    }
    private func bindStore() {
        storeSubscription = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func refresh() {
        tokenStore.reload()
        refreshAudit()
        objectWillChange.send()
    }

    func present(_ value: ManagementSheet) {
        guard !preventsDismissal else { return }
        sheetError = nil
        sheet = value
    }

    func dismissSheet() {
        guard !preventsDismissal else { return }
        sheet = nil
        sheetError = nil
    }

    func report(_ message: String, error: Bool = false) {
        notice = ManagementNotice(message: message, isError: error)
        if error, sheet != nil { sheetError = message }
    }

    /// The busy state is set before scheduling, so a rapid second click cannot
    /// enqueue a duplicate operation. Errors remain visible until addressed.
    func run(_ label: String, operation: @escaping () async throws -> Void) {
        guard !isBusy, issuedToken == nil else { return }
        busy = label
        sheetError = nil
        Task { @MainActor in
            defer { self.busy = nil; self.onPreferencesChanged() }
            do { try await operation() }
            catch { self.report(error.localizedDescription, error: true) }
        }
    }

    func setRecording(_ enabled: Bool) {
        settings.autoPausedByLimit = false
        settings.pauseRecording = !enabled
        onPreferencesChanged()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if let message = settings.setLaunchAtLogin(enabled) { report(message, error: true) }
        else { report(enabled ? "已开启登录时启动。" : "已关闭登录时启动。") }
        onPreferencesChanged()
    }

    func setAPIEnabled(_ enabled: Bool) {
        do {
            try changeAPI(enabled)
            report(enabled ? "本地接口已开启。请为需要访问的程序创建令牌。" : "本地接口已关闭，现有令牌已停止访问。")
        } catch { report(error.localizedDescription, error: true) }
        onPreferencesChanged()
    }

    func saveWorkspace(name: String, editing id: UUID?, activate: Bool) {
        if let error = WorkflowValidation.workspaceName(name, existing: registry.workspaces, excluding: id) {
            sheetError = error
            return
        }
        run(id == nil ? "正在创建工作区…" : "正在保存名称…") {
            if let id {
                try self.registry.rename(id, to: name)
                self.report("工作区名称已保存。")
            } else {
                let created = try self.registry.createWorkspace(named: name, historyLimit: self.settings.historyLimit)
                if activate {
                    do { self.rebind(try await self.switchWorkspace(created.id)) }
                    catch {
                        self.sheet = nil
                        throw WorkflowError.message("工作区已创建，但未能切换。请在列表中重试。\(error.localizedDescription)")
                    }
                }
                self.report("已创建工作区「\(created.name)」。")
            }
            self.sheet = nil
        }
    }

    func activate(_ id: UUID) {
        guard id != registry.activeID, sheet == nil, !preventsDismissal else { return }
        run("正在切换工作区…") {
            self.rebind(try await self.switchWorkspace(id))
            self.report("已切换到「\(self.workspaceName)」。")
        }
    }

    func requestDeleteWorkspace(_ workspace: WorkspaceDescriptor) {
        guard !workspace.isDefault else { return }
        present(.confirmation(ManagementConfirmation(
            title: "将「\(workspace.name)」移到废纸篓？",
            detail: "该工作区的全部历史和图片会一起移入废纸篓，可从访达恢复。其他工作区不受影响。"
                + (workspace.id == registry.activeID ? "将先切换到默认工作区。" : ""),
            button: "移到废纸篓", action: .deleteWorkspace(workspace.id))))
    }

    func requestLimit(_ limit: Int) {
        guard store.availability.isReady else { sheetError = "请先恢复数据库连接，再调整历史上限。"; return }
        guard (0...1_000_000).contains(limit) else { sheetError = "请输入有效上限。"; return }
        let excess = limit == 0 ? 0 : max(0, store.items.count - limit)
        if excess > 0 {
            sheet = .confirmation(ManagementConfirmation(
                title: "从「\(workspaceName)」删除较早的 \(excess) 条历史？",
                detail: "新上限为 \(limit) 条。超出的历史会立即删除，无法撤销。若其中有私密内容，需要系统验证。",
                button: "删除并应用上限", action: .limit(registry.activeID, limit)))
        } else {
            run("正在保存历史上限…") {
                try await self.applyLimit(limit)
                self.sheet = nil
            }
        }
    }

    private func applyLimit(_ limit: Int) async throws {
        let oldLimit = settings.historyLimit
        let active = registry.activeWorkspace
        // Persist the scoped preference before destructive work; a failed write
        // must not delete history while pretending that the limit was saved.
        if !active.isDefault { try registry.setHistoryLimitChecked(limit, for: active.id) }
        settings.historyLimit = limit
        let result = await store.trimHistory(to: limit)
        guard case .deleted(let count) = result else {
            if !active.isDefault {
                do { try registry.setHistoryLimitChecked(oldLimit, for: active.id) }
                catch {
                    throw WorkflowError.message("历史清理未完成，且无法恢复之前的上限。当前上限仍为 \(limit) 条，请检查存储状态后重试。")
                }
            }
            settings.historyLimit = oldLimit
            throw WorkflowError.message("未能应用上限，设置已恢复。请检查数据库状态后重试。")
        }
        store.reconcileAutoPauseAfterHistoryChange()
        report(count > 0 ? "上限已保存，已删除较早的 \(count) 条历史。" : "历史上限已保存。")
    }

    func requestClear() {
        guard store.availability.isReady else { report("请先恢复数据库连接。", error: true); return }
        guard !store.items.isEmpty else { report("当前工作区没有需要清空的历史。"); return }
        let summary = store.clearSummary
        present(.confirmation(ManagementConfirmation(
            title: "清空「\(workspaceName)」的 \(summary.removable) 条历史？",
            detail: "正文、备注与图片都会被删除，无法撤销。其他工作区不受影响。"
                + (summary.requiresAuthentication ? "包含 \(summary.privateCount) 条私密内容，下一步需要系统验证。" : ""),
            button: "清空此工作区", action: .clearHistory(registry.activeID))))
    }

    func execute(_ confirmation: ManagementConfirmation) {
        run("正在处理，请稍候…") {
            switch confirmation.action {
            case .clearHistory(let id):
                try self.requireCurrentWorkspace(id)
                if self.store.clearSummary.requiresAuthentication {
                    guard await self.authenticate("清空「\(self.workspaceName)」中的私密历史") else {
                        throw WorkflowError.message("未通过验证，历史未清空。")
                    }
                }
                try self.requireCurrentWorkspace(id)
                switch await self.store.clearAllAsync() {
                case .cleared(let count): self.report("已清空 \(count) 条历史。")
                case .busy: throw WorkflowError.message("历史正在处理中，请稍后重试。")
                case .failed: throw WorkflowError.message("清空失败，请检查数据状态后重试。")
                }
            case .limit(let id, let limit):
                try self.requireCurrentWorkspace(id)
                let affected = max(0, self.store.items.count - limit)
                if self.store.items.suffix(affected).contains(where: \.isPrivate) {
                    guard await self.authenticate("验证后调整包含私密内容的历史上限") else {
                        throw WorkflowError.message("未通过验证，上限和历史未更改。")
                    }
                }
                try self.requireCurrentWorkspace(id)
                try await self.applyLimit(limit)
            case .deleteWorkspace(let id):
                guard let workspace = self.registry.workspaces.first(where: { $0.id == id }), !workspace.isDefault else {
                    throw WorkflowError.message("这个工作区不能删除。")
                }
                if self.registry.activeID == id {
                    guard let fallback = self.registry.workspaces.first(where: \.isDefault) else {
                        throw WorkflowError.message("请先切换到其他工作区。")
                    }
                    self.rebind(try await self.switchWorkspace(fallback.id))
                }
                try self.registry.delete(id)
                self.report("「\(workspace.name)」已移到废纸篓。")
            case .revoke(let id):
                guard self.tokenStore.revoke(id: id) else {
                    throw WorkflowError.message("撤销未保存，令牌仍有效。请检查数据目录权限后重试。")
                }
                if self.issuedToken?.token.id == id { self.issuedToken = nil }
                self.report("令牌已撤销，该程序不能再用此令牌访问。")
            case .revokeAll:
                guard self.tokenStore.revokeAll() else {
                    throw WorkflowError.message("撤销未保存，现有令牌仍有效。请重试。")
                }
                self.report("所有令牌已撤销。")
            case .clearAudit:
                guard APIAuditLog.clear(rootDirectory: self.registry.rootDirectory) else {
                    throw WorkflowError.message("调用记录未能清空，请检查目录权限后重试。")
                }
                self.audit = []
                self.auditError = nil
                self.report("调用记录已清空，剪贴板历史未改变。")
            }
            self.sheet = nil
        }
    }

    private func requireCurrentWorkspace(_ id: UUID) throws {
        guard registry.activeID == id else {
            throw WorkflowError.message("当前工作区已改变。请取消并重新确认操作范围。")
        }
    }

    func rebuildIndex() {
        guard let database = store.database else { report("请先恢复数据库连接。", error: true); return }
        run("正在重建搜索索引…") {
            try await database.rebuildFTS()
            self.report("搜索索引已重建，历史内容未改变。")
        }
    }

    func retryStore() {
        run("正在重新连接数据库…") {
            let next = try await self.switchWorkspace(self.registry.activeID)
            guard next.availability.isReady else { throw WorkflowError.message("仍然无法读取历史，请检查数据目录后重试。") }
            self.rebind(next)
            self.report("历史已重新加载。")
        }
    }

    func addIgnoredApplications(_ urls: [URL]) {
        let result = IgnoreTargetActions.addApplications(at: urls, to: settings)
        let note = "已添加 \(result.added.count) 个应用。"
            + (result.alreadyListed.isEmpty ? "" : "\(result.alreadyListed.count) 个已在清单中。")
            + (result.unusable.isEmpty ? "" : "无法识别：\(result.unusable.joined(separator: "、"))。")
        report(note, error: !result.unusable.isEmpty)
        onPreferencesChanged()
    }

    func removeIgnored(_ id: String) {
        settings.ignoredApps.removeAll { $0 == id }
        let result = IgnoreListNotice.removal(
            name: AppIdentityCache.shared.displayName(for: id),
            stillAutoIgnored: settings.autoIgnoredApps.contains(id))
        report(result.text)
        onPreferencesChanged()
    }

    func createToken(name: String, scopes: Set<APIToken.Scope>, days: Int) {
        guard issuedToken == nil, !isBusy else { return }
        if let error = WorkflowValidation.tokenName(name) { sheetError = error; return }
        guard !scopes.isEmpty else { sheetError = "至少选择一项权限。"; return }
        do {
            var scopes = scopes
            if scopes.contains(.searchText) { scopes.insert(.searchMeta) }
            let created = try tokenStore.create(
                label: name, scopes: APIToken.Scope.allCases.filter { scopes.contains($0) },
                expiresAt: days == 0 ? nil : Date().addingTimeInterval(Double(days) * 86_400))
            issuedToken = created
            secretRevealed = false
            secretSaved = false
            copyFeedback = nil
            sheetError = nil
            sheet = .secret
        } catch { sheetError = "令牌未创建：\(error.localizedDescription)" }
    }

    func copyIssuedToken(format: String) {
        guard let issuedToken else { return }
        let helper = Bundle.main.bundlePath + "/Contents/Helpers/clipa-mcp"
        let value = format == "cursor" ? APIMcp.cursorConfig(token: issuedToken.secret, helperPath: helper)
            : format == "codex" ? APIMcp.codexConfig(token: issuedToken.secret, helperPath: helper)
            : issuedToken.secret
        copyFeedback = SensitiveClipboard.copy(value)
            ? "已复制。不会记入历史；若没有复制其他内容，60 秒后自动清除。"
            : "复制失败，请重试。"
    }

    func finishToken() {
        guard secretSaved else { return }
        issuedToken = nil
        secretRevealed = false
        copyFeedback = nil
        sheet = nil
        report("授权已创建，可随时在此撤销。")
    }

    func abandonToken() {
        guard let created = issuedToken else { return }
        guard tokenStore.revoke(id: created.token.id) else {
            sheetError = "撤销失败，令牌仍有效。请先保存令牌，或重试撤销。"
            return
        }
        issuedToken = nil
        sheet = nil
        report("未完成的授权已撤销。")
    }

    func refreshAudit() {
        do {
            audit = try APIAuditLog.readRecent(500, rootDirectory: registry.rootDirectory)
            auditError = nil
        } catch {
            audit = []
            auditError = "调用记录无法读取或格式异常，请检查数据目录后重试。"
        }
    }
    var filteredAudit: [APIAuditLog.Entry] {
        audit.filter {
            (!auditDeniedOnly || $0.denied != nil) &&
            (auditQuery.isEmpty || ($0.token + " " + $0.peer + " " + $0.verb).localizedCaseInsensitiveContains(auditQuery))
        }
    }
}

/// The newly constructed store has no subscribers until it reaches the main
/// actor. Blocking legacy load/migration work stays off the UI and task pool.
enum BackgroundStoreLoader {
    static func open(directory: URL, settings: SettingsStore) async -> ClipStore {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ClipStore(baseDirectory: directory, settingsStore: settings))
            }
        }
    }
}
