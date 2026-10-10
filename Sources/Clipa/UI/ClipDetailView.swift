import AppKit
import SwiftUI

/// On-demand detail preserves the compact history layout. Private content is
/// rendered only while unlocked, and uses the guarded copy action.
@MainActor
struct ClipDetailView: View {
    @ObservedObject var vm: PanelViewModel
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { vm.previewID = nil } label: {
                    Label("返回", systemImage: "chevron.left")
                }.buttonStyle(.borderless).help("返回历史列表（Esc）")
                Spacer()
                Text("内容详情").font(.headline)
                Spacer()
                Button("添加备注", systemImage: "square.and.pencil") {
                    vm.openNoteEditor(vm.previewItem)
                }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(vm.previewItem == nil || vm.privateUnlockInFlight)
            }.padding(18)
            Divider()
            if let item = vm.previewItem {
                if item.isPrivate && !vm.isPrivateUnlocked(item) {
                    VStack(spacing: 14) {
                        Image(systemName: "lock.fill").font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("私密内容已锁定").font(.title3.weight(.semibold))
                        Text("验证身份后可查看，60 秒后自动锁定。")
                            .font(.callout).foregroundStyle(.secondary)
                        if vm.privateUnlockInFlight {
                            ProgressView("等待系统验证…").controlSize(.small)
                        } else {
                            Button("验证身份并查看") { vm.unlockForPreview(item) }
                                .buttonStyle(.borderedProminent)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    unlockedDetail(item)
                }
                Divider()
                HStack {
                    Text(item.isPrivate ? "私密内容 · 仅通过复制按钮复制" : "空格或 Esc 返回")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if vm.copyingID == item.id { ProgressView().controlSize(.small) }
                    Button(item.isPrivate && !vm.isPrivateUnlocked(item) ? "解锁并复制" : "复制并关闭") {
                        Task { if await vm.copyAsync(item) { onDismiss() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.copyingID != nil || vm.privateUnlockInFlight)
                }.padding(16)
            } else {
                ContentUnavailableView("条目已不存在", systemImage: "doc.badge.ellipsis",
                                       description: Text("它可能已被删除，返回列表后可继续浏览其他内容。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func unlockedDetail(_ item: Clip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(item.typePresentation.title, systemImage: item.typePresentation.symbolName)
                if let source = item.sourceApp { Text("· " + source) }
                Spacer()
                Text(item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption).foregroundStyle(.secondary)
            if item.kind == .image {
                StripThumbnailView(item: item, store: vm.store, showsLoadErrorDetails: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if item.kind == .file {
                            ForEach(Array(item.fileURLs.prefix(50).enumerated()), id: \.offset) { _, url in
                                HStack {
                                    Label(url.lastPathComponent, systemImage: "doc")
                                    Spacer()
                                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                        .disabled(!FileManager.default.fileExists(atPath: url.path))
                                }
                            }
                            if item.fileURLs.count > 50 { Text("另有 \(item.fileURLs.count - 50) 个文件。复制会包含所有文件。").foregroundStyle(.secondary) }
                        } else {
                            textBody(item)
                            if item.text.prefix(20_001).count > 20_000 {
                                Text("预览展示前 20,000 个字，复制时保留完整内容。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if item.hasNote {
                            Divider()
                            Label("备注", systemImage: "note.text").font(.headline)
                            Text(verbatim: item.note).font(.callout).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func textBody(_ item: Clip) -> some View {
        let text = Text(verbatim: String(item.text.prefix(20_000)))
            .font(.system(size: 13, design: item.smartTag == .json || item.smartTag == .yaml ? .monospaced : .default))
            .frame(maxWidth: .infinity, alignment: .leading)
        if item.isPrivate { text }
        else { text.textSelection(.enabled) }
    }
}
