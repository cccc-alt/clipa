import Foundation

struct NormalizedSearchFields: Equatable {
    let body: String
    let note: String

    let bodyLength: Int

    let isCanonicallyAmbiguous: Bool

    init(
        body: String,
        note: String,
        isCanonicallyAmbiguous: Bool = false
    ) {
        self.body = body
        self.note = note
        self.bodyLength = body.count
        self.isCanonicallyAmbiguous = isCanonicallyAmbiguous
    }

    func contains(_ term: String) -> Bool {
        body.contains(term) || note.contains(term)
    }
}

final class MemorySearchIndex {

    private enum PendingChange {
        case set(NormalizedSearchFields)
        case removed
    }

    private final class Sharing {
        private let lock = NSLock()
        private var count = 0

        func acquire() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func release() {
            lock.lock()
            count -= 1
            lock.unlock()
        }

        var liveSnapshots: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private var entries: [Int64: NormalizedSearchFields] = [:]

    private(set) var ambiguousIDs: Set<Int64> = []

    private var pending: [Int64: PendingChange] = [:]
    private var sharing: Sharing?
    private var isSnapshot = false

    deinit {
        guard isSnapshot else { return }
        sharing?.release()
    }

    private var storageIsShared: Bool {
        (sharing?.liveSnapshots ?? 0) > 0
    }

    var count: Int {
        guard !pending.isEmpty else { return entries.count }
        var total = entries.count
        for (dbID, change) in pending {
            switch change {
            case .set:
                if entries[dbID] == nil { total += 1 }
            case .removed:
                if entries[dbID] != nil { total -= 1 }
            }
        }
        return total
    }

    private static let rowsPerWorker = 1_024

    /// Parallel rebuild: normalize rows across cores, merge once.
func rebuild(from clips: [Clip]) {
        let workers = Self.workerCount(for: clips.count)
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {

            if clips.count >= 1_024 {
                let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                NSLog(
                    "Clipa 内存索引重建：\(clips.count) 行 / \(workers) worker / \(String(format: "%.0f", ms))ms"
                )
            }
        }
        guard workers > 1 else {
            rebuildSerially(from: clips)
            return
        }
        let chunkSize = (clips.count + workers - 1) / workers
        var chunkEntries = [[Int64: NormalizedSearchFields]](
            repeating: [:],
            count: workers
        )
        var chunkAmbiguous = [Set<Int64>](repeating: [], count: workers)
        chunkEntries.withUnsafeMutableBufferPointer { entriesBuffer in
            chunkAmbiguous.withUnsafeMutableBufferPointer { ambiguousBuffer in
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let start = worker * chunkSize
                    let end = min(start + chunkSize, clips.count)
                    guard start < end else { return }
                    var local: [Int64: NormalizedSearchFields] = [:]
                    local.reserveCapacity(end - start)
                    var localAmbiguous: Set<Int64> = []
                    for index in start..<end {
                        let clip = clips[index]
                        let field = Self.fields(for: clip)
                        local[clip.dbID] = field
                        if field.isCanonicallyAmbiguous {
                            localAmbiguous.insert(clip.dbID)
                        }
                    }
                    entriesBuffer[worker] = local
                    ambiguousBuffer[worker] = localAmbiguous
                }
            }
        }
        var rebuilt: [Int64: NormalizedSearchFields] = [:]
        rebuilt.reserveCapacity(clips.count)
        var ambiguous: Set<Int64> = []
        ambiguous.reserveCapacity(clips.count / 32)
        for worker in 0..<workers {
            rebuilt.merge(chunkEntries[worker], uniquingKeysWith: { first, _ in first })
            ambiguous.formUnion(chunkAmbiguous[worker])
        }
        entries = rebuilt
        ambiguousIDs = ambiguous
        pending.removeAll(keepingCapacity: true)
    }

    private func rebuildSerially(from clips: [Clip]) {
        var rebuilt: [Int64: NormalizedSearchFields] = [:]
        rebuilt.reserveCapacity(clips.count)
        var ambiguous: Set<Int64> = []
        ambiguous.reserveCapacity(clips.count / 32)
        for clip in clips {
            let field = Self.fields(for: clip)
            rebuilt[clip.dbID] = field
            if field.isCanonicallyAmbiguous { ambiguous.insert(clip.dbID) }
        }
        entries = rebuilt
        ambiguousIDs = ambiguous
        pending.removeAll(keepingCapacity: true)
    }

    private static func workerCount(for rowCount: Int) -> Int {
        let affordable = rowCount / rowsPerWorker
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(1, min(cores, affordable))
    }

    func insert(clip: Clip) {
        change(dbID: clip.dbID, .set(Self.fields(for: clip)))
    }

    func update(clip: Clip) {
        insert(clip: clip)
    }

    func remove(dbID: Int64) {
        change(dbID: dbID, .removed)
    }

    private func change(dbID: Int64, _ change: PendingChange) {
        guard !storageIsShared else {
            pending[dbID] = change
            return
        }
        mergePending()
        apply(change, dbID: dbID)
    }

    private func mergePending() {
        guard !pending.isEmpty else { return }
        let queued = pending
        pending.removeAll(keepingCapacity: true)
        for (dbID, change) in queued {
            apply(change, dbID: dbID)
        }
    }

    private func apply(_ change: PendingChange, dbID: Int64) {
        switch change {
        case .set(let fields):
            entries[dbID] = fields
            if fields.isCanonicallyAmbiguous {
                ambiguousIDs.insert(dbID)
            } else {
                ambiguousIDs.remove(dbID)
            }
        case .removed:
            entries[dbID] = nil
            ambiguousIDs.remove(dbID)
        }
    }

    func normalizedFields(dbID: Int64) -> NormalizedSearchFields? {
        if let queued = pending[dbID] {
            switch queued {
            case .set(let fields): return fields
            case .removed: return nil
            }
        }
        return entries[dbID]
    }

    func snapshot() -> MemorySearchIndex {
        let copy = MemorySearchIndex()
        copy.entries = entries
        copy.ambiguousIDs = ambiguousIDs
        copy.pending = pending
        copy.isSnapshot = true
        let shared = sharing ?? Sharing()
        sharing = shared
        copy.sharing = shared
        shared.acquire()
        return copy
    }

    func containsAllTerms(dbID: Int64, terms: [String]) -> Bool {
        guard let fields = normalizedFields(dbID: dbID) else { return false }
        return terms.allSatisfy { fields.contains($0) }
    }

    func isCanonicallyAmbiguous(dbID: Int64) -> Bool {
        if let queued = pending[dbID] {
            switch queued {
            case .set(let fields): return fields.isCanonicallyAmbiguous
            case .removed: return false
            }
        }
        return ambiguousIDs.contains(dbID)
    }

    var ambiguousRowCount: Int {
        guard !pending.isEmpty else { return ambiguousIDs.count }
        var count = ambiguousIDs.count
        for (dbID, change) in pending {
            let was = ambiguousIDs.contains(dbID)
            let now: Bool
            switch change {
            case .set(let fields): now = fields.isCanonicallyAmbiguous
            case .removed: now = false
            }
            if now != was { count += now ? 1 : -1 }
        }
        return count
    }

    var hasAmbiguousRows: Bool { ambiguousRowCount > 0 }

    var effectiveAmbiguousIDs: Set<Int64> {
        guard !pending.isEmpty else { return ambiguousIDs }
        var result = ambiguousIDs
        for (dbID, change) in pending {
            switch change {
            case .set(let fields):
                if fields.isCanonicallyAmbiguous {
                    result.insert(dbID)
                } else {
                    result.remove(dbID)
                }
            case .removed:
                result.remove(dbID)
            }
        }
        return result
    }

    func matches(
        dbID: Int64,
        groups: [[String]],
        excludedKeywords: [String]
    ) -> Bool {
        guard let fields = normalizedFields(dbID: dbID) else { return false }
        for group in groups
        where !group.contains(where: { fields.contains($0) }) {
            return false
        }
        return !excludedKeywords.contains { fields.contains($0) }
    }

    func allIDs() -> [Int64] {
        var result: [Int64] = []
        result.reserveCapacity(count)
        forEachEntry { dbID, _ in result.append(dbID) }
        return result
    }

    func evidenceMatches(
        candidateIDs: Set<Int64>? = nil,
        groups: [[String]],
        excludedKeywords: [String],
        termLengths: [Int],
        phrase: String?
    ) -> [(dbID: Int64, evidence: ClipMatchEvidence)] {
        var result: [(dbID: Int64, evidence: ClipMatchEvidence)] = []
        result.reserveCapacity(candidateIDs?.count ?? count)

        forEachEntry { dbID, fields in
            if let candidateIDs, !candidateIDs.contains(dbID) { return }
            if excludedKeywords.contains(where: { fields.contains($0) }) {
                return
            }

            var groupBest: [Int] = []
            var matchedTermCounts: [Int] = []
            groupBest.reserveCapacity(groups.count)
            matchedTermCounts.reserveCapacity(groups.count)
            var cursor = 0
            var allGroupsHit = true
            for group in groups {
                var best = 0
                var matched = 0
                for term in group {
                    guard cursor < termLengths.count else {
                        allGroupsHit = false
                        break
                    }
                    let facts = TermMatchFacts.scan(
                        body: fields.body,
                        note: fields.note,
                        term: term,
                        bodyLength: fields.bodyLength
                    )
                    let score = TermMatchFacts.score(
                        facts: facts,
                        termLength: termLengths[cursor]
                    )
                    cursor += 1
                    if score > 0 {
                        matched += 1
                        best = max(best, score)
                    }
                }
                if best == 0 {
                    allGroupsHit = false
                    break
                }
                groupBest.append(best)
                matchedTermCounts.append(matched)
            }
            guard allGroupsHit else { return }

            result.append(
                (
                    dbID,
                    ClipMatchEvidence(
                        groupBest: groupBest,
                        matchedTermCounts: matchedTermCounts,
                        phraseMatched: phrase.map {
                            fields.body.contains($0)
                        } ?? false
                    )
                )
            )
        }
        return result
    }

    private func forEachEntry(
        _ body: (Int64, NormalizedSearchFields) -> Void
    ) {
        if pending.isEmpty {
            for (dbID, fields) in entries { body(dbID, fields) }
            return
        }
        for (dbID, fields) in entries where pending[dbID] == nil {
            body(dbID, fields)
        }
        for (dbID, change) in pending {
            if case .set(let fields) = change { body(dbID, fields) }
        }
    }

    func matchingIDs(
        candidateIDs: Set<Int64>? = nil,
        groups: [[String]],
        excludedKeywords: [String]
    ) -> [Int64] {
        var result: [Int64] = []
        result.reserveCapacity(candidateIDs?.count ?? count)

        forEachEntry { dbID, _ in
            if let candidateIDs, !candidateIDs.contains(dbID) {
                return
            }
            if matches(
                dbID: dbID,
                groups: groups,
                excludedKeywords: excludedKeywords
            ) {
                result.append(dbID)
            }
        }
        return result
    }

    private static func fields(for clip: Clip) -> NormalizedSearchFields {

        let body = clip.isPrivate ? "" : QueryNormalizer.normalize(clip.text)
        let note = clip.isPrivate ? "" : QueryNormalizer.normalize(clip.note)
        return NormalizedSearchFields(
            body: body,
            note: note,
            isCanonicallyAmbiguous: !SearchTextSafety.isByteSubstringSafe(
                text: body,
                note: note
            )
        )
    }
}
