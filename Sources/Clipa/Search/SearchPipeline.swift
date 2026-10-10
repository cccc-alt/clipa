import Foundation

/// What one search produced.
///
/// The plan is kept because the panel's chip row reads it ("时间：最近一周",
/// "类型：yaml") — the chips describe the *local* plan the planner derived from
/// the search box, which is all the pipeline does now.
struct SearchPipelineResult: Sendable {
    let clips: [Clip]
    let plan: SearchQueryPlan
}

/// The panel's one search path: box text + filters, resolved locally.
///
/// A local planner and a local engine, no network. Every AI-assisted variant
/// this file once carried was removed (see `docs/verification.md`); what is
/// left is the part the panel always needed.
final class DefaultSearchPipeline: @unchecked Sendable {
    private let store: any SearchDataSource
    private let localSearchEngine: LocalSearchEngine

    init(store: any SearchDataSource, localSearchEngine: LocalSearchEngine) {
        self.store = store
        self.localSearchEngine = localSearchEngine
    }

    /// Synchronous form for callers that must have a result before returning
    /// (the self-test, the panel's first paint).
    func performLocalSearch(
        query: String,
        uiFilter: SearchFilter,
        dataSource: (any SearchDataSource)? = nil,
        sort: SearchSort = .relevance
    ) -> SearchPipelineResult {
        TaskBlocking.run {
            await self.performLocalSearchAsync(
                query: query,
                uiFilter: uiFilter,
                dataSource: dataSource,
                sort: sort
            )
        }
    }

    /// The real implementation. Every actor call is awaited, so a caller
    /// running inside a task never blocks a cooperative thread.
    ///
    /// `sort` 只对**有关键词**的查询生效：空查询本身就是最近使用序（recency），
    /// 两种排序在那里是同一个东西。
    func performLocalSearchAsync(
        query: String,
        uiFilter: SearchFilter,
        dataSource: (any SearchDataSource)? = nil,
        sort: SearchSort = .relevance
    ) async -> SearchPipelineResult {
        let searchStore = dataSource ?? store
        let trimmedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmedQuery.isEmpty {
            return await performPlainLocalSearchAsync(
                query: "",
                uiFilter: uiFilter,
                store: searchStore
            )
        }
        return await performWholeKeywordLocalSearchAsync(
            query: trimmedQuery,
            uiFilter: uiFilter,
            store: searchStore,
            sort: sort
        )
    }

    /// Ordinary local search: the search-box words are AND-ed. No
    /// time/type/smart-tag/sort/limit rules are applied.
    ///
    /// The plan comes from `SearchQueryPlan.keyword` so there is exactly one
    /// definition of "what the box means" — the engine's own default path
    /// (`plan == nil`) builds the same plan, and the two used to disagree:
    /// callers that let the engine build the plan AND-ed the words, while the
    /// panel's path collapsed them into one phrase.
    private func performWholeKeywordLocalSearchAsync(
        query rawQuery: String,
        uiFilter: SearchFilter,
        store: any SearchDataSource,
        sort: SearchSort
    ) async -> SearchPipelineResult {
        let plan = SearchQueryPlan.keyword(rawQuery, sort: sort)
        let result = await localSearchEngine.searchAsync(
            query: rawQuery,
            filter: uiFilter,
            store: store,
            plan: plan
        )
        return SearchPipelineResult(
            clips: result.clips,
            plan: result.plan ?? plan
        )
    }

    private func performPlainLocalSearchAsync(
        query: String,
        uiFilter: SearchFilter,
        store: (any SearchDataSource)? = nil
    ) async -> SearchPipelineResult {
        let searchStore = store ?? self.store
        let scopeText = SearchBoxSplitter.split(query).scopeText
        let result = await localSearchEngine.searchAsync(
            query: scopeText,
            filter: uiFilter,
            store: searchStore
        )
        let plan = result.plan ?? SearchQueryPlan.keyword(scopeText)
        return SearchPipelineResult(clips: result.clips, plan: plan)
    }
}
