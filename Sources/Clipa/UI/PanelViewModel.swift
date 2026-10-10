import AppKit
import Combine
import Foundation
import ImageIO
import SwiftUI

/// One row of the flattened history list: a section title or a clip.
///
/// Identities are global (`clip-<uuid>` / `header-<section>`), which is what
/// lets a row keep its identity while the list around it changes.
enum HistoryListEntry: Identifiable {
    case header(ClipSectionModel)
    case clip(UUID)

    var id: String {
        switch self {
        case .header(let section):
            return "header-\(section.section.rawValue)"
        case .clip(let clipID):
            return "clip-\(clipID.uuidString)"
        }
    }
}

/// Clipa's search box is a single local-search flow: everything the user types
/// is a literal keyword, resolved by the local engine with no network involved.
enum SearchState: Equatable {
    case idle
    case searching
    case showingResults
}

/// Thin UI-state coordinator. Search parsing/validation/ranking/FTS live in
/// SearchEngine; SQL lives in DatabaseManager.
@MainActor
final class PanelViewModel: ObservableObject {
    /// Rebound in place when the active workspace changes. The panel, its
    /// window and its SwiftUI hosting view outlive a workspace switch — SwiftUI
    /// keeps the hosting view (and therefore this view model) alive even after
    /// the window drops its content view — so building a second view model
    /// would leave the previous workspace's whole history resident.
    private(set) var store: ClipStore
    let settings: SettingsStore

    private var searchPipeline: DefaultSearchPipeline
    private var cancellables = Set<AnyCancellable>()
    /// Settings live outside the workspace cycle, so this one subscription is
    /// kept apart from `cancellables` and survives a store rebind.
    private var settingsCancellable: AnyCancellable?
    /// Follows `ClipStore.shared` across a workspace switch. Kept out of
    /// `cancellables` for the same reason as `settingsCancellable`: it has to
    /// survive the very rebind it triggers.
    private var sharedStoreCancellable: AnyCancellable?

    // Search state
    @Published var query = ""
    /// 搜索结果的排序（2026-10-02）：`.relevance` 是默认（打分 + 新近加成，
    /// 顺序会随输入变化）；`.newest` 是"位置稳定"的时间序 —— 按 `lastCopiedAt`
    /// 排（最近一次复制时间），与不搜索时的列表顺序同源，所以切换前后
    /// "同一内容在不搜索时排第几"的直觉保持一致。切换即重跑当前查询。
    @Published var searchSort: SearchSort = .relevance {
        didSet {
            guard oldValue != searchSort else { return }
            filtersDidChange()
        }
    }
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var results: [ClipSectionModel] = []
    @Published private(set) var searchState: SearchState = .idle

    // UI state
    @Published var kindFilter: ClipKind?
    @Published var smartTagFilter: SmartTag?
    @Published private(set) var collections: [ClipCollection] = []
    @Published private(set) var selectedCollectionID: UUID?
    @Published private(set) var collectionLoading = false
    private var collectionMembers = Set<UUID>()
    private var collectionTask: Task<Void, Never>?
    private var collectionMutationInFlight = false
    var selectedCollectionName: String? { collections.first { $0.id == selectedCollectionID }?.name }
    @Published var isSearchFieldFocused = false
    /// Which surface currently owns the keyboard.
    ///
    /// The main panel and the bottom strip share this one view model, and both
    /// of them focus their own search field when the shared `openTick` (or a
    /// finished search) changes. Without a single owner the two views fought:
    /// opening the strip immediately handed focus to the hidden main panel, and
    /// every keystroke's result update took the caret away again — the box
    /// accepted one character and then went dead.
    enum Surface {
        case main
        case quickStrip
    }
    @Published var activeSurface: Surface?
    @Published var selectedID: UUID?
    @Published var openTick = 0
    @Published var toast: String?
    /// True while the card row should scroll to follow the selection.
    ///
    /// The reader moving the selection (arrows, click, favouriting a card) asks
    /// the row to follow; the list changing *under* them — a delete, a capture
    /// landing — must not, or deleting a card would also throw away the place
    /// they were reading from.
    @Published private(set) var revealSelection = true
    /// Bumped on every *deliberate* selection. A counter rather than the
    /// selection id, because re-selecting the card that is already selected
    /// still has to scroll it into view — and a flag alone cannot tell that
    /// apart from "nothing happened".
    @Published private(set) var revealRequestTick = 0
    @Published var noteDraft = ""
    @Published var showNoteEditor = false
    @Published private(set) var noteEditingID: UUID?
    @Published private(set) var noteIsSaving = false
    @Published var noteError: String?
    @Published var noteDiscardConfirmation = false
    @Published var previewID: UUID?
    @Published private(set) var copyingID: UUID?
    private var noteOperation: UUID?
    private struct DraftKey: Hashable { let directory: String; let id: UUID }
    @Published private var noteDrafts: [DraftKey: String] = [:]
    var hasAnyNoteDrafts: Bool { !noteDrafts.isEmpty || (showNoteEditor && hasUnsavedNote) }
    func discardAllNoteDrafts() {
        noteDrafts.removeAll()
        discardNoteChanges()
    }
    var noteEditingItem: Clip? { (noteEditingID ?? selectedID).flatMap { store.clip(id: $0) } }
    var previewItem: Clip? { previewID.flatMap { store.clip(id: $0) } }
    var hasUnsavedNote: Bool { noteEditingItem.map { noteDraft != $0.note } ?? !noteDraft.isEmpty }
    var pendingNoteCount: Int {
        noteDrafts.keys.filter { $0.directory == store.dataDirectory.path && store.clip(id: $0.id)?.isPrivate == false }.count
    }
    @Published private var privateUnlockedIDs: Set<UUID> = []


    /// Called when the user clicks an empty/background area of the panel,
    /// which is treated as an outside click: the panel parks below the app
    /// instead of swallowing the click.
    var onPark: (() -> Void)?
    /// Called when a system authentication prompt starts / finishes. The panel
    /// controller keeps the clipboard overlay floating while the prompt is up
    /// and brings it back to the front after the user accepts or cancels it.
    var onPrivateAuthenticationStateChanged: ((Bool) -> Void)?

    private var toastWork: DispatchWorkItem?
    private var privateUnlockTimers: [UUID: DispatchWorkItem] = [:]
    @Published private(set) var privateUnlockInFlight = false
    /// Guards rapid duplicate clicks while a DB-backed UI mutation is in
    /// flight; without it a second click can act on stale pre-await state.
    private var pendingMutatingIDs: Set<UUID> = []

    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    /// Who should take the selection when the card it is on disappears: the
    /// visible card that follows it (or the one before it, when the deleted card
    /// was last). Set by the delete, consumed by `reconcileSelection`.
    private var selectionSuccessor: UUID?
    /// Flat row order used by arrow navigation, kept separate from the
    /// sectioned UI so repeated key presses do not re-flatten all results.
    @Published private(set) var navigationOrder: [UUID] = []
    /// Section titles and rows flattened once per result set. The view used to
    /// rebuild this on every body evaluation, which is an O(rows) allocation
    /// per redraw — 100k entries on the library that froze the panel.
    @Published private(set) var listEntries: [HistoryListEntry] = []
    /// The slice of `listEntries` the view is allowed to build. SwiftUI builds
    /// a row value for *every* entry it is handed, not just the visible ones,
    /// so the window is what keeps a 100k-result search from freezing.
    @Published private(set) var renderedRange: Range<Int> = 0..<0
    /// Section title for the section the window currently starts inside, so a
    /// window that begins mid-section still renders its heading.
    private var renderedContextHeader: HistoryListEntry?
    /// Entry index (inside `listEntries`) for each position in
    /// `navigationOrder`, so keyboard navigation can put the selected row
    /// inside the window before the view tries to scroll to it.
    private var entryIndexByNavigationIndex: [Int] = []
    private var lastNavigationSelectedID: UUID?
    private var lastNavigationIndex = 0

    /// Rows added each time the window is extended. Big enough that ordinary
    /// scrolling rarely waits, small enough that a redraw stays cheap.
    static let listWindowPageSize = 300

    init(
        store: ClipStore = .shared,
        settings: SettingsStore = .shared
    ) {
        self.store = store
        self.settings = settings
        searchPipeline = DefaultSearchPipeline(
            store: store,
            localSearchEngine: LocalSearchEngine(
                database: store.database,
                store: store
            )
        )
        subscribeToStores()
        // Settings are shared by every workspace, so this subscription is not
        // store-bound and is set up exactly once.
        settingsCancellable = settings.$pauseRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // The panel captured one store at init, and the window plus its SwiftUI
        // hosting view outlive a workspace switch, so nothing rebuilds it. Wiring
        // the follow-up here instead of in the switcher means no caller can
        // forget it — which is exactly what happened: `rebind` existed, was
        // tested, and was never called, so switching workspaces left the page on
        // the old history while the capture path had already moved.
        sharedStoreCancellable = NotificationCenter.default
            .publisher(for: ClipStore.sharedReplacedNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebind(store: .shared)
            }

        // First paint: run the search off the main actor like every other
        // refresh. The synchronous variant below stays for tests and for
        // callers that must have a result in hand before returning.
        refreshWithoutBlockingMainThread()
    }

    /// Wires up everything that follows the store, so a workspace switch can
    /// re-do exactly this against the new store.
    private func subscribeToStores() {
        NotificationCenter.default.publisher(for: .clipaCollectionsChanged)
            .sink { [weak self] notification in
                guard let self, notification.object as? URL == self.store.dataDirectory else { return }
                self.refreshCollections()
            }.store(in: &cancellables)
        store.itemsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                self.pruneDrafts()
                // A capture / pin / delete reordered the rows; keep the
                // reader's place instead of snapping the window.
                self.refreshActiveQuery(preserveWindow: true)
                if let selectedID = self.selectedID,
                   self.store.clip(id: selectedID) == nil {
                    // P2 修复（2026-10-03）：不再留"无选中"窗口——旧写法把
                    // 选中清空后要等 40ms debounce 的刷新回来才补，期间按
                    // Return 会落到第一张卡。立即在当前导航序里把选中钉到
                    // 被删条目的邻居，随后的 reconcile 再做权威修正。
                    self.selectedID = self.neighborOf(removing: selectedID)
                }
            }
            .store(in: &cancellables)

        store.$availability
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

    }

    /// Drops everything bound to the current store.
    ///
    /// Every one of these is a path back to the store: the Combine
    /// subscriptions, the result arrays, the row/image caches and the tasks
    /// that may still be reading it. A workspace switch has to clear all of
    /// them, otherwise the previous workspace's history stays resident — which
    /// is what made an empty workspace cost 530MB.
    private func releaseStoreBoundState() {
        collectionTask?.cancel()
        collectionTask = nil
        collections = []
        selectedCollectionID = nil
        collectionMembers = []
        collectionLoading = false
        suspendNoteEditor()
        previewID = nil
        noteOperation = nil
        noteIsSaving = false
        noteEditingID = nil
        noteDraft = ""
        noteError = nil
        searchTask?.cancel()
        searchTask = nil
        toastWork?.cancel()
        toastWork = nil
        for work in privateUnlockTimers.values { work.cancel() }
        privateUnlockTimers.removeAll()
        cancellables.removeAll()
        clips = []
        results = []
        listEntries = []
        navigationOrder = []
        entryIndexByNavigationIndex = []
        renderedRange = 0..<0
        renderedContextHeader = nil
        privateUnlockedIDs = []
        pendingMutatingIDs = []
        // P2 修复（2026-10-03）：解锁计时也归零。旧实现只清了视图侧状态，
        // PrivacyGate 的 unlockDeadlines 跨工作区继续计时——状态双源不一致。
        PrivacyGate.shared.markLocked()
    }

    /// 被删条目的导航邻居（优先下一位，其次上一位）。给"items 已变更但
    /// 刷新尚未返回"的窗口期用：此刻 navigationOrder 仍是旧序，但足以把
    /// 选中钉在删除点附近，而不是任由 Return 落到第一张卡。
    private func neighborOf(removing id: UUID) -> UUID? {
        guard let index = navigationOrder.firstIndex(of: id) else {
            return navigationOrder.first
        }
        if navigationOrder.indices.contains(index + 1) {
            return navigationOrder[index + 1]
        }
        if index > 0 { return navigationOrder[index - 1] }
        return nil
    }

    /// Points the panel at another workspace's store without rebuilding the
    /// panel. See `store` for why the panel is reused instead of replaced.
    func rebind(store: ClipStore) {
        guard store !== self.store else { return }
        releaseStoreBoundState()
        self.store = store
        searchPipeline = DefaultSearchPipeline(
            store: store,
            localSearchEngine: LocalSearchEngine(
                database: store.database,
                store: store
            )
        )
        subscribeToStores()
        selectedID = nil
        query = ""
        kindFilter = nil
        smartTagFilter = nil
        refreshWithoutBlockingMainThread()
    }

    /// Re-runs the current query away from the main actor, without the typing
    /// debounce. Used by actions that change the result set (delete, store retry)
    /// and by the first paint, which all used to run the whole search —
    /// including the database round trip — synchronously on the main thread and
    /// froze the panel for its duration (measured 118 ms for a broad keyword on
    /// a 1050-clip library).
    private func refreshWithoutBlockingMainThread() {
        searchTask?.cancel()
        searchGeneration += 1
        runLocalSearch(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            filter: currentFilter,
            generation: searchGeneration
        )
    }

    // MARK: - Search

    private var currentFilter: SearchFilter {
        SearchFilter(
            kinds: kindFilter.map { [$0] } ?? [],
            smartTags: smartTagFilter.map { [$0] } ?? []
        )
    }

    /// Kept for the filter row that was removed from the panel. Both setters
    /// used to change state without asking for a re-query, so re-wiring them
    /// would have produced "switching the filter does nothing".
    func selectKindFilter(_ kind: ClipKind?) {
        smartTagFilter = nil
        kindFilter = kind
        filtersDidChange()
    }

    // MARK: - Store recovery

    /// Retries the database open and reports the outcome without ever hiding
    /// the failure state behind a normal-looking empty history.
    func retryStoreConnection() {
        if store.retryDatabaseOpen() {
            showToast(StoreUnavailableCopy.retrySucceeded)
        } else {
            showToast(StoreUnavailableCopy.retryFailed)
        }
    }

    /// Opens the folder holding clips.sqlite and images/.
    func revealDataDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([store.dataDirectory])
    }

    func selectSmartTagFilter(_ tag: SmartTag?) {
        kindFilter = nil
        smartTagFilter = tag
        filtersDidChange()
    }

    var activeFilterTitle: String {
        smartTagFilter.map { filterTitle(for: $0) }
            ?? kindFilter?.displayName
            ?? "全部"
    }

    var isFiltering: Bool {
        kindFilter != nil || smartTagFilter != nil
    }

    /// True when the list is showing a subset of the stored history: search
    /// text or a type filter.
    var hasActiveFilter: Bool {
        isFiltering
            || selectedCollectionID != nil
            || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Count line under the list.
    ///
    /// While a filter is active it reports the rows actually on screen next to
    /// the stored total, so the number can never contradict what the list is
    /// showing. Without a filter the two are the same, and the plain total
    /// stays the more natural reading.
    var historyCountText: String {
        let total = store.items.count
        guard hasActiveFilter else { return "共 \(total) 条" }
        return "结果 \(navigationOrder.count) 条 · 共 \(total) 条"
    }

    /// Filter-menu label. Row labels keep `SmartTag.displayName` (e.g. “文本”,
    /// “链接”), while the menu uses a distinct wording so coarse-kind and
    /// smart-tag entries never look duplicated.
    func filterTitle(for tag: SmartTag) -> String {
        switch tag {
        case .text: return "文本"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    private func applySearchPipelineResult(
        _ result: SearchPipelineResult,
        filter: SearchFilter,
        preserveWindow: Bool = false
    ) {
        let visible = selectedCollectionID == nil ? result.clips
            : result.clips.filter { collectionMembers.contains($0.id) && !$0.isPrivate && !$0.isHidden }
        clips = visible
        results = ClipGrouper.group(
            clips: visible,
            calendar: .current,
            now: Date()
        )
        navigationOrder = results.flatMap(\.clips).map(\.id)
        rebuildListEntries(preserveWindow: preserveWindow)
        reconcileSelection(with: navigationOrder)
    }

    func selectCollection(_ id: UUID?) {
        guard !noteIsSaving, copyingID == nil, !privateUnlockInFlight else { return }
        selectedCollectionID = id
        collectionMembers = []
        refreshActiveQuery()
        refreshCollections()
    }

    func refreshCollections() {
        collectionTask?.cancel()
        let source = store, target = selectedCollectionID
        collectionLoading = true
        collectionTask = Task { [weak self] in
            do {
                guard let db = source.database else { throw WorkflowError.message("数据库暂不可用。") }
                let collections = try await db.listCollections()
                let exists = target.map { id in collections.contains { $0.id == id } } ?? true
                let members: Set<UUID>
                if let target, exists { members = try await db.collectionMembers(id: target) }
                else { members = [] }
                guard !Task.isCancelled, let self, self.store === source, self.selectedCollectionID == target else { return }
                self.collections = collections
                if !exists { self.selectedCollectionID = nil; self.showToast("资料集已删除，已返回全部历史") }
                self.collectionMembers = members
                self.collectionLoading = false
                if target != nil { self.refreshActiveQuery() }
            } catch {
                guard !Task.isCancelled, let self, self.store === source else { return }
                self.collectionLoading = false
                if target != nil { self.collectionMembers = []; self.refreshActiveQuery(); self.showToast("资料集读取失败，请重试") }
            }
        }
    }

    func changeCollection(_ collection: UUID, item: Clip, adding: Bool) {
        guard !collectionMutationInFlight, !item.isPrivate, !item.isHidden else { return }
        collectionMutationInFlight = true
        let source = store
        Task { [weak self] in
            defer { self?.collectionMutationInFlight = false }
            do {
                guard let db = source.database else { throw WorkflowError.message("数据库暂不可用。") }
                try await db.changeCollectionMembers(id: collection, clips: [item.id], adding: adding)
                NotificationCenter.default.post(name: .clipaCollectionsChanged, object: source.dataDirectory)
                if self?.store === source { self?.showToast(adding ? "已加入资料集" : "已从资料集移除，历史仍保留") }
            } catch { if self?.store === source { self?.showToast(error.localizedDescription) } }
        }
    }

    // MARK: - Rendered list window

    /// Flattens the sections once per result set and starts the window at the
    /// top. Also records where each navigable clip sits inside the flattened
    /// list, so navigation can keep its target inside the window.
    ///
    /// `preserveWindow` keeps the reader where they were: a pin, delete or
    /// capture reorders the rows underneath them, and snapping back to the top
    /// (or recentring on the moved row) would throw away their place.
    private func rebuildListEntries(preserveWindow: Bool = false) {
        var entries: [HistoryListEntry] = []
        entries.reserveCapacity(navigationOrder.count + results.count)
        var entryIndices: [Int] = []
        entryIndices.reserveCapacity(navigationOrder.count)
        for section in results {
            entries.append(.header(section))
            for clip in section.clips {
                entryIndices.append(entries.count)
                entries.append(.clip(clip.id))
            }
        }
        listEntries = entries
        entryIndexByNavigationIndex = entryIndices
        if preserveWindow, !renderedRange.isEmpty, !entries.isEmpty {
            let lower = min(renderedRange.lowerBound, entries.count - 1)
            let upper = min(
                entries.count,
                max(lower + 1, renderedRange.upperBound)
            )
            renderedRange = lower..<upper
            renderedContextHeader = contextHeader(before: lower)
        } else {
            renderedContextHeader = nil
            renderedRange = 0..<min(entries.count, Self.listWindowPageSize)
        }
    }

    /// What the view should build: the window, preceded by the current
    /// section's title when the window starts in the middle of a section.
    var renderedEntries: [HistoryListEntry] {
        guard !renderedRange.isEmpty,
              renderedRange.upperBound <= listEntries.count else {
            return []
        }
        var slice = Array(listEntries[renderedRange])
        if let header = renderedContextHeader {
            slice.insert(header, at: 0)
        }
        return slice
    }

    var canExtendRenderedWindow: Bool {
        renderedRange.upperBound < listEntries.count
    }

    /// The clips the card row is allowed to build, in navigation order.
    ///
    /// Section headers are dropped — the strip is one flat row — but the window
    /// is what keeps a 100k-row library cheap: the view builds this slice and
    /// asks for the next page when the reader reaches its end.
    var renderedClips: [Clip] {
        renderedEntries.compactMap { entry in
            guard case .clip(let clipID) = entry else { return nil }
            return store.clip(id: clipID)
        }
    }

    /// True while the row is showing only part of the results, i.e. while
    /// scrolling further right still has something to reveal.
    var canLoadMoreCards: Bool {
        canExtendRenderedWindow
    }

    var canExtendRenderedWindowUpward: Bool {
        renderedRange.lowerBound > 0
    }

    /// Grows the window when the user scrolls toward its end. The window only
    /// ever grows downwards here, so the section heading above it stays valid.
    func extendRenderedWindow() {
        guard canExtendRenderedWindow else { return }
        let upper = min(
            listEntries.count,
            renderedRange.upperBound + Self.listWindowPageSize
        )
        renderedRange = renderedRange.lowerBound..<upper
    }

    /// Grows the window upwards when the user scrolls back to its top.
    ///
    /// Without this the window is a one-way door: a window that was recentred
    /// (keyboard navigation, or the selection moving after a pin/delete) has
    /// no rows above it, so the list can never be scrolled back up.
    func extendRenderedWindowUpward() {
        guard canExtendRenderedWindowUpward else { return }
        let lower = max(
            0,
            renderedRange.lowerBound - Self.listWindowPageSize
        )
        renderedRange = lower..<renderedRange.upperBound
        renderedContextHeader = contextHeader(before: lower)
    }

    /// Makes sure the row for `clipID` is inside the window before the view
    /// scrolls to it. A far jump recentres the window instead of building
    /// everything between here and there.
    func ensureEntryVisible(clipID: UUID) {
        guard let navigationIndex = navigationOrder.firstIndex(of: clipID),
              entryIndexByNavigationIndex.indices.contains(navigationIndex)
        else { return }
        ensureEntryVisible(
            entryIndex: entryIndexByNavigationIndex[navigationIndex]
        )
    }

    private func ensureEntryVisible(entryIndex: Int) {
        guard entryIndex >= 0, entryIndex < listEntries.count else { return }
        if renderedRange.contains(entryIndex) { return }
        let page = Self.listWindowPageSize
        if entryIndex >= renderedRange.upperBound,
           entryIndex - renderedRange.upperBound < page {
            // Just past the end: grow the window, which keeps the current
            // section heading correct.
            extendRenderedWindow()
            if renderedRange.contains(entryIndex) { return }
        }
        // A far jump (keyboard navigation wraps from the first row to the
        // last): recentre so the window stays bounded.
        let start = max(
            0,
            min(entryIndex - page / 2, max(0, listEntries.count - page))
        )
        let end = min(listEntries.count, start + page)
        renderedRange = start..<end
        renderedContextHeader = contextHeader(before: start)
    }

    /// The section title that governs `index`, when the window starts inside a
    /// section rather than on its heading.
    private func contextHeader(before index: Int) -> HistoryListEntry? {
        var cursor = min(index, listEntries.count - 1)
        while cursor >= 0 {
            if case .header = listEntries[cursor] {
                return listEntries[cursor]
            }
            cursor -= 1
        }
        return nil
    }

    /// Keeps the highlighted row/detail pane inside the currently visible
    /// result set after pin/private/delete/filter operations reorder rows.
    private func reconcileSelection(with visibleIDs: [UUID]) {
        // Where the selection should land if the card it was on has gone:
        // `selectionSuccessor`, recorded by the delete itself. Falling back to
        // the first row is only right when there is no such card (an empty
        // selection at first paint, a filter that removed everything else).
        //
        // Both branches below need this: the store subscription clears
        // `selectedID` the moment the row disappears, so a delete arrives here
        // as "nothing selected" rather than "the old id is gone".
        let successor = selectionSuccessor.flatMap { candidate in
            visibleIDs.contains(candidate) ? candidate : nil
        }
        // No selection over a non-empty list is a dead end: the list shows
        // rows, nothing looks selected, and Return has nothing to copy. Adopt
        // the first row instead of leaving the panel in that state.
        if selectedID == nil, let nextID = successor ?? visibleIDs.first {
            selectionSuccessor = nil
            revealSelection = false
            selectedID = nextID
            lastNavigationSelectedID = nextID
            lastNavigationIndex = 0
            return
        }
        if let selectedID, !visibleIDs.contains(selectedID) {
            // The card the reader was on is gone. Land on the one that took its
            // place — `selectionSuccessor`, recorded by the delete itself —
            // and only fall back to the first row when there is no such card.
            // Deleting a card should not also move the reader to the top.
            selectionSuccessor = nil
            revealSelection = false
            // The editor went with the card it belonged to. Leaving it open
            // re-targeted it at the neighbour, so "保存" wrote the deleted card's
            // text onto a different row.
            if showNoteEditor {
                showNoteEditor = false
                noteDraft = ""
            }
            if let next = successor ?? visibleIDs.first {
                self.selectedID = next
                lastNavigationSelectedID = next
                lastNavigationIndex = 0
            } else {
                self.selectedID = nil
                lastNavigationSelectedID = nil
                lastNavigationIndex = 0
                if showNoteEditor {
                    showNoteEditor = false
                }
                noteDraft = ""
            }
        }
        // Deliberately no `ensureEntryVisible` here: reconciling after a pin /
        // delete / capture is a background reorder, and recentring the window
        // on the moved row made the list jump (and, before upward extension
        // existed, left it unable to scroll back). The window stays where the
        // reader left it; keyboard navigation is what asks to follow the
        // selection, and it does so in `moveSelection`.
    }

    func refreshSearch() {
        // A synchronous refresh always wins over anything still running in the
        // background: bumping the generation here makes an in-flight search
        // drop its (now older) result instead of overwriting this one.
        searchGeneration += 1
        let filter = currentFilter
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty search is the default history view. Any non-empty ordinary
        // local search treats the whole box content as one literal keyword.
        if trimmed.isEmpty {
            let result = searchPipeline.performLocalSearch(
                query: "",
                uiFilter: filter
            )
            applySearchPipelineResult(result, filter: filter)
            searchState = .idle
            return
        }
        let result = searchPipeline.performLocalSearch(
            query: trimmed,
            uiFilter: filter,
            sort: searchSort
        )
        applySearchPipelineResult(result, filter: filter)
        searchState = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? .idle : .showingResults
    }

    /// Re-runs the current query away from the main actor. Used whenever the
    /// inputs changed but the query text did not: a capture landed, a row was
    /// deleted, a filter chip was toggled. These all used to re-run the whole
    /// search on the main actor — 31 ms for the plain history view and up to
    /// 170 ms for a broad keyword.
    ///
    /// The 40 ms debounce matters as much as the thread hop: a burst of
    /// captures publishes `items` once per row, and every search holds the
    /// database actor for its whole duration, so coalescing is what keeps the
    /// next capture from queueing behind three of them.
    /// `preserveWindow` is for refreshes the reader did not ask for — a
    /// capture landing, a row captured or deleted. The result set is rebuilt
    /// underneath them, but the window they were reading stays put.
    private func refreshActiveQuery(preserveWindow: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let filter = currentFilter
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 40_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let owner = self else { return }
            guard generation == owner.searchGeneration else { return }
            owner.runLocalSearch(
                query: trimmed,
                filter: filter,
                generation: generation,
                preserveWindow: preserveWindow
            )
        }
    }

    func queryDidChange() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            searchGeneration += 1
            searchState = .idle
            // Clearing the box is the other half of the typing path: the full
            // history view costs ~31 ms on the main actor (1012 rows), so it
            // goes off-main as well — `refreshActiveQuery` covers the empty
            // query too.
            refreshActiveQuery()
            return
        }

        searchGeneration += 1
        let generation = searchGeneration
        let filter = currentFilter
        searchState = .searching

        // 40ms local debounce: FTS is not fired once per keystroke.
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 40_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let owner = self else { return }
            guard generation == owner.searchGeneration else { return }
            owner.runLocalSearch(
                query: trimmed,
                filter: filter,
                generation: generation
            )
        }
    }

    /// Runs the local search for `query` off the main actor and applies the
    /// result back on it.
    ///
    /// The panel used to call `performLocalSearch` inside `MainActor.run`,
    /// so every keystroke froze the UI for the whole query — measured
    /// 31–193 ms on a production-sized library (FTS + validation + ranking).
    /// The search now reads an O(1) copy-on-write `SearchSnapshot` taken here
    /// on the main actor, and the expensive part runs on a background task.
    /// Results are identical because the snapshot is the same state the
    /// main-thread run read, and `generation` still decides what may be
    /// applied, so an out-of-order finish can never win.
    private func runLocalSearch(
        query: String,
        filter: SearchFilter,
        generation: Int,
        preserveWindow: Bool = false
    ) {
        let snapshot = store.searchSnapshot
        let pipeline = searchPipeline
        let sort = searchSort
        searchTask = Task { [weak self] in
            // A newer keystroke / capture may already have superseded this
            // work while it sat in the queue. Bail before touching SQLite:
            // every FTS hit holds the database actor, and a stale search that
            // still runs makes the *next* capture wait behind it.
            guard !Task.isCancelled else { return }
            // `performLocalSearchAsync` awaits the database actor instead of
            // blocking the cooperative thread that runs this detached task.
            let worker = Task.detached(priority: .userInitiated) {
                await pipeline.performLocalSearchAsync(
                    query: query,
                    uiFilter: filter,
                    dataSource: snapshot,
                    sort: sort
                )
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let owner = self, !Task.isCancelled else { return }
            guard generation == owner.searchGeneration else { return }
            owner.applySearchPipelineResult(
                result,
                filter: filter,
                preserveWindow: preserveWindow
            )
            owner.searchState = query.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? .idle : .showingResults
        }
    }

    /// Programmatic search entry used by the UI/state layer. Debounce and
    /// result invalidation live in `queryDidChange`.
    func search() {
        queryDidChange()
    }

    func filtersDidChange() {
        refreshActiveQuery()
    }

    func clearSearch() {
        query = ""
        queryDidChange()
    }

    // MARK: - Search box scope

    /// The single text field stays canonical; everything downstream derives
    /// from this split.
    var searchBoxSplit: SearchBoxSplit {
        SearchBoxSplitter.split(query)
    }

    // MARK: - Derived UI state

    var filteredItems: [Clip] {
        results.flatMap(\.clips)
    }

    var firstResultItem: Clip? {
        for section in results {
            if let first = section.clips.first {
                return first
            }
        }
        return nil
    }

    var historyGroups: [ClipSectionModel] {
        results
    }

    var selectedItem: Clip? {
        guard let selectedID else { return nil }
        return store.clip(id: selectedID)
    }

    /// Arrow-key navigation follows the exact order rows are displayed.
    func moveSelection(by delta: Int) {
        guard !navigationOrder.isEmpty else { return }
        let count = navigationOrder.count
        let currentIndex: Int
        if selectedID == lastNavigationSelectedID,
           navigationOrder.indices.contains(lastNavigationIndex),
           navigationOrder[lastNavigationIndex] == selectedID {
            currentIndex = lastNavigationIndex
        } else if let selectedID,
                  let found = navigationOrder.firstIndex(of: selectedID) {
            currentIndex = found
        } else {
            currentIndex = 0
        }
        let next = (currentIndex + delta + count) % count
        let nextID = navigationOrder[next]
        guard let item = store.clip(id: nextID) else { return }
        lastNavigationSelectedID = nextID
        lastNavigationIndex = next
        // Keep the row inside the rendered window before the view scrolls to
        // it; navigation wraps, so the target can be at the far end.
        ensureEntryVisible(clipID: nextID)
        selectGated(item)
    }

    // MARK: - Convenience

    /// Rows read the precomputed marker persisted with the clip; no per-row
    /// regex scan happens during rendering.
    func isSensitive(_ item: Clip) -> Bool {
        item.containsSensitive
    }

    func relativeTime(for date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        // P3 优化（2026-10-03）：DateFormatter 的创建很贵（ICU 解析格式），
        // 一页 300 张卡 × 每键击重绘就是 300+ 次分配——静态缓存一份。
        return Self.relativeDateFormatter.string(from: date)
    }

    private static let relativeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    // MARK: - Item actions

    func select(_ item: Clip) {
        guard copyingID == nil, !noteIsSaving else { return }
        if showNoteEditor, noteEditingID == item.id { return }
        suspendNoteEditor()
        revealSelection = true
        revealRequestTick &+= 1
        selectionSuccessor = nil
        if selectedID != item.id { selectedID = item.id }
        noteDraft = item.isPrivate && !isPrivateUnlocked(item) ? "" : item.note
    }

    private func draftKey(_ id: UUID) -> DraftKey { DraftKey(directory: store.dataDirectory.path, id: id) }

    private func pruneDrafts() {
        for key in noteDrafts.keys where key.directory == store.dataDirectory.path {
            if store.clip(id: key.id)?.isPrivate != false { noteDrafts[key] = nil }
        }
    }

    /// Ordinary drafts remain in memory for this session, scoped by workspace.
    /// Private drafts are never retained after the editor leaves the screen.
    func suspendNoteEditor() {
        guard showNoteEditor, !noteIsSaving else { return }
        if let item = noteEditingItem {
            let key = draftKey(item.id)
            if !item.isPrivate, noteDraft != item.note { noteDrafts[key] = noteDraft }
            else { noteDrafts[key] = nil }
        }
        showNoteEditor = false
        noteEditingID = nil
        noteDiscardConfirmation = false
        noteError = nil
        noteDraft = ""
    }

    func requestCloseNoteEditor() {
        guard !noteIsSaving else { return }
        if noteDiscardConfirmation { noteDiscardConfirmation = false; return }
        if hasUnsavedNote { noteDiscardConfirmation = true }
        else { discardNoteChanges() }
    }

    func discardNoteChanges() {
        guard !noteIsSaving else { return }
        if let id = noteEditingID { noteDrafts[draftKey(id)] = nil }
        showNoteEditor = false
        noteEditingID = nil
        noteDraft = ""
        noteError = nil
        noteDiscardConfirmation = false
    }

    func resumeNoteDraft() {
        pruneDrafts()
        guard let key = noteDrafts.keys.first(where: { $0.directory == store.dataDirectory.path }),
              let item = store.clip(id: key.id) else { return }
        openNoteEditor(item)
    }

    func openPreview(_ item: Clip? = nil) {
        guard !noteIsSaving, let item = item ?? selectedItem ?? firstResultItem else { return }
        select(item)
        previewID = item.id
    }

    func selectGated(_ item: Clip) {
        select(item)
    }

    /// Called by the view once it has scrolled the selection into view.
    ///
    /// The request is deliberately one-shot. While it stays set, *every* growth
    /// of the rendered window re-centres the row on the selection — including
    /// the growth the reader's own drag triggers when the next page is pulled
    /// in, which snapped the card strip back to the selected card each time and
    /// made "keep scrolling right" impossible. Nothing but a keyboard/deliberate
    /// selection asks for a scroll, so the request is spent the moment it is
    /// honoured.
    func consumeRevealRequest() {
        guard revealSelection else { return }
        revealSelection = false
    }

    /// A private item is unlocked individually.
    func isPrivateUnlocked(_ item: Clip) -> Bool {
        privateUnlockedIDs.contains(item.id)
    }

    func requestPrivateUnlock(
        for item: Clip,
        completion: @escaping (Bool) -> Void
    ) {
        if isPrivateUnlocked(item) {
            completion(true)
            return
        }
        guard !privateUnlockInFlight else {
            // P2 修复（2026-10-03）：说清是"已有验证在进行"——completion(false)
            // 会让调用方弹"需要系统验证"，用户误以为是没权限。
            showToast("已有验证正在进行，请稍候")
            completion(false)
            return
        }
        privateAuthenticationDidBegin()
        PrivacyGate.shared.requestUnlock(for: item.id) { [weak self] ok in
            guard let self else { return }
            self.privateAuthenticationDidEnd()
            if ok {
                self.privateUnlockedIDs.insert(item.id)
                self.privateUnlockTimers[item.id]?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.clearPrivateUnlockState(for: item.id)
                }
                self.privateUnlockTimers[item.id] = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 60,
                    execute: work
                )
            }
            completion(ok)
        }
    }

    /// Requests a fresh system prompt. Unlike `requestPrivateUnlock`, this does
    /// not reuse an existing 60-second unlock and does not create unlock state,
    /// because it guards permanent state changes such as “取消私密”.
    func requestFreshPrivateAuthentication(
        reason: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard !privateUnlockInFlight else {
            // P2 修复（2026-10-03）：说清是"已有验证在进行"——completion(false)
            // 会让调用方弹"需要系统验证"，用户误以为是没权限。
            showToast("已有验证正在进行，请稍候")
            completion(false)
            return
        }
        privateAuthenticationDidBegin()
        PrivacyGate.shared.requestAuthentication(reason: reason) { [weak self] ok in
            guard let self else { return }
            self.privateAuthenticationDidEnd()
            completion(ok)
        }
    }

    private func privateAuthenticationDidBegin() {
        privateUnlockInFlight = true
        onPrivateAuthenticationStateChanged?(true)
    }

    private func privateAuthenticationDidEnd() {
        privateUnlockInFlight = false
        onPrivateAuthenticationStateChanged?(false)
    }

    private func clearPrivateUnlockState(for id: UUID) {
        privateUnlockedIDs.remove(id)
        privateUnlockTimers[id]?.cancel()
        privateUnlockTimers[id] = nil
        noteDrafts[draftKey(id)] = nil
        if selectedID == id || noteEditingID == id {
            if showNoteEditor {
                showNoteEditor = false
            }
            noteDraft = ""
        }
        PrivacyGate.shared.markLocked(id)
    }

    /// “解锁查看”：先完成系统认证并建立 60 秒解锁状态，但不复制内容。
    func unlockForPreview(_ item: Clip) {
        requestPrivateUnlock(for: item) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                // "Unlock to view" that silently does nothing is
                // indistinguishable from a broken button.
                NSSound.beep()
                self.showToast("未解锁：需要系统验证")
                return
            }
            self.select(item)
            self.showToast("已解锁，60 秒内可直接查看与复制")
        }
    }

    func togglePrivate(_ item: Clip) {
        guard !rejectIfHistoryClearing() else { return }
        guard let current = store.clip(id: item.id) else { return }
        if current.isPrivate {
            cancelPrivate(current)
            return
        }
        _ = store.togglePrivate(current)
        // Re-setting the same item to private must start locked again, even if
        // an earlier 60-second unlock for that UUID is still valid.
        clearPrivateUnlockState(for: current.id)
        let nowPrivate = store.clip(id: item.id)?.isPrivate ?? false
        showToast(
            nowPrivate ? PrivateCoverDisclosure.toast : "操作失败，请重试"
        )
    }

    func cancelPrivate(_ item: Clip) {
        guard !rejectIfHistoryClearing() else { return }
        guard let current = store.clip(id: item.id), current.isPrivate else { return }
        requestFreshPrivateAuthentication(
            reason: "验证后取消 Clipa 私密遮挡"
        ) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.showToast("未取消私密：需要系统验证")
                return
            }
            guard let now = self.store.clip(id: current.id), now.isPrivate else { return }
            let updated = self.store.togglePrivate(now)
            self.clearPrivateUnlockState(for: now.id)
            self.showToast(updated ? "已取消私密" : "取消私密失败，请重试")
        }
    }

    func copy(_ item: Clip) {
        guard let current = store.clip(id: item.id) else {
            NSSound.beep()
            showToast("复制失败：条目不存在或已被删除")
            return
        }
        performClipboardCopy(current, successMessage: "已复制到剪贴板")
    }

    private func performClipboardCopy(
        _ item: Clip,
        successMessage: String
    ) {
        guard let current = store.clip(id: item.id) else {
            NSSound.beep()
            showToast("复制失败：条目不存在或已被删除")
            return
        }
        guard store.assetAvailability(for: current) == .available else {
            NSSound.beep()
            showToast(assetUnavailableMessage(for: current))
            return
        }
        if current.isPrivate, !isPrivateUnlocked(current) {
            requestPrivateUnlock(for: current) { [weak self] ok in
                guard ok else { return }
                self?.performClipboardCopy(
                    current,
                    successMessage: successMessage
                )
            }
            return
        }
        guard ClipboardWriter.shared.copy(current, store: store) else {
            NSSound.beep()
            showToast("复制失败，请重试")
            return
        }
        showToast(successMessage)
    }

    private func assetUnavailableMessage(for item: Clip) -> String {
        switch item.kind {
        case .image:
            return "图片数据缺失，无法复制"
        case .file:
            return "文件已被移动或删除，无法复制"
        default:
            return "复制失败，请重试"
        }
    }

    func delete(_ item: Clip) {
        guard !rejectIfHistoryClearing() else { return }
        guard let current = store.clip(id: item.id) else {
            showToast("条目不存在或已被删除")
            return
        }
        guard !current.isPrivate else {
            requestFreshPrivateAuthentication(
                reason: "验证后删除私密条目"
            ) { [weak self] ok in
                guard let self else { return }
                guard ok else {
                    self.showToast("未删除：需要系统验证")
                    return
                }
                self.performDelete(current)
            }
            return
        }
        performDelete(current)
    }

    /// Records which card takes the selection when `id` is deleted: the card
    /// that follows it, or the one before it when the deleted card was last.
    ///
    /// Deleting keeps the reader's place, which means two things: the row must
    /// not scroll (hence `revealSelection = false`), and the selection must land
    /// on the neighbour — the reconciler's fallback is the *first* row, which
    /// would silently move the reader to the top of the list.
    private func rememberNeighbour(of id: UUID) {
        revealSelection = false
        guard let index = navigationOrder.firstIndex(of: id) else {
            selectionSuccessor = nil
            return
        }
        if index + 1 < navigationOrder.count {
            selectionSuccessor = navigationOrder[index + 1]
        } else if index > 0 {
            selectionSuccessor = navigationOrder[index - 1]
        } else {
            selectionSuccessor = nil
        }
    }

    private func performDelete(_ item: Clip) {
        rememberNeighbour(of: item.id)
        switch store.delete(item) {
        case .deleted(let count) where count > 0:
            showToast("已删除")
        case .deleted:
            showToast("条目不存在或已被删除")
        case .failed:
            // The recorded neighbour belongs to a delete that did not happen:
            // leaving it set meant the *next* unrelated reorder that dropped the
            // selection moved it to a card the user never touched.
            selectionSuccessor = nil
            NSSound.beep()
            showToast("删除失败，请重试")
        }
    }

    func deleteMany(_ items: [Clip]) {
        guard !rejectIfHistoryClearing() else { return }
        let existing = items.compactMap { store.clip(id: $0.id) }
        guard !existing.isEmpty else {
            showToast("没有可删除的条目")
            return
        }
        let privateCount = existing.lazy.filter(\.isPrivate).count
        guard privateCount == 0 else {
            requestFreshPrivateAuthentication(
                reason: "验证后批量删除含私密内容的条目"
            ) { [weak self] ok in
                guard let self else { return }
                guard ok else {
                    self.showToast("未删除：需要系统验证")
                    return
                }
                self.performDeleteMany(existing)
            }
            return
        }
        performDeleteMany(existing)
    }

    private func performDeleteMany(_ items: [Clip]) {
        let requested = items.count
        // Same "keep the reader's place" contract as the single-card delete: if
        // the highlighted card is among the ones going away, remember where the
        // selection should land instead of letting the reconciler fall back to
        // the top of the list.
        if let selectedID, items.contains(where: { $0.id == selectedID }) {
            rememberNeighbour(of: selectedID)
        }
        switch store.delete(ids: Set(items.map(\.id))) {
        case .deleted(let count) where count == requested:
            showToast("已删除 \(count) 条")
        case .deleted(let count) where count > 0:
            showToast(
                "已删除 \(count) 条（\(requested - count) 条已不存在）"
            )
        case .deleted:
            showToast("没有可删除的条目")
        case .failed:
            NSSound.beep()
            showToast("删除失败，请重试")
        }
    }

    func togglePaused() {
        settings.pauseRecording.toggle()
        settings.autoPausedByLimit = false
        AppDelegate.shared?.syncPauseState()
        showToast(settings.pauseRecording ? "已暂停记录" : "已恢复记录")
    }

    func saveNote() {
        guard !noteIsSaving, let item = validatedNoteTarget() else { return }
        let saved = store.setNote(noteDraft.isEmpty ? nil : noteDraft, for: item)
        completeNoteSave(saved, item: item, savedDraft: noteDraft)
    }

    private func validatedNoteTarget() -> Clip? {
        guard !store.isClearingHistory else { noteError = "历史正在清空，请稍候。"; return nil }
        guard let item = noteEditingItem else { noteError = "原条目已不存在，草稿仍留在输入框中。"; return nil }
        guard !item.isPrivate || isPrivateUnlocked(item) else {
            discardNoteChanges()
            showToast("私密内容已锁定，未保存的备注已清除")
            return nil
        }
        guard noteDraft.prefix(20_001).count <= 20_000 else {
            noteError = "备注最多 20,000 个字，请缩短后再保存。"
            return nil
        }
        return item
    }

    private func completeNoteSave(_ saved: Bool, item: Clip, savedDraft: String) {
        guard saved else { noteError = "保存失败。草稿已保留，请重试。"; return }
        noteDrafts[draftKey(item.id)] = nil
        showNoteEditor = false
        noteEditingID = nil
        noteDraft = ""
        noteError = nil
        noteDiscardConfirmation = false
        showToast(savedDraft.isEmpty ? "已清除备注" : "已保存备注")
    }

    func togglePrivateAsync(_ item: Clip) async {
        guard !rejectIfHistoryClearing() else { return }
        guard let current = store.clip(id: item.id) else { return }
        if current.isPrivate {
            await cancelPrivateAsync(current)
            return
        }
        guard beginMutation(for: current.id) else { return }
        defer { endMutation(for: current.id) }
        let updated = await store.togglePrivateAsync(current)
        // Re-setting the same item to private must start locked again, even if
        // an earlier 60-second unlock for that UUID is still valid.
        clearPrivateUnlockState(for: current.id)
        let nowPrivate = store.clip(id: item.id)?.isPrivate ?? false
        showToast(
            updated && nowPrivate
                ? PrivateCoverDisclosure.toast
                : "操作失败，请重试"
        )
    }

    func cancelPrivateAsync(_ item: Clip) async {
        guard !rejectIfHistoryClearing() else { return }
        guard let current = store.clip(id: item.id), current.isPrivate else {
            return
        }
        guard beginMutation(for: current.id) else { return }
        defer { endMutation(for: current.id) }
        let ok = await requestFreshPrivateAuthenticationAsync(
            reason: "验证后取消 Clipa 私密遮挡"
        )
        guard ok else {
            showToast("未取消私密：需要系统验证")
            return
        }
        guard let now = store.clip(id: current.id), now.isPrivate else {
            return
        }
        let updated = await store.togglePrivateAsync(now)
        clearPrivateUnlockState(for: now.id)
        showToast(updated ? "已取消私密" : "取消私密失败，请重试")
    }

    func deleteAsync(_ item: Clip) async {
        guard !rejectIfHistoryClearing() else { return }
        guard let current = store.clip(id: item.id) else {
            showToast("条目不存在或已被删除")
            return
        }
        guard beginMutation(for: current.id) else { return }
        defer { endMutation(for: current.id) }
        if current.isPrivate {
            let ok = await requestFreshPrivateAuthenticationAsync(
                reason: "验证后删除私密条目"
            )
            guard ok else {
                showToast("未删除：需要系统验证")
                return
            }
        }
        rememberNeighbour(of: current.id)
        switch await store.deleteAsync(current) {
        case .deleted(let count) where count > 0:
            showToast("已删除")
        case .deleted:
            showToast("条目不存在或已被删除")
        case .failed:
            NSSound.beep()
            showToast("删除失败，请重试")
        }
    }

    func deleteManyAsync(_ items: [Clip]) async {
        guard !rejectIfHistoryClearing() else { return }
        let existing = items.compactMap { store.clip(id: $0.id) }
        guard !existing.isEmpty else {
            showToast("没有可删除的条目")
            return
        }
        let ids = Set(existing.map(\.id))
        let alreadyRunning = ids.contains {
            pendingMutatingIDs.contains($0)
        }
        guard !alreadyRunning else { return }
        for id in ids {
            pendingMutatingIDs.insert(id)
        }
        defer {
            for id in ids {
                pendingMutatingIDs.remove(id)
            }
        }
        let privateCount = existing.lazy.filter(\.isPrivate).count
        if privateCount > 0 {
            let ok = await requestFreshPrivateAuthenticationAsync(
                reason: "验证后批量删除含私密内容的条目"
            )
            guard ok else {
                showToast("未删除：需要系统验证")
                return
            }
        }
        let requested = existing.count
        // Same "keep the reader's place" contract as the single-card delete: if
        // the highlighted card is going away, remember where the selection
        // should land instead of letting the reconciler jump to the top.
        if let selectedID, ids.contains(selectedID) {
            rememberNeighbour(of: selectedID)
        }
        switch await store.deleteAsync(ids: ids) {
        case .deleted(let count) where count == requested:
            showToast("已删除 \(count) 条")
        case .deleted(let count) where count > 0:
            showToast(
                "已删除 \(count) 条（\(requested - count) 条已不存在）"
            )
        case .deleted:
            showToast("没有可删除的条目")
        case .failed:
            NSSound.beep()
            showToast("删除失败，请重试")
        }
    }

    func saveNoteAsync() async {
        guard !noteIsSaving, !noteDiscardConfirmation, let item = validatedNoteTarget() else { return }
        let source = store
        let draft = noteDraft
        let operation = UUID()
        noteOperation = operation
        noteIsSaving = true
        noteError = nil
        defer {
            if noteOperation == operation { noteOperation = nil; noteIsSaving = false }
        }
        let saved = await source.setNoteAsync(draft.isEmpty ? nil : draft, for: item)
        guard store === source, noteOperation == operation else { return }
        if item.isPrivate, !isPrivateUnlocked(item) { return }
        completeNoteSave(saved, item: item, savedDraft: draft)
    }

    /// - Returns: `true` when the content really reached the pasteboard. The
    ///   panel's copy-and-dismiss path needs that: a locked card whose Touch ID
    ///   prompt was cancelled must not take the whole panel down with it.
    @discardableResult
    func copyAsync(_ item: Clip) async -> Bool {
        guard copyingID == nil else { return false }
        copyingID = item.id
        defer { copyingID = nil }
        guard let current = store.clip(id: item.id) else {
            NSSound.beep()
            showToast("复制失败：条目不存在或已被删除")
            return false
        }
        return await performClipboardCopyAsync(
            current,
            successMessage: "已复制到剪贴板"
        )
    }

    @discardableResult
    private func performClipboardCopyAsync(
        _ item: Clip,
        successMessage: String
    ) async -> Bool {
        guard let current = store.clip(id: item.id) else {
            NSSound.beep()
            showToast("复制失败：条目不存在或已被删除")
            return false
        }
        guard await store.assetAvailabilityAsync(for: current) == .available else {
            NSSound.beep()
            showToast(assetUnavailableMessage(for: current))
            return false
        }
        if current.isPrivate, !isPrivateUnlocked(current) {
            let ok = await requestPrivateUnlockAsync(for: current)
            guard ok else {
                // Used to return in complete silence: the panel closed, or
                // nothing happened at all, and the user was left guessing
                // whether their Touch ID prompt had been rejected.
                NSSound.beep()
                showToast("未复制：需要系统验证")
                return false
            }
            return await performClipboardCopyAsync(
                current,
                successMessage: successMessage
            )
        }
        guard await ClipboardWriter.shared.copyAsync(
            current,
            store: store
        ) else {
            NSSound.beep()
            showToast("复制失败，请重试")
            return false
        }
        showToast(successMessage)
        return true
    }

    private func requestPrivateUnlockAsync(for item: Clip) async -> Bool {
        await withCheckedContinuation { continuation in
            requestPrivateUnlock(for: item) { ok in
                continuation.resume(returning: ok)
            }
        }
    }

    private func requestFreshPrivateAuthenticationAsync(
        reason: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            requestFreshPrivateAuthentication(reason: reason) { ok in
                continuation.resume(returning: ok)
            }
        }
    }

    private func beginMutation(for id: UUID) -> Bool {
        // A second action on a card whose first action is still in flight used
        // to be swallowed without a trace. A beep at least says "not now".
        guard pendingMutatingIDs.insert(id).inserted else {
            NSSound.beep()
            return false
        }
        return true
    }

    private func endMutation(for id: UUID) {
        pendingMutatingIDs.remove(id)
    }

    /// Opens the note editor after satisfying the private lock, if any.
    func openNoteEditor(_ item: Clip? = nil) {
        guard let target = item ?? selectedItem else {
            NSSound.beep()
            return
        }
        let item = store.clip(id: target.id) ?? target
        if item.isPrivate, !isPrivateUnlocked(item) {
            requestPrivateUnlock(for: item) { [weak self] ok in
                guard let self else { return }
                guard ok else {
                    NSSound.beep()
                    self.showToast("未打开备注：需要系统验证")
                    return
                }
                self.openNoteEditor(item)
            }
            return
        }
        guard !noteIsSaving else { return }
        let key = draftKey(item.id)
        guard noteDrafts[key] != nil || noteDrafts.count < 8 else {
            showToast("请先保存或放弃已有的备注草稿，再开始新的编辑")
            return
        }
        select(item)
        noteEditingID = item.id
        noteDraft = item.isPrivate ? item.note : (noteDrafts[key] ?? item.note)
        noteError = nil
        noteDiscardConfirmation = false
        showNoteEditor = true
    }

    func showToast(_ message: String) {
        toastWork?.cancel()
        toast = message
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) {
                self?.toast = nil
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    /// Returns true when a history mutation must be rejected because a clear
    /// transaction is currently running.
    private func rejectIfHistoryClearing() -> Bool {
        guard store.isClearingHistory else { return false }
        showToast("正在清空历史，请稍候")
        return true
    }

}

extension Color {
    /// P3 优化（2026-10-03）：按 hex 字符串缓存解析结果。调用点在卡片渲染
    /// 热路径上（每卡每帧 2 次），Scanner 解析不必每次都来。视图层调用，
    /// 字典只在主线程触达。
    private static var hexCache: [String: Color] = [:]

    init(hex: String) {
        if let cached = Self.hexCache[hex] {
            self = cached
            return
        }
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
        Self.hexCache[hex] = self
    }
}
