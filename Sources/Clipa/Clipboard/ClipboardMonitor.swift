import AppKit
import Foundation
import UniformTypeIdentifiers

final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    var onCapture: ((NewClip, _ captureEpoch: UInt64) -> Void)?

    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?

    private var loggedDropReasons: Set<String> = []
    private let dropLogLock = NSLock()

    private static let pollIntervalMilliseconds = 100

    private static let attributionWindowLimit: TimeInterval = 0.5

    private static let maxProcessingDepth = 8

    private var processingDepth = 0
    private let processingDepthLock = NSLock()

    private var lastPollAt = Date()
    private var captureGate = PasteboardCaptureGate()
    private let processor = ClipboardProcessor()
    private let activeApps = ActiveAppTracker.shared
    private let processingQueue = DispatchQueue(
        label: "com.clipa.clipboard-processing",
        qos: .userInitiated
    )

    private var hasAnnouncedConfidentialSkip = false

    private var settings: SettingsStore { .shared }

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        pollOnce()
        NSLog(
            "Clipa clipboard monitor started (\(Self.pollIntervalMilliseconds)ms poll)"
        )
        let source = DispatchSource.makeTimerSource(queue: .main)

        source.schedule(
            deadline: .now(),
            repeating: .milliseconds(Self.pollIntervalMilliseconds),
            leeway: .milliseconds(20)
        )
        source.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func ignoreNextChange() {
        suppressedChangeCount = NSPasteboard.general.changeCount
    }

    func resetChangeCount() {
        lastChangeCount = NSPasteboard.general.changeCount
        suppressedChangeCount = nil
    }

    func beginClearBarrier() {
        captureGate.beginClear(
            at: NSPasteboard.general.changeCount
        )
    }

    func isCurrentCapture(_ epoch: UInt64) -> Bool {
        captureGate.isCurrent(epoch)
    }

    var currentCaptureEpoch: UInt64 {
        captureGate.epoch
    }

    func flushPendingCapture() {
        pollOnce()
    }

    nonisolated static func captureSource(
        owners: [ActiveAppTracker.FrontmostSegment],
        isOwnApp: (String?) -> Bool,
        lastExternalName: String?
    ) -> (name: String?, bundleID: String?) {
        if let external = owners.last(where: { !isOwnApp($0.bundleID) }) {
            return (external.name, external.bundleID)
        }
        return (lastExternalName, nil)
    }

    private func pollOnce() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount

        let now = Date()

        let windowStart = max(
            lastPollAt,
            now.addingTimeInterval(-Self.attributionWindowLimit)
        )
        lastPollAt = now
        activeApps.record(NSWorkspace.shared.frontmostApplication, at: now)
        guard changeCount != lastChangeCount else { return }

        let overwritten = changeCount - lastChangeCount - 1
        if overwritten > 0 {
            NSLog(
                "Clipa pasteboard change %d → %d: %d intermediate change(s) "
                    + "were overwritten before the poll could read them",
                lastChangeCount,
                changeCount,
                overwritten
            )
        } else {
            NSLog(
                "Clipa pasteboard change %d → %d",
                lastChangeCount,
                changeCount
            )
        }
        defer { lastChangeCount = changeCount }

        let isOwnPasteboardWrite = suppressedChangeCount == changeCount
        suppressedChangeCount = nil

        guard captureGate.shouldCapture(changeCount: changeCount) else {
            noteDrop("clear-history barrier")
            return
        }

        if isOwnPasteboardWrite {
            noteDrop("own pasteboard write")
            return
        }

        let policy = processor.policySnapshot(settings: settings)
        if policy.pauseRecording {
            noteDrop("recording paused")
            return
        }

        var owners = activeApps.frontmostSince(windowStart, now: now)
        if owners.isEmpty {
            let front = NSWorkspace.shared.frontmostApplication
            owners = [
                ActiveAppTracker.FrontmostSegment(
                    bundleID: front?.bundleIdentifier,
                    name: front?.localizedName,
                    startedAt: now
                )
            ]
        }

        if policy.ignores(anyOf: owners.map(\.bundleID)) {
            noteDrop(
                "ignored app: "
                    + owners.compactMap(\.bundleID).joined(separator: ", ")
            )
            return
        }
        let source = Self.captureSource(
            owners: owners,
            isOwnApp: { policy.isOwnApp(bundleID: $0) },
            lastExternalName: activeApps.lastExternalApp?.localizedName
        )

        if policy.skipConfidential,
           let marker = ConfidentialMarker.matched(in: pasteboard) {
            announceConfidentialSkipOnce(marker)
            return
        }

        guard let capture = ClipboardMonitor.inspect(pasteboard) else {
            noteDrop(
                "nothing capturable in "
                    + (pasteboard.types?.map(\.rawValue).joined(separator: ",")
                        ?? "no types")
            )
            return
        }
        let captureEpoch = captureGate.epoch

        guard beginProcessing() else {
            noteDrop("capture backlog full")
            return
        }
        processingQueue.async { [weak self] in
            guard let self else { return }
            defer { self.finishProcessing() }
            let decision = self.processor.process(
                capture: capture,
                sourceName: source.name,
                sourceBundle: source.bundleID,
                policy: policy
            )
            if case .captured(let draft) = decision {
                Self.noteCaptureAccepted(draft, source: source.name)
                DispatchQueue.main.async {
                    self.onCapture?(draft, captureEpoch)
                }
            } else {
                self.noteProcessorDrop(decision)
            }
        }
    }

    private func beginProcessing() -> Bool {
        processingDepthLock.lock()
        defer { processingDepthLock.unlock() }
        guard processingDepth < Self.maxProcessingDepth else { return false }
        processingDepth += 1
        return true
    }

    private func finishProcessing() {
        processingDepthLock.lock()
        processingDepth = max(0, processingDepth - 1)
        processingDepthLock.unlock()
    }

    private func noteProcessorDrop(_ decision: CaptureDecision) {
        switch decision {
        case .captured:
            break
        case .paused:
            noteDrop("processor: paused")
        case .ignoredSource:
            noteDrop("processor: ignored source")
        case .confidentialSkipped:
            noteDrop("processor: confidential marker")
        case .sensitiveSkipped:
            noteDrop("processor: sensitive content")
        case .noContent:
            noteDrop("processor: no content")
        }
    }

    private static var hasLoggedAcceptedCapture = false

    private static let acceptedLogLock = NSLock()

    private static func noteCaptureAccepted(_ draft: NewClip, source: String?) {
        acceptedLogLock.lock()
        let isFirst = !hasLoggedAcceptedCapture
        hasLoggedAcceptedCapture = true
        acceptedLogLock.unlock()
        guard isFirst else { return }
        NSLog(
            "Clipa capture accepted: kind=%@ source=%@",
            String(describing: draft.kind.rawValue),
            source ?? "unknown"
        )
    }

    enum CaptureDecision: Equatable {
        case paused
        case ignoredSource

        case confidentialSkipped
        case sensitiveSkipped
        case noContent
        case captured(NewClip)

        static func == (lhs: CaptureDecision, rhs: CaptureDecision) -> Bool {
            switch (lhs, rhs) {
            case (.paused, .paused),
                 (.ignoredSource, .ignoredSource),
                 (.confidentialSkipped, .confidentialSkipped),
                 (.sensitiveSkipped, .sensitiveSkipped),
                 (.noContent, .noContent):
                return true
            default:
                return false
            }
        }
    }

    enum ConfidentialMarker {
        static let types: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("com.agilebits.onepassword")
        ]

        static func matched(
            in pasteboard: NSPasteboard
        ) -> NSPasteboard.PasteboardType? {
            let present = Set(pasteboard.types ?? [])
            return types.first { present.contains($0) }
        }

        static func isPresent(on pasteboard: NSPasteboard) -> Bool {
            matched(in: pasteboard) != nil
        }
    }

    private func announceConfidentialSkipOnce(
        _ marker: NSPasteboard.PasteboardType
    ) {
        guard !hasAnnouncedConfidentialSkip else { return }
        hasAnnouncedConfidentialSkip = true

        NSLog("Clipa skipped a pasteboard marked %@", marker.rawValue)
    }

    private func noteDrop(_ reason: String) {
        dropLogLock.lock()
        let isNew = loggedDropReasons.insert(reason).inserted
        dropLogLock.unlock()
        guard isNew else { return }
        NSLog("Clipa capture skipped: %@", reason)
    }

    func evaluate(
        pasteboard: NSPasteboard,
        frontBundleID: String?,
        sourceName: String?,
        settings: SettingsStore,
        store: ClipStore
    ) -> CaptureDecision {
        processor.evaluate(
            pasteboard: pasteboard,
            frontBundleID: frontBundleID,
            sourceName: sourceName,
            settings: settings,
            store: store
        )
    }

    static func inspect(_ pasteboard: NSPasteboard) -> CaptureResult? {
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        let pngData = pasteboard.data(forType: .png)

        var tiffLoaded = false
        var tiffCache: Data?
        func tiffData() -> Data? {
            if !tiffLoaded {
                tiffCache = pasteboard.data(forType: .tiff)
                tiffLoaded = true
            }
            return tiffCache
        }

        let finderFileTypes = [
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("com.apple.finder.noderef")
        ]

        let presentTypes = Set(pasteboard.types ?? [])
        let isFinderFileSelection = finderFileTypes.contains {
            presentTypes.contains($0)
        }

        if fileURLs.count == 1,
           let url = fileURLs.first,
           UTType(filenameExtension: url.pathExtension)?
               .conforms(to: .image) == true {
            return CaptureResult(
                kind: .image,
                text: "",
                imageData: pngData,
                tiffImageData: tiffData(),
                imageFileURL: url,
                fileURLs: fileURLs
            )
        }

        if isFinderFileSelection, !fileURLs.isEmpty {
            return CaptureResult(
                kind: .file,
                text: fileURLs.map(\.path).joined(separator: "\n"),
                imageData: nil,
                tiffImageData: nil,
                imageFileURL: nil,
                fileURLs: fileURLs
            )
        }

        if let png = pngData {
            return CaptureResult(
                kind: .image,
                text: "",
                imageData: png,
                tiffImageData: nil,
                imageFileURL: nil,
                fileURLs: []
            )
        }
        if let tiff = tiffData() {

            return CaptureResult(
                kind: .image,
                text: "",
                imageData: nil,
                tiffImageData: tiff,
                imageFileURL: nil,
                fileURLs: []
            )
        }

        if !fileURLs.isEmpty {
            return CaptureResult(
                kind: .file,
                text: fileURLs.map(\.path).joined(separator: "\n"),
                imageData: nil,
                tiffImageData: nil,
                imageFileURL: nil,
                fileURLs: fileURLs
            )
        }

        let text = pasteboard.string(forType: .string)
        var rtfData: Data?
        var htmlData: Data?
        var attributedText: String?
        if (text ?? "").isEmpty {
            rtfData = pasteboard.data(forType: .rtf)
            if rtfData == nil {
                htmlData = pasteboard.data(forType: .html)
            }
            if rtfData == nil, htmlData == nil {
                attributedText = (pasteboard.readObjects(
                    forClasses: [NSAttributedString.self],
                    options: [:]
                )?.first as? NSAttributedString)?.string
            }
        }
        var urlText: String?
        if (text ?? "").isEmpty,
           (attributedText ?? "").isEmpty,
           rtfData == nil,
           htmlData == nil {
            urlText = pasteboard.string(forType: .URL)
        }
        guard !(text ?? "").isEmpty
            || !(attributedText ?? "").isEmpty
            || rtfData != nil
            || htmlData != nil
            || !(urlText ?? "").isEmpty else {
            return nil
        }
        return CaptureResult(

            kind: .text,
            text: text ?? "",
            imageData: nil,
            tiffImageData: nil,
            imageFileURL: nil,
            fileURLs: [],
            attributedText: attributedText,
            rtfData: rtfData,
            htmlData: htmlData,
            urlText: urlText
        )
    }

    static func classify(_ text: String) -> ClipKind {
        SmartClassifier.inferredClassification(text: text, kind: .text).kind
    }
}
