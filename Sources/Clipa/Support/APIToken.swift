import Foundation
import Security
import Combine

/// 本地控制面的令牌与作用域。
///
/// **为什么不按签名白名单**：Agent 多半跑在解释器里（python / node / shell），不是自己的
/// 签名 app；按签名挡会把它们全挡在门外。令牌对签名与否一视同仁，而且**可归属、可撤销、
/// 可限作用域**。调用方的签名身份仍然记录（审计里区分是谁在用），但它不是准入条件。
///
/// 令牌文件 `<root>/api-tokens.json`，权限 `0600`，**只存哈希**：文件被读了也拿不到
/// 手里的令牌。完整令牌只在创建时显示一次。
struct APIToken: Codable, Equatable, Identifiable {
    enum TokenError: LocalizedError {
        case hashFailed
        case storageUnavailable

        var errorDescription: String? {
            switch self {
            case .hashFailed: return "令牌哈希计算失败"
            case .storageUnavailable: return "令牌文件无法读取，请先修复后重试。现有文件未被覆盖。"
            }
        }
    }

    /// 作用域。默认只给 meta —— 正文与写能力都要显式授权。
    enum Scope: String, Codable, CaseIterable, Sendable {
        case searchMeta = "search.meta"
        case searchText = "search.text"
        case readFull = "read.full"
        case copy
        case put
        case note
        case delete
        case collectionsRead = "collections.read"
        case collectionsWrite = "collections.write"

        var title: String {
            switch self {
            case .searchMeta: return "查询——只给元信息"
            case .searchText: return "查询——附正文开头"
            case .readFull: return "读取整条正文"
            case .copy: return "把某条历史放回系统剪贴板"
            case .put: return "把内容写进历史"
            case .note: return "写备注"
            case .delete: return "删除历史条目"
            case .collectionsRead: return "查看资料集"
            case .collectionsWrite: return "整理资料集"
            }
        }

        /// 写能力：默认一律不给，要勾才给。
        var isWrite: Bool {
            switch self {
            case .searchMeta, .searchText, .readFull, .collectionsRead: return false
            case .copy, .put, .note, .delete, .collectionsWrite: return true
            }
        }
    }

    let id: String
    var label: String
    /// 审计与「已授权程序」里用来指代这个令牌的名字：label 是自由文本、
    /// 允许重名（多客户端 / 轮换都会产生），**归因必须靠 id**。
    var displayName: String { "\(label)（\(id)）" }
    /// 只存哈希（SHA-256 十六进制）。
    let tokenHash: String
    var scopes: [Scope]
    let createdAt: Date
    var expiresAt: Date?
    var lastUsedAt: Date?
    var callCount: Int
    /// nil is a legacy grant that must be reconfirmed, never a wildcard.
    var workspaceIDs: [UUID]? = nil
    var connectionID: UUID? = nil

    func allows(workspaceID: UUID) -> Bool { workspaceIDs?.contains(workspaceID) == true }

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

/// 令牌仓库。`@MainActor`：它跟设置、菜单在同一个世界里，而 socket 侧只通过
/// `verify(secret:)` 这一条路进来。
@MainActor
final class APITokenStore: ObservableObject {
    static let shared = APITokenStore()

    /// 测试/探针钩子：指向临时目录，绝不碰用户的真实令牌文件。
    ///
    /// `nonisolated(unsafe)`：它由 CLI 隔离在进程启动时设置一次，之后只读。
    nonisolated(unsafe) static var directoryOverride: URL?

    @Published private(set) var tokens: [APIToken] = []
    /// 使用统计的落盘节流（P3 优化 2026-10-03）：状态见 `recordUse`。
    private var lastPersistedUse: Date?
    private var pendingUsePersist = false
    @Published private(set) var loadError: String?

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

    // MARK: - 读写

    func reload() {
        let pendingStats = pendingUsePersist ? tokens : []
        do {
            let data = try Data(contentsOf: fileURL)
            var loaded = try JSONDecoder().decode([APIToken].self, from: data)
            for index in loaded.indices {
                guard let pending = pendingStats.first(where: { $0.id == loaded[index].id && $0.tokenHash == loaded[index].tokenHash }) else { continue }
                loaded[index].callCount = max(loaded[index].callCount, pending.callCount)
                if let used = pending.lastUsedAt, used > (loaded[index].lastUsedAt ?? .distantPast) {
                    loaded[index].lastUsedAt = used
                }
            }
            tokens = loaded
            loadError = nil
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
            tokens = []
            loadError = nil
        } catch {
            // 读坏了**不能**当作"没有令牌"就放行——那样最坏情况是全部拒绝，
            // 但把文件读成空会让"撤销过的令牌"看起来还在。
            tokens = []
            loadError = "令牌文件无法解析：\(error.localizedDescription)"
            NSLog("Clipa token file unreadable: \(error.localizedDescription)")
        }
    }

    private func save() throws {
        guard loadError == nil else { throw APIToken.TokenError.storageUnavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tokens)
        try OwnerOnlyFile.write(data, to: fileURL)
    }

    // MARK: - 创建 / 撤销

    /// 新建一个令牌，返回**只此一次**的完整令牌串。
    @discardableResult
    func create(
        label: String,
        scopes: [APIToken.Scope],
        expiresAt: Date? = nil,
        workspaceIDs: [UUID]? = nil,
        connectionID: UUID? = nil
    ) throws -> (token: APIToken, secret: String) {
        guard loadError == nil else { throw APIToken.TokenError.storageUnavailable }
        let secret = Self.generateSecret()
        guard let digest = Self.hash(secret) else {
            throw APIToken.TokenError.hashFailed
        }
        var id: String
        repeat { id = "t_" + UUID().uuidString.prefix(8).lowercased() }
        while tokens.contains(where: { $0.id == id })
        let token = APIToken(
            id: id,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            tokenHash: digest,
            scopes: scopes,
            createdAt: Date(),
            expiresAt: expiresAt,
            lastUsedAt: nil,
            callCount: 0,
            workspaceIDs: workspaceIDs ?? [WorkspaceStore.shared.activeID],
            connectionID: connectionID
        )
        let snapshot = tokens
        tokens.append(token)
        do { try save() }
        catch {
            tokens = snapshot
            throw error
        }
        return (token, secret)
    }

    func updateAuthorization(id: String, scopes: [APIToken.Scope], workspaceIDs: [UUID], expiresAt: Date?) throws {
        guard !workspaceIDs.isEmpty, let index = tokens.firstIndex(where: { $0.id == id }) else {
            throw APIToken.TokenError.storageUnavailable
        }
        let previous = tokens
        tokens[index].scopes = scopes
        var seen = Set<UUID>()
        tokens[index].workspaceIDs = workspaceIDs.filter { seen.insert($0).inserted }
        tokens[index].expiresAt = expiresAt
        do { try save() } catch { tokens = previous; throw error }
    }

    /// Replace a managed connection's credential only after its new grant is
    /// persisted. If writing the private credential fails, restore the grant.
    func rotate(id: String, persistCredential: (String) throws -> Void) throws {
        guard let index = tokens.firstIndex(where: { $0.id == id }) else { throw APIToken.TokenError.storageUnavailable }
        let secret = Self.generateSecret()
        guard let hash = Self.hash(secret) else { throw APIToken.TokenError.hashFailed }
        let previous = tokens
        let old = tokens[index]
        tokens[index] = APIToken(id: old.id, label: old.label, tokenHash: hash, scopes: old.scopes,
                                createdAt: old.createdAt, expiresAt: old.expiresAt, lastUsedAt: nil,
                                callCount: old.callCount, workspaceIDs: old.workspaceIDs, connectionID: old.connectionID)
        do {
            try save()
            try persistCredential(secret)
        } catch {
            tokens = previous
            do { try save() }
            catch { loadError = "凭据更新失败，且无法恢复原授权。请修复存储后重新连接。" }
            throw error
        }
    }

    /// 撤销一个令牌。**持久化失败会回滚内存并返回 false**——P2 修复
    /// （2026-10-03）：旧实现 `try? save()`，磁盘满/权限问题时内存里已删、
    /// 文件还是旧的，重启后"已撤销"的令牌会复活。
    @discardableResult
    func revoke(id: String) -> Bool {
        guard loadError == nil else { return false }
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
        guard loadError == nil else { return false }
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

    // MARK: - 校验

    /// 校验一个令牌串。返回命中的令牌（含作用域）。
    func verify(secret: String) -> APIToken? {
        guard !secret.isEmpty else { return nil }
        // 哈希失败时宁可"谁都进不来"，也不要出现"空哈希相互匹配"这种放行。
        guard let digest = Self.hash(secret), !digest.isEmpty else { return nil }
        // 常量时间比较：本机 socket 上做时序攻击不现实，但比较一个秘密时按行规来。
        for token in tokens where token.tokenHash.count == digest.count {
            if Self.constantTimeEquals(token.tokenHash, digest),
               !token.isExpired {
                return token
            }
        }
        return nil
    }

    func failureCode(secret: String) -> APIErrorCode {
        guard let digest = Self.hash(secret) else { return .notAuthorized }
        return tokens.contains { Self.constantTimeEquals($0.tokenHash, digest) && $0.isExpired }
            ? .tokenExpired : .notAuthorized
    }

    /// 记录一次使用。落盘**节流**（P2/P3 修复 2026-10-03）：lastUsedAt/callCount
    /// 只是使用统计，不值得每个请求都整文件重写（临时文件 + rename，且在主
    /// actor 上同步 IO）——最多每 30 秒落一次盘；退出时未落盘的变更由
    /// `flushPendingUse` 补写。写失败只记日志：统计丢失不影响安全，但不能
    /// 静默到排查时看不见。
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

    /// 把未落盘的使用统计强制写一次（应用退出时调用）。
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

    // MARK: - 小工具

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
        // 复用仓库里已有的哈希（SHA-256 十六进制），不引第二个实现。
        // 它可能失败（返回 nil）——那种情况下**绝不能**退化成"随便一个令牌都放行"。
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
