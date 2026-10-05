import Foundation

struct ClipTypePresentation: Equatable, Sendable {

    enum Source: Equatable, Sendable {
        case kind(ClipKind)
        case smartTag(SmartTag)
    }

    let source: Source
    let title: String
    let symbolName: String

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

    static func resolve(
        kind: ClipKind,
        smartTag: SmartTag
    ) -> ClipTypePresentation {
        if smartTag.refinedKind != nil {
            return ClipTypePresentation(smartTag: smartTag)
        }
        return ClipTypePresentation(kind: kind)
    }

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

    var typePresentation: ClipTypePresentation {
        ClipTypePresentation.resolve(kind: kind, smartTag: smartTag)
    }
}

extension SmartTag {

    var refinedKind: ClipKind? {
        switch self {
        case .json, .yaml, .markdown:
            return .text
        case .text, .image, .file:
            return nil
        }
    }
}
