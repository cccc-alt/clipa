import Foundation

enum FTSQueryBuilder {

    static func buildANDQuery(terms: [String]) -> String? {
        let safe = terms.filter { SearchQuery.canUseFTS(term: $0) }
        guard !safe.isEmpty else { return nil }
        let quoted = safe.map { escapedPhrase($0) }
        return quoted.joined(separator: " AND ")
    }

    static func buildGroupQuery(groups: [[String]]) -> String? {
        guard !groups.isEmpty else { return nil }
        var clauses: [String] = []
        for group in groups {

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
