import Foundation

struct SearchPipelineResult: Sendable {
    let clips: [Clip]
    let plan: SearchQueryPlan
}

final class DefaultSearchPipeline: @unchecked Sendable {
    private let store: any SearchDataSource
    private let localSearchEngine: LocalSearchEngine

    init(store: any SearchDataSource, localSearchEngine: LocalSearchEngine) {
        self.store = store
        self.localSearchEngine = localSearchEngine
    }

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
