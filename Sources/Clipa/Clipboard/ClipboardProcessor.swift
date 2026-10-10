import AppKit
import Foundation
import UniformTypeIdentifiers

/// Immutable policy values captured on the main thread at observation time.
///
/// Background capture processing must never read `SettingsStore` directly:
/// its `@Published` properties and `UserDefaults` are not safe to touch from
/// another thread. Applying a snapshot also keeps the decision stable even if
/// the user changes settings while a queued capture is still being processed.
struct CapturePolicySnapshot {
    let pauseRecording: Bool
    let ignoredBundleIDs: Set<String>
    let skipSensitive: Bool
    /// Honour the source app's own "do not record this" pasteboard marker.
    let skipConfidential: Bool
    let ownBundleID: String?

    init(settings: SettingsStore) {
        pauseRecording = settings.pauseRecording
        ignoredBundleIDs = Set(settings.effectiveIgnoredApps)
        skipSensitive = settings.skipSensitive
        skipConfidential = settings.skipConfidentialPasteboard
        ownBundleID = Bundle.main.bundleIdentifier
    }

    func isIgnored(bundleID: String?) -> Bool {
        guard let bundleID,
              let normalized = BundleIDNormalizer.normalize(bundleID) else {
            return false
        }
        return ignoredBundleIDs.contains(normalized)
    }

    /// Fail-closed ignore check used by the capture path: the pasteboard change
    /// may have been made by any app that was frontmost inside the poll window,
    /// so one ignored app among them is enough to drop the capture instead of
    /// recording content the user asked Clipa to skip.
    func ignores(anyOf bundleIDs: [String?]) -> Bool {
        bundleIDs.contains { isIgnored(bundleID: $0) }
    }

    func isOwnApp(bundleID: String?) -> Bool {
        guard let ownBundleID = ownBundleID.flatMap(
            BundleIDNormalizer.normalize
        ) else { return false }
        return BundleIDNormalizer.normalize(bundleID ?? "") == ownBundleID
    }

}

/// Turns a pasteboard event into a validated, fully classified `NewClip`.
///
/// The class is split into two phases so the monitor can keep all pasteboard
/// reads on the main thread and then run the expensive half (image file write,
/// hashing, sensitivity checks, content classification) on a serial background
/// queue:
/// - `evaluate(pasteboard:...)` is the full synchronous pipeline used by
///   self-tests and the `--capture-evaluate` probe.
/// - `process(capture:...)` is the background half and never touches the
///   pasteboard or the settings object.
final class ClipboardProcessor {
    private static let maxImageBytes = 30_000_000

    func policySnapshot(
        settings: SettingsStore
    ) -> CapturePolicySnapshot {
        CapturePolicySnapshot(settings: settings)
    }

    /// Full capture pipeline, evaluable against an isolated pasteboard/store.
    func evaluate(
        pasteboard: NSPasteboard,
        frontBundleID: String?,
        sourceName: String?,
        sourceBundle: String? = nil,
        settings: SettingsStore,
        store: ClipStore
    ) -> ClipboardMonitor.CaptureDecision {
        let policy = CapturePolicySnapshot(settings: settings)
        if policy.pauseRecording {
            return .paused
        }
        // No own-app skip here. Clipa's *own* pasteboard writes are dropped by
        // the monitor's suppression marker (set by `ClipboardWriter`), which is
        // precise; "Clipa was frontmost" is not — the panel holds focus while
        // the user copies elsewhere, and those copies must be recorded.
        if policy.isIgnored(bundleID: frontBundleID) {
            return .ignoredSource
        }
        // Runs before any content is read: a confidential pasteboard is never
        // inspected, so nothing about it can leak into a log, a hash or the
        // history through a later stage.
        if policy.skipConfidential,
           ClipboardMonitor.ConfidentialMarker.isPresent(on: pasteboard) {
            return .confidentialSkipped
        }
        guard let capture = ClipboardMonitor.inspect(pasteboard) else {
            return .noContent
        }
        return process(
            capture: capture,
            sourceName: sourceName,
            sourceBundle: sourceBundle,
            policy: policy
        )
    }

    /// Expensive capture half. Runs on a caller-provided background queue in
    /// the monitor. Image bytes are carried on the draft and persisted with
    /// the row, so there is no separate file write to coordinate.
    func process(
        capture: CaptureResult,
        sourceName: String?,
        sourceBundle: String? = nil,
        policy: CapturePolicySnapshot
    ) -> ClipboardMonitor.CaptureDecision {
        let text = Self.resolvedText(from: capture)
        // A rich-text payload with nothing readable left (an image-only web
        // page copy) is not a clip. Deciding it here keeps the "no empty rows"
        // guarantee that used to come from inspection itself.
        if capture.kind == .text, text.isEmpty {
            return .noContent
        }
        var draft = NewClip(
            kind: capture.kind,
            text: text,
            fileURLs: capture.fileURLs,
            sourceApp: sourceName ?? "未知应用",
            sourceBundle: sourceBundle
        )

        switch capture.kind {
        case .image:
            guard let payload = Self.imagePayload(from: capture) else {
                // A file-backed image we could not read is still worth
                // keeping as a file reference so the copy is not lost.
                if capture.imageFileURL != nil {
                    return .captured(
                        Self.fileDraft(
                            from: capture,
                            sourceName: sourceName,
                            sourceBundle: sourceBundle
                        )
                    )
                }
                return .noContent
            }
            if payload.data.count > Self.maxImageBytes {
                if capture.imageFileURL != nil {
                    return .captured(
                        Self.fileDraft(
                            from: capture,
                            sourceName: sourceName,
                            sourceBundle: sourceBundle
                        )
                    )
                }
                return .noContent
            }
            draft.imageData = payload.data
            draft.imageFormat = payload.format
            draft.contentHash = ContentHasher.hash(data: payload.data)
            // Finder image files become Clipa-owned image clips; the original
            // path must not create a hidden later dependency.
            draft.fileURLs = []
        case .file:
            draft.contentHash = ContentHasher.hash(fileURLs: draft.fileURLs)
        default:
            draft.contentHash = ContentHasher.hash(text: draft.text)
        }

        // The skip gate and the persisted marker have to make the same call.
        // Using only the base rules here let JWT / credentialed DB URLs / SSH
        // keys through while `contains_sensitive` still said true.
        if policy.skipSensitive,
           SensitiveDetector.containsSensitive(text: draft.text) {
            return .sensitiveSkipped
        }

        if capture.kind == .text {
            Self.applyContentClassification(to: &draft)
            draft.containsSensitive =
                SensitiveDetector.containsSensitive(
                    text: draft.text,
                    note: draft.note
                )
        }
        return .captured(draft)
    }

    /// The capture's plain text, decoding rich flavors when the pasteboard
    /// carried no plain string.
    ///
    /// Runs on the capture queue: the HTML importer is WebKit-backed and slow
    /// enough to freeze the panel, and `RichTextDecoder` sanitizes the document
    /// so that importing it cannot open a connection.
    static func resolvedText(from capture: CaptureResult) -> String {
        var candidate = capture.text
        if candidate.isEmpty {
            candidate = capture.attributedText ?? ""
        }
        if candidate.isEmpty, let rtf = capture.rtfData {
            candidate = RichTextDecoder.plainText(fromRTF: rtf) ?? ""
        }
        if candidate.isEmpty, let html = capture.htmlData {
            candidate = RichTextDecoder.plainText(fromHTML: html) ?? ""
        }
        if candidate.isEmpty {
            candidate = capture.urlText ?? ""
        }
        let trimmed = candidate.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return Self.isBlank(trimmed) ? "" : trimmed
    }

    /// True when nothing readable is left: whitespace, or the
    /// object-replacement characters the rich-text importer emits for an
    /// attachment it could not turn into text (an image-only web page copy).
    private static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar == "\u{FFFC}"
                || scalar == "\u{FFFD}"
        }
    }

    /// Runs the classifier exactly once on the background queue and persists
    /// the result on `NewClip`, so the database actor no longer needs to
    /// re-run the same expensive pass for capture-path inserts.
    private static func applyContentClassification(
        to draft: inout NewClip
    ) {
        let result = SmartClassifier.inferredClassification(
            text: draft.text,
            kind: draft.kind
        )
        draft.kind = result.kind
        draft.smartTag = result.smartTag
    }

    private struct ImagePayload {
        let data: Data
        let format: String
    }

    /// Original bytes plus the UTI to store them under.
    ///
    /// Only a pasted TIFF is re-encoded (112 MB → 0.5 MB for a 2560×1440
    /// screen). Everything else keeps its source bytes, so EXIF, animation
    /// and vector payloads survive, and no full-size decode happens here.
    private static func imagePayload(from capture: CaptureResult) -> ImagePayload? {
        // A file-backed image (Finder copy) is read from disk first, and it
        // never falls back to the pasteboard bytes: Finder attaches that
        // file's *icon* there, so a fallback would silently store a 1024×1024
        // thumbnail instead of the user's image. If the file is gone, too
        // large, or not a regular file, the caller keeps a file clip.
        if let url = capture.imageFileURL {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), values.isRegularFile == true else {
                return nil
            }
            if let size = values.fileSize, size > Self.maxImageBytes {
                // Rejected before reading, so a 2 GB file never reaches RAM.
                return nil
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                return nil
            }
            return ImagePayload(data: data, format: imageFormat(for: url))
        }
        if let png = capture.imageData {
            return ImagePayload(data: png, format: UTType.png.identifier)
        }
        if let tiff = capture.tiffImageData {
            if let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                return ImagePayload(data: png, format: UTType.png.identifier)
            }
            // An undecodable TIFF is still the user's image; keep the bytes
            // instead of dropping the capture.
            return ImagePayload(data: tiff, format: UTType.tiff.identifier)
        }
        return nil
    }

    private static func imageFormat(for url: URL) -> String {
        let ext = url.pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext) else {
            return UTType.png.identifier
        }
        return type.identifier
    }

    private static func fileDraft(
        from capture: CaptureResult,
        sourceName: String?,
        sourceBundle: String? = nil
    ) -> NewClip {
        var draft = NewClip(
            kind: .file,
            text: capture.text.isEmpty
                ? capture.fileURLs.map(\.path).joined(separator: "\n")
                : capture.text,
            fileURLs: capture.fileURLs,
            sourceApp: sourceName ?? "未知应用",
            sourceBundle: sourceBundle
        )
        draft.contentHash = ContentHasher.hash(fileURLs: draft.fileURLs)
        return draft
    }
}
