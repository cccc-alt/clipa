import Foundation

/// 控制面的调用审计：一行一条 JSON，追加写（`api-audit.jsonl`，权限 `0600`）。
///
/// **正文永不入日志**，查询词也截断到 80 字 —— 日志是给人看的，而剪贴板里常常是密码。
/// 用追加写而不是数据库：调用很稀（限流 60 次/分钟），崩溃时也不会写坏已有记录。
enum APIAuditLog {
    /// 超过这个行数就裁剪（保留最近 `keepLines` 行）。
    static let maxLines = 1_000
    static let keepLines = 500

    struct Entry: Codable, Equatable {
        let at: Date
        /// 令牌**标签**（不是令牌本体）。
        let token: String
        /// 调用方身份：可执行文件路径 + pid。签名身份是后续增强，不影响准入。
        let peer: String
        let verb: String
        var query: String?
        var hits: Int?
        /// 被拒绝时的错误码；成功时为空。
        var denied: String?
    }

    static func url(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("api-audit.jsonl")
    }

    private static let lock = NSLock()

    static func append(_ entry: Entry, rootDirectory: URL) {
        lock.lock()
        defer { lock.unlock() }
        let file = url(rootDirectory: rootDirectory)
        try? FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(
                atPath: file.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        if lineCounts[file.path] == nil {
            // Initialize before the first append; starting at zero skipped the
            // existing file's rows on every process restart.
            let text = (try? tailText(file)) ?? ""
            lineCounts[file.path] = text.split(separator: "\n").count
        }
        guard let line = encodeLine(entry) else { return }
        // P2 修复（2026-10-03）：写失败要留痕。审计不含正文、丢一条不致命，
        // 但**静默**丢失会让排查无从下手。
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            lineCounts[file.path, default: 0] += 1
        } catch {
            NSLog(
                "Clipa API audit write failed: \(error.localizedDescription)"
            )
        }
        trimIfNeeded(at: file)
    }

    /// 最近的调用，**新的在前**（菜单与 `clipa doctor` 都按这个顺序显示）。
    static func recent(_ limit: Int, rootDirectory: URL) -> [Entry] {
        (try? readRecent(limit, rootDirectory: rootDirectory)) ?? []
    }

    /// Strict UI read: an unreadable file is a recovery state, not an empty list.
    /// Only the bounded tail is needed for the most recent records.
    static func readRecent(_ limit: Int, rootDirectory: URL) throws -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let file = url(rootDirectory: rootDirectory)
        let text: String
        do { text = try tailText(file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try text.split(separator: "\n").reversed().prefix(max(0, limit)).map {
            try decoder.decode(Entry.self, from: Data($0.utf8))
        }
    }

    private static func tailText(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let start = end > 2 * 1024 * 1024 ? end - 2 * 1024 * 1024 : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0, let newline = data.firstIndex(of: 10) { data = data.suffix(from: data.index(after: newline)) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ClipaAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: "调用记录格式异常"])
        }
        return text
    }

    @discardableResult
    static func clear(rootDirectory: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let file = url(rootDirectory: rootDirectory)
        guard unlink(file.path) == 0 || errno == ENOENT else { return false }
        lineCounts.removeValue(forKey: url(rootDirectory: rootDirectory).path)
        return true
    }

    // MARK: - 内部

    private static func encodeLine(_ entry: Entry) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(entry),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text + "\n"
    }

    /// 行数缓存（P3 优化 2026-10-03）：append 是每请求热路径，原来每次都把
    /// 整个文件重读一遍来数行（≈200KB/次）。进程内维护计数：文件首次触达时
    /// 从磁盘数一次，之后增量维护；裁剪后重置为保留行数；clear 时清掉条目。
    private static var lineCounts: [String: Int] = [:]

    private static func trimIfNeeded(at file: URL) {
        let key = file.path
        let count: Int
        if let cached = lineCounts[key] {
            count = cached
        } else {
            guard let text = try? String(
                contentsOf: file, encoding: .utf8
            ) else {
                lineCounts[key] = 0
                return
            }
            count = text.split(
                separator: "\n", omittingEmptySubsequences: true
            ).count
            lineCounts[key] = count
        }
        guard count > maxLines else { return }
        guard let text = try? tailText(file) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.suffix(keepLines).joined(separator: "\n") + "\n"
        // 走与导出同一套原子 + 0600 写：日志里没有正文，但它仍然是"谁读了什么"的证据。
        if (try? OwnerOnlyFile.write(Data(kept.utf8), to: file)) != nil {
            lineCounts[key] = keepLines
        }
    }
}
