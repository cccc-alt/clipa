import AppKit
import Combine
import Foundation

enum ManagementPage: String, CaseIterable, Identifiable {
    case general, workspaces, collections, privacy, history, integrations, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .workspaces: return "工作区"
        case .collections: return "资料集"
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
        case .collections: return "folder"
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
        case .collections: return "将当前工作区的参考内容按项目整理"
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
        case deleteCollection(UUID, UUID)
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
    case authorization(String)
    case connect(IntegrationClient, String?)
    case connectionReady
    case collection(UUID?)
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
        didSet {
            if page != oldValue { notice = nil }
            if page == .collections { refreshCollections() }
        }
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
    @Published private(set) var connectionResult: ClientInstallResult?
    @Published private(set) var connectionDiagnostics: [UUID: String] = [:]
    @Published private(set) var collections: [ClipCollection] = []
    @Published private(set) var collectionError: String?
    @Published private(set) var collectionsLoading = false
    private var collectionTask: Task<Void, Never>?

    let switchWorkspace: (UUID) async throws -> ClipStore
    let changeAPI: (Bool) throws -> Void
    let apiIsRunning: () -> Bool
    let authenticate: (String) async -> Bool
    var onPreferencesChanged: () -> Void = {}
    var openClipboard: () -> Void = {}
    var openOnboarding: () -> Void = {}
    var openCollection: (UUID) -> Void = { _ in }
    var helperBundleURL = Bundle.main.bundleURL
    var installClientConfiguration: (IntegrationClient, UUID, URL, Bool) throws -> ClientInstallResult = {
        try ClientConfigurationInstaller.install(client: $0, id: $1, helper: $2, replaceExisting: $3)
    }
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
        NotificationCenter.default.publisher(for: .clipaCollectionsChanged)
            .sink { [weak self] notification in
                guard let self, notification.object as? URL == self.store.dataDirectory else { return }
                self.refreshCollections()
            }.store(in: &subscriptions)
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
        collections = []
        bindStore()
        if page == .collections { refreshCollections() }
    }
    private func bindStore() {
        storeSubscription = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            if self?.page == .collections { self?.refreshCollections() }
        }
    }

    func refresh() {
        tokenStore.reload()
        refreshAudit()
        if page == .collections { refreshCollections() }
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
                let profile = self.tokenStore.tokens.first { $0.id == id }?.connectionID
                guard self.tokenStore.revoke(id: id) else {
                    throw WorkflowError.message("撤销未保存，令牌仍有效。请检查数据目录权限后重试。")
                }
                if self.issuedToken?.token.id == id { self.issuedToken = nil }
                self.report("令牌已撤销，该程序不能再用此令牌访问。")
                if let profile {
                    do { try ClientCredentials.remove(profile, root: self.registry.rootDirectory) }
                    catch { self.report(error.localizedDescription, error: true) }
                }
            case .revokeAll:
                let profiles = self.tokenStore.tokens.compactMap(\.connectionID)
                guard self.tokenStore.revokeAll() else {
                    throw WorkflowError.message("撤销未保存，现有令牌仍有效。请重试。")
                }
                self.report("所有令牌已撤销。")
                for profile in profiles {
                    do { try ClientCredentials.remove(profile, root: self.registry.rootDirectory) }
                    catch { self.report(error.localizedDescription, error: true) }
                }
            case .clearAudit:
                guard APIAuditLog.clear(rootDirectory: self.registry.rootDirectory) else {
                    throw WorkflowError.message("调用记录未能清空，请检查目录权限后重试。")
                }
                self.audit = []
                self.auditError = nil
                self.report("调用记录已清空，剪贴板历史未改变。")
            case .deleteCollection(let workspace, let id):
                try self.requireCurrentWorkspace(workspace)
                guard let db = self.store.database else { throw WorkflowError.message("数据库暂不可用。") }
                try await db.deleteCollection(id: id)
                NotificationCenter.default.post(name: .clipaCollectionsChanged, object: self.store.dataDirectory)
                self.refreshCollections()
                self.report("资料集已删除，剪贴板历史仍保留。")
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

    func createToken(name: String, scopes: Set<APIToken.Scope>, days: Int, workspaceIDs: Set<UUID>? = nil) {
        guard issuedToken == nil, !isBusy else { return }
        if let error = WorkflowValidation.tokenName(name) { sheetError = error; return }
        guard !scopes.isEmpty else { sheetError = "至少选择一项权限。"; return }
        let workspaces = workspaceIDs ?? [registry.activeID]
        guard !workspaces.isEmpty, workspaces.isSubset(of: Set(registry.workspaces.map(\.id))) else {
            sheetError = "请选择有效的工作区。"; return
        }
        do {
            var scopes = scopes
            if scopes.contains(.searchText) { scopes.insert(.searchMeta) }
            let created = try tokenStore.create(
                label: name, scopes: APIToken.Scope.allCases.filter { scopes.contains($0) },
                expiresAt: days == 0 ? nil : Date().addingTimeInterval(Double(days) * 86_400),
                workspaceIDs: registry.workspaces.map(\.id).filter(workspaces.contains))
            issuedToken = created
            secretRevealed = false
            secretSaved = false
            copyFeedback = nil
            sheetError = nil
            sheet = .secret
        } catch { sheetError = "令牌未创建：\(error.localizedDescription)" }
    }

    func saveAuthorization(id: String, scopes: Set<APIToken.Scope>, days: Int, workspaceIDs: Set<UUID>) {
        guard !workspaceIDs.isEmpty, !scopes.isEmpty,
              workspaceIDs.isSubset(of: Set(registry.workspaces.map(\.id))) else {
            sheetError = "至少选择一个有效工作区和一项权限。"; return
        }
        do {
            var scopes = scopes
            if scopes.contains(.searchText) { scopes.insert(.searchMeta) }
            try tokenStore.updateAuthorization(id: id, scopes: APIToken.Scope.allCases.filter(scopes.contains),
                workspaceIDs: registry.workspaces.map(\.id).filter(workspaceIDs.contains),
                expiresAt: days == 0 ? nil : Date().addingTimeInterval(Double(days) * 86_400))
            sheet = nil
            report("授权范围和有效期已更新。请重新启动 AI 客户端，刷新可用工具列表。")
        } catch { sheetError = "授权未保存：\(error.localizedDescription)" }
    }

    func workspaceNames(for token: APIToken) -> String {
        guard let ids = token.workspaceIDs, !ids.isEmpty else { return "需要确认工作区后恢复访问" }
        return ids.map { id in registry.workspaces.first { $0.id == id }?.name ?? "已删除的工作区" }.joined(separator: "、")
    }

    func connectClient(_ client: IntegrationClient, existingID: String?, scopes: Set<APIToken.Scope>,
                       workspaceIDs: Set<UUID>, days: Int, replaceExisting: Bool) {
        guard !workspaceIDs.isEmpty, !scopes.isEmpty,
              workspaceIDs.isSubset(of: Set(registry.workspaces.map(\.id))) else {
            sheetError = "请选择有效工作区与权限。"; return
        }
        run("正在配置 \(client.title)…") {
            let existing = existingID.flatMap { id in self.tokenStore.tokens.first { $0.id == id } }
            let profileID = existing?.connectionID ?? UUID()
            let helper = self.helperBundleURL.appendingPathComponent("Contents/Helpers/clipa-mcp")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw WorkflowError.message("请从已安装的 Clipa.app 中连接应用。")
            }
            if !self.settings.apiControlEnabled { try self.changeAPI(true) }
            let installer = self.installClientConfiguration
            let result: ClientInstallResult = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try installer(client, profileID, helper, replaceExisting)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            var normalized = scopes
            if normalized.contains(.searchText) { normalized.insert(.searchMeta) }
            let grants = APIToken.Scope.allCases.filter(normalized.contains)
            let workspaces = self.registry.workspaces.map(\.id).filter(workspaceIDs.contains)
            let expires = days == 0 ? nil : Date().addingTimeInterval(Double(days) * 86_400)
            if let existing, existing.connectionID != nil {
                try self.tokenStore.updateAuthorization(id: existing.id, scopes: grants, workspaceIDs: workspaces, expiresAt: expires)
                try self.tokenStore.rotate(id: existing.id) { secret in
                    try ClientCredentials.write(ClientCredential(id: profileID, tokenID: existing.id,
                        client: client, secret: secret, createdAt: Date()), root: self.registry.rootDirectory)
                }
            } else {
                let created = try self.tokenStore.create(label: client.title, scopes: grants, expiresAt: expires,
                                                        workspaceIDs: workspaces, connectionID: profileID)
                do {
                    try ClientCredentials.write(ClientCredential(id: profileID, tokenID: created.token.id,
                        client: client, secret: created.secret, createdAt: Date()), root: self.registry.rootDirectory)
                } catch {
                    let revoked = self.tokenStore.revoke(id: created.token.id)
                    throw WorkflowError.message(revoked ? "凭据未保存，新授权已撤销。请重试。"
                        : "凭据未保存，且撤销未完成。请在授权列表中撤销此授权后重试。")
                }
            }
            self.connectionResult = result
            self.connectionDiagnostics[profileID] = "配置已保存，等待客户端调用"
            self.sheet = .connectionReady
            self.onPreferencesChanged()
        }
    }

    func reconnect(_ token: APIToken) {
        guard let id = token.connectionID else { present(.authorization(token.id)); return }
        let client = (try? ClientCredentials.read(id, root: registry.rootDirectory))?.client ?? .custom
        present(.connect(client, token.id))
    }

    func testConnection(_ token: APIToken) {
        guard let id = token.connectionID else { return }
        run("正在检测连接…") {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clipa")
            let output: (Int32, Data) = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try ClientConfigurationInstaller.run(helper,
                        ["diagnose", "--connection", id.uuidString, "--json", "--no-launch"])) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try decoder.decode(APIResponse.self, from: output.1)
            self.connectionDiagnostics[id] = response.diagnostic?.message ?? response.error?.message ?? "未能完成检测"
            self.report(response.ok ? "本机检测通过。请在 AI 客户端调用 Clipa，完成端到端确认。"
                        : (response.error?.message ?? "连接失败") + "。" + (response.error?.hint ?? "请重新连接。"), error: !response.ok)
        }
    }

    func copyConnectionConfig() {
        guard let config = connectionResult?.config else { return }
        copyFeedback = SensitiveClipboard.copy(config) ? "配置已复制，其中不包含令牌。" : "复制失败，请重试。"
    }

    func refreshCollections() {
        collectionTask?.cancel()
        let source = store
        collectionsLoading = true
        collectionTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
                guard let db = source.database else { throw WorkflowError.message("请先恢复数据库连接。") }
                let items = try await db.listCollections()
                guard !Task.isCancelled, let self, self.store === source else { return }
                self.collections = items; self.collectionError = nil; self.collectionsLoading = false
            } catch {
                guard !Task.isCancelled, let self, self.store === source else { return }
                self.collectionError = error.localizedDescription; self.collectionsLoading = false
            }
        }
    }

    func saveCollection(name: String, id: UUID?) {
        run("正在保存资料集…") {
            guard let db = self.store.database else { throw WorkflowError.message("数据库暂不可用。") }
            _ = try await db.saveCollection(id: id, name: name)
            self.sheet = nil
            NotificationCenter.default.post(name: .clipaCollectionsChanged, object: self.store.dataDirectory)
            self.refreshCollections()
            self.report("资料集已保存。可在剪贴板条目的右键菜单中添加内容。")
        }
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
