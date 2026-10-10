import Foundation

struct APIWorkspace: Codable {
    let id: UUID
    let name: String
    let isCurrent: Bool
}

struct APIDiagnostic: Codable {
    enum CodingKeys: String, CodingKey {
        case state, message, recovery
        case connectionID = "connectionId"
    }
    let state: String
    let message: String
    let recovery: String
    var connectionID: UUID? = nil
}

struct ClipCollection: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let createdAt: Date
    var count: Int
}

enum IntegrationValidation {
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    static func name(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, clean.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WorkflowError.message("名称需为 1–60 个字，不能含控制字符。")
        }
        return clean
    }

    /// Offsets are UTF-8 bytes. Never silently split a scalar or change offsets.
    static func page(_ text: String, offset: Int, budget: Int) throws -> (text: String, next: Int?, total: Int) {
        let bytes = text.utf8
        let count = bytes.count
        guard offset >= 0, offset <= count, (256...262_144).contains(budget) else {
            throw WorkflowError.message("byte_offset 必须在正文范围内；max_bytes 必须为 256–262144。")
        }
        let start = bytes.index(bytes.startIndex, offsetBy: offset)
        guard start == bytes.endIndex || bytes[start] & 0xC0 != 0x80 else {
            throw WorkflowError.message("byte_offset 不是 UTF-8 字符边界，请使用返回的 next_byte_offset。")
        }
        var end = bytes.index(start, offsetBy: min(budget, count - offset))
        while end != bytes.endIndex && bytes[end] & 0xC0 == 0x80 { end = bytes.index(before: end) }
        let consumed = bytes.distance(from: bytes.startIndex, to: end)
        return (String(decoding: bytes[start..<end], as: UTF8.self), consumed < count ? consumed : nil, count)
    }
}
