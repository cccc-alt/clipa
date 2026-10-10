import Foundation

/// Decides whether a normalized string may be matched by SQLite's `instr()`
/// instead of Swift's `String.contains`.
///
/// The oracle compares grapheme clusters with canonical equivalence, while
/// `instr()` compares scalars. The two agree when both strings are NFC and:
///
/// 1. every grapheme cluster is exactly one scalar — otherwise a needle can be
///    a scalar prefix of a cluster and `instr()` would match where Swift sees
///    a different character (`"👨"` inside `"👨‍👩‍👧"`, a skin-tone
///    modifier, a flag, jamo, a prepend character, …);
/// 2. no combining mark is present — a substring of an NFC string can be
///    non-NFC, so a mark left standalone (or blocked from composing, such as
///    `"각" + U+0301`) is the only way left for canonical equivalence to
///    differ from byte equality.
///
/// NFC is applied by `QueryNormalizer` on both clips and queries, and
/// normalization can *introduce* a mark (`İ` lowercases to `i` + U+0307), so
/// this must be evaluated on the normalized value, never on the raw clip.
enum SearchTextSafety {
    static func isByteSubstringSafe(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        // `count` walks grapheme clusters, `unicodeScalars.count` walks
        // scalars: equal counts mean every character is a single scalar.
        guard value.count == value.unicodeScalars.count else { return false }
        for scalar in value.unicodeScalars
        where isCombiningMark(scalar) {
            return false
        }
        return true
    }

    static func isByteSubstringSafe(text: String, note: String) -> Bool {
        isByteSubstringSafe(text) && isByteSubstringSafe(note)
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}
