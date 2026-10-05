import Foundation

enum SearchSort: String, Equatable, Sendable {
    case relevance
    case newest
    case oldest
}

struct SearchQueryPlan: Equatable, Sendable {
    let originalQuery: String

    let keywordGroups: [[String]]
    let excludedKeywords: [String]

    let timeRange: DateInterval?
    let kinds: Set<ClipKind>
    let smartTags: Set<SmartTag>

    let sort: SearchSort
    let limit: Int?

    let isUnsatisfiable: Bool

    init(
        originalQuery: String,
        keywordGroups: [[String]],
        excludedKeywords: [String],
        timeRange: DateInterval?,
        kinds: Set<ClipKind>,
        smartTags: Set<SmartTag>,
        sort: SearchSort,
        limit: Int?,
        isUnsatisfiable: Bool = false
    ) {
        self.originalQuery = originalQuery
        self.keywordGroups = keywordGroups
        self.excludedKeywords = excludedKeywords
        self.timeRange = timeRange
        self.kinds = kinds
        self.smartTags = smartTags
        self.sort = sort
        self.limit = limit
        self.isUnsatisfiable = isUnsatisfiable
    }
}

extension SearchQueryPlan {

    static func keyword(
        _ raw: String,
        sort: SearchSort = .relevance
    ) -> SearchQueryPlan {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = SearchQuery.parse(trimmed)
            .terms
            .map { [$0.normalized] }
        return SearchQueryPlan(
            originalQuery: raw,
            keywordGroups: groups,
            excludedKeywords: [],
            timeRange: nil,
            kinds: [],
            smartTags: [],
            sort: sort,
            limit: nil
        )
    }
}
