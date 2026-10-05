import Foundation

enum SearchTextSafety {
    static func isByteSubstringSafe(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }

        guard value.count == value.unicodeScalars.count else { return false }
        for scalar in value.unicodeScalars
        where isCombiningMark(scalar) {
            return false
        }
        return true
    }

    static func isByteSubstringSafe(text: String, note: String) -> Bool {
        isByteSubstringSafe(text) && isByteSubstringSafe(note)
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}
