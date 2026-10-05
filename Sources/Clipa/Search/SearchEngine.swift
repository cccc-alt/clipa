import Foundation

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

enum SearchTextMatchMode: Sendable {

    case automatic

    case oracleOnly

    case sqlOnly
}

final class LocalSearchEngine: SearchEngine, @unchecked Sendable {
    let database: DatabaseManager?
    private let store: (any SearchDataSource)?
    private let filter: SearchFilter
    private let textMatchMode: SearchTextMatchMode

    private static let ambiguousRowBudget = 2000

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

    func search(
        query: String,
        plan: SearchQueryPlan?
    ) async throws -> [SearchResult] {
        try Task.checkCancellation()
        guard let store else { throw SearchEngineError.missingStore }
        return await searchAsync(
            query: query,
            filter: filter,
            store: store,
            plan: plan
        ).results
    }

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

        let hasPositive = !plan.keywordGroups.isEmpty

        let isKeywordless = !hasPositive
            && plan.excludedKeywords.isEmpty
            && plan.sort == .relevance
        let criteria = SearchCriteria(plan: plan, filter: filter)

        let positiveTerms = plan.keywordGroups.flatMap { $0 }
        let termLengths = positiveTerms.map {
            QueryNormalizer.normalizeQuery($0).count
        }
        let orderedPhrase = SearchRanker.orderedPhrase(
            groups: plan.keywordGroups
        )
        let needsEvidence = plan.sort == .relevance && !isKeywordless

        var candidateIDs: Set<Int64>?
        var ftsMS = 0.0
        let ftsStart = SearchClock.now()
        if hasPositive,
           let ftsQuery = FTSQueryBuilder.buildGroupQuery(
               groups: plan.keywordGroups
           ) {
            var recall: FTSRepository.FTSCandidateRecall?
            if let database = liveDatabase {
                do {
                    recall = try await database.ftsCandidateIDs(query: ftsQuery)
                } catch {
                    NSLog("Clipa FTS recall failed: \(error.localizedDescription)")
                }
            }

            if let recall {
                candidateIDs =
                    (!recall.truncated && !recall.ids.isEmpty)
                    ? recall.ids
                    : nil
            }
            ftsMS = SearchClock.milliseconds(from: ftsStart)
        } else if hasPositive {

            candidateIDs = nil
        }

        let validationStart = SearchClock.now()
        var matchingIDs: [Int64] = []
        var evidenceByID: [Int64: ClipMatchEvidence] = [:]
        let textTier: SearchTextTier
        var fastMatches: [(dbID: Int64, evidence: ClipMatchEvidence)]?
        var fastIDs: [Int64]?
        if isKeywordless {

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

                    fastIDs = await exactIDs(criteria: criteria, store: store)
                }
            }
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

                matchingIDs = store.memoryIndex.matchingIDs(
                    candidateIDs: candidateIDs,
                    groups: plan.keywordGroups,
                    excludedKeywords: plan.excludedKeywords
                )
                textTier = candidateIDs == nil ? .memoryScan : .ftsCandidates
            }
        }
        let validationMS = SearchClock.milliseconds(from: validationStart)

        var clips: [Clip] = []
        clips.reserveCapacity(matchingIDs.count)
        var rankingEvidence: [ClipMatchEvidence] = []
        if needsEvidence { rankingEvidence.reserveCapacity(matchingIDs.count) }
        var missingEvidence = false
        for dbID in matchingIDs {
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

    private func fastPathDatabase(
        criteria: SearchCriteria,
        store: any SearchDataSource
    ) -> DatabaseManager? {
        guard textMatchMode != .oracleOnly else { return nil }
        guard criteria.hasPositiveKeywords else { return nil }
        guard criteria.allTermsAreByteSubstringSafe else { return nil }
        return liveDatabase
    }

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
        for row in rows {

            guard index.normalizedFields(dbID: row.dbID) != nil else {
                continue
            }
            sqlIDs.append(row.dbID)

            guard !index.isCanonicallyAmbiguous(dbID: row.dbID) else {
                continue
            }
            guard let evidence = MatchEvidenceBuilder.evidence(
                facts: row.facts,
                groups: criteria.groups,
                termLengths: termLengths,
                phraseMatched: row.phraseMatched
            ) else {

                return nil
            }
            result.append((row.dbID, evidence))
        }
        let ambiguous = ambiguousCandidates(
            criteria: criteria,
            sqlIDs: sqlIDs,
            index: index
        )

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
