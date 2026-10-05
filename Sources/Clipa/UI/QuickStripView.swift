import AppKit
import SwiftUI

private let noResultTitle = "没有找到相关的剪贴板内容。"
private let noResultSuggestions = [
    "少输入几个字，支持片段匹配",
    "给条目写过的备注也会被搜到",
    "确认当前工作区（⌃⌘1–9）：各工作区历史相互独立"
]

enum StoreUnavailableCopy {
    static let title = "Clipa 数据库暂时无法打开"
    static let reassurance = "历史数据没有被删除，仍完整保存在本机。"
    static let writePaused = "修复前不会记录新的复制内容。"
    static let summaryBar = "历史不可用"
    static let retry = "重试打开"
    static let openDirectory = "打开数据目录"
    static let retrySucceeded = "已重新连接数据库"
    static let retryFailed = "仍然无法打开数据库，历史数据未被删除"
    static let captureRejected = "数据库不可用，本次复制未记录"

    static func detail(for reason: ClipStoreUnavailabilityReason) -> String {
        switch reason {
        case .databaseUnreadable:
            return "数据库文件无法读取，可能已损坏或被其他程序占用。"
        case .historyUnreadable:
            return "数据库能打开，但读取历史时出错，可能存在局部损坏。"
        case .migrationFailed:
            return "数据库升级没有完成；文件本身通常是完整的，可以重试。"
        case .storageUnavailable:
            return "无法在数据目录中创建数据库，请检查磁盘空间与目录权限。"
        }
    }
}

/// The single floating panel (cmd+ctrl+V): Spotlight-style row list.
struct QuickStripView: View {
    @ObservedObject var vm: PanelViewModel
    @FocusState private var searchFocused: Bool

    @FocusState private var noteFieldFocused: Bool

    static let visibleCards = 5

    static let stripHorizontalPadding: CGFloat = ClipaTheme.Metrics.s12
    static let cardSpacing: CGFloat = ClipaTheme.Metrics.s8

    static let stripVerticalPadding: CGFloat = ClipaTheme.Metrics.s8

    static let topBarHeight: CGFloat = ClipaTheme.Metrics.headerHeight
    static let footerHeight: CGFloat = ClipaTheme.Metrics.footerHeight

    static let cardPageSize = PanelViewModel.listWindowPageSize

    static func cardWidth(in width: CGFloat) -> CGFloat {
        let count = CGFloat(visibleCards)
        let available = width
            - stripHorizontalPadding * 2
            - cardSpacing * (count - 1)
        return max(available / count, 120)
    }

    static func cardCenterX(index: Int, in width: CGFloat) -> CGFloat {
        stripHorizontalPadding
            + CGFloat(index) * (cardWidth(in: width) + cardSpacing)
            + cardWidth(in: width) / 2
    }

    static func cardHeight(in paneHeight: CGFloat) -> CGFloat {
        let chrome = topBarHeight + 2
        let resultsHeight = paneHeight - chrome - footerHeight
        return max(resultsHeight - stripVerticalPadding * 2, 0)
    }

    static func cardRowCenterY(in paneHeight: CGFloat) -> CGFloat {
        let chrome = topBarHeight + 2
        let resultsHeight = paneHeight - chrome - footerHeight
        return chrome + resultsHeight / 2
    }

    var onDismiss: () -> Void = {}

    var body: some View {
        resultsSurface
        .background { glassPane }
        .clipShape(paneShape)
        .overlay { paneRim }
        .overlay(alignment: .bottom) { floatingOverlays }

        .onChange(of: vm.openTick) { _, _ in
            guard vm.activeSurface == .quickStrip else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {

                guard vm.activeSurface == .quickStrip else { return }
                searchFocused = true
            }
        }
        .onChange(of: vm.query) { _, _ in
            vm.queryDidChange()
        }
        .onChange(of: vm.searchState) { _, _ in

            guard vm.activeSurface == .quickStrip else { return }
            switch vm.searchState {
            case .showingResults:

                if vm.isSearchFieldFocused {
                    DispatchQueue.main.async {
                        searchFocused = true
                    }
                }
            case .idle, .searching:
                break
            }
        }
        .onChange(of: searchFocused) { _, focused in
            vm.isSearchFieldFocused = focused
        }
        .onChange(of: vm.navigationOrder) { _, _ in
            if vm.selectedItem == nil, let first = vm.firstResultItem {
                vm.select(first)
            }
        }

        .environment(\.colorScheme, .light)
    }

    private var resultsSurface: some View {
        VStack(spacing: 0) {
            headerBar
            separator

            resultsArea
                .contentShape(Rectangle())
                .onTapGesture {
                    (vm.onPark ?? onDismiss)()
                }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.clipboard")
                .font(.system(size: ClipaTheme.IconSize.tile, weight: .regular))
                .foregroundStyle(ClipaTheme.Palette.textPrimary)
                .help("剪贴板历史")
            queryFieldTitle
            Spacer(minLength: 8)

            Text(vm.historyCountText)
                .font(.system(size: ClipaTheme.TypeScale.micro))
                .monospacedDigit()
                .foregroundStyle(ClipaTheme.Palette.textSecondary)
                .lineLimit(1)
                .help("当前显示的条数")
            overflowMenu
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerBarHeight)
    }

    static let headerBarHeight: CGFloat = ClipaTheme.Metrics.headerHeight

    static let rowHeight: CGFloat = ClipaTheme.Metrics.rowHeight

    static let listTopInset: CGFloat = headerBarHeight + 1

    static func rowCenterY(index: Int, in paneHeight: CGFloat) -> CGFloat {
        listTopInset + rowHeight * CGFloat(index) + rowHeight / 2
    }

    private var queryFieldTitle: some View {
        HStack(spacing: 8) {
            TextField("剪贴板", text: $vm.query)
                .textFieldStyle(.plain)
                .font(.system(size: ClipaTheme.TypeScale.display, weight: .medium))
                .foregroundStyle(ClipaTheme.Palette.textPrimary)
                .focused($searchFocused)
                .help(
                    "输入即过滤（正文与备注，多词同时命中）"
                        + " · 回车复制选中"
                )
                .onSubmit {
                    Task { await copySelectedAndDismiss() }
                }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: ClipaTheme.IconSize.control))
                        .foregroundStyle(ClipaTheme.Palette.textSecondary.opacity(0.8))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("清空搜索")
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .animation(.easeOut(duration: 0.12), value: vm.query.isEmpty)
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                vm.togglePaused()
            } label: {
                Label(
                    vm.settings.pauseRecording ? "恢复记录" : "暂停记录",
                    systemImage: vm.settings.pauseRecording
                        ? "play.circle" : "pause.circle"
                )
            }
            Button {
                vm.searchSort = vm.searchSort == .newest
                    ? .relevance : .newest
            } label: {
                Label(
                    vm.searchSort == .newest ? "排序：最新" : "排序：相关",
                    systemImage: "arrow.up.arrow.down"
                )
            }
            Divider()

        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: ClipaTheme.IconSize.tile))
                .foregroundStyle(ClipaTheme.Palette.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("面板操作")
    }

    static let paneCornerRadius: CGFloat = ClipaTheme.Metrics.radiusPane

    private var paneShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: Self.paneCornerRadius,
            style: .continuous
        )
    }

    private var glassPane: some View {
        ZStack {
            GlassBackdrop(
                scheme: .light,
                cornerRadius: Self.paneCornerRadius
            )

            paneShape.fill(ClipaTheme.Palette.surface.opacity(0.72))
        }
    }

    private var paneRim: some View {
        paneShape.strokeBorder(ClipaTheme.Palette.border, lineWidth: 1)
    }

    private var items: [Clip] {
        vm.renderedClips
    }

    @ViewBuilder
    private var resultsArea: some View {
        if items.isEmpty {
            emptyState
        } else {
            resultList
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        SpotlightRowView(
                            vm: vm,
                            item: item,
                            onDismiss: onDismiss
                        )
                            .id(item.id)
                    }

                    if vm.canLoadMoreCards {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { vm.extendRenderedWindow() }
                    }
                }
            }
            .onAppear {
                reveal(vm.selectedID, in: proxy)
            }
            .onChange(of: vm.revealRequestTick) { _, _ in
                reveal(vm.selectedID, in: proxy)
            }
            .onChange(of: vm.selectedID) { _, id in
                guard vm.revealSelection else { return }
                reveal(id, in: proxy)
            }
            .onChange(of: vm.openTick) { _, _ in
                reveal(vm.selectedID, in: proxy)
            }
            .onChange(of: vm.renderedClips.count) { _, _ in
                guard vm.revealSelection else { return }
                reveal(vm.selectedID, in: proxy)
            }
        }
        .frame(maxHeight: .infinity)
    }

        private func reveal(_ id: UUID?, in proxy: ScrollViewProxy) {

        defer { vm.consumeRevealRequest() }
        guard let id, items.contains(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let reason = vm.store.availability.reason {
            storeUnavailableView(reason: reason)
        } else if vm.store.items.isEmpty {
            emptyHistoryView
        } else {
            noMatchView
        }
    }

    private var emptyHistoryView: some View {
        VStack(spacing: ClipaTheme.Metrics.s8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: ClipaTheme.IconSize.hero, weight: .light))
                .foregroundStyle(ClipaTheme.Palette.textTertiary)
                .frame(height: 72)
            Text("复制任意内容，自动出现在这里")
                .font(.system(size: ClipaTheme.TypeScale.caption))
                .foregroundStyle(ClipaTheme.Palette.textPrimary)
            Text("⌃⌘V 随时唤出这个面板")
                .font(.system(size: ClipaTheme.TypeScale.micro))
                .foregroundStyle(ClipaTheme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ClipaTheme.IconSize.hero, weight: .light))
                .foregroundStyle(ClipaTheme.Palette.textTertiary.opacity(0.85))
            Text(noResultTitle)
                .font(.system(size: ClipaTheme.TypeScale.caption, weight: .medium))
                .foregroundStyle(ClipaTheme.Palette.textPrimary)
            VStack(alignment: .leading, spacing: 3) {
                Text("你可以尝试：")
                    .font(.system(size: ClipaTheme.TypeScale.micro))
                    .foregroundStyle(ClipaTheme.Palette.textSecondary)
                ForEach(noResultSuggestions, id: \.self) { suggestion in
                    Text("• \(suggestion)")
                        .font(.system(size: ClipaTheme.TypeScale.micro))
                        .foregroundStyle(ClipaTheme.Palette.textSecondary.opacity(0.9))
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func storeUnavailableView(
        reason: ClipStoreUnavailabilityReason
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: ClipaTheme.IconSize.hero, weight: .light))
                .foregroundStyle(ClipaTheme.Palette.destructive)
            Text(StoreUnavailableCopy.title)
                .font(.system(size: ClipaTheme.TypeScale.body, weight: .semibold))
                .foregroundStyle(ClipaTheme.Palette.textPrimary)
            Text(StoreUnavailableCopy.reassurance)
                .font(.system(size: ClipaTheme.TypeScale.micro))
                .foregroundStyle(ClipaTheme.Palette.textSecondary)
            Text(StoreUnavailableCopy.detail(for: reason))
                .font(.system(size: ClipaTheme.TypeScale.micro))
                .foregroundStyle(ClipaTheme.Palette.textSecondary.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(StoreUnavailableCopy.writePaused)
                .font(.system(size: ClipaTheme.TypeScale.micro))
                .foregroundStyle(ClipaTheme.Palette.destructive.opacity(0.9))
            HStack(spacing: 8) {
                Button(StoreUnavailableCopy.retry) {
                    vm.retryStoreConnection()
                }
                Button(StoreUnavailableCopy.openDirectory) {
                    vm.revealDataDirectory()
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var separator: some View {
        Rectangle()
            .fill(ClipaTheme.Palette.separator)
            .frame(height: 1)
    }

    private var floatingOverlays: some View {
        VStack(spacing: 8) {
            if vm.showNoteEditor {
                editorsCard
            }
            if let toast = vm.toast {

                Text(toast)
                    .font(.system(size: ClipaTheme.TypeScale.caption, weight: .medium))
                    .foregroundStyle(ClipaTheme.Palette.surface)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(
                            ClipaTheme.Palette.textPrimary.opacity(0.92)
                        )
                    )
                    .overlay {
                        Capsule().strokeBorder(
                            ClipaTheme.Palette.separator.opacity(0.45),
                            lineWidth: 0.6
                        )
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(duration: 0.25), value: vm.toast)
            }
        }
        .padding(.bottom, 36)
    }

    private var editorsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: ClipaTheme.IconSize.control, weight: .medium))
                    .foregroundStyle(ClipaTheme.Palette.textSecondary)
                Text("编辑备注")
                    .font(.system(size: ClipaTheme.TypeScale.micro, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(ClipaTheme.Palette.textSecondary)
                Spacer(minLength: 8)
                if let item = vm.selectedItem {
                    noteTargetChip(for: item)
                }
            }
            noteEditor
            Text("⏎ 保存 · esc 取消")
                .font(.system(size: ClipaTheme.TypeScale.micro))
                .foregroundStyle(ClipaTheme.Palette.textSecondary.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: 520)
        .background {
            RoundedRectangle(
                cornerRadius: ClipaTheme.Metrics.radiusPane,
                style: .continuous
            )
            .fill(ClipaTheme.Palette.surfaceShade)
        }
        .overlay {

            RoundedRectangle(
                cornerRadius: ClipaTheme.Metrics.radiusPane,
                style: .continuous
            )
                .strokeBorder(
                    noteFieldFocused
                        ? ClipaTheme.Palette.accent
                        : ClipaTheme.Palette.border,
                    lineWidth: noteFieldFocused ? 2 : 1
                )
        }
        .shadow(
            color: ClipaTheme.Palette.shadow.opacity(0.18),
            radius: 16,
            y: 8
        )
        .padding(.horizontal, ClipaTheme.Metrics.s16)
        .onAppear {

            DispatchQueue.main.async { noteFieldFocused = true }
        }
    }

    private func noteTargetChip(for item: Clip) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: ClipaTheme.IconSize.inline, weight: .medium))
            Text(item.kind.displayName)
                .font(.system(size: ClipaTheme.TypeScale.micro, weight: .semibold))
            if let hint = noteTargetHint(for: item) {
                Text(hint)
                    .font(.system(size: ClipaTheme.TypeScale.micro))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(ClipaTheme.Palette.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(maxWidth: 240, alignment: .leading)
        .overlay {

            Capsule().strokeBorder(
                ClipaTheme.Palette.textPrimary.opacity(0.25),
                lineWidth: 0.8
            )
        }
    }

    private func noteTargetHint(for item: Clip) -> String? {
        if item.isPrivate { return "私密 · 已解锁" }
        let body = item.text.isEmpty
            ? (item.fileURLs.first?.lastPathComponent ?? "")
            : item.text
        let collapsed = body
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(28))
    }

    private var noteEditor: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: ClipaTheme.IconSize.inline))
                    .foregroundStyle(
                        noteFieldFocused
                            ? ClipaTheme.Palette.accent
                            : ClipaTheme.Palette.textSecondary
                    )
                TextField("写条备注…", text: $vm.noteDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClipaTheme.TypeScale.body))
                    .foregroundStyle(ClipaTheme.Palette.textPrimary)
                    .focused($noteFieldFocused)
                    .onSubmit {
                        Task { await vm.saveNoteAsync() }
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(
                    cornerRadius: ClipaTheme.Metrics.radiusControl,
                    style: .continuous
                )
                .fill(ClipaTheme.Palette.surface)
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: ClipaTheme.Metrics.radiusControl,
                    style: .continuous
                )
                    .strokeBorder(
                        noteFieldFocused
                            ? ClipaTheme.Palette.accent
                            : ClipaTheme.Palette.border,
                        lineWidth: noteFieldFocused ? 2 : 1
                    )
            }
            NotePillButton(title: "保存", prominent: true) {
                Task { await vm.saveNoteAsync() }
            }
            NotePillButton(title: "取消", prominent: false) {
                vm.showNoteEditor = false
            }
        }
    }

    func copySelectedAndDismiss() async {
        guard let item = vm.selectedItem else { return }

        guard await vm.copyAsync(item) else { return }
        onDismiss()
    }
}

private struct NotePillButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(
                    .system(
                        size: 11.5,
                        weight: prominent ? .semibold : .regular
                    )
                )
                .foregroundStyle(
                    prominent
                        ? ClipaTheme.Palette.onAccent
                        : ClipaTheme.Palette.textSecondary
                )
                .padding(.horizontal, ClipaTheme.Metrics.s12)
                .frame(height: 30)
                .background {
                    RoundedRectangle(
                        cornerRadius: ClipaTheme.Metrics.radiusControl,
                        style: .continuous
                    )
                        .fill(fill)
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ClipaTheme.Metrics.radiusControl,
                        style: .continuous
                    )
                        .strokeBorder(
                            prominent
                                ? AnyShapeStyle(Color.clear)
                                : AnyShapeStyle(
                                    ClipaTheme.Palette.border
                                ),
                            lineWidth: 1
                        )
                }
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: ClipaTheme.Metrics.radiusControl,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var fill: AnyShapeStyle {
        guard prominent else {
            return AnyShapeStyle(
                ClipaTheme.Palette.fill.opacity(isHovered ? 1 : 0)
            )
        }
        return AnyShapeStyle(
            isHovered
                ? ClipaTheme.Palette.accentPressed
                : ClipaTheme.Palette.accent
        )
    }
}

private struct ToolbarIconButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: ClipaTheme.IconSize.control, weight: .medium))
                .foregroundStyle(
                    isHovered
                        ? ClipaTheme.Palette.textPrimary
                        : tint
                )
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(
                        cornerRadius: ClipaTheme.Metrics.radiusControl,
                        style: .continuous
                    )
                        .fill(
                            ClipaTheme.Palette.fill.opacity(isHovered ? 1 : 0)
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct SpotlightRowView: View {
    @ObservedObject var vm: PanelViewModel
    let item: Clip

    let onDismiss: () -> Void

    @State private var isHovered = false

    @State private var appIndexTick = 0

    private var isSelected: Bool { vm.selectedID == item.id }
    private var isLocked: Bool {
        item.isPrivate && !vm.isPrivateUnlocked(item)
    }
    private var showsSensitive: Bool {
        !isLocked && vm.isSensitive(item)
    }

    var body: some View {

        rowContent
            .contentShape(Rectangle())
            .onTapGesture { vm.selectGated(item) }
            .onHover { isHovered = $0 }
            .contextMenu { rowMenu }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: SpotlightRowView.appIndexDidBuild
                )
            ) { _ in
                appIndexTick += 1
            }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {

                    if !isLocked {
                        sourceAppBadge
                            .id(appIndexTick)
                            .offset(x: 4, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .font(.system(size: ClipaTheme.TypeScale.body))
                    .foregroundStyle(ClipaTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rowSubtitle)
                    .font(.system(size: ClipaTheme.TypeScale.micro))
                    .foregroundStyle(ClipaTheme.Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsSensitive {
                Image(systemName: "lock.shield")
                    .font(.system(size: ClipaTheme.IconSize.inline))
                    .foregroundStyle(ClipaTheme.Palette.destructive.opacity(0.9))
            }
            pasteButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, ClipaTheme.Metrics.s8)
        .background {
            RoundedRectangle(
                cornerRadius: ClipaTheme.Metrics.radiusRow,
                style: .continuous
            )
                .fill(
                    isSelected
                        ? ClipaTheme.Palette.accent.opacity(0.12)
                        : isHovered
                            ? ClipaTheme.Palette.textPrimary.opacity(0.05)
                            : Color.clear
                )
        }
        .padding(.horizontal, 8)
    }

    private static let iconLock = NSLock()
    private static var iconStore: [String: NSImage?] = [:]
    private static var nameIndexStorage: [String: URL]?
    private static let indexStateLock = NSLock()
    private static var indexBuildStarted = false

    static let appIndexDidBuild = Notification.Name("ClipaAppIndexDidBuild")
    private static let indexRoots = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        NSHomeDirectory() + "/Applications",
    ]

    private static func fold(_ s: String) -> String {
        s.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        .replacingOccurrences(of: " ", with: "")
    }

    private static func buildAppIndex() -> [String: URL] {
        var index: [String: URL] = [:]

        let query = MDQueryCreate(
            kCFAllocatorDefault,
            "(kMDItemContentTypeTree = 'com.apple.application')" as CFString,
            ["kMDItemDisplayName", "kMDItemFSName"] as CFArray,
            nil
        )
        if let query, MDQueryExecute(
            query, CFOptionFlags(kMDQuerySynchronous.rawValue)
        ) {
            let count = MDQueryGetResultCount(query)
            for i in 0..<count {

                guard let raw = MDQueryGetResultAtIndex(query, i) else {
                    continue
                }
                let item = unsafeBitCast(raw, to: MDItem.self)
                guard let path = MDItemCopyAttribute(item, kMDItemPath)
                    as? String
                else { continue }
                let url = URL(fileURLWithPath: path)
                let display = MDItemCopyAttribute(item, kMDItemDisplayName)
                    as? String
                let fs = MDItemCopyAttribute(item, kMDItemFSName) as? String
                if let display, !display.isEmpty {
                    index[fold(display), default: url] = url
                }
                if let fs, !fs.isEmpty {
                    let base = (fs as NSString).deletingPathExtension
                    index[fold(base), default: url] = url
                }
            }
        }

        if index.count < 10 {
            let fm = FileManager.default
            for root in indexRoots {
                guard let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: nil,
                    options: [.skipsPackageDescendants]
                ) else { continue }
                for case let url as URL in enumerator
                where url.pathExtension == "app" {
                    let base = url.deletingPathExtension().lastPathComponent
                    index[fold(base), default: url] = url
                }
            }
        }

        return index
    }

    static func buildAppIndexForTesting() {
        let built = buildAppIndex()
        indexStateLock.lock()
        nameIndexStorage = built
        indexStateLock.unlock()
    }

    private static func ensureAppIndexBuilding() {
        indexStateLock.lock()
        let started = indexBuildStarted
        indexBuildStarted = true
        indexStateLock.unlock()
        guard !started else { return }
        DispatchQueue.global(qos: .utility).async {
            let built = buildAppIndex()
            indexStateLock.lock()
            nameIndexStorage = built
            indexStateLock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: SpotlightRowView.appIndexDidBuild,
                    object: nil
                )
            }
        }
    }

    private static func currentAppIndex() -> [String: URL] {
        indexStateLock.lock()
        defer { indexStateLock.unlock() }
        return nameIndexStorage ?? [:]
    }

    private static var indexIsBuilt: Bool {
        indexStateLock.lock()
        defer { indexStateLock.unlock() }
        return nameIndexStorage != nil
    }

    static func appIcon(
        forAppName name: String? = nil,
        bundleID: String? = nil
    ) -> NSImage? {
        let hasName = !(name?.isEmpty ?? true)
        let hasBundle = !(bundleID?.isEmpty ?? true)
        guard hasName || hasBundle else { return nil }
        let cacheKey = hasBundle ? "bundle:\(bundleID!)" : name!
        if !indexIsBuilt { ensureAppIndexBuilding() }
        iconLock.lock()
        defer { iconLock.unlock() }
        if let cached = iconStore[cacheKey] { return cached }
        var resolved: NSImage?

        if hasBundle,
           let url = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: bundleID!
           ) {
            resolved = NSWorkspace.shared.icon(forFile: url.path)
        }

        if resolved == nil, hasName {
            let folded = fold(name!)
            if let running = NSWorkspace.shared.runningApplications
                .first(where: { fold($0.localizedName ?? "") == folded }) {
                resolved = running.icon
            }

            guard indexIsBuilt else { return resolved }
            let index = currentAppIndex()
            if resolved == nil {
                if let url = index[folded] {
                    resolved = NSWorkspace.shared.icon(forFile: url.path)
                } else {
                    let hit = index.keys
                        .filter {
                            !$0.isEmpty && ($0.contains(folded) || folded.contains($0))
                        }
                        .min(by: { $0.count < $1.count })
                    if let hit, let url = index[hit] {
                        resolved = NSWorkspace.shared.icon(forFile: url.path)
                    }
                }
            }
        }
        iconStore[cacheKey] = resolved
        return resolved
    }

    @ViewBuilder
    private var sourceAppBadge: some View {
        if let icon = Self.appIcon(
            forAppName: item.sourceApp,
            bundleID: item.sourceBundle
        ) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if isLocked {
            RoundedRectangle(cornerRadius: ClipaTheme.Metrics.radiusRow, style: .continuous)
                .fill(ClipaTheme.Palette.veil)
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: ClipaTheme.IconSize.control, weight: .semibold))
                        .foregroundStyle(ClipaTheme.Palette.surface)
                }
        } else if item.kind == .image {
            StripThumbnailView(item: item, store: vm.store)
                .clipShape(RoundedRectangle(cornerRadius: ClipaTheme.Metrics.radiusRow, style: .continuous))
        } else if item.kind == .file {

            RoundedRectangle(cornerRadius: ClipaTheme.Metrics.radiusRow, style: .continuous)
                .fill(ClipaTheme.Palette.surfaceShade)
                .overlay {
                    Image(
                        systemName: item.fileURLs.first?.pathExtension
                            .lowercased() == "pdf"
                            ? "doc.richtext.fill"
                            : "folder"
                    )
                    .font(.system(size: ClipaTheme.IconSize.tile))
                    .foregroundStyle(ClipaTheme.Palette.textSecondary)
                }
        } else if item.smartTag == .json {

            RoundedRectangle(cornerRadius: ClipaTheme.Metrics.radiusRow, style: .continuous)
                .fill(ClipaTheme.Palette.surfaceShade)
                .overlay {
                    Text("{ }")
                        .font(
                            .system(
                                size: ClipaTheme.TypeScale.title,
                                weight: .semibold,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(ClipaTheme.Palette.textSecondary)
                }
        } else if item.smartTag == .yaml {

            RoundedRectangle(cornerRadius: ClipaTheme.Metrics.radiusRow, style: .continuous)
                .fill(ClipaTheme.Palette.surfaceShade)
                .overlay {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 3) {
                            Capsule().fill(ClipaTheme.Palette.textSecondary.opacity(0.45))
                                .frame(width: 5, height: 2)
                            Capsule().fill(ClipaTheme.Palette.textSecondary.opacity(0.35))
                                .frame(width: 14, height: 2)
                        }
                        HStack(spacing: 3) {
                            Capsule().fill(Color.clear)
                                .frame(width: 8, height: 2)
                            Capsule().fill(ClipaTheme.Palette.textSecondary.opacity(0.45))
                                .frame(width: 5, height: 2)
                            Capsule().fill(ClipaTheme.Palette.textSecondary.opacity(0.35))
                                .frame(width: 10, height: 2)
                        }
                    }
                }
        } else {

            RoundedRectangle(cornerRadius: ClipaTheme.Metrics.radiusRow, style: .continuous)
                .fill(ClipaTheme.Palette.surfaceShade)
                .overlay {
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(ClipaTheme.Palette.textSecondary.opacity(0.35))
                            .frame(width: 22, height: 2)
                        Capsule().fill(ClipaTheme.Palette.textSecondary.opacity(0.25))
                            .frame(width: 16, height: 2)
                        Capsule().fill(ClipaTheme.Palette.textSecondary.opacity(0.18))
                            .frame(width: 19, height: 2)
                    }
                }
        }
    }

    private var rowTitle: String {
        if isLocked { return "已上锁的私密条目" }
        switch item.kind {
        case .image:
            return item.fileURLs.first?.lastPathComponent ?? "图像"
        case .file:
            return item.fileURLs.first?.lastPathComponent ?? "文件"
        default:
            return ClipPreview.display(for: item.text, limit: 120)
        }
    }

    private var rowSubtitle: String {
        var parts: [String] = []
        if isLocked {
            parts.append("私密")
        } else {
            parts.append(item.typePresentation.title)
            if item.hasNote { parts.append("✎ " + item.note) }
        }
        parts.append("拷贝于 " + vm.relativeTime(for: item.lastCopiedAt))
        return parts.joined(separator: " · ")
    }

    private var pasteButton: some View {
        Button {
            Task {
                if await vm.copyAsync(item) {
                    onDismiss()
                }
            }
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: ClipaTheme.IconSize.inline, weight: .medium))
                .foregroundStyle(ClipaTheme.Palette.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(
                        ClipaTheme.Palette.textSecondary.opacity(
                            isHovered ? 0.14 : 0.08
                        )
                    )
                )
        }
        .buttonStyle(.plain)
        .help("复制并收起")
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button {
            Task { await vm.copyAsync(item) }
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            Task { await vm.togglePrivateAsync(item) }
        } label: {
            Label(
                item.isPrivate ? "取消私密" : "设为私密",
                systemImage: item.isPrivate ? "lock.open" : "lock"
            )
        }
        .help(PrivateCoverDisclosure.note)
        if item.isPrivate, !vm.isPrivateUnlocked(item) {
            Button {
                vm.unlockForPreview(item)
            } label: {
                Label("解锁查看（60 秒）", systemImage: "touchid")
            }
        }
        Button {
            vm.openNoteEditor(item)
        } label: {
            Label("添加 / 编辑备注", systemImage: "square.and.pencil")
        }
        Divider()
        Button(role: .destructive) {
            Task { await vm.deleteAsync(item) }
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}

private struct GlassBackdrop: NSViewRepresentable {
    var scheme: ColorScheme
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {

        let light = NSAppearance(named: .aqua)
        if #available(macOS 26.0, *) {
            let view = InertGlassEffectView()
            view.style = .clear
            view.cornerRadius = cornerRadius
            view.appearance = light
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            return view
        }
        let view = InertVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = light
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            return
        }
        if let effect = view as? InertVisualEffectView {
            apply(to: effect)
        }
    }

    private func apply(to view: InertVisualEffectView) {

        view.material = scheme == .dark ? .hudWindow : .underWindowBackground
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
    }
}

@available(macOS 26.0, *)
private final class InertGlassEffectView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class InertVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct StripThumbnailView: View {
    let item: Clip
    let store: ClipStore

    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    nonisolated static let maxPixel = 1024

    nonisolated static let minPixel = 480

    private static let decodedCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(nsImage: image)

                        .interpolation(.high)
                        .resizable()
                        .scaledToFit()
                        .clipShape(
                            RoundedRectangle(cornerRadius: ClipaTheme.Metrics.radiusRow, style: .continuous)
                        )
                        .background {
                            RoundedRectangle(cornerRadius: ClipaTheme.Metrics.radiusRow, style: .continuous)
                                .fill(ClipaTheme.Palette.surface.opacity(0.6))
                        }
                } else {

                    RoundedRectangle(cornerRadius: ClipaTheme.Metrics.radiusRow, style: .continuous)
                        .fill(ClipaTheme.Palette.surfaceShade)
                        .overlay {
                            RoundedRectangle(cornerRadius: ClipaTheme.Metrics.radiusRow, style: .continuous)
                                .strokeBorder(
                                    ClipaTheme.Palette.textPrimary.opacity(0.25),
                                    style: StrokeStyle(
                                        lineWidth: 0.9,
                                        dash: [4, 3]
                                    )
                                )
                        }
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: ClipaTheme.IconSize.tile))
                                .foregroundStyle(
                                    ClipaTheme.Palette.textSecondary.opacity(0.7)
                                )
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: item.id) {
                await decodeImage(boxSize: proxy.size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func decodeImage(boxSize: CGSize) async {
        let clip = item
        let source = store

        let maxPixel = Self.previewMaxPixel(
            boxSize: boxSize,
            displayScale: displayScale
        )

        let cacheKey = "\(clip.dbID)-\(maxPixel)" as NSString
        if let cached = Self.decodedCache.object(forKey: cacheKey) {
            image = cached
            return
        }

        guard let data = await source.imageDataAsync(for: clip) else {
            image = nil
            return
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decodePreview(data, maxPixel: maxPixel)
        }.value
        image = decoded
        if let decoded {
            Self.decodedCache.setObject(
                decoded,
                forKey: cacheKey,
                cost: maxPixel * maxPixel * 4
            )
        }
    }

    nonisolated static func previewMaxPixel(
        boxSize: CGSize,
        displayScale: CGFloat
    ) -> Int {
        let longestPoint = max(boxSize.width, boxSize.height)
        let physical = Int((longestPoint * max(displayScale, 1)).rounded())
        return min(max(physical, minPixel), maxPixel)
    }

    nonisolated static func decodePreview(
        _ data: Data,
        maxPixel: Int
    ) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return NSImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return NSImage(data: data)
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
