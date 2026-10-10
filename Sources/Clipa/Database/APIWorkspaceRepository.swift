import Foundation
import CSQLCipher

/// Inactive workspace reads query bounded SQL projections, never instantiate
/// another in-memory clipboard history or load image blobs.
extension DatabaseManager {
    func publicClipCount() throws -> Int {
        try connection.scalarInt("SELECT COUNT(*) FROM clips WHERE is_private=0 AND is_hidden=0")
    }

    func apiRead(_ args: APIRequest.Arguments, token: APIToken, single: Bool) throws -> APIResponse {
        enum Value { case text(String), number(Double) }
        var conditions = ["c.is_private=0", "c.is_hidden=0"]
        var values: [Value] = []
        let budget = single ? args.maxBytes ?? 65_536 : (token.allows(.searchText) || token.allows(.readFull)) ? 64 : 0
        let byteOffset = single ? args.byteOffset ?? 0 : 0
        let field = single ? args.field ?? "text" : "text"
        guard field == "text" || field == "note" else { throw WorkflowError.message("field 必须为 text 或 note。") }
        let bodyColumn = field == "note" ? "c.note" : "c.text"
        let bodyCondition = field == "note" ? "1" : "c.kind=0"
        guard byteOffset >= 0, byteOffset < Int.max - 262_149, !single || (256...262_144).contains(budget) else {
            throw WorkflowError.message("byte_offset 不能为负；max_bytes 必须为 256–262144。")
        }
        if single {
            guard let id = args.id, !id.isEmpty, id.count <= 36 else { throw DatabaseError.missingRow }
            conditions.append("substr(lower(c.id),1,length(?))=?")
            values += [.text(id.lowercased()), .text(id.lowercased())]
        } else {
            let query = SearchQuery.parse(args.query ?? "")
            if let fts = FTSQueryBuilder.buildANDQuery(terms: query.ftsTerms.map(\.normalized)) {
                conditions.append("c.db_id IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)")
                values.append(.text(fts))
            }
            for term in query.terms {
                conditions.append("(instr(c.norm_text,?)>0 OR instr(c.norm_note,?)>0)")
                values += [.text(term.normalized), .text(term.normalized)]
            }
            if let value = args.kind {
                guard let kind = ClipKind(rawValue: value) else { throw WorkflowError.message("kind 必须为 text、image 或 file。") }
                conditions.append("c.kind=?"); values.append(.number(Double(kind.databaseValue)))
            }
            if let source = args.source, !source.isEmpty {
                conditions.append("(lower(c.source_app)=lower(?) OR c.source_bundle=?)")
                values += [.text(source), .text(source)]
            }
            let after = args.after.flatMap(IntegrationValidation.date)
            let before = args.before.flatMap(IntegrationValidation.date)
            guard args.after == nil || after != nil, args.before == nil || before != nil,
                  (after ?? .distantPast) <= (before ?? .distantFuture) else {
                throw WorkflowError.message("时间范围无效，请使用带时区的 ISO 8601 时间。")
            }
            if let after { conditions.append("COALESCE(c.last_copied_at,c.created_at)>=?"); values.append(.number(after.timeIntervalSince1970)) }
            if let before { conditions.append("COALESCE(c.last_copied_at,c.created_at)<=?"); values.append(.number(before.timeIntervalSince1970)) }
            if let collection = args.collectionID {
                guard token.allows(.collectionsRead) else { throw WorkflowError.message("按资料集筛选需要 collections.read 权限。") }
                // Confirm existence independently of whether it has visible members.
                let exists = try connection.prepare("SELECT 1 FROM clip_collections WHERE id=?") { statement in
                    connection.bindText(statement, 1, collection.uuidString)
                    return sqlite3_step(statement) == SQLITE_ROW
                }
                guard exists else { throw DatabaseError.missingRow }
                conditions.append("EXISTS(SELECT 1 FROM clip_collection_members m WHERE m.clip_id=c.id AND m.collection_id=?)")
                values.append(.text(collection.uuidString))
            }
        }
        let predicate = conditions.joined(separator: " AND ")
        func bind(_ statement: OpaquePointer) {
            for (index, value) in values.enumerated() {
                switch value {
                case .text(let text): connection.bindText(statement, Int32(index + 1), text)
                case .number(let number): sqlite3_bind_double(statement, Int32(index + 1), number)
                }
            }
        }
        let total = try connection.prepare("SELECT COUNT(*) FROM clips c WHERE " + predicate) { statement in
            bind(statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.sql(connection.lastErrorMessage) }
            return Int(sqlite3_column_int64(statement, 0))
        }
        if single {
            guard total > 0 else { throw DatabaseError.missingRow }
            guard total == 1 else { throw WorkflowError.message("id 前缀不唯一，请使用完整 UUID。") }
        }
        let limit = single ? 1 : min(50, max(1, args.limit ?? 10))
        let offset = single ? 0 : max(0, args.offset ?? 0)
        // Integers below have been bounded above; all caller-supplied SQL values
        // are still bound. Text and notes are projected under their own scopes.
        let sql = """
            SELECT c.id,c.kind,c.created_at,COALESCE(c.last_copied_at,c.created_at),c.source_app,c.smart_tag,c.contains_sensitive,
              CASE WHEN \(bodyCondition) THEN substr(CAST(\(bodyColumn) AS BLOB),\(byteOffset + 1),\(budget + 4)) ELSE X'' END,
              \(token.allows(.readFull) ? "substr(c.note,1,512)" : "''"),
              CASE WHEN \(bodyCondition) THEN length(CAST(\(bodyColumn) AS BLOB)) ELSE 0 END,
              length(CAST(c.note AS BLOB))
            FROM clips c WHERE \(predicate)
            ORDER BY c.last_copied_at DESC,c.db_id DESC LIMIT \(limit) OFFSET \(offset)
            """
        var nextByte: Int?
        var bodyTotal = 0
        let formatter = ISO8601DateFormatter()
        let records: [APIRecord] = try connection.prepare(sql) { statement in
            bind(statement)
            var result: [APIRecord] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                bodyTotal = Int(sqlite3_column_int64(statement, 9))
                guard byteOffset <= bodyTotal else { throw WorkflowError.message("byte_offset 超出正文范围。") }
                var bytes = connection.columnData(statement, 7) ?? Data()
                if let first = bytes.first, first & 0xC0 == 0x80 { throw WorkflowError.message("请使用返回的 next_byte_offset。") }
                bytes = Data(bytes.prefix(budget))
                while !bytes.isEmpty && String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
                let next = byteOffset + bytes.count
                nextByte = next < bodyTotal ? next : nil
                var record = APIRecord(id: connection.columnText(statement, 0) ?? "",
                    kind: ClipKind(databaseValue: Int(sqlite3_column_int(statement, 1)))?.rawValue ?? "text",
                    createdAt: formatter.string(from: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))),
                    lastCopiedAt: formatter.string(from: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))),
                    sourceApp: connection.columnText(statement, 4), smartTag: connection.columnText(statement, 5) ?? "",
                    sensitive: sqlite3_column_int(statement, 6) != 0, redacted: false,
                    truncated: budget > 0 && nextByte != nil, text: field == "text" ? String(decoding: bytes, as: UTF8.self) : "",
                    note: field == "note" ? String(decoding: bytes, as: UTF8.self) : APIRecord.bounded(connection.columnText(statement, 8) ?? "", bytes: APIRecord.Limits.noteBytes).text)
                let noteTruncated = field == "note" ? nextByte != nil : sqlite3_column_int64(statement, 10) > APIRecord.Limits.noteBytes
                record.noteTruncated = token.allows(.readFull) && noteTruncated ? true : nil
                result.append(record)
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw DatabaseError.sql(connection.lastErrorMessage) }
            return result
        }
        var response = APIResponse(ok: true, schema: APIContract.protocolVersion)
        if single {
            response.field = field
            response.clip = records.first; response.byteOffset = byteOffset
            response.nextByteOffset = nextByte; response.totalBytes = bodyTotal; response.truncated = nextByte != nil
        } else {
            response.results = records; response.total = total; response.count = records.count; response.offset = offset
            response.nextOffset = offset + records.count < total ? offset + records.count : nil
            response.truncated = response.nextOffset != nil
        }
        return response
    }
}
