import AppKit
import Foundation

/// Decodes the rich-text flavors of a clipboard capture into plain text.
///
/// Two rules come from the promise that a copy stays on this machine:
///
/// 1. **Decoding must not reach the network.** Foundation's HTML importer is
///    WebKit-backed and resolves remote subresources — copying a web page with
///    `<img src="http://…">` used to make Clipa open connections the moment the
///    pasteboard changed (measured: 4 connections for one image). Everything in
///    the document that could be fetched as a URL is therefore removed before
///    the importer ever sees it, by `sanitizedHTML`.
/// 2. **Decoding must not run on the main thread.** The same importer takes
///    long enough on a big page to freeze the panel, so callers run it on the
///    capture queue.
///
/// RTF needs neither: its reader only handles embedded data.
enum RichTextDecoder {
    /// Plain text of an HTML payload, or `nil` when nothing readable is left.
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

    /// Plain text of an RTF payload.
    static func plainText(fromRTF data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)?.string
    }

    /// Removes everything the HTML importer could use to open a connection.
    ///
    /// Deliberately conservative — the goal is the *text* the user copied, so
    /// dropping markup that only carries layout, styling or embedded media
    /// costs nothing:
    ///
    /// - elements whose content is never the user's text, or whose attributes
    ///   fetch by definition (`script`, `style`, `link`, `meta`, `iframe`,
    ///   `object`, `embed`, media elements, `base`, `template`, …) are removed
    ///   entirely, content included;
    /// - every URL-bearing attribute (`src`, `srcset`, `href`, `background`,
    ///   `poster`, `action`, `cite`, …) is stripped from what remains;
    /// - CSS `url(…)` and `@import` are removed, which covers inline `style`
    ///   attributes and any CSS text that survived.
    ///
    /// Relative references cannot be fetched without a base URL (none is
    /// passed to the importer) but are stripped too, so the rule is uniform and
    /// the output is easy to assert on.
    static func sanitizedHTML(_ html: String) -> String {
        var text = html
        for element in droppedElements {
            text = replacing(
                text,
                pattern: "<\(element)\\b[^>]*>.*?</\(element)\\s*>",
                with: " ",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
            // Void or unclosed forms (`<link …>`, a stray `<meta …>`).
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

    /// Elements removed with their content: none of them contributes visible
    /// text, and each can pull in a URL.
    private static let droppedElements = [
        "script", "style", "link", "meta", "iframe", "frame", "frameset",
        "object", "embed", "applet", "video", "audio", "source", "track",
        "base", "template", "noscript"
    ]

    /// Attributes whose value is a URL the importer would try to load.
    ///
    /// Namespaced forms (`xlink:href`, `xml:base`, …) count too, which is why
    /// the name may carry a prefix. Elements that are kept for their text
    /// (`svg`, `math`, `canvas`) are covered by this rule rather than dropped —
    /// losing a copied formula would be a worse bug than the one being fixed.
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
