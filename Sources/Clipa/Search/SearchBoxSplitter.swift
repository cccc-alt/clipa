import Foundation

struct SearchBoxSplit: Equatable, Sendable {
    let raw: String
    let scopeText: String

    var hasScope: Bool {
        !scopeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum SearchBoxSplitter {
    static func split(_ rawQuery: String) -> SearchBoxSplit {
        let raw = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchBoxSplit(raw: raw, scopeText: raw)
    }
}
