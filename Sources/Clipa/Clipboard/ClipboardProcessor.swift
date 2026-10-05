import AppKit
import Foundation
import UniformTypeIdentifiers

struct CapturePolicySnapshot {
    let pauseRecording: Bool
    let ignoredBundleIDs: Set<String>
    let skipSensitive: Bool

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

final class ClipboardProcessor {
    private static let maxImageBytes = 30_000_000

    func policySnapshot(
        settings: SettingsStore
    ) -> CapturePolicySnapshot {
        CapturePolicySnapshot(settings: settings)
    }

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

        if policy.isIgnored(bundleID: frontBundleID) {
            return .ignoredSource
        }

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

    func process(
        capture: CaptureResult,
        sourceName: String?,
        sourceBundle: String? = nil,
        policy: CapturePolicySnapshot
    ) -> ClipboardMonitor.CaptureDecision {
        let text = Self.resolvedText(from: capture)

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

            draft.fileURLs = []
        case .file:
            draft.contentHash = ContentHasher.hash(fileURLs: draft.fileURLs)
        default:
            draft.contentHash = ContentHasher.hash(text: draft.text)
        }

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

    private static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar == "\u{FFFC}"
                || scalar == "\u{FFFD}"
        }
    }

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

    private static func imagePayload(from capture: CaptureResult) -> ImagePayload? {

        if let url = capture.imageFileURL {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), values.isRegularFile == true else {
                return nil
            }
            if let size = values.fileSize, size > Self.maxImageBytes {

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
