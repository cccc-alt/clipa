import Foundation

/// Local sensitive-data detection. Pure pattern matching — no network, no
/// model. Its result is stored on the clip as `contains_sensitive`, which
/// drives the panel's 🔐 marker and the "只看敏感内容" search filter.
enum SensitiveDetector {
    static func containsSensitive(_ clip: Clip) -> Bool {
        containsSensitive(text: clip.text, note: clip.note)
    }

    static func containsSensitive(text: String, note: String = "") -> Bool {
        if SmartClassifier.isSensitive(text) { return true }
        if !note.isEmpty, SmartClassifier.isSensitive(note) { return true }
        return hasExtraSensitiveContent(text) || hasExtraSensitiveContent(note)
    }

    private static let extraPatterns = [
        // JWT
        #"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
        // Database URLs with credentials
        #"(?:mysql|postgres(?:ql)?|mongodb(?:\+srv)?|redis)://[^\s:"']+:[^\s@]+@"#,
        // SSH private key blocks
        #"-----BEGIN (?:OPENSSH|RSA|EC|DSA) PRIVATE KEY-----"#
    ]
    private static let extraRegexes: [NSRegularExpression] =
        extraPatterns.compactMap {
            try? NSRegularExpression(pattern: $0)
        }

    private static func hasExtraSensitiveContent(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for regex in extraRegexes {
            if regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ) != nil {
                return true
            }
        }
        return false
    }
}
