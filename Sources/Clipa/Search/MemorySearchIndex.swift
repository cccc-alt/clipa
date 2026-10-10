import Foundation

/// Pre-normalized body/note used by the ranker so it never has to run
/// normalization a second time over the same clip.
struct NormalizedSearchFields: Equatable {
    let body: String
    let note: String
    /// 正文长度（图形簇计数）。P3 优化（2026-10-03）：构造时算一次——
    /// 打分路径对每个 (行， 词) 都要它，`body.count` 是全串 O(len) 走查，
    /// m 个词就是 m 次重复劳动。
    let bodyLength: Int
    /// True when this text can only be matched reliably by Swift's grapheme
    /// comparison (combining marks, joiners, …). The SQL fast path never
    /// decides these rows; see `SearchTextSafety`.
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

/// Pre-normalized memory index used for:
/// - instant short-token / no-FTS queries,
/// - exact semantic validation of FTS candidates,
/// - every final AND/OR/exclusion check.
///
/// Text stored here is normalized body + note. Source app, type names and
/// labels intentionally never enter this index.
final class MemorySearchIndex {
    /// One change queued while a snapshot still shared `entries`.
    private enum PendingChange {
        case set(NormalizedSearchFields)
        case removed
    }

    /// Counts live snapshots so the live index knows whether its storage is
    /// shared. Snapshots are released on whatever thread finishes the search,
    /// so the count is lock-guarded; the dictionaries themselves are only ever
    /// mutated from the live index (main actor).
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

    /// Subset of `entries` whose normalized text may behave differently under
    /// the SQL byte-substring predicate. Those rows are always decided by the
    /// Swift predicate, so the fast path cannot lose or invent a match.
    private(set) var ambiguousIDs: Set<Int64> = []

    /// Changes that arrived while a snapshot held `entries`.
    ///
    /// Mutating a dictionary that a snapshot still shares forces a full
    /// copy-on-write of all 100k entries (~5ms for the index alone at that
    /// size). Instead the change is queued here, where it is visible to the
    /// next snapshot (a snapshot copies this small queue) and merged back into
    /// `entries` the next time no snapshot is alive — at which point the
    /// dictionaries are uniquely referenced and mutate in place.
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

    /// Rows per worker below which the parallel path is not worth its
    /// overhead. 2026-10-04：从 4096 降到 1024——8 核机器上 4096 意味着
    /// ~33k 行才开始用满核，而 1 万条量级的库（10k/4096 = 2 个 worker）
    /// 只吃到 2 核；1024 让 8k 行以上的库就用满全部核。
    private static let rowsPerWorker = 1_024

    /// Rebuilds the whole index.
    ///
    /// Normalizing and inspecting one clip touches nothing but that clip, so
    /// the row range is split across cores and merged once. Measured on a
    /// 103k-row library: 5.6s serially (8-core machine), ~1.5s with 8
    /// workers. The merge is serial and preserves exactly the same entries —
    /// the index is keyed by dbID, so no result depends on the order in which
    /// the chunks are produced.
    func rebuild(from clips: [Clip]) {
        let workers = Self.workerCount(for: clips.count)
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            // 大库才有观察价值；小库的毫秒级重建不值得日志噪音。
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

    /// Applies a change, queueing it while a snapshot shares the storage.
    private func change(dbID: Int64, _ change: PendingChange) {
        guard !storageIsShared else {
            pending[dbID] = change
            return
        }
        mergePending()
        apply(change, dbID: dbID)
    }

    /// Folds the queue into `entries`. Safe to touch the dictionaries without
    /// copying only because no snapshot holds them at this point.
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

    /// Copy-on-write copy for off-main search.
    ///
    /// The dictionaries are shared (O(1)) and the small pending queue is
    /// carried along so the snapshot sees every change the live index has
    /// accepted, including the ones it has not merged yet. The returned
    /// instance must only be read — `SearchSnapshot` enforces that by never
    /// calling a mutating method on it.
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

    /// Ambiguity queries for callers that must not allocate the whole set.
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

    /// The full ambiguity set, including queued changes. Only allocates when a
    /// snapshot is mid-flight, which is exactly when the queue is non-empty.
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

    /// Single semantic definition of "this clip matches these keywords".
    /// Every group must be hit by at least one of its own terms; no excluded
    /// term may be present. Used by the validator and by the fast path's
    /// ambiguous-row pass, so both agree by construction.
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

    /// Every known row id, cheapest possible walk.
    ///
    /// Used by the keyword-less query, where no row can fail to match and none
    /// can outrank another: building match evidence for the whole library to
    /// then sort by a constant is pure waste, and the empty search box is the
    /// query the panel runs on every capture.
    func allIDs() -> [Int64] {
        var result: [Int64] = []
        result.reserveCapacity(count)
        forEachEntry { dbID, _ in result.append(dbID) }
        return result
    }

    /// Matching *and* scoring in one pass.
    ///
    /// The reference path scans a candidate's body once to decide "does it
    /// contain the term" and then a second (and third) time inside the ranker
    /// to score it. Here each term is scanned once, the facts it yields are
    /// turned into scores by the shared rule, and the ranker consumes only the
    /// aggregate — no clip body is read again.
    ///
    /// Groups are still short-circuited: as soon as one group has no hit the
    /// clip cannot match and the remaining terms are never scanned.
    func evidenceMatches(
        candidateIDs: Set<Int64>? = nil,
        groups: [[String]],
        excludedKeywords: [String],
        termLengths: [Int],
        phrase: String?
    ) -> [(dbID: Int64, evidence: ClipMatchEvidence)] {
        var result: [(dbID: Int64, evidence: ClipMatchEvidence)] = []
        result.reserveCapacity(candidateIDs?.count ?? count)

        forEachSearchEntry(candidateIDs: candidateIDs) { dbID, fields in
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

    /// Walks every entry as the caller should see it: base rows with queued
    /// changes applied, then queued rows the base does not have yet.
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

    /// Sparse recall is O(candidates), including queued snapshot changes.
    /// A full scan polls cancellation in batches so superseded keystrokes stop
    /// consuming CPU without adding a task lookup to every term comparison.
    private func forEachSearchEntry(
        candidateIDs: Set<Int64>?,
        _ body: (Int64, NormalizedSearchFields) -> Void
    ) {
        var visited = 0
        func shouldStop() -> Bool {
            defer { visited += 1 }
            return visited & 255 == 0 && Task<Never, Never>.isCancelled
        }
        if let candidateIDs {
            for dbID in candidateIDs {
                if shouldStop() { return }
                if let fields = normalizedFields(dbID: dbID) { body(dbID, fields) }
            }
            return
        }
        if pending.isEmpty {
            for (dbID, fields) in entries {
                if shouldStop() { return }
                body(dbID, fields)
            }
            return
        }
        for (dbID, fields) in entries where pending[dbID] == nil {
            if shouldStop() { return }
            body(dbID, fields)
        }
        for (dbID, change) in pending {
            if shouldStop() { return }
            if case .set(let fields) = change { body(dbID, fields) }
        }
    }

    /// Single semantic entry point for final recall validation. Handles
    /// AND/OR positive groups, exclusion keywords and optional FTS recall.
    func matchingIDs(
        candidateIDs: Set<Int64>? = nil,
        groups: [[String]],
        excludedKeywords: [String]
    ) -> [Int64] {
        var result: [Int64] = []
        result.reserveCapacity(candidateIDs?.count ?? count)

        forEachSearchEntry(candidateIDs: candidateIDs) { dbID, _ in
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

    /// Pure per-clip work, so `rebuild` can run it on several cores at once.
    private static func fields(for clip: Clip) -> NormalizedSearchFields {
        // 私密条目的正文**不进索引**（M3），与库里那两位（`norm_text`/`norm_note`、
        // `clips_fts`）用同一条规则：索引里留一份可被检索的副本等于绕过加密。
        //
        // 更关键的是"两层必须一致"：搜索是 FTS 召回 + 内存验证，而 `SearchParity`
        // 就是拿这两层对拍的。只让数据库那层空着，就会出现"搜『密码』命中、
        // 搜『密码本』不命中"这种取决于走哪条路径的结果——那比不加密更难排查。
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
