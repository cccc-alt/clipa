import Foundation

struct RankedClip {
    let dbID: Int64
    let score: Int
}

struct RankCandidate {
    let clip: Clip
    let fields: NormalizedSearchFields
}

struct TermMatchFacts: Equatable, Sendable {

    var bodyPosition: Int = 0

    var bodyLength: Int = 0

    var bodyAtLineStart: Bool = false
    var noteMatched: Bool = false

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

struct ClipMatchEvidence: Equatable, Sendable {

    let groupBest: [Int]

    let matchedTermCounts: [Int]

    let phraseMatched: Bool

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

typealias TermMatchRow = (
    dbID: Int64,
    facts: [TermMatchFacts],
    phraseMatched: Bool
)

enum MatchEvidenceBuilder {

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
    case exact
    case prefix
    case linePrefix
    case bodySubstring
    case noteSubstring
    case multiSubstring
}

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

    static func rank(
        clips: [Clip],
        evidence: [ClipMatchEvidence],
        now: Date = Date()
    ) -> [Clip] {
        guard !clips.isEmpty else { return [] }
        guard evidence.count == clips.count else {

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

    static func orderedPhrase(groups: [[String]]) -> String? {
        guard !groups.isEmpty,
              groups.allSatisfy({ $0.count == 1 }) else { return nil }
        return groups
            .compactMap { $0.first }
            .map { QueryNormalizer.normalize($0) }
            .joined(separator: " ")
    }

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

            base += min(matchedTerms - 1, 2) * 20
        }

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
