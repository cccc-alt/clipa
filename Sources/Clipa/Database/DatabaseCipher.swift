import Foundation
import CSQLCipher

/// One-time plaintext -> SQLCipher migration via sqlcipher_export.
enum DatabaseCipher {

    static func migrateIfPlaintext(path: String, keyExpression: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[FileAttributeKey.size] as? Int64,
              size > 16
        else { return }

        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &raw, flags, nil) == SQLITE_OK, let raw else {
            sqlite3_close(raw)
            return
        }
        let probeOK = sqlite3_exec(
            raw, "SELECT count(*) FROM sqlite_master;", nil, nil, nil
        ) == SQLITE_OK
        sqlite3_close(raw)
        guard probeOK else { return }

        try exportToEncrypted(path: path, keyExpression: keyExpression)
    }

    private static func exportToEncrypted(
        path: String,
        keyExpression: String
    ) throws {
        let fm = FileManager.default
        let tmp = path + ".cipher-migrating"
        let backup = path + ".plain-backup"

        try? fm.removeItem(atPath: tmp)
        try? fm.removeItem(atPath: backup)

        var raw: OpaquePointer?

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &raw, flags, nil) == SQLITE_OK, let raw else {
            let message = raw.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown error"
            sqlite3_close(raw)
            throw DatabaseError.connectionFailed(message)
        }
        defer { sqlite3_close(raw) }

        try exec(raw, "PRAGMA wal_checkpoint(TRUNCATE);")

        let quotedKey = "'" + keyExpression.replacingOccurrences(of: "'", with: "''") + "'"
        try exec(
            raw,
            "ATTACH DATABASE '\(escape(tmp))' AS cipher KEY \(quotedKey);"
        )
        try exec(raw, "SELECT sqlcipher_export('cipher');")
        try exec(raw, "DETACH DATABASE cipher;")

        let wal = path + "-wal"
        let shm = path + "-shm"
        if fm.fileExists(atPath: backup) { try fm.removeItem(atPath: backup) }
        try fm.moveItem(atPath: path, toPath: backup)
        try fm.moveItem(atPath: tmp, toPath: path)

        try? fm.removeItem(atPath: wal)
        try? fm.removeItem(atPath: shm)
        NSLog("Clipa 数据库已加密迁移（明文备份：\((backup as NSString).lastPathComponent)）")
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DatabaseError.sql(message)
        }
    }

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "'", with: "''")
    }
}
