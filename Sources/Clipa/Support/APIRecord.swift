import Foundation

struct APIRecord: Codable, Equatable {
    let id: String
    let kind: String
    let createdAt: String
    let lastCopiedAt: String
    let sourceApp: String?
    let smartTag: String

    let sensitive: Bool

    let redacted: Bool

    let truncated: Bool

    let text: String
    let note: String
}

extension APIRecord {

    enum Limits {
        static let bodyBytes = 4096
        static let noteBytes = 512
    }

    static func make(
        for clip: Clip,
        formatter: ISO8601DateFormatter,
        body: String,
        note: String,
        redacted: Bool,
        truncated: Bool
    ) -> APIRecord {
        APIRecord(
            id: clip.id.uuidString,
            kind: clip.kind.rawValue,
            createdAt: formatter.string(from: clip.createdAt),
            lastCopiedAt: formatter.string(from: clip.lastCopiedAt),
            sourceApp: clip.sourceApp,
            smartTag: clip.smartTag.rawValue,
            sensitive: clip.containsSensitive,
            redacted: redacted,
            truncated: truncated,
            text: body,
            note: note
        )
    }

    static func bounded(
        _ text: String,
        bytes: Int
    ) -> (text: String, truncated: Bool) {
        guard bytes >= 0 else { return ("", false) }
        guard bytes < Int.max, text.utf8.count > bytes else {
            return (text, false)
        }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes { return (result, true) }
            result.append(character)
            used += size
        }
        return (result, false)
    }
}
