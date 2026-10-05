import Foundation
import Security

struct APIToken: Codable, Equatable, Identifiable {
    enum TokenError: LocalizedError {
        case hashFailed

        var errorDescription: String? {
            switch self {
            case .hashFailed: return "令牌哈希计算失败"
            }
        }
    }

    enum Scope: String, Codable, CaseIterable, Sendable {
        case searchMeta = "search.meta"
        case searchText = "search.text"
        case readFull = "read.full"
        case copy
        case put
        case note
        case delete

        var title: String {
            switch self {
            case .searchMeta: return "查询——只给元信息"
            case .searchText: return "查询——附正文开头"
            case .readFull: return "读取整条正文"
            case .copy: return "把某条历史放回系统剪贴板"
            case .put: return "把内容写进历史"
            case .note: return "写备注"
            case .delete: return "删除历史条目"
            }
        }

        var isWrite: Bool {
            switch self {
            case .searchMeta, .searchText, .readFull: return false
            case .copy, .put, .note, .delete: return true
            }
        }
    }

    let id: String
    var label: String

    var displayName: String { "\(label)（\(id)）" }

    let tokenHash: String
    var scopes: [Scope]
    let createdAt: Date
    var expiresAt: Date?
    var lastUsedAt: Date?
    var callCount: Int

    func allows(_ scope: Scope) -> Bool {
        scopes.contains(scope)
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    var scopeList: String {
        scopes.isEmpty ? "（无）" : scopes.map(\.rawValue).joined(separator: " · ")
    }
}

@MainActor
final class APITokenStore {
    static let shared = APITokenStore()

    nonisolated(unsafe) static var directoryOverride: URL?

    private(set) var tokens: [APIToken] = []

    private var lastPersistedUse: Date?
    private var pendingUsePersist = false
    private(set) var loadError: String?

    private var fileURL: URL {
        Self.url(rootDirectory: Self.directory())
    }

    static func url(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("api-tokens.json")
    }

    private static func directory() -> URL {
        if let override = directoryOverride { return override }
        return ClipStore.defaultBaseDirectory()
    }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL) else {
            tokens = []
            loadError = nil
            return
        }
        do {
            tokens = try JSONDecoder().decode([APIToken].self, from: data)
            loadError = nil
        } catch {

            tokens = []
            loadError = "令牌文件无法解析：\(error.localizedDescription)"
            NSLog("Clipa token file unreadable: \(error.localizedDescription)")
        }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tokens)
        try OwnerOnlyFile.write(data, to: fileURL)
    }

    @discardableResult
    func create(
        label: String,
        scopes: [APIToken.Scope],
        expiresAt: Date? = nil
    ) throws -> (token: APIToken, secret: String) {
        let secret = Self.generateSecret()
        guard let digest = Self.hash(secret) else {
            throw APIToken.TokenError.hashFailed
        }
        let token = APIToken(
            id: "t_" + UUID().uuidString.prefix(8).lowercased(),
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            tokenHash: digest,
            scopes: scopes,
            createdAt: Date(),
            expiresAt: expiresAt,
            lastUsedAt: nil,
            callCount: 0
        )
        tokens.append(token)
        try save()
        return (token, secret)
    }

    @discardableResult
    func revoke(id: String) -> Bool {
        let snapshot = tokens
        tokens.removeAll { $0.id == id }
        do {
            try save()
            return true
        } catch {
            tokens = snapshot
            NSLog(
                "Clipa token revoke failed (rolled back): \(error.localizedDescription)"
            )
            return false
        }
    }

    @discardableResult
    func revokeAll() -> Bool {
        let snapshot = tokens
        tokens = []
        do {
            try save()
            return true
        } catch {
            tokens = snapshot
            NSLog(
                "Clipa token revokeAll failed (rolled back): \(error.localizedDescription)"
            )
            return false
        }
    }

    func verify(secret: String) -> APIToken? {
        guard !secret.isEmpty else { return nil }

        guard let digest = Self.hash(secret), !digest.isEmpty else { return nil }

        for token in tokens where token.tokenHash.count == digest.count {
            if Self.constantTimeEquals(token.tokenHash, digest),
               !token.isExpired {
                return token
            }
        }
        return nil
    }

    func recordUse(id: String) {
        guard let index = tokens.firstIndex(where: { $0.id == id }) else {
            return
        }
        tokens[index].lastUsedAt = Date()
        tokens[index].callCount += 1
        let now = Date()
        if let last = lastPersistedUse,
           now.timeIntervalSince(last) < 30 {
            pendingUsePersist = true
            return
        }
        lastPersistedUse = now
        do {
            try save()
            pendingUsePersist = false
        } catch {
            pendingUsePersist = true
            NSLog(
                "Clipa token usage persist failed: \(error.localizedDescription)"
            )
        }
    }

    func flushPendingUse() {
        guard pendingUsePersist else { return }
        pendingUsePersist = false
        do {
            try save()
        } catch {
            pendingUsePersist = true
            NSLog(
                "Clipa token usage flush failed: \(error.localizedDescription)"
            )
        }
    }

    static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "clipa_" + encoded
    }

    static func hash(_ secret: String) -> String? {

        ContentHasher.hash(text: secret)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<left.count {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}
