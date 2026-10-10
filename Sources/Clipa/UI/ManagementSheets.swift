import SwiftUI

@MainActor
struct ManagementSheetView: View {
    @ObservedObject var model: ManagementModel

    @ViewBuilder var body: some View {
        switch model.sheet {
        case .workspace(let id): WorkspaceNameForm(model: model, workspaceID: id)
        case .limit: HistoryLimitForm(model: model)
        case .token: TokenPermissionForm(model: model)
        case .secret: TokenReceiptView(model: model)
        case .confirmation(let confirmation): ConfirmationForm(model: model, confirmation: confirmation)
        case nil: EmptyView()
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
    @State private var name = ""
    @State private var scopes: Set<APIToken.Scope> = [.searchMeta, .searchText]
    @State private var days = 30
    @FocusState private var focused: Bool
    private var valid: Bool { WorkflowValidation.tokenName(name) == nil && !scopes.isEmpty }

    var body: some View {
        SheetLayout(model: model, title: "授权一个程序",
                    detail: "为每个程序创建独立令牌。默认只允许搜索与预览，私密内容始终不开放。") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("程序名称，例如 Codex 或 Cursor", text: $name)
                        .textFieldStyle(.roundedBorder).focused($focused)
                        .accessibilityLabel("授权程序名称")
                    if let error = WorkflowValidation.tokenName(name), !name.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Picker("有效期", selection: $days) {
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                        Text("不过期").tag(0)
                    }
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
            Button("取消") { model.dismissSheet() }.keyboardShortcut(.cancelAction)
            Button("创建令牌") { model.createToken(name: name, scopes: scopes, days: days) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!valid || model.tokenStore.loadError != nil)
        }
        .onAppear { focused = true }
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
