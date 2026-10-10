import Foundation
import CSQLCipher

extension Notification.Name {
    static let clipaCollectionsChanged = Notification.Name("ClipaCollectionsChanged")
}

extension DatabaseManager {
    func listCollections(limit: Int = 500, offset: Int = 0) throws -> [ClipCollection] {
        try connection.prepare("""
            SELECT g.id, g.name, g.created_at,
                (SELECT COUNT(*) FROM clip_collection_members m JOIN clips c ON c.id=m.clip_id
                 WHERE m.collection_id=g.id AND c.is_private=0 AND c.is_hidden=0)
            FROM clip_collections g ORDER BY g.created_at DESC, g.id LIMIT ? OFFSET ?
            """) { statement in
            sqlite3_bind_int64(statement, 1, Int64(min(max(limit, 1), 500)))
            sqlite3_bind_int64(statement, 2, Int64(max(offset, 0)))
            var result: [ClipCollection] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let raw = connection.columnText(statement, 0), let id = UUID(uuidString: raw) {
                    result.append(ClipCollection(id: id, name: connection.columnText(statement, 1) ?? "",
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                        count: Int(sqlite3_column_int64(statement, 3))))
                }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw DatabaseError.sql(connection.lastErrorMessage) }
            return result
        }
    }

    private func requireCollection(_ id: UUID) throws {
        let exists = try connection.prepare("SELECT 1 FROM clip_collections WHERE id=?") { statement in
            connection.bindText(statement, 1, id.uuidString)
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { return true }
            guard status == SQLITE_DONE else { throw DatabaseError.sql(connection.lastErrorMessage) }
            return false
        }
        guard exists else { throw DatabaseError.missingRow }
    }

    func collectionMembers(id: UUID) throws -> Set<UUID> {
        try requireCollection(id)
        return try connection.prepare("""
            SELECT c.id FROM clip_collection_members m JOIN clips c ON c.id=m.clip_id
            WHERE m.collection_id=? AND c.is_private=0 AND c.is_hidden=0
            """) { statement in
            connection.bindText(statement, 1, id.uuidString)
            var result = Set<UUID>()
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let value = connection.columnText(statement, 0), let uuid = UUID(uuidString: value) { result.insert(uuid) }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw DatabaseError.sql(connection.lastErrorMessage) }
            return result
        }
    }

    @discardableResult
    func saveCollection(id: UUID? = nil, name: String) throws -> UUID {
        let name = try IntegrationValidation.name(name)
        let key = QueryNormalizer.normalize(name)
        let target = id ?? UUID()
        if let id { try requireCollection(id) }
        else if try connection.scalarInt("SELECT COUNT(*) FROM clip_collections") >= 500 {
            throw WorkflowError.message("每个工作区最多创建 500 个资料集。")
        }
        let duplicate = try connection.prepare("SELECT 1 FROM clip_collections WHERE name_key=? AND id<>?") { statement in
            connection.bindText(statement, 1, key)
            connection.bindText(statement, 2, target.uuidString)
            return sqlite3_step(statement) == SQLITE_ROW
        }
        guard !duplicate else { throw WorkflowError.message("已有同名资料集，请换一个名称。") }
        let sql = id == nil ? "INSERT INTO clip_collections(name,name_key,id,created_at) VALUES(?,?,?,?)"
                            : "UPDATE clip_collections SET name=?, name_key=? WHERE id=?"
        try connection.prepare(sql) { statement in
            connection.bindText(statement, 1, name)
            connection.bindText(statement, 2, key)
            connection.bindText(statement, 3, target.uuidString)
            if id == nil { sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.sql(connection.lastErrorMessage) }
        }
        return target
    }

    func deleteCollection(id: UUID) throws {
        try requireCollection(id)
        try connection.prepare("DELETE FROM clip_collections WHERE id=?") { statement in
            connection.bindText(statement, 1, id.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.sql(connection.lastErrorMessage) }
        }
    }

    func changeCollectionMembers(id: UUID, clips: [UUID], adding: Bool) throws {
        guard !clips.isEmpty, clips.count <= 100 else { throw WorkflowError.message("每次需提供 1–100 个条目。") }
        try connection.beginImmediate()
        do {
            try requireCollection(id)
            for clip in Set(clips) {
                let visible = try connection.prepare("SELECT 1 FROM clips WHERE id=? AND is_private=0 AND is_hidden=0") { statement in
                    connection.bindText(statement, 1, clip.uuidString)
                    return sqlite3_step(statement) == SQLITE_ROW
                }
                guard visible else { throw DatabaseError.missingRow }
                try connection.prepare(adding
                    ? "INSERT OR IGNORE INTO clip_collection_members(collection_id,clip_id) VALUES(?,?)"
                    : "DELETE FROM clip_collection_members WHERE collection_id=? AND clip_id=?") { statement in
                    connection.bindText(statement, 1, id.uuidString)
                    connection.bindText(statement, 2, clip.uuidString)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.sql(connection.lastErrorMessage) }
                }
            }
            try connection.commit()
        } catch { connection.rollback(); throw error }
    }
}
