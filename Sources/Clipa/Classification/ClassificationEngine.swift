import Foundation

enum ClassificationConfidence: Sendable {
    case low
    case medium
    case high
}

enum ClassificationReason: Sendable, Equatable {
    case parserValidated
    case multipleKeyValuePairs
    case nestedIndentation
    case yamlList
    case yamlDocumentMarker
    case kubernetesStructure

    /// Penalty signals that stop structured formats from claiming log-shaped
    /// or prose-shaped text.
    case timestamp
    case decodeFailure
    case exception
    case stackTrace
    case naturalLanguage

    case strictJSON

    /// Structure that argues for the *other* format: `#` headings read as
    /// Markdown headings, or a wall of `key: value` mappings read as YAML.
    case markdownStructure
    case yamlMapping

    /// YAML accepted on structural evidence because the subset parser could not
    /// validate it (Kubernetes manifests, CI configuration, templates).
    case structuralFallback

    case custom(String)
}

struct ClassificationResult: Sendable {
    let tag: SmartTag
    let score: Double
    let confidence: ClassificationConfidence
    let reasons: [ClassificationReason]
}

struct TextFeatures: Sendable {
    let hasTimestamp: Bool
    let hasDecodeFailure: Bool
    let hasException: Bool
    let hasStackTrace: Bool
    let hasFatalError: Bool
    let hasNaturalLanguage: Bool
}

struct ClassificationContext: Sendable {
    let originalText: String
    let trimmedText: String
    let lowercaseText: String
    let lines: [String]
    let nonEmptyLines: [String]
    let lineCount: Int
    let nonEmptyLineCount: Int
    let characterCount: Int
    /// `#`…`######` followed by text — Markdown headings, which YAML would
    /// otherwise read as comments.
    let atxHeadingCount: Int
    /// Lines opening a YAML mapping (`key:` / `key: value`), comments excluded.
    let mappingLineCount: Int
    let textFeatures: TextFeatures

    init(text: String) {
        let sample = String(text.prefix(100_000))
        originalText = text
        trimmedText = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        lowercaseText = trimmedText.lowercased()
        lines = trimmedText.components(separatedBy: "\n")
        nonEmptyLines = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        lineCount = lines.count
        nonEmptyLineCount = nonEmptyLines.count
        characterCount = trimmedText.count
        var headings = 0
        var mappings = 0
        for line in nonEmptyLines {
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let rest = line.dropFirst(hashes)
                if (1...6).contains(hashes),
                   rest.hasPrefix(" ") || rest.hasPrefix("\t") {
                    headings += 1
                }
                continue
            }
            if Self.isMappingLine(line) { mappings += 1 }
        }
        atxHeadingCount = headings
        mappingLineCount = mappings
        textFeatures = TextFeatureExtractor.extract(
            trimmedText: trimmedText,
            lowercaseText: lowercaseText,
            nonEmptyLines: nonEmptyLines
        )
    }

    /// Cheap `key:` / `key: value` test used only to tell YAML-dominant text
    /// from heading-dominant text.
    ///
    /// P1 修复（2026-10-02）：与 `YAMLFeatureDetector.mappingLineRegex`
    /// （`^\s*[\p{L}\p{N}_.-]+\s*:(?:\s.*)?$`）语义对齐——冒号后必须是
    /// **行尾或空白**。旧版只看冒号前的 key，`https://a.com` 的 key 是
    /// "https"、后面跟着 "//a.com"，也被当成映射行；两行 URL + 两行键值
    /// 就能凑出 0.70 的 YAML 分越过 0.50 阈值。两版必须一致：它们共同喂给
    /// YAML 打分与 Markdown 惩罚。
    static func isMappingLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let key = trimmed[trimmed.startIndex..<colon]
        guard let first = key.first,
              first.isLetter || first == "_" else { return false }
        guard key.allSatisfy({
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-"
        }) else { return false }
        let remainder = trimmed[trimmed.index(after: colon)...]
        return remainder.isEmpty || remainder.first!.isWhitespace
    }
}

/// YAML 的**形状校验**（2026-09-30）：自带的 704 行子集解析器 `YAMLSubset`
/// 随"精简解析器"一并移除，改用行级结构检查回答同一个问题——
/// "这段文本能不能如实当作 YAML 块来标注"。
///
/// 它不是解析器：块标量的续行、锚点引用的展开仍可能看走眼。看不准时
/// 交给原有的结构回退（k8s 结构 / 映射行密度），两道都不过就不标 ——
/// 把 YAML 误标成文本，永远比把文本误标成 YAML 便宜。
private enum YAMLShape {
    /// 每个有内容的行都必须是映射行、序列项、注释或文档标记，且至少要有
    /// 一行结构 —— 全部满足才算"能按块 YAML 理解"。
    static func looksLikeParsableBlock(_ text: String) -> Bool {
        var sawStructure = false
        for rawLine in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "---" || line == "..." {
                sawStructure = true
                continue
            }
            if line.hasPrefix("- ") || line == "-" {
                sawStructure = true
                continue
            }
            if ClassificationContext.isMappingLine(line) {
                sawStructure = true
                continue
            }
            return false
        }
        return sawStructure
    }

    /// 会改变 YAML 语义而这套检查不支持的构造：锚点/别名（`&`/`*`）、
    /// 标签（`!`）、合并键（`<<:`）、多文档。形状像 YAML 且带这些构造的
    /// 文本由调用方走"形状支持不了 + 两个结构信号"的既有路径。
    static func hasUnsupportedConstructs(_ text: String) -> Bool {
        var documentMarkers = 0
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line == "---" || line.hasPrefix("--- ") {
                documentMarkers += 1
                if documentMarkers > 1 { return true }
            }
            if line.hasPrefix("&") || line.hasPrefix("*")
                || line.hasPrefix("!") || line.contains("<<:") {
                return true
            }
        }
        return false
    }
}

protocol ContentClassifier: Sendable {
    var tag: SmartTag { get }
    func classify(_ context: ClassificationContext) -> ClassificationResult?
}

enum ClassificationEngine {
    private static let classifiers: [any ContentClassifier] = [
        JSONClassifier(),
        YAMLClassifier(),
        MarkdownClassifier()
    ]

    static func classify(_ text: String) -> SmartTag? {
        let context = ClassificationContext(text: text)
        let results = classifiers.compactMap { $0.classify(context) }
        return ClassificationResolver.resolve(results)
    }

    static func classifyDetailed(_ text: String) -> [ClassificationResult] {
        let context = ClassificationContext(text: text)
        return classifiers.compactMap { $0.classify(context) }
    }
}

enum ClassificationResolver {
    static func resolve(
        _ results: [ClassificationResult]
    ) -> SmartTag? {
        guard !results.isEmpty else { return nil }
        let accepted = results.filter {
            $0.score >= threshold(for: $0.tag)
        }
        guard !accepted.isEmpty else { return nil }
        return accepted.sorted(by: compare).first?.tag
    }

    static func threshold(for tag: SmartTag) -> Double {
        switch tag {
        case .json: return 0.90
        case .yaml: return 0.50
        case .markdown: return 0.40
        case .text, .image, .file: return 1.0
        }
    }

    private static func compare(
        _ lhs: ClassificationResult,
        _ rhs: ClassificationResult
    ) -> Bool {
        let difference = abs(lhs.score - rhs.score)
        if difference >= 0.05 {
            return lhs.score > rhs.score
        }
        return priority(lhs.tag) > priority(rhs.tag)
    }

    private static func priority(_ tag: SmartTag) -> Int {
        switch tag {
        case .json: return 100
        case .yaml: return 70
        case .markdown: return 65
        case .text, .image, .file: return 0
        }
    }
}

private enum TextFeatureExtractor {
    /// Matched anywhere in the text with `anchorsMatchLines`, so "some line
    /// starts with a timestamp" is a single pass instead of one regex per line.
    private static let timestampRegex = try? NSRegularExpression(
        pattern: #"^\[?(?:\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?|\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?|\d{2}:\d{2}:\d{2}(?:\.\d+)?|[A-Za-z]{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})"#,
        options: [.anchorsMatchLines]
    )
    private static let decodeFailureRegex = try? NSRegularExpression(
        pattern: #"(?:decode failed|decoding failed|failed to decode|unable to decode|decode error)"#,
        options: [.caseInsensitive]
    )
    private static let stackTraceRegex = try? NSRegularExpression(
        pattern: #"(?:stack trace|traceback|File \"|^\s+at\s+)"#,
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    static func extract(
        trimmedText: String,
        lowercaseText: String,
        nonEmptyLines: [String]
    ) -> TextFeatures {
        let hasTimestamp = timestampRegex?.firstMatch(
            in: trimmedText,
            range: NSRange(trimmedText.startIndex..., in: trimmedText)
        ) != nil
        let hasDecodeFailure = decodeFailureRegex?.firstMatch(
            in: lowercaseText,
            range: NSRange(lowercaseText.startIndex..., in: lowercaseText)
        ) != nil
        let hasException = lowercaseText.contains("exception")
        let hasStackTrace = stackTraceRegex?.firstMatch(
            in: trimmedText,
            range: NSRange(trimmedText.startIndex..., in: trimmedText)
        ) != nil
        let hasFatalError =
            lowercaseText.contains("fatal error")
            || lowercaseText.contains("[fatal]")

        let hasNaturalLanguage =
            nonEmptyLines.count >= 2
            && nonEmptyLines.filter {
                $0.contains("。")
                    || $0.contains("！")
                    || $0.contains("？")
                    || $0.count > 40
            }.count * 2 > nonEmptyLines.count

        return TextFeatures(
            hasTimestamp: hasTimestamp,
            hasDecodeFailure: hasDecodeFailure,
            hasException: hasException,
            hasStackTrace: hasStackTrace,
            hasFatalError: hasFatalError,
            hasNaturalLanguage: hasNaturalLanguage
        )
    }
}

private struct JSONClassifier: ContentClassifier {
    let tag: SmartTag = .json

    /// Parsing the whole document is what makes large JSON recognizable, but
    /// the cost has to stay bounded; anything beyond this is left to the
    /// sampled heuristics.
    private static let maxParseBytes = 8 * 1024 * 1024

    func classify(
        _ context: ClassificationContext
    ) -> ClassificationResult? {
        // The context samples the first 100k characters for the structural
        // heuristics, and a truncated prefix of a large JSON file never parses
        // — which is why every JSON over 100k was previously filed as text.
        // Strict parsing needs the complete document.
        let text = context.originalText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard text.hasPrefix("{") || text.hasPrefix("[") else { return nil }
        guard text.utf8.count <= Self.maxParseBytes else { return nil }
        // 校验交给 Foundation 的 JSONSerialization：系统实现、同样严格，
        // 替代原先自带的 JSONTree 子集解析器（2026-09-30 随"精简解析器"移除）。
        // 前缀已保证顶层是容器，命中的必然是字典或数组，不存在碎片歧义。
        guard let object = try? JSONSerialization.jsonObject(
                  with: Data(text.utf8)
              ),
              object is [Any] || object is [String: Any]
        else { return nil }
        return ClassificationResult(
            tag: .json,
            score: 1.0,
            confidence: .high,
            reasons: [.strictJSON, .parserValidated]
        )
    }
}

private struct YAMLClassifier: ContentClassifier {
    let tag: SmartTag = .yaml

    func classify(
        _ context: ClassificationContext
    ) -> ClassificationResult? {
        let features = YAMLFeatureDetector.detect(context)
        let parseable = YAMLShape.looksLikeParsableBlock(context.trimmedText)
        let unsupportedShaped = YAMLShape.hasUnsupportedConstructs(
            context.trimmedText
        )
        let parserValidated =
            parseable
            || (unsupportedShaped && features.structuralSignalCount >= 2)

        // Structural fallback. The subset parser rejects plenty of real-world
        // YAML — Kubernetes manifests and CI configuration among them — and
        // those files are neither parser-validated nor "shaped but
        // unsupported", so they used to be filed as plain text. Accept them
        // when the structure is unmistakable, with prose and Markdown ruled
        // out first.
        let firstMeaningful = context.nonEmptyLines.first {
            !$0.hasPrefix("#")
        }
        let startsLikeYAML = firstMeaningful.map {
            ClassificationContext.isMappingLine($0) || $0.hasPrefix("- ")
        } ?? false
        let mappingDensity = Double(context.mappingLineCount)
            / Double(max(1, context.nonEmptyLineCount))
        let structurallyYAML =
            startsLikeYAML
            && (
                features.hasKubernetesStructure
                || (context.mappingLineCount >= 8 && mappingDensity >= 0.5)
            )
            && !context.textFeatures.hasNaturalLanguage
            && !features.hasChineseProsePairs
            // Headings block the fallback only when they *dominate* the
            // document. A config file with a handful of `#` comment headings
            // still has far more mappings than headings; an absolute threshold
            // rejected those outright (25 of 37 remaining cases).
            && !(context.atxHeadingCount >= 3
                 && context.atxHeadingCount * 2 >= context.mappingLineCount)
        let usedStructuralFallback = !parserValidated && structurallyYAML

        guard parserValidated || usedStructuralFallback else {
            return nil
        }
        guard features.structuralSignalCount > 0 else { return nil }

        var score = 0.0
        var reasons: [ClassificationReason] = []
        if usedStructuralFallback {
            reasons.append(.structuralFallback)
        }

        if features.keyValueCount >= 1 {
            score += 0.10
        }
        if features.hasMultipleKeyValuePairs {
            score += 0.45
            reasons.append(.multipleKeyValuePairs)
        }
        if features.hasNestedIndentation {
            score += 0.25
            reasons.append(.nestedIndentation)
        }
        if features.hasListItems {
            score += 0.25
            reasons.append(.yamlList)
        }
        if features.hasDocumentMarker {
            score += 0.15
            reasons.append(.yamlDocumentMarker)
        }
        if features.hasYamlComments {
            score += 0.05
        }
        if features.hasBlockScalar {
            score += 0.35
            reasons.append(.parserValidated)
        }
        if features.hasKubernetesStructure {
            score += 0.50
            reasons.append(.kubernetesStructure)
        }

        // Parser validation is represented by enough structural signals here.
        if features.structuralSignalCount >= 2 {
            score += 0.15
            reasons.append(.parserValidated)
        }

        let common = context.textFeatures
        if common.hasTimestamp {
            score -= 0.15
            reasons.append(.timestamp)
        }
        // Heading-dominant text is Markdown: a document whose `#` lines
        // outnumber its mappings is a README, not a YAML file with comments.
        // Measured on real repository files: Markdown read as YAML had ~36
        // headings vs ~21 mappings, while correctly-classified YAML had ~2 vs ~26.
        // Only when the subset parser could NOT validate the text. A file the
        // parser did parse is YAML no matter how many `#` comment banners it
        // carries — 13 otherwise-correct files were knocked below Markdown by
        // this penalty, while only 3 of 333 Markdown samples are parseable.
        if !parseable,
           context.atxHeadingCount >= 5,
           Double(context.atxHeadingCount)
            > Double(context.mappingLineCount) * 1.5 {
            score -= 0.45
            reasons.append(.markdownStructure)
        }
        if common.hasDecodeFailure {
            score -= 0.40
            reasons.append(.decodeFailure)
        }
        if common.hasException {
            score -= 0.40
            reasons.append(.exception)
        }
        if common.hasStackTrace {
            score -= 0.50
            reasons.append(.stackTrace)
        }
        if common.hasFatalError {
            score -= 0.45
        }
        if common.hasNaturalLanguage {
            score -= 0.20
            reasons.append(.naturalLanguage)
        }
        if features.hasChineseProsePairs {
            score -= 0.45
            reasons.append(.naturalLanguage)
        }

        score = max(0, min(score, 1))

        if features.structuralSignalCount < 2 {
            return nil
        }

        guard score > 0 else { return nil }

        return ClassificationResult(
            tag: .yaml,
            score: score,
            confidence: Self.confidence(for: score),
            reasons: reasons
        )
    }

    private static func confidence(
        for score: Double
    ) -> ClassificationConfidence {
        if score >= 0.80 { return .high }
        if score >= 0.50 { return .medium }
        return .low
    }
}

private struct MarkdownClassifier: ContentClassifier {
    let tag: SmartTag = .markdown

    private static let headingRegex = try? NSRegularExpression(
        pattern: #"^#{1,6}\s+.+$"#
    )
    private static let listRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:[-*+]|\d+\.)\s+.+$"#
    )
    private static let tableRegex = try? NSRegularExpression(
        pattern: #"^\s*\|?[\s:\-|]+\|?\s*$"#
    )
    private static let hrRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"#
    )

    func classify(
        _ context: ClassificationContext
    ) -> ClassificationResult? {
        let lines = context.nonEmptyLines
        var headingCount = 0
        var listCount = 0
        var codeFenceCount = 0
        var tableCount = 0
        var blockquoteCount = 0
        var linkCount = 0
        var boldCount = 0
        var hrCount = 0

        for (index, line) in lines.enumerated() {
            if MarkdownClassifier.headingRegex?.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ) != nil {
                headingCount += 1
            } else if MarkdownClassifier.listRegex?.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ) != nil {
                listCount += 1
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                codeFenceCount += 1
            }
            if line.hasPrefix(">") {
                blockquoteCount += 1
            }
            if MarkdownClassifier.tableRegex?.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ) != nil,
               index + 1 < lines.count,
               lines[index + 1].contains("|") {
                tableCount += 1
            }
            if line.contains("[") && line.contains("](") {
                linkCount += 1
            }
            if line.contains("**") {
                boldCount += 1
            }
            if MarkdownClassifier.hrRegex?.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
            ) != nil {
                hrCount += 1
            }
        }

        let hasHeading = headingCount > 0
        // P1 修复（2026-10-02）：`linkCount > 0` 从"一票通过项"移除——正文中
        // 出现**一个**链接是普通句子的常态，不该单凭它就把整段判成 Markdown
        // （链接权重恰好 0.40、及格线也恰好 0.40，轻重颠倒：单个 ATX 标题
        // 反而不够）。链接降为普通加分项，见下。
        let hasStrongStructure =
            codeFenceCount >= 2
            || tableCount > 0
            || listCount >= 2
            || blockquoteCount >= 2
            || hrCount > 0
            || (lines.first == "---" && lines.dropFirst().contains("---"))
        guard hasHeading || hasStrongStructure else {
            return nil
        }

        var score = 0.0
        var reasons: [ClassificationReason] = []
        if hasHeading {
            score += 0.25
        }
        if listCount > 0 {
            score += listCount >= 2 ? 0.40 : 0.20
        }
        if codeFenceCount >= 2 {
            score += 0.45
        }
        if tableCount > 0 {
            score += 0.40
        }
        if blockquoteCount > 0 {
            score += blockquoteCount >= 2 ? 0.40 : 0.20
        }
        if linkCount > 0 {
            // 0.15：标题(0.25)+链接(0.15) 恰好过线——"一行标题带一个链接"
            // 是 README 片段的常态；而裸链接配不上独立达标。
            score += 0.15
        }
        if boldCount > 0 {
            score += 0.10
        }
        if hrCount > 0 {
            score += 0.15
        }
        if lines.first == "---" && lines.dropFirst().contains("---") {
            score += 0.20
        }
        // A wall of `key: value` with no headings is a config file that happens
        // to contain bullet-like lines, not a Markdown document. Measured on
        // real repositories: YAML read as Markdown had ~33 mappings vs ~0
        // headings, while correctly-classified Markdown had ~0 mappings.
        if context.mappingLineCount >= 5,
           Double(context.mappingLineCount)
            > Double(context.atxHeadingCount) * 3 {
            score -= 0.45
            reasons.append(.yamlMapping)
        }

        score = max(0, min(score, 1))
        guard score >= 0.40 else { return nil }
        return ClassificationResult(
            tag: .markdown,
            score: score,
            confidence: score >= 0.80 ? .high : .medium,
            reasons: reasons
        )
    }
}

private struct YAMLFeatures: Sendable {
    let keyValueCount: Int
    let hasMultipleKeyValuePairs: Bool
    let hasNestedIndentation: Bool
    let hasListItems: Bool
    let hasDocumentMarker: Bool
    let hasYamlComments: Bool
    let hasKubernetesStructure: Bool
    let hasChineseProsePairs: Bool
    let hasBlockScalar: Bool
    let structuralSignalCount: Int
}

private enum YAMLFeatureDetector {
    private static let mappingLineRegex = try? NSRegularExpression(
        pattern: #"^\s*[\p{L}\p{N}_.-]+\s*:(?:\s.*)?$"#
    )
    private static let listItemRegex = try? NSRegularExpression(
        pattern: #"^\s*-\s+.+$"#
    )
    private static let hanRegex = try? NSRegularExpression(
        pattern: #"\p{Han}"#
    )
    private static let blockScalarRegex = try? NSRegularExpression(
        pattern: #"^\s*[\p{L}\p{N}_.-]+\s*:\s*[|>]\s*(?:#.*)?$"#
    )

    static func detect(_ context: ClassificationContext) -> YAMLFeatures {
        let lines = context.nonEmptyLines
        let mappingLines = lines.filter { Self.isMappingLine($0) }
        let keyValueCount = mappingLines.count
        let listCount = lines.filter { isListItem($0) }.count
        let blockScalarCount = lines.filter {
            blockScalarRegex?.firstMatch(
                in: $0,
                range: NSRange($0.startIndex..., in: $0)
            ) != nil
        }.count
        let commentCount = lines.filter { isComment($0) }.count
        let docMarkerCount = lines.filter {
            $0 == "---" || $0 == "..."
        }.count
        let lowercasedKeys = Set(
            mappingLines.map { lowercasedKey($0).lowercased() }
        )
        let kubernetes =
            lowercasedKeys.contains("apiversion")
            && lowercasedKeys.contains("kind")

        // `lines` is empty for whitespace-only text (the trimmer removes the
        // single blank line), and `1..<0` is a trap rather than an empty range.
        let nested = lines.count >= 2 && (1..<lines.count).contains { index in
            let previous = lines[index - 1]
            let current = lines[index]
            guard isMappingLine(previous), isMappingLine(current) else {
                return false
            }
            let previousIndent = leadingSpaces(previous)
            let currentIndent = leadingSpaces(current)
            return currentIndent >= previousIndent + 2
        }
        let hasChineseProsePairs =
            keyValueCount >= 2
            && mappingLines.allSatisfy {
                hanRegex?.firstMatch(
                    in: $0,
                    range: NSRange($0.startIndex..., in: $0)
                ) != nil
            }
            && listCount == 0
            && !nested
            && commentCount == 0
            && docMarkerCount == 0

        let structuralSignalCount =
            (keyValueCount > 0 ? 1 : 0)
            + (keyValueCount >= 2 ? 1 : 0)
            + (nested ? 1 : 0)
            + (listCount > 0 ? 1 : 0)
            + (blockScalarCount > 0 ? 1 : 0)
            + (docMarkerCount > 0 ? 1 : 0)
            + (commentCount > 0 ? 1 : 0)

        return YAMLFeatures(
            keyValueCount: keyValueCount,
            hasMultipleKeyValuePairs: keyValueCount >= 2,
            hasNestedIndentation: nested,
            hasListItems: listCount > 0,
            hasDocumentMarker: docMarkerCount > 0,
            hasYamlComments: commentCount > 0,
            hasKubernetesStructure: kubernetes,
            hasChineseProsePairs: hasChineseProsePairs,
            hasBlockScalar: blockScalarCount > 0,
            structuralSignalCount: structuralSignalCount
        )
    }

    private static func isMappingLine(_ line: String) -> Bool {
        mappingLineRegex?.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) != nil
    }

    private static func lowercasedKey(_ line: String) -> String {
        let parts = line.split(separator: ":", maxSplits: 1)
        return parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func isListItem(_ line: String) -> Bool {
        listItemRegex?.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) != nil
    }

    private static func isComment(_ line: String) -> Bool {
        line.hasPrefix("#")
    }
}
