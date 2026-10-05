import Foundation

enum QueryNormalizer {
    static func normalize(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .precomposedStringWithCanonicalMapping

        result = result.folding(
            options: [.widthInsensitive, .diacriticInsensitive],
            locale: nil
        )

        result = result.lowercased()
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeQuery(_ value: String) -> String {
        normalize(value)
    }

    static func searchable(text: String, note: String) -> String {
        let body = normalize(text)
        let noteText = normalize(note)
        if body.isEmpty { return noteText }
        if noteText.isEmpty { return body }
        return body + "\n" + noteText
    }

}
