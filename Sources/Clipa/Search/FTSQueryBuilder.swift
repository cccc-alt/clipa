import Foundation

/// Builds and escapes an FTS5 query. Callers never concatenate user terms.
enum FTSQueryBuilder {
    /// `terms` must already be normalized and individually FTS-eligible.
    static func buildANDQuery(terms: [String]) -> String? {
        let safe = terms.filter { SearchQuery.canUseFTS(term: $0) }
        guard !safe.isEmpty else { return nil }
        let quoted = safe.map { escapedPhrase($0) }
        return quoted.joined(separator: " AND ")
    }

    /// Builds `(A OR B) AND C AND ...`.
    ///
    /// Groups that contain short/memory-only terms cannot be expressed by
    /// FTS5 exactly. Such groups are skipped here — never mixed into a
    /// partial OR clause — and the memory validator still enforces them
    /// afterwards. The FTS query is therefore always a strict subset of the
    /// final semantics, so recall stays sound.
    static func buildGroupQuery(groups: [[String]]) -> String? {
        guard !groups.isEmpty else { return nil }
        var clauses: [String] = []
        for group in groups {
            // A whole OR group may only enter FTS when every term can be
            // represented; dropping one term would change OR semantics.
            guard group.allSatisfy({ SearchQuery.canUseFTS(term: $0) }) else {
                continue
            }
            clauses.append(
                "(" + group.map { escapedPhrase($0) }.joined(separator: " OR ") + ")"
            )
        }
        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " AND ")
    }

    static func escapedPhrase(_ term: String) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"" + escaped + "\""
    }
}
