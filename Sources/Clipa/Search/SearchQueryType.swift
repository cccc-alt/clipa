import Foundation

/// Coarse shape of a query before planning. Used to decide whether a failed
/// local recall may be retried with a broader AI-search recall plan.
enum SearchQueryType: Equatable, Sendable {
    /// Clean terms such as `Terway`, `docker network` or `网络`.
    case plainKeyword
    /// Free-form description such as “我之前复制过一个关于 … 的东西”.
    case naturalLanguage
}
