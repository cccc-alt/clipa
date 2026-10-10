import AppKit
import Foundation
import UniformTypeIdentifiers

/// Owns only the pasteboard observation loop ("发现复制"). Everything after a
/// change is delegated to ClipboardProcessor.
///
/// Threading split:
/// - The main thread inspects `NSPasteboard` (pasteboards are not safe to
///   touch from arbitrary threads) and captures a `CapturePolicySnapshot`.
/// - A serial background queue performs image file writes, hashing and
///   sensitivity classification. Results hop back to the main thread, which
///   is the only place `onCapture` is invoked.
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    var onCapture: ((NewClip, _ captureEpoch: UInt64) -> Void)?

    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?
    /// Drop reasons already logged this launch; see `noteDrop`.
    ///
    /// Written from the main thread (`pollOnce`) *and* from the processing
    /// queue (`noteProcessorDrop`), so every access goes through
    /// `dropLogLock`. An unguarded `Set` mutated from two threads is
    /// undefined behaviour: at best the log loses an entry, at worst the
    /// buffer is corrupted and the app crashes nowhere near the real cause.
    private var loggedDropReasons: Set<String> = []
    private let dropLogLock = NSLock()
    /// How often the pasteboard is inspected. See `start()`.
    private static let pollIntervalMilliseconds = 100
    /// Hard limit on how far back a capture may be attributed, in seconds.
    private static let attributionWindowLimit: TimeInterval = 0.5
    /// How many processed captures may be queued behind each other before new
    /// events are dropped; see `beginProcessing`.
    private static let maxProcessingDepth = 8
    /// Captures waiting on the processing queue. Guarded by
    /// `processingDepthLock` (written from the main thread, read on the queue).
    private var processingDepth = 0
    private let processingDepthLock = NSLock()
    /// When the previous poll ran; bounds the window a change can belong to.
    private var lastPollAt = Date()
    private var captureGate = PasteboardCaptureGate()
    private let processor = ClipboardProcessor()
    private let activeApps = ActiveAppTracker.shared
    private let processingQueue = DispatchQueue(
        label: "com.clipa.clipboard-processing",
        qos: .userInitiated
    )
    /// One explanation per launch for skipped confidential pasteboards. A
    /// per-event line would amount to a log of how often — and when — the user
    /// handled a password.
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
        // A tick only compares an integer and reads the pasteboard when the
        // count actually moved, so polling faster is nearly free — and it is
        // *better* on both sides of the trade. The attribution window is one
        // interval, so a tighter poll means the app that wrote the pasteboard is
        // more likely to still be the frontmost one when the change is noticed
        // (better credit, and a better chance that an ignored app is still
        // visible in the window). The old 200 ms was wide enough for two copies
        // to land inside one tick — only the second one was readable — and for a
        // blocked main thread to stretch the gap further.
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

    /// Starts a new capture generation immediately before a history clear.
    /// Pre-barrier pasteboard changes and in-flight captures will be dropped.
    func beginClearBarrier() {
        captureGate.beginClear(
            at: NSPasteboard.general.changeCount
        )
    }

    func isCurrentCapture(_ epoch: UInt64) -> Bool {
        captureGate.isCurrent(epoch)
    }

    /// Current capture generation, exposed for tests and for callers that
    /// need to queue work behind a clear barrier.
    var currentCaptureEpoch: UInt64 {
        captureGate.epoch
    }

    /// Called before Clipa writes to the general pasteboard. If an external
    /// copy happened since the last poll, it is captured now instead of being
    /// hidden by the upcoming own-write suppression.
    func flushPendingCapture() {
        pollOnce()
    }

    /// Which app a capture is credited to.
    ///
    /// The **newest** app in the poll window that is not Clipa itself, so a
    /// pending external copy is never credited to the panel; when Clipa held
    /// focus for the whole window (the panel is open) the credit goes to the
    /// last app the user was actually in — that is the app they took the
    /// screenshot from, and macOS never tells us who really wrote the
    /// pasteboard.
    ///
    /// Newest, not oldest: the pasteboard was written by whoever had focus when
    /// ⌘C was pressed, while the window also contains the app the user was in
    /// *before* switching — crediting that one labelled copies with an app they
    /// had already left.
    ///
    /// Pure, so the self-test can pin the attribution rules.
    /// 归因结果：本地化显示名 + bundle identifier。bundleID 2026-10-04 起
    /// 一并落库（`clips.source_bundle`）——徽标图标解析优先走它，跨系统
    /// 语言稳定、应用改名不受影响。
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
        // The window a pasteboard change can have happened in: from the last
        // poll until now. Advanced on every poll, including the ones that find
        // nothing, so the window never grows past one interval.
        let now = Date()
        // Clamped, not `lastPollAt` itself: after a sleep/wake or a long
        // main-thread stall the previous poll can be minutes old, and the
        // window would then contain every app the user has been in since —
        // crediting the copy to the wrong one, and letting a long-closed
        // ignored app drop it.
        let windowStart = max(
            lastPollAt,
            now.addingTimeInterval(-Self.attributionWindowLimit)
        )
        lastPollAt = now
        guard changeCount != lastChangeCount else { return }
        // Activation notifications maintain the timeline while idle. Resolve
        // NSWorkspace identity only when there is a capture to attribute.
        activeApps.record(NSWorkspace.shared.frontmostApplication, at: now)
        // One content-free line per pasteboard change: without it, "the app
        // never captured my copy" is indistinguishable from "the poll never
        // saw a change". A gap of more than one means the pasteboard was
        // written *again* before this poll could read it, so the intermediate
        // content is gone — say that out loud instead of only printing the
        // endpoints.
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

        // Consumed here, ahead of every early return below. Clearing it only on
        // the path that used to reach it (the barrier and "recording paused"
        // branches returned first) left a stale count behind — a marker waiting
        // for some later, unrelated copy to match it and be swallowed.
        let isOwnPasteboardWrite = suppressedChangeCount == changeCount
        suppressedChangeCount = nil

        // A change that existed when the user confirmed "clear history" is an
        // old generation even if the polling timer only sees it now.
        guard captureGate.shouldCapture(changeCount: changeCount) else {
            noteDrop("clear-history barrier")
            return
        }

        if isOwnPasteboardWrite {
            noteDrop("own pasteboard write")
            return
        }

        // Cheap policy checks run inline; no content is read unless the event
        // is actually eligible for capture.
        let policy = processor.policySnapshot(settings: settings)
        if policy.pauseRecording {
            noteDrop("recording paused")
            return
        }

        // Every app that was frontmost inside the window, oldest first. An
        // empty timeline (app just launched) falls back to right now.
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
        // Deliberately *no* "Clipa is in the window → drop it" rule here.
        // Clipa's own pasteboard writes are already dropped precisely, by the
        // suppression marker consumed above (`ClipboardWriter` marks the change
        // it just made). Dropping every change seen while the panel held focus
        // also threw away the user's real copies — a screenshot taken with the
        // panel open is attributed to Clipa and never appeared in the history.
        // Every app seen in the window, not just the newest one, and that is
        // deliberate: an ignored app that *was* frontmost within the window may
        // be the one that wrote the pasteboard (the change is only noticed up to
        // one poll later), so narrowing this to the newest app would let a
        // password copied in an ignored app through whenever the user switched
        // away right after. The window is one 200 ms poll, so the cost of the
        // strictness is a copy made within 200 ms of leaving an ignored app —
        // far rarer than the leak it prevents, and this app's whole premise is
        // that the private side of the trade is the one that wins.
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

        // Runs before any content is read, so a copy the source app called
        // secret never reaches the hash, the classifier or the history — for
        // any app, listed or not, and whatever its content looks like.
        if policy.skipConfidential,
           let marker = ConfidentialMarker.matched(in: pasteboard) {
            announceConfidentialSkipOnce(marker)
            return
        }

        // Pasteboard inspection stays on the main thread. The bytes returned
        // by this call are already detached from the pasteboard, so the rest
        // of the pipeline can safely run behind the main thread.
        guard let capture = ClipboardMonitor.inspect(pasteboard) else {
            noteDrop(
                "nothing capturable in "
                    + (pasteboard.types?.map(\.rawValue).joined(separator: ",")
                        ?? "no types")
            )
            return
        }
        let captureEpoch = captureGate.epoch

        // Bounded backlog. Every entry on this queue carries the capture's full
        // payload — a screenshot is tens of megabytes — and nothing capped how
        // many could pile up behind a slow one. Past the limit the newest event
        // is dropped and said so, which is the right thing to lose: it is the
        // one whose content the user just overwrote anyway.
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

    /// Claims a slot on the processing queue; false when the backlog is full.
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

    /// One line per drop reason per launch; content-free.
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

    /// The first accepted capture of a launch, so the log shows both ends of the
    /// pipeline (kind + source only — never the content).
    private static var hasLoggedAcceptedCapture = false
    /// Guards `hasLoggedAcceptedCapture`; the call arrives from the capture
    /// queue while the main thread may be logging a drop at the same time.
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
        /// The source app marked its own pasteboard content confidential
        /// (`org.nspasteboard.*`), so it was never inspected.
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

    /// Pasteboard types by which an app declares its own content off-limits to
    /// clipboard managers.
    ///
    /// `org.nspasteboard.*` is the interoperability convention
    /// (<https://nspasteboard.org>): password managers, browser password
    /// fields and terminal secret prompts mark their copy as `ConcealedType`,
    /// and apps that put content on the pasteboard programmatically for a
    /// one-off paste mark it `TransientType`. The 1Password entry is the
    /// legacy marker older releases still write.
    ///
    /// The check runs against the pasteboard's *type list*, not its payload:
    /// one rule therefore covers text, images and file copies alike, and it
    /// never depends on recognising the source app or on guessing from
    /// content. It is the only reliable way to know that a copy was meant to
    /// be secret — a random password string is indistinguishable from any
    /// other text.
    enum ConfidentialMarker {
        static let types: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("com.agilebits.onepassword")
        ]

        /// The marker that fired, so logs and tests can name the rule instead
        /// of reporting a bare "skipped".
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
        // Names the marker, never the content.
        NSLog("Clipa skipped a pasteboard marked %@", marker.rawValue)
    }

    /// One content-free log line per drop reason per launch.
    ///
    /// "Nothing was captured" used to be silent, which made a field report like
    /// "my screenshot never appeared" impossible to diagnose without attaching a
    /// debugger. The reasons carry no clipboard text, only which gate fired.
    private func noteDrop(_ reason: String) {
        dropLogLock.lock()
        let isNew = loggedDropReasons.insert(reason).inserted
        dropLogLock.unlock()
        guard isNew else { return }
        NSLog("Clipa capture skipped: %@", reason)
    }

    /// Full capture pipeline, evaluable against an isolated pasteboard/store.
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

    /// Pure pasteboard content inspection shared with self-tests.
    ///
    /// Content only — the confidential-marker gate lives in the capture policy
    /// path (`CapturePolicySnapshot.skipConfidential`), because it is a user
    /// preference, not a property of the bytes. Callers that feed real captures
    /// must go through `evaluate`/`pollOnce`, which apply that gate first.
    static func inspect(_ pasteboard: NSPasteboard) -> CaptureResult? {
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        let pngData = pasteboard.data(forType: .png)
        // The TIFF representation is read lazily. macOS publishes an
        // *uncompressed* TIFF beside the PNG for every screenshot and for every
        // Finder icon copy, and this whole function runs on the main thread:
        // reading it unconditionally made the app copy tens of megabytes and
        // then throw the bytes away (only the PNG branch below is taken), so
        // the panel and the hotkey froze for a moment on every screenshot.
        var tiffLoaded = false
        var tiffCache: Data?
        func tiffData() -> Data? {
            if !tiffLoaded {
                tiffCache = pasteboard.data(forType: .tiff)
                tiffLoaded = true
            }
            return tiffCache
        }
        // Finder marks every file copy with these flavors. It also attaches
        // the file's *icon* (`com.apple.icns` / `public.tiff`) and the file
        // name as plain text, none of which is the user's actual selection.
        let finderFileTypes = [
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("com.apple.finder.noderef")
        ]
        // Asked of the *type list*, not of the payload: reading a flavor's
        // data just to learn whether it exists pulled the whole filename plist
        // into memory on the main thread. `pasteboard.types` answers the same
        // question for free.
        let presentTypes = Set(pasteboard.types ?? [])
        let isFinderFileSelection = finderFileTypes.contains {
            presentTypes.contains($0)
        }

        // 1) Exactly one image file copied in Finder. macOS also puts the
        // file's *icon* on the pasteboard (`com.apple.icns` +
        // `public.tiff`, rendered at 1024×1024), which is a thumbnail, not
        // the user's image. The file URL is the truth here, so the original
        // bytes win; the pasted bytes are kept only as a fallback for the
        // case where the file disappears between copy and capture.
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

        // 2) Finder file selections that are not a single image: multiple
        // files, or one non-image file. The attached icon/TIFF must not turn
        // `Package.swift` into an image clip.
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

        // 3) Actual image bytes win over file URLs: screenshots and "copy
        // image" from browsers/apps always land here.
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
            // TIFF → PNG conversion is deferred to the background capture
            // queue; an undecodable image simply becomes `.noContent` there.
            return CaptureResult(
                kind: .image,
                text: "",
                imageData: nil,
                tiffImageData: tiff,
                imageFileURL: nil,
                fileURLs: []
            )
        }

        // 4) Other file copies (multiple files, or a single non-image file)
        // remain real file clips.
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

        // 5) Text. Plain text is taken as-is; rich flavors are read as raw
        // bytes here and decoded on the capture queue (`RichTextDecoder`),
        // which both keeps the main thread free of the HTML importer and is
        // what lets that importer be handed a sanitized document.
        //
        // Order matters: the `NSAttributedString` object read is deliberately
        // last. With an HTML flavor present the system can satisfy that read by
        // importing the HTML itself — the very fetch this design avoids — so it
        // is only attempted when the pasteboard carries neither RTF nor HTML.
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
            // Text media is intentionally cheap here: pasteboard inspection
            // stays on the main thread, so the format engine (JSON/YAML/
            // Markdown) runs once on the background capture queue and can
            // promote the final kind there.
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

    /// Unified coarse kind for text-like content.
    static func classify(_ text: String) -> ClipKind {
        SmartClassifier.inferredClassification(text: text, kind: .text).kind
    }
}
