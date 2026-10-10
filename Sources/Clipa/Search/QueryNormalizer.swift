import Foundation

/// Single source of normalization for content and queries.
///
/// Deliberately does NOT strip punctuation, URLs, code symbols or short
/// tokens: Clipa users search for `192.168`, `::1`, `C++` or `/api/`.
enum QueryNormalizer {
    static func normalize(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // 零宽字符与 BOM（P1 修复 2026-10-02）：网页排版常内嵌
            // U+200B/200C/200D/FEFF，肉眼不可见但参与逐字匹配——从网页复制
            // 的查询会因此搜不到历史里明明存在的原文。两侧（索引与查询）都走
            // 本函数，剥掉即双方一致。NBSP 先折成普通空格，让分词正常断词。
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .precomposedStringWithCanonicalMapping
        // Width and diacritic folding: the search copies must not depend on how
        // the text was typed or pasted. A Chinese IME produces full-width
        // `ＡＢＣ` constantly, and searching for `abc` used to find nothing;
        // `café` was unreachable from `cafe`. Both sides of every comparison go
        // through this function, and the FTS index / `norm_*` columns are
        // rebuilt automatically on upgrade because the fingerprint they are
        // stored with is derived from the probe outputs below.
        result = result.folding(
            options: [.widthInsensitive, .diacriticInsensitive],
            locale: nil
        )
        // Consistent newline handling without flattening meaningful content.
        result = result.lowercased()
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeQuery(_ value: String) -> String {
        normalize(value)
    }

    /// Searchable memory text: keywords match `note` and clipboard body text.
    static func searchable(text: String, note: String) -> String {
        let body = normalize(text)
        let noteText = normalize(note)
        if body.isEmpty { return noteText }
        if noteText.isEmpty { return body }
        return body + "\n" + noteText
    }

}
