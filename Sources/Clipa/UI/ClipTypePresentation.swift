import Foundation

/// Presentation-level description of a clip's type.
///
/// Clipa stores two layers: a coarse `ClipKind` (text / image / file,
/// persisted in `clips.kind`) and a fine-grained `SmartTag` (json / yaml /
/// markdown / …). Structured text keeps the coarse `.text` kind, but the
/// format the user cares about is carried by the smart tag.
///
/// Every type label, icon and tint in the panel resolves through this type, so
/// one surface can never read “YAML” while another reads “文本” for the same
/// clip.
struct ClipTypePresentation: Equatable, Sendable {
    /// Which layer produced the displayed type. Kept so tests and callers can
    /// tell a user-visible refinement from the persisted base kind.
    enum Source: Equatable, Sendable {
        case kind(ClipKind)
        case smartTag(SmartTag)
    }

    let source: Source
    let title: String
    let symbolName: String
    /// 类型色。像素农场风里它替回了 `strokeDash`（黑白线稿版用它区分类型）——
    /// "同一个类型在任何界面上都长得一样"这条性质从头到尾没变，变的只是载体。
    let tintHex: String

    init(kind: ClipKind) {
        source = .kind(kind)
        title = kind.displayName
        symbolName = kind.symbolName
        tintHex = kind.tintHex
    }

    init(smartTag: SmartTag) {
        source = .smartTag(smartTag)
        title = smartTag.displayName
        symbolName = smartTag.symbolName
        tintHex = smartTag.tintHex
    }

    /// A refining smart tag always wins over the coarse kind. Placeholder tags
    /// (`text` / `url` / `code` / `image` / `file`) carry no extra detail, so
    /// the kind stays in charge — a code-shaped clip never degrades to “文本”.
    static func resolve(
        kind: ClipKind,
        smartTag: SmartTag
    ) -> ClipTypePresentation {
        if smartTag.refinedKind != nil {
            return ClipTypePresentation(smartTag: smartTag)
        }
        return ClipTypePresentation(kind: kind)
    }

    /// Type names for a search plan. Fine tags win, and a coarse kind is
    /// dropped once a tag already refines it, so `kinds: [text]` +
    /// `smartTags: [yaml]` renders as just “YAML”.
    static func titles(
        kinds: Set<ClipKind>,
        smartTags: Set<SmartTag>
    ) -> [String] {
        let covered = Set(smartTags.compactMap(\.refinedKind))
        let kindTitles = kinds
            .filter { !covered.contains($0) }
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
        let tagTitles = smartTags
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
        var seen = Set<String>()
        return (kindTitles + tagTitles).filter { seen.insert($0).inserted }
    }
}

extension Clip {
    /// Single source of truth for how this clip's type is rendered.
    var typePresentation: ClipTypePresentation {
        ClipTypePresentation.resolve(kind: kind, smartTag: smartTag)
    }
}

extension SmartTag {
    /// The coarse kind this tag refines, or `nil` when the tag only mirrors a
    /// kind (`text` / `image` / `file`).
    var refinedKind: ClipKind? {
        switch self {
        case .json, .yaml, .markdown:
            return .text
        case .text, .image, .file:
            return nil
        }
    }
}
