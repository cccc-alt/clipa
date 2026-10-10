import Foundation
import CSQLCipher

/// Image bytes for image clips.
///
/// They live in `clip_images`, keyed by the owning `clips.db_id`, instead of
/// inline in `clips`. Inline blobs made every scan of `clips` walk the whole
/// file — SQLite follows each row's overflow chain to reach the next row — so
/// loading the row list of a 10GB library cost 6.1s instead of 0.34s. Keeping
/// the bytes in the same database file (just another table) preserves the
/// single-transaction / single-backup property.
enum ClipImageRepository {
    /// Set once every inline blob has been moved.
    /// Set once the file has been compacted after the move.
    static let compactedMarkerKey = "images.compacted_after_move"

    static func store(
        dbID: Int64,
        data: Data,
        connection: DatabaseConnection
    ) throws {
        let sql = "INSERT OR REPLACE INTO clip_images (clip_id, blob) VALUES (?, ?)"
        try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            connection.bindData(statement, 2, data)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    static func load(
        dbID: Int64,
        connection: DatabaseConnection
    ) throws -> Data? {
        let sql = "SELECT blob FROM clip_images WHERE clip_id = ?"
        return try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return connection.columnData(statement, 0)
        }
    }

    /// Cheap availability probe: never transfers the blob itself.
    static func hasData(
        dbID: Int64,
        connection: DatabaseConnection
    ) throws -> Bool {
        let sql = "SELECT 1 FROM clip_images WHERE clip_id = ? LIMIT 1"
        return try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    static func delete(
        dbID: Int64,
        connection: DatabaseConnection
    ) throws {
        let sql = "DELETE FROM clip_images WHERE clip_id = ?"
        try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }

    // MARK: - v10 move

    /// Image rows whose bytes are still inline in `clips`.
    ///
    /// `kind = 3` is what keeps this cheap: the kind index visits only image
    /// rows instead of walking the whole (multi-gigabyte) table.
    static func pendingInlineImageIDs(
        connection: DatabaseConnection,
        limit: Int
    ) throws -> [Int64] {
        let sql = """
            SELECT db_id FROM clips
            WHERE kind = 3
              AND image_blob IS NOT NULL
              AND length(image_blob) > 0
            ORDER BY db_id ASC
            LIMIT ?
            """
        return try connection.prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, Int64(limit))
            var ids: [Int64] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(statement, 0))
            }
            return ids
        }
    }

    static func inlineImageCount(
        connection: DatabaseConnection
    ) throws -> Int {
        let sql = """
            SELECT COUNT(*) FROM clips
            WHERE kind = 3
              AND image_blob IS NOT NULL
              AND length(image_blob) > 0
            """
        return try connection.scalarInt(sql)
    }

    /// Copies one row's bytes into `clip_images` and clears the inline column
    /// so the row is never processed twice.
    ///
    /// The copy happens inside SQLite (`INSERT ... SELECT`), so a 20MB image
    /// never becomes a 20MB Swift `Data` on the way across.
    static func moveInlineImage(
        dbID: Int64,
        connection: DatabaseConnection
    ) throws {
        let copy = """
            INSERT OR REPLACE INTO clip_images (clip_id, blob)
            SELECT db_id, image_blob FROM clips
            WHERE db_id = ? AND image_blob IS NOT NULL
            """
        try connection.prepare(copy) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
        let clear = "UPDATE clips SET image_blob = NULL WHERE db_id = ?"
        try connection.prepare(clear) { statement in
            sqlite3_bind_int64(statement, 1, dbID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }
}
