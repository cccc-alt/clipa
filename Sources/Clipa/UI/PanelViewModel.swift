import AppKit
import Combine
import Foundation
import ImageIO
import SwiftUI

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

enum SearchState: Equatable {
    case idle
    case searching
    case showingResults
}

@MainActor
/// Panel state and actions: search, selection, notes, privacy.
final class PanelViewModel: ObservableObject {

    private(set) var store: ClipStore
    let settings: SettingsStore

    private var searchPipeline: DefaultSearchPipeline
    private var cancellables = Set<AnyCancellable>()

    private var settingsCancellable: AnyCancellable?

    private var sharedStoreCancellable: AnyCancellable?

    @Published var query = ""

    @Published var searchSort: SearchSort = .relevance {
        didSet {
            guard oldValue != searchSort else { return }
            filtersDidChange()
        }
    }
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var results: [ClipSectionModel] = []
    @Published private(set) var searchState: SearchState = .idle

    @Published var kindFilter: ClipKind?
    @Published var smartTagFilter: SmartTag?
    @Published var isSearchFieldFocused = false

    enum Surface {
        case main
        case quickStrip
    }
    @Published var activeSurface: Surface?
    @Published var selectedID: UUID?
    @Published var openTick = 0
    @Published var toast: String?

    @Published private(set) var revealSelection = true

    @Published private(set) var revealRequestTick = 0
    @Published var noteDraft = ""
    @Published var showNoteEditor = false
    @Published private var privateUnlockedIDs: Set<UUID> = []

    var onPark: (() -> Void)?

    var onPrivateAuthenticationStateChanged: ((Bool) -> Void)?

    private var toastWork: DispatchWorkItem?
    private var privateUnlockTimers: [UUID: DispatchWorkItem] = [:]
    private var privateUnlockInFlight = false

    private var pendingMutatingIDs: Set<UUID> = []

    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    private var selectionSuccessor: UUID?

    @Published private(set) var navigationOrder: [UUID] = []

    @Published private(set) var listEntries: [HistoryListEntry] = []

    @Published private(set) var renderedRange: Range<Int> = 0..<0

    private var renderedContextHeader: HistoryListEntry?

    private var entryIndexByNavigationIndex: [Int] = []
    private var lastNavigationSelectedID: UUID?
    private var lastNavigationIndex = 0

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

        settingsCancellable = settings.$pauseRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }

        sharedStoreCancellable = NotificationCenter.default
            .publisher(for: ClipStore.sharedReplacedNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebind(store: .shared)
            }

        refreshWithoutBlockingMainThread()
    }

    private func subscribeToStores() {
        store.itemsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()

                self.refreshActiveQuery(preserveWindow: true)
                if let selectedID = self.selectedID,
                   self.store.clip(id: selectedID) == nil {

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

    private func releaseStoreBoundState() {
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

        PrivacyGate.shared.markLocked()
    }

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

    private func refreshWithoutBlockingMainThread() {
        searchTask?.cancel()
        searchGeneration += 1
        runLocalSearch(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            filter: currentFilter,
            generation: searchGeneration
        )
    }

    private var currentFilter: SearchFilter {
        SearchFilter(
            kinds: kindFilter.map { [$0] } ?? [],
            smartTags: smartTagFilter.map { [$0] } ?? []
        )
    }

    func selectKindFilter(_ kind: ClipKind?) {
        smartTagFilter = nil
        kindFilter = kind
        filtersDidChange()
    }

    func retryStoreConnection() {
        if store.retryDatabaseOpen() {
            showToast(StoreUnavailableCopy.retrySucceeded)
        } else {
            showToast(StoreUnavailableCopy.retryFailed)
        }
    }

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

    var hasActiveFilter: Bool {
        isFiltering
            || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var historyCountText: String {
        let total = store.items.count
        guard hasActiveFilter else { return "共 \(total) 条" }
        return "结果 \(navigationOrder.count) 条 · 共 \(total) 条"
    }

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
        clips = result.clips
        results = ClipGrouper.group(
            clips: result.clips,
            calendar: .current,
            now: Date()
        )
        navigationOrder = results.flatMap(\.clips).map(\.id)
        rebuildListEntries(preserveWindow: preserveWindow)
        reconcileSelection(with: navigationOrder)
    }

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

    var renderedClips: [Clip] {
        renderedEntries.compactMap { entry in
            guard case .clip(let clipID) = entry else { return nil }
            return store.clip(id: clipID)
        }
    }

    var canLoadMoreCards: Bool {
        canExtendRenderedWindow
    }

    var canExtendRenderedWindowUpward: Bool {
        renderedRange.lowerBound > 0
    }

    func extendRenderedWindow() {
        guard canExtendRenderedWindow else { return }
        let upper = min(
            listEntries.count,
            renderedRange.upperBound + Self.listWindowPageSize
        )
        renderedRange = renderedRange.lowerBound..<upper
    }

    func extendRenderedWindowUpward() {
        guard canExtendRenderedWindowUpward else { return }
        let lower = max(
            0,
            renderedRange.lowerBound - Self.listWindowPageSize
        )
        renderedRange = lower..<renderedRange.upperBound
        renderedContextHeader = contextHeader(before: lower)
    }

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

            extendRenderedWindow()
            if renderedRange.contains(entryIndex) { return }
        }

        let start = max(
            0,
            min(entryIndex - page / 2, max(0, listEntries.count - page))
        )
        let end = min(listEntries.count, start + page)
        renderedRange = start..<end
        renderedContextHeader = contextHeader(before: start)
    }

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

    private func reconcileSelection(with visibleIDs: [UUID]) {

        let successor = selectionSuccessor.flatMap { candidate in
            visibleIDs.contains(candidate) ? candidate : nil
        }

        if selectedID == nil, let nextID = successor ?? visibleIDs.first {
            selectionSuccessor = nil
            revealSelection = false
            selectedID = nextID
            lastNavigationSelectedID = nextID
            lastNavigationIndex = 0
            return
        }
        if let selectedID, !visibleIDs.contains(selectedID) {

            selectionSuccessor = nil
            revealSelection = false

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

    }

    func refreshSearch() {

        searchGeneration += 1
        let filter = currentFilter
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

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

            refreshActiveQuery()
            return
        }

        searchGeneration += 1
        let generation = searchGeneration
        let filter = currentFilter
        searchState = .searching

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

            guard !Task.isCancelled else { return }

            let result = await Task.detached(priority: .userInitiated) {
                await pipeline.performLocalSearchAsync(
                    query: query,
                    uiFilter: filter,
                    dataSource: snapshot,
                    sort: sort
                )
            }.value
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

    var searchBoxSplit: SearchBoxSplit {
        SearchBoxSplitter.split(query)
    }

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

        ensureEntryVisible(clipID: nextID)
        selectGated(item)
    }

    func isSensitive(_ item: Clip) -> Bool {
        item.containsSensitive
    }

    func relativeTime(for date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }

        return Self.relativeDateFormatter.string(from: date)
    }

    private static let relativeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    func select(_ item: Clip) {

        revealSelection = true
        revealRequestTick &+= 1
        selectionSuccessor = nil

        commitPendingNoteDraftIfNeeded()
        if selectedID != item.id {
            selectedID = item.id
        }
        if item.isPrivate, !isPrivateUnlocked(item) {
            noteDraft = ""
        } else if noteDraft != item.note {
            noteDraft = item.note
        }
        if showNoteEditor {
            showNoteEditor = false
        }
    }

    private func commitPendingNoteDraftIfNeeded() {
        guard showNoteEditor, let editing = selectedItem else { return }
        let draft = noteDraft
        guard draft != editing.note else { return }
        Task { [weak self] in
            guard let self else { return }
            let saved = await self.store.setNoteAsync(
                draft.isEmpty ? nil : draft,
                for: editing
            )
            if !saved {
                self.showToast("备注保存失败，请重试")
            }
        }
    }

    func selectGated(_ item: Clip) {
        select(item)
    }

    func consumeRevealRequest() {
        guard revealSelection else { return }
        revealSelection = false
    }

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

    func requestFreshPrivateAuthentication(
        reason: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard !privateUnlockInFlight else {

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
        if selectedID == id {
            if showNoteEditor {
                showNoteEditor = false
            }
            noteDraft = ""
        }
        PrivacyGate.shared.markLocked(id)
    }

    func unlockForPreview(_ item: Clip) {
        requestPrivateUnlock(for: item) { [weak self] ok in
            guard let self else { return }
            guard ok else {

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
        guard !rejectIfHistoryClearing() else { return }
        guard let item = selectedItem else { return }
        guard !item.isPrivate || isPrivateUnlocked(item) else {
            showNoteEditor = false
            noteDraft = ""
            showToast("私密内容已重新锁定，未保存备注")
            return
        }
        _ = store.setNote(noteDraft.isEmpty ? nil : noteDraft, for: item)
        showToast(noteDraft.isEmpty ? "已清除备注" : "已保存备注")
        showNoteEditor = false
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
        guard !rejectIfHistoryClearing() else { return }
        guard let item = selectedItem else { return }
        guard !item.isPrivate || isPrivateUnlocked(item) else {
            showNoteEditor = false
            noteDraft = ""
            showToast("私密内容已重新锁定，未保存备注")
            return
        }
        let note = noteDraft
        let saved = await store.setNoteAsync(
            note.isEmpty ? nil : note,
            for: item
        )
        showToast(
            saved
                ? (note.isEmpty ? "已清除备注" : "已保存备注")
                : "备注保存失败，请重试"
        )
        showNoteEditor = false
    }

    @discardableResult
    func copyAsync(_ item: Clip) async -> Bool {
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

        guard pendingMutatingIDs.insert(id).inserted else {
            NSSound.beep()
            return false
        }
        return true
    }

    private func endMutation(for id: UUID) {
        pendingMutatingIDs.remove(id)
    }

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
        select(item)
        noteDraft = item.note
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

    private func rejectIfHistoryClearing() -> Bool {
        guard store.isClearingHistory else { return false }
        showToast("正在清空历史，请稍候")
        return true
    }

}

extension Color {

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
