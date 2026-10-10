import Foundation
import CSQLCipher

enum DatabaseError: LocalizedError {
    case connectionFailed(String)
    case sql(String)
    case missingRow
    /// Schema upgrade failed. Distinct from the others because the file itself
    /// is usually intact — the store is mid-migration, not damaged, so the UI
    /// can offer a retry instead of a repair.
    case migration(String)
    /// 私密条目解密失败（钥匙串暂不可用 / ACL 未批准）。行本身完好——密文就在
    /// 盘上——所以调用方必须**拒绝写回**、保持原样，而不是把读出来的空串当成
    /// 内容写回去（那会把密文永久覆盖）。
    case decryptionUnavailable
    /// 捕获条目横跨了一次"清空历史"。这条是**拒绝**而非错误：条目属于清空前的
    /// 世代，写入它会残留一条用户刚删掉的历史。
    case historyClearInProgress
    /// 整库加密密钥拿不到（钥匙串暂不可用）。库本身完好，重试即可。
    case databaseKeyUnavailable
    /// 带密钥打开后读不出 schema：密钥不匹配或文件损坏。**不可恢复**——
    /// 交给"数据库不可用"恢复态，绝不能当成空库新建覆盖。
    case databaseKeyMismatch

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "SQLite 打开失败：\(message)"
        case .sql(let message):
            return "SQLite 错误：\(message)"
        case .missingRow:
            return "SQLite 记录不存在"
        case .migration(let message):
            return "数据库升级未完成：\(message)"
        case .decryptionUnavailable:
            return "解密失败：钥匙串暂不可用，条目保持原样，请稍后重试"
        case .historyClearInProgress:
            return "正在清空历史，本次捕获被拒绝"
        case .databaseKeyUnavailable:
            return "数据库密钥不可用：钥匙串暂不可用，请稍后重试"
        case .databaseKeyMismatch:
            return "数据库无法解密：密钥不匹配或文件已损坏"
        }
    }
}

/// Low-level SQLite handle plus tiny helpers. All callers must serialize
/// access (DatabaseManager owns a dedicated serial queue), and the handle is
/// opened with SQLITE_OPEN_FULLMUTEX as an extra safety net.
final class DatabaseConnection {
    private var db: OpaquePointer?
    private struct CachedStatement {
        let handle: OpaquePointer
        let lastUse: UInt64
        let bytes: Int
    }
    private var statements: [String: CachedStatement] = [:]
    private var statementClock: UInt64 = 0
    private let statementCapacity = 48
    private var statementBytes = 0
    private let statementByteLimit = 512 * 1024

    var statementCacheUsage: (count: Int, bytes: Int) {
        (statements.count, statementBytes)
    }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(
        path: String,
        keyProvider: (String, Bool) -> String? = {
            DBKey.rawKeyExpression(databasePath: $0, createIfMissing: $1)
        }
    ) throws {
        try DatabaseFiles.protectDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        let openLock = try DatabaseFiles.lockOpen(path)
        defer { DatabaseFiles.unlockOpen(openLock) }
        try DatabaseFiles.protectDatabase(path)
        try DatabaseCipher.recoverInterruptedMigration(path: path)
        let needsExistingKey = try DatabaseCipher.containsCiphertext(path: path)
        guard let key = keyProvider(path, !needsExistingKey) else {
            throw DatabaseError.databaseKeyUnavailable
        }
        guard key.hasPrefix("x'"), key.hasSuffix("'"),
              DBKey.isValidHexKey(String(key.dropFirst(2).dropLast())) else {
            throw DatabaseError.databaseKeyUnavailable
        }
        // Encryption is mandatory. Migration failure must never open a writable
        // plaintext connection, and key failure must never create a new database.
        do {
            try DatabaseCipher.migrateIfPlaintext(path: path, keyExpression: key)
        } catch {
            throw DatabaseError.migration(error.localizedDescription)
        }
        try DatabaseFiles.protectFile(path, create: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(DatabaseFiles.sqlitePath(path), &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw DatabaseError.connectionFailed(message)
        }
        do {
            guard sqlite3_key(handle, key, Int32(key.utf8.count)) == SQLITE_OK,
                  sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.databaseKeyMismatch
            }
            // Older builds left a plaintext safety copy. Preserve its contents,
            // but encrypt it in place with the same workspace key.
            try DatabaseCipher.migrateIfPlaintext(
                path: path + ".plain-backup", keyExpression: key
            )
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        db = handle
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { close() }

    /// Closes the handle now. Every entry point above checks for a nil handle
    /// and reports "not open" instead of touching a freed pointer.
    ///
    /// Uses `sqlite3_close_v2` on purpose: it never fails, it turns the handle
    /// into a zombie that is reaped once the last statement is finalized. The
    /// plain `sqlite3_close` returns `SQLITE_BUSY` and leaves the handle *open*
    /// when a statement is still live — which is how a second connection to the
    /// same file survived a "close".
    func close() {
        guard let handle = db else { return }
        db = nil
        for entry in statements.values { sqlite3_finalize(entry.handle) }
        statements.removeAll()
        statementBytes = 0
        sqlite3_close_v2(handle)
    }

    func configure() throws {
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA temp_store = MEMORY;")
        try exec("PRAGMA cache_size = -2048;")
        try exec("PRAGMA journal_size_limit = 8388608;")
        try exec("PRAGMA secure_delete = ON;")
    }

    /// 把"刚刚离开页面的内容"从文件里赶出去。
    ///
    /// 只做 `UPDATE` 是不够的：旧的正文可能还留在空闲页里，而 WAL 里存着**改之前**
    /// 的整页镜像——只看主文件会以为已经擦干净了。顺序与"清空历史（安全擦除）"一致：
    /// `secure_delete` 让释放的内容填零 → 检查点截断 WAL → `VACUUM` 重建主文件。
    ///
    /// `VACUUM` 不能在事务里执行，必须在提交之后调用；库很大时它会有可感知的停顿，
    /// 所以只用在两个低频动作上：M3 迁移、以及"设为私密"的切换。
    func purgeFreedContent() throws {
        try exec("PRAGMA secure_delete = ON;")
        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try exec("VACUUM;")
    }

    var lastErrorMessage: String {
        guard let db else { return "no connection" }
        return String(cString: sqlite3_errmsg(db))
    }

    func exec(_ sql: String) throws {
        guard let db else { throw DatabaseError.connectionFailed("not open") }
        var error: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage
            if let error { sqlite3_free(error) }
            throw DatabaseError.sql(message)
        }
    }

    func prepare<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw DatabaseError.connectionFailed("not open") }
        let statement: OpaquePointer
        // Check out the handle so nested calls using the same SQL get their
        // own statement. Bound values are always cleared before returning it.
        if let cached = statements.removeValue(forKey: sql) {
            statement = cached.handle
            statementBytes -= cached.bytes
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil) == SQLITE_OK,
                  let prepared else {
                sqlite3_finalize(prepared)
                throw DatabaseError.sql(lastErrorMessage)
            }
            statement = prepared
        }
        defer {
            let status = sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            // Never retain failed statements, huge generated queries or a
            // zombie handle closed by a nested call.
            let bytes = Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_MEMUSED, 0))
            if self.db == db, status == SQLITE_OK, sql.utf8.count <= 16_384, bytes <= 64 * 1024 {
                if let nested = statements.removeValue(forKey: sql) {
                    statementBytes -= nested.bytes
                    sqlite3_finalize(nested.handle)
                }
                while statements.count >= statementCapacity || statementBytes + bytes > statementByteLimit {
                    guard let oldest = statements.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
                    statementBytes -= oldest.value.bytes
                    sqlite3_finalize(oldest.value.handle)
                    statements.removeValue(forKey: oldest.key)
                }
                statementClock &+= 1
                statements[sql] = CachedStatement(handle: statement, lastUse: statementClock, bytes: bytes)
                statementBytes += bytes
            } else {
                sqlite3_finalize(statement)
            }
        }
        return try body(statement)
    }

    /// Only read-only search operations install this handler. Cancellation
    /// cannot interrupt clipboard writes or migrations on the same connection.
    func withCancellableRead<T>(_ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        guard let db else { throw DatabaseError.connectionFailed("not open") }
        sqlite3_progress_handler(db, 1000, { _ in
            Task<Never, Never>.isCancelled ? 1 : 0
        }, nil)
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        do {
            let result = try body()
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    func beginImmediate() throws {
        try exec("BEGIN IMMEDIATE")
    }

    func commit() throws {
        try exec("COMMIT")
    }

    func rollback() {
        try? exec("ROLLBACK")
    }

    func lastInsertRowID() -> Int64 {
        guard let db else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    func userVersion() -> Int {
        (try? scalarInt("PRAGMA user_version;")) ?? 0
    }

    func setUserVersion(_ version: Int) {
        try? exec("PRAGMA user_version = \(version);")
    }

    func scalarInt(_ sql: String) throws -> Int {
        try prepare(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.sql(lastErrorMessage)
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func rowCount(in table: String) throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM \(table)")
    }

    func hasTable(_ name: String) -> Bool {
        let sql = """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type IN ('table', 'view') AND name = ?
            """
        do {
            return try prepare(sql) { statement in
                sqlite3_bind_text(statement, 1, name, -1, transient)
                guard sqlite3_step(statement) == SQLITE_ROW else { return false }
                return sqlite3_column_int(statement, 0) != 0
            }
        } catch {
            return false
        }
    }

    /// Like `hasTable`, but a failed query is reported as an error instead of
    /// being folded into "no".
    ///
    /// The forgiving version is right for a cheap gate, and wrong for anything
    /// that then *writes*: a `hasColumn` that answered "no" because the query
    /// failed made the migration run `ALTER TABLE ADD COLUMN` for a column that
    /// already existed — "duplicate column name" — and from then on every
    /// launch failed the same way, with the database reported as unopenable.
    func requireTable(_ name: String) throws -> Bool {
        let sql = """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type IN ('table', 'view') AND name = ?
            """
        return try prepare(sql) { statement in
            sqlite3_bind_text(statement, 1, name, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    /// Strict counterpart of `hasColumn`; see `requireTable`.
    func requireColumn(table: String, column: String) throws -> Bool {
        try prepare("PRAGMA table_info(\(table));") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = sqlite3_column_text(statement, 1)
                    .map { String(cString: $0) } ?? ""
                if name == column { return true }
            }
            return false
        }
    }

    func hasColumn(table: String, column: String) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        do {
            return try prepare(sql) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    let name = sqlite3_column_text(statement, 1)
                        .map { String(cString: $0) } ?? ""
                    if name == column { return true }
                }
                return false
            }
        } catch {
            return false
        }
    }

    func columnType(table: String, column: String) -> String? {
        let sql = "PRAGMA table_info(\(table));"
        do {
            return try prepare(sql) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    let name = sqlite3_column_text(statement, 1)
                        .map { String(cString: $0) } ?? ""
                    if name == column {
                        return sqlite3_column_text(statement, 2)
                            .map { String(cString: $0) }
                    }
                }
                return nil
            }
        } catch {
            return nil
        }
    }

    func ftsColumnList(for table: String) -> String? {
        let sql = "SELECT sql FROM sqlite_master WHERE name = ? AND type = 'table';"
        do {
            return try prepare(sql) { statement in
                sqlite3_bind_text(statement, 1, table, -1, transient)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return sqlite3_column_text(statement, 0)
                    .map { String(cString: $0) }
            }
        } catch {
            return nil
        }
    }
}

// MARK: - SQLite value helpers

extension DatabaseConnection {
    func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        // The byte length is passed explicitly. With `-1` SQLite reads up to the
        // first NUL byte, so any string containing U+0000 was silently
        // truncated on the way into the database — and came back shorter than
        // the clip the user copied.
        guard !value.isEmpty else {
            // An empty Swift string must bind as an empty *string*, not as
            // NULL: several predicates distinguish the two.
            _ = sqlite3_bind_text(statement, index, "", 0, transient)
            return
        }
        // withCString borrows contiguous UTF-8 storage; an explicit length
        // preserves embedded NULs without allocating an extra byte array.
        value.withCString { pointer in
            _ = sqlite3_bind_text(statement, index, pointer, Int32(value.utf8.count), transient)
        }
    }

    func bindDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }

    /// Binds image bytes. `SQLITE_TRANSIENT` copies the buffer, so the
    /// closure-scoped pointer is safe.
    func bindData(_ statement: OpaquePointer, _ index: Int32, _ value: Data?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                statement,
                index,
                buffer.baseAddress,
                Int32(buffer.count),
                transient
            )
        }
    }

    func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }

    /// Decodes a TEXT column by its *byte length* instead of scanning for a NUL.
    ///
    /// `String(cString:)` stops at the first U+0000, so a clip whose text
    /// contained an embedded NUL came back shorter than it went in — the read
    /// half of the same truncation `bindText` had on the write half.
    static func decodeText(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return "" }
        return String(
            decoding: UnsafeRawBufferPointer(start: pointer, count: count),
            as: UTF8.self
        )
    }

    func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        Self.decodeText(statement, index)
    }

    func columnString(_ statement: OpaquePointer, _ index: Int32) -> String {
        columnText(statement, index) ?? ""
    }

    func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }
}

func clipTimestamp(_ date: Date) -> Double {
    date.timeIntervalSince1970
}
