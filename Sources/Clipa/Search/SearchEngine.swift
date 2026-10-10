import Foundation

/// Unified search entry point from the design contract:
/// `search(query:plan:)` returns one `SearchResult` per ranked hit.
protocol SearchEngine: Sendable {
    func search(
        query: String,
        plan: SearchQueryPlan?
    ) async throws -> [SearchResult]
}

enum SearchEngineError: LocalizedError {
    case missingStore

    var errorDescription: String? {
        switch self {
        case .missingStore:
            return "搜索需要关联 ClipStore，请通过 init(store:) 创建搜索服务。"
        }
    }
}

/// Selects how the text half of a search is evaluated.
///
/// The SQL path is only ever an optimization: every rule other than "which
/// rows contain these phrases" (metadata, ranking, grouping, limits) stays in
/// Swift, and any query the fast path cannot prove equivalent falls back to
/// the in-memory oracle.
enum SearchTextMatchMode: Sendable {
    /// SQL when it is provably equivalent, oracle otherwise.
    case automatic
    /// Always the in-memory index. Used as the reference in parity tests.
    case oracleOnly
    /// Demand the SQL path; still falls back when unavailable, which the
    /// parity harness detects through `SearchMetrics.exactFastPath`.
    case sqlOnly
}

/// Concrete local implementation of `SearchEngine`.
///
/// Recall is narrowed by FTS5 when possible, then MemorySearchIndex performs
/// the final phrase/exclusion semantics and metadata filters (time/kind)
/// are applied in memory before ranking/grouping. The query itself is always a
/// literal keyword: nothing is parsed out of it.
final class LocalSearchEngine: SearchEngine, @unchecked Sendable {
    let database: DatabaseManager?
    private let store: (any SearchDataSource)?
    private let filter: SearchFilter
    private let textMatchMode: SearchTextMatchMode

    /// How many canonically ambiguous rows the fast path may have to re-check in
    /// Swift before it gives up and hands the query to the oracle.
    ///
    /// A budget *per query*, not a property of the library. Gating on how many
    /// ambiguous rows the store holds in total switched the SQL fast path off
    /// for good once a library passed this many emoji / combining characters,
    /// after which every keystroke fell back to scanning all 100k rows — even
    /// for a query that never touched an ambiguous row.
    private static let ambiguousRowBudget = 2000

    /// Prefer the store's current handle: after a failed open is retried, a
    /// long-lived engine must not keep querying the stale connection.
    private var liveDatabase: DatabaseManager? {
        store?.database ?? database
    }

    init(
        database: DatabaseManager? = nil,
        store: (any SearchDataSource)? = nil,
        filter: SearchFilter = SearchFilter(),
        textMatchMode: SearchTextMatchMode = .automatic
    ) {
        self.database = database
        self.store = store
        self.filter = filter
        self.textMatchMode = textMatchMode
    }

    /// Protocol entry point. Instances created without a store throw; the
    /// detailed synchronous `search(query:filter:store:...)` below remains
    /// available to callers that need sectioned UI results.
    func search(
        query: String,
        plan: SearchQueryPlan?
    ) async throws -> [SearchResult] {
        try Task.checkCancellation()
        guard let store else { throw SearchEngineError.missingStore }
        let response = await searchAsync(
            query: query, filter: filter, store: store, plan: plan
        )
        try Task.checkCancellation()
        return response.results
    }

    /// Synchronous entry point for callers that are not cooperative-pool
    /// threads: the main thread, a CLI probe or a test. Callers already inside
    /// a task must use `searchAsync` — blocking a pool thread while the inner
    /// work needs one deadlocks (see `TaskBlocking`).
    func search(
        query rawQuery: String,
        filter: SearchFilter,
        store: any SearchDataSource,
        plan providedPlan: SearchQueryPlan? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SearchResponse {
        TaskBlocking.run {
            await self.searchAsync(
                query: rawQuery,
                filter: filter,
                store: store,
                plan: providedPlan,
                now: now,
                calendar: calendar
            )
        }
    }

    /// The real implementation. Every database call is awaited, so a caller
    /// running inside a task never blocks a cooperative thread.
    func searchAsync(
        query rawQuery: String,
        filter: SearchFilter,
        store: any SearchDataSource,
        plan providedPlan: SearchQueryPlan? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> SearchResponse {
        let start = SearchClock.now()
        let query = SearchQuery.parse(rawQuery)
        let plan = providedPlan ?? SearchQueryPlan.keyword(rawQuery)
        let parseEnd = SearchClock.now()
        let cancelled = SearchResponse(
            query: query, plan: plan, clips: [], results: [], sections: [], metrics: nil
        )
        guard !Task.isCancelled else { return cancelled }

        let hasPositive = !plan.keywordGroups.isEmpty
        // Nothing to match and nothing to rank: every row scores zero, so
        // "relevance" order *is* the recency order the store already keeps.
        // Scanning the whole library to build match evidence and then sorting
        // by a constant was the most expensive way to do nothing — and the
        // empty search box is the query the panel runs on every capture, so it
        // is the hottest search in the app.
        let isKeywordless = !hasPositive
            && plan.excludedKeywords.isEmpty
            && plan.sort == .relevance
        let criteria = SearchCriteria(plan: plan, filter: filter)
        // Scoring inputs, computed once and shared by every matcher so the
        // ranker never has to read a clip body again.
        let positiveTerms = plan.keywordGroups.flatMap { $0 }
        let termLengths = positiveTerms.map {
            QueryNormalizer.normalizeQuery($0).count
        }
        let orderedPhrase = SearchRanker.orderedPhrase(
            groups: plan.keywordGroups
        )
        let needsEvidence = plan.sort == .relevance && !isKeywordless

        // 1) FTS candidate recall. Metadata-only queries never touch FTS.
        var candidateIDs: Set<Int64>?
        var ftsMS = 0.0
        let ftsStart = SearchClock.now()
        if hasPositive,
           let ftsQuery = FTSQueryBuilder.buildGroupQuery(
               groups: plan.keywordGroups
           ) {
            var recall: FTSRepository.FTSCandidateRecall?
            if let database = store.database ?? liveDatabase {
                do {
                    recall = try await database.ftsCandidateIDs(query: ftsQuery)
                } catch {
                    if Task.isCancelled { return cancelled }
                    NSLog("Clipa FTS recall failed: \(error.localizedDescription)")
                }
            }
            // Empty or truncated FTS recall is not a usable candidate set:
            // step 2 either runs the SQL exact predicate or, when that cannot
            // be proven equivalent, the complete in-memory scan.
            if let recall {
                candidateIDs =
                    (!recall.truncated && !recall.ids.isEmpty)
                    ? recall.ids
                    : nil
            }
            ftsMS = SearchClock.milliseconds(from: ftsStart)
        } else if hasPositive {
            // A group contains only short terms (AI / C# / IP): FTS cannot
            // express it, so there is no candidate set to narrow with.
            candidateIDs = nil
        }

        guard !Task.isCancelled else { return cancelled }

        // 2) Memory validator: exact body + note semantics.
        //
        // When FTS could not produce a usable candidate set (no FTS-eligible
        // term, empty recall, or a truncated recall) the oracle would scan
        // every clip's text in Swift. The SQL fast path runs the same text
        // predicate over the normalized columns in C instead and only falls
        // back when it cannot prove equivalence.
        let validationStart = SearchClock.now()
        var matchingIDs: [Int64] = []
        var evidenceByID: [Int64: ClipMatchEvidence] = [:]
        let textTier: SearchTextTier
        var fastMatches: [(dbID: Int64, evidence: ClipMatchEvidence)]?
        var fastIDs: [Int64]?
        if isKeywordless {
            // Take the ids straight out of the index: no term to test, no
            // evidence to build, and nothing the ranker could reorder.
            matchingIDs = store.memoryIndex.allIDs()
            textTier = .memoryScan
        } else {
            if hasPositive, candidateIDs == nil {
                if needsEvidence {
                    fastMatches = await exactMatches(
                        criteria: criteria,
                        store: store,
                        terms: positiveTerms,
                        termLengths: termLengths,
                        phrase: orderedPhrase
                    )
                } else {
                    // Explicit sorts never rank, so the fact projection would
                    // be wasted work.
                    fastIDs = await exactIDs(criteria: criteria, store: store)
                }
            }
            guard !Task.isCancelled else { return cancelled }
            if let fastMatches {
                matchingIDs = fastMatches.map(\.dbID)
                evidenceByID = Dictionary(
                    fastMatches.map { ($0.dbID, $0.evidence) },
                    uniquingKeysWith: { first, _ in first }
                )
                textTier = .sqlExact
            } else if let fastIDs {
                matchingIDs = fastIDs
                textTier = .sqlExact
            } else if needsEvidence {
                // One pass produces both the match verdict and the scoring
                // facts.
                let matches = store.memoryIndex.evidenceMatches(
                    candidateIDs: candidateIDs,
                    groups: plan.keywordGroups,
                    excludedKeywords: plan.excludedKeywords,
                    termLengths: termLengths,
                    phrase: orderedPhrase
                )
                matchingIDs = matches.map(\.dbID)
                evidenceByID = Dictionary(
                    matches.map { ($0.dbID, $0.evidence) },
                    uniquingKeysWith: { first, _ in first }
                )
                textTier = candidateIDs == nil ? .memoryScan : .ftsCandidates
            } else {
                // Explicit sorts never rank, so the short-circuiting matcher is
                // still the cheapest option.
                matchingIDs = store.memoryIndex.matchingIDs(
                    candidateIDs: candidateIDs,
                    groups: plan.keywordGroups,
                    excludedKeywords: plan.excludedKeywords
                )
                textTier = candidateIDs == nil ? .memoryScan : .ftsCandidates
            }
        }
        guard !Task.isCancelled else { return cancelled }
        let validationMS = SearchClock.milliseconds(from: validationStart)

        // 3) Metadata filters (hidden / kind / natural time), fused
        // with the materialization the ranker needs so the clips are only
        // copied once.
        var clips: [Clip] = []
        clips.reserveCapacity(matchingIDs.count)
        var rankingEvidence: [ClipMatchEvidence] = []
        if needsEvidence { rankingEvidence.reserveCapacity(matchingIDs.count) }
        var missingEvidence = false
        for (offset, dbID) in matchingIDs.enumerated() {
            if offset & 255 == 0, Task.isCancelled { return cancelled }
            guard let clip = store.clip(dbID: dbID),
                  criteria.matches(clip: clip) else { continue }
            clips.append(clip)
            guard needsEvidence else { continue }
            if let item = evidenceByID[dbID] {
                rankingEvidence.append(item)
            } else {
                missingEvidence = true
                rankingEvidence.append(
                    ClipMatchEvidence(
                        groupBest: [],
                        matchedTermCounts: [],
                        phraseMatched: false
                    )
                )
            }
        }

        // 4) Rank / explicit sort / limit, then group.
        guard !Task.isCancelled else { return cancelled }
        let rankingStart = SearchClock.now()
        switch plan.sort {
        case .newest:
            clips.sort(by: {
                if $0.lastCopiedAt != $1.lastCopiedAt {
                    return $0.lastCopiedAt > $1.lastCopiedAt
                }
                return $0.dbID > $1.dbID
            })
        case .oldest:
            clips.sort(by: {
                if $0.lastCopiedAt != $1.lastCopiedAt {
                    return $0.lastCopiedAt < $1.lastCopiedAt
                }
                return $0.dbID < $1.dbID
            })
        case .relevance:
            if isKeywordless {
                // Exactly what `SearchRanker` produces for a plan with no
                // positive group: every score is zero, so the order is recency
                // and then `db_id`. Written out here rather than routed through
                // the ranker so the whole library never has to be scored.
                clips.sort(by: {
                    if $0.lastCopiedAt != $1.lastCopiedAt {
                        return $0.lastCopiedAt > $1.lastCopiedAt
                    }
                    return $0.dbID > $1.dbID
                })
            } else if missingEvidence {
                clips = SearchRanker.rank(
                    candidates: clips.map {
                        rankCandidate(for: $0, store: store)
                    },
                    groups: plan.keywordGroups,
                    now: now
                )
            } else {
                clips = SearchRanker.rank(
                    clips: clips,
                    evidence: rankingEvidence,
                    now: now
                )
            }
        }
        if let limit = plan.limit, limit > 0 {
            clips = Array(clips.prefix(limit))
        }
        let rankingMS = SearchClock.milliseconds(from: rankingStart)

        guard !Task.isCancelled else { return cancelled }
        let sections = ClipGrouper.group(
            clips: clips,
            calendar: calendar,
            now: now
        )
        let totalMS = SearchClock.milliseconds(from: start)

        let metrics = SearchMetrics(
            parseMS: SearchClock.milliseconds(from: start, to: parseEnd),
            ftsMS: ftsMS,
            validationMS: validationMS,
            rankingMS: rankingMS,
            totalMS: totalMS,
            candidateCount: candidateIDs?.count ?? 0,
            resultCount: clips.count,
            textTier: textTier
        )
        let resultItems = clips.enumerated().map {
            SearchResult(clip: $0.element, rank: $0.offset)
        }
        return SearchResponse(
            query: query,
            plan: plan,
            clips: clips,
            results: resultItems,
            sections: sections,
            metrics: metrics
        )
    }

    /// Ranking candidate for one clip, reusing the memory index fields when
    /// they exist. Only the defensive ranking fallback needs this; the normal
    /// path ranks from match evidence and never reads a body.
    private func rankCandidate(
        for clip: Clip,
        store: any SearchDataSource
    ) -> RankCandidate {
        if let fields = store.memoryIndex.normalizedFields(dbID: clip.dbID) {
            return RankCandidate(clip: clip, fields: fields)
        }
        return RankCandidate(
            clip: clip,
            fields: NormalizedSearchFields(
                body: QueryNormalizer.normalize(clip.text),
                note: QueryNormalizer.normalize(clip.note)
            )
        )
    }

    /// Shared gate for both fast paths. `nil` means "use the oracle".
    private func fastPathDatabase(
        criteria: SearchCriteria,
        store: any SearchDataSource
    ) -> DatabaseManager? {
        guard textMatchMode != .oracleOnly else { return nil }
        guard criteria.hasPositiveKeywords else { return nil }
        guard criteria.allTermsAreByteSubstringSafe else { return nil }
        return store.database ?? liveDatabase
    }

    /// Which canonically ambiguous rows still need the exact Swift predicate.
    ///
    /// For those rows the SQL byte predicate is a superset of the Swift one,
    /// so a row SQL did not return cannot match — except for the exclusion
    /// clause, which is a *negative* test and therefore not a superset. With
    /// exclusions present every ambiguous row is re-checked exactly as before;
    /// without them only the bytes that looked like a hit are inspected, which
    /// is what keeps a query that matches nothing out of the Swift scanner.
    private func ambiguousCandidates(
        criteria: SearchCriteria,
        sqlIDs: [Int64],
        index: MemorySearchIndex
    ) -> Set<Int64> {
        guard index.hasAmbiguousRows else { return [] }
        guard criteria.excludedKeywords.isEmpty else {
            return index.effectiveAmbiguousIDs
        }
        return Set(
            sqlIDs.filter { index.isCanonicallyAmbiguous(dbID: $0) }
        )
    }

    /// Exact text matches plus their scoring facts, computed in C.
    ///
    /// Returns `nil` whenever equivalence cannot be guaranteed — ambiguous
    /// terms, too many canonically ambiguous rows, no database, the
    /// normalization columns not ready, or facts that contradict the SQL
    /// predicate — and the caller uses the oracle. Rows whose text is
    /// canonically ambiguous are never decided by SQL: they are evaluated here
    /// with the same `MemorySearchIndex` predicate the validator uses.
    private func exactMatches(
        criteria: SearchCriteria,
        store: any SearchDataSource,
        terms: [String],
        termLengths: [Int],
        phrase: String?
    ) async -> [(dbID: Int64, evidence: ClipMatchEvidence)]? {
        guard let database = fastPathDatabase(
            criteria: criteria,
            store: store
        ) else { return nil }
        let index = store.memoryIndex

        let rows: [TermMatchRow]?
        do {
            rows = try await database.searchMatches(
                criteria: criteria,
                terms: terms,
                phrase: phrase
            )
        } catch {
            if Task.isCancelled { return nil }
            NSLog(
                "Clipa SQL text recall failed: \(error.localizedDescription)"
            )
            return nil
        }
        guard let rows else { return nil }

        var result: [(dbID: Int64, evidence: ClipMatchEvidence)] = []
        result.reserveCapacity(rows.count)
        var sqlIDs: [Int64] = []
        sqlIDs.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() {
            if offset & 255 == 0, Task.isCancelled { return nil }
            // Rows this snapshot does not know are not SQL's to answer.
            guard index.normalizedFields(dbID: row.dbID) != nil else {
                continue
            }
            sqlIDs.append(row.dbID)
            // Ambiguous text is decided by the Swift predicate below.
            guard !index.isCanonicallyAmbiguous(dbID: row.dbID) else {
                continue
            }
            guard let evidence = MatchEvidenceBuilder.evidence(
                facts: row.facts,
                groups: criteria.groups,
                termLengths: termLengths,
                phraseMatched: row.phraseMatched
            ) else {
                // The predicate said "match" but the facts disagree: never drop
                // the row, hand the whole query back to the oracle.
                return nil
            }
            result.append((row.dbID, evidence))
        }
        let ambiguous = ambiguousCandidates(
            criteria: criteria,
            sqlIDs: sqlIDs,
            index: index
        )
        // Per-query budget: only the ambiguous rows this query actually has to
        // re-check in Swift count. Past it the query goes to the oracle, which
        // is the same answer at a predictable cost.
        guard ambiguous.count <= Self.ambiguousRowBudget else { return nil }
        if !ambiguous.isEmpty {
            result.append(
                contentsOf: index.evidenceMatches(
                    candidateIDs: ambiguous,
                    groups: criteria.groups,
                    excludedKeywords: criteria.excludedKeywords,
                    termLengths: termLengths,
                    phrase: phrase
                )
            )
        }
        return result
    }

    /// Ids only, for plans that sort explicitly and never rank.
    private func exactIDs(
        criteria: SearchCriteria,
        store: any SearchDataSource
    ) async -> [Int64]? {
        guard let database = fastPathDatabase(
            criteria: criteria,
            store: store
        ) else { return nil }
        let index = store.memoryIndex

        let sqlIDs: [Int64]?
        do {
            sqlIDs = try await database.searchCandidateIDs(criteria: criteria)
        } catch {
            if Task.isCancelled { return nil }
            NSLog(
                "Clipa SQL text recall failed: \(error.localizedDescription)"
            )
            return nil
        }
        guard let sqlIDs else { return nil }

        let known = sqlIDs.filter { index.normalizedFields(dbID: $0) != nil }
        var result = known.filter {
            !index.isCanonicallyAmbiguous(dbID: $0)
        }
        let ambiguous = ambiguousCandidates(
            criteria: criteria,
            sqlIDs: known,
            index: index
        )
        guard ambiguous.count <= Self.ambiguousRowBudget else { return nil }
        if !ambiguous.isEmpty {
            result.append(
                contentsOf: index.matchingIDs(
                    candidateIDs: ambiguous,
                    groups: criteria.groups,
                    excludedKeywords: criteria.excludedKeywords
                )
            )
        }
        return result
    }
}

enum SearchClock {
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func milliseconds(from start: UInt64) -> Double {
        milliseconds(from: start, to: now())
    }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        let elapsed = end >= start ? end - start : 0
        return Double(elapsed) / 1_000_000
    }
}
