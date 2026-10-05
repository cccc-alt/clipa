import Foundation
import CSQLCipher

enum DatabaseError: LocalizedError {
    case connectionFailed(String)
    case sql(String)
    case missingRow

    case migration(String)

    case decryptionUnavailable

    case historyClearInProgress

    case databaseKeyUnavailable

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

final class DatabaseConnection {
    private var db: OpaquePointer?

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Opens the workspace database with its SQLCipher key; one-time
/// plaintext migration happens here.
    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX

        let key = DBKey.rawKeyExpression(databasePath: path)
        var plaintextFallback = (key == nil)
        if let key {
            do {
                try DatabaseCipher.migrateIfPlaintext(
                    path: path,
                    keyExpression: key
                )
            } catch {
                NSLog("Clipa 数据库加密迁移失败（本次保持明文）：\(error.localizedDescription)")
                plaintextFallback = true
            }
        }

        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown error"
            sqlite3_close(handle)
            throw DatabaseError.connectionFailed(message)
        }
        db = handle
        if let key, !plaintextFallback {
            sqlite3_key(handle, key, Int32(key.utf8.count))
        }

        if !plaintextFallback {
            if sqlite3_exec(
                handle, "SELECT count(*) FROM sqlite_master;", nil, nil, nil
            ) != SQLITE_OK {
                let message = String(cString: sqlite3_errmsg(handle))
                NSLog("Clipa DBG 加密库探针失败：\(message)")
                sqlite3_close_v2(handle)
                db = nil
                throw DatabaseError.databaseKeyMismatch
            }
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit {
        sqlite3_close(db)
    }

    func close() {
        guard let handle = db else { return }
        db = nil
        sqlite3_close_v2(handle)
    }

    func configure() throws {
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
    }

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
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw DatabaseError.sql(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
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

extension DatabaseConnection {
    func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        guard !value.isEmpty else {

            _ = sqlite3_bind_text(statement, index, "", 0, transient)
            return
        }
        var bytes = Array(value.utf8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            _ = sqlite3_bind_text(
                statement,
                index,
                buffer.baseAddress,
                Int32(buffer.count),
                transient
            )
        }
    }

    func bindDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }

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
