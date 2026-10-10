import SwiftUI

@MainActor
struct ManagementSheetView: View {
    @ObservedObject var model: ManagementModel

    @ViewBuilder var body: some View {
        switch model.sheet {
        case .workspace(let id): WorkspaceNameForm(model: model, workspaceID: id)
        case .limit: HistoryLimitForm(model: model)
        case .token: TokenPermissionForm(model: model)
        case .authorization(let id): TokenPermissionForm(model: model, editingID: id)
        case .connect(let client, let id): TokenPermissionForm(model: model, editingID: id, client: client)
        case .connectionReady: ConnectionReceiptView(model: model)
        case .collection(let id): CollectionNameForm(model: model, collectionID: id)
        case .secret: TokenReceiptView(model: model)
        case .confirmation(let confirmation): ConfirmationForm(model: model, confirmation: confirmation)
        case nil: EmptyView()
        }
    }
}

@MainActor
private struct CollectionNameForm: View {
    @ObservedObject var model: ManagementModel
    let collectionID: UUID?
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        SheetLayout(model: model, title: collectionID == nil ? "新建资料集" : "重命名资料集",
                    detail: "保存在「\(model.workspaceName)」中。名称为 1–60 个字，不能重复。") {
            TextField("例如：项目参考", text: $name).textFieldStyle(.roundedBorder).focused($focused)
        } actions: {
            Button("取消") { model.dismissSheet() }.keyboardShortcut(.cancelAction)
            Button("保存") { model.saveCollection(name: name, id: collectionID) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled((try? IntegrationValidation.name(name)) == nil)
        }
        .onAppear {
            name = model.collections.first { $0.id == collectionID }?.name ?? ""
            focused = true
        }
    }
}

@MainActor
private struct SheetLayout<Content: View, Actions: View>: View {
    @ObservedObject var model: ManagementModel
    let title: String
    let detail: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24)
            Divider()
            content.padding(24).disabled(model.isBusy)
            if let error = model.sheetError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.bottom, 16)
            }
            if let busy = model.busy {
                HStack { ProgressView().controlSize(.small); Text(busy).font(.callout) }
                    .padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider()
            HStack { Spacer(); actions }.padding(16).disabled(model.isBusy)
        }
        .frame(width: 510)
    }
}

@MainActor
private struct WorkspaceNameForm: View {
    @ObservedObject var model: ManagementModel
    let workspaceID: UUID?
    @State private var name = ""
    @State private var activate = true
    @FocusState private var focused: Bool

    private var error: String? {
        WorkflowValidation.workspaceName(name, existing: model.registry.workspaces, excluding: workspaceID)
    }
    var body: some View {
        SheetLayout(model: model, title: workspaceID == nil ? "新建工作区" : "重命名工作区",
                    detail: "工作区名称用于区分历史。每个工作区的数据相互独立。") {
            VStack(alignment: .leading, spacing: 12) {
                Text("名称").font(.headline)
                TextField("例如：工作、个人、项目资料", text: $name)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { submit() }
                    .accessibilityLabel("工作区名称")
                Text(name.isEmpty ? "1–40 个字，名称不能重复。" : error ?? "名称可用。")
                    .font(.caption).foregroundStyle(error != nil && !name.isEmpty ? Color.orange : .secondary)
                if workspaceID == nil {
                    Toggle("创建后立即切换到此工作区", isOn: $activate)
                }
            }
        } actions: {
            Button("取消") { model.dismissSheet() }.keyboardShortcut(.cancelAction)
            Button(workspaceID == nil ? "创建" : "保存") { submit() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(error != nil)
        }
        .onAppear {
            name = model.registry.workspaces.first(where: { $0.id == workspaceID })?.name ?? ""
            focused = true
        }
    }
    private func submit() {
        guard error == nil else { return }
        model.saveWorkspace(name: name, editing: workspaceID, activate: activate)
    }
}

@MainActor
private struct HistoryLimitForm: View {
    @ObservedObject var model: ManagementModel
    @State private var unlimited = false
    @State private var value = ""
    @FocusState private var focused: Bool
    private var limit: Int? { unlimited ? 0 : WorkflowValidation.historyLimit(value) }

    var body: some View {
        SheetLayout(model: model, title: "更改历史上限",
                    detail: "仅应用于「\(model.workspaceName)」。当前保存 \(model.store.items.count) 条历史。") {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("不限制历史条数", isOn: $unlimited)
                HStack {
                    Text("最多保留")
                    TextField("例如 5000", text: $value).textFieldStyle(.roundedBorder)
                        .frame(width: 150).focused($focused).disabled(unlimited)
                        .accessibilityLabel("历史上限条数")
                    Text("条")
                }
                Text(unlimited ? "更多历史会占用更多磁盘与内存。" : "请输入 1–1,000,000 的整数。")
                    .font(.caption).foregroundStyle(limit == nil ? Color.orange : .secondary)
                if let limit, limit > 0, model.store.items.count > limit {
                    Label("较早的 \(model.store.items.count - limit) 条历史将被删除，下一步会再次确认。",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
        } actions: {
            Button("取消") { model.dismissSheet() }.keyboardShortcut(.cancelAction)
            Button("继续") { if let limit { model.requestLimit(limit) } }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(limit == nil)
        }
        .onAppear {
            unlimited = model.settings.historyLimit == 0
            value = String(model.settings.historyLimit > 0 ? model.settings.historyLimit : 5000)
            focused = !unlimited
        }
    }
}

@MainActor
private struct TokenPermissionForm: View {
    @ObservedObject var model: ManagementModel
    var editingID: String? = nil
    var client: IntegrationClient? = nil
    @State private var name = ""
    @State private var scopes: Set<APIToken.Scope> = [.searchMeta, .searchText]
    @State private var days = 30
    @State private var workspaceIDs = Set<UUID>()
    @State private var replaceExisting = false
    @FocusState private var focused: Bool
    private var valid: Bool { WorkflowValidation.tokenName(name) == nil && !scopes.isEmpty && !workspaceIDs.isEmpty }

    var body: some View {
        SheetLayout(model: model, title: client.map { "连接 " + $0.title } ?? (editingID == nil ? "授权一个程序" : "管理授权"),
                    detail: "选择程序可以访问的工作区与操作。连接发生在本机；AI 客户端可能将获准读取的内容发送到其模型服务。私密内容始终不开放。") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("程序名称，例如 Codex 或 Cursor", text: $name)
                        .textFieldStyle(.roundedBorder).focused($focused)
                        .accessibilityLabel("授权程序名称")
                        .disabled(editingID != nil || client != nil)
                    if let client {
                        Text(client.configURL(home: FileManager.default.homeDirectoryForCurrentUser)?.path ?? "完成后复制配置到客户端。")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if client != .custom {
                            Toggle("替换已有 Clipa 配置（写入前备份）", isOn: $replaceExisting)
                                .toggleStyle(.checkbox)
                        }
                    }
                    if let error = WorkflowValidation.tokenName(name), !name.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Picker("有效期", selection: $days) {
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                        Text("不过期").tag(0)
                    }
                    Text(editingID == nil ? "有效期从创建时开始计算。" : "保存后将从现在重新计算有效期。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("允许访问的工作区").font(.headline)
                    Text("未指定工作区时使用列表中第一个已选工作区。读取和资料整理不会切换当前界面。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.registry.workspaces) { workspace in
                        Toggle(workspace.name, isOn: Binding(
                            get: { workspaceIDs.contains(workspace.id) },
                            set: { if $0 { workspaceIDs.insert(workspace.id) } else { workspaceIDs.remove(workspace.id) } }
                        )).toggleStyle(.checkbox)
                    }
                    if workspaceIDs.isEmpty { Text("至少选择一个工作区。").font(.caption).foregroundStyle(.orange) }
                    Divider()
                    Text("读取").font(.headline)
                    ForEach(APIToken.Scope.allCases.filter { !$0.isWrite }, id: \.self) { scope in
                        permission(scope)
                    }
                    Divider()
                    Text("操作权限").font(.headline)
                    ForEach(APIToken.Scope.allCases.filter(\.isWrite), id: \.self) { scope in
                        permission(scope)
                    }
                    if scopes.isEmpty { Text("至少选择一项权限。").font(.caption).foregroundStyle(.orange) }
                }
            }.frame(maxHeight: 370)
        } actions: {
            Text("\(workspaceIDs.count) 个工作区 · " + (scopes.contains(where: \.isWrite) ? "含操作权限" : "只读"))
                .font(.caption).foregroundStyle(.secondary)
            Button("取消") { model.dismissSheet() }.keyboardShortcut(.cancelAction)
            Button(client != nil ? "确认并连接" : editingID == nil ? "创建令牌" : "保存授权") {
                if let client { model.connectClient(client, existingID: editingID, scopes: scopes, workspaceIDs: workspaceIDs, days: days, replaceExisting: replaceExisting) }
                else if let editingID { model.saveAuthorization(id: editingID, scopes: scopes, days: days, workspaceIDs: workspaceIDs) }
                else { model.createToken(name: name, scopes: scopes, days: days, workspaceIDs: workspaceIDs) }
            }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!valid || model.tokenStore.loadError != nil)
        }
        .onAppear {
            if let editingID, let token = model.tokenStore.tokens.first(where: { $0.id == editingID }) {
                name = token.label
                scopes = Set(token.scopes)
                workspaceIDs = Set(token.workspaceIDs ?? [])
                days = token.expiresAt == nil ? 0 : 30
            } else { workspaceIDs = [model.registry.activeID]; name = client?.title ?? "" }
            focused = editingID == nil
        }
    }

    private func permission(_ scope: APIToken.Scope) -> some View {
        Toggle(isOn: Binding(get: { scopes.contains(scope) }, set: {
            if $0 { scopes.insert(scope) } else { scopes.remove(scope) }
            if scopes.contains(.searchText) { scopes.insert(.searchMeta) }
        })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(scope.uiTitle)
                Text(scope.uiDetail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(scope == .searchMeta && scopes.contains(.searchText))
    }
}

@MainActor
private struct ConnectionReceiptView: View {
    @ObservedObject var model: ManagementModel
    var body: some View {
        SheetLayout(model: model, title: "连接配置已准备好",
                    detail: "令牌由 Clipa 单独保管。客户端配置只包含连接编号；撤销授权后连接立即失效。") {
            VStack(alignment: .leading, spacing: 14) {
                if let path = model.connectionResult?.destination {
                    Label("配置已写入", systemImage: "checkmark.circle")
                    Text(path.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("请重新启动该 AI 客户端，然后让它调用 clipa_status。设置列表中的“最近调用”会在实际访问后更新。")
                        .font(.callout)
                } else {
                    Text("复制以下配置到支持 stdio MCP 的客户端，然后重新启动客户端。")
                        .font(.callout)
                }
                if let backup = model.connectionResult?.backup {
                    Text("原配置备份：" + backup.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("复制连接配置") { model.copyConnectionConfig() }
                if let feedback = model.copyFeedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            }
        } actions: {
            Button("完成") { model.dismissSheet() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }
}

@MainActor
private struct TokenReceiptView: View {
    @ObservedObject var model: ManagementModel

    var body: some View {
        SheetLayout(model: model, title: "保存「\(model.issuedToken?.token.label ?? "")」的令牌",
                    detail: "完整令牌只显示这一次。关闭后无法再次查看，但可在授权列表中撤销。") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(model.secretRevealed ? model.issuedToken?.secret ?? "" : String(repeating: "•", count: 28))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(3).textSelection(.disabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(model.secretRevealed ? "令牌已显示" : "令牌已隐藏")
                    Button(model.secretRevealed ? "隐藏" : "显示") { model.secretRevealed.toggle() }
                }
                .padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("复制令牌", systemImage: "doc.on.doc") { model.copyIssuedToken(format: "token") }
                    Menu("复制客户端配置") {
                        Button("Cursor 配置") { model.copyIssuedToken(format: "cursor") }
                        Button("Codex 配置") { model.copyIssuedToken(format: "codex") }
                    }.fixedSize()
                }
                if let feedback = model.copyFeedback {
                    Text(feedback).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("使用上方按钮复制可避免令牌进入剪贴板历史，剪贴板副本将在 60 秒后清除。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Toggle("我已保存令牌或客户端配置", isOn: $model.secretSaved)
                if !model.settings.apiControlEnabled {
                    Text("本地接口尚未开启。完成配置后，在「应用集成」页面启用访问。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button("撤销并关闭", role: .destructive) { model.abandonToken() }
            Button("完成") { model.finishToken() }.buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction).disabled(!model.secretSaved)
        }
    }
}

@MainActor
private struct ConfirmationForm: View {
    @ObservedObject var model: ManagementModel
    let confirmation: ManagementConfirmation
    var body: some View {
        SheetLayout(model: model, title: confirmation.title, detail: confirmation.detail) {
            Label("只有点击下方确认按钮才会执行。", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
        } actions: {
            Button("取消") { model.dismissSheet() }.keyboardShortcut(.cancelAction)
            Button(confirmation.button, role: .destructive) { model.execute(confirmation) }
        }
    }
}
