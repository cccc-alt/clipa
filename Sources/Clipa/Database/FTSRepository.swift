import Foundation
import CSQLCipher

/// All reads/writes for `clips_fts`. The virtual table has no UUID or
/// `source_app` columns; `rowid` is the same integer as `clips.db_id`.
enum FTSRepository {
    /// Bump whenever the indexed columns, the tokenizer or the meaning of the
    /// stored text changes. A mismatch forces a rebuild without anyone having
    /// to remember to run one.
    static let schemaVersion = 1

    static let markerKey = "fts.index_marker"
    static let lastStrongCheckKey = "fts.last_strong_check_at"
    static let sessionStateKey = "session.state"
    static let sessionOpenValue = "open"
    static let sessionCleanValue = "clean"

    /// A full content pass is not run on every launch; this is how stale a
    /// "clean" index may get before it is verified row by row again.
    static let strongCheckInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Sample size for the per-launch content spot check.
    static let sampleCheckRows = 200

    /// `indexed == false` 是私密条目的路径（M3）：索引列**必须留空**。
    ///
    /// 索引里存的是正文的归一化副本 —— 也就是**第二份明文**。私密内容加密了
    /// `clips.text` 却在这里留一份可读副本，等于没加密；而且索引里放密文也没用
    /// （trigram 匹配不到），只会让 `verifyStrong` 与 `clips.norm_text` 永久不一致。
    /// 行还留着（`rowid = db_id` 的对齐不变量不变），只是没有内容可匹配。
    static func insert(
        rowid: Int64,
        text: String,
        note: String,
        indexed: Bool,
        connection: DatabaseConnection
    ) throws {
        let sql = "INSERT INTO clips_fts (rowid, text, note) VALUES (?, ?, ?)"
        try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, rowid)
            connection.bindText(
                statement,
                2,
                indexed ? QueryNormalizer.normalize(text) : ""
            )
            // Same normalizer as `clips.norm_note`: `verifyStrong` compares the
            // two copies row by row, so they must be produced by the same rule.
            connection.bindText(
                statement,
                3,
                indexed ? QueryNormalizer.normalize(note) : ""
            )
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func updateNote(
        rowid: Int64,
        note: String,
        indexed: Bool,
        connection: DatabaseConnection
    ) throws {
        let sql = "UPDATE clips_fts SET note = ? WHERE rowid = ?"
        try connection.prepare(sql) { statement in
            connection.bindText(
                statement,
                1,
                indexed ? QueryNormalizer.normalize(note) : ""
            )
            sqlite3_bind_int64(statement, 2, rowid)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    /// 整行索引内容的改写，供"私密 ↔ 普通"切换用（M3）。
    ///
    /// 切换时必须同时改这一行：变私密要**收回**索引里的正文副本，取消私密要
    /// **放回**。少了这一步，搜索会在切换后悄悄少一条或多一条；而且两个副本对不上
    /// 时 `verifyStrong` 会判定索引不可信，于是每次启动都重建一遍。
    static func setContent(
        rowid: Int64,
        text: String,
        note: String,
        indexed: Bool,
        connection: DatabaseConnection
    ) throws {
        let sql = "UPDATE clips_fts SET text = ?, note = ? WHERE rowid = ?"
        try connection.prepare(sql) { statement in
            connection.bindText(
                statement,
                1,
                indexed ? QueryNormalizer.normalize(text) : ""
            )
            connection.bindText(
                statement,
                2,
                indexed ? QueryNormalizer.normalize(note) : ""
            )
            sqlite3_bind_int64(statement, 3, rowid)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func delete(
        rowid: Int64,
        connection: DatabaseConnection
    ) throws {
        let sql = "DELETE FROM clips_fts WHERE rowid = ?"
        try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, rowid)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func deleteAll(connection: DatabaseConnection) throws {
        try connection.exec("DELETE FROM clips_fts")
    }

    /// Candidate recall only. Final semantics are decided by MemorySearchIndex.
    struct FTSCandidateRecall: Equatable {
        let ids: Set<Int64>
        /// True when recall stopped at the cap. The caller should fall back
        /// to the complete memory index instead of treating the prefix as
        /// an exhaustive candidate set.
        let truncated: Bool
    }

    static func candidateIDs(
        query: String,
        maxCount: Int = 2000,
        connection: DatabaseConnection
    ) throws -> FTSCandidateRecall {
        let sql = "SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?"
        var ids: Set<Int64> = []
        var truncated = false
        try connection.prepare(sql) { statement in
            connection.bindText(statement, 1, query)
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    throw DatabaseError.sql(connection.lastErrorMessage)
                }
                // One row *past* the cap is what proves the recall was cut
                // short. Stopping at `>= maxCount` reported a query that
                // matched exactly `maxCount` rows as truncated, which threw
                // away a complete candidate set and forced the caller into the
                // full in-memory scan for nothing.
                guard ids.count < maxCount else {
                    truncated = true
                    return
                }
                ids.insert(sqlite3_column_int64(statement, 0))
            }
        }
        return FTSCandidateRecall(ids: ids, truncated: truncated)
    }

    /// Rebuilds the index from `clips`. Callers that also want the index
    /// marker updated atomically should use `rebuildAndMark` instead.
    static func rebuild(connection: DatabaseConnection) throws {
        try connection.beginImmediate()
        do {
            try rebuildRows(connection: connection)
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
    }

    /// Rebuilds and stamps the marker in **one** transaction. A crash can
    /// therefore never leave a "fresh marker + stale index" combination.
    static func rebuildAndMark(connection: DatabaseConnection) throws {
        try connection.beginImmediate()
        do {
            try rebuildRows(connection: connection)
            let marker = try makeMarker(connection: connection)
            try writeMarker(marker, connection: connection)
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
    }

    /// Assumes an open transaction.
    ///
    /// Streams row by row. The previous version read the entire corpus into a
    /// Swift array before deleting anything, so one rebuild held every clip's
    /// text in memory *on top of* the index it was writing — inside the write
    /// transaction that blocks captures — which on a 100k-row library is
    /// hundreds of megabytes at the worst possible moment.
    private static func rebuildRows(connection: DatabaseConnection) throws {
        let insertSQL = """
            INSERT INTO clips_fts (rowid, text, note)
            VALUES (?, ?, ?)
            """
        // 私密行一起读出来并**单独处理**（M3）：它们的落盘正文是密文，归一化密文
        // 既没有意义（trigram 匹配不到），又会让索引与 `clips.norm_text` 永久不一致。
        // 重建本来就是"把不变量重新摆正"的地方，所以顺手把它们的 `norm_*` 也清空。
        let selectSQL = """
            SELECT db_id, is_private, text, note,
                   COALESCE(norm_text, ''), COALESCE(norm_note, '')
            FROM clips
            """
        // 收集而不是在扫描 `clips` 的过程中改它：迭代中的表被自己写会跳过行。
        var privateRowsNeedingNormReset: [Int64] = []
        try connection.exec("DELETE FROM clips_fts")
        try connection.prepare(selectSQL) { select in
            try connection.prepare(insertSQL) { insert in
                while sqlite3_step(select) == SQLITE_ROW {
                    let rowID = sqlite3_column_int64(select, 0)
                    let isPrivate = sqlite3_column_int(select, 1) != 0
                    let text = connection.columnString(select, 2)
                    let note = connection.columnString(select, 3)
                    sqlite3_bind_int64(insert, 1, rowID)
                    connection.bindText(
                        insert,
                        2,
                        isPrivate ? "" : QueryNormalizer.normalize(text)
                    )
                    // A rebuild must reproduce the same normalization as the
                    // write paths, or the two copies would disagree.
                    connection.bindText(
                        insert,
                        3,
                        isPrivate ? "" : QueryNormalizer.normalize(note)
                    )
                    guard sqlite3_step(insert) == SQLITE_DONE else {
                        throw DatabaseError.sql(
                            connection.lastErrorMessage
                        )
                    }
                    sqlite3_reset(insert)
                    guard isPrivate else { continue }
                    if !connection.columnString(select, 4).isEmpty
                        || !connection.columnString(select, 5).isEmpty {
                        privateRowsNeedingNormReset.append(rowID)
                    }
                }
            }
        }
        for rowID in privateRowsNeedingNormReset {
            try connection.prepare("""
                UPDATE clips SET norm_text = '', norm_note = ''
                WHERE db_id = ?
                """) { reset in
                sqlite3_bind_int64(reset, 1, rowID)
                guard sqlite3_step(reset) == SQLITE_DONE else {
                    throw DatabaseError.sql(connection.lastErrorMessage)
                }
            }
        }
    }

    static func count(connection: DatabaseConnection) throws -> Int {
        try connection.rowCount(in: "clips_fts")
    }

    // MARK: - Index trust (marker, verification, decision)

    /// What `store_meta` vouches for. Written in the same transaction as the
    /// rebuild it describes.
    struct IndexMarker: Codable, Equatable {
        let schemaVersion: Int
        /// Normalized `sqlite_master.sql` of `clips_fts`.
        let ddlFingerprint: String
        /// Outputs of `QueryNormalizer` for fixed probe inputs. Comparing them
        /// catches a normalization change even if nobody bumped a version.
        let normalizerProbe: [String]
        let rowCount: Int
        let dbIDSum: Int64
        let textBytes: Int64
        let noteBytes: Int64
        let builtAt: Double
        let buildCount: Int
    }

    /// Cheap aggregates that must agree between `clips` and `clips_fts`.
    struct IndexAggregates: Equatable {
        let rowCount: Int
        let idSum: Int64
        let textBytes: Int64
        let noteBytes: Int64

        var description: String {
            "rows=\(rowCount) idSum=\(idSum)"
                + " textBytes=\(textBytes) noteBytes=\(noteBytes)"
        }
    }

    enum RebuildReason: String {
        case tableMissing
        case schemaChanged
        case markerMissing
        case markerUndecodable
        case normalizerChanged
        case aggregatesDiffer
        case sampleMismatch
        case strongCheckFailed
        case migrationTouchedClips
        case normalizationIncomplete
        case requested
    }

    enum IndexDecision: Equatable {
        case trusted(IndexMarker)
        case rebuild(RebuildReason, String)
    }

    /// Inputs whose normalization output pins the normalizer's behaviour.
    /// Deliberately covers the cases the search path cares about: uppercase,
    /// decomposed accents, width folding, CRLF and CJK with spaces.
    static let normalizerProbeInputs = [
        "İstanbul",
        "ＡＢＣ",
        "e\u{0301}",
        "A\r\nB",
        "  K8S  网络  "
    ]

    static func normalizerProbe() -> [String] {
        normalizerProbeInputs.map { QueryNormalizer.normalize($0) }
    }

    /// `sqlite_master.sql` reduced to a stable form: case and whitespace are
    /// not part of the contract, column order and options are.
    static func ddlFingerprint(connection: DatabaseConnection) -> String? {
        guard let sql = connection.ftsColumnList(for: "clips_fts") else {
            return nil
        }
        return sql.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func marker(connection: DatabaseConnection) -> IndexMarker? {
        guard let raw = StoreMeta.value(
            forKey: markerKey,
            connection: connection
        ), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(IndexMarker.self, from: data)
    }

    private static func writeMarker(
        _ marker: IndexMarker,
        connection: DatabaseConnection
    ) throws {
        let data = try JSONEncoder().encode(marker)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DatabaseError.sql("无法序列化 FTS 索引标记")
        }
        try StoreMeta.set(json, forKey: markerKey, connection: connection)
    }

    private static func makeMarker(
        connection: DatabaseConnection
    ) throws -> IndexMarker {
        let aggregates = try clipsAggregates(connection: connection)
        let previous = marker(connection: connection)
        return IndexMarker(
            schemaVersion: schemaVersion,
            ddlFingerprint: ddlFingerprint(connection: connection) ?? "",
            normalizerProbe: normalizerProbe(),
            rowCount: aggregates.rowCount,
            dbIDSum: aggregates.idSum,
            textBytes: aggregates.textBytes,
            noteBytes: aggregates.noteBytes,
            builtAt: Date().timeIntervalSince1970,
            buildCount: (previous?.buildCount ?? 0) + 1
        )
    }

    /// Byte lengths are read from SQLite metadata, so this is a cheap table
    /// scan rather than a text pass.
    static func clipsAggregates(
        connection: DatabaseConnection
    ) throws -> IndexAggregates {
        try aggregates(
            connection: connection,
            sql: """
                SELECT COUNT(*), COALESCE(SUM(db_id), 0),
                       COALESCE(SUM(LENGTH(CAST(norm_text AS BLOB))), 0),
                       COALESCE(SUM(LENGTH(CAST(norm_note AS BLOB))), 0)
                FROM clips
                """
        )
    }

    static func ftsAggregates(
        connection: DatabaseConnection
    ) throws -> IndexAggregates {
        try aggregates(
            connection: connection,
            sql: """
                SELECT COUNT(*), COALESCE(SUM(rowid), 0),
                       COALESCE(SUM(LENGTH(CAST(text AS BLOB))), 0),
                       COALESCE(SUM(LENGTH(CAST(note AS BLOB))), 0)
                FROM clips_fts
                """
        )
    }

    private static func aggregates(
        connection: DatabaseConnection,
        sql: String
    ) throws -> IndexAggregates {
        try connection.prepare(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
            return IndexAggregates(
                rowCount: Int(sqlite3_column_int64(statement, 0)),
                idSum: sqlite3_column_int64(statement, 1),
                textBytes: sqlite3_column_int64(statement, 2),
                noteBytes: sqlite3_column_int64(statement, 3)
            )
        }
    }

    /// Row-by-row comparison of both sides, in rowid order, stopping at the
    /// first difference. This is the "strong" check: it reads the whole corpus
    /// but never rebuilds unless something is actually wrong.
    static func verifyStrong(
        connection: DatabaseConnection
    ) throws -> (ok: Bool, detail: String) {
        let clipsSQL = """
            SELECT db_id, norm_text, norm_note FROM clips ORDER BY db_id
            """
        let ftsSQL = """
            SELECT rowid, text, note FROM clips_fts ORDER BY rowid
            """
        return try connection.prepare(clipsSQL) { clipsStatement in
            try connection.prepare(ftsSQL) { ftsStatement in
                var compared = 0
                while true {
                    let hasClips = sqlite3_step(clipsStatement) == SQLITE_ROW
                    let hasFTS = sqlite3_step(ftsStatement) == SQLITE_ROW
                    if !hasClips && !hasFTS {
                        return (true, "rows=\(compared)")
                    }
                    if hasClips != hasFTS {
                        return (
                            false,
                            "行数不一致：已比对 \(compared) 行，"
                                + (hasClips ? "clips 多一行" : "clips_fts 多一行")
                        )
                    }
                    let clipID = sqlite3_column_int64(clipsStatement, 0)
                    let ftsID = sqlite3_column_int64(ftsStatement, 0)
                    guard clipID == ftsID else {
                        return (
                            false,
                            "rowid 不一致：clips \(clipID) vs clips_fts \(ftsID)"
                        )
                    }
                    let clipText = connection.columnString(clipsStatement, 1)
                    let clipNote = connection.columnString(clipsStatement, 2)
                    let ftsText = connection.columnString(ftsStatement, 1)
                    let ftsNote = connection.columnString(ftsStatement, 2)
                    if clipText != ftsText || clipNote != ftsNote {
                        return (
                            false,
                            "rowid \(clipID) 内容不一致"
                        )
                    }
                    compared += 1
                }
            }
        }
    }

    /// Spot check used on every launch: a few random rows compared by content,
    /// which catches drift the byte-length sums cannot see.
    static func verifySample(
        connection: DatabaseConnection,
        count: Int = sampleCheckRows
    ) throws -> (ok: Bool, detail: String) {
        let total = try connection.rowCount(in: "clips")
        guard total > 0 else { return (true, "empty") }
        let bounds: (min: Int64, max: Int64) = try connection.prepare("""
            SELECT COALESCE(MIN(db_id), 0), COALESCE(MAX(db_id), 0) FROM clips
            """) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
            return (
                sqlite3_column_int64(statement, 0),
                sqlite3_column_int64(statement, 1)
            )
        }
        guard bounds.max >= bounds.min else { return (true, "empty") }

        var checked = 0
        var attempts = 0
        let attemptBudget = max(count, 1) * 8
        while checked < count && attempts < attemptBudget {
            attempts += 1
            let pick = Int64.random(in: bounds.min...bounds.max)
            switch try compareRow(dbID: pick, connection: connection) {
            case .absent:
                continue
            case .equal:
                checked += 1
            case .different(let detail):
                return (false, detail)
            }
        }
        guard checked > 0 else { return (true, "no rows sampled") }
        return (true, "sampled=\(checked)")
    }

    private enum RowComparison {
        case absent
        case equal
        case different(String)
    }

    private static func compareRow(
        dbID: Int64,
        connection: DatabaseConnection
    ) throws -> RowComparison {
        // Both sides are read separately on purpose. The old version used an
        // inner join, so a row that exists on one side only came back as "no
        // row" and the sampler skipped it — the one inconsistency the spot
        // check could never see, even though a missing candidate is exactly
        // what makes a search silently lose a result.
        let clip: (text: String, note: String)? = try connection.prepare("""
            SELECT norm_text, norm_note FROM clips WHERE db_id = ?
            """) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (
                connection.columnString(statement, 0),
                connection.columnString(statement, 1)
            )
        }
        let fts: (text: String, note: String)? = try connection.prepare("""
            SELECT text, note FROM clips_fts WHERE rowid = ?
            """) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (
                connection.columnString(statement, 0),
                connection.columnString(statement, 1)
            )
        }
        switch (clip, fts) {
        case (nil, nil):
            return .absent
        case (let expected?, nil):
            return .different(
                "rowid \(dbID) 在 FTS 索引中缺失（正文 \(expected.text.count) 字符）"
            )
        case (nil, _?):
            return .different("rowid \(dbID) 只存在于 FTS 索引")
        case (let expected?, let actual?):
            guard expected.text == actual.text, expected.note == actual.note
            else {
                return .different("rowid \(dbID) 内容不一致")
            }
            return .equal
        }
    }

    /// Decides whether the index can be trusted as-is.
    ///
    /// The order is cheapest first: schema, marker, normalizer probe, then the
    /// aggregate comparison, then a spot check, and finally a full row-by-row
    /// pass when the last one is stale or the previous session did not end
    /// cleanly.
    static func decide(
        connection: DatabaseConnection,
        now: Date = Date()
    ) throws -> IndexDecision {
        guard connection.hasTable("clips_fts") else {
            return .rebuild(.tableMissing, "")
        }
        guard let currentDDL = ddlFingerprint(connection: connection),
              currentDDL.contains("trigram") else {
            return .rebuild(.schemaChanged, "clips_fts DDL 与期望不符")
        }
        guard let storedMarker = marker(connection: connection) else {
            if let raw = StoreMeta.value(
                forKey: markerKey,
                connection: connection
            ) {
                return .rebuild(
                    .markerUndecodable,
                    "标记无法解析：\(raw.prefix(40))"
                )
            }
            return .rebuild(.markerMissing, "store_meta 无索引标记")
        }
        guard storedMarker.schemaVersion == schemaVersion else {
            return .rebuild(
                .schemaChanged,
                "标记版本 \(storedMarker.schemaVersion)"
            )
        }
        guard storedMarker.ddlFingerprint == currentDDL else {
            return .rebuild(.schemaChanged, "标记与当前 DDL 不一致")
        }
        guard storedMarker.normalizerProbe == normalizerProbe() else {
            return .rebuild(.normalizerChanged, "归一化器输出发生变化")
        }
        if try SearchRepository.pendingNormalizationCount(
            connection: connection
        ) > 0 {
            return .rebuild(.normalizationIncomplete, "归一化文本未回填完成")
        }
        let clips = try clipsAggregates(connection: connection)
        let fts = try ftsAggregates(connection: connection)
        guard clips == fts else {
            return .rebuild(
                .aggregatesDiffer,
                "clips[\(clips.description)] fts[\(fts.description)]"
            )
        }
        let sample = try verifySample(connection: connection)
        guard sample.ok else {
            return .rebuild(.sampleMismatch, sample.detail)
        }
        if try shouldRunStrongCheck(connection: connection, now: now) {
            let strong = try verifyStrong(connection: connection)
            try StoreMeta.set(
                String(now.timeIntervalSince1970),
                forKey: lastStrongCheckKey,
                connection: connection
            )
            guard strong.ok else {
                return .rebuild(.strongCheckFailed, strong.detail)
            }
        }
        return .trusted(storedMarker)
    }

    /// A full pass runs when the last one is stale, or when the previous
    /// session did not shut down cleanly (`session.state` left at "open").
    static func shouldRunStrongCheck(
        connection: DatabaseConnection,
        now: Date
    ) throws -> Bool {
        if StoreMeta.value(
            forKey: sessionStateKey,
            connection: connection
        ) == sessionOpenValue {
            return true
        }
        guard let raw = StoreMeta.value(
            forKey: lastStrongCheckKey,
            connection: connection
        ), let last = Double(raw) else {
            return true
        }
        return now.timeIntervalSince1970 - last > strongCheckInterval
    }

    static func markSessionOpen(connection: DatabaseConnection) throws {
        try StoreMeta.set(
            sessionOpenValue,
            forKey: sessionStateKey,
            connection: connection
        )
    }

    static func markSessionClean(connection: DatabaseConnection) throws {
        try StoreMeta.set(
            sessionCleanValue,
            forKey: sessionStateKey,
            connection: connection
        )
    }
}
