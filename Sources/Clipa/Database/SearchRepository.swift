import Foundation
import CSQLCipher

enum SearchRepository {
    static let normalizationMarkerKey = "search.normalized_text_version"

    static func normalizationFingerprint() -> String {
        FTSRepository.normalizerProbe().joined(separator: "\u{1F}")
    }

    static func pendingNormalizationCount(
        connection: DatabaseConnection
    ) throws -> Int {
        try connection.scalarInt(
            "SELECT COUNT(*) FROM clips WHERE norm_text IS NULL"
        )
    }

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

    static func completeNormalizationIfNeeded(
        connection: DatabaseConnection
    ) throws {
        let fingerprint = normalizationFingerprint()
        let stored = StoreMeta.value(
            forKey: normalizationMarkerKey,
            connection: connection
        )
        if stored != fingerprint {

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
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(statement, 0))
            }
            return ids
        }
    }

    static func exactMatches(
        criteria: SearchCriteria,
        terms: [String],
        phrase: String?,
        connection: DatabaseConnection
    ) throws -> [TermMatchRow] {
        guard !criteria.groups.isEmpty else { return [] }

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
            while sqlite3_step(statement) == SQLITE_ROW {
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
