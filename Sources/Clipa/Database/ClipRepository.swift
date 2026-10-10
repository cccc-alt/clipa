import Foundation
import CSQLCipher

/// Minimal row projection for history clearing. It avoids loading full Clip
/// objects (text, notes, URLs, tags, image bytes) just to delete rows.
struct ClipClearRow: Equatable {
    let dbID: Int64
}

/// One row whose image still lives in the v6 `images/` directory.
struct LegacyImageRow: Equatable {
    let dbID: Int64
    let fileName: String?
    /// 私密行的 legacy 图片在导入时**落盘即密封**（2026-10-04），
    /// 不再依赖启动补偿兜底。
    let isPrivate: Bool
}

/// Row-level CRUD for the `clips` table only. FTS writes are intentionally a
/// separate repository so the two tables cannot be confused.
enum ClipRepository {
    static let selectSQL = """
        SELECT \(DatabaseSchema.clipColumns)
        FROM clips
        """

    // MARK: - Read

    static func loadRecent(
        connection: DatabaseConnection,
        limit: Int?
    ) throws -> [Clip] {
        let requestedLimit = limit
        let sql: String
        if requestedLimit != nil {
            sql = selectSQL + " ORDER BY last_copied_at DESC, db_id DESC LIMIT ?"
        } else {
            sql = selectSQL + " ORDER BY last_copied_at DESC, db_id DESC"
        }
        return try connection.prepare(sql) { statement in
            if let limit = requestedLimit {
                sqlite3_bind_int64(statement, 1, Int64(limit))
            }
            var clips: [Clip] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let clip = clip(from: statement) {
                    clips.append(clip)
                }
            }
            return clips
        }
    }

    static func clip(dbID: Int64, connection: DatabaseConnection) throws -> Clip? {
        let sql = selectSQL + " WHERE db_id = ?"
        return try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return clip(from: statement)
        }
    }

    /// The duplicate row for `hash`, restricted to the same `kind`.
    ///
    /// The kind is part of the lookup, matching
    /// `DatabaseSchema.uniqueContentHashIndex`: hashes are computed per content
    /// family, and a text copy and a file copy of the same path collide on the
    /// digest alone. Without the kind here the text copy would be treated as a
    /// duplicate of the file row and never become its own entry.
    static func findByHash(
        hash: String,
        kind: ClipKind,
        connection: DatabaseConnection
    ) throws -> Clip? {
        let sql = selectSQL
            + " WHERE content_hash = ? AND kind = ? LIMIT 1"
        return try connection.prepare(sql) { statement in
            connection.bindText(statement, 1, hash)
            sqlite3_bind_int(statement, 2, Int32(kind.databaseValue))
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return clip(from: statement)
        }
    }

    // MARK: - Write

    /// Returns only the identity + image references needed after a clear.
    static func clearRows(
        connection: DatabaseConnection
    ) throws -> [ClipClearRow] {
        return try connection.prepare("SELECT db_id FROM clips") { statement in
            var rows: [ClipClearRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    ClipClearRow(dbID: sqlite3_column_int64(statement, 0))
                )
            }
            return rows
        }
    }

    // MARK: - v6 image import

    static func pendingLegacyImages(
        connection: DatabaseConnection,
        limit: Int
    ) throws -> [LegacyImageRow] {
        let sql = """
            SELECT db_id, image_file, is_private FROM clips
            WHERE image_file IS NOT NULL AND image_file != ''
            ORDER BY db_id ASC
            LIMIT ?
            """
        return try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, Int64(limit))
            var rows: [LegacyImageRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    LegacyImageRow(
                        dbID: sqlite3_column_int64(statement, 0),
                        fileName: DatabaseConnection.sharedColumnText(
                            statement,
                            1
                        ),
                        isPrivate: sqlite3_column_int(statement, 2) != 0
                    )
                )
            }
            return rows
        }
    }

    static func legacyImageCount(
        connection: DatabaseConnection
    ) throws -> Int {
        let sql = """
            SELECT COUNT(*) FROM clips
            WHERE image_file IS NOT NULL AND image_file != ''
            """
        return try connection.prepare(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Copies legacy bytes into the row and clears `image_file` so the import
    /// never processes the row twice.
    static func storeLegacyImage(
        dbID: Int64,
        data: Data,
        format: String,
        connection: DatabaseConnection
    ) throws {
        try ClipImageRepository.store(
            dbID: dbID,
            data: data,
            connection: connection
        )
        let sql = """
            UPDATE clips
            SET image_blob = NULL, image_format = ?, image_file = ''
            WHERE db_id = ?
            """
        try connection.prepare(sql) { statement in
            connection.bindText(statement, 1, format)
            sqlite3_bind_int64(statement, 2, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    /// Marks a legacy row as handled even though its file is gone. The clip
    /// keeps its image kind and reports missing data instead of retrying.
    static func clearLegacyImageFile(
        dbID: Int64,
        connection: DatabaseConnection
    ) throws {
        let sql = "UPDATE clips SET image_file = '' WHERE db_id = ?"
        try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func insert(
        _ draft: NewClip,
        connection: DatabaseConnection
    ) throws -> Int64 {
        let sql = """
            INSERT INTO clips (
                id, kind, text, note, image_file, file_urls, source_app,
                created_at, last_copied_at, updated_at,
                is_pinned, is_private, is_hidden, content_hash,
                smart_tag, classification_version, contains_sensitive,
                image_blob, image_format, source_bundle, norm_text, norm_note
            )
            VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, ?, 0, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        let classification: SmartClassification
        if let precomputed = draft.smartTag {
            classification = SmartClassification(
                kind: SmartClassifier.kind(
                    for: precomputed,
                    fallbackKind: draft.kind
                ),
                smartTag: precomputed
            )
        } else {
            classification = SmartClassifier.inferredClassification(
                text: draft.text,
                kind: draft.kind
            )
        }
        try connection.prepare(sql) { statement in
            let now = clipTimestamp(Date())
            // 私密条目：正文以密文落盘，且**不进索引**（见下方 norm_* 绑定）。
            let privateBody = draft.isPrivate
            connection.bindText(statement, 1, draft.id.uuidString)
            sqlite3_bind_int(
                statement,
                2,
                Int32(classification.kind.databaseValue)
            )
            // 私密条目的正文以密文落盘（M3）。密封失败**要让插入失败**：
            // 退回写明文等于造出一个"以为私密、其实明文"的行，比报错危险得多。
            connection.bindText(
                statement,
                3,
                privateBody
                    ? try StoreCrypto.sealForStorage(draft.text)
                    : draft.text
            )
            connection.bindText(
                statement,
                4,
                privateBody
                    ? try StoreCrypto.sealForStorage(draft.note)
                    : draft.note
            )
            connection.bindText(statement, 5, encodedFileURLs(draft.fileURLs))
            connection.bindText(statement, 6, draft.sourceApp)
            connection.bindDouble(statement, 7, now)
            connection.bindDouble(statement, 8, now)
            connection.bindDouble(statement, 9, now)
            sqlite3_bind_int(statement, 10, draft.isPrivate ? 1 : 0)
            connection.bindText(statement, 11, draft.contentHash)
            connection.bindText(statement, 12, classification.smartTag.rawValue)
            sqlite3_bind_int(
                statement,
                13,
                Int32(ClassificationPolicy.currentVersion)
            )
            sqlite3_bind_int(
                statement,
                14,
                (draft.containsSensitive
                    ?? SensitiveDetector.containsSensitive(
                        text: draft.text,
                        note: draft.note
                    )) ? 1 : 0
            )
            // Image bytes live in `clip_images` (v10). The inline column stays
            // empty so scans of `clips` never walk blob pages; the caller
            // writes this row's bytes in the same transaction.
            sqlite3_bind_null(statement, 15)
            connection.bindText(
                statement,
                16,
                draft.imageFormat ?? ""
            )
            connection.bindText(statement, 17, draft.sourceBundle)
            // Same normalization the FTS table and the in-memory index use,
            // written in the same transaction so the three never disagree.
            //
            // 私密行写**空串而不是 NULL**（M3）：这一列是索引用的第二份明文，
            // 私密内容不能有它；而空串让"回填"任务（只认 `norm_text IS NULL`）
            // 永远不会把明文补回来——这正是留空串而不是留 NULL 的原因。
            connection.bindText(
                statement,
                18,
                privateBody ? "" : QueryNormalizer.normalize(draft.text)
            )
            connection.bindText(
                statement,
                19,
                privateBody ? "" : QueryNormalizer.normalize(draft.note)
            )
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
        return connection.lastInsertRowID()
    }

    static func deleteRow(
        dbID: Int64,
        connection: DatabaseConnection
    ) throws {
        // Explicit, so a connection that somehow opened without foreign-key
        // enforcement cannot leave orphaned image bytes behind.
        try ClipImageRepository.delete(dbID: dbID, connection: connection)
        try connection.prepare("DELETE FROM clips WHERE db_id = ?") { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    /// 落盘正文 → 内存正文（`updateBody` 的读侧）。
    ///
    /// 私密行走解密；解不开返回空串——**绝不把密文当正文交出去**（见 `clip(from:)`）。
    static func bodyText(stored: String, isPrivate: Bool) -> String {
        guard isPrivate else { return stored }
        return StoreCrypto.openStored(stored) ?? ""
    }

    /// 只查一行是不是私密。给"改备注"这类需要知道落盘形态、又不需要正文的路径用：
    /// 为拿一个布尔值把整行解密出来不值得。
    static func isPrivateRow(
        dbID: Int64,
        connection: DatabaseConnection
    ) throws -> Bool? {
        try connection.prepare(
            "SELECT is_private FROM clips WHERE db_id = ?"
        ) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    /// 读一行的**落盘形态**正文与备注（私密行即密文，不做解密）。
    /// 给 `updatePrivate` 这类必须区分"解密失败"与"内容真的为空"的写路径用：
    /// 原始值由调用方直接问 `StoreCrypto`，仓库层不做二次解释。
    static func storedBodyAndNote(
        dbID: Int64,
        connection: DatabaseConnection
    ) throws -> (text: String, note: String)? {
        let result: (text: String, note: String)? = try connection.prepare(
            "SELECT text, note FROM clips WHERE db_id = ?"
        ) { statement -> (text: String, note: String)? in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let text = DatabaseConnection.sharedColumnText(statement, 0),
                  let note = DatabaseConnection.sharedColumnText(statement, 1)
            else { return nil }
            return (text: text, note: note)
        }
        return result
    }

    /// 改备注：写 `note`，并把归一化后的备注写进 `norm_note`。
    ///
    /// 私密条目（M3）：备注写密文，且**不写** `norm_note`——它与 `clips_fts`
    /// 一样是索引用的第二份明文。
    static func updateNote(
        dbID: Int64,
        note: String,
        isPrivate: Bool,
        connection: DatabaseConnection
    ) throws {
        let sql = """
            UPDATE clips
            SET note = ?, norm_note = ?, updated_at = ?
            WHERE db_id = ?
            """
        let stored = isPrivate ? try StoreCrypto.sealForStorage(note) : note
        try connection.prepare(sql) { statement in
            connection.bindText(statement, 1, stored)
            connection.bindText(
                statement,
                2,
                isPrivate ? "" : QueryNormalizer.normalize(note)
            )
            connection.bindDouble(statement, 3, clipTimestamp(Date()))
            sqlite3_bind_int64(statement, 4, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    /// 改写正文与备注，**入参是内存里的明文**：加密与索引副本的去留都由
    /// `isPrivate` 决定，调用方不需要（也做不到）自己拼落盘形态。
    ///
    /// "私密 ↔ 普通"切换与 M3 迁移共用这一条写入路径，所以两处的行为不会分叉。
    static func updateBody(
        dbID: Int64,
        text: String,
        note: String,
        isPrivate: Bool,
        connection: DatabaseConnection
    ) throws {
        let sql = """
            UPDATE clips
            SET text = ?, note = ?, norm_text = ?, norm_note = ?, updated_at = ?
            WHERE db_id = ?
            """
        let storedText = isPrivate
            ? try StoreCrypto.sealForStorage(text) : text
        let storedNote = isPrivate
            ? try StoreCrypto.sealForStorage(note) : note
        try connection.prepare(sql) { statement in
            connection.bindText(statement, 1, storedText)
            connection.bindText(statement, 2, storedNote)
            connection.bindText(
                statement,
                3,
                isPrivate ? "" : QueryNormalizer.normalize(text)
            )
            connection.bindText(
                statement,
                4,
                isPrivate ? "" : QueryNormalizer.normalize(note)
            )
            connection.bindDouble(statement, 5, clipTimestamp(Date()))
            sqlite3_bind_int64(statement, 6, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func updateImage(
        dbID: Int64,
        data: Data?,
        format: String?,
        connection: DatabaseConnection
    ) throws {
        if let data, !data.isEmpty {
            try ClipImageRepository.store(
                dbID: dbID,
                data: data,
                connection: connection
            )
        } else {
            try ClipImageRepository.delete(
                dbID: dbID,
                connection: connection
            )
        }
        let sql = """
            UPDATE clips
            SET image_blob = NULL, image_format = ?, updated_at = ?
            WHERE db_id = ?
            """
        try connection.prepare(sql) { statement in
            connection.bindText(statement, 1, format ?? "")
            connection.bindDouble(statement, 2, clipTimestamp(Date()))
            sqlite3_bind_int64(statement, 3, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func updatePrivate(
        dbID: Int64,
        isPrivate: Bool,
        connection: DatabaseConnection
    ) throws {
        let sql = "UPDATE clips SET is_private = ?, updated_at = ? WHERE db_id = ?"
        try connection.prepare(sql) { statement in
            sqlite3_bind_int(statement, 1, isPrivate ? 1 : 0)
            connection.bindDouble(statement, 2, clipTimestamp(Date()))
            sqlite3_bind_int64(statement, 3, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func touch(
        dbID: Int64,
        sourceApp: String?,
        connection: DatabaseConnection
    ) throws {
        let sql = """
            UPDATE clips
            SET last_copied_at = ?, source_app = ?
            WHERE db_id = ?
            """
        try connection.prepare(sql) { statement in
            connection.bindDouble(statement, 1, clipTimestamp(Date()))
            connection.bindText(statement, 2, sourceApp)
            sqlite3_bind_int64(statement, 3, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func updateContentHash(
        dbID: Int64,
        hash: String?,
        connection: DatabaseConnection
    ) throws {
        try connection.prepare("UPDATE clips SET content_hash = ? WHERE db_id = ?") { statement in
            connection.bindText(statement, 1, hash)
            sqlite3_bind_int64(statement, 2, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func updateContainsSensitive(
        dbID: Int64,
        containsSensitive: Bool,
        connection: DatabaseConnection
    ) throws {
        try connection.prepare("""
            UPDATE clips SET contains_sensitive = ?
            WHERE db_id = ?
            """) { statement in
            sqlite3_bind_int(statement, 1, containsSensitive ? 1 : 0)
            sqlite3_bind_int64(statement, 2, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    /// Persists one automatic or manual classification result.
    /// `manualTag == nil` clears a previous override (restore auto).
    static func updateClassification(
        dbID: Int64,
        kind: ClipKind,
        smartTag: SmartTag,
        version: Int,
        manualTag: String?,
        containsSensitive: Bool? = nil,
        connection: DatabaseConnection
    ) throws {
        var sql = """
            UPDATE clips
            SET kind = ?, smart_tag = ?, classification_version = ?,
                manual_tag = ?
            """
        if containsSensitive != nil {
            sql += ", contains_sensitive = ?"
        }
        sql += " WHERE db_id = ?"

        try connection.prepare(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(kind.databaseValue))
            connection.bindText(statement, 2, smartTag.rawValue)
            sqlite3_bind_int(statement, 3, Int32(version))
            connection.bindText(statement, 4, manualTag)
            var index: Int32 = 5
            if let containsSensitive {
                sqlite3_bind_int(statement, index, containsSensitive ? 1 : 0)
                index += 1
            }
            sqlite3_bind_int64(statement, index, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func pendingReclassification(
        connection: DatabaseConnection,
        limit: Int
    ) throws -> [Clip] {
        // `selectSQL` has no trailing newline, so the separator matters:
        // without it the statement reads `FROM clipsWHERE manual_tag IS NULL`
        // and every background reclassification pass fails to parse.
        let sql = selectSQL + "\n" + """
            WHERE manual_tag IS NULL
              AND (classification_version < ?
                   OR smart_tag = '')
            ORDER BY db_id ASC
            LIMIT ?
            """
        return try connection.prepare(sql) { statement in
            sqlite3_bind_int(
                statement,
                1,
                Int32(ClassificationPolicy.currentVersion)
            )
            sqlite3_bind_int(statement, 2, Int32(limit))
            var clips: [Clip] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let clip = clip(from: statement) {
                    clips.append(clip)
                }
            }
            return clips
        }
    }

    // MARK: - Decoding

    static func clip(from statement: OpaquePointer) -> Clip? {
        let idText = DatabaseConnection.sharedColumnText(statement, 1) ?? ""
        guard let id = UUID(uuidString: idText),
              let kind = ClipKind(
                  databaseValue: Int(sqlite3_column_int(statement, 2))
              ) else {
            return nil
        }
        let fileURLs = decodeFileURLs(DatabaseConnection.sharedColumnText(statement, 6) ?? "[]")
        let isPrivate = sqlite3_column_int(statement, 11) != 0
        // 私密条目的正文落盘是密文（M3）。这里必须解开；解不开就留空——
        // **绝不把密文当正文交出去**：它会显示在卡片上、被复制出去、甚至被写回库。
        // 非私密行根本不走 crypto，所以"用户复制了一段以 clipa1: 开头的文本"
        // 不会被误判成密文。
        let text = bodyText(
            stored: DatabaseConnection.sharedColumnText(statement, 3) ?? "",
            isPrivate: isPrivate
        )
        let note = bodyText(
            stored: DatabaseConnection.sharedColumnText(statement, 4) ?? "",
            isPrivate: isPrivate
        )
        let manualTag = DatabaseConnection.sharedColumnText(statement, 16)
        let storedSmartTag =
            manualTag
            ?? DatabaseConnection.sharedColumnText(statement, 14)
        return Clip(
            dbID: sqlite3_column_int64(statement, 0),
            id: id,
            kind: kind,
            text: text,
            note: note,
            imageFormat: DatabaseConnection.sharedColumnText(statement, 18),
            fileURLs: fileURLs,
            sourceApp: DatabaseConnection.sharedColumnText(statement, 7),
            sourceBundle: DatabaseConnection.sharedColumnText(statement, 19),
            createdAt: DatabaseConnection.sharedDate(statement, 8),
            lastCopiedAt: DatabaseConnection.sharedDate(statement, 9),
            updatedAt: DatabaseConnection.sharedDate(statement, 10),
            isPrivate: sqlite3_column_int(statement, 11) != 0,
            isHidden: sqlite3_column_int(statement, 12) != 0,
            smartTag: SmartTag(
                rawValue: storedSmartTag ?? ""
            ) ?? SmartClassifier.inferredTag(
                text: text,
                kind: kind
            ),
            contentHash: DatabaseConnection.sharedColumnText(statement, 13),
            containsSensitive: sqlite3_column_int(statement, 17) != 0,
            smartTagIsManual: manualTag != nil,
            classificationVersion: Int(sqlite3_column_int(statement, 15))
        )
    }

    static func encodedFileURLs(_ urls: [URL]) -> String? {
        let paths = urls.map(\.path)
        guard let data = try? JSONEncoder().encode(paths) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeFileURLs(_ json: String) -> [URL] {
        guard let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

}

// Static helpers called by the repository; kept small so row decoding can stay
// next to the column layout above without a repository-level connection.
extension DatabaseConnection {
    static func sharedColumnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        DatabaseConnection.decodeText(statement, index)
    }

    /// The timestamp columns are REAL (`timeIntervalSince1970` with fractional
    /// seconds). Reading them with `sqlite3_column_int64` truncated every value
    /// to whole seconds, so two clips copied inside the same second compared
    /// equal in memory while SQLite, ordering on the REAL value, disagreed — the
    /// in-memory list and the database list could then show different orders,
    /// and `trimToLimit` (which trusts the in-memory order) could evict a
    /// different row than the database considers oldest.
    static func sharedDate(_ statement: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    /// `nil` for a NULL column. `sharedDate` cannot express that: it would turn
    /// "never pinned" into 1970, which the memory view would then sort as the
    /// oldest row in the drawer instead of leaving it out.
    static func sharedOptionalDate(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sharedDate(statement, index)
    }
}
