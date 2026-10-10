import Darwin
import Foundation
import CSQLCipher

/// Convert legacy plaintext using a verified sibling file and one atomic rename.
/// No plaintext backup is created; any failure before rename leaves the source.
enum DatabaseCipher {
    private static let plaintextHeader = Data("SQLite format 3\0".utf8)

    static func containsCiphertext(path: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let header = try file.read(upToCount: 16) ?? Data()
        return !header.isEmpty && header != plaintextHeader
    }

    /// Recover the old implementation's crash window between its two moves.
    /// The backup is moved, never discarded, and then follows normal migration.
    static func recoverInterruptedMigration(path: String) throws {
        guard !FileManager.default.fileExists(atPath: path),
              try DatabaseFiles.protectFile(path + ".plain-backup") else { return }
        try FileManager.default.moveItem(atPath: path + ".plain-backup", toPath: path)
    }

    static func migrateIfPlaintext(path: String, keyExpression: String) throws {
        guard FileManager.default.fileExists(atPath: path),
              try !containsCiphertext(path: path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { return }
        try exportToEncrypted(path: path, keyExpression: keyExpression)
    }

    private static func exportToEncrypted(path: String, keyExpression: String) throws {
        let temporary = path + ".cipher-" + UUID().uuidString + ".tmp"
        try DatabaseFiles.protectFile(temporary, create: true)
        defer {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: temporary + suffix)
            }
        }
        var source: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(DatabaseFiles.sqlitePath(path), &source, flags, nil) == SQLITE_OK,
              let source else {
            sqlite3_close(source)
            throw DatabaseError.connectionFailed("无法打开待加密的旧数据库")
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 3000)
        try exec(source, "PRAGMA temp_store = MEMORY;")
        try exec(source, "PRAGMA locking_mode = EXCLUSIVE;")
        // Changing from WAL checkpoints all committed frames and refuses busy
        // readers/writers. EXCLUSIVE mode retains the source lock until close.
        guard try scalarText(source, "PRAGMA journal_mode = DELETE;") == "delete" else {
            throw DatabaseError.migration("旧数据库仍在使用中，请稍后重试")
        }
        try exec(source, "BEGIN EXCLUSIVE; COMMIT;")
        let version = try scalarText(source, "PRAGMA user_version;")
        let applicationID = try scalarText(source, "PRAGMA application_id;")
        var attach: OpaquePointer?
        guard sqlite3_prepare_v2(source, "ATTACH DATABASE ? AS cipher KEY ?;", -1, &attach, nil) == SQLITE_OK,
              let attach else { throw DatabaseError.sql("无法准备加密迁移") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(attach, 1, DatabaseFiles.sqlitePath(temporary), -1, transient)
        sqlite3_bind_text(attach, 2, keyExpression, -1, transient)
        let attached = sqlite3_step(attach)
        sqlite3_finalize(attach)
        guard attached == SQLITE_DONE else { throw DatabaseError.sql("无法创建加密迁移文件") }
        try exec(source, "PRAGMA cipher.synchronous = FULL;")
        try exec(source, "SELECT sqlcipher_export('cipher');")
        // sqlcipher_export copies tables/indexes, but not these header fields.
        try exec(source, "PRAGMA cipher.user_version = \(Int(version) ?? 0);")
        try exec(source, "PRAGMA cipher.application_id = \(Int(applicationID) ?? 0);")
        try exec(source, "DETACH DATABASE cipher;")
        try verify(path: temporary, keyExpression: keyExpression)
        // rename replaces an existing file atomically. There is no interval
        // with a missing main database, and no unencrypted backup left behind.
        guard rename(temporary, path) == 0 else {
            throw DatabaseError.migration("无法原子替换加密数据库（\(errno)）")
        }
    }

    private static func verify(path: String, keyExpression: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(DatabaseFiles.sqlitePath(path), &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw DatabaseError.migration("无法验证加密副本")
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_key(handle, keyExpression, Int32(keyExpression.utf8.count)) == SQLITE_OK,
              try scalarText(handle, "PRAGMA quick_check;") == "ok" else {
            throw DatabaseError.migration("加密副本完整性校验失败")
        }
    }

    private static func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw DatabaseError.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            throw DatabaseError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return String(cString: text)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DatabaseError.sql(message)
        }
    }
}
