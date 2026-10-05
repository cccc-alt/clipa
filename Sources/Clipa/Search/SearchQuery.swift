import Foundation

struct SearchTerm: Equatable {
    let raw: String
    let normalized: String
    let canUseFTS: Bool
}

struct SearchQuery: Equatable {
    let raw: String
    let normalized: String
    let terms: [SearchTerm]

    var isEmpty: Bool { terms.isEmpty }

    var ftsTerms: [SearchTerm] {
        terms.filter(\.canUseFTS)
    }

    var memoryTermStrings: [String] {
        terms.map(\.normalized)
    }
}

extension SearchQuery {

    static func parse(_ rawQuery: String) -> SearchQuery {
        let raw = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = QueryNormalizer.normalizeQuery(raw)

        if normalized.count > 2048 {
            normalized = String(normalized.prefix(2048))
        }
        guard !normalized.isEmpty else {
            return SearchQuery(raw: raw, normalized: "", terms: [])
        }

        let terms = normalized
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { String($0) }
            .filter { !$0.isEmpty }
            .map { rawToken -> SearchTerm in
                SearchTerm(
                    raw: rawToken,
                    normalized: rawToken,
                    canUseFTS: SearchQuery.canUseFTS(term: rawToken)
                )
            }
        return SearchQuery(raw: raw, normalized: normalized, terms: terms)
    }

    static func canUseFTS(term: String) -> Bool {
        let normalized = QueryNormalizer.normalizeQuery(term)
        guard normalized.count >= 3 else { return false }

        guard !normalized.contains("\"") else { return false }
        guard normalized.rangeOfCharacter(from: .controlCharacters) == nil else {
            return false
        }
        return true
    }
}

struct SearchFilter: Equatable {
    var onlyPrivate = false
    var onlySensitive = false
    var kinds: Set<ClipKind> = []
    var smartTags: Set<SmartTag> = []
    var timeRange: DateInterval?

    var sources: Set<String> = []
}

enum SearchTextTier: String, Equatable, Sendable {

    case ftsCandidates

    case sqlExact

    case memoryScan
}

struct SearchMetrics: Equatable {
    let parseMS: Double
    let ftsMS: Double
    let validationMS: Double
    let rankingMS: Double
    let totalMS: Double

    let candidateCount: Int
    let resultCount: Int
    let textTier: SearchTextTier

    var exactFastPath: Bool { textTier == .sqlExact }
}

struct SearchResult: Sendable, Identifiable {
    let clip: Clip

    let rank: Int

    var id: UUID { clip.id }
}

struct SearchResponse {
    let query: SearchQuery
    let plan: SearchQueryPlan?
    let clips: [Clip]
    let results: [SearchResult]
    let sections: [ClipSectionModel]
    let metrics: SearchMetrics?
}
