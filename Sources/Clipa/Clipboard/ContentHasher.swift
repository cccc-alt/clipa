import CommonCrypto
import Foundation

/// SHA-256 helpers used only for duplicate detection. The hash is a storage
/// field, never a full-text search field.
enum ContentHasher {
    static func hash(text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return sha256Hex(Data(normalized.utf8))
    }

    static func hash(data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return sha256Hex(data)
    }

    static func hash(fileURLs: [URL]) -> String? {
        let paths = fileURLs
            .map { $0.path }
            .sorted()
            .joined(separator: "\n")
        return hash(text: paths)
    }

    static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
