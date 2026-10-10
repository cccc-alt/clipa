import Foundation

/// Display-oriented smart tags.
///
/// Product decision (2026-09-11): the taxonomy is text / JSON / YAML /
/// Markdown / image / file. URL, code, log, shell command, IP and email are no
/// longer types — such content is plain text. Tags are produced together with
/// the persisted base kind (text / image / file) so the two layers never
/// disagree.
enum SmartTag: String, CaseIterable, Equatable, Hashable, Sendable {
    case text
    case json
    case yaml
    case markdown
    case image
    case file

    var displayName: String {
        switch self {
        case .text: return "文本"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .json: return "curlybraces"
        case .yaml: return "list.bullet.indent"
        case .markdown: return "textformat"
        case .image: return "photo"
        case .file: return "folder"
        }
    }

    /// 类型色（见 `ClipKind.tintHex`）：六种类型六个可分辨的色。
    ///
    /// 唯一的硬要求始终是**两两可分辨**，载体换过两次（色相 → 线型 → 色相）。
    /// 这里的色值都留在冷色一侧（板岩 / 琥珀 / 青绿 / 蓝 / 紫 / 蓝灰），
    /// 压在模糊的玻璃面上是一家人，不会像外挂的调色盘。
    var tintHex: String {
        switch self {
        case .text: return "55636E"
        case .json: return "E8A33D"
        case .yaml: return "12B5A4"
        case .markdown: return "0A84FF"
        case .image: return "7B61FF"
        case .file: return "7C8798"
        }
    }
}

/// One classification result that keeps the coarse persisted kind and the
/// display-oriented smart tag consistent.
struct SmartClassification: Sendable, Equatable {
    let kind: ClipKind
    let smartTag: SmartTag
}

enum SmartClassifier {
    private static let sensitivePatterns: [(name: String, pattern: String)] = [
        ("OpenAI Key", #"sk-[A-Za-z0-9]{20,}"#),
        ("AWS Key", #"AKIA[0-9A-Z]{16}"#),
        ("GitHub Token", #"gh[pousr]_[A-Za-z0-9]{20,}"#),
        ("Bearer Token", #"(?i)\bbearer\s+(?<value>[A-Za-z0-9\-._~+/]{8,}={0,2})"#),
        ("Slack Token", #"xox[baprs]-[A-Za-z0-9\-]+"#),
        ("Private Key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        // Label rules accept a quote on either side of the separator, so a
        // structured payload (`{"password": "…"}` / `"api_key":"…"`) reads the
        // same as a plain `password: …` line. This is still shape matching on
        // the raw string: sensitive detection must not depend on whether the
        // content was classified as JSON/YAML.
        // The unquoted branch must not start on a quote, or a short quoted
        // value (`{"password": "abc"}`) gets matched by swallowing the closing
        // quote and brace.
        ("Password Label", #"(?i)(?:password|passwd|密码|口令)["']?\s*[:=：]\s*(?<value>"[^\s,;，。"]{6,}"|'[^\s,;，。']{6,}'|[^\s,;，。"']{6,})"#),
        ("Named Credential Label", #"(?i)\b(?:api[ _-]?key|access[ _-]?token|auth[ _-]?token|client[ _-]?secret|refresh[ _-]?token|secret[ _-]?key|private[ _-]?key|私钥|密钥|访问令牌)["']?\s*[:=：]\s*(?<value>"[^\s,;，。"]{8,}"|'[^\s,;，。']{8,}'|[^\s,;，。"']{8,})"#),
        ("Opaque Token Label", #"(?i)\b(?:token|令牌)["']?\s*[:=：]\s*(?<value>"[A-Za-z0-9_\-./+=]{12,}"|'[A-Za-z0-9_\-./+=]{12,}'|[A-Za-z0-9_\-./+=]{12,})"#)
    ]
    private static let sensitiveRegexes: [NSRegularExpression] =
        sensitivePatterns.compactMap {
            try? NSRegularExpression(pattern: $0.pattern)
        }

    /// Best-effort tag for a stored clip.
    static func tag(for item: Clip) -> SmartTag {
        inferredTag(text: item.text, kind: item.kind)
    }

    /// Recomputes a SmartTag without relying on persisted classification.
    static func inferredTag(
        text: String,
        kind: ClipKind
    ) -> SmartTag {
        inferredClassification(text: text, kind: kind).smartTag
    }

    /// Single entry point for content classification.
    ///
    /// Physical clip kinds (image/file) are immutable. Text-like content runs
    /// through the format engine; anything it does not recognize stays plain
    /// text. The returned pair is what callers must persist so `ClipKind` and
    /// `SmartTag` never disagree.
    static func inferredClassification(
        text: String,
        kind: ClipKind
    ) -> SmartClassification {
        switch kind {
        case .image:
            return SmartClassification(kind: .image, smartTag: .image)
        case .file:
            return SmartClassification(kind: .file, smartTag: .file)
        case .text:
            break
        }

        if text.isEmpty {
            return SmartClassification(kind: .text, smartTag: .text)
        }

        if let classified = ClassificationEngine.classify(text) {
            return SmartClassification(
                kind: Self.kind(for: classified, fallbackKind: kind),
                smartTag: classified
            )
        }

        return SmartClassification(kind: .text, smartTag: .text)
    }

    /// Maps a smart tag back to the coarse persisted kind.
    static func kind(
        for smartTag: SmartTag,
        fallbackKind: ClipKind
    ) -> ClipKind {
        switch smartTag {
        case .image:
            return .image
        case .file:
            return .file
        case .json, .yaml, .markdown, .text:
            return .text
        }
    }

    // MARK: - JSON

    static func isJSON(_ text: String) -> Bool {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        // 校验交给 Foundation 的 JSONSerialization（原 JSONTree 子集解析器
        // 已于 2026-09-30 移除）。前缀保证顶层是容器，无碎片歧义。
        guard let object = try? JSONSerialization.jsonObject(
                  with: Data(trimmed.utf8)
              ) else { return false }
        return object is [Any] || object is [String: Any]
    }

    // MARK: - YAML

    /// Best-effort YAML block detection. Conservative on purpose: only
    /// multi-line text with real mapping structure (`key: value` / `key:`
    /// followed by more structure) is tagged as YAML, so notes and prose with a
    /// stray colon are not mislabelled. JSON is excluded (handled above).
    static func isYAML(_ text: String) -> Bool {
        return ClassificationEngine.classify(text) == .yaml
    }

    // MARK: - Sensitive

    static func isSensitive(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for regex in sensitiveRegexes {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(
                in: text,
                range: range
            ) {
                let valueRange = match.range(withName: "value")
                guard valueRange.location != NSNotFound,
                      let value = Range(valueRange, in: text)
                        .map({ String(text[$0]) }) else {
                    return true
                }
                if !Self.isPlaceholderValue(value) {
                    return true
                }
            }
        }
        return false
    }

    /// Labels such as `password: your-password-123` or
    /// `token: <example-token>` describe an example, not a real credential.
    private static func isPlaceholderValue(_ raw: String) -> Bool {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Wrappers only — the inner text still has to be a whole value, so
            // `[parameters('x')]` normalises to the ARM reference it is.
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>[]"))
        // A crypt hash is credential material, whatever it starts with, so it
        // is exempt before any placeholder rule runs.
        if isCryptHashValue(value) { return false }
        if isReferenceValue(value) { return true }
        let lower = value.lowercased()
        let literalMarkers = [
            "null", "none", "nil", "false", "true", "redacted",
            "not set", "unknown", "changeme", "changethis", "placeholder",
            "your", "example", "sample", "xxxx", "xxxxx", "xxx",
            "你的", "示例", "测试值", "替换", "待填", "请替换"
        ]
        return literalMarkers.contains { lower.hasPrefix($0) }
    }

    /// `$1$`, `$2b$`, `$5$`, `$6$`, `$y$`, `$argon2id$` … the `$id$salt$hash`
    /// family. These begin with `$` exactly like a shell variable does, so the
    /// reference rule below has to yield to them.
    private static let cryptHashPattern =
        #"^\$(?:0|1|2[a-z]?|3|5|6|7|y|md5|sha1|scrypt|argon2(?:id|i|d)?)\$"#
    private static let cryptHashRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: cryptHashPattern)

    /// A value that *points at* a secret instead of being one. Anchored, and
    /// only a whole value counts: `$y$j9T$…` starts with `$y`, and a
    /// `abc${REF}xyz` value is still a literal, so neither may be downgraded.
    private static let referencePatterns = [
        #"^\$[A-Za-z_][A-Za-z0-9_]*$"#,   // $VAR
        #"^\$\{[^}]*\}$"#,                 // ${VAR}, ${VAR:-x}, ${VAR:=x}
        #"^\$\([^)]*\)$"#,                 // $(command)
        #"^\$\{\{.*\}\}$"#,                // ${{ secrets.X }}
        #"^\{\{.*\}\}$"#,                  // {{ var }}
        #"^@env:[A-Za-z0-9_]+$"#,          // Home Assistant
        #"^parameters\(.*\)$"#             // ARM template reference
    ]
    private static let referenceRegexes: [NSRegularExpression] =
        referencePatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    private static func isReferenceValue(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return referenceRegexes.contains {
            $0.firstMatch(in: value, range: range) != nil
        }
    }

    private static func isCryptHashValue(_ value: String) -> Bool {
        guard let cryptHashRegex, !value.isEmpty else { return false }
        return cryptHashRegex.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) != nil
    }
}

extension Clip {
    var isSensitiveContent: Bool {
        if containsSensitive { return true }
        guard !text.isEmpty || !note.isEmpty else { return false }
        return SensitiveDetector.containsSensitive(self)
    }
}
