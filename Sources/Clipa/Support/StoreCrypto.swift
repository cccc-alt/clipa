import CryptoKit
import Foundation
import Security

/// AES-GCM envelopes for private text, notes and image bytes, in addition to
/// SQLCipher encryption of the whole database. Private content stays out of
/// normalized columns, FTS and the memory search index.
///
/// Text: clipa1: + base64(nonce || ciphertext || tag).
/// Binary: CLIPAE1 + nonce || ciphertext || tag.
/// Each seal uses a fresh random nonce. Legacy unsealed values remain readable
/// so migrations can encrypt them; new private writes always fail on key errors.
enum StoreCrypto {
    static let envelopePrefix = "clipa1:"
    static let keyByteCount = 32

    /// 钥匙串条目标识。`service` 与 bundle id 一致（本机已有别的工具用同名
    /// service 存自己的键，靠 `account` 区分）；换密钥格式就换 `account`，
    /// 旧密钥不会被新代码误用。
    private static let keychainService = "com.clipa.desktop"
    private static let keychainAccount = "store.private-key.v1"

    enum Failure: LocalizedError, Equatable {
        case keyUnavailable(String)
        case sealingFailed
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .keyUnavailable(let detail):
                return "读不到本机钥匙串里的数据密钥：\(detail)"
            case .sealingFailed:
                return "加密失败，正文未写入"
            case .authenticationFailed:
                return "密文无法解开（密钥不同或内容被改动）"
            }
        }
    }

    // MARK: - 信封（纯函数：不碰钥匙串，可单独测）

    static func isEnvelope(_ value: String) -> Bool {
        value.hasPrefix(envelopePrefix)
    }

    static func seal(_ plaintext: String, key: Data) throws -> String {
        // 空串不加密：没有内容需要保护，也让"空正文"在库里保持字面可读。
        guard !plaintext.isEmpty else { return plaintext }
        let box = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: SymmetricKey(data: key)
        )
        guard let combined = box.combined else { throw Failure.sealingFailed }
        return envelopePrefix + combined.base64EncodedString()
    }

    /// 非密文原样返回：历史明文行、以及"降级后又升级"的行都必须能读。
    static func open(_ stored: String, key: Data) throws -> String {
        guard isEnvelope(stored) else { return stored }
        let payload = String(stored.dropFirst(envelopePrefix.count))
        guard let data = Data(base64Encoded: payload),
              let box = try? AES.GCM.SealedBox(combined: data),
              let bytes = try? AES.GCM.open(box, using: SymmetricKey(data: key)),
              let text = String(data: bytes, encoding: .utf8)
        else {
            throw Failure.authenticationFailed
        }
        return text
    }

    // MARK: - 钥匙串里的数据密钥

    private static let lock = NSLock()
    private static var cachedKey: Data?
    private static var failureNote: String?

    /// 测试隔离的钥匙串替代（2026-10-01）：CLI 隔离模式（自检 / 探针）设置它之后，
    /// `key()` 用这把进程内随机密钥，**完全不碰用户的登录钥匙串**。
    ///
    /// 缺口是怎么暴露的：自检的私密测试一直真读真写登录钥匙串；当发起请求的
    /// 二进制身份不在条目的 ACL 里（比如 /tmp 下的未打包测试二进制，或某次
    /// 重装后的新构建），securityd 会弹授权框等用户点 —— 自检就挂在
    /// `SecItemCopyMatching` 上，而别处看起来一切正常。"隔离世界"此前没有把
    /// 钥匙串隔离进去。钥匙串本身的读写行为仍由 `--crypto-probe` 覆盖，
    /// 那条探针（且只有那条）就是要真碰钥匙串的。
    static var isolationKey: Data?

    static func generateKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw Failure.keyUnavailable(describe(status))
        }
        return Data(bytes)
    }

    /// 取密钥：钥匙串里有就用，没有就生成并写回。
    static func key() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        if let isolationKey {
            cachedKey = isolationKey
            return isolationKey
        }
        if let stored = try readKeychain() {
            cachedKey = stored
            return stored
        }
        let fresh = try generateKey()
        if try addKey(fresh) {
            cachedKey = fresh
            return fresh
        }
        // P2 修复（2026-10-03）：add 报 duplicate = 另一个进程（或探针的隔离
        // 实例）刚写入了自己的密钥。旧实现"先删后加"会把它顶掉——先写进程
        // 加密的内容从此全部解不开。现在**采纳先到者**：读回它的密钥并使用。
        guard let winner = try readKeychain() else {
            throw Failure.keyUnavailable("并发写入钥匙串后读取失败")
        }
        cachedKey = winner
        return winner
    }

    /// 丢掉进程内缓存，下次重新问钥匙串。探针用它证明"密钥真的在钥匙串里"，
    /// 而不是恰好还留在内存里。**不删条目**。
    static func forgetCachedKey() {
        lock.lock()
        defer { lock.unlock() }
        cachedKey = nil
    }

    /// 只读属性、**不含密钥本体**，给探针与诊断用。
    struct KeyStatus {
        let present: Bool
        let creationDate: Date?
        let error: String?
    }

    static func keyStatus() -> KeyStatus {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            let attributes = out as? [String: Any]
            return KeyStatus(
                present: true,
                creationDate: attributes?[kSecAttrCreationDate as String]
                    as? Date,
                error: nil
            )
        case errSecItemNotFound:
            return KeyStatus(present: false, creationDate: nil, error: nil)
        default:
            return KeyStatus(
                present: false,
                creationDate: nil,
                error: describe(status)
            )
        }
    }

    // MARK: - 存储接口

    /// 写入路径：**失败就抛，绝不退回写明文**——一个"以为私密、其实是明文"的
    /// 行，比一次写失败危险得多。
    static func sealForStorage(_ plaintext: String) throws -> String {
        try seal(plaintext, key: try key())
    }

    /// 读取路径：非密文原样返回；密文解不开返回 `nil`（调用方留空并记一笔）。
    ///
    /// 绝不把密文当正文交出去：它会显示在卡片上、被复制出去、甚至被写回数据库。
    static func openStored(_ stored: String) -> String? {
        guard isEnvelope(stored) else { return stored }
        do {
            return try open(stored, key: try key())
        } catch {
            noteFailure(error.localizedDescription)
            return nil
        }
    }

    // MARK: - 二进制信封（图片字节，2026-10-02）

    /// 图片等二进制载荷的密文前缀。读取按它自识别：带前缀 → 解密；
    /// 不带 → 原样返回。这让"先 seal、后置私密标志"（或任何顺序错乱）
    /// 都不会产生读不回来的状态。
    private static let dataMagic = Data("CLIPAE1".utf8)

    static func isSealedData(_ data: Data) -> Bool {
        data.starts(with: dataMagic)
    }

    static func seal(_ plaintext: Data, key: Data) throws -> Data {
        guard !plaintext.isEmpty else { return plaintext }
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        guard let combined = box.combined else { throw Failure.sealingFailed }
        return dataMagic + combined
    }

    static func open(_ stored: Data, key: Data) throws -> Data {
        guard isSealedData(stored) else { return stored }
        let box = try AES.GCM.SealedBox(
            combined: stored.dropFirst(dataMagic.count)
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    /// 写路径（图片）：失败就抛，绝不退回写明文。
    static func sealDataForStorage(_ plaintext: Data) throws -> Data {
        try seal(plaintext, key: try key())
    }

    /// 读路径（图片）：非密文原样返回；密文解不开返回 `nil` 并记失败原因
    /// ——绝不把密文当图片交出去。
    static func openDataStored(_ stored: Data) -> Data? {
        guard isSealedData(stored) else { return stored }
        do {
            return try open(stored, key: try key())
        } catch {
            noteFailure(error.localizedDescription)
            return nil
        }
    }

    // MARK: - 失败可见性

    /// 最近一次解密失败的原因（`nil` = 没失败过）。UI 用它把"读不到"讲出来，
    /// 而不是安静地显示一张空卡片。
    static var lastFailureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return failureNote
    }

    static func noteFailure(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        failureNote = message
    }

    static func clearFailureNote() {
        lock.lock()
        defer { lock.unlock() }
        failureNote = nil
    }

    // MARK: - Keychain plumbing

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func readKeychain() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, data.count == keyByteCount else {
                throw Failure.keyUnavailable("密钥格式无效")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keyUnavailable(describe(status))
        }
    }

    /// **先加、撞了让位**（P2 修复 2026-10-03）：不再先删后加。钥匙串条目
    /// 写入是原子的，"已存在"只能说明别的实例刚写了完整密钥——那是该采纳的
    /// 事实，不是要清除的残条。返回是否由本次写入占位。
    private static func addKey(_ key: Data) throws -> Bool {
        var add = baseQuery
        add[kSecValueData as String] = key
        // `ThisDeviceOnly` + 不同步：密钥不随备份/iCloud 离开这台机器。
        add[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        default:
            throw Failure.keyUnavailable(describe(status))
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?)
            ?? "OSStatus \(status)"
    }
}
