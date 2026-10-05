import CryptoKit
import Foundation
import Security

/// Per-workspace SQLCipher key (keychain, ThisDeviceOnly).
enum DBKey {

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "数据库密钥不可用：\(reason)" }
    }

    private static let keychainService = "com.clipa.desktop"
    private static let keyByteCount = 32
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    static var isolationSeed: Data?

    static func rawKeyExpression(databasePath: String) -> String? {

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

    private static func pathHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

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

            guard let data = out as? Data,
                  let hex = String(data: data, encoding: .utf8) else {
                return nil
            }
            return hex
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(reason: "OSStatus \(status)")
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
