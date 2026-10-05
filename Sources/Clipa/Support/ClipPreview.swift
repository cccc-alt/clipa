import Foundation

enum ClipPreview {

    static func display(for text: String, limit: Int) -> String {

        let bounded = String(text.prefix(limit))
        return bounded.count == limit ? bounded + "…" : bounded
    }
}
