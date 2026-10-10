import Foundation
import CSQLCipher

/// v1 -> v4 migration plus the one-time legacy `clips.json` import.
///
/// v1 rows are copied by their old `position` (newest first as v1 wrote it),
/// mapped into `last_copied_at`, then `clips_fts` is rebuilt with
/// `rowid == clips.db_id`. v4 converts `kind` to INTEGER and timestamps to
/// REAL. Nothing is ever deleted destructively before the copy verifies; the
/// old JSON file is kept untouched as a backup.
final class MigrationManager {
    private let connection: DatabaseConnection
    /// Only used by the legacy JSON-import and content-hash backfill paths,
    /// which still reference `images/` on an upgrade from v6 or earlier.
    private let imagesDirectory: URL
    /// Legacy snippet file, imported into the `snippets` table once (v8).

    /// Set by any migration step that touches `clips` outside the repositories
    /// that keep `clips_fts` in step. Such a step forces a rebuild even when
    /// the cheap verification would otherwise pass.
    private var ftsNeedsRebuild = false
    private var ftsRebuildReason: FTSRepository.RebuildReason = .requested

    init(
        connection: DatabaseConnection,
        imagesDirectory: URL
    ) {
        self.connection = connection
        self.imagesDirectory = imagesDirectory
    }

    func migrateIfNeeded(markSessionOpen: Bool = true) throws {
        // P1 修复（2026-10-02）：结构性判断用 require 版探针。折叠错误的
        // hasTable/hasColumn 会把"查询失败"当成"表/列不存在"——一次 IO 抖动
        // 就能把全新的 v12 库误导向 legacy 迁移路径，此后每次启动都失败。
        // 判断错了宁可本次启动失败并给出真实原因，也不能拿着错误答案搬家。
        let clipsExist = try connection.requireTable("clips")
        // Written at the very end of a successful run, so "already at the
        // current version" means every step below completed. Two of them are
        // whole-table write scans that can only have work to do on the upgrade
        // that introduces them; running them on every launch was pure cost on a
        // large library. Everything that is also a *safety* check (FTS trust,
        // normalization completeness, consistency) is deliberately not gated.
        let isUpgrade = connection.userVersion()
            < DatabaseSchema.currentUserVersion

        if !clipsExist {
            if try connection.requireTable("clips_v4") {
                // Interrupted v4 conversion between "DROP clips" and "RENAME".
                try connection.exec("ALTER TABLE clips_v4 RENAME TO clips")
                try connection.exec(DatabaseSchema.clipsIndexes)
                if try !connection.requireTable("clips_fts") {
                    try connection.exec(DatabaseSchema.ftsTable)
                }
            } else if try connection.requireTable("clips_v2") {
                // Interrupted migration between "DROP clips" and "RENAME":
                // finish the rename, then the normal verification below runs.
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

        // The legacy `clips.json` import used to sit *inside* the branch above
        // that only runs when the `clips` table does not exist yet. The table is
        // created and committed before the import runs, so a failed import — a
        // malformed entry, a crash, a force quit — left a store that already had
        // a `clips` table behind: every later launch took the "already
        // migrated" path and never retried, while the user's entire pre-upgrade
        // history stayed on disk in `clips.json`, silently ignored.
        //
        // It now runs on every launch and is bounded by a marker written in the
        // same transaction as the rows.
        try connection.exec(DatabaseSchema.storeMetaTable)
        try importLegacyJSONIfPresent()

        // The v10 image table is created up front: migration steps below
        // (deduplication, legacy image import) delete rows through
        // `ClipRepository.deleteRow`, which keeps it in step.
        try connection.exec(DatabaseSchema.clipImagesTable)

        try ensureSmartTagColumn()
        try ensureClassificationMetadataColumns()
        try migrateToStorageLayoutV4IfNeeded()
        // v4 rebuild drops the old table (and its indexes), so recreate the
        // classification index only after the final layout is in place.
        try ensureClassificationMetadataColumns()
        // Runs last: the v4 rebuild above copies the old table wholesale, so
        // the legacy column has to still exist while that happens.
        try dropRemovedAIFeatureSchema()
        if isUpgrade {
            try dropRemovedSearchFeatureTables()
        }

        // Older rows predate content_hash; fill it once from their current
        // content so duplicate detection works across the upgrade boundary.
        try backfillContentHashesIfNeeded()

        // FTS schema is v2-only (text + note, rowid = db_id). Any previous
        // layout is dropped and rebuilt.
        if !ftsIsV2() {
            try connection.exec("DROP TABLE IF EXISTS clips_fts")
            try connection.exec(DatabaseSchema.ftsTable)
            ftsNeedsRebuild = true
            ftsRebuildReason = .schemaChanged
        }
        // The normalized-text copy must exist before the index can be
        // verified against it.
        try ensureSearchNormalizationColumns()
        if isUpgrade {
            // Two whole-table passes (a GROUP BY over every hash, then a
            // full-table UPDATE rewrite) that can only find work on the upgrade
            // that introduces them: once the unique index exists, duplicates
            // cannot be created, and retired tags can only come from an older
            // build's rows.
            try deduplicateContentHashesIfNeeded()
        }
        // The hash-only index has to go before the wider one is created: two
        // rows with the same digest and different kinds are legal from v11 on,
        // and the old index would keep rejecting the second one.
        try connection.exec(DatabaseSchema.dropSupersededContentHashIndex)
        try connection.exec(DatabaseSchema.uniqueContentHashIndex)
        // Adds the v7 image columns. The one-time import of legacy
        // `images/*.png` files into `image_blob` is *not* done here: it is
        // drained in the background by `ClipStore` so app launch never
        // blocks on reading (potentially gigabytes of) old image files.
        try ensureImageColumns()
        // 2026-10-04：来源应用 bundleID 落库（徽标图标解析用）。可空列，
        // 旧行 NULL → UI 回退名字索引；老版本构建打开新库也兼容（显式
        // SELECT 列表，多出的列被忽略），所以走幂等 ensure 而非版本门槛。
        try ensureSourceBundleColumn()

        // Retired-type taxonomy, applied last so it runs against the final
        // layout and the reclassifier picks the rows up on the next drain.
        if isUpgrade {
            try migrateRetiredTypesIfNeeded()
        }

        // v9 search normalization copy.

        // v9 search normalization copy.
        // because the completion marker lives in `store_meta`.
        try SearchRepository.completeNormalizationIfNeeded(
            connection: connection
        )

        // M3：私密内容的落盘加密。放在归一化回填**之后**——回填只认
        // `norm_text IS NULL`，而私密行写的是空串，所以不会被动；顺序反过来
        // （先加密、后回填）就会拿密文算出无意义的 `norm_*`。
        try encryptPrivateContentIfNeeded()

        // Only rebuild the FTS index when the data says it is needed, instead
        // of rewriting the whole index on every launch.
        try reconcileFTSIndex()
        try verifyConsistency()
        if markSessionOpen { try FTSRepository.markSessionOpen(connection: connection) }

        try connection.exec(DatabaseSchema.collectionsTables)
        connection.setUserVersion(DatabaseSchema.currentUserVersion)
    }

    // MARK: - M3 private content encryption

    /// `store_meta` 标记：`"1"` = 私密正文已按 v1 格式加密落盘。
    ///
    /// 用标记而不是只看 `user_version`，因为这一步**允许失败**（钥匙串取不到
    /// 密钥）：失败时不写标记，下次启动重试；已加密的行会被幂等跳过，所以重试
    /// 不会做无用功。
    private static let privateEncryptionMarker = "crypto.private_content_version"

    // MARK: 密封判定（P2 修复 2026-10-03）

    /// 一个落盘值是否还需要封密：非信封 = 明文；信封但解不开 = 前缀巧合或
    /// 损坏——读侧对这两种情况都取不到内容，按明文重封不丢失任何可读信息。
    /// （空串无需处理：没有内容要保护。）
    private func needsSealing(_ value: String) -> Bool {
        if value.isEmpty { return false }
        guard StoreCrypto.isEnvelope(value) else { return true }
        return StoreCrypto.openStored(value) == nil
    }

    /// 把落盘值还原成**明文**：能解开就解开（updateBody 重封换 nonce 无妨）；
    /// 解不开的按原样当明文。与 `needsSealing` 配对使用。
    private func plainValue(_ value: String) -> String {
        guard StoreCrypto.isEnvelope(value) else { return value }
        return StoreCrypto.openStored(value) ?? value
    }

    /// 把私密条目的正文与备注加密落盘，并清掉它们的索引副本（M3）。
    ///
    /// 分批（500 行）而不是一次全表：`clips` 在被自己扫描时不能改，所以先读一批
    /// 再写一批——与 `SearchRepository.backfillNormalizedText` 同一套路，内存
    /// 占用与 WAL 增量都有上界。
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
                // P2 修复（2026-10-03）：需要封密的行由 Swift 侧按"能否成功
                // 解密"判定（见 needsSealing）——不能用 SQL 前缀判断。
                let batch = candidates.filter {
                    needsSealing($0.text) || needsSealing($0.note)
                }
                guard !batch.isEmpty else { continue }
                try connection.beginImmediate()
                do {
                    for row in batch {
                        // 入参必须是明文：已封的字段先解回明文，由 updateBody
                        // 重新封（换 nonce 无妨）——对已是密文的值再封一次就
                        // 双重加密了，必须避免。
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
            // 任何失败都**一个字都不改**：留着明文等下一次启动重试，比"迁移
            // 失败导致库打不开"强得多。（P1 修复 2026-10-02：原来只兜钥匙串
            // 错误，SQL/磁盘错误会抛穿 `migrateIfNeeded`，把完好数据库贴上
            // "打不开"的封条——与"这一步绝不使库不可打开"的设计相悖。）
            // 已成功加密的批次保持已提交：`pendingPrivateRows` 会跳过它们，
            // 下次启动从断点继续。
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
        // 替换掉的旧明文还在数据页与 WAL 里；`VACUUM` 不能进事务，所以放在这里。
        // 失败只记日志：加密本身已经完成，而"库打不开"比"页里可能残留明文"更糟。
        // 探针会扫字节，所以真漏了会被抓到，不会安静地过去。
        do {
            try connection.purgeFreedContent()
        } catch {
            NSLog("Clipa M3 purge failed: \(error.localizedDescription)")
        }
    }

    /// 私密行候选（正文或备注非空），按 db_id 游标翻页。
    ///
    /// P2 修复（2026-10-03）：**SQL 里不再用 `NOT LIKE 'clipa1:%'` 判"已加密"**
    /// ——正文明文恰好以该前缀开头时会被永久跳过，读侧解不开、显示为空。
    /// 是否需要封密改由 Swift 侧按"能否成功解密"判定（`needsSealing`），
    /// 这里只负责取候选与推进游标。
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

    // MARK: - v9 FTS index trust

    /// Rebuilds only when a migration invalidated the index, or when the
    /// verification cannot prove that `clips_fts` mirrors `clips`.
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

    // MARK: - v9 search normalization

    /// Adds the normalized-text copy used by the SQL fast path. Nullable on
    /// purpose: "not backfilled yet" must be distinguishable from "normalized
    /// to the empty string", so the fast path can refuse to run.
    private func ensureSearchNormalizationColumns() throws {
        if try !connection.requireColumn(table: "clips", column: "norm_text") {
            try connection.exec("ALTER TABLE clips ADD COLUMN norm_text TEXT")
        }
        if try !connection.requireColumn(table: "clips", column: "norm_note") {
            try connection.exec("ALTER TABLE clips ADD COLUMN norm_note TEXT")
        }
    }

    // MARK: - v3 taxonomy (retired types)

    /// 2026-09-11 product decision: only text / JSON / YAML / Markdown / image
    /// / file remain. The `link` (1) and `code` (2) kind encodings collapse
    /// into `text`, and rows labelled with a retired smart tag are marked
    /// stale so the background reclassifier re-derives JSON / YAML / Markdown
    /// from their content instead of keeping a dead label.
    private func migrateRetiredTypesIfNeeded() throws {
        try connection.exec(
            "UPDATE clips SET kind = 0 WHERE kind IN (1, 2)"
        )
        let retiredTags = "'url', 'code', 'log', 'command', 'ip', 'email'"
        // A manual label that no longer exists cannot be honoured, so it is
        // cleared and the row returns to automatic classification.
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

    // MARK: - v7 image storage (files → BLOB)

    /// The legacy `image_file` column is kept for one release so an older
    /// build can still open the database.
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

    /// 2026-10-04：`clips.source_bundle`（来源应用 bundle identifier）。
    /// 见 migrateIfNeeded 调用处的注释——幂等加列，不动 user_version。
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

    // MARK: - v4 storage layout (kind INTEGER, timestamps REAL)

    /// Rebuilds `clips` when the storage layout predates v4. The kind column
    /// changes from TEXT names to the stable integer encoding in `ClipKind`,
    /// and timestamps switch from INTEGER seconds to REAL epoch seconds.
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

    // MARK: - Legacy table

    private func migrateLegacyTableToV2() throws {
        // A previous interrupted migration may have left clips_v2 behind while
        // the original v1 table is still intact; drop and redo safely.
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

    /// Removes what the deleted AI feature left behind in the schema: the
    /// `clips.ai_visibility` column and the `ai_token_usage` table. Databases
    /// written by earlier versions still carry both; nothing reads or writes
    /// them, and leaving them would keep a piece of the removed feature in
    /// every user's file.
    ///
    /// Guarded because this runs on every launch: each statement only fires
    /// once, on the upgrade that follows.
    private func dropRemovedAIFeatureSchema() throws {
        if try connection.requireColumn(table: "clips", column: "ai_visibility") {
            do {
                try connection.exec("ALTER TABLE clips DROP COLUMN ai_visibility")
            } catch {
                // Not worth refusing to open the database over: an extra column
                // nobody reads or writes is harmless, and this used to make the
                // store permanently unopenable when SQLite could not drop it.
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

    /// Drops what the removed AI search features left behind: the
    /// `search_learning` rule cache and the `search_functions` script library.
    /// Upgraded stores still carry rows in both, nothing reads or writes them
    /// any more, and their `store_meta` bookkeeping ("examples seeded v1 …v4",
    /// "syntax_v5_migrated") is noise in every future diagnosis.
    ///
    /// `search.normalized_text_version` belongs to the live search index and is
    /// deliberately left alone.
    private func dropRemovedSearchFeatureTables() throws {
        for table in ["search_learning", "search_functions"] {
            guard try connection.requireTable(table) else { continue }
            do {
                try connection.exec("DROP TABLE IF EXISTS \(table)")
                NSLog("Clipa dropped the retired \(table) table")
            } catch {
                // An extra unused table is not worth refusing to open the
                // database over.
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
        // 写路径（ADD COLUMN）前的判断同样用 require 版：查询失败折叠成"列
        // 不存在"会对已存在的列再 ADD 一次——"duplicate column name"，且从此
        // 每次启动都同样失败（requireTable 的文档注释记录过这起事故）。
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

    // MARK: - content_hash backfill

    /// Removes legacy/corrupt rows that share a content hash *and kind* before
    /// the unique index is installed. Winner policy: pinned > newest copy >
    /// rowid.
    ///
    /// The grouping has to match the index exactly
    /// (`idx_clips_content_hash_kind_unique`): a text copy and a file copy of
    /// the same path share a digest on purpose now, so deduplicating on the hash
    /// alone would delete a row the index considers legitimate.
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
                // This path deletes rows outside `ClipRepository`'s siblings,
                // so the index is maintained here too instead of relying on a
                // later full rebuild.
                try FTSRepository.delete(rowid: dbID, connection: connection)
            }
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        // Belt and braces: even though the index was kept in step above, mark
        // the launch as one that touched `clips` so the index is rebuilt.
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

    /// One-time fill of `content_hash` for rows written before the column
    /// existed.
    ///
    /// Marker-guarded because it is a full-table read that, for image rows,
    /// also touches the filesystem — running it on every launch cost a scan of
    /// the whole library each time. Rows that cannot be hashed are left NULL,
    /// which is exactly what "no hash" means: they do not take part in
    /// duplicate detection. Leaving them NULL is honest; re-reading the disk for
    /// them on every launch was not.
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

        // One transaction. The old loop ran one autocommitted UPDATE per row,
        // which is a WAL write per row on a library that can have tens of
        // thousands of them — and a crash halfway left the table split between
        // two rule providers.
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
            // The empty string is the *normal* value here: every row whose
            // bytes were moved into `clip_images` keeps `image_file = ''`, and
            // `columnText` hands that back. The old guard accepted it, built
            // `images/` itself as the path, failed to read a directory as a
            // file and returned nil — so those rows could never be hashed, and
            // were re-read on every single launch.
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

    // MARK: - Legacy clips.json

    private struct LegacyClip: Decodable {
        let id: UUID?
        let kind: ClipKind
        let text: String
        let imageFileName: String?
        let fileURLs: [String]?
        let sourceApp: String?
        let createdAt: Date
        let updatedAt: Date
        /// Keeps the v1 spelling on purpose: this is a field of the `clips.json`
        /// file format we *read*, not a name of ours. Renaming it here would
        /// have broken every pre-v2 import, which is exactly the kind of silent
        /// data loss the import is meant to prevent.
        let isPinned: Bool?
        let note: String?
        let isHidden: Bool?
        let isPrivate: Bool?
    }

    /// Moves `clips.json` into the `clips` table, retryably and at most once.
    ///
    /// The marker — not an empty table — decides whether the import already ran.
    /// It is written inside the import's own transaction, so a rollback leaves
    /// no marker behind and the next launch tries again; a user who deletes
    /// every clip afterwards must not see the old file come back.
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
            // Corrupt file: keep it and leave the marker unwritten, so a later
            // launch (or a newer build) can still rescue it.
            NSLog("Clipa legacy clips.json could not be decoded: \(error)")
            return
        }
        guard !legacy.isEmpty else { return }
        let existingCount = try connection.rowCount(in: "clips")
        guard existingCount == 0 else {
            // The rows are already there: either an older build performed the
            // import, or this store never came from v1. Mark it so the check
            // does not run on every launch.
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
                    // 私密的历史条目按"不进索引"写入：这一刻正文还是明文，
                    // 紧随其后的 M3 步骤会把它封成密文，而索引副本从一开始
                    // 就不该存在。
                    indexed: !(entry.isPrivate ?? false),
                    connection: connection
                )
            }
            // Same transaction as the rows: the marker can never claim an
            // import that rolled back, and a committed import is never repeated.
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
