import AppKit
import ServiceManagement
import SwiftUI

@MainActor
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                ForEach(OnboardingStep.allCases) { step in
                    HStack(spacing: 7) {
                        Image(systemName: step.rawValue < model.step.rawValue ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle\(step == model.step ? ".fill" : "")")
                        Text(step.title)
                    }
                    .font(.callout.weight(step == model.step ? .semibold : .regular))
                    .foregroundStyle(step == model.step ? Color.accentColor : .secondary)
                    .accessibilityLabel("第 \(step.rawValue + 1) 步，\(step.title)\(step == model.step ? "，当前步骤" : "")")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32).padding(.vertical, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch model.step {
                    case .welcome: welcome
                    case .workflow: workflow
                    case .privacy: privacy
                    case .ready: ready
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(32)
            }
            Divider()
            HStack(spacing: 12) {
                Button("稍后再看") { model.skip() }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    .help("关闭引导，隐私选项尚未应用。可从设置中重新查看。")
                Spacer()
                if model.step != .welcome {
                    Button("上一步") { model.back() }
                }
                if model.step == .ready {
                    Button(model.loginError == nil ? "开始使用" : "重试并开始") { model.finish() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(model.step == .welcome ? "开始了解" : "下一步") { model.advance() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(minWidth: 640, minHeight: 530)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func heading(_ title: String, _ detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol).font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor).frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 26, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 26) {
            heading("欢迎使用 Clipa", "找回刚刚复制的内容，让每一次复制都用得上。", symbol: "doc.on.clipboard")
            VStack(alignment: .leading, spacing: 24) {
                feature("文本、图片和文件", "复制后保存在历史中，需要时快速找回。", symbol: "doc.text.image")
                feature("从键盘开始", "按 ⌃⌘V 打开，输入关键词，回车复制。", symbol: "keyboard")
                feature("保存在你的 Mac 上", "历史在本机加密存储，隐私选项由你决定。", symbol: "lock.shield")
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            Text("约一分钟完成。也可以稍后从「设置 → 通用 → 新手引导」重新查看。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var workflow: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("复制，再快速找回", "在任何应用按 ⌘C 复制，然后按 ⌃⌘V 打开 Clipa。", symbol: "keyboard")
            OnboardingSearchDemo()
            HStack(spacing: 22) {
                shortcut("↑ ↓", "选择条目")
                shortcut("↩", "复制并关闭")
                shortcut("⌘V", "回到原应用粘贴")
            }
            Text("空格查看详情，Esc 返回。Clipa 将内容放回剪贴板，由你在目标应用粘贴。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("决定哪些内容被记录", "以下选项将在点击「开始使用」后应用，之后可随时在设置中调整。", symbol: "hand.raised")
            VStack(alignment: .leading, spacing: 18) {
                privacyToggle("遵循来源应用的机密标记", "跳过来源应用标记为不应记录的复制内容。", value: $model.skipConfidential)
                Divider()
                privacyToggle("跳过疑似敏感内容", "检测到密钥、令牌或私钥时跳过记录，识别可能存在遗漏。", value: $model.skipSensitive)
                Divider()
                privacyToggle("跳过密码管理器", "忽略内置清单中的密码管理器复制行为。", value: $model.skipPasswordManagers)
            }
            .padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            Label("已保存的条目可右键设为私密。查看或复制时验证身份，60 秒后自动锁定；私密内容不参与搜索。", systemImage: "lock")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("准备好开始了", "Clipa 常驻顶部菜单栏，需要时按 ⌃⌘V 唤出。", symbol: "checkmark.circle")
            VStack(alignment: .leading, spacing: 16) {
                Toggle("登录时启动 Clipa", isOn: $model.launchAtLogin)
                Text("可选。打开后，登录 Mac 时自动运行；macOS 可能要求在系统设置中批准。")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                feature("更多选项都在设置中", "管理工作区、忽略应用、历史上限和本机程序授权。", symbol: "gearshape")
            }
            .padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            if let error = model.loginError {
                VStack(alignment: .leading, spacing: 12) {
                    Label("登录时启动尚未就绪：\(error)", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("打开系统登录项…") { SMAppService.openSystemSettingsLoginItems() }
                        Button("稍后处理，继续") { model.finish(acceptPendingLogin: true) }
                    }
                }.font(.callout)
            } else {
                Text(model.settings.pauseRecording
                     ? "你当前已暂停记录。开始后仍保持暂停，可在设置中恢复。"
                     : "开始后会记录符合隐私规则的复制内容。首次打开历史时，macOS 可能请求钥匙串授权。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func feature(_ title: String, _ detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func privacyToggle(_ title: String, _ detail: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.toggleStyle(.checkbox)
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(keys).font(.system(.body, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Text(action).font(.callout)
        }
    }
}

/// Interactive examples stay local to the view; they never read real history
/// or replace the user's clipboard.
private struct OnboardingSearchDemo: View {
    @State private var query = ""
    private let examples = ["明天下午三点，项目会议", "周五前确认设计方案", "https://example.com"]
    private var results: [String] {
        examples.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("试着搜索“会议”", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("搜索演示内容")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除演示搜索")
                }
            }.padding(14)
            Divider()
            VStack(spacing: 4) {
                if results.isEmpty {
                    Text("没有匹配的示例，换个关键词试试。").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 110)
                } else {
                    ForEach(Array(results.enumerated()), id: \.element) { index, text in
                        HStack {
                            Image(systemName: "doc.text")
                            Text(verbatim: text).lineLimit(1)
                            Spacer()
                            if index == 0 { Image(systemName: "return") }
                        }
                        .padding(10)
                        .foregroundStyle(index == 0 ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                        .background(index == 0 ? Color(nsColor: .selectedContentBackgroundColor) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.padding(8).frame(minHeight: 136, alignment: .top)
            Divider()
            Text("演示内容 · 不会读取或修改你的剪贴板")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4)))
    }
}
