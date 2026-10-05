import Foundation
import CSQLCipher

struct ClipClearRow: Equatable {
    let dbID: Int64
}

struct LegacyImageRow: Equatable {
    let dbID: Int64
    let fileName: String?

    let isPrivate: Bool
}

enum ClipRepository {
    static let selectSQL = """
        SELECT \(DatabaseSchema.clipColumns)
        FROM clips
        """

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

            let privateBody = draft.isPrivate
            connection.bindText(statement, 1, draft.id.uuidString)
            sqlite3_bind_int(
                statement,
                2,
                Int32(classification.kind.databaseValue)
            )

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

            sqlite3_bind_null(statement, 15)
            connection.bindText(
                statement,
                16,
                draft.imageFormat ?? ""
            )
            connection.bindText(statement, 17, draft.sourceBundle)

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

        try ClipImageRepository.delete(dbID: dbID, connection: connection)
        try connection.prepare("DELETE FROM clips WHERE db_id = ?") { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func bodyText(stored: String, isPrivate: Bool) -> String {
        guard isPrivate else { return stored }
        return StoreCrypto.openStored(stored) ?? ""
    }

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

extension DatabaseConnection {
    static func sharedColumnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        DatabaseConnection.decodeText(statement, index)
    }

    static func sharedDate(_ statement: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

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
