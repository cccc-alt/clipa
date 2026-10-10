import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ManagementView: View {
    @ObservedObject var model: ManagementModel
    @State private var chooseApplications = false

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ManagementPage.allCases) { page in
                        Button { model.page = page } label: {
                            Label(page.title, systemImage: page.symbol)
                                .font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).frame(height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(model.page == page ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityAddTraits(model.page == page ? .isSelected : [])
                        .keyboardShortcut(KeyEquivalent(Character(String((ManagementPage.allCases.firstIndex(of: page) ?? 0) + 1))), modifiers: .command)
                        .help(page.detail)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 20)
            }
            .navigationSplitViewColumnWidth(min: 165, ideal: 180, max: 210)
            .disabled(model.isBusy || model.sheet != nil)
        } detail: {
            VStack(spacing: 0) {
                header
                if let notice = model.notice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(notice.isError ? Color.orange : Color.accentColor)
                        Text(notice.message).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("关闭通知")
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24).padding(.bottom, 12)
                    .accessibilityElement(children: .contain)
                }
                if let busy = model.busy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout)
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.bottom, 12)
                    .accessibilityLabel(busy)
                }
                Divider()
                pageContent.disabled(model.isBusy)
            }
            .frame(minWidth: 490)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 510)
        .sheet(isPresented: Binding(
            get: { model.sheet != nil },
            set: { if !$0 { model.dismissSheet() } }
        )) {
            ManagementSheetView(model: model)
                .interactiveDismissDisabled(model.preventsDismissal)
        }
        .fileImporter(isPresented: $chooseApplications, allowedContentTypes: [.applicationBundle],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.addIgnoredApplications(urls)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    model.report("无法选择应用：\(error.localizedDescription)", error: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.page.title).font(.system(size: 22, weight: .semibold))
                Text(model.page.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.page == .workspaces {
                Button("新建工作区", systemImage: "plus") { model.present(.workspace(nil)) }
                    .disabled(model.isBusy || model.registry.loadError != nil)
            } else if model.page == .integrations {
                Button("新建授权", systemImage: "plus") { model.present(.token) }
                    .disabled(model.isBusy || model.tokenStore.loadError != nil)
            } else if model.page == .activity {
                Button("刷新", systemImage: "arrow.clockwise") { model.refreshAudit() }
                    .disabled(model.isBusy)
            }
        }
        .padding(24)
    }

    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .general: general
        case .workspaces: workspaces
        case .privacy: privacy
        case .history: history
        case .integrations: integrations
        case .activity: activity
        }
    }

    private var general: some View {
        Form {
            Section("日常使用") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("新手引导")
                        Text("了解快捷键、搜索复制与隐私设置。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新查看…") { model.openOnboarding() }
                }
                Toggle("记录剪贴板", isOn: Binding(
                    get: { !model.settings.pauseRecording }, set: { model.setRecording($0) }
                ))
                Text(model.settings.autoPausedByLimit
                     ? "历史已达上限。删除部分历史或提高上限后可继续记录。"
                     : "记录文本、图片和文件。暂停后，已有历史仍可搜索与复制。")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("打开剪贴板", value: "⌃⌘V")
                HStack {
                    Text("↑ ↓ 选择 · ↩ 复制 · 空格 / ⌘Y 预览 · Esc 返回")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开面板") { model.openClipboard() }
                }
            }
            Section("启动") {
                Toggle("登录时启动 Clipa", isOn: Binding(
                    get: { model.settings.launchAtLogin }, set: { model.setLaunchAtLogin($0) }
                ))
                Button("在系统设置中管理登录项…") { SMAppService.openSystemSettingsLoginItems() }
            }
            Section("外观与辅助功能") {
                LabeledContent("外观", value: "跟随系统")
                Text("使用系统强调色，并响应深色模式、减少透明度和减少动态效果设置。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("关于") {
                LabeledContent("版本", value: APIContract.appVersion)
                Text("历史仅存储在本机。私密内容需验证身份后查看，不参与全文搜索或本地接口访问。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var workspaces: some View {
        Form {
            if let error = model.registry.loadError {
                Section("工作区列表需要处理") {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("在访达中显示数据目录") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.registry.rootDirectory])
                    }
                }
            }
            Section {
                Text("当前工作区：\(model.workspaceName)").font(.headline)
                Text("切换工作区只改变当前浏览和记录的位置，不移动已有历史。隐私规则和授权设置在所有工作区间共用。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("全部工作区") {
                ForEach(model.registry.workspaces) { workspace in
                    HStack(spacing: 12) {
                        Image(systemName: workspace.isDefault ? "tray" : "square.stack.3d.up")
                            .frame(width: 24).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspace.name).font(.body.weight(.medium))
                            Text(workspace.isDefault ? "内置工作区 · 不可删除" : "独立历史与存储")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if workspace.id == model.registry.activeID {
                            Label("使用中", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Button("切换") { model.activate(workspace.id) }
                        }
                        Menu {
                            Button("重命名…") { model.present(.workspace(workspace.id)) }
                            Button("在访达中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([model.registry.baseDirectory(for: workspace)])
                            }
                            if !workspace.isDefault {
                                Divider()
                                Button("移到废纸篓…", role: .destructive) { model.requestDeleteWorkspace(workspace) }
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 18) }
                            .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("管理工作区 \(workspace.name)")
                    }.padding(.vertical, 4)
                        .disabled(model.registry.loadError != nil)
                }
            }
        }.formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("自动过滤") {
                privacyToggle("遵循来源应用的机密标记", detail: "例如密码管理器标记为不应记录的内容。", path: \.skipConfidentialPasteboard)
                privacyToggle("跳过疑似敏感内容", detail: "识别到密钥、令牌或私钥时，不将本次复制写入历史。", path: \.skipSensitive)
                privacyToggle("跳过密码管理器", detail: "忽略内置清单中的密码管理器复制行为。", path: \.ignorePasswordManagers)
                Text("规则仅影响之后的复制，不会删除已有历史。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    TextField("搜索忽略的应用", text: $model.ignoredQuery)
                        .textFieldStyle(.roundedBorder)
                    Button("添加应用…") { chooseApplications = true }
                }
                let ids = model.settings.ignoredApps.filter {
                    model.ignoredQuery.isEmpty
                    || (AppIdentityCache.shared.displayName(for: $0) + " " + $0)
                        .localizedCaseInsensitiveContains(model.ignoredQuery)
                }
                if model.settings.ignoredApps.isEmpty {
                    Text("尚未手动忽略任何应用。添加后，这些应用复制的内容不会进入历史。")
                        .foregroundStyle(.secondary).font(.callout)
                } else if ids.isEmpty {
                    Text("没有匹配的应用。").foregroundStyle(.secondary)
                }
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 10) {
                        if let image = SpotlightRowView.appIcon(bundleID: id) {
                            Image(nsImage: image).resizable().frame(width: 24, height: 24)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppIdentityCache.shared.displayName(for: id))
                            Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("移除") { model.removeIgnored(id) }
                            .accessibilityLabel("不再手动忽略 \(AppIdentityCache.shared.displayName(for: id))")
                    }
                }
            } header: { Text("手动忽略的应用") }
            Section("私密内容") {
                Text("在历史条目的菜单中选择「设为私密」。查看、复制或取消私密时使用 Touch ID 或系统密码验证。解锁有效期为 60 秒。")
                    .font(.callout)
                Text("私密内容不参与搜索，不向授权程序提供。未保存的私密备注会在锁定或关闭面板时清除。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func privacyToggle(_ title: String, detail: String,
                               path: ReferenceWritableKeyPath<SettingsStore, Bool>) -> some View {
        Toggle(isOn: Binding(get: { model.settings[keyPath: path] }, set: {
            model.settings[keyPath: path] = $0
            model.onPreferencesChanged()
        })) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var history: some View {
        Form {
            Section("当前工作区 · \(model.workspaceName)") {
                LabeledContent("历史条数", value: model.store.availability.isReady ? "\(model.store.items.count) 条" : "暂时无法读取")
                LabeledContent("数据库状态") {
                    Label(model.store.availability.isReady ? "可用" : "需要处理",
                          systemImage: model.store.availability.isReady ? "checkmark.shield" : "exclamationmark.triangle")
                        .foregroundStyle(model.store.availability.isReady ? Color.secondary : .orange)
                }
                if let error = model.storeError {
                    Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("重新连接并加载历史") { model.retryStore() }
                }
                LabeledContent("数据位置") {
                    Text(model.store.dataDirectory.path).font(.caption)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Button("在访达中显示数据目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.dataDirectory])
                }
            }
            Section("保存策略") {
                HStack {
                    LabeledContent("历史上限", value: model.settings.historyLimit == 0 ? "不限制" : "\(model.settings.historyLimit) 条")
                    Button("更改…") { model.present(.limit) }.disabled(!model.store.availability.isReady)
                }
                Toggle("达到上限时暂停记录", isOn: Binding(
                    get: { model.settings.autoPauseAtLimit }, set: {
                        model.settings.autoPauseAtLimit = $0; model.onPreferencesChanged()
                    }
                ))
                Text(model.settings.autoPauseAtLimit
                     ? "到达上限后停止新增；腾出空间后自动恢复。"
                     : "到达上限后自动移除最早的历史，保留新的复制内容。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("维护") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("重建搜索索引")
                        Text("搜索结果异常时使用，不会更改历史内容。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重建…") { model.rebuildIndex() }.disabled(!model.store.availability.isReady)
                }
                Toggle("清空时安全擦除", isOn: Binding(
                    get: { model.settings.secureEraseHistoryOnClear }, set: {
                        model.settings.secureEraseHistoryOnClear = $0; model.onPreferencesChanged()
                    }
                ))
                Text("安全擦除会整理数据库及其日志，大型历史库可能需要较长时间。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("清空当前工作区…", role: .destructive) { model.requestClear() }
                    .disabled(!model.store.availability.isReady || model.store.items.isEmpty)
            }
        }.formStyle(.grouped)
    }

    private var integrations: some View {
        Form {
            Section("本地接口") {
                Toggle("允许授权程序访问", isOn: Binding(
                    get: { model.settings.apiControlEnabled }, set: { model.setAPIEnabled($0) }
                ))
                LabeledContent("运行状态", value: model.apiIsRunning() ? "已开启，仅本机可连接" : "未运行")
                Text("每个程序使用独立令牌，并按所选权限访问。关闭接口后所有程序暂停访问；私密内容始终不可访问。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("已授权程序") {
                if let error = model.tokenStore.loadError {
                    Label("授权文件需要处理", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Button("重新读取授权文件") { model.refresh() }
                } else if model.tokenStore.tokens.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有授权程序").font(.headline)
                        Text("创建令牌后可复制 Cursor、Codex 配置，或将令牌用于命令行。").foregroundStyle(.secondary)
                        Button("创建第一个授权") { model.present(.token) }
                    }.padding(.vertical, 8)
                } else {
                    ForEach(model.tokenStore.tokens) { token in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(token.label, systemImage: "app.connected.to.app.below.fill").font(.headline)
                                Spacer()
                                if token.isExpired { Text("已过期").foregroundStyle(.orange).font(.caption) }
                                Button("撤销…", role: .destructive) {
                                    model.present(.confirmation(ManagementConfirmation(
                                        title: "撤销「\(token.label)」的授权？",
                                        detail: "使用令牌 \(token.id) 的程序将立即失去访问权限，需创建新令牌才能重新连接。",
                                        button: "撤销授权", action: .revoke(token.id))))
                                }
                            }
                            Text(token.scopes.map(\.uiTitle).joined(separator: " · "))
                                .font(.callout).foregroundStyle(.secondary)
                            Text("\(token.id) · 已使用 \(token.callCount) 次 · "
                                 + (token.expiresAt.map { "到期：" + $0.formatted(date: .numeric, time: .omitted) } ?? "不过期"))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(.vertical, 6)
                    }
                    Button("撤销全部授权…", role: .destructive) {
                        model.present(.confirmation(ManagementConfirmation(
                            title: "撤销全部 \(model.tokenStore.tokens.count) 个授权？",
                            detail: "所有使用现有令牌的程序都会立即失去访问权限。此操作不能撤销。",
                            button: "撤销全部", action: .revokeAll)))
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private var activity: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索程序、令牌或操作", text: $model.auditQuery).textFieldStyle(.roundedBorder)
                Toggle("仅显示拒绝", isOn: $model.auditDeniedOnly).toggleStyle(.checkbox)
            }.padding(20)
            if let error = model.auditError {
                ContentUnavailableView("调用记录暂时不可用", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("打开数据目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.registry.rootDirectory])
                }.padding(.bottom, 20)
            } else if model.filteredAudit.isEmpty {
                ContentUnavailableView(model.audit.isEmpty ? "还没有调用记录" : "没有匹配的调用",
                                       systemImage: "clock",
                                       description: Text(model.audit.isEmpty ? "授权程序使用本地接口后，记录会出现在这里。" : "更改关键词或关闭过滤条件后重试。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(model.filteredAudit.enumerated()), id: \.offset) { _, entry in
                    DisclosureGroup {
                        LabeledContent("调用来源") { Text(entry.peer).textSelection(.enabled) }
                        LabeledContent("结果", value: entry.denied.map(Self.denialTitle) ?? "操作成功")
                        if let hits = entry.hits { LabeledContent("结果条数", value: String(hits)) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.denied == nil ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(entry.denied == nil ? Color.secondary : .orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.token == "-" ? "未授权程序" : entry.token)
                                Text(Self.verbTitle(entry.verb)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.at.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                Text(model.auditError == nil ? "最近 \(model.audit.count) 条 · 不显示剪贴板正文" : "记录暂时不可用").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空调用记录…", role: .destructive) {
                    model.present(.confirmation(ManagementConfirmation(
                        title: "清空调用记录？", detail: "只移除本地接口的调用记录，不会删除剪贴板历史或撤销授权。",
                        button: "清空记录", action: .clearAudit)))
                }.disabled(model.audit.isEmpty && model.auditError == nil)
            }.padding(16)
        }
    }

    private static func denialTitle(_ value: String) -> String {
        ["not_enabled": "本地接口未开启", "not_authorized": "令牌无效或已过期",
         "denied": "此令牌没有所需权限", "rate_limited": "调用过于频繁，请稍后重试",
         "bad_request": "请求格式不正确", "not_found": "条目不存在或不可访问",
         "version_mismatch": "客户端协议版本不兼容"][value] ?? "请求被拒绝：" + value
    }

    private static func verbTitle(_ value: String) -> String {
        ["status": "查看接口状态", "search": "搜索历史", "get": "读取内容", "copy": "复制内容",
         "put": "添加历史", "note": "修改备注", "delete": "删除历史"][value] ?? value
    }
}

extension APIToken.Scope {
    var uiTitle: String {
        switch self {
        case .searchMeta: return "搜索条目"
        case .searchText: return "预览搜索结果"
        case .readFull: return "读取完整内容"
        case .copy: return "复制到剪贴板"
        case .put: return "添加历史"
        case .note: return "修改备注"
        case .delete: return "删除历史"
        }
    }
    var uiDetail: String {
        switch self {
        case .searchMeta: return "返回类型、来源和时间，不包含正文。"
        case .searchText: return "提供搜索结果的正文开头；同时需要搜索权限。"
        case .readFull: return "允许读取完整正文和备注。"
        case .copy: return "允许替换系统剪贴板中的内容。"
        case .put: return "仍遵守暂停记录、敏感内容和忽略应用规则。"
        case .note: return "允许修改历史条目的备注。"
        case .delete: return "允许永久删除非私密历史，请谨慎授权。"
        }
    }
}
