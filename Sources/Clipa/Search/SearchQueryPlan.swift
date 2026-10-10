import Foundation

enum SearchSort: String, Equatable, Sendable {
    case relevance
    case newest
    case oldest
}

/// The search plan: what to look for, and how to present it.
///
/// Semantics:
/// - `keywordGroups` are AND-ed groups; every group must match at least one
///   of its own terms (group == OR).
/// - `excludedKeywords` must match none.
/// - time / kind / sort / limit are metadata filters applied after recall.
///
/// Only `keywordGroups` and `sort` are ever populated now that the local
/// natural-language parser is gone; the remaining fields stay because the
/// recall and ranking layers still read them.
struct SearchQueryPlan: Equatable, Sendable {
    let originalQuery: String

    /// e.g. [[A], [B]] = A AND B; [[A, B]] = A OR B.
    let keywordGroups: [[String]]
    let excludedKeywords: [String]

    let timeRange: DateInterval?
    let kinds: Set<ClipKind>
    let smartTags: Set<SmartTag>

    let sort: SearchSort
    let limit: Int?

    /// True when the plan can never be satisfied — today that only happens when
    /// a plan's time range and the UI filter's range do not overlap. The
    /// constraint cannot be expressed as a `DateInterval` (that would trap), so
    /// it travels as a flag and `SearchCriteria` turns it into an empty window.
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
    /// The literal plan: whitespace-separated words are AND-ed, and no time /
    /// type / exclusion / sort rules are derived from the input.
    ///
    /// One group per word — `docker network` means "contains both", which is
    /// what `SearchQuery` has always documented ("whitespace-separated tokens
    /// are AND-ed over body + note") and what every other search field does. It
    /// used to collapse the whole box into a *single* phrase, so the two words
    /// only matched where they happened to be adjacent.
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
