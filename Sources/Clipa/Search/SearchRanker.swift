import Foundation

struct RankedClip {
    let dbID: Int64
    let score: Int
}

/// A clip paired with its already-normalized fields from `MemorySearchIndex`.
struct RankCandidate {
    let clip: Clip
    let fields: NormalizedSearchFields
}

// MARK: - Match evidence

/// What a matcher learned about one (clip, term) pair while looking for the
/// term. Both matchers produce it — the in-memory scan and SQLite's
/// `instr()`/`length()` — so the ranker never has to walk the body again.
struct TermMatchFacts: Equatable, Sendable {
    /// 1-based character position of the first body occurrence; 0 = absent.
    var bodyPosition: Int = 0
    /// Character length of the body, used for the exact-match test.
    var bodyLength: Int = 0
    /// True when the first body occurrence starts a line.
    var bodyAtLineStart: Bool = false
    var noteMatched: Bool = false

    /// Scans a normalized body/note once and records where the term was found.
    /// `bodyLength` 由调用方传入缓存值（见 `NormalizedSearchFields`）时免掉
    /// 每次 `body.count` 的全串走查。
    static func scan(
        body: String,
        note: String,
        term: String,
        bodyLength: Int? = nil
    ) -> TermMatchFacts {
        var facts = TermMatchFacts()
        facts.bodyLength = bodyLength ?? body.count
        if !body.isEmpty, let found = body.range(of: term) {
            let position = body.distance(
                from: body.startIndex,
                to: found.lowerBound
            ) + 1
            facts.bodyPosition = position
            facts.bodyAtLineStart =
                position == 1
                || body[body.index(before: found.lowerBound)] == "\n"
        } else if !note.isEmpty {
            facts.noteMatched = note.range(of: term) != nil
        }
        return facts
    }

    /// The single scoring rule, driven by facts instead of by re-reading text.
    /// Mirrors the reference `SearchRanker.termScore(body:note:term:)`.
    static func score(facts: TermMatchFacts, termLength: Int) -> Int {
        if facts.bodyPosition > 0 {
            if facts.bodyPosition == 1 {
                return facts.bodyLength == termLength ? 1000 : 800
            }
            return facts.bodyAtLineStart ? 650 : 500
        }
        return facts.noteMatched ? 400 : 0
    }
}

/// Per-clip scoring input for one search, produced by whichever matcher ran.
struct ClipMatchEvidence: Equatable, Sendable {
    /// Best term score per positive group, in plan order.
    let groupBest: [Int]
    /// How many terms of each group matched (drives the OR coverage bonus).
    let matchedTermCounts: [Int]
    /// The ordered single-term phrase appears in the body (phrase bonus).
    let phraseMatched: Bool

    /// Group aggregation, in the same order and with the same constants as the
    /// reference ranker.
    var baseScore: Int {
        var base = 0
        for index in groupBest.indices {
            let best = groupBest[index]
            guard best > 0 else {
                base += 300
                continue
            }
            base += best
            base += min(matchedTermCounts[index] - 1, 2) * 20
        }
        if phraseMatched { base += 400 }
        return base
    }
}

/// One SQL fast-path row: the clip id plus the facts each positive term
/// produced. Kept as a typealias because Swift's parser rejects a tuple type
/// containing an array type inside array sugar.
typealias TermMatchRow = (
    dbID: Int64,
    facts: [TermMatchFacts],
    phraseMatched: Bool
)

/// Turns per-term facts into per-clip evidence.
enum MatchEvidenceBuilder {
    /// `facts` are flattened in plan order (group by group, term by term) and
    /// `termLengths` is parallel to them. Returns `nil` when any positive group
    /// has no hit — the caller must then treat the clip as not matching, or, on
    /// the SQL path, fall back rather than silently drop it.
    static func evidence(
        facts: [TermMatchFacts],
        groups: [[String]],
        termLengths: [Int],
        phraseMatched: Bool
    ) -> ClipMatchEvidence? {
        var groupBest: [Int] = []
        var counts: [Int] = []
        groupBest.reserveCapacity(groups.count)
        counts.reserveCapacity(groups.count)
        var cursor = 0
        for group in groups {
            var best = 0
            var matched = 0
            for _ in group {
                guard cursor < facts.count, cursor < termLengths.count else {
                    return nil
                }
                let score = TermMatchFacts.score(
                    facts: facts[cursor],
                    termLength: termLengths[cursor]
                )
                cursor += 1
                if score > 0 {
                    matched += 1
                    best = max(best, score)
                }
            }
            guard best > 0 else { return nil }
            groupBest.append(best)
            counts.append(matched)
        }
        return ClipMatchEvidence(
            groupBest: groupBest,
            matchedTermCounts: counts,
            phraseMatched: phraseMatched
        )
    }
}

enum MatchQuality {
    case exact       // 整个 body == query
    case prefix      // body 以 query 开头
    case linePrefix  // 某一行以 query 开头
    case bodySubstring
    case noteSubstring
    case multiSubstring
}

/// Lightweight deterministic ranking: match quality dominates and a small
/// recency bonus breaks ties.
enum SearchRanker {
    static func rank(
        clips: [Clip],
        query: SearchQuery,
        now: Date = Date()
    ) -> [Clip] {
        clips
            .map { clip in
                (clip, score(clip: clip, query: query, now: now))
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.lastCopiedAt != rhs.0.lastCopiedAt {
                    return lhs.0.lastCopiedAt > rhs.0.lastCopiedAt
                }
                return lhs.0.dbID > rhs.0.dbID
            }
            .map(\.0)
    }

    /// Relevance ranking driven by the same planned terms used for recall.
    /// Each AND group contributes its best matching term; OR groups may add a
    /// small coverage bonus; an exact multi-term phrase keeps a bonus so a
    /// contiguous "docker network" body still beats scattered matches.
    static func rank(
        clips: [Clip],
        query: SearchQuery,
        groups: [[String]],
        now: Date = Date()
    ) -> [Clip] {
        let candidates = clips.map { clip in
            RankCandidate(
                clip: clip,
                fields: NormalizedSearchFields(
                    body: QueryNormalizer.normalize(clip.text),
                    note: QueryNormalizer.normalize(clip.note)
                )
            )
        }
        return rank(candidates: candidates, groups: groups, now: now)
    }

    /// Production ranking path: fields come from the memory index, so no
    /// clip body/note is normalized again during search.
    static func rank(
        candidates: [RankCandidate],
        groups: [[String]],
        now: Date = Date()
    ) -> [Clip] {
        sortRanked(
            candidates.map { candidate in
                (
                    candidate.clip,
                    score(
                        candidate: candidate,
                        groups: groups,
                        now: now
                    )
                )
            }
        )
    }

    /// Production ranking path for the evidence-based matcher: the matcher
    /// already recorded where each term matched, so no clip body is read here.
    ///
    /// `clips` and `evidence` are parallel arrays. Sorting happens on a compact
    /// key (score, timestamp, index) so the sort never retains or releases a
    /// `Clip`; the clips are touched again only once, to build the result.
    static func rank(
        clips: [Clip],
        evidence: [ClipMatchEvidence],
        now: Date = Date()
    ) -> [Clip] {
        guard !clips.isEmpty else { return [] }
        guard evidence.count == clips.count else {
            // Defensive: the caller builds both in one pass, so this cannot
            // happen today. Never drop clips because of it, but do not hand
            // back the input order either — that is the dictionary traversal
            // order, and it would make the result list non-deterministic.
            // Fall back to the same total order the ranker uses when every
            // score ties.
            return clips.sorted { lhs, rhs in
                if lhs.lastCopiedAt != rhs.lastCopiedAt {
                    return lhs.lastCopiedAt > rhs.lastCopiedAt
                }
                return lhs.dbID > rhs.dbID
            }
        }

        struct RankKey {
            let score: Int
            let lastCopiedAt: Double
            let index: Int
        }

        var keys: [RankKey] = []
        keys.reserveCapacity(clips.count)
        for index in clips.indices {
            let item = evidence[index]
            // A metadata-only query (no positive groups) scores zero for
            // everyone, exactly like the reference ranker, so the recency
            // bonus must not be added there.
            let score = item.groupBest.isEmpty
                ? 0
                : item.baseScore
                    + recencyBonus(
                        now: now,
                        lastCopiedAt: clips[index].lastCopiedAt
                    )
            keys.append(
                RankKey(
                    score: score,
                    lastCopiedAt: clips[index].lastCopiedAt
                        .timeIntervalSince1970,
                    index: index
                )
            )
        }
        keys.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lastCopiedAt != rhs.lastCopiedAt {
                return lhs.lastCopiedAt > rhs.lastCopiedAt
            }
            return clips[lhs.index].dbID > clips[rhs.index].dbID
        }
        var ranked: [Clip] = []
        ranked.reserveCapacity(keys.count)
        for key in keys {
            ranked.append(clips[key.index])
        }
        return ranked
    }

    /// Shared tie-breaking order: score, then recency, then `db_id`. A total
    /// order, so results are deterministic and pageable.
    private static func sortRanked(_ ranked: [(Clip, Int)]) -> [Clip] {
        ranked
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.lastCopiedAt != rhs.0.lastCopiedAt {
                    return lhs.0.lastCopiedAt > rhs.0.lastCopiedAt
                }
                return lhs.0.dbID > rhs.0.dbID
            }
            .map(\.0)
    }

    /// The ordered multi-term phrase used for the phrase bonus: only a plan
    /// whose groups are all single terms can form one.
    static func orderedPhrase(groups: [[String]]) -> String? {
        guard !groups.isEmpty,
              groups.allSatisfy({ $0.count == 1 }) else { return nil }
        return groups
            .compactMap { $0.first }
            .map { QueryNormalizer.normalize($0) }
            .joined(separator: " ")
    }

    /// Recency bonus buckets, shared by every ranking path.
    static func recencyBonus(now: Date, lastCopiedAt: Date) -> Int {
        let age = max(0, now.timeIntervalSince(lastCopiedAt))
        let days = age / 86_400
        switch days {
        case ..<1: return 40
        case ..<2: return 25
        case ..<7: return 15
        case ..<30: return 5
        default: return 0
        }
    }

    static func score(clip: Clip, query: SearchQuery, now: Date = Date()) -> Int {
        guard !query.terms.isEmpty else { return 0 }
        let q = query.normalized
        let body = QueryNormalizer.normalize(clip.text)
        let note = QueryNormalizer.normalize(clip.note)

        let base: Int
        if !body.isEmpty, body == q {
            base = 1000
        } else if !body.isEmpty, body.hasPrefix(q) {
            base = 800
        } else if !body.isEmpty,
                  body.split(separator: "\n").contains(where: { $0.hasPrefix(q) }) {
            base = 650
        } else if !body.isEmpty, body.contains(q) {
            base = 500
        } else if !note.isEmpty, note.contains(q) {
            base = 400
        } else {
            base = 300
        }

        var score = base
        let age = max(0, now.timeIntervalSince(clip.lastCopiedAt))
        let days = age / 86_400
        switch days {
        case ..<1: score += 40
        case ..<2: score += 25
        case ..<7: score += 15
        case ..<30: score += 5
        default: break
        }
        return score
    }

    private static func score(
        candidate: RankCandidate,
        groups: [[String]],
        now: Date
    ) -> Int {
        guard !groups.isEmpty else { return 0 }
        let body = candidate.fields.body
        let note = candidate.fields.note
        let clip = candidate.clip

        var base = 0
        for group in groups {
            var best = 0
            var matchedTerms = 0
            for term in group {
                let value = termScore(
                    body: body,
                    note: note,
                    term: QueryNormalizer.normalize(term)
                )
                if value > 0 {
                    matchedTerms += 1
                    best = max(best, value)
                }
            }
            guard best > 0 else {
                base += 300
                continue
            }
            base += best
            // OR groups: every extra term that also matches is weak evidence,
            // but never enough to outweigh one group's best body match.
            base += min(matchedTerms - 1, 2) * 20
        }

        // Exact ordered multi-term phrase bonus for AND-style plans such as
        // "docker network". Only single-term AND groups can form this phrase.
        if let phrase = orderedPhrase(groups: groups), body.contains(phrase) {
            base += 400
        }

        base += recencyBonus(now: now, lastCopiedAt: clip.lastCopiedAt)
        return base
    }

    private static func termScore(
        body: String,
        note: String,
        term: String
    ) -> Int {
        guard !term.isEmpty else { return 0 }
        if !body.isEmpty {
            if body == term { return 1000 }
            if body.hasPrefix(term) { return 800 }
            // One positioned search instead of "does a line start with it?"
            // followed by "does it appear at all?": both questions read the
            // whole body, and ranking runs over every candidate on each
            // keystroke. Where the match sits decides the score.
            if let found = body.range(of: term) {
                let atLineStart =
                    found.lowerBound == body.startIndex
                    || body[body.index(before: found.lowerBound)] == "\n"
                return atLineStart ? 650 : 500
            }
        }
        if !note.isEmpty, note.contains(term) { return 400 }
        return 0
    }
}
