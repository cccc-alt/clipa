import Foundation

/// What the user typed in the single search box.
///
/// The box is one local-search field: `scopeText` is the query itself,
/// trimmed. An earlier version split an "AI instruction" out of the same field
/// and sent that half to a model; that layer was removed along with the rest of
/// the AI features, so the type now carries a single scope.
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
