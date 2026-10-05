import Foundation

enum APIAuditLog {

    static let maxLines = 1_000
    static let keepLines = 500

    struct Entry: Codable, Equatable {
        let at: Date

        let token: String

        let peer: String
        let verb: String
        var query: String?
        var hits: Int?

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
        guard let line = encodeLine(entry) else { return }

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

    static func recent(_ limit: Int, rootDirectory: URL) -> [Entry] {
        guard let text = try? String(
            contentsOf: url(rootDirectory: rootDirectory),
            encoding: .utf8
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [Entry] = []
        for line in text.split(separator: "\n").reversed() {
            guard entries.count < limit else { break }
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: data) else {
                continue
            }
            entries.append(entry)
        }
        return entries
    }

    static func clear(rootDirectory: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(
            at: url(rootDirectory: rootDirectory)
        )
        lineCounts.removeValue(forKey: url(rootDirectory: rootDirectory).path)
    }

    private static func encodeLine(_ entry: Entry) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(entry),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text + "\n"
    }

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
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.suffix(keepLines).joined(separator: "\n") + "\n"

        if (try? OwnerOnlyFile.write(Data(kept.utf8), to: file)) != nil {
            lineCounts[key] = keepLines
        }
    }
}
