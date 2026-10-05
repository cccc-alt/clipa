import Foundation

enum BundleIDNormalizer {

    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

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
