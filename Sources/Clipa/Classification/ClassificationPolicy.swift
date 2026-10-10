import Foundation

/// Monotonic classifier version. Bump whenever `ClassificationEngine`,
/// `SmartClassifier`, or sensitive detection rules change so old rows can be
/// reclassified in the background.
enum ClassificationPolicy {
    /// v1: P0 unified classification chain.
    /// v2: P1 command/IP/email/YAML rules + schema v6 metadata.
    /// v3: 2026-09-11 taxonomy — only text / JSON / YAML / Markdown / image /
    /// file survive; link, code, log, command, IP and email are retired, so
    /// every stale row is re-derived from its content.
    /// v4: 2026-09-12 sensitive rules — label rules accept a quoted key
    /// (`{"password": "…"}`), so persisted `contains_sensitive` rows are
    /// re-evaluated once.
    /// v5: 2026-09-12 P0 — a value that is *entirely* a reference/template
    /// (`${VAR}`, `$VAR`, `$(cmd)`, `${{ … }}`, `@env:X`, `parameters(…)`) is
    /// no longer a credential; crypt hashes (`$6$…`, `$y$…`) stay sensitive.
    static let currentVersion = 5
}
