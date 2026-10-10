import CryptoKit
import Foundation
import Security

/// 数据库整库加密密钥（SQLCipher passphrase）。
///
/// 每个工作区一把 256-bit 随机密钥，存本机钥匙串（`ThisDeviceOnly`、不同步、
/// 不随备份离开这台机器）。取用纪律与 `StoreCrypto.key()` 相同：**存在即复用，
/// 并发先到者赢，绝不先删后建**（P2#1 修复的同款）。
///
/// 传给 SQLCipher 用 `x'<hex>'` 形式（`PRAGMA key` / `ATTACH … KEY` 的
/// raw-key 语法）：密钥本身就是随机字节，走 raw 语法可以跳过 KDF 派生——
/// 那是给"人能记住的口令"用的，对随机密钥只是每次打开白付几十毫秒。
enum DBKey {
    /// 打不开钥匙串时的错误面：调用方把它映射到"数据库不可用"恢复态。
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "数据库密钥不可用：\(reason)" }
    }

    private static let keychainService = "com.clipa.desktop"
    private static let keyByteCount = 32
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    /// CLI 探针/自检的钥匙串隔离（与 `StoreCrypto.isolationKey` 同源同生命周期）：
    /// 设定后密钥从种子+路径确定性派生，不碰用户钥匙串、不产生条目垃圾。
    static var isolationSeed: Data?

    /// 返回 `x'<64 位 hex>'` 形式的密钥表达式；钥匙串不可用时返回 nil。
    static func rawKeyExpression(
        databasePath: String, createIfMissing: Bool = true
    ) -> String? {
        // 隔离模式（自检/探针）：种子+路径确定性派生，零钥匙串参与。
        if let seed = isolationSeed {
            var material = seed
            material.append(Data(databasePath.utf8))
            let hex = SHA256.hash(data: material)
                .map { String(format: "%02x", $0) }
                .joined()
            return "x'\(hex)'"
        }
        let account = "db-key-\(pathHash(databasePath))"
        lock.lock()
        defer { lock.unlock() }
        if let hex = cache[account] { return "x'\(hex)'" }
        do {
            if let stored = try readKeychain(account: account) {
                cache[account] = stored
                return "x'\(stored)'"
            }
            // A missing key for ciphertext is a recovery condition. Generating
            // a replacement would permanently associate the path with a wrong key.
            guard createIfMissing else { return nil }
            var bytes = [UInt8](repeating: 0, count: keyByteCount)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                NSLog("Clipa DBKey 随机密钥生成失败：\(status)")
                return nil
            }
            let fresh = bytes.map { String(format: "%02x", $0) }.joined()
            if try addKeychain(hex: fresh, account: account) {
                cache[account] = fresh
                return "x'\(fresh)'"
            }
            // 撞条目：采纳先到者（与 StoreCrypto 同款）。
            guard let winner = try readKeychain(account: account) else {
                return nil
            }
            cache[account] = winner
            return "x'\(winner)'"
        } catch {
            NSLog("Clipa DBKey 钥匙串读写失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 路径 → 稳定的 account 后缀（同一路径映射同一条目、不同路径互不覆盖；
    /// 不追求密码学强度）。
    private static func pathHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Keychain

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            // 存进去的就是 hex 字符串本体（addKeychain 用 Data(hex.utf8)），
            // 读回必须是 UTF-8 还原——不能再把字节二次 hex 化（那会把 64 字符
            // 的密钥变成 128 字符的错误密钥，第二次进程打开就 NOTADB）。
            guard let data = out as? Data,
                  let hex = String(data: data, encoding: .utf8),
                  isValidHexKey(hex) else {
                throw Failure(reason: "密钥格式无效")
            }
            return hex
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(reason: "OSStatus \(status)")
        }
    }

    static func isValidHexKey(_ hex: String) -> Bool {
        hex.utf8.count == keyByteCount * 2 && hex.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func addKeychain(hex: String, account: String) throws -> Bool {
        var add = baseQuery(account: account)
        add[kSecValueData as String] = Data(hex.utf8)
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
            throw Failure(reason: "OSStatus \(status)")
        }
    }
}
