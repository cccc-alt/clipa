import Foundation
import CSQLCipher

enum FTSRepository {

    static let schemaVersion = 1

    static let markerKey = "fts.index_marker"
    static let lastStrongCheckKey = "fts.last_strong_check_at"
    static let sessionStateKey = "session.state"
    static let sessionOpenValue = "open"
    static let sessionCleanValue = "clean"

    static let strongCheckInterval: TimeInterval = 7 * 24 * 60 * 60

    static let sampleCheckRows = 200

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

    struct FTSCandidateRecall: Equatable {
        let ids: Set<Int64>

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
            while sqlite3_step(statement) == SQLITE_ROW {

                guard ids.count < maxCount else {
                    truncated = true
                    return
                }
                ids.insert(sqlite3_column_int64(statement, 0))
            }
        }
        return FTSCandidateRecall(ids: ids, truncated: truncated)
    }

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

    private static func rebuildRows(connection: DatabaseConnection) throws {
        let insertSQL = """
            INSERT INTO clips_fts (rowid, text, note)
            VALUES (?, ?, ?)
            """

        let selectSQL = """
            SELECT db_id, is_private, text, note,
                   COALESCE(norm_text, ''), COALESCE(norm_note, '')
            FROM clips
            """

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

    struct IndexMarker: Codable, Equatable {
        let schemaVersion: Int

        let ddlFingerprint: String

        let normalizerProbe: [String]
        let rowCount: Int
        let dbIDSum: Int64
        let textBytes: Int64
        let noteBytes: Int64
        let builtAt: Double
        let buildCount: Int
    }

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
