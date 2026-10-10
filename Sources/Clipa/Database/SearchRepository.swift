import Foundation
import CSQLCipher

/// SQL-side text matching for the accuracy-gated fast path.
///
/// This repository never decides ordering, ranking or metadata semantics: it
/// answers one question — which rows contain these phrases — by running the
/// predicate over the normalized text copy (`clips.norm_text` /
/// `clips.norm_note`) inside SQLite instead of scanning every clip's text in
/// Swift. `MemorySearchIndex` stays the source of truth for everything else.
///
/// Every value is bound; the only string concatenation is the shape of the
/// predicate itself, mirroring `FTSQueryBuilder`.
enum SearchRepository {
    static let normalizationMarkerKey = "search.normalized_text_version"

    /// Fingerprint of the normalizer's *behaviour*, taken from the same probe
    /// the FTS index uses.
    ///
    /// A hand-written version number could be bumped without recomputing the
    /// existing rows: the marker would then claim the columns were normalized
    /// by the new rule while they still held the old one, and the SQL fast path
    /// — which is trusted as equivalent — would compare new-normalized terms
    /// against old-normalized text, silently losing or inventing matches.
    /// Deriving the marker from the probe makes a rule change impossible to
    /// miss, and keeps this side in step with the FTS rebuild that the same
    /// probe already triggers.
    static func normalizationFingerprint() -> String {
        FTSRepository.normalizerProbe().joined(separator: "\u{1F}")
    }

    // MARK: - Normalized text columns

    static func pendingNormalizationCount(
        connection: DatabaseConnection
    ) throws -> Int {
        try connection.scalarInt(
            "SELECT COUNT(*) FROM clips WHERE norm_text IS NULL"
        )
    }

    /// O(1) marker check plus a full-column count, so a store that lost rows
    /// (or gained rows from an older build) can never enable the fast path and
    /// silently drop matches.
    static func isNormalizationComplete(
        connection: DatabaseConnection
    ) -> Bool {
        guard StoreMeta.value(
            forKey: normalizationMarkerKey,
            connection: connection
        ) == normalizationFingerprint() else { return false }
        guard let pending = try? pendingNormalizationCount(
            connection: connection
        ) else { return false }
        return pending == 0
    }

    /// Fills `norm_text` / `norm_note` for one batch. Returns how many rows
    /// were written; `0` means the backfill is complete.
    @discardableResult
    static func backfillNormalizedText(
        connection: DatabaseConnection,
        batchSize: Int = 500
    ) throws -> Int {
        struct PendingRow {
            let dbID: Int64
            let text: String
            let note: String
        }
        // `is_private = 0`：私密行的正文是密文（M3），归一化它既没意义，也会把
        // 一份可索引的副本留在库里。正常情况下私密行走不到这里（它们写的是空串
        // 而不是 NULL）；这条条件是防线——将来某个路径把私密行的 norm_text 清回
        // NULL 时，明文不会被悄悄回填。
        let rows: [PendingRow] = try connection.prepare("""
            SELECT db_id, text, note FROM clips
            WHERE norm_text IS NULL
              AND is_private = 0
            ORDER BY db_id ASC
            LIMIT ?
            """) { statement in
            sqlite3_bind_int64(statement, 1, Int64(batchSize))
            var rows: [PendingRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    PendingRow(
                        dbID: sqlite3_column_int64(statement, 0),
                        text: connection.columnText(statement, 1) ?? "",
                        note: connection.columnText(statement, 2) ?? ""
                    )
                )
            }
            return rows
        }
        guard !rows.isEmpty else { return 0 }

        try connection.beginImmediate()
        do {
            try connection.prepare("""
                UPDATE clips SET norm_text = ?, norm_note = ?
                WHERE db_id = ?
                """) { statement in
                for row in rows {
                    connection.bindText(
                        statement,
                        1,
                        QueryNormalizer.normalize(row.text)
                    )
                    connection.bindText(
                        statement,
                        2,
                        QueryNormalizer.normalize(row.note)
                    )
                    sqlite3_bind_int64(statement, 3, row.dbID)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.sql(connection.lastErrorMessage)
                    }
                    sqlite3_reset(statement)
                }
            }
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        return rows.count
    }

    /// Clears the normalized columns in `db_id` batches so the backfill
    /// recomputes them under the current rule.
    ///
    /// Batched on purpose: this runs once after a rule change, and on a large
    /// library a single transaction would hold the whole table's worth of
    /// writes in the WAL. A crash mid-way simply repeats from the start.
    ///
    /// **私密行被排除**（M3）：它们落盘是密文，`norm_text`/`norm_note` 是空的
    /// 占位而不是 `NULL`。这里若把它们清成 `NULL`，紧接着的回填就会把**明文**
    /// 写回索引列——加密刚做完就被自己拆掉，而且换一条归一化规则就会再发生一次。
    @discardableResult
    static func clearNormalizedText(
        connection: DatabaseConnection,
        batchSize: Int = 2_000
    ) throws -> Int {
        let maxID: Int64 = try connection.prepare(
            "SELECT COALESCE(MAX(db_id), 0) FROM clips"
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(statement, 0)
        }
        guard maxID > 0 else { return 0 }
        let step = Int64(max(batchSize, 1))
        var cursor: Int64 = 0
        var batches = 0
        while cursor < maxID {
            let upper = cursor + step
            try connection.beginImmediate()
            do {
                try connection.prepare("""
                    UPDATE clips SET norm_text = NULL, norm_note = NULL
                    WHERE db_id > ? AND db_id <= ?
                      AND is_private = 0
                      AND (norm_text IS NOT NULL OR norm_note IS NOT NULL)
                    """) { statement in
                    sqlite3_bind_int64(statement, 1, cursor)
                    sqlite3_bind_int64(statement, 2, upper)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.sql(connection.lastErrorMessage)
                    }
                }
                try connection.commit()
            } catch {
                connection.rollback()
                throw error
            }
            cursor = upper
            batches += 1
        }
        return batches
    }

    /// Brings the normalized columns up to the current rule, then records the
    /// fingerprint. Idempotent: a crash mid-way simply re-runs what is still
    /// NULL next launch.
    static func completeNormalizationIfNeeded(
        connection: DatabaseConnection
    ) throws {
        let fingerprint = normalizationFingerprint()
        let stored = StoreMeta.value(
            forKey: normalizationMarkerKey,
            connection: connection
        )
        if stored != fingerprint {
            // Either the rule changed or the columns were never stamped. The
            // marker is deliberately not written before the text is recomputed
            // — stamping it would make the fast path trust stale columns.
            try clearNormalizedText(connection: connection)
        }
        while try pendingNormalizationCount(connection: connection) > 0 {
            let processed = try backfillNormalizedText(connection: connection)
            if processed == 0 { break }
        }
        guard try pendingNormalizationCount(connection: connection) == 0 else {
            return
        }
        try StoreMeta.set(
            fingerprint,
            forKey: normalizationMarkerKey,
            connection: connection
        )
    }

    /// `clips` row count and how many of them carry normalized text. Used by
    /// the integrity gate and by the self-test.
    static func integritySnapshot(
        connection: DatabaseConnection
    ) throws -> (clips: Int, normalized: Int) {
        let clips = try connection.rowCount(in: "clips")
        let normalized = try connection.scalarInt("""
            SELECT COUNT(*) FROM clips
            WHERE norm_text IS NOT NULL AND norm_note IS NOT NULL
            """)
        return (clips, normalized)
    }

    // MARK: - Fast-path text matching

    /// Ids only, for plans whose order does not need scoring
    /// (`newest` / `oldest` never reach the ranker).
    ///
    /// Skipping the fact projection is worth roughly 40% of the statement for
    /// broad short queries: `instr` for the filter stays, but the position,
    /// body length, line-start and note columns are not computed at all.
    static func exactCandidateIDs(
        criteria: SearchCriteria,
        connection: DatabaseConnection
    ) throws -> [Int64] {
        guard !criteria.groups.isEmpty else { return [] }
        guard !criteria.groups.contains(where: \.isEmpty) else { return [] }

        var sql = """
            SELECT db_id FROM clips
            WHERE norm_text IS NOT NULL AND norm_note IS NOT NULL
            """
        var bindings: [String] = []
        for group in criteria.groups {
            let clauses = group.map { _ in
                "(instr(norm_text, ?) > 0 OR instr(norm_note, ?) > 0)"
            }
            sql += " AND (" + clauses.joined(separator: " OR ") + ")"
            for term in group {
                bindings.append(term)
                bindings.append(term)
            }
        }
        for term in criteria.excludedKeywords {
            sql += " AND instr(norm_text, ?) = 0 AND instr(norm_note, ?) = 0"
            bindings.append(term)
            bindings.append(term)
        }

        return try connection.prepare(sql) { statement in
            for (offset, value) in bindings.enumerated() {
                connection.bindText(statement, Int32(offset + 1), value)
            }
            var ids: [Int64] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw DatabaseError.sql(connection.lastErrorMessage)
                }
                ids.append(sqlite3_column_int64(statement, 0))
            }
            return ids
        }
    }

    /// Exact text matches together with the facts the ranker needs.
    ///
    /// The predicate mirrors `MemorySearchIndex.matchingIDs` term for term:
    /// every group must contain one of its terms, no excluded term may be
    /// present. Metadata is deliberately *not* applied here — the oracle keeps
    /// filtering it, so a mistake in this predicate cannot hide a row.
    ///
    /// `instr()` is already evaluated while filtering, so the same expressions
    /// are also projected: where the term matched, how long the body is,
    /// whether the first hit starts a line, and whether the note matched. The
    /// scoring rules themselves stay in Swift — SQL only reports facts, which
    /// is what keeps ranking to a single implementation.
    static func exactMatches(
        criteria: SearchCriteria,
        terms: [String],
        phrase: String?,
        connection: DatabaseConnection
    ) throws -> [TermMatchRow] {
        guard !criteria.groups.isEmpty else { return [] }
        // An empty OR group can never be satisfied, exactly like the oracle's
        // `group.contains { ... }` returning false.
        guard !criteria.groups.contains(where: \.isEmpty) else { return [] }

        var termParams: [Int] = []
        var nextParam = 1
        for _ in terms {
            termParams.append(nextParam)
            nextParam += 1
        }
        var exclusionParams: [Int] = []
        for _ in criteria.excludedKeywords {
            exclusionParams.append(nextParam)
            nextParam += 1
        }
        let phraseParam = phrase == nil ? nil : nextParam

        var selectColumns: [String] = ["db_id"]
        for param in termParams {
            selectColumns.append("instr(norm_text, ?\(param))")
            selectColumns.append("length(norm_text)")
            selectColumns.append(
                "CASE WHEN instr(norm_text, ?\(param)) > 1"
                    + " AND substr(norm_text, instr(norm_text, ?\(param)) - 1, 1)"
                    + " = char(10) THEN 1 ELSE 0 END"
            )
            selectColumns.append("(instr(norm_note, ?\(param)) > 0)")
        }
        if let phraseParam {
            selectColumns.append("(instr(norm_text, ?\(phraseParam)) > 0)")
        } else {
            selectColumns.append("0")
        }

        var whereClauses: [String] = [
            "norm_text IS NOT NULL",
            "norm_note IS NOT NULL"
        ]
        var cursor = 0
        for group in criteria.groups {
            var alternatives: [String] = []
            for _ in group {
                let param = termParams[cursor]
                cursor += 1
                alternatives.append(
                    "(instr(norm_text, ?\(param)) > 0"
                        + " OR instr(norm_note, ?\(param)) > 0)"
                )
            }
            whereClauses.append(
                "(" + alternatives.joined(separator: " OR ") + ")"
            )
        }
        for param in exclusionParams {
            whereClauses.append("instr(norm_text, ?\(param)) = 0")
            whereClauses.append("instr(norm_note, ?\(param)) = 0")
        }

        let sql = """
            SELECT \(selectColumns.joined(separator: ", "))
            FROM clips
            WHERE \(whereClauses.joined(separator: " AND "))
            """

        return try connection.prepare(sql) { statement in
            for (offset, term) in terms.enumerated() {
                connection.bindText(
                    statement,
                    Int32(termParams[offset]),
                    term
                )
            }
            for (offset, term) in criteria.excludedKeywords.enumerated() {
                connection.bindText(
                    statement,
                    Int32(exclusionParams[offset]),
                    term
                )
            }
            if let phraseParam, let phrase {
                connection.bindText(statement, Int32(phraseParam), phrase)
            }

            var rows: [TermMatchRow] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw DatabaseError.sql(connection.lastErrorMessage)
                }
                let dbID = sqlite3_column_int64(statement, 0)
                var facts: [TermMatchFacts] = []
                facts.reserveCapacity(terms.count)
                var column: Int32 = 1
                for _ in terms {
                    var factsForTerm = TermMatchFacts()
                    factsForTerm.bodyPosition = Int(
                        sqlite3_column_int64(statement, column)
                    )
                    factsForTerm.bodyLength = Int(
                        sqlite3_column_int64(statement, column + 1)
                    )
                    factsForTerm.bodyAtLineStart =
                        sqlite3_column_int64(statement, column + 2) != 0
                    factsForTerm.noteMatched =
                        sqlite3_column_int64(statement, column + 3) != 0
                    facts.append(factsForTerm)
                    column += 4
                }
                let phraseMatched =
                    sqlite3_column_int64(statement, column) != 0
                rows.append((dbID, facts, phraseMatched))
            }
            return rows
        }
    }
}
