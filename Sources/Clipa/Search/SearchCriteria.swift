import Foundation

/// A time window that can be *empty*.
///
/// `DateInterval` cannot represent "these two ranges do not overlap": both of
/// its initializers trap when start > end on this platform, and the search
/// path used to build exactly that whenever a plan's range and the UI filter's
/// range were disjoint — a hard crash instead of "no results". Callers
/// therefore intersect windows (which may be empty) and only turn a non-empty
/// one back into a `DateInterval`.
struct SearchTimeWindow: Equatable, Sendable {
    let start: Date
    let end: Date

    var isEmpty: Bool { start > end }

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    init(_ interval: DateInterval) {
        start = interval.start
        end = interval.end
    }

    var interval: DateInterval? {
        isEmpty ? nil : DateInterval(start: start, end: end)
    }

    /// Matches nothing, for a plan that can never be satisfied.
    static let never = SearchTimeWindow(
        start: .distantFuture,
        end: .distantPast
    )
}

/// One merged description of a search: the text semantics plus every metadata
/// constraint, produced once from a plan and the UI filter.
///
/// Before this type the merge rules lived inside `LocalSearchEngine`
/// (`matchesMetadata`) and had to be repeated anywhere else that needed them.
/// Now there is a single merge, and two renderings of the same data:
///
/// - `matches(clip:)` — the oracle predicate, evaluated in memory;
/// - `SearchRepository.exactCandidateIDs(criteria:)` — the SQL rendering of
///   the *text* half only, used by the accuracy-gated fast path.
struct SearchCriteria: Sendable {
    let originalQuery: String
    /// AND-ed groups; a group is OR-ed. An empty group can never be hit.
    let groups: [[String]]
    let excludedKeywords: [String]
    let onlyPrivate: Bool
    let onlySensitive: Bool
    /// Lower-cased source-app names; empty = unconstrained.
    let sources: Set<String>
    /// `nil` = unconstrained, empty set = matches nothing.
    let kinds: Set<ClipKind>?
    let smartTags: Set<SmartTag>?
    let timeRange: SearchTimeWindow?
    let sort: SearchSort
    let limit: Int?

    init(plan: SearchQueryPlan, filter: SearchFilter = SearchFilter()) {
        originalQuery = plan.originalQuery
        groups = plan.keywordGroups
        excludedKeywords = plan.excludedKeywords
        onlyPrivate = filter.onlyPrivate
        onlySensitive = filter.onlySensitive
        sources = Set(filter.sources.map { $0.lowercased() })
        kinds = Self.intersect(plan.kinds, filter.kinds)
        smartTags = Self.intersect(plan.smartTags, filter.smartTags)
        timeRange = plan.isUnsatisfiable
            ? .never
            : Self.intersect(
                plan.timeRange.map(SearchTimeWindow.init),
                filter.timeRange.map(SearchTimeWindow.init)
            )
        sort = plan.sort
        limit = plan.limit
    }

    var hasPositiveKeywords: Bool { !groups.isEmpty }

    /// True when no text term relies on canonical equivalence, so the byte
    /// substring predicate in SQLite is guaranteed to see the same matches.
    /// Terms are normalized first: normalization itself can introduce a
    /// combining mark.
    var allTermsAreByteSubstringSafe: Bool {
        for group in groups {
            for term in group
            where !SearchTextSafety.isByteSubstringSafe(
                QueryNormalizer.normalizeQuery(term)
            ) {
                return false
            }
        }
        for term in excludedKeywords
        where !SearchTextSafety.isByteSubstringSafe(
            QueryNormalizer.normalizeQuery(term)
        ) {
            return false
        }
        return true
    }

    /// Oracle predicate. Equivalent to the previous `matchesMetadata`.
    func matches(clip: Clip) -> Bool {
        if clip.isHidden { return false }
        if onlyPrivate && !clip.isPrivate { return false }
        if onlySensitive && !clip.containsSensitive { return false }
        if !sources.isEmpty,
           !sources.contains((clip.sourceApp ?? "").lowercased()) {
            return false
        }
        if let kinds, !kinds.contains(clip.kind) { return false }
        if let smartTags, !smartTags.contains(clip.smartTag) { return false }
        if let timeRange {
            // An empty window matches nothing: the ±1s storage tolerance must
            // not resurrect it.
            if timeRange.isEmpty { return false }
            if !Self.withinInterval(timeRange, date: clip.lastCopiedAt) {
                return false
            }
        }
        return true
    }

    /// SQLite stores integer seconds (`rounded()`), so a clip captured late in
    /// a second can appear up to 1s after `Date()`. Time filters must not
    /// exclude that row just because of storage rounding.
    static func withinInterval(
        _ window: SearchTimeWindow,
        date: Date
    ) -> Bool {
        let tolerance = 1.0
        return date >= window.start.addingTimeInterval(-tolerance)
            && date <= window.end.addingTimeInterval(tolerance)
    }

    /// `nil` means "no constraint"; two non-empty sets intersect, which is the
    /// rule the UI already relied on (contradictory filters match nothing).
    private static func intersect<T: Hashable>(
        _ plan: Set<T>,
        _ filter: Set<T>
    ) -> Set<T>? {
        if !plan.isEmpty && !filter.isEmpty { return plan.intersection(filter) }
        if !plan.isEmpty { return plan }
        if !filter.isEmpty { return filter }
        return nil
    }

    private static func intersect(
        _ plan: SearchTimeWindow?,
        _ filter: SearchTimeWindow?
    ) -> SearchTimeWindow? {
        switch (plan, filter) {
        case (nil, nil):
            return nil
        case (let value?, nil), (nil, let value?):
            return value
        case (let lhs?, let rhs?):
            // Tolerant of start > end on purpose: an empty window is how the
            // caller learns that the two ranges cannot both hold.
            return SearchTimeWindow(
                start: max(lhs.start, rhs.start),
                end: min(lhs.end, rhs.end)
            )
        }
    }
}
