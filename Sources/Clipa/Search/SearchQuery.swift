import Foundation

/// One parsed query token.
struct SearchTerm: Equatable {
    let raw: String
    let normalized: String
    let canUseFTS: Bool
}

/// Parsed user input. v2 deliberately has no DSL: `app:`, `before:`, quotes,
/// OR / NOT are not interpreted. Whitespace-separated tokens are AND-ed over
/// body + note.
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
    /// Minimal, predictable lexical parser: trim → normalize → whitespace
    /// split → AND. No hidden DSL. The structured natural-language plan is
    /// produced separately by the caller (see `SearchQueryPlan`).
    static func parse(_ rawQuery: String) -> SearchQuery {
        let raw = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = QueryNormalizer.normalizeQuery(raw)
        // P2 修复（2026-10-03）：查询长度上限。往搜索框粘贴一篇 10MB 文本
        // 会生成百万级 trigram 的 FTS 查询 + O(n·m) 的内存全库扫描，把主
        // actor 卡死。搜索框不是文档编辑器——2048 字符（数百个词）覆盖
        // 一切真实查询，超长部分截断。
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

    /// An FTS-eligible term must survive the FTS5 parser and be at least one
    /// full trigram (3 characters). Shorter terms (`AI`, `IP`, `C#`) are still
    /// searchable — they simply stay in the Memory validator path.
    static func canUseFTS(term: String) -> Bool {
        let normalized = QueryNormalizer.normalizeQuery(term)
        guard normalized.count >= 3 else { return false }
        // FTSQueryBuilder quotes every term, so code/URL punctuation such as
        // `192.168`, `/api/` or `a-b-c` is literal and safe. Only double
        // quotes are excluded (v2 does not parse quoted-phrase DSL).
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
    /// Source-app names a rule asked for (`clip.source == "Xcode"`). Empty
    /// means unconstrained; `SearchCriteria` applies it in memory, and its
    /// presence is what makes the rule take the full-candidate path instead of
    /// the "newest 20 000" fallback.
    var sources: Set<String> = []
}

/// Debuggable timing breakdown of one search.
/// Which strategy produced the text-match set. Exposed in `SearchMetrics` so
/// the debug card, logs and the parity harness can name the path a query took.
enum SearchTextTier: String, Equatable, Sendable {
    /// FTS produced a usable candidate set; the memory validator confirmed it.
    case ftsCandidates
    /// The SQL exact predicate replaced the full in-memory text scan.
    case sqlExact
    /// The complete in-memory scan — the reference implementation.
    case memoryScan
}

/// Debuggable timing breakdown of one search.
struct SearchMetrics: Equatable {
    let parseMS: Double
    let ftsMS: Double
    let validationMS: Double
    let rankingMS: Double
    let totalMS: Double

    let candidateCount: Int
    let resultCount: Int
    let textTier: SearchTextTier

    /// True when the SQL exact-match fast path produced the candidate set
    /// instead of the in-memory oracle scan.
    var exactFastPath: Bool { textTier == .sqlExact }
}

/// One ranked hit returned by a `SearchEngine`.
struct SearchResult: Sendable, Identifiable {
    let clip: Clip
    /// Zero-based position inside the ranked/ordered result list.
    let rank: Int

    var id: UUID { clip.id }
}

/// Full UI-facing search outcome: plan, ranked hits, sections and metrics.
struct SearchResponse {
    let query: SearchQuery
    let plan: SearchQueryPlan?
    let clips: [Clip]
    let results: [SearchResult]
    let sections: [ClipSectionModel]
    let metrics: SearchMetrics?
}
