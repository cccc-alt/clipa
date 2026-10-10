import Foundation
import CSQLCipher
import UniformTypeIdentifiers

/// Result of persisting a clipboard capture.
struct ClipWriteResult {
    let clip: Clip
    /// `true` when a brand-new row was created; `false` when an existing
    /// duplicate was touched (bumped to the top).
    let inserted: Bool
}

/// Actor-isolated owner of the SQLite connection.
///
/// Clipboard, search, AI and UI can only reach SQL through actor hops, so no
/// two modules can ever mutate the connection concurrently. Internally the
/// manager is split into ClipRepository / FTSRepository / MigrationManager.
actor DatabaseManager {
    /// The actor's own thread. See `DatabaseExecutor` for why the database must
    /// not share the Swift-concurrency pool.
    nonisolated let databaseExecutor = DatabaseExecutor()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        databaseExecutor.asUnownedSerialExecutor()
    }

    let connection: DatabaseConnection
    let baseDirectory: URL

    /// True when every row carries normalized text, so the SQL exact-match
    /// fast path may run. Computed once per open: the marker alone is not
    /// enough, because a store written by an older build could contain rows
    /// the backfill never saw.
    private(set) var searchNormalizationReady = false

    /// Name of the SQLite file inside the base directory. Exposed so callers
    /// can tell a fresh install (no file yet) apart from a store that exists
    /// but cannot be opened.
    static let databaseFileName = "clips.sqlite"

    static func databaseURL(in baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(databaseFileName)
    }

    init(baseDirectory: URL, trackSession: Bool = true) throws {
        self.baseDirectory = baseDirectory
        let databaseURL = Self.databaseURL(in: baseDirectory)
        try DatabaseFiles.protectDirectory(baseDirectory)
        let connection = try DatabaseConnection(path: databaseURL.path)
        try connection.configure()
        self.connection = connection

        let migration = MigrationManager(
            connection: connection,
            imagesDirectory: baseDirectory.appendingPathComponent(
                "images",
                isDirectory: true
            )
        )
        do {
            try migration.migrateIfNeeded(markSessionOpen: trackSession)
        } catch {
            // Tag migration failures so the store can tell "upgrade stalled"
            // apart from "file unreadable" and pick the right message.
            throw DatabaseError.migration(String(describing: error))
        }
        searchNormalizationReady = SearchRepository.isNormalizationComplete(
            connection: connection
        )
    }

    /// Closes the SQLite handle and makes every later call fail cleanly.
    ///
    /// Called before a reopened connection replaces this manager. Two live
    /// handles on the same file broke the single-writer assumption this actor
    /// exists to provide: captures failed with `SQLITE_BUSY` (and were dropped),
    /// and the `VACUUM` / `wal_checkpoint` behind a secure erase failed
    /// silently because the stale connection still held a read lock.
    ///
    /// Safe to call twice; safe to call while another manager is open.
    func invalidate() {
        connection.close()
    }

    // MARK: - v6 image import (background)

    /// Connection-level secure-delete mode: 0 off, 1 on, 2 fast. Used by
    /// tests to prove a non-secure clear never weakens the default.
    func secureDeleteMode() throws -> Int {
        try connection.scalarInt("PRAGMA secure_delete;")
    }

    struct LegacyImageImportResult: Equatable {
        let migrated: Int
        let missing: Int
        let remaining: Int
    }

    /// Legacy `images/*.png` files are migrated in bounded batches from the
    /// store's background task. Doing this inside `init` used to block app
    /// launch and pull every image into memory at once.
    @discardableResult
    func importLegacyImages(
        limit: Int = 50
    ) throws -> LegacyImageImportResult {
        let rows = try ClipRepository.pendingLegacyImages(
            connection: connection,
            limit: limit
        )
        guard !rows.isEmpty else {
            retireLegacyImageDirectory()
            return LegacyImageImportResult(
                migrated: 0,
                missing: 0,
                remaining: 0
            )
        }

        let imagesDirectory = baseDirectory.appendingPathComponent(
            "images",
            isDirectory: true
        )
        var migrated = 0
        var missing = 0
        // P3 优化（2026-10-03）：**磁盘读移出写锁**。原来一整个
        // BEGIN IMMEDIATE 包住最多 50 次"读文件 + 写库"，写锁持有时长包含
        // 全部磁盘 IO——期间捕获路径全部排队。先在锁外把每行的字节读好
        // （缺失/空文件标记待清除，读取失败照旧留在 pending），再开一个短
        // 事务只做数据库写入。行保持幂等：本次没写的行下次 drain 再来。
        var prepared: [(dbID: Int64, data: Data?, format: String)] = []
        for row in rows {
            guard let fileName = row.fileName,
                  Self.isSafeImageFileName(fileName) else {
                prepared.append((row.dbID, nil, ""))
                continue
            }
            // "The file is gone" and "the file could not be read right now"
            // are different facts. Collapsing them into one `try?` meant a
            // transient I/O error — a permission problem, an unmounted
            // volume, memory pressure — marked the row as permanently
            // image-less and the bytes were never looked for again, even
            // though they were still sitting in `images/`.
            let url = imagesDirectory.appendingPathComponent(
                fileName,
                isDirectory: false
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                prepared.append((row.dbID, nil, ""))
                missing += 1
                continue
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                // Left pending on purpose: the next drain tries again (it
                // stops as soon as a batch makes no progress, so this
                // cannot spin), and the row keeps its file name.
                NSLog(
                    "Clipa legacy image read failed for \(fileName): "
                        + error.localizedDescription + " (kept pending)"
                )
                continue
            }
            guard !data.isEmpty else {
                prepared.append((row.dbID, nil, ""))
                missing += 1
                continue
            }
            // 私密行：legacy 图片**导入即密封**（2026-10-04）——不再依赖
            // 启动补偿兜底明文窗口。密封失败按"读取失败"同款处理：留在
            // pending，下次 drain 重试。
            let stored: Data
            if row.isPrivate {
                do {
                    stored = try StoreCrypto.sealDataForStorage(data)
                } catch {
                    NSLog(
                        "Clipa legacy image seal failed for \(fileName): "
                            + error.localizedDescription + " (kept pending)"
                    )
                    continue
                }
            } else {
                stored = data
            }
            prepared.append((
                row.dbID,
                stored,
                Self.legacyImageFormat(forFileName: fileName)
            ))
        }
        try connection.beginImmediate()
        do {
            for item in prepared {
                if let data = item.data {
                    try ClipRepository.storeLegacyImage(
                        dbID: item.dbID,
                        data: data,
                        format: item.format,
                        connection: connection
                    )
                    migrated += 1
                } else {
                    try ClipRepository.clearLegacyImageFile(
                        dbID: item.dbID,
                        connection: connection
                    )
                    missing += 1
                }
            }
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }

        let remaining = try ClipRepository.legacyImageCount(
            connection: connection
        )
        if remaining == 0 {
            retireLegacyImageDirectory()
        }
        NSLog(
            "Clipa legacy image import: migrated=\(migrated)"
                + " missing=\(missing) remaining=\(remaining)"
        )
        return LegacyImageImportResult(
            migrated: migrated,
            missing: missing,
            remaining: remaining
        )
    }

    /// Legacy file names are `UUID.png` written by Clipa.
    private static func isSafeImageFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.contains("\0") else {
            return false
        }
        return true
    }

    /// Legacy file names carry the real format in their extension. Anything
    /// unknown is treated as PNG because that is what Clipa wrote.
    private static func legacyImageFormat(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext) else {
            return UTType.png.identifier
        }
        return type.identifier
    }

    /// Renames (never deletes) the v6 directory once every row migrated, so a
    /// byte-level rollback is still possible.
    private func retireLegacyImageDirectory() {
        let fileManager = FileManager.default
        let imagesDirectory = baseDirectory.appendingPathComponent(
            "images",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: imagesDirectory.path) else {
            return
        }
        var target = baseDirectory.appendingPathComponent(
            "images-migrated-v6",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: target.path) {
            target = baseDirectory.appendingPathComponent(
                "images-migrated-v6-\(Int(Date().timeIntervalSince1970))",
                isDirectory: true
            )
        }
        do {
            try fileManager.moveItem(at: imagesDirectory, to: target)
            NSLog("Clipa legacy image import: retired \(target.lastPathComponent)")
        } catch {
            NSLog(
                "Clipa legacy image import: rename failed"
                    + " \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Read

    func loadRecentClips(limit: Int? = nil) throws -> [Clip] {
        try ClipRepository.loadRecent(connection: connection, limit: limit)
    }

    func storeMetaKeys(prefix: String) throws -> [String] {
        try connection.prepare(
            "SELECT key FROM store_meta WHERE key LIKE ? ORDER BY key"
        ) { statement in
            connection.bindText(statement, 1, prefix + "%")
            var keys: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let key = connection.columnText(statement, 0) {
                    keys.append(key)
                }
            }
            return keys
        }
    }

    func clip(dbID: Int64) throws -> Clip? {
        try ClipRepository.clip(dbID: dbID, connection: connection)
    }

    func findDuplicate(contentHash: String, kind: ClipKind) throws -> Clip? {
        try ClipRepository.findByHash(
            hash: contentHash,
            kind: kind,
            connection: connection
        )
    }

    func ftsCandidateIDs(
        query: String,
        maxCount: Int = 2000
    ) throws -> FTSRepository.FTSCandidateRecall {
        try connection.withCancellableRead {
            try FTSRepository.candidateIDs(
                query: query, maxCount: maxCount, connection: connection
            )
        }
    }

    func ftsCount() throws -> Int {
        try FTSRepository.count(connection: connection)
    }

    /// Exact text matches plus the facts the ranker needs, for the SQL fast
    /// path. Returns `nil` when the normalized columns are not ready, which
    /// tells the caller to use the in-memory oracle instead of guessing.
    func searchMatches(
        criteria: SearchCriteria,
        terms: [String],
        phrase: String?
    ) throws -> [TermMatchRow]? {
        guard searchNormalizationReady else { return nil }
        // `terms` and `criteria.groups` must describe the same plan: the
        // predicate builder walks the groups while indexing the term-parameter
        // table, so a mismatch between them used to index past the end of that
        // table. Refusing the fast path hands the query to the oracle instead.
        let groupTermCount = criteria.groups.reduce(0) { $0 + $1.count }
        guard groupTermCount == terms.count else { return nil }
        return try connection.withCancellableRead {
            try SearchRepository.exactMatches(
                criteria: criteria, terms: terms, phrase: phrase, connection: connection
            )
        }
    }

    /// Ids only, for plans that sort explicitly and never rank.
    func searchCandidateIDs(
        criteria: SearchCriteria
    ) throws -> [Int64]? {
        guard searchNormalizationReady else { return nil }
        return try connection.withCancellableRead {
            try SearchRepository.exactCandidateIDs(criteria: criteria, connection: connection)
        }
    }

    /// Readiness probe used by the self-test and the parity harness.
    func searchNormalizationStatus() throws -> (
        ready: Bool,
        pending: Int,
        clips: Int
    ) {
        let snapshot = try SearchRepository.integritySnapshot(
            connection: connection
        )
        return (
            ready: searchNormalizationReady,
            pending: snapshot.clips - snapshot.normalized,
            clips: snapshot.clips
        )
    }

    // MARK: - Mutations (all atomic clips + clips_fts)

    /// P1 修复（2026-10-02）：epoch 复查与 INSERT **同一个 actor 任务**内完成。
    /// Store 侧的复查与 `await insertClip` 之间隔着挂起点——清空可以插在中间
    /// 完成，复查通过的条目随后照常落库，残留一条用户刚删掉的历史。本方法把
    /// 复查闭包放进 actor 任务内求值，与清空事务严格串行：要么先提交（随后被
    /// 清掉），要么被拒绝——不存在中间态。`captureStillCurrent` 必须是同步
    /// 快速调用（读一个代数计数器），不得挂起。
    func insertClip(
        _ draft: NewClip,
        captureStillCurrent: @escaping @Sendable () -> Bool
    ) throws -> ClipWriteResult {
        guard captureStillCurrent() else {
            throw DatabaseError.historyClearInProgress
        }
        return try insertClip(draft)
    }

    func insertClip(_ draft: NewClip) throws -> ClipWriteResult {
        if let hash = draft.contentHash,
           let duplicate = try ClipRepository.findByHash(
               hash: hash,
               kind: draft.kind,
               connection: connection
           ) {
            try connection.beginImmediate()
            do {
                try ClipRepository.touch(
                    dbID: duplicate.dbID,
                    sourceApp: draft.sourceApp,
                    connection: connection
                )
                if let smartTag = draft.smartTag,
                   !duplicate.smartTagIsManual,
                   duplicate.classificationVersion
                    < ClassificationPolicy.currentVersion {
                    try ClipRepository.updateClassification(
                        dbID: duplicate.dbID,
                        kind: SmartClassifier.kind(
                            for: smartTag,
                            fallbackKind: duplicate.kind
                        ),
                        smartTag: smartTag,
                        version: ClassificationPolicy.currentVersion,
                        manualTag: nil,
                        containsSensitive:
                            draft.containsSensitive
                            ?? SensitiveDetector.containsSensitive(
                                text: draft.text,
                                note: draft.note
                            ),
                        connection: connection
                    )
                }
                try connection.commit()
            } catch {
                connection.rollback()
                throw error
            }
            guard let touched = try ClipRepository.clip(
                dbID: duplicate.dbID,
                connection: connection
            ) else {
                throw DatabaseError.missingRow
            }
            return ClipWriteResult(clip: touched, inserted: false)
        }

        try connection.beginImmediate()
        do {
            let dbID = try ClipRepository.insert(draft, connection: connection)
            try storeImage(draft, dbID: dbID)
            // 私密条目不进索引：索引列是正文的**第二份明文**，加密了正文却在
            // 这里留副本等于没加密（M3）。
            try FTSRepository.insert(
                rowid: dbID,
                text: draft.text,
                note: draft.note,
                indexed: !draft.isPrivate,
                connection: connection
            )
            guard let clip = try ClipRepository.clip(
                dbID: dbID,
                connection: connection
            ) else {
                throw DatabaseError.missingRow
            }
            try connection.commit()
            return ClipWriteResult(clip: clip, inserted: true)
        } catch {
            connection.rollback()
            throw error
        }
    }

    /// Bulk insert in one transaction, for the scale stress harness only.
    /// Seeding 100k+ rows through `insertClip` would pay one WAL commit per
    /// row; batching keeps that cost proportional to the call, not the row.
    ///
    /// Drafts whose `content_hash` already exists are skipped (the same rule
    /// `insertClip` applies) and reported as `nil`, so the caller can keep the
    /// input/output offsets aligned.
    func insertClipBatch(_ drafts: [NewClip]) throws -> [Int64?] {
        guard !drafts.isEmpty else { return [] }
        var results: [Int64?] = []
        results.reserveCapacity(drafts.count)
        try connection.beginImmediate()
        do {
            for draft in drafts {
                if let hash = draft.contentHash,
                   try ClipRepository.findByHash(
                       hash: hash,
                       kind: draft.kind,
                       connection: connection
                   ) != nil {
                    results.append(nil)
                    continue
                }
                let dbID = try ClipRepository.insert(
                    draft,
                    connection: connection
                )
                try storeImage(draft, dbID: dbID)
                // 私密条目不进索引（M3），与单条插入同理。
                try FTSRepository.insert(
                    rowid: dbID,
                    text: draft.text,
                    note: draft.note,
                    indexed: !draft.isPrivate,
                    connection: connection
                )
                results.append(dbID)
            }
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        return results
    }

    func updateNote(dbID: Int64, note: String) throws -> Clip? {
        // 这一行是不是私密，决定备注写成密文还是明文、以及要不要进索引。
        // 单独查一列，不必为拿一个布尔值把整行解密出来。
        let isPrivate = try ClipRepository.isPrivateRow(
            dbID: dbID,
            connection: connection
        ) ?? false
        try connection.beginImmediate()
        do {
            try ClipRepository.updateNote(
                dbID: dbID,
                note: note,
                isPrivate: isPrivate,
                connection: connection
            )
            try FTSRepository.updateNote(
                rowid: dbID,
                note: note,
                indexed: !isPrivate,
                connection: connection
            )
            guard let updated = try ClipRepository.clip(
                dbID: dbID,
                connection: connection
            ) else {
                throw DatabaseError.missingRow
            }
            try ClipRepository.updateContainsSensitive(
                dbID: dbID,
                containsSensitive:
                    SensitiveDetector.containsSensitive(updated),
                connection: connection
            )
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        return try ClipRepository.clip(dbID: dbID, connection: connection)
    }

    /// Reclassifies a bounded set of rows whose stored rule version is old.
    /// Returns how many rows were processed.
    func reclassifyPending(limit: Int = 200) throws -> Int {
        let pending = try ClipRepository.pendingReclassification(
            connection: connection,
            limit: limit
        )
        guard !pending.isEmpty else { return 0 }
        // P3 优化（2026-10-03）：整批一个事务。原来每行一条 UPDATE 各自
        // autocommit——200 行就是 200 次 WAL 提交，这跑在启动路径上。
        try connection.beginImmediate()
        do {
            for clip in pending {
                let result = SmartClassifier.inferredClassification(
                    text: clip.text,
                    kind: clip.kind
                )
                try ClipRepository.updateClassification(
                    dbID: clip.dbID,
                    kind: result.kind,
                    smartTag: result.smartTag,
                    version: ClassificationPolicy.currentVersion,
                    manualTag: nil,
                    containsSensitive:
                        SensitiveDetector.containsSensitive(clip),
                    connection: connection
                )
            }
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        return pending.count
    }

    func reclassifyClip(dbID: Int64) throws -> Clip? {
        guard let current = try ClipRepository.clip(
            dbID: dbID,
            connection: connection
        ) else { return nil }
        let result = SmartClassifier.inferredClassification(
            text: current.text,
            kind: current.kind
        )
        try connection.beginImmediate()
        do {
            try ClipRepository.updateClassification(
                dbID: dbID,
                kind: result.kind,
                smartTag: result.smartTag,
                version: ClassificationPolicy.currentVersion,
                manualTag: current.smartTagIsManual
                    ? current.smartTag.rawValue
                    : nil,
                containsSensitive:
                    SensitiveDetector.containsSensitive(current),
                connection: connection
            )
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        return try ClipRepository.clip(dbID: dbID, connection: connection)
    }

    /// Test hook: 把一行的落盘正文改成任意值（不解密不校验），用来构造
    /// "长得像密文但解不开"的损坏状态——P0 修复（拒绝写回空串）的回归夹具。
    func setStoredBodyForTesting(dbID: Int64, text: String) throws {
        try connection.prepare("UPDATE clips SET text = ? WHERE db_id = ?") {
            statement in
            connection.bindText(statement, 1, text)
            sqlite3_bind_int64(statement, 2, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    /// Test hook: 读一行的落盘正文（不解密），断言"密文仍在、没被空串覆盖"。
    func storedBodyForTesting(dbID: Int64) throws -> String? {
        try connection.prepare("SELECT text FROM clips WHERE db_id = ?") {
            statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return DatabaseConnection.sharedColumnText(statement, 0)
        }
    }

    /// Test hook: marks one auto-classified row as stale so callers can
    /// exercise `reclassifyPending` without manufacturing an old database.
    func setClassificationVersionForTesting(
        dbID: Int64,
        version: Int
    ) throws -> Clip? {
        try connection.prepare("""
            UPDATE clips SET classification_version = ?
            WHERE db_id = ?
            """) { statement in
            sqlite3_bind_int(statement, 1, Int32(version))
            sqlite3_bind_int64(statement, 2, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
        return try ClipRepository.clip(dbID: dbID, connection: connection)
    }

    /// Replaces the stored image bytes of an existing row.
    func updateImage(
        dbID: Int64,
        data: Data?,
        format: String?
    ) throws -> Clip? {
        try connection.beginImmediate()
        do {
            try ClipRepository.updateImage(
                dbID: dbID,
                data: data,
                format: format,
                connection: connection
            )
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        return try ClipRepository.clip(dbID: dbID, connection: connection)
    }

    /// 切换私密：正文的**落盘形态**也要跟着换（M3）。
    ///
    /// 变私密 → 封成密文 + 从索引里收回正文副本；取消私密 → 写回明文 + 把副本
    /// 放回索引。三张表（`clips` / `clips_fts` / `norm_*`）必须在同一个事务里改完，
    /// 否则搜索会悄悄少一条或多一条，`verifyStrong` 还会判定索引不可信而每次
    /// 启动都重建。
    func updatePrivate(dbID: Int64, isPrivate: Bool) throws -> Clip? {
        // 读的是**解密后**的正文：两个方向都需要它（封密文、或写回明文）。
        guard let current = try ClipRepository.clip(
            dbID: dbID,
            connection: connection
        ) else {
            throw DatabaseError.missingRow
        }
        guard current.isPrivate != isPrivate else {
            return current
        }
        // P0 修复（2026-10-02）：解密失败的私密行**拒绝切换**。
        //
        // 读取侧契约是"解不开就给空串"（不把密文交出去），但这让"解密失败"
        // 与"内容真的为空"在下游无法区分：钥匙串临时不可用（锁定 / ACL 拒绝）
        // 时，旧逻辑会把内存里的空串 `updateBody` 回写 ——
        // `UPDATE clips SET text=''` 把密文永久覆盖，不可恢复。
        // 所以"取消私密"方向必须拿**原始落盘值**重新解密：解不开就在开事务
        // 之前抛错，条目保持原样。
        var plainText = current.text
        var plainNote = current.note
        if current.isPrivate {
            let stored = try ClipRepository.storedBodyAndNote(
                dbID: dbID,
                connection: connection
            )
            guard let stored,
                  let text = StoreCrypto.openStored(stored.text),
                  let note = StoreCrypto.openStored(stored.note) else {
                throw DatabaseError.decryptionUnavailable
            }
            plainText = text
            plainNote = note
        }
        try connection.beginImmediate()
        do {
            try ClipRepository.updateBody(
                dbID: dbID,
                text: plainText,
                note: plainNote,
                isPrivate: isPrivate,
                connection: connection
            )
            try ClipRepository.updatePrivate(
                dbID: dbID,
                isPrivate: isPrivate,
                connection: connection
            )
            // P2 修复（2026-10-03）：图片字节的 seal/还原并入**同一事务**。
            // 旧实现在事务外再补一笔独立 updateImage，注释却声称"同事务"——
            // 中间崩溃留下 is_private=1 + 明文图片（或反之）。blob 读写都在
            // 本事务内，与标志同生共死。
            if current.kind == .image {
                let raw = try ClipImageRepository.load(
                    dbID: dbID,
                    connection: connection
                ) ?? inlineImageData(dbID: dbID)
                if let raw {
                    // 先归一到明文：混合状态幂等；解不开的密文按 P0 语义拒绝，
                    // 不留半成品。
                    guard let plain = StoreCrypto.openDataStored(raw) else {
                        throw DatabaseError.decryptionUnavailable
                    }
                    let data = isPrivate
                        ? try StoreCrypto.sealDataForStorage(plain)
                        : plain
                    try ClipRepository.updateImage(
                        dbID: dbID,
                        data: data,
                        format: current.imageFormat,
                        connection: connection
                    )
                }
            }
            try FTSRepository.setContent(
                rowid: dbID,
                text: plainText,
                note: plainNote,
                indexed: !isPrivate,
                connection: connection
            )
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        // 提交之后才能擦：刚才那份明文（取消私密时反过来是密文）还躺在数据页与
        // WAL 里，只看主文件会以为已经干净了。失败只记日志——正文的形态已经改对，
        // 不能把一次成功的切换变成失败。
        do {
            try connection.purgeFreedContent()
        } catch {
            NSLog(
                "Clipa private switch purge failed: \(error.localizedDescription)"
            )
        }
        return try ClipRepository.clip(dbID: dbID, connection: connection)
    }

    func deleteClips(dbIDs: [Int64]) throws -> [Clip] {
        var deleted: [Clip] = []
        try connection.beginImmediate()
        do {
            for dbID in dbIDs {
                if let clip = try ClipRepository.clip(
                    dbID: dbID,
                    connection: connection
                ) {
                    deleted.append(clip)
                }
            }
            // P3 优化（2026-10-03）：FTS 与行删除合并为多值 IN——原来每行
            // 各一次 prepare+step，批量删 100 行 ≈ 200 次。
            if !deleted.isEmpty {
                let ids = deleted.map(\.dbID)
                let placeholders = Array(repeating: "?", count: ids.count)
                    .joined(separator: ",")
                try connection.prepare(
                    "DELETE FROM clips_fts WHERE rowid IN (\(placeholders))"
                ) { statement in
                    for (index, dbID) in ids.enumerated() {
                        sqlite3_bind_int64(statement, Int32(index + 1), dbID)
                    }
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.sql(
                            connection.lastErrorMessage
                        )
                    }
                }
                try connection.prepare(
                    "DELETE FROM clips WHERE db_id IN (\(placeholders))"
                ) { statement in
                    for (index, dbID) in ids.enumerated() {
                        sqlite3_bind_int64(statement, Int32(index + 1), dbID)
                    }
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.sql(
                            connection.lastErrorMessage
                        )
                    }
                }
            }
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        return deleted
    }

    /// Deletes not-yet-pinned (or all) history rows using a minimal projection.
    /// When `secureErase` is enabled, SQLite is raised to full secure-delete
    /// mode, the WAL is checkpointed and the file is compacted. When it is
    /// disabled the connection's default mode is left untouched.
    func clearAll(
        secureErase: Bool,
        failAfterDeleteForTesting: Bool = false
    ) throws -> [ClipClearRow] {
        // Only ever raise the connection's secure_delete mode. Writing OFF
        // here would disable whatever the platform defaults to (macOS ships
        // SQLite with FAST mode enabled), and the pragma would stay weakened
        // for every later delete in the same session.
        if secureErase {
            try connection.exec("PRAGMA secure_delete = ON;")
        }
        try connection.beginImmediate()
        let removable: [ClipClearRow]
        do {
            removable = try ClipRepository.clearRows(connection: connection)
            try FTSRepository.deleteAll(connection: connection)
            try connection.exec("DELETE FROM clip_images")
            try connection.exec("DELETE FROM clips")
            if failAfterDeleteForTesting {
                throw DatabaseError.sql("forced clear failure")
            }
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        if secureErase {
            do {
                try connection.exec("PRAGMA wal_checkpoint(TRUNCATE);")
                try connection.exec("VACUUM;")
            } catch {
                // Rows are already deleted; surface the incomplete secure
                // erase in logs without turning a successful clear into a
                // misleading failure.
                NSLog(
                    "Clipa secure erase post-processing failed: \(error.localizedDescription)"
                )
            }
            // The retired v6 image directory holds a second copy of the same
            // screenshots: the import renames it instead of deleting it so a
            // rollback stays possible. That makes it the one place where
            // "清空历史（安全擦除）" promised the originals were gone while every
            // one of them was still on disk as a plain PNG.
            removeRetiredImageDirectories()
        }
        return removable
    }

    /// Deletes the retired v6 image directories. Secure-erase only: a plain
    /// clear leaves the rollback scaffolding alone, exactly like the rest of the
    /// database's.
    private func removeRetiredImageDirectories() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries
        where entry.lastPathComponent.hasPrefix("images-migrated-v6") {
            do {
                try fileManager.removeItem(at: entry)
                NSLog(
                    "Clipa secure erase removed \(entry.lastPathComponent)"
                )
            } catch {
                NSLog(
                    "Clipa secure erase could not remove "
                        + entry.lastPathComponent + ": "
                        + error.localizedDescription
                )
            }
        }
    }

    /// Loads image bytes on demand. Row-list queries never select blobs, so a
    /// history with many screenshots stays cheap to render.
    func imageData(dbID: Int64) throws -> Data? {
        if let data = try ClipImageRepository.load(
            dbID: dbID,
            connection: connection
        ) {
            return data
        }
        // Transitional fallback: rows the v10 move has not reached yet still
        // carry their bytes inline. Cheap either way — both are key lookups.
        return try inlineImageData(dbID: dbID)
    }

    private func inlineImageData(dbID: Int64) throws -> Data? {
        let sql = "SELECT image_blob FROM clips WHERE db_id = ?"
        return try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return connection.columnData(statement, 0)
        }
    }

    /// Cheap availability probe: never transfers the blob itself.
    func hasImageData(dbID: Int64) throws -> Bool {
        if try ClipImageRepository.hasData(
            dbID: dbID,
            connection: connection
        ) {
            return true
        }
        let sql = """
            SELECT length(image_blob) FROM clips
            WHERE db_id = ? AND image_blob IS NOT NULL
            """
        return try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            if sqlite3_column_type(statement, 0) == SQLITE_NULL { return false }
            return sqlite3_column_int64(statement, 0) > 0
        }
    }

    /// Writes a new row's image bytes. Called inside the same transaction as
    /// the `clips` insert, so a clip never exists without its bytes.
    private func storeImage(_ draft: NewClip, dbID: Int64) throws {
        guard let data = draft.imageData, !data.isEmpty else { return }
        try ClipImageRepository.store(
            dbID: dbID,
            data: data,
            connection: connection
        )
    }

    // MARK: - v10 image storage migration

    struct ClipImageMigrationResult: Equatable {
        let moved: Int
        let remaining: Int
    }

    /// Moves inline image bytes into `clip_images` in bounded batches.
    ///
    /// Each batch is its own transaction, so an interrupted migration resumes
    /// on the next launch: rows already moved have `image_blob` NULL and drop
    /// out of the pending query.
    func migrateClipImages(limit: Int = 20) throws -> ClipImageMigrationResult {
        let ids = try ClipImageRepository.pendingInlineImageIDs(
            connection: connection,
            limit: limit
        )
        guard !ids.isEmpty else {
            return ClipImageMigrationResult(
                moved: 0,
                remaining: try ClipImageRepository.inlineImageCount(
                    connection: connection
                )
            )
        }
        try connection.beginImmediate()
        do {
            for dbID in ids {
                try ClipImageRepository.moveInlineImage(
                    dbID: dbID,
                    connection: connection
                )
            }
            try connection.commit()
        } catch {
            connection.rollback()
            throw error
        }
        return ClipImageMigrationResult(
            moved: ids.count,
            remaining: try ClipImageRepository.inlineImageCount(
                connection: connection
            )
        )
    }

    func clipImagesMigrationPending() throws -> Int {
        try ClipImageRepository.inlineImageCount(connection: connection)
    }

    func clipImagesCompactionDone() throws -> Bool {
        StoreMeta.value(
            forKey: ClipImageRepository.compactedMarkerKey,
            connection: connection
        ) == "1"
    }

    /// Reclaims the space the moved blobs left behind. Worth running once
    /// after the move — a 10GB store drops to roughly its live size, which is
    /// also what makes the scan cheap again.
    func compactAfterImageMigration() throws {
        try connection.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try connection.exec("VACUUM;")
        try StoreMeta.set(
            "1",
            forKey: ClipImageRepository.compactedMarkerKey,
            connection: connection
        )
    }

    func replaceAllForTesting(_ drafts: [NewClip]) throws -> [Clip] {
        try connection.beginImmediate()
        do {
            try FTSRepository.deleteAll(connection: connection)
            try connection.exec("DELETE FROM clip_images")
            try connection.exec("DELETE FROM clips")
            var inserted: [Clip] = []
            for draft in drafts {
                let dbID = try ClipRepository.insert(
                    draft,
                    connection: connection
                )
                try storeImage(draft, dbID: dbID)
                try FTSRepository.insert(
                    rowid: dbID,
                    text: draft.text,
                    note: draft.note,
                    indexed: !draft.isPrivate,
                    connection: connection
                )
                if let clip = try ClipRepository.clip(
                    dbID: dbID,
                    connection: connection
                ) {
                    inserted.append(clip)
                }
            }
            try connection.commit()
            return inserted
        } catch {
            connection.rollback()
            throw error
        }
    }

    func rebuildFTS() throws {
        try FTSRepository.rebuildAndMark(connection: connection)
    }

    /// Marker describing the index build `store_meta` currently vouches for.
    func ftsIndexMarker() throws -> FTSRepository.IndexMarker? {
        FTSRepository.marker(connection: connection)
    }

    /// Re-runs the trust decision without rebuilding, for diagnostics.
    func ftsIndexDecision() throws -> FTSRepository.IndexDecision {
        try FTSRepository.decide(connection: connection)
    }

    /// Full row-by-row comparison of `clips` and `clips_fts`.
    func verifyFTSIndexStrong() throws -> (ok: Bool, detail: String) {
        try FTSRepository.verifyStrong(connection: connection)
    }

    /// Recorded on a clean shutdown so the next launch can tell an unclean
    /// exit apart and run the full verification.
    func markSessionCleanShutdown() throws {
        try FTSRepository.markSessionClean(connection: connection)
    }
}
