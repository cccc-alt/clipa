import Foundation
import CSQLCipher

/// Deterministic synthetic workload. The same source also runs against the
/// original implementation, so timings compare code rather than different data.
enum StorageSearchBenchmark {
    static func run() -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipaStorageBench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var checksum = 0
        func measure(_ label: String, rounds: Int, _ work: () throws -> Void) rethrows {
            try work()
            var timings: [Double] = []
            for _ in 0..<rounds {
                let start = SearchClock.now()
                try work()
                timings.append(SearchClock.milliseconds(from: start))
            }
            timings.sort()
            print("[BENCH] \(label): median_ms=\(String(format: "%.4f", timings[timings.count / 2])) rounds=\(rounds)")
        }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (1...100_000).map { i in
            Clip(dbID: Int64(i), id: UUID(), kind: .text,
                 text: "payload \(i) search needle 中文检索\nlet number = \(i)",
                 createdAt: stamp, lastCopiedAt: stamp, updatedAt: stamp)
        }
        let index = MemorySearchIndex()
        index.rebuild(from: rows)
        let candidates = Set((1...32).map { Int64($0 * 997) })
        measure("100k rows / 32 candidates / match", rounds: 50) {
            checksum += index.matchingIDs(
                candidateIDs: candidates, groups: [["needle"]], excludedKeywords: []
            ).count
        }
        measure("100k rows / 32 candidates / evidence", rounds: 50) {
            checksum += index.evidenceMatches(
                candidateIDs: candidates, groups: [["needle"]], excludedKeywords: [],
                termLengths: [6], phrase: nil
            ).count
        }
        measure("100k rows / full scan / absent", rounds: 5) {
            checksum += index.matchingIDs(groups: [["absent"]], excludedKeywords: []).count
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let db = try DatabaseConnection(path: root.appendingPathComponent("clips.sqlite").path)
            defer { db.close() }
            try db.configure()
            try db.exec("CREATE TABLE bench(id INTEGER PRIMARY KEY, body TEXT);")
            try measure("8000 parameterized inserts / transaction", rounds: 5) {
                try db.exec("DELETE FROM bench;")
                try db.beginImmediate()
                for i in 1...8000 {
                    try db.prepare("INSERT INTO bench(id, body) VALUES (?, ?)") { statement in
                        sqlite3_bind_int(statement, 1, Int32(i))
                        db.bindText(statement, 2, "payload \(i) 中文")
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.sql(db.lastErrorMessage) }
                    }
                }
                try db.commit()
            }
            try measure("20000 parameterized row reads", rounds: 5) {
                for i in 0..<20_000 {
                    try db.prepare("SELECT body FROM bench WHERE id = ?") { statement in
                        sqlite3_bind_int(statement, 1, Int32(i % 8000 + 1))
                        guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.missingRow }
                        checksum += db.columnString(statement, 0).utf8.count
                    }
                }
            }
        } catch {
            print("[BENCH] failed: \(error.localizedDescription)")
            return 1
        }
        print("[BENCH] checksum=\(checksum)")
        return 0
    }
}
