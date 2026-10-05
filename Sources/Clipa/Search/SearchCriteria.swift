import Foundation

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

    static let never = SearchTimeWindow(
        start: .distantFuture,
        end: .distantPast
    )
}

struct SearchCriteria: Sendable {
    let originalQuery: String

    let groups: [[String]]
    let excludedKeywords: [String]
    let onlyPrivate: Bool
    let onlySensitive: Bool

    let sources: Set<String>

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

            if timeRange.isEmpty { return false }
            if !Self.withinInterval(timeRange, date: clip.lastCopiedAt) {
                return false
            }
        }
        return true
    }

    static func withinInterval(
        _ window: SearchTimeWindow,
        date: Date
    ) -> Bool {
        let tolerance = 1.0
        return date >= window.start.addingTimeInterval(-tolerance)
            && date <= window.end.addingTimeInterval(tolerance)
    }

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

            return SearchTimeWindow(
                start: max(lhs.start, rhs.start),
                end: min(lhs.end, rhs.end)
            )
        }
    }
}
