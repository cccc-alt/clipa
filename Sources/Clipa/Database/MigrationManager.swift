import Foundation
import CSQLCipher

final class MigrationManager {
    private let connection: DatabaseConnection

    private let imagesDirectory: URL

    private var ftsNeedsRebuild = false
    private var ftsRebuildReason: FTSRepository.RebuildReason = .requested

    init(
        connection: DatabaseConnection,
        imagesDirectory: URL
    ) {
        self.connection = connection
        self.imagesDirectory = imagesDirectory
    }

    /// Idempotent, retry-safe schema migrations; never bricks the store.
func migrateIfNeeded() throws {

        let clipsExist = try connection.requireTable("clips")

        let isUpgrade = connection.userVersion()
            < DatabaseSchema.currentUserVersion

        if !clipsExist {
            if try connection.requireTable("clips_v4") {

                try connection.exec("ALTER TABLE clips_v4 RENAME TO clips")
                try connection.exec(DatabaseSchema.clipsIndexes)
                if try !connection.requireTable("clips_fts") {
                    try connection.exec(DatabaseSchema.ftsTable)
                }
            } else if try connection.requireTable("clips_v2") {

                try connection.exec("ALTER TABLE clips_v2 RENAME TO clips")
                try connection.exec(DatabaseSchema.clipsIndexes)
                if try !connection.requireTable("clips_fts") {
                    try connection.exec(DatabaseSchema.ftsTable)
                }
            } else {
                try connection.exec(DatabaseSchema.clipsTable)
                try connection.exec(DatabaseSchema.clipsIndexes)
                try connection.exec(DatabaseSchema.ftsTable)
            }
        } else if try !connection.requireColumn(table: "clips", column: "db_id") {
            try migrateLegacyTableToV2()
        } else {
            try connection.exec(DatabaseSchema.clipsIndexes)
        }

        try connection.exec(DatabaseSchema.storeMetaTable)
        try importLegacyJSONIfPresent()

        try connection.exec(DatabaseSchema.clipImagesTable)

        try ensureSmartTagColumn()
        try ensureClassificationMetadataColumns()
        try migrateToStorageLayoutV4IfNeeded()

        try ensureClassificationMetadataColumns()

        try dropRemovedAIFeatureSchema()
        if isUpgrade {
            try dropRemovedSearchFeatureTables()
        }

        try backfillContentHashesIfNeeded()

        if !ftsIsV2() {
            try connection.exec("DROP TABLE IF EXISTS clips_fts")
            try connection.exec(DatabaseSchema.ftsTable)
            ftsNeedsRebuild = true
            ftsRebuildReason = .schemaChanged
        }

        try ensureSearchNormalizationColumns()
        if isUpgrade {

            try deduplicateContentHashesIfNeeded()
        }

        try connection.exec(DatabaseSchema.dropSupersededContentHashIndex)
        try connection.exec(DatabaseSchema.uniqueContentHashIndex)

        try ensureImageColumns()

        try ensureSourceBundleColumn()

        if isUpgrade {
            try migrateRetiredTypesIfNeeded()
        }

        try SearchRepository.completeNormalizationIfNeeded(
            connection: connection
        )

        try encryptPrivateContentIfNeeded()

        try reconcileFTSIndex()
        try verifyConsistency()
        try FTSRepository.markSessionOpen(connection: connection)

        connection.setUserVersion(DatabaseSchema.currentUserVersion)
    }

    private static let privateEncryptionMarker = "crypto.private_content_version"

    private func needsSealing(_ value: String) -> Bool {
        if value.isEmpty { return false }
        guard StoreCrypto.isEnvelope(value) else { return true }
        return StoreCrypto.openStored(value) == nil
    }

    private func plainValue(_ value: String) -> String {
        guard StoreCrypto.isEnvelope(value) else { return value }
        return StoreCrypto.openStored(value) ?? value
    }

    private func encryptPrivateContentIfNeeded() throws {
        if StoreMeta.value(
            forKey: Self.privateEncryptionMarker,
            connection: connection
        ) == "1" { return }

        var sealed = 0
        var cursor: Int64 = 0
        do {
            while true {
                let candidates = try privateRowCandidates(after: cursor, limit: 500)
                if candidates.isEmpty { break }
                cursor = candidates.last!.dbID

                let batch = candidates.filter {
                    needsSealing($0.text) || needsSealing($0.note)
                }
                guard !batch.isEmpty else { continue }
                try connection.beginImmediate()
                do {
                    for row in batch {

                        try ClipRepository.updateBody(
                            dbID: row.dbID,
                            text: plainValue(row.text),
                            note: plainValue(row.note),
                            isPrivate: true,
                            connection: connection
                        )
                        try FTSRepository.setContent(
                            rowid: row.dbID,
                            text: "",
                            note: "",
                            indexed: false,
                            connection: connection
                        )
                    }
                    try connection.commit()
                } catch {
                    connection.rollback()
                    throw error
                }
                sealed += batch.count
            }
        } catch {

            NSLog("Clipa private encryption deferred: \(error.localizedDescription)")
            return
        }
        try StoreMeta.set(
            "1",
            forKey: Self.privateEncryptionMarker,
            connection: connection
        )
        if sealed > 0 {
            NSLog("Clipa private encryption sealed \(sealed) rows")
        }

        do {
            try connection.purgeFreedContent()
        } catch {
            NSLog("Clipa M3 purge failed: \(error.localizedDescription)")
        }
    }

    private func privateRowCandidates(
        after: Int64, limit: Int
    ) throws -> [(dbID: Int64, text: String, note: String)] {
        let sql = """
            SELECT db_id, text, note FROM clips
            WHERE is_private = 1 AND (text != '' OR note != '') AND db_id > ?
            ORDER BY db_id ASC
            LIMIT ?
            """
        return try connection.prepare(sql) { statement -> [(
            dbID: Int64, text: String, note: String
        )] in
            sqlite3_bind_int64(statement, 1, after)
            sqlite3_bind_int64(statement, 2, Int64(limit))
            var rows: [(dbID: Int64, text: String, note: String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((
                    sqlite3_column_int64(statement, 0),
                    connection.columnText(statement, 1) ?? "",
                    connection.columnText(statement, 2) ?? ""
                ))
            }
            return rows
        }
    }

    private func reconcileFTSIndex() throws {
        if ftsNeedsRebuild {
            NSLog("Clipa FTS 索引重建（\(ftsRebuildReason.rawValue)）")
            try FTSRepository.rebuildAndMark(connection: connection)
            return
        }
        switch try FTSRepository.decide(connection: connection) {
        case .trusted(let marker):
            NSLog(
                "Clipa FTS 索引校验通过，跳过重建（buildCount=\(marker.buildCount)）"
            )
        case .rebuild(let reason, let detail):
            let suffix = detail.isEmpty ? "" : " \(detail)"
            NSLog("Clipa FTS 索引重建（\(reason.rawValue)）\(suffix)")
            try FTSRepository.rebuildAndMark(connection: connection)
        }
    }

    private func ensureSearchNormalizationColumns() throws {
        if try !connection.requireColumn(table: "clips", column: "norm_text") {
            try connection.exec("ALTER TABLE clips ADD COLUMN norm_text TEXT")
        }
        if try !connection.requireColumn(table: "clips", column: "norm_note") {
            try connection.exec("ALTER TABLE clips ADD COLUMN norm_note TEXT")
        }
    }

    private func migrateRetiredTypesIfNeeded() throws {
        try connection.exec(
            "UPDATE clips SET kind = 0 WHERE kind IN (1, 2)"
        )
        let retiredTags = "'url', 'code', 'log', 'command', 'ip', 'email'"

        try connection.exec("""
            UPDATE clips SET manual_tag = NULL
            WHERE manual_tag IN (\(retiredTags))
            """)
        try connection.exec("""
            UPDATE clips
            SET smart_tag = '', classification_version = 0
            WHERE smart_tag IN (\(retiredTags))
            """)
    }

    private func ensureImageColumns() throws {
        if try !connection.requireColumn(table: "clips", column: "image_blob") {
            try connection.exec("ALTER TABLE clips ADD COLUMN image_blob BLOB")
        }
        if try !connection.requireColumn(table: "clips", column: "image_format") {
            try connection.exec("""
                ALTER TABLE clips
                ADD COLUMN image_format TEXT NOT NULL DEFAULT ''
                """)
        }
    }

    private func ensureSourceBundleColumn() throws {
        if try !connection.requireColumn(
            table: "clips",
            column: "source_bundle"
        ) {
            try connection.exec(
                "ALTER TABLE clips ADD COLUMN source_bundle TEXT"
            )
        }
    }

    private func migrateToStorageLayoutV4IfNeeded() throws {
        let kindType = connection.columnType(table: "clips", column: "kind")
            .map { $0.uppercased() }
        let createdAtType = connection.columnType(table: "clips", column: "created_at")
            .map { $0.uppercased() }
        let lastCopiedType = connection.columnType(
            table: "clips",
            column: "last_copied_at"
        ).map { $0.uppercased() }
        let updatedAtType = connection.columnType(table: "clips", column: "updated_at")
            .map { $0.uppercased() }
        guard kindType != "INTEGER"
            || createdAtType != "REAL"
            || lastCopiedType != "REAL"
            || updatedAtType != "REAL"
        else { return }

        try connection.exec("DROP TABLE IF EXISTS clips_v4")
        try connection.exec(DatabaseSchema.clipsTableSQL(named: "clips_v4"))
        try connection.exec("""
            INSERT INTO clips_v4 (
                db_id, id, kind, text, note, image_file, file_urls, source_app,
                created_at, last_copied_at, updated_at,
                is_pinned, is_private, is_hidden, content_hash, smart_tag
            )
            SELECT
                db_id, id,
                CASE kind
                    WHEN 'text' THEN 0
                    WHEN 'link' THEN 1
                    WHEN 'code' THEN 2
                    WHEN 'image' THEN 3
                    WHEN 'file' THEN 4
                    ELSE CAST(kind AS INTEGER)
                END,
                text, note, image_file, file_urls, source_app,
                CAST(created_at AS REAL),
                CAST(last_copied_at AS REAL),
                CAST(updated_at AS REAL),
                is_pinned, is_private, is_hidden, content_hash, smart_tag
            FROM clips
            """)
        try connection.exec("DROP TABLE IF EXISTS clips")
        try connection.exec("ALTER TABLE clips_v4 RENAME TO clips")
        try connection.exec(DatabaseSchema.clipsIndexes)
        try connection.exec("DROP TABLE IF EXISTS clips_fts")
        try connection.exec(DatabaseSchema.ftsTable)
        ftsNeedsRebuild = true
        ftsRebuildReason = .schemaChanged
    }

    private func migrateLegacyTableToV2() throws {

        try connection.exec("DROP TABLE IF EXISTS clips_v2")
        try connection.exec("""
            CREATE TABLE IF NOT EXISTS clips_v2 (
                db_id INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                note TEXT NOT NULL DEFAULT '',
                image_file TEXT,
                file_urls TEXT NOT NULL DEFAULT '[]',
                source_app TEXT,
                created_at INTEGER NOT NULL,
                last_copied_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                is_private INTEGER NOT NULL DEFAULT 0,
                is_hidden INTEGER NOT NULL DEFAULT 0,
                content_hash TEXT
            )
            """)

        try connection.exec("""
            INSERT INTO clips_v2 (
                id, kind, text, note, image_file, file_urls, source_app,
                created_at, last_copied_at, updated_at,
                is_pinned, is_private, is_hidden
            )
            SELECT
                id, kind, text,
                COALESCE(note, ''),
                image_file,
                COALESCE(file_urls, '[]'),
                source_app,
                CAST(created_at AS INTEGER),
                CAST(COALESCE(updated_at, created_at) AS INTEGER),
                CAST(COALESCE(updated_at, created_at) AS INTEGER),
                is_pinned, is_private, is_hidden
            FROM clips
            ORDER BY position ASC
            """)

        try connection.exec("DROP INDEX IF EXISTS idx_clips_position")
        try connection.exec("DROP TABLE IF EXISTS clips")
        try connection.exec("ALTER TABLE clips_v2 RENAME TO clips")
        try connection.exec(DatabaseSchema.clipsIndexes)
        try connection.exec("DROP TABLE IF EXISTS clips_fts")
        try connection.exec(DatabaseSchema.ftsTable)
        ftsNeedsRebuild = true
        ftsRebuildReason = .schemaChanged
        try importLegacyJSONIfPresent()
    }

    private func dropRemovedAIFeatureSchema() throws {
        if try connection.requireColumn(table: "clips", column: "ai_visibility") {
            do {
                try connection.exec("ALTER TABLE clips DROP COLUMN ai_visibility")
            } catch {

                NSLog(
                    "Clipa could not drop the retired ai_visibility column: "
                        + error.localizedDescription
                )
            }
        }
        if try connection.requireTable("ai_token_usage") {
            try connection.exec("DROP TABLE IF EXISTS ai_token_usage")
        }
    }

    private func dropRemovedSearchFeatureTables() throws {
        for table in ["search_learning", "search_functions"] {
            guard try connection.requireTable(table) else { continue }
            do {
                try connection.exec("DROP TABLE IF EXISTS \(table)")
                NSLog("Clipa dropped the retired \(table) table")
            } catch {

                NSLog(
                    "Clipa could not drop the retired \(table) table: "
                        + error.localizedDescription
                )
            }
        }
        try connection.exec(
            "DELETE FROM store_meta WHERE key LIKE 'search_functions.%'"
        )
    }

    private func ensureSmartTagColumn() throws {
        guard try !connection.requireColumn(
            table: "clips",
            column: "smart_tag"
        ) else {
            return
        }
        try connection.exec("""
            ALTER TABLE clips
            ADD COLUMN smart_tag TEXT NOT NULL DEFAULT ''
            """)
    }

    private func ensureClassificationMetadataColumns() throws {
        if try !connection.requireColumn(
            table: "clips",
            column: "classification_version"
        ) {
            try connection.exec("""
                ALTER TABLE clips
                ADD COLUMN classification_version INTEGER NOT NULL DEFAULT 0
                """)
        }
        if try !connection.requireColumn(table: "clips", column: "manual_tag") {
            try connection.exec("""
                ALTER TABLE clips ADD COLUMN manual_tag TEXT
                """)
        }

        if try !connection.requireColumn(
            table: "clips",
            column: "contains_sensitive"
        ) {
            try connection.exec("""
                ALTER TABLE clips
                ADD COLUMN contains_sensitive INTEGER NOT NULL DEFAULT 0
                """)
        }
        try connection.exec(
            "CREATE INDEX IF NOT EXISTS idx_clips_classification"
                + " ON clips(classification_version)"
        )
    }

    private func ftsIsV2() -> Bool {
        guard let sql = connection.ftsColumnList(for: "clips_fts") else { return false }
        return sql.contains("tokenize='trigram'")
            && sql.contains("note")
            && !sql.contains("source_app")
    }

    private func verifyConsistency() throws {
        let clipsCount = try connection.rowCount(in: "clips")
        let ftsCount = try FTSRepository.count(connection: connection)
        guard clipsCount == ftsCount else {
            throw DatabaseError.sql(
                "clips=\(clipsCount) clips_fts=\(ftsCount) 不一致"
            )
        }
    }

    private func deduplicateContentHashesIfNeeded() throws {
        let duplicateCount = try connection.scalarInt("""
            SELECT COUNT(*) FROM (
                SELECT content_hash, kind
                FROM clips
                WHERE content_hash IS NOT NULL AND content_hash != ''
                GROUP BY content_hash, kind
                HAVING COUNT(*) > 1
            )
            """)
        guard duplicateCount > 0 else { return }

        var seenKey: String?
        var loserDBIDs: [Int64] = []
        var loserImageFiles: [String] = []
        try connection.prepare("""
            SELECT db_id, content_hash, kind, image_file
            FROM clips
            WHERE content_hash IS NOT NULL AND content_hash != ''
            ORDER BY
                content_hash,
                kind,
                is_pinned DESC,
                last_copied_at DESC,
                db_id DESC
            """) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let dbID = sqlite3_column_int64(statement, 0)
                let key = connection.columnString(statement, 1)
                    + "\u{1F}"
                    + connection.columnString(statement, 2)
                if let seenKey, seenKey == key {
                    loserDBIDs.append(dbID)
                    if let image = connection.columnText(statement, 3),
                       !image.isEmpty {
                        loserImageFiles.append(image)
                    }
                } else {
                    seenKey = key
                }
            }
        }
        guard !loserDBIDs.isEmpty else { return }

        try connection.beginImmediate()
        do {
            for dbID in loserDBIDs {
                try ClipRepository.deleteRow(
                    dbID: dbID,
                    connection: connection
                )

                try FTSRepository.delete(rowid: dbID, connection: connection)
            }
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }

        ftsNeedsRebuild = true
        ftsRebuildReason = .migrationTouchedClips
        for fileName in loserImageFiles {
            try? FileManager.default.removeItem(
                at: imagesDirectory.appendingPathComponent(fileName)
            )
        }
    }

    private struct HashRow {
        let dbID: Int64
        let kind: ClipKind?
        let text: String
        let fileURLsJSON: String
        let imageFileName: String?
        let existingHash: String?
    }

    private func backfillContentHashesIfNeeded() throws {
        let markerKey = "clips.content_hash_backfill_done"
        guard StoreMeta.value(forKey: markerKey, connection: connection) == nil
        else { return }

        let rows = try connection.prepare("""
            SELECT db_id, kind, text, file_urls, image_file, content_hash
            FROM clips
            WHERE content_hash IS NULL OR content_hash = ''
            """) { statement -> [HashRow] in
            var rows: [HashRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let kindRaw = connection.columnString(statement, 1)
                let kind = ClipKind(databaseValue: Int(kindRaw) ?? -1)
                    ?? ClipKind(rawValue: kindRaw)
                rows.append(HashRow(
                    dbID: sqlite3_column_int64(statement, 0),
                    kind: kind,
                    text: connection.columnString(statement, 2),
                    fileURLsJSON: connection.columnString(statement, 3),
                    imageFileName: connection.columnText(statement, 4),
                    existingHash: connection.columnText(statement, 5)
                ))
            }
            return rows
        }

        guard !rows.isEmpty else {
            try StoreMeta.set("empty", forKey: markerKey, connection: connection)
            return
        }

        try connection.beginImmediate()
        do {
            for row in rows {
                guard row.existingHash == nil || row.existingHash!.isEmpty
                else { continue }
                guard let hash = contentHash(for: row) else { continue }
                try ClipRepository.updateContentHash(
                    dbID: row.dbID,
                    hash: hash,
                    connection: connection
                )
            }
            try StoreMeta.set("done", forKey: markerKey, connection: connection)
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
    }

    private func contentHash(for row: HashRow) -> String? {
        switch row.kind {
        case .image:

            guard let fileName = row.imageFileName, !fileName.isEmpty
            else { return nil }
            let url = imagesDirectory.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ContentHasher.hash(data: data)
        case .file:
            let urls = ClipRepository.decodeFileURLs(row.fileURLsJSON)
            if !urls.isEmpty {
                return ContentHasher.hash(fileURLs: urls)
            }
            return ContentHasher.hash(text: row.text)
        default:
            return ContentHasher.hash(text: row.text)
        }
    }

    private struct LegacyClip: Decodable {
        let id: UUID?
        let kind: ClipKind
        let text: String
        let imageFileName: String?
        let fileURLs: [String]?
        let sourceApp: String?
        let createdAt: Date
        let updatedAt: Date

        let isPinned: Bool?
        let note: String?
        let isHidden: Bool?
        let isPrivate: Bool?
    }

    private func importLegacyJSONIfPresent() throws {
        let markerKey = "clips.legacy_json_imported"
        guard StoreMeta.value(forKey: markerKey, connection: connection) == nil
        else { return }
        let jsonURL = imagesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("clips.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL) else { return }
        let legacy: [LegacyClip]
        do {
            legacy = try JSONDecoder().decode([LegacyClip].self, from: data)
        } catch {

            NSLog("Clipa legacy clips.json could not be decoded: \(error)")
            return
        }
        guard !legacy.isEmpty else { return }
        let existingCount = try connection.rowCount(in: "clips")
        guard existingCount == 0 else {

            try StoreMeta.set("skipped", forKey: markerKey, connection: connection)
            return
        }

        try connection.beginImmediate()
        do {
            var seenIDs = Set<UUID>()
            for entry in legacy {
                let id = entry.id ?? UUID()
                guard !seenIDs.contains(id) else { continue }
                seenIDs.insert(id)
                let fileURLs = (entry.fileURLs ?? []).map { URL(fileURLWithPath: $0) }
                let contentHash = legacyHash(
                    kind: entry.kind,
                    text: entry.text,
                    fileURLs: fileURLs,
                    imageFileName: entry.imageFileName
                )
                let now = clipTimestamp(Date())
                let createdAt = clipTimestamp(entry.createdAt)
                let recency = max(createdAt, clipTimestamp(entry.updatedAt))
                let sql = """
                    INSERT INTO clips (
                        id, kind, text, note, image_file, file_urls, source_app,
                        created_at, last_copied_at, updated_at,
                        is_pinned, is_private, is_hidden, content_hash
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                let dbID: Int64 = try connection.prepare(sql) { statement in
                    connection.bindText(statement, 1, id.uuidString)
                    sqlite3_bind_int(statement, 2, Int32(entry.kind.databaseValue))
                    connection.bindText(statement, 3, entry.text)
                    connection.bindText(statement, 4, entry.note ?? "")
                    connection.bindText(statement, 5, entry.imageFileName)
                    connection.bindText(
                        statement,
                        6,
                        ClipRepository.encodedFileURLs(fileURLs)
                    )
                    connection.bindText(statement, 7, entry.sourceApp)
                    connection.bindDouble(statement, 8, createdAt)
                    connection.bindDouble(statement, 9, max(recency, now - 1))
                    connection.bindDouble(statement, 10, recency)
                    sqlite3_bind_int(
                        statement,
                        11,
                        (entry.isPinned ?? false) ? 1 : 0
                    )
                    sqlite3_bind_int(
                        statement,
                        12,
                        (entry.isPrivate ?? false) ? 1 : 0
                    )
                    sqlite3_bind_int(
                        statement,
                        13,
                        (entry.isHidden ?? false) ? 1 : 0
                    )
                    connection.bindText(statement, 14, contentHash)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.sql(connection.lastErrorMessage)
                    }
                    return connection.lastInsertRowID()
                }
                try FTSRepository.insert(
                    rowid: dbID,
                    text: entry.text,
                    note: entry.note ?? "",

                    indexed: !(entry.isPrivate ?? false),
                    connection: connection
                )
            }

            try StoreMeta.set("imported", forKey: markerKey, connection: connection)
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
    }

    private func legacyHash(
        kind: ClipKind,
        text: String,
        fileURLs: [URL],
        imageFileName: String?
    ) -> String? {
        switch kind {
        case .image:
            guard let fileName = imageFileName else { return nil }
            let url = imagesDirectory.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ContentHasher.hash(data: data)
        case .file:
            if !fileURLs.isEmpty {
                return ContentHasher.hash(fileURLs: fileURLs)
            }
            return ContentHasher.hash(text: text)
        default:
            return ContentHasher.hash(text: text)
        }
    }
}
