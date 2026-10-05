import AppKit
import Foundation

enum RichTextDecoder {

    static func plainText(fromHTML data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let raw, !raw.isEmpty else { return nil }
        let sanitized = sanitizedHTML(raw)
        guard !sanitized.isEmpty else { return nil }
        let attributed = try? NSAttributedString(
            data: Data(sanitized.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
        return attributed?.string
    }

    static func plainText(fromRTF data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)?.string
    }

    static func sanitizedHTML(_ html: String) -> String {
        var text = html
        for element in droppedElements {
            text = replacing(
                text,
                pattern: "<\(element)\\b[^>]*>.*?</\(element)\\s*>",
                with: " ",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )

            text = replacing(
                text,
                pattern: "<\(element)\\b[^>]*>",
                with: " ",
                options: [.caseInsensitive]
            )
            text = replacing(
                text,
                pattern: "</\(element)\\s*>",
                with: " ",
                options: [.caseInsensitive]
            )
        }
        text = replacing(
            text,
            pattern: urlAttributePattern,
            with: "",
            options: [.caseInsensitive]
        )
        text = replacing(
            text,
            pattern: "url\\s*\\([^)]*\\)",
            with: "",
            options: [.caseInsensitive]
        )
        text = replacing(
            text,
            pattern: "@import\\s+[^;]*;?",
            with: "",
            options: [.caseInsensitive]
        )
        return text
    }

    private static let droppedElements = [
        "script", "style", "link", "meta", "iframe", "frame", "frameset",
        "object", "embed", "applet", "video", "audio", "source", "track",
        "base", "template", "noscript"
    ]

    private static let urlAttributePattern =
        "\\s(?:[A-Za-z][\\w.-]*:)?(?:src|srcset|href|background|poster"
        + "|action|formaction|ping"
        + "|longdesc|usemap|manifest|codebase|cite|profile|archive|icon"
        + "|data)\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)"

    private static func replacing(
        _ text: String,
        pattern: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: template
        )
    }
}
