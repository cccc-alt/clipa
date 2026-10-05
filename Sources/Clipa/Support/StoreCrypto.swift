import CryptoKit
import Foundation
import Security

/// Field-level AES-GCM sealing for private items; key in the device keychain.
enum StoreCrypto {
    static let envelopePrefix = "clipa1:"
    static let keyByteCount = 32

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

    static func isEnvelope(_ value: String) -> Bool {
        value.hasPrefix(envelopePrefix)
    }

    static func seal(_ plaintext: String, key: Data) throws -> String {

        guard !plaintext.isEmpty else { return plaintext }
        let box = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: SymmetricKey(data: key)
        )
        guard let combined = box.combined else { throw Failure.sealingFailed }
        return envelopePrefix + combined.base64EncodedString()
    }

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

    private static let lock = NSLock()
    private static var cachedKey: Data?
    private static var failureNote: String?

    static var isolationKey: Data?

    static func generateKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw Failure.keyUnavailable(describe(status))
        }
        return Data(bytes)
    }

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

        guard let winner = try readKeychain() else {
            throw Failure.keyUnavailable("并发写入钥匙串后读取失败")
        }
        cachedKey = winner
        return winner
    }

    static func forgetCachedKey() {
        lock.lock()
        defer { lock.unlock() }
        cachedKey = nil
    }

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

    static func sealForStorage(_ plaintext: String) throws -> String {
        try seal(plaintext, key: try key())
    }

    static func openStored(_ stored: String) -> String? {
        guard isEnvelope(stored) else { return stored }
        do {
            return try open(stored, key: try key())
        } catch {
            noteFailure(error.localizedDescription)
            return nil
        }
    }

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

    static func sealDataForStorage(_ plaintext: Data) throws -> Data {
        try seal(plaintext, key: try key())
    }

    static func openDataStored(_ stored: Data) -> Data? {
        guard isSealedData(stored) else { return stored }
        do {
            return try open(stored, key: try key())
        } catch {
            noteFailure(error.localizedDescription)
            return nil
        }
    }

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
            guard let data = out as? Data else {
                throw Failure.keyUnavailable("条目里没有数据")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keyUnavailable(describe(status))
        }
    }

    private static func addKey(_ key: Data) throws -> Bool {
        var add = baseQuery
        add[kSecValueData as String] = key

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
