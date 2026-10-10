import CSQLCipher
import Foundation

/// Centralized SQL for the v2 persistent store. `clips` and `clips_fts` are
/// always row-aligned: `clips.db_id == clips_fts.rowid`.
enum DatabaseSchema {
    /// v7: image bytes moved into `clips.image_blob`; `image_format` records
    /// the original UTI. The legacy `image_file` column is migrated and
    /// cleared, then left in place for one release so an older build can
    /// still open the database.
    ///
    /// v8: snippets moved out of `snippets.json` into the `snippets` table, so
    /// the store is a single transactional unit. `store_meta` carries the
    /// one-time import marker.
    ///
    /// v9: `norm_text` / `norm_note` hold `QueryNormalizer` output so the SQL
    /// fast path can run the substring predicate in C. They are NULL until the
    /// one-time backfill runs; a NULL row disables the fast path.
    ///
    /// v10: image bytes moved out of `clips` into `clip_images`. An inline
    /// blob makes SQLite walk the row's overflow chain to reach the next row,
    /// so every scan of `clips` touched the whole file — a 10GB library cost
    /// 6.1s to read 103k rows instead of 0.34s. The bytes stay in the same
    /// database file, so a transaction, a backup or a restore still covers
    /// clips and their images together. The old `image_blob` column stays for
    /// one release: a downgraded build opens the database and reports those
    /// clips as missing their image instead of failing.
    ///
    /// v11: duplicate detection is keyed by `(content_hash, kind)`, and the
    /// tables the removed AI search features left behind are dropped. Both are
    /// one-time steps, and `MigrationManager` runs them only while the stored
    /// version is behind this one — which is exactly why the number has to move:
    /// a store that already reads 10 would otherwise never run them, the way
    /// `search_learning` survived an upgrade during this change's own
    /// end-to-end check.
    ///
    /// v12: private clips are encrypted at rest (`StoreCrypto`): `text` / `note`
    /// hold AES-GCM ciphertext and their index copies (`norm_text` / `norm_note`
    /// / `clips_fts`) are blanked, because those two columns are a *second*
    /// plaintext copy of the same body. The step itself is gated on a
    /// `store_meta` marker rather than on this number: it has to stay
    /// idempotent and retryable, since it can legitimately fail (the keychain
    /// key is unavailable) and must never leave the store unopenable. The number
    /// moves anyway so an older build cannot mistake an encrypted store for one
    /// it understands — and `clips.text` for those rows no longer holds anything
    /// that build could show.
    // v13: workspace-local collections and memberships, inside SQLCipher.
    static let currentUserVersion = 13

    static let collectionsTables = """
        CREATE TABLE IF NOT EXISTS clip_collections (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            name_key TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS clip_collection_members (
            collection_id TEXT NOT NULL REFERENCES clip_collections(id) ON DELETE CASCADE,
            clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
            PRIMARY KEY(collection_id, clip_id)
        );
        CREATE INDEX IF NOT EXISTS idx_collection_clip ON clip_collection_members(clip_id);
        """

    // The select column list must stay in sync with ClipRepository.clip(from:).
    // content_hash 13, smart_tag 14,
    // classification_version 15, manual_tag 16, contains_sensitive 17,
    // image_format 18, source_bundle 19.
    // `image_blob` is deliberately excluded (list queries must never pull image
    // bytes), and so is the retired `is_pinned` flag: the column stays in the
    // table so an older build can still open this database, but nothing reads it.
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

    /// Application-level duplicate guarantee. App code serializes writes, but
    /// the unique index protects the store from legacy/corrupt duplicates.
    ///
    /// Keyed on `(content_hash, kind)`, not on the hash alone. A text copy of
    /// `/Users/x/report.pdf` and the Finder copy of that same file hash
    /// identically — the file hash *is* the hash of its path list — so a
    /// hash-only key folded the text copy into the existing file row: the user's
    /// copy produced no new entry and the file card silently came back to the
    /// front instead.
    static let uniqueContentHashIndex = """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_clips_content_hash_kind_unique
        ON clips(content_hash, kind)
        WHERE content_hash IS NOT NULL AND content_hash != ''
        """

    /// The hash-only index `uniqueContentHashIndex` superseded. Dropped on
    /// upgrade: it would reject the very rows the wider key now allows.
    static let dropSupersededContentHashIndex =
        "DROP INDEX IF EXISTS idx_clips_content_hash_unique"

    static let ftsTable = """
        CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts USING fts5(
            text,
            note,
            tokenize='trigram'
        )
        """

    // `rebuildFTS` (raw text, no normalization) and `searchLearningTable` are
    // gone: the first was an unused alternative to `FTSRepository.rebuild` that
    // would have indexed un-normalized text, the second belonged to the removed
    // AI search feature. Existing stores get the table dropped by
    // `dropRemovedSearchFeatureTables`.

    static let storeMetaTable = """
        CREATE TABLE IF NOT EXISTS store_meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        )
        """

    /// 1:1 companion table for image bytes (v10).
    ///
    /// `ON DELETE CASCADE` keeps `clip_images` in step with `clips` even for
    /// the bulk deletes in "clear history"; `foreign_keys` is enabled on every
    /// connection, and the code paths delete explicitly as well so a store
    /// opened without enforcement cannot leak orphan bytes.
    static let clipImagesTable = """
        CREATE TABLE IF NOT EXISTS clip_images (
            clip_id INTEGER PRIMARY KEY
                REFERENCES clips(db_id) ON DELETE CASCADE,
            blob BLOB NOT NULL
        )
        """

}

/// `StoreMeta`：一次性迁移标记的 key/value 读写（原在 SnippetRepository.swift，
/// 2026-10-02 snippets 模块删除后迁到这里——它被搜索归一化指纹、迁移标记
/// 共用，与 snippets 无关）。
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
