import CSQLCipher
import Foundation

enum DatabaseSchema {

    static let currentUserVersion = 12

    static let clipColumns = """
        db_id, id, kind, text, note, image_file, file_urls, source_app,
        created_at, last_copied_at, updated_at,
        is_private, is_hidden, content_hash,
        smart_tag, classification_version, manual_tag, contains_sensitive,
        image_format, source_bundle
        """

    static let clipsTable = clipsTableSQL(named: "clips")

    static func clipsTableSQL(named name: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS \(name) (
            db_id INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            kind INTEGER NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            note TEXT NOT NULL DEFAULT '',
            image_file TEXT,
            file_urls TEXT NOT NULL DEFAULT '[]',
            source_app TEXT,
            created_at REAL NOT NULL,
            last_copied_at REAL,
            updated_at REAL NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            is_private INTEGER NOT NULL DEFAULT 0,
            is_hidden INTEGER NOT NULL DEFAULT 0,
            content_hash TEXT,
            smart_tag TEXT NOT NULL DEFAULT '',
            classification_version INTEGER NOT NULL DEFAULT 0,
            manual_tag TEXT,
            contains_sensitive INTEGER NOT NULL DEFAULT 0,
            image_blob BLOB,
            image_format TEXT NOT NULL DEFAULT '',
            source_bundle TEXT,
            norm_text TEXT,
            norm_note TEXT
        )
        """
    }

    static let clipsIndexes = """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_clips_uuid ON clips(id);
        CREATE INDEX IF NOT EXISTS idx_clips_last_copied
            ON clips(last_copied_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clips_pinned ON clips(is_pinned);
        CREATE INDEX IF NOT EXISTS idx_clips_hidden ON clips(is_hidden);
        CREATE INDEX IF NOT EXISTS idx_clips_kind ON clips(kind);
        CREATE INDEX IF NOT EXISTS idx_clips_hash ON clips(content_hash);
        """

    static let uniqueContentHashIndex = """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_clips_content_hash_kind_unique
        ON clips(content_hash, kind)
        WHERE content_hash IS NOT NULL AND content_hash != ''
        """

    static let dropSupersededContentHashIndex =
        "DROP INDEX IF EXISTS idx_clips_content_hash_unique"

    static let ftsTable = """
        CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts USING fts5(
            text,
            note,
            tokenize='trigram'
        )
        """

    static let storeMetaTable = """
        CREATE TABLE IF NOT EXISTS store_meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        )
        """

    static let clipImagesTable = """
        CREATE TABLE IF NOT EXISTS clip_images (
            clip_id INTEGER PRIMARY KEY
                REFERENCES clips(db_id) ON DELETE CASCADE,
            blob BLOB NOT NULL
        )
        """

}

enum StoreMeta {
    static func value(
        forKey key: String,
        connection: DatabaseConnection
    ) -> String? {
        let sql = "SELECT value FROM store_meta WHERE key = ? LIMIT 1"
        return try? connection.prepare(sql) { statement in
            connection.bindText(statement, 1, key)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return connection.columnText(statement, 0)
        }
    }

    static func set(
        _ value: String,
        forKey key: String,
        connection: DatabaseConnection
    ) throws {
        let sql = "INSERT INTO store_meta (key, value) VALUES (?, ?) "
            + "ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        try connection.prepare(sql) { statement in
            connection.bindText(statement, 1, key)
            connection.bindText(statement, 2, value)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.sql(connection.lastErrorMessage)
            }
        }
    }
}
