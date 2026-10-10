import AppKit
import SwiftUI

/// Single source of wording for the store recovery state, so the popup, the
/// toast and the menu bar can never disagree about what happened.
///
/// This lived in the ⌃⌘V main panel until that page was retired; the bottom
/// popup inherited it together with the rest of the panel's modules.
enum StoreUnavailableCopy {
    static let title = "Clipa 数据库暂时无法打开"
    static let reassurance = "现有历史保留在本机，此时不会覆盖或清空数据。"
    static let writePaused = "修复前不会记录新的复制内容。"
    static let summaryBar = "历史不可用"
    static let retry = "重试打开"
    static let openDirectory = "打开数据目录"
    static let retrySucceeded = "已重新连接数据库"
    static let retryFailed = "仍然无法打开数据库，历史数据未被删除"
    static let captureRejected = "数据库不可用，本次复制未记录"

    static func detail(for reason: ClipStoreUnavailabilityReason) -> String {
        switch reason {
        case .keyUnavailable:
            return "钥匙串暂时不可用。请解锁此 Mac 或允许 Clipa 访问密钥后重试。"
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

/// Clipa's one and only clipboard page: the floating panel.
///
/// ⌃⌘V 唤出（水平居中、垂直中心 54%，滑入滑出动画）。承载全部功能：
/// 全文搜索（正文 + 备注）、暂停记录、备注、私密夹、store 恢复态，
/// 以及每行的右键菜单（复制 / 私密 / 解锁 / 备注 / 删除）。
struct QuickStripView: View {
    @ObservedObject var vm: PanelViewModel
    var forceOpaqueSurface = false
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 备注编辑器打开时把键盘交给那个输入框 —— 打开编辑器还要先点一下才能打字，
    /// 是这类浮层最常见的粗糙处。
    @FocusState private var noteFieldFocused: Bool

    /// Cards visible at once. Five keeps a card wide enough for a real text
    /// preview at a readable size instead of a wall of tiny lines.
    static let visibleCards = 5
    /// Gutter and card gap of the horizontal card row.
    static let stripHorizontalPadding: CGFloat = ClipaTheme.Metrics.s12
    static let cardSpacing: CGFloat = ClipaTheme.Metrics.s8
    /// Vertical inset of the card row inside the results area.
    static let stripVerticalPadding: CGFloat = ClipaTheme.Metrics.s8
    /// Chrome heights, shared with the layout below and with the probes that
    /// compute where a card sits in the window.
    ///
    /// One row above the results: the brand mark hugs the left edge, the
    /// search field sits on the pane's centre line, and the pause toggle hugs
    /// the right edge.
    static let topBarHeight: CGFloat = headerBarHeight
    static let footerHeight: CGFloat = ClipaTheme.Metrics.footerHeight
    /// First page of cards built when the row opens, and the size of every
    /// page loaded afterwards. The row pages through the *whole* result set —
    /// a 100k-row library is reachable by scrolling, three hundred cards at a
    /// time, without ever building more than one page of views.
    static let cardPageSize = PanelViewModel.listWindowPageSize

    /// Card width for a given pane width, and the x centre of the card at
    /// `index` — one place for the geometry the layout and the probes share.
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

    /// Height of one card for a given pane height. The cards fill the results
    /// area minus its vertical inset.
    static func cardHeight(in paneHeight: CGFloat) -> CGFloat {
        let chrome = topBarHeight + 2
        let resultsHeight = paneHeight - chrome - footerHeight
        return max(resultsHeight - stripVerticalPadding * 2, 0)
    }

    /// Y offset, inside the pane, of the vertical centre of the card row.
    static func cardRowCenterY(in paneHeight: CGFloat) -> CGFloat {
        let chrome = topBarHeight + 2
        let resultsHeight = paneHeight - chrome - footerHeight
        return chrome + resultsHeight / 2
    }

    /// Called when the user asks for something that should dismiss the popup
    /// (press Esc, copy a row, click the list background).
    var onDismiss: () -> Void = {}

    var body: some View {
        primarySurface
        .background { glassPane }
        .clipShape(paneShape)
        .overlay { paneRim }
        .overlay(alignment: .bottom) { floatingOverlays }
        // The NSPanel supplies the system shadow; content has no synthetic glow.
        .onChange(of: vm.openTick) { _, _ in
            guard vm.activeSurface == .quickStrip else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                // P2 修复（2026-10-03）：延迟聚焦在触发时**复查**状态——面板
                // 可能在 0.12s 内已经隐藏或切了表面，无条件聚焦会抢走别处光标。
                guard vm.activeSurface == .quickStrip else { return }
                if vm.showNoteEditor { noteFieldFocused = true }
                else if vm.previewID == nil { searchFocused = true }
            }
        }
        .onChange(of: vm.query) { _, _ in
            vm.queryDidChange()
        }
        .onChange(of: vm.searchState) { _, _ in
            // Every search re-renders the cards; the caret has to stay in the
            // search box through that, or typing dies after one character.
            guard vm.activeSurface == .quickStrip else { return }
            switch vm.searchState {
            case .showingResults:
                // P2 修复（2026-10-03）：只在**光标本就在搜索框**时才拉回
                // ——用户正在备注编辑器里打字时，结果返回不该把光标抢走。
                if vm.isSearchFieldFocused {
                    DispatchQueue.main.async {
                        searchFocused = true
                    }
                }
            case .idle, .searching:
                break
            }
        }
        .onChange(of: vm.copyingID) { _, id in
            if id == nil, vm.activeSurface == .quickStrip, vm.previewID == nil, !vm.showNoteEditor {
                searchFocused = true
            }
        }
        .onChange(of: vm.previewID) { _, id in
            if id == nil, vm.activeSurface == .quickStrip { searchFocused = true }
        }
        .onChange(of: vm.noteDiscardConfirmation) { _, confirming in
            if !confirming, vm.showNoteEditor { noteFieldFocused = true }
        }
        .onChange(of: vm.showNoteEditor) { _, showing in
            if !showing, vm.activeSurface == .quickStrip { searchFocused = true }
        }
        .onChange(of: searchFocused) { _, focused in
            vm.isSearchFieldFocused = focused
        }
        .onChange(of: vm.navigationOrder) { _, _ in
            if vm.selectedItem == nil, let first = vm.firstResultItem {
                vm.select(first)
            }
        }
    }

    @ViewBuilder private var primarySurface: some View {
        if vm.previewID != nil { ClipDetailView(vm: vm, onDismiss: onDismiss) }
        else { resultsSurface }
    }

    private var usesOpaqueSurface: Bool { forceOpaqueSurface || reduceTransparency }

    private var resultsSurface: some View {
        VStack(spacing: 0) {
            headerBar
            filterBar
            separator
            resultsArea
                .background(ClipaTheme.Palette.surfaceShade.opacity(usesOpaqueSurface ? 1 : 0.38))
            separator
            footerBar
        }
    }

    // MARK: - Search and scope

    static let filterBarHeight: CGFloat = 40
    static let headerBarHeight: CGFloat = ClipaTheme.Metrics.headerHeight + filterBarHeight
    static let rowHeight: CGFloat = ClipaTheme.Metrics.rowHeight
    static let listTopInset: CGFloat = headerBarHeight + 1

    static func rowCenterY(index: Int, in paneHeight: CGFloat) -> CGFloat {
        listTopInset + rowHeight * CGFloat(index) + rowHeight / 2
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索剪贴板历史", text: $vm.query)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular))
                .focused($searchFocused)
                .disabled(vm.copyingID != nil || vm.privateUnlockInFlight)
                .accessibilityLabel("搜索剪贴板历史")
                .help("搜索正文和备注，多个关键词同时匹配")
                .onSubmit { Task { await copySelectedAndDismiss() } }
            if vm.searchState == .searching {
                ProgressView().controlSize(.small).scaleEffect(0.75)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("正在搜索")
            }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 16))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 22)
        .frame(height: ClipaTheme.Metrics.headerHeight)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("内容类型", selection: Binding(
                get: { vm.kindFilter },
                set: {
                    vm.kindFilter = $0
                    vm.smartTagFilter = nil
                    vm.filtersDidChange()
                }
            )) {
                Text("全部").tag(Optional<ClipKind>.none)
                ForEach(ClipKind.allCases) { kind in
                    Text(kind.displayName).tag(Optional(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("筛选内容类型")
            .disabled(!vm.store.availability.isReady || vm.noteIsSaving || vm.copyingID != nil)
            Spacer(minLength: 4)
            Button { AppDelegate.shared?.showManagement(.workspaces) } label: {
                Label(WorkspaceStore.shared.activeWorkspace.name, systemImage: "square.stack.3d.up")
                    .font(.system(size: 11)).lineLimit(1).frame(maxWidth: 110)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("切换与管理工作区")
            Text(vm.store.availability.isReady ? vm.historyCountText : "历史不可用")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(vm.historyCountText)
            Menu {
                Picker("排序方式", selection: $vm.searchSort) {
                    Text("相关程度").tag(SearchSort.relevance)
                    Text("最近复制").tag(SearchSort.newest)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("结果排序")
            .accessibilityLabel("结果排序")
            .disabled(!vm.store.availability.isReady)
            Button { AppDelegate.shared?.showManagement() } label: {
                Image(systemName: "gearshape").frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless).help("设置（⌘,）").accessibilityLabel("打开设置")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(height: Self.filterBarHeight)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Text("Clipa")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            if vm.store.availability.isReady {
                Button { vm.togglePaused() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: vm.settings.pauseRecording ? "pause.circle.fill" : "record.circle")
                            .foregroundStyle(vm.settings.pauseRecording ? Color.orange : Color.secondary)
                        Text(vm.settings.pauseRecording ? "已暂停" : "正在记录")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(vm.settings.pauseRecording ? "恢复剪贴板记录" : "暂停剪贴板记录")
                .accessibilityLabel(vm.settings.pauseRecording ? "恢复记录" : "暂停记录")
            } else {
                Label("历史不可用", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if vm.pendingNoteCount > 0, !vm.showNoteEditor {
                Button { vm.resumeNoteDraft() } label: {
                    Label(String(vm.pendingNoteCount), systemImage: "square.and.pencil").font(.caption)
                }.buttonStyle(.borderless).help("继续编辑未保存备注（草稿保留至退出应用）")
            }
            Spacer(minLength: 8)
            if vm.showNoteEditor && vm.noteDiscardConfirmation {
                shortcutHint("esc", title: "继续编辑")
            } else if vm.showNoteEditor {
                shortcutHint("↩", title: "保存")
                shortcutHint("esc", title: "取消")
            } else {
                shortcutHint("↑ ↓", title: "选择")
                shortcutHint(vm.query.isEmpty ? "空格" : "⌘Y", title: "预览")
                shortcutHint("↩", title: vm.selectedItem.map { $0.isPrivate && !vm.isPrivateUnlocked($0) } == true ? "解锁并复制" : "复制")
                shortcutHint("esc", title: "关闭")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.footerHeight)
    }

    private func shortcutHint(_ key: String, title: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .frame(height: 17)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            Text(title).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Glass chrome

    /// Corner radius of the pane itself; the rim, the clip and the specular
    /// layers all use it so they cannot drift apart.
    static let paneCornerRadius: CGFloat = ClipaTheme.Metrics.radiusPane

    private var paneShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: Self.paneCornerRadius,
            style: .continuous
        )
    }

    /// 面板底：真的窗口后模糊 + **一层系统窗底色**。
    ///
    /// The backdrop blur itself (`GlassBackdrop`) is what the presentation probe
    /// pins, so it stays. What sits on top of it is now the system's own window
    /// background rather than a hand-mixed white, and the sheen / bottom glow
    /// are gone entirely.
    @ViewBuilder
    private var glassPane: some View {
        if usesOpaqueSurface {
            paneShape.fill(ClipaTheme.Palette.surface)
        } else {
            ZStack {
                GlassBackdrop(scheme: colorScheme, cornerRadius: Self.paneCornerRadius)
                // A semantic base keeps text legible over bright windows in dark
                // appearance, and when the compositor cannot supply a backdrop.
                paneShape.fill(ClipaTheme.Palette.surface.opacity(colorScheme == .dark ? 0.88 : 0.78))
            }
        }
    }

    private var paneRim: some View {
        paneShape.strokeBorder(ClipaTheme.Palette.separator.opacity(0.55), lineWidth: 0.5)
            .allowsHitTesting(false)
    }

    // MARK: - Top bar

    /// One row: the Clipa mark hugs the left edge, the search field sits on the
    /// pane's centre line (it is the primary control, and the middle of a bottom
    /// panel is where the pointer already rests), and the two action icons hug
    /// the right edge.
    // MARK: - Results

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

    /// Spotlight 对齐的**纵向列表**（2026-10-04）：通宽行 = 缩略图 + 单行
    /// 标题 + 「类型 · 拷贝于时间」+ 行尾回填按钮。选中行整行高亮，
    /// 键盘 ↑↓ 沿列表走，分页哨兵与选中回滚语义与旧卡片流一致。
    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        SpotlightRowView(
                            vm: vm,
                            item: item,
                            onDismiss: onDismiss
                        )
                            .id(item.id)
                    }
                    // Sentinel: 读到已加载页的末尾就拉下一页（与旧卡片流同一机制）。
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
        // The request is spent here either way: a target that is not on screen
        // yet has already had the window extended for it (`ensureEntryVisible`),
        // and one that never arrives must not leave the strip re-centring on
        // every later window growth.
        defer { vm.consumeRevealRequest() }
        guard let id, items.contains(where: { $0.id == id }) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
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
        VStack(spacing: 12) {
            Image(systemName: vm.settings.pauseRecording ? "pause.circle" : "doc.on.clipboard")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(vm.settings.pauseRecording ? "剪贴板记录已暂停" : "从第一次复制开始")
                .font(.system(size: 17, weight: .semibold))
            Text(vm.settings.pauseRecording
                 ? "恢复记录后，新复制的内容会出现在这里。"
                 : "复制文本、图片或文件，即可在这里快速找回。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if vm.settings.pauseRecording {
                Button("恢复记录") { vm.togglePaused() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            } else {
                Text("⌃⌘V 随时打开 · 内容仅保存在本机")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text("没有找到匹配内容")
                .font(.system(size: 17, weight: .semibold))
            Text("试试更短的关键词，或切换到全部类型。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("清除搜索和筛选") {
                vm.query = ""
                vm.kindFilter = nil
                vm.smartTagFilter = nil
                vm.filtersDidChange()
                searchFocused = true
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Failure state for the whole page: says the data is still there, says that
    /// recording is paused, and offers the only two safe actions.
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
                    if let app = AppDelegate.shared { app.retryHistoryFromPanel() }
                    else { vm.retryStoreConnection() }
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

    // MARK: - Footer

    private var separator: some View {
        Rectangle()
            .fill(ClipaTheme.Palette.separator)
            .frame(height: 1)
    }

    // MARK: - Floating editors and toast

    /// The note editor floats above the cards, so the page keeps a single
    /// results surface without losing the module.
    private var floatingOverlays: some View {
        VStack(spacing: 8) {
            if vm.showNoteEditor {
                editorsCard
            }
            if let toast = vm.toast {
                // 墨牌：the one deliberately dark chip left on the pane. A
                // bright pill would sink into a bright board, and a toast is
                // exactly the thing that has to be noticed.
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
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .animation(reduceMotion ? nil : .spring(duration: 0.25), value: vm.toast)
            }
        }
        .padding(.bottom, Self.footerHeight + 12)
    }

    /// Note editor keeps its target visible, uses system controls, and restores
    /// search focus when dismissed. Private content is never used in the label.
    private var editorsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("编辑备注", systemImage: "note.text")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let item = vm.noteEditingItem {
                    Text(item.isPrivate ? "私密条目 · 已解锁" : item.typePresentation.title)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let item = vm.noteEditingItem, !item.isPrivate {
                Text(ClipPreview.display(for: item.text.isEmpty
                     ? item.fileURLs.first?.lastPathComponent ?? "图像" : item.text, limit: 90))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            HStack(spacing: 8) {
                TextField("为这条内容添加备注", text: $vm.noteDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.system(size: 13))
                    .focused($noteFieldFocused)
                    .accessibilityLabel("备注内容")
                    .disabled(vm.noteIsSaving || vm.noteDiscardConfirmation)
                    .onSubmit { Task { await vm.saveNoteAsync() } }
                NotePillButton(title: "取消", prominent: false) { vm.requestCloseNoteEditor() }
                    .disabled(vm.noteIsSaving)
                NotePillButton(title: "保存", prominent: true) {
                    Task { await vm.saveNoteAsync() }
                }
                .disabled(vm.noteIsSaving || vm.noteDiscardConfirmation)
                if vm.noteIsSaving { ProgressView().controlSize(.small) }
            }
            if let error = vm.noteError {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if vm.noteDiscardConfirmation {
                HStack {
                    Text("放弃未保存的修改？").font(.callout)
                    Spacer()
                    Button("继续编辑") { vm.noteDiscardConfirmation = false; noteFieldFocused = true }
                    Button("放弃修改", role: .destructive) { vm.discardNoteChanges() }
                }
            } else if vm.noteEditingItem?.isPrivate == true {
                Text("私密备注请及时保存；锁定或关闭面板后将清除未保存内容。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(ClipaTheme.Palette.separator.opacity(0.5), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
        .padding(.horizontal, 16)
        .onAppear {
            DispatchQueue.main.async {
                guard vm.showNoteEditor else { return }
                noteFieldFocused = true
            }
        }
    }

    // MARK: - Actions

    func copySelectedAndDismiss() async {
        guard let item = vm.selectedItem else { return }
        // Only a copy that actually reached the pasteboard dismisses the panel:
        // dismissing after a cancelled Touch ID prompt took the user's context
        // away and left the clipboard untouched.
        guard await vm.copyAsync(item) else { return }
        onDismiss()
    }
}

/// Standard dialog actions keep the primary save action distinct from cancel.
private struct NotePillButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        if prominent {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .tint(ClipaTheme.Palette.accent)
        } else {
            Button(title, action: action).buttonStyle(.bordered)
        }
    }
}

/// One content block in the horizontal row.
///
/// It carries what the removed panel's list row carried — type, source, a
/// bounded preview, the note, the sensitivity and private markers — plus the
/// panel's right-click menu, so what used to be reachable from the history list
/// still is.
/// Spotlight 对齐的**列表行**（2026-10-04）。
///
/// 与实拍的 Spotlight 剪贴板行同构：前导缩略图 → 单行标题 →
/// 「类型 · 拷贝于时间」副标题 → 行尾圆形回填按钮。
/// 选中 = 整行高亮；右键菜单沿用原卡片的超集操作（私密 / 备注 / 删除）。
struct SpotlightRowView: View {
    @ObservedObject var vm: PanelViewModel
    let item: Clip
    /// 回填成功后收起面板（由外层注入，保持行视图无窗口引用）。
    let onDismiss: () -> Void

    @State private var isHovered = false
    /// 应用名索引后台就绪时 +1，触发徽标补渲染（首次渲染时索引可能还没建好）。
    @State private var appIndexTick = 0

    private var isSelected: Bool { vm.selectedID == item.id }
    private var isLocked: Bool {
        item.isPrivate && !vm.isPrivateUnlocked(item)
    }
    private var showsSensitive: Bool {
        !isLocked && vm.isSensitive(item)
    }

    var body: some View {
        // 行 = 选择（点一下高亮，↑↓ 走）；回填在行尾圆钮与回车上。
        // 不用嵌套 Button：外层手势用 onTapGesture，内层才是真按钮。
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
                .frame(width: 36, height: 36)
                .overlay(alignment: .bottomTrailing) {
                    if !isLocked {
                        sourceAppBadge.id(appIndexTick).offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(rowTitle)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : ClipaTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(rowSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.78) : ClipaTheme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsSensitive {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8) : ClipaTheme.Palette.warning)
                    .help("此内容可能包含敏感信息")
                    .accessibilityLabel("可能包含敏感信息")
            }
            Text(vm.relativeTime(for: item.lastCopiedAt))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.78) : ClipaTheme.Palette.textSecondary)
                .lineLimit(1)
            pasteButton
        }
        .padding(.horizontal, 12)
        .frame(height: QuickStripView.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected
                      ? Color(nsColor: .selectedContentBackgroundColor)
                      : isHovered ? ClipaTheme.Palette.fill.opacity(0.6) : Color.clear)
                .padding(.vertical, 2)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowTitle + "，" + rowSubtitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "复制并关闭") {
            Task { if await vm.copyAsync(item) { onDismiss() } }
        }
    }

    // MARK: 来源应用徽标（2026-10-04，对齐 Spotlight 实拍）

    /// 缩略图右下角叠 15pt 来源应用图标。
    ///
    /// 解析（2026-10-04 重写）：sourceApp 记录的是**本地化名字**
    /// （终端 / 备忘录 / 访达 / 微信……），直接拼 `/Applications/名字.app`
    /// 会大面积 miss。改为一次性枚举应用目录建**本地化名字索引**
    /// （localizedName + 文件夹名双键，大小写/全半角/变音归一 + 包含匹配），
    /// 运行中应用优先（名字最准），都 miss 才不显示徽标——宁缺勿滥。
    private static let iconLock = NSLock()
    private static var iconStore: [String: NSImage?] = [:]
    private static var nameIndexStorage: [String: URL]?
    private static let indexStateLock = NSLock()
    private static var indexBuildStarted = false
    /// 索引后台构建完成后发到主线程，行视图监听它补一次渲染——
    /// 构建完成前那批行漏掉的徽标随后会出现。
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

    /// 已装应用的名字索引。键 = **本地化显示名** 与文件夹名（折叠后），
    /// 值 = .app 的 URL。
    ///
    /// 主源是 Spotlight 元数据（`kMDItemDisplayName`）——sourceApp 记录的
    /// "终端 / 备忘录 / 微信"正是这个：**文件夹名反而对不上**
    /// （Notes.app 的文件夹叫 Notes，显示名才叫备忘录）。目录枚举只作
    /// Spotlight 被禁用时的兜底（覆盖英文名）。
    ///
    /// 并发契约（2026-10-04）：MDQuery 同步查询**绝不能在 SwiftUI 布局事务
    /// 内执行**——body 渲染中调用会与 AttributeGraph 互锁（面板探针挂死实证，
    /// sample 栈：layout → sourceAppBadge → installedAppIndex → MDQuery）。
    /// 构建因此只走两条路：后台一次性预热（`ensureAppIndexBuilding`），或
    /// 测试钩子 `buildAppIndexForTesting`（无渲染事务的上下文）。渲染路径
    /// 只读 `currentAppIndex()` 快照，绝不等待。
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
                // 结果对象由 query 持有——裸指针按 unretained 语义转成 MDItem。
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

        // 兜底：Spotlight 无结果（索引被关）时退回目录枚举——覆盖英文名。
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

    /// 测试钩子：同步构建索引。只允许在没有 SwiftUI 渲染事务的上下文调用
    /// （自检在 MainActor 上直接调用，无布局事务）。
    static func buildAppIndexForTesting() {
        let built = buildAppIndex()
        indexStateLock.lock()
        nameIndexStorage = built
        indexStateLock.unlock()
    }

    /// 后台预热一次；重复调用是空操作。渲染路径首次取不到索引时触发。
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

    /// 来源应用徽标解析。2026-10-04 起 bundleID 优先（捕获时落库，
    /// `clips.source_bundle`）：`urlForApplication(withBundleIdentifier:)`
    /// 是 O(1) 查询，跨系统语言稳定、应用改名不受影响，完全不依赖名字
    /// 索引。名字路径（运行中应用 + MDQuery 索引）降级为旧数据回退
    /// （`source_bundle` 为 NULL 的行）。
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
        // 0. bundleID：最稳的一级（新条目都走这里）。
        if hasBundle,
           let url = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: bundleID!
           ) {
            resolved = NSWorkspace.shared.icon(forFile: url.path)
        }
        // 1. 名字 → 运行中应用：本地化名字最准（且覆盖未装盘的实例）。
        if resolved == nil, hasName {
            let folded = fold(name!)
            if let running = NSWorkspace.shared.runningApplications
                .first(where: { fold($0.localizedName ?? "") == folded }) {
                resolved = running.icon
            }
            // 2. 名字 → 已装应用索引：精确命中 → 包含匹配（最短键 = 最贴
            //    合的）。索引还没建好时**不缓存 miss**——构建完成的通知会
            //    触发重渲染，那时同一名字才能解析到真实图标。
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
        if !isLocked, item.kind == .image {
            StripThumbnailView(item: item, store: vm.store)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.16) : ClipaTheme.Palette.fill.opacity(0.65))
                .overlay {
                    Image(systemName: isLocked ? "lock.fill" : item.typePresentation.symbolName)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : ClipaTheme.Palette.textSecondary)
                }
        }
    }

    /// 行标题：文本 = 单行内容；图片 = 文件名（缺省「图像」）；
    /// 文件 = 首个文件名；上锁 = 固定文案。
    private var rowTitle: String {
        if isLocked { return "私密条目" }
        switch item.kind {
        case .image:
            return item.fileURLs.first?.lastPathComponent ?? "图像"
        case .file:
            return item.fileURLs.first?.lastPathComponent ?? "文件"
        default:
            return ClipPreview.display(for: item.text, limit: 120)
        }
    }

    /// 副标题：对齐 Spotlight 的「类型 · 拷贝于时间」。有备注时直接展示
    /// 备注内容（✎ 前缀）——用户写备注就是为了辨认，"有备注"三个字等于
    /// 没说（2026-10-05 行式改版时把内容丢了，只留了个状态词）。
    private var rowSubtitle: String {
        if isLocked { return "验证身份后查看或复制" }
        var parts = [item.typePresentation.title]
        if item.hasNote {
            parts.append(ClipPreview.display(for: item.note, limit: 72))
        } else if let source = item.sourceApp, !source.isEmpty {
            parts.append(source)
        }
        if item.isPrivate { parts.append("已解锁") }
        return parts.joined(separator: " · ")
    }

    private var pasteButton: some View {
        Button {
            Task { if await vm.copyAsync(item) { onDismiss() } }
        } label: {
            Image(systemName: isSelected ? "return" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.9) : ClipaTheme.Palette.textSecondary)
                .frame(width: 28, height: 28)
                .background(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .opacity(isSelected || isHovered ? 1 : 0)
        .disabled(vm.copyingID != nil || vm.privateUnlockInFlight)
        .overlay {
            if vm.copyingID == item.id { ProgressView().controlSize(.small).allowsHitTesting(false) }
        }
        .help(isLocked ? "验证身份后复制" : "复制并关闭面板")
        .accessibilityLabel(isLocked ? "验证身份后复制" : "复制并关闭面板")
    }

    /// 原卡片的右键菜单原样保留：Spotlight 行里没有这些操作位，
    /// Clipa 的超集功能收进上下文菜单，不破坏对齐。
    /// 每项带前导 SF Symbol 图标——对齐 macOS 26 菜单的图标配 format
    /// （2026-10-04，用户提供 Finder 右键实拍）。
    @ViewBuilder
    private var rowMenu: some View {
        Button {
            Task { await vm.copyAsync(item) }
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Button { vm.openPreview(item) } label: {
            Label("查看内容", systemImage: "eye")
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

/// Native macOS 26 glass, with a behind-window material fallback on macOS 14–15.
/// It follows the hosting appearance and never intercepts content interaction.
private struct GlassBackdrop: NSViewRepresentable {
    var scheme: ColorScheme
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        if #available(macOS 26.0, *) {
            let view = InertGlassEffectView()
            view.style = .regular
            view.cornerRadius = cornerRadius
            view.appearance = appearance
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            return view
        }
        let view = InertVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = appearance
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            return
        }
        if let effect = view as? InertVisualEffectView {
            apply(to: effect)
        }
    }

    private func apply(to view: InertVisualEffectView) {
        // `underWindowBackground` keeps the desktop readable through the pane;
        // `hudWindow` is the darker, glassier variant for dark appearance.
        view.material = .popover
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
    }
}

/// `NSGlassEffectView` must not take part in hit testing either: it sits behind
/// the SwiftUI content, and AppKit hit-tests real subviews before the hosting
/// view's own drawing.
@available(macOS 26.0, *)
private final class InertGlassEffectView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Blurs what is behind the window without ever swallowing a click.
private final class InertVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Thumbnail for one card.
///
/// Self-contained: each card downsamples its own image on a background queue
/// and drops it when the card goes away, so the popup needs no shared cache.
///
/// The decode target is sized for the *displayed* box: the card's image area
/// (roughly 250×150pt ≈ 500×300 physical pixels on a Retina screen) decides
/// the long edge via `previewMaxPixel`, clamped to [`minPixel`, `maxPixel`].
/// The old 240 px ceiling left every picture visibly soft — the floor exists
/// so that can never come back; the 1024 px ceiling bounds memory for a
/// 6000 px screenshot. Decoding a 250×150pt box at the old fixed 1024 spent
/// ~4× the bitmap memory the screen can actually show.
struct StripThumbnailView: View {
    let item: Clip
    let store: ClipStore
    var showsLoadErrorDetails = false

    @State private var image: NSImage?
    @State private var loadedRequest: String?
    @State private var loadFailed = false
    @State private var retry = 0
    @Environment(\.displayScale) private var displayScale

    /// Long-edge *ceiling* of the decoded image handed to the view.
    nonisolated static let maxPixel = 1024

    /// Long-edge *floor*: below this the picture goes soft again — the
    /// regression the decode ceiling was originally pinned against.
    nonisolated static let minPixel = 480

    /// 已解码缩略图缓存（P3 优化 2026-10-03）：键 = (条目, 目标长边)。
    /// 上限 60 张 / 96MB——覆盖两屏卡片，超出与内存压力由 NSCache 自动驱逐。
    private static let decodedCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    var body: some View {
        GeometryReader { proxy in
            let request = requestIdentity(size: proxy.size) + "-\(retry)"
            ZStack {
                if let image, loadedRequest == request {
                    Image(nsImage: image)
                        // `interpolation(.high)` keeps downscaling smooth; without
                        // it AppKit picks nearest-neighbour for large reductions and
                        // screenshots of text turn to mush.
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
                    // 图片占位：一层极浅的灰纸 + **虚线**边框（"这里本该有张图"这件事
                    // 用线说，不用色块说）。
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
                            VStack(spacing: 12) {
                                Image(systemName: loadFailed ? "exclamationmark.triangle" : "photo")
                                    .font(.system(size: ClipaTheme.IconSize.tile)).foregroundStyle(.secondary)
                                if loadFailed && showsLoadErrorDetails {
                                    Text("图片暂时无法预览").font(.headline)
                                    Button("重新加载") { retry += 1 }.buttonStyle(.bordered)
                                }
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: request) {
                await decodeImage(boxSize: proxy.size, request: request)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Decodes this card's image at its own displayed size.
    private func requestIdentity(size: CGSize) -> String {
        "\(store.dataDirectory.path)-\(item.id)-\(item.updatedAt.timeIntervalSince1970)-\(item.isPrivate)-\(Self.previewMaxPixel(boxSize: size, displayScale: displayScale))"
    }

    private func decodeImage(boxSize: CGSize, request: String) async {
        loadFailed = false
        let clip = item
        let source = store
        // 解码目标在主线程上量好（几何 + 屏幕缩放），再交给后台线程解码。
        // 一张 250×150pt 的框在 2x 屏上要 500px；旧的固定 1024 白占了
        // 约 4 倍的位图内存。
        let maxPixel = Self.previewMaxPixel(
            boxSize: boxSize,
            displayScale: displayScale
        )
        // P3 优化（2026-10-03）：命中缓存就不重拉 blob、不重解密、不重解码
        // ——LazyHStack 回滚会重建视图，旧实现等于每次回滚都白干一遍。
        let cacheKey = "\(source.dataDirectory.path)-\(clip.id)-\(clip.updatedAt.timeIntervalSince1970)-\(maxPixel)" as NSString
        if !clip.isPrivate, let cached = Self.decodedCache.object(forKey: cacheKey) {
            loadedRequest = request
            image = cached
            return
        }
        // Await the blob first (never blocking a cooperative thread — this
        // view is what starved the pool when several image cards were on
        // screen), then decode off the main actor.
        guard let data = await source.imageDataAsync(for: clip) else {
            guard !Task.isCancelled else { return }
            image = nil
            loadFailed = true
            return
        }
        guard !Task.isCancelled else { return }
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decodePreview(data, maxPixel: maxPixel)
        }.value
        guard !Task.isCancelled else { return }
        loadedRequest = request
        image = decoded
        loadFailed = decoded == nil
        if !clip.isPrivate, let decoded {
            Self.decodedCache.setObject(
                decoded,
                forKey: cacheKey,
                cost: maxPixel * maxPixel * 4
            )
        }
    }

    /// 解码长边 = 图片框的物理像素长边（点 × 屏幕缩放），夹在
    /// [`minPixel`, `maxPixel`] 之间。下限守住"发软"的旧 bug，上限守住
    /// "6000px 截图也不把内存炸掉"的旧承诺 —— 自检对这两端都 pin。
    nonisolated static func previewMaxPixel(
        boxSize: CGSize,
        displayScale: CGFloat
    ) -> Int {
        let longestPoint = max(boxSize.width, boxSize.height)
        let physical = Int((longestPoint * max(displayScale, 1)).rounded())
        return min(max(physical, minPixel), maxPixel)
    }

    /// `nonisolated` because it runs on the detached decode task below: it only
    /// touches CoreGraphics and `NSImage`, never view or actor state.
    ///
    /// Internal rather than private so the self-test can pin the decode ceiling
    /// — the "picture looks soft" bug was exactly this number being 240.
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
