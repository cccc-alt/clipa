import Darwin
import Foundation
import CSQLCipher

/// Isolated checks for encryption failures, bounded search and socket I/O.
enum StorageSearchProbe {
    @MainActor
    static func run() async -> Int32 {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1 }
            print("[\(condition ? "PASS" : "FAIL")] \(name)")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipaStorageProbe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "x'" + String(repeating: "a1", count: 32) + "'"
        let otherKey = "x'" + String(repeating: "b2", count: 32) + "'"
        func path(_ name: String) -> String { root.appendingPathComponent(name).path }
        func open(_ name: String) throws -> DatabaseConnection {
            try DatabaseConnection(path: path(name), keyProvider: { _, _ in key })
        }
        func bytes(_ name: String) throws -> Data {
            try Data(contentsOf: URL(fileURLWithPath: path(name)))
        }
        func plaintext(_ name: String, wal: Bool = false) throws -> OpaquePointer {
            try DatabaseFiles.protectDirectory(root)
            var raw: OpaquePointer?
            guard sqlite3_open(path(name), &raw) == SQLITE_OK, let raw else {
                throw DatabaseError.connectionFailed("fixture")
            }
            let sql = """
                PRAGMA journal_mode = \(wal ? "WAL" : "DELETE");
                PRAGMA user_version = 12;
                PRAGMA application_id = 1234;
                CREATE TABLE payload (id INTEGER PRIMARY KEY, body TEXT, image BLOB);
                INSERT INTO payload VALUES (1, '迁移 sentinel', x'001122334455');
                CREATE VIRTUAL TABLE search USING fts5(body, tokenize='trigram');
                INSERT INTO search VALUES ('migration sentinel');
                """
            guard sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(raw)
                throw DatabaseError.sql("fixture")
            }
            return raw
        }
        do {
            do {
                _ = try DatabaseConnection(path: path("missing.sqlite"), keyProvider: { _, _ in nil })
                check(false, "missing key rejects writes")
            } catch DatabaseError.databaseKeyUnavailable {
                check(!FileManager.default.fileExists(atPath: path("missing.sqlite")), "missing key creates no database")
            }
            do {
                _ = try DatabaseConnection(path: path("invalid.sqlite"), keyProvider: { _, _ in "x'broken'" })
                check(false, "invalid key rejects writes")
            } catch DatabaseError.databaseKeyUnavailable {
                check(!FileManager.default.fileExists(atPath: path("invalid.sqlite")), "invalid key creates no database")
            }
            let encrypted = try open("encrypted.sqlite")
            try encrypted.configure()
            try encrypted.exec("CREATE TABLE payload (body TEXT); INSERT INTO payload VALUES ('unique-sensitive-marker');")
            let directoryMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
            check(directoryMode?.intValue == 0o700, "data directory is 0700")
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: path("encrypted.sqlite") + suffix)
                check(OwnerOnlyFile.isOwnerOnly(at: url), "database\(suffix) is owner-only")
                let data = try Data(contentsOf: url)
                check(data.range(of: Data("unique-sensitive-marker".utf8)) == nil, "database\(suffix) contains no plaintext marker")
            }
            encrypted.close()
            let before = try bytes("encrypted.sqlite")
            var allowedCreation = true
            do {
                _ = try DatabaseConnection(path: path("encrypted.sqlite"), keyProvider: { _, create in
                    allowedCreation = create
                    return nil
                })
                check(false, "ciphertext with missing key fails closed")
            } catch DatabaseError.databaseKeyUnavailable {
                let after = try bytes("encrypted.sqlite")
                check(!allowedCreation && after == before, "ciphertext key cannot be regenerated and file stays intact")
            }
            do {
                _ = try DatabaseConnection(path: path("encrypted.sqlite"), keyProvider: { _, _ in otherKey })
                check(false, "wrong key is rejected")
            } catch DatabaseError.databaseKeyMismatch {
                check(try bytes("encrypted.sqlite") == before, "wrong key leaves ciphertext intact")
            }
            let raw = try plaintext("legacy.sqlite", wal: true)
            sqlite3_exec(raw, "BEGIN; SELECT * FROM payload;", nil, nil, nil)
            do {
                _ = try open("legacy.sqlite")
                check(false, "busy plaintext migration refuses fallback")
            } catch DatabaseError.migration {
                check(true, "busy plaintext migration refuses fallback")
            }
            sqlite3_exec(raw, "COMMIT;", nil, nil, nil)
            sqlite3_close(raw)
            let migrated = try open("legacy.sqlite")
            check(try migrated.scalarInt("PRAGMA user_version;") == 12, "migration preserves schema version")
            check(try migrated.scalarInt("PRAGMA application_id;") == 1234, "migration preserves application id")
            check(try migrated.scalarInt("SELECT COUNT(*) FROM payload WHERE body='迁移 sentinel' AND image=x'001122334455';") == 1, "migration preserves text and image bytes")
            check(try migrated.scalarInt("SELECT COUNT(*) FROM search WHERE search MATCH 'sentinel';") == 1, "migration preserves FTS search")
            migrated.close()
            check(try DatabaseCipher.containsCiphertext(path: path("legacy.sqlite")), "migrated file is encrypted")
            check(!FileManager.default.fileExists(atPath: path("legacy.sqlite.plain-backup")), "migration creates no plaintext backup")

            sqlite3_close(try plaintext("legacy.sqlite.plain-backup"))
            let reopened = try open("legacy.sqlite")
            reopened.close()
            let archived = try open("legacy.sqlite.plain-backup")
            check(try archived.scalarInt("SELECT COUNT(*) FROM payload;") == 1, "old backup is preserved as readable ciphertext")
            archived.close()
            check(try DatabaseCipher.containsCiphertext(path: path("legacy.sqlite.plain-backup")), "old backup no longer leaks plaintext")

            sqlite3_close(try plaintext("recovered.sqlite.plain-backup"))
            let recovered = try open("recovered.sqlite")
            check(try recovered.scalarInt("SELECT COUNT(*) FROM payload;") == 1, "interrupted old migration recovers the original data")
            recovered.close()

            let corrupt = Data("SQLite format 3\0".utf8) + Data(repeating: 0xff, count: 2048)
            try corrupt.write(to: URL(fileURLWithPath: path("corrupt.sqlite")))
            do {
                _ = try open("corrupt.sqlite")
                check(false, "invalid migration source rejects open")
            } catch {
                check(try bytes("corrupt.sqlite") == corrupt, "failed migration preserves original bytes")
            }
            check(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains(".cipher-") }, "failed migration cleans temporary files")

            try FileManager.default.createSymbolicLink(atPath: path("link.sqlite"), withDestinationPath: path("encrypted.sqlite"))
            do {
                _ = try open("link.sqlite")
                check(false, "symlink database rejected")
            } catch { check(try bytes("encrypted.sqlite") == before, "symlink rejected without changing target") }

            let db = try open("cache.sqlite")
            defer { db.close() }
            let query = "SELECT ?, ?"
            try db.prepare(query) { statement in
                db.bindText(statement, 1, "hello\0世界")
                db.bindText(statement, 2, "must-not-be-retained")
                check(sqlite3_step(statement) == SQLITE_ROW && db.columnText(statement, 0) == "hello\0世界", "binding preserves NUL and Unicode")
            }
            try db.prepare(query) { statement in
                db.bindText(statement, 1, "new")
                check(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_type(statement, 1) == SQLITE_NULL, "statement reuse clears all bound values")
                try db.prepare(query) { inner in
                    db.bindText(inner, 1, "inner")
                    check(sqlite3_step(inner) == SQLITE_ROW && db.columnText(inner, 0) == "inner", "nested query uses an independent statement")
                }
                check(db.columnText(statement, 0) == "new", "nested query does not overwrite outer row")
            }
            try db.exec("CREATE TABLE changing (id INTEGER PRIMARY KEY);")
            _ = try db.scalarInt("SELECT count(*) FROM changing;")
            try db.exec("ALTER TABLE changing ADD COLUMN body TEXT; INSERT INTO changing VALUES(1, 'a');")
            check(try db.scalarInt("SELECT count(*) FROM changing;") == 1, "cached query recompiles after schema changes")
            for i in 0..<150 { _ = try db.scalarInt("SELECT \(i)") }
            check(try db.scalarInt("SELECT count(*) FROM changing;") == 1, "query remains correct after cache eviction")
            check(db.statementCacheUsage.count <= 48 && db.statementCacheUsage.bytes <= 512 * 1024, "statement cache has count and memory bounds")
            let openLock = try DatabaseFiles.lockOpen(path("locked.sqlite"))
            do {
                _ = try open("locked.sqlite")
                check(false, "concurrent migration open is refused")
            } catch { check(true, "concurrent migration open is refused") }
            DatabaseFiles.unlockOpen(openLock)
        } catch { check(false, "storage checks threw: \(error.localizedDescription)") }

        let started = DispatchSemaphore(value: 0)
        let cancelPath = path("cancel.sqlite")
        let task = Task.detached { () throws -> Bool in
            let db = try DatabaseConnection(path: cancelPath, keyProvider: { _, _ in key })
            defer { db.close() }
            started.signal()
            do {
                _ = try db.withCancellableRead {
                    try db.scalarInt("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n;")
                }
                return false
            } catch is CancellationError {
                return try db.scalarInt("SELECT 42;") == 42
            }
        }
        check(started.wait(timeout: .now() + 5) == .success, "long SQL read started")
        try? await Task.sleep(nanoseconds: 20_000_000)
        let cancellationStart = SearchClock.now()
        task.cancel()
        check((try? await task.value) == true, "in-flight SQL cancels and leaves connection reusable")
        check(SearchClock.milliseconds(from: cancellationStart) < 1000, "SQL cancellation completes within one second")

        let stamp = Date()
        func clip(_ id: Int64, _ body: String, privateRow: Bool = false) -> Clip {
            Clip(dbID: id, id: UUID(), kind: .text, text: body, createdAt: stamp,
                 lastCopiedAt: stamp, updatedAt: stamp, isPrivate: privateRow)
        }
        let index = MemorySearchIndex()
        index.rebuild(from: [clip(1, "needle 👨‍👩‍👧"), clip(2, "needle removed"), clip(3, "needle private", privateRow: true)])
        let early = index.snapshot()
        index.remove(dbID: 2)
        index.update(clip: clip(1, "needle changed"))
        index.insert(clip: clip(4, "needle 中文"))
        let candidates: Set<Int64> = [1, 2, 3, 4, 999]
        let hits = index.matchingIDs(candidateIDs: candidates, groups: [["needle"]], excludedKeywords: [])
        check(Set(hits) == [1, 4], "sparse lookup handles pending, private and missing rows")
        let evidence = index.evidenceMatches(candidateIDs: candidates, groups: [["needle"]], excludedKeywords: ["changed"], termLengths: [6], phrase: nil)
        check(Set(evidence.map(\.dbID)) == [4], "sparse evidence respects exclusions and pending updates")
        check(Set(early.matchingIDs(candidateIDs: candidates, groups: [["needle"]], excludedKeywords: [])) == [1, 2], "old snapshot remains immutable")

        func framed(_ payload: String, limit: Int, shutdownWrite: Bool = true) -> String? {
            var pair: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
            defer { close(pair[0]); close(pair[1]) }
            payload.withCString { pointer in _ = write(pair[0], pointer, payload.utf8.count) }
            if shutdownWrite { shutdown(pair[0], SHUT_WR) }
            return APIControlServer.readLine(from: pair[1], limit: limit, timeout: 0.05)
        }
        check(framed("1234\n", limit: 4) == "1234", "request exactly at byte limit is accepted")
        check(framed("12345\n", limit: 4) == nil, "oversized request is rejected")
        check(framed("1234", limit: 4) == nil, "EOF without newline is rejected")
        let readStart = SearchClock.now()
        check(framed("1", limit: 4, shutdownWrite: false) == nil, "incomplete request times out")
        check(SearchClock.milliseconds(from: readStart) < 500, "socket deadline bounds blocked reads")
        var slowReader: [Int32] = [0, 0]
        if socketpair(AF_UNIX, SOCK_STREAM, 0, &slowReader) == 0 {
            let sendStart = SearchClock.now()
            APIControlServer.sendPayload(Data(repeating: 1, count: 2 * 1024 * 1024), to: slowReader[0], timeout: 0.05)
            check(SearchClock.milliseconds(from: sendStart) < 500, "socket deadline bounds responses to a non-reading client")
            close(slowReader[0])
            close(slowReader[1])
        } else { check(false, "slow response fixture") }
        print("[STORAGE-SEARCH] \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }
}
