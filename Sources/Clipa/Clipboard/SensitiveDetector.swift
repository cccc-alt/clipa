import Foundation

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

        #"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,

        #"(?:mysql|postgres(?:ql)?|mongodb(?:\+srv)?|redis)://[^\s:"']+:[^\s@]+@"#,

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
