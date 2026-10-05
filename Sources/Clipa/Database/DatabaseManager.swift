import Foundation
import CSQLCipher
import UniformTypeIdentifiers

struct ClipWriteResult {
    let clip: Clip

    let inserted: Bool
}

actor DatabaseManager {

    nonisolated let databaseExecutor = DatabaseExecutor()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        databaseExecutor.asUnownedSerialExecutor()
    }

    private let connection: DatabaseConnection
    let baseDirectory: URL

    private(set) var searchNormalizationReady = false

    static let databaseFileName = "clips.sqlite"

    static func databaseURL(in baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(databaseFileName)
    }

    init(baseDirectory: URL) throws {
        self.baseDirectory = baseDirectory
        let databaseURL = Self.databaseURL(in: baseDirectory)
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
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
            try migration.migrateIfNeeded()
        } catch {

            throw DatabaseError.migration(String(describing: error))
        }
        searchNormalizationReady = SearchRepository.isNormalizationComplete(
            connection: connection
        )
    }

    func invalidate() {
        connection.close()
    }

    func secureDeleteMode() throws -> Int {
        try connection.scalarInt("PRAGMA secure_delete;")
    }

    struct LegacyImageImportResult: Equatable {
        let migrated: Int
        let missing: Int
        let remaining: Int
    }

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

        var prepared: [(dbID: Int64, data: Data?, format: String)] = []
        for row in rows {
            guard let fileName = row.fileName,
                  Self.isSafeImageFileName(fileName) else {
                prepared.append((row.dbID, nil, ""))
                continue
            }

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

    private static func legacyImageFormat(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext) else {
            return UTType.png.identifier
        }
        return type.identifier
    }

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
        try FTSRepository.candidateIDs(
            query: query,
            maxCount: maxCount,
            connection: connection
        )
    }

    func ftsCount() throws -> Int {
        try FTSRepository.count(connection: connection)
    }

    func searchMatches(
        criteria: SearchCriteria,
        terms: [String],
        phrase: String?
    ) throws -> [TermMatchRow]? {
        guard searchNormalizationReady else { return nil }

        let groupTermCount = criteria.groups.reduce(0) { $0 + $1.count }
        guard groupTermCount == terms.count else { return nil }
        return try SearchRepository.exactMatches(
            criteria: criteria,
            terms: terms,
            phrase: phrase,
            connection: connection
        )
    }

    func searchCandidateIDs(
        criteria: SearchCriteria
    ) throws -> [Int64]? {
        guard searchNormalizationReady else { return nil }
        return try SearchRepository.exactCandidateIDs(
            criteria: criteria,
            connection: connection
        )
    }

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

    func reclassifyPending(limit: Int = 200) throws -> Int {
        let pending = try ClipRepository.pendingReclassification(
            connection: connection,
            limit: limit
        )
        guard !pending.isEmpty else { return 0 }

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

    func storedBodyForTesting(dbID: Int64) throws -> String? {
        try connection.prepare("SELECT text FROM clips WHERE db_id = ?") {
            statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return DatabaseConnection.sharedColumnText(statement, 0)
        }
    }

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

    func updatePrivate(dbID: Int64, isPrivate: Bool) throws -> Clip? {

        guard let current = try ClipRepository.clip(
            dbID: dbID,
            connection: connection
        ) else {
            throw DatabaseError.missingRow
        }
        guard current.isPrivate != isPrivate else {
            return current
        }

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

            if current.kind == .image {
                let raw = try ClipImageRepository.load(
                    dbID: dbID,
                    connection: connection
                ) ?? inlineImageData(dbID: dbID)
                if let raw {

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

    func clearAll(
        secureErase: Bool,
        failAfterDeleteForTesting: Bool = false
    ) throws -> [ClipClearRow] {

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

                NSLog(
                    "Clipa secure erase post-processing failed: \(error.localizedDescription)"
                )
            }

            removeRetiredImageDirectories()
        }
        return removable
    }

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

    func imageData(dbID: Int64) throws -> Data? {
        if let data = try ClipImageRepository.load(
            dbID: dbID,
            connection: connection
        ) {
            return data
        }

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

    private func storeImage(_ draft: NewClip, dbID: Int64) throws {
        guard let data = draft.imageData, !data.isEmpty else { return }
        try ClipImageRepository.store(
            dbID: dbID,
            data: data,
            connection: connection
        )
    }

    struct ClipImageMigrationResult: Equatable {
        let moved: Int
        let remaining: Int
    }

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

    func ftsIndexMarker() throws -> FTSRepository.IndexMarker? {
        FTSRepository.marker(connection: connection)
    }

    func ftsIndexDecision() throws -> FTSRepository.IndexDecision {
        try FTSRepository.decide(connection: connection)
    }

    func verifyFTSIndexStrong() throws -> (ok: Bool, detail: String) {
        try FTSRepository.verifyStrong(connection: connection)
    }

    func markSessionCleanShutdown() throws {
        try FTSRepository.markSessionClean(connection: connection)
    }
}
