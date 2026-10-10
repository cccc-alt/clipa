import Foundation

/// Bundle identifiers reach Clipa from several places — LaunchServices,
/// defaults edited by hand, entries written by older versions — so they are
/// normalized before being stored or compared.
///
/// LaunchServices resolves bundle identifiers case-insensitively (verified:
/// `com.apple.safari` and `COM.APPLE.SAFARI` both resolve to Safari.app), so
/// matching is case-insensitive too. That makes a hand-typed or imported entry
/// behave the same as one captured from a running app.
enum BundleIDNormalizer {
    /// Trimmed and lowercased; `nil` when nothing usable is left.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    /// Normalizes a list, dropping blanks and duplicates while keeping the
    /// original order so the settings list does not jump around.
    static func normalize(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in list {
            guard let normalized = normalize(item) else { continue }
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }
}
